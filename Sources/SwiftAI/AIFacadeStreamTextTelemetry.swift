import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


enum StreamTextTelemetryPart: Sendable {
    case part(LanguageStreamPart)
    case retryAttemptBoundary
}

func streamTextWithTelemetry(
    makeStream: @escaping @Sendable () async throws -> AsyncThrowingStream<LanguageStreamPart, Error>,
    operationID: String,
    providerID: String,
    modelID: String?,
    input: JSONValue?,
    retryPolicy: AIRetryPolicy,
    streamRetries: Int? = nil,
    telemetry: Telemetry.Options?,
    abortSignal: AIAbortSignal? = nil,
    logWarnings: Bool = true
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    publicLanguageStream(
        streamTextWithTelemetryParts(
            makeStream: makeStream,
            operationID: operationID,
            providerID: providerID,
            modelID: modelID,
            input: input,
            retryPolicy: retryPolicy,
            streamRetries: streamRetries,
            telemetry: telemetry,
            abortSignal: abortSignal,
            logWarnings: logWarnings
        )
    )
}

func streamTextWithTelemetryParts(
    makeStream: @escaping @Sendable () async throws -> AsyncThrowingStream<LanguageStreamPart, Error>,
    operationID: String,
    providerID: String,
    modelID: String?,
    input: JSONValue?,
    retryPolicy: AIRetryPolicy,
    streamRetries: Int? = nil,
    telemetry: Telemetry.Options?,
    abortSignal: AIAbortSignal? = nil,
    logWarnings: Bool = true
) -> AsyncThrowingStream<StreamTextTelemetryPart, Error> {
    let dispatcher = TelemetryDispatcher(options: telemetry)
    let callID = UUID().uuidString
    let started = DispatchTime.now().uptimeNanoseconds
    let terminalState = AIStreamTerminalState()

    return AsyncThrowingStream { continuation in
        let task = Task {
            var step = LanguageStreamToolStep()

            do {
                await dispatcher.record(telemetryEvent(
                    kind: .start,
                    callID: callID,
                    operationID: operationID,
                    providerID: providerID,
                    modelID: modelID,
                    options: telemetry,
                    maxRetries: retryPolicy.maxRetries,
                    input: input
                ))
                try validateRetryPolicy(retryPolicy)
                if let streamRetries, streamRetries < 0 {
                    throw AIError.invalidArgument(
                        argument: "streamRetries",
                        message: "streamRetries must be greater than or equal to zero."
                    )
                }
                let canRetryAfterStreamStart = (streamRetries ?? 0) > 0

                var errors: [String] = []
                var delay = retryPolicy.initialDelayNanoseconds
                var streamRetryCount = 0
                while true {
                    var yieldedPart = false
                    var receivedPart = false
                    var attemptStep = LanguageStreamToolStep()
                    var bufferedAttemptParts: [LanguageStreamPart] = []
                    var isBufferingAttemptParts = false
                    var openTextPartIDs: Set<String> = []
                    var openReasoningPartIDs: Set<String> = []
                    var retryFailure: Error?
                    var streamEndedWithoutOutput = false
                    var receivedSemanticOutput = false
                    var receivedTerminalPart = false
                    do {
                        let stream = try await dispatcher.executeLanguageModelCall(
                            callID: callID,
                            operationID: operationID,
                            providerID: providerID,
                            modelID: modelID,
                            operation: makeStream
                        )
                        for try await part in stream {
                            try Task.checkCancellation()
                            receivedPart = true
                            let outgoingPart: LanguageStreamPart
                            switch part {
                            case let .finish(reason, usage) where reason == nil && attemptStep.hasUnterminatedInBandError:
                                outgoingPart = .finish(reason: "error", usage: usage)
                            case let .finishMetadata(reason, usage, metadata) where reason == nil && attemptStep.hasUnterminatedInBandError:
                                outgoingPart = .finishMetadata(reason: "error", usage: usage, providerMetadata: metadata)
                            default:
                                outgoingPart = part
                            }
                            receivedSemanticOutput = receivedSemanticOutput || isStreamRetrySemanticOutput(outgoingPart)
                            receivedTerminalPart = receivedTerminalPart || outgoingPart.isStreamRetryTerminalPart

                            if let providerError = outgoingPart.streamProviderError,
                               providerError.isRetryable,
                               let streamRetries,
                               streamRetryCount < streamRetries {
                                retryFailure = providerError
                                break
                            }

                            if outgoingPart.streamProviderError != nil,
                               !bufferedAttemptParts.isEmpty {
                                for bufferedPart in bufferedAttemptParts {
                                    updateStreamRetryOpenParts(
                                        bufferedPart,
                                        textIDs: &openTextPartIDs,
                                        reasoningIDs: &openReasoningPartIDs
                                    )
                                    continuation.yield(.part(bufferedPart))
                                    yieldedPart = true
                                }
                                bufferedAttemptParts = []
                                isBufferingAttemptParts = false
                            }

                            attemptStep.record(outgoingPart)
                            if canRetryAfterStreamStart,
                               isBufferingAttemptParts || isStreamRetryBufferedPart(outgoingPart) {
                                isBufferingAttemptParts = true
                                bufferedAttemptParts.append(outgoingPart)
                                continue
                            }
                            updateStreamRetryOpenParts(
                                outgoingPart,
                                textIDs: &openTextPartIDs,
                                reasoningIDs: &openReasoningPartIDs
                            )
                            continuation.yield(.part(outgoingPart))
                            yieldedPart = true
                        }

                        if let retryFailure {
                            streamRetryCount += 1
                            for id in openTextPartIDs.sorted() {
                                continuation.yield(.part(.textEnd(id: id)))
                            }
                            for id in openReasoningPartIDs.sorted() {
                                continuation.yield(.part(.reasoningEnd(id: id)))
                            }
                            openTextPartIDs.removeAll()
                            openReasoningPartIDs.removeAll()
                            await dispatcher.record(telemetryEvent(
                                kind: .retry,
                                callID: callID,
                                operationID: operationID,
                                providerID: providerID,
                                modelID: modelID,
                                options: telemetry,
                                attempt: streamRetryCount,
                                maxRetries: streamRetries ?? 0,
                                delayNanoseconds: 0,
                                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                                errorDescription: String(describing: retryFailure)
                            ))
                            continuation.yield(.retryAttemptBoundary)
                            continue
                        }

                        if !receivedTerminalPart && !receivedSemanticOutput {
                            streamEndedWithoutOutput = true
                            throw AIError.invalidResponse(
                                provider: providerID,
                                message: "No output generated. The model stream ended without a finish chunk."
                            )
                        }

                        for bufferedPart in bufferedAttemptParts {
                            updateStreamRetryOpenParts(
                                bufferedPart,
                                textIDs: &openTextPartIDs,
                                reasoningIDs: &openReasoningPartIDs
                            )
                            continuation.yield(.part(bufferedPart))
                            yieldedPart = true
                        }
                        step = attemptStep
                        if step.hasUnterminatedInBandError {
                            let terminal = LanguageStreamPart.finishMetadata(
                                reason: "error",
                                usage: step.usage,
                                providerMetadata: [:]
                            )
                            step.record(terminal)
                            continuation.yield(.part(terminal))
                            yieldedPart = true
                        }
                        let result = TextGenerationResult(
                            text: step.text,
                            reasoning: step.reasoning,
                            finishReason: step.finishReason,
                            usage: step.usage,
                            toolCalls: step.toolCalls,
                            toolApprovalRequests: step.approvalRequests,
                            toolApprovalResponses: step.approvalResponses,
                            providerMetadata: step.providerMetadata,
                            rawValue: .object([:]),
                            warnings: step.warnings,
                            requestMetadata: input.map { AIRequestMetadata(body: $0) } ?? AIRequestMetadata(),
                            responseMetadata: step.responseMetadata
                        )
                        if await terminalState.claimTerminalEvent() {
                            await dispatcher.record(telemetryEvent(
                                kind: .end,
                                callID: callID,
                                operationID: operationID,
                                providerID: providerID,
                                modelID: modelID,
                                options: telemetry,
                                maxRetries: retryPolicy.maxRetries,
                                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                                output: textGenerationTelemetryOutput(result),
                                usage: result.usage,
                                warnings: result.warnings,
                                providerMetadata: result.providerMetadata,
                                responseMetadata: result.responseMetadata,
                                useResponseModelID: true
                            ))
                            if logWarnings {
                                await AIWarningLogging.logWarnings(result.warnings, providerID: providerID, modelID: modelID)
                            }
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        throw AIRetryError(reason: .cancelled, attempts: errors.count + 1, errors: errors)
                    } catch {
                        if streamEndedWithoutOutput {
                            throw error
                        }
                        if yieldedPart || receivedPart {
                            throw error
                        }
                        errors.append(String(describing: error))
                        let attempts = errors.count
                        guard retryPolicy.maxRetries > 0 else { throw error }
                        guard isRetryable(error) else {
                            if attempts == 1 { throw error }
                            throw AIRetryError(reason: .errorNotRetryable, attempts: attempts, errors: errors)
                        }
                        guard attempts <= retryPolicy.maxRetries else {
                            throw AIRetryError(reason: .maxRetriesExceeded, attempts: attempts, errors: errors)
                        }
                        let sleepDelay = retryDelayNanoseconds(from: error, exponentialBackoffDelay: delay)
                        await dispatcher.record(telemetryEvent(
                            kind: .retry,
                            callID: callID,
                            operationID: operationID,
                            providerID: providerID,
                            modelID: modelID,
                            options: telemetry,
                            attempt: attempts,
                            maxRetries: retryPolicy.maxRetries,
                            delayNanoseconds: sleepDelay,
                            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                            errorDescription: String(describing: error)
                        ))
                        if sleepDelay > 0 {
                            try await sleep(nanoseconds: sleepDelay, abortSignal: abortSignal)
                        }
                        delay = nextDelay(current: delay, policy: retryPolicy)
                    }
                }
            } catch {
                if isCancellationTelemetryError(error) {
                    let abortDescription = abortSignal.flatMap { signal in
                        signal.isAborted ? signal.reason : nil
                    } ?? String(describing: error)
                    if await terminalState.claimTerminalEvent() {
                        await dispatcher.record(telemetryEvent(
                            kind: .abort,
                            callID: callID,
                            operationID: operationID,
                            providerID: providerID,
                            modelID: modelID,
                            options: telemetry,
                            maxRetries: retryPolicy.maxRetries,
                            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                            errorDescription: abortDescription
                        ))
                    }
                    continuation.finish()
                } else {
                    if await terminalState.claimTerminalEvent() {
                        await dispatcher.record(telemetryEvent(
                            kind: .error,
                            callID: callID,
                            operationID: operationID,
                            providerID: providerID,
                            modelID: modelID,
                            options: telemetry,
                            maxRetries: retryPolicy.maxRetries,
                            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                            errorDescription: String(describing: error)
                        ))
                    }
                    continuation.finish(throwing: error)
                }
            }
        }

        continuation.onTermination = { termination in
            if case .cancelled = termination {
                let abortDescription = abortSignal.flatMap { signal in
                    signal.isAborted ? signal.reason : nil
                } ?? "Stream cancelled."
                Task {
                    if await terminalState.claimTerminalEvent() {
                        await dispatcher.record(telemetryEvent(
                            kind: .abort,
                            callID: callID,
                            operationID: operationID,
                            providerID: providerID,
                            modelID: modelID,
                            options: telemetry,
                            maxRetries: retryPolicy.maxRetries,
                            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                            errorDescription: abortDescription
                        ))
                    }
                }
            }
            task.cancel()
        }
    }
}

func publicLanguageStream(
    _ stream: AsyncThrowingStream<StreamTextTelemetryPart, Error>
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    guard case let .part(part) = event else { continue }
                    continuation.yield(part)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

func internalLanguageStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>
) -> AsyncThrowingStream<StreamTextTelemetryPart, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await part in stream {
                    try Task.checkCancellation()
                    continuation.yield(.part(part))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func isStreamRetryBufferedPart(_ part: LanguageStreamPart) -> Bool {
    switch part {
    case .toolInputStart, .toolInputStartText, .toolInputDelta, .toolInputEnd, .toolCallDelta,
         .toolCall, .toolResult, .toolApprovalRequest, .toolApprovalResponse:
        return true
    default:
        return false
    }
}

private func isStreamRetrySemanticOutput(_ part: LanguageStreamPart) -> Bool {
    switch part {
    case let .textDelta(delta), let .reasoningDelta(delta):
        return !delta.isEmpty
    case let .textDeltaPart(_, delta, _), let .reasoningDeltaPart(_, delta, _):
        return !delta.isEmpty
    case let .toolInputDelta(_, delta, _):
        return !delta.isEmpty
    case .file, .reasoningFile, .toolCall:
        return true
    default:
        return false
    }
}

private extension LanguageStreamPart {
    var isStreamRetryTerminalPart: Bool {
        switch self {
        case .finish, .finishMetadata, .error:
            return true
        default:
            return false
        }
    }
}


private func updateStreamRetryOpenParts(
    _ part: LanguageStreamPart,
    textIDs: inout Set<String>,
    reasoningIDs: inout Set<String>
) {
    switch part {
    case let .textStart(id, _):
        textIDs.insert(id)
    case let .textEnd(id, _), let .textEndWithCitations(id, _, _):
        textIDs.remove(id)
    case let .reasoningStart(id, _):
        reasoningIDs.insert(id)
    case let .reasoningEnd(id, _):
        reasoningIDs.remove(id)
    default:
        break
    }
}