import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension AI {
    /// Starts native streaming transcription. Telemetry counts audio only as the model consumes it.
    public static func streamTranscribe(model: any StreamingTranscriptionModel, request: StreamingTranscriptionRequest,
                                        telemetry: Telemetry.Options? = nil) async throws -> StreamingTranscriptionResult {
        let dispatcher = TelemetryDispatcher(options: telemetry)
        guard dispatcher.isEnabled else { return try await model.stream(request) }
        let callID = UUID().uuidString
        let started = DispatchTime.now().uptimeNanoseconds
        let counter = AIStreamingAudioByteCounter()
        let pump = AIStreamingTranscriptionPump()
        let terminal = AIStreamTerminalState()
        var observed = request
        observed.audio = request.audio.observingChunks { counter.add($0.count) }
        let input: JSONValue = .object([
            "mediaType": .string(request.inputAudioFormat.mediaType),
            "sampleRate": request.inputAudioFormat.sampleRate.map { .number(Double($0)) },
            "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
            "headers": headersTelemetryJSON(request.headers)
        ])
        await dispatcher.record(telemetryEvent(kind: .start, callID: callID, operationID: "ai.streamTranscribe", providerID: model.providerID,
                                               modelID: model.modelID, options: telemetry, input: input))
        let result: StreamingTranscriptionResult
        do { result = try await model.stream(observed) }
        catch {
            await dispatcher.record(telemetryEvent(kind: isCancellationTelemetryError(error) ? .abort : .error, callID: callID,
                                                   operationID: "ai.streamTranscribe", providerID: model.providerID, modelID: model.modelID,
                                                   options: telemetry, durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                                                   errorDescription: String(describing: error)))
            throw error
        }
        let stream = AsyncThrowingStream<StreamingTranscriptionPart, Error> { continuation in
            let task = Task {
                var warnings: [AIWarning] = []
                var responseMetadata = result.responseMetadata
                do {
                    for try await part in result.stream {
                        try Task.checkCancellation()
                        switch part {
                        case let .streamStart(value): warnings = value
                        case let .responseMetadata(value): responseMetadata = value
                        case let .finish(finish):
                            if await terminal.claimTerminalEvent() {
                                var event = telemetryEvent(kind: .end, callID: callID, operationID: "ai.streamTranscribe", providerID: model.providerID,
                                                           modelID: model.modelID, options: telemetry,
                                                           durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                                                           output: .object(["text": .string(finish.text), "byteLength": .number(Double(counter.value)),
                                                                            "segmentCount": .number(Double(finish.segments.count)),
                                                                            "language": finish.language.map(JSONValue.string),
                                                                            "durationInSeconds": finish.durationInSeconds.map(JSONValue.number)]),
                                                           warnings: warnings, providerMetadata: finish.providerMetadata, responseMetadata: responseMetadata)
                                event.providerUsage = finish.usage
                                await dispatcher.record(event)
                            }
                        case let .error(message, _):
                            if await terminal.claimTerminalEvent() {
                                await dispatcher.record(telemetryEvent(kind: .error, callID: callID, operationID: "ai.streamTranscribe", providerID: model.providerID,
                                                                       modelID: model.modelID, options: telemetry,
                                                                       durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started, errorDescription: message))
                            }
                        default: break
                        }
                        continuation.yield(part)
                    }
                    continuation.finish()
                } catch {
                    if await terminal.claimTerminalEvent() {
                        await dispatcher.record(telemetryEvent(kind: isCancellationTelemetryError(error) ? .abort : .error, callID: callID,
                                                               operationID: "ai.streamTranscribe", providerID: model.providerID, modelID: model.modelID,
                                                               options: telemetry, durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                                                               errorDescription: String(describing: error)))
                    }
                    continuation.finish(throwing: error)
                }
            }
            pump.set(task)
            continuation.onTermination = { termination in
                task.cancel()
                if case .cancelled = termination {
                    result.cancel()
                    Task {
                        if await terminal.claimTerminalEvent() {
                            await dispatcher.record(telemetryEvent(kind: .abort, callID: callID, operationID: "ai.streamTranscribe", providerID: model.providerID,
                                                                   modelID: model.modelID, options: telemetry,
                                                                   durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started))
                        }
                    }
                }
            }
        }
        return StreamingTranscriptionResult(stream: stream, requestMetadata: result.requestMetadata, responseMetadata: result.responseMetadata,
                                            cancel: {
            result.cancel()
            pump.cancel()
            Task {
                if await terminal.claimTerminalEvent() {
                    await dispatcher.record(telemetryEvent(kind: .abort, callID: callID, operationID: "ai.streamTranscribe", providerID: model.providerID,
                                                           modelID: model.modelID, options: telemetry, durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started))
                }
            }
        })
    }
}


private final class AIStreamingTranscriptionPump: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func set(_ task: Task<Void, Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel(); task = nil } }
}

private final class AIStreamingAudioByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ bytes: Int) { lock.withLock { count += bytes } }
    var value: Int { lock.withLock { count } }
}