import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension AI {
    public static func streamObject<Object: Decodable & Sendable>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        as type: Object.Type = Object.self,
        schema: JSONValue? = nil,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<Object>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<ObjectStreamPart<Object>, Error> {
        let objectRequest = objectRequest(
            from: request,
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            jsonInstruction: jsonInstruction
        )
        let streamRequest = objectRequest

        if let timeoutNanoseconds, timeoutNanoseconds <= 0 {
            return objectStreamWithTelemetry(
                makeStream: {
                    failingPartStream(AIError.invalidArgument(
                        argument: "timeoutNanoseconds",
                        message: "timeoutNanoseconds must be greater than zero."
                    ))
                },
                operationID: "ai.streamObject",
                providerID: model.providerID,
                modelID: model.modelID,
                request: streamRequest,
                input: objectGenerationTelemetryInput(
                    streamRequest,
                    outputKind: "object",
                    schema: schema,
                    schemaName: schemaName,
                    schemaDescription: schemaDescription
                ),
                retryPolicy: retryPolicy,
                telemetry: telemetry,
                callbacks: callbacks
            )
        }

        let makeStream: @Sendable () -> AsyncThrowingStream<ObjectStreamPart<Object>, Error> = {
            AsyncThrowingStream<ObjectStreamPart<Object>, Error> { continuation in
            let task = Task {
                var text = ""
                var reasoning = ""
                var finishReason: String?
                var usage: TokenUsage?
                var warnings: [AIWarning] = []
                var sources: [AISource] = []
                var providerMetadata: [String: JSONValue] = [:]
                var responseMetadata = AIResponseMetadata()
                var rawValues: [JSONValue] = []
                var lastPartialObject: JSONValue?
                var pendingTextDelta = ""

                func flushPendingTextDelta() {
                    guard !pendingTextDelta.isEmpty else { return }
                    continuation.yield(.textDelta(pendingTextDelta))
                    pendingTextDelta = ""
                }

                func consumeTextDelta(_ delta: String) {
                    text += delta
                    pendingTextDelta += delta
                    if shouldEmitObjectTextDelta(accumulatedText: text) {
                        flushPendingTextDelta()
                    }
                    if let partial = partialObject(from: text), partial != lastPartialObject {
                        lastPartialObject = partial
                        continuation.yield(.partialObject(partial))
                        if let typedPartial = typedPartialObject(Object.self, from: partial) {
                            continuation.yield(.partial(typedPartial))
                        }
                    }
                }

                do {
                    for try await part in streamText(model: model, request: streamRequest, retryPolicy: .none, logWarnings: false) {
                        try Task.checkCancellation()
                        switch part {
                        case let .streamStart(partWarnings):
                            warnings.append(contentsOf: partWarnings)
                            for warning in partWarnings {
                                continuation.yield(.warning(warning))
                            }
                        case let .textDelta(delta):
                            consumeTextDelta(delta)
                        case let .textDeltaPart(_, delta, _):
                            consumeTextDelta(delta)
                        case let .reasoningDelta(delta):
                            flushPendingTextDelta()
                            reasoning += delta
                            continuation.yield(.raw(part))
                        case let .reasoningDeltaPart(_, delta, _):
                            flushPendingTextDelta()
                            reasoning += delta
                            continuation.yield(.raw(part))
                        case let .source(source):
                            flushPendingTextDelta()
                            sources.append(source)
                            continuation.yield(.source(source))
                        case let .metadata(metadata):
                            flushPendingTextDelta()
                            continuation.yield(.metadata(metadata))
                        case let .responseMetadata(metadata):
                            flushPendingTextDelta()
                            responseMetadata = metadata
                            continuation.yield(.responseMetadata(metadata))
                        case let .raw(raw):
                            flushPendingTextDelta()
                            rawValues.append(raw)
                            continuation.yield(.raw(part))
                        case let .error(message, _):
                            flushPendingTextDelta()
                            continuation.yield(.raw(part))
                            throw AIError.invalidResponse(
                                provider: model.providerID,
                                message: message
                            )
                        case let .finish(reason, partUsage):
                            flushPendingTextDelta()
                            finishReason = reason
                            usage = partUsage
                        case let .finishMetadata(reason, partUsage, metadata):
                            flushPendingTextDelta()
                            finishReason = reason
                            usage = partUsage
                            providerMetadata.merge(metadata) { _, new in new }
                        default:
                            flushPendingTextDelta()
                            continuation.yield(.raw(part))
                        }
                    }

                    flushPendingTextDelta()
                    let parsed: (object: Object, rawObject: JSONValue, text: String)
                    do {
                        parsed = try await parseObject(
                            Object.self,
                            from: text,
                            schema: schema,
                            repairText: repairText,
                            providerID: model.providerID
                        )
                    } catch {
                        throw objectGenerationErrorWithResultMetadata(
                            error,
                            finishReason: finishReason,
                            usage: usage,
                            warnings: warnings,
                            providerMetadata: providerMetadata,
                            responseMetadata: responseMetadata
                        )
                    }
                    let textResult = TextGenerationResult(
                        text: parsed.text,
                        reasoning: reasoning,
                        finishReason: finishReason,
                        usage: usage,
                        sources: sources,
                        providerMetadata: providerMetadata,
                        rawValue: rawValues.isEmpty ? parsed.rawObject : .array(rawValues),
                        warnings: warnings,
                        requestMetadata: AIRequestMetadata(body: languageRequestMetadataBody(streamRequest), headers: streamRequest.headers),
                        responseMetadata: responseMetadata
                    )
                    let objectResult = ObjectGenerationResult(
                        object: parsed.object,
                        text: parsed.text,
                        rawObject: parsed.rawObject,
                        reasoning: reasoning,
                        finishReason: finishReason,
                        usage: usage,
                        warnings: warnings,
                        providerMetadata: providerMetadata,
                        responseMetadata: responseMetadata,
                        textResult: textResult
                    )
                    continuation.yield(.object(objectResult))
                    continuation.yield(.finish(reason: finishReason, usage: usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        }
        return objectStreamWithTelemetry(
            makeStream: {
                streamWithTimeout(
                    streamWithAbortSignal(makeStream(), abortSignal: streamRequest.abortSignal),
                    timeoutNanoseconds: timeoutNanoseconds ?? retryPolicy.timeoutNanoseconds
                )
            },
            operationID: "ai.streamObject",
            providerID: model.providerID,
            modelID: model.modelID,
            request: streamRequest,
            input: objectGenerationTelemetryInput(
                streamRequest,
                outputKind: "object",
                schema: schema,
                schemaName: schemaName,
                schemaDescription: schemaDescription
            ),
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks
        )
    }
}


private func shouldEmitObjectTextDelta(accumulatedText: String) -> Bool {
    !objectTextEndsAtStructuralColon(accumulatedText)
}

private func objectTextEndsAtStructuralColon(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.last == ":" else { return false }

    var inString = false
    var isEscaped = false
    for character in trimmed {
        if isEscaped {
            isEscaped = false
            continue
        }
        if inString, character == "\\" {
            isEscaped = true
            continue
        }
        if character == "\"" {
            inString.toggle()
        }
    }
    return !inString
}