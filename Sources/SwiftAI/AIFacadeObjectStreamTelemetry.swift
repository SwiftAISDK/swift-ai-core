import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func objectStreamWithTelemetry<Object: Sendable>(
    makeStream: @escaping @Sendable () async throws -> AsyncThrowingStream<ObjectStreamPart<Object>, Error>,
    operationID: String,
    providerID: String,
    modelID: String?,
    request: LanguageModelRequest? = nil,
    input: JSONValue?,
    retryPolicy: AIRetryPolicy,
    telemetry: Telemetry.Options?,
    callbacks: AIObjectGenerationCallbacks<Object>? = nil
) -> AsyncThrowingStream<ObjectStreamPart<Object>, Error> {
    let dispatcher = TelemetryDispatcher(options: telemetry)
    let callID = UUID().uuidString
    let started = DispatchTime.now().uptimeNanoseconds
    let terminalState = AIStreamTerminalState()

    return AsyncThrowingStream { continuation in
        let task = Task {
            await AIDeprecationLogging.objectWarning("streamObject")
            var text = ""
            var partialCount = 0
            var objectResult: ObjectGenerationResult<Object>?
            var finishReason: String?
            var usage: TokenUsage?
            var warnings: [AIWarning] = []
            var providerMetadata: [String: JSONValue] = [:]
            var responseMetadata = AIResponseMetadata()
            do {
                let startInput = input?.objectValue
                await callbacks?.onStart?(AIObjectGenerationStartEvent(
                    callID: callID,
                    operationID: operationID,
                    providerID: providerID,
                    modelID: modelID,
                    outputKind: startInput?["output"]?.stringValue ?? "object",
                    request: request ?? LanguageModelRequest(messages: []),
                    schema: startInput?["schema"],
                    schemaName: startInput?["schemaName"]?.stringValue,
                    schemaDescription: startInput?["schemaDescription"]?.stringValue,
                    maxRetries: retryPolicy.maxRetries
                ))
                await callbacks?.onStepStart?(AIObjectGenerationStepStartEvent(
                    callID: callID,
                    stepNumber: 0,
                    providerID: providerID,
                    modelID: modelID,
                    request: request ?? LanguageModelRequest(messages: [])
                ))
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

                var errors: [String] = []
                var delay = retryPolicy.initialDelayNanoseconds
                while true {
                    var yieldedPart = false
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
                            yieldedPart = true
                            switch part {
                            case let .textDelta(delta):
                                text += delta
                            case .partialObject:
                                partialCount += 1
                            case let .object(result):
                                objectResult = result
                                warnings = result.warnings
                                providerMetadata = result.providerMetadata
                                responseMetadata = result.responseMetadata
                            case let .warning(warning):
                                warnings.append(warning)
                            case let .metadata(metadata):
                                providerMetadata.merge(metadata) { _, new in new }
                            case let .responseMetadata(metadata):
                                responseMetadata = metadata
                            case .raw(.error):
                                finishReason = "error"
                            case let .finish(reason, partUsage):
                                finishReason = reason
                                usage = partUsage
                            default:
                                break
                            }
                            continuation.yield(part)
                        }
                        let output = objectStreamTelemetryOutput(
                            text: objectResult?.text ?? text,
                            rawObject: objectResult?.rawObject,
                            partialCount: partialCount,
                            finishReason: objectResult?.finishReason ?? finishReason
                        )
                        if await terminalState.claimTerminalEvent() {
                            await callbacks?.onStepFinish?(AIObjectGenerationStepFinishEvent(
                                callID: callID,
                                stepNumber: 0,
                                providerID: providerID,
                                modelID: modelID,
                                text: objectResult?.text ?? text,
                                reasoning: objectResult?.reasoning ?? "",
                                finishReason: objectResult?.finishReason ?? finishReason,
                                usage: objectResult?.usage ?? usage,
                                warnings: warnings,
                                providerMetadata: providerMetadata,
                                responseMetadata: responseMetadata
                            ))
                            if let objectResult {
                                await callbacks?.onFinish?(AIObjectGenerationFinishEvent(
                                    callID: callID,
                                    object: objectResult.object,
                                    text: objectResult.text,
                                    rawObject: objectResult.rawObject,
                                    reasoning: objectResult.reasoning,
                                    finishReason: objectResult.finishReason,
                                    usage: objectResult.usage,
                                    warnings: objectResult.warnings,
                                    providerMetadata: objectResult.providerMetadata,
                                    responseMetadata: objectResult.responseMetadata
                                ))
                            }
                            await dispatcher.record(telemetryEvent(
                                kind: .end,
                                callID: callID,
                                operationID: operationID,
                                providerID: providerID,
                                modelID: modelID,
                                options: telemetry,
                                maxRetries: retryPolicy.maxRetries,
                                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                                output: output,
                                usage: objectResult?.usage ?? usage,
                                warnings: warnings,
                                providerMetadata: providerMetadata,
                                responseMetadata: responseMetadata,
                                useResponseModelID: true
                            ))
                            await AIWarningLogging.logWarnings(warnings, providerID: providerID, modelID: modelID)
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        throw AIRetryError(reason: .cancelled, attempts: errors.count + 1, errors: errors)
                    } catch {
                        if yieldedPart {
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
                            try await sleep(nanoseconds: sleepDelay, abortSignal: request?.abortSignal)
                        }
                        delay = nextDelay(current: delay, policy: retryPolicy)
                    }
                }
            } catch {
                if isCancellationTelemetryError(error) {
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
                            errorDescription: String(describing: error)
                        ))
                    }
                    continuation.finish()
                } else {
                    if await terminalState.claimTerminalEvent() {
                        await callbacks?.onError?(AIObjectGenerationErrorEvent(
                            callID: callID,
                            providerID: providerID,
                            modelID: modelID,
                            text: objectResult?.text ?? text,
                            errorDescription: String(describing: error),
                            finishReason: objectResult?.finishReason ?? finishReason,
                            usage: objectResult?.usage ?? usage,
                            warnings: warnings,
                            providerMetadata: providerMetadata,
                            responseMetadata: responseMetadata
                        ))
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
                            errorDescription: "Stream cancelled."
                        ))
                    }
                }
            }
            task.cancel()
        }
    }
}