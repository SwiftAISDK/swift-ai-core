import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension AI {
    /// Experimental speech synthesis from complete or incremental text. The
    /// result has one stream owner; awaiting metadata first drains the stream.
    public static func experimentalStreamSpeech(model: any SpeechModel, request: StreamingSpeechRequest,
                                                onError: @escaping @Sendable (any Error) async throws -> Void = { error in FileHandle.standardError.write(Data("\(error)\n".utf8)) }) throws -> StreamingSpeechResult {
        guard let model = model as? any StreamingSpeechModel else {
            throw AIError.invalidArgument(argument: "model", message: "The \(model.providerID) model \(model.modelID) does not support streaming speech.")
        }
        return StreamingSpeechResult(engine: SpeechResultEngine(model: model, request: request, onError: onError))
    }
}


final class SpeechResultEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let rawPromise = AIDelayedPromise<StreamingSpeechModelResult>()
    private let summaryPromise = AIDelayedPromise<StreamingSpeechSummary>()
    private let controller = AIAbortController()
    private let providerID: String
    private let modelID: String
    private let input: AIStreamingTextInput
    private let onError: @Sendable (any Error) async throws -> Void
    private var owner = false
    private var complete = false
    private var reading = false
    private var iterator: AsyncThrowingStream<StreamingSpeechPart, Error>.Iterator?
    private var raw: StreamingSpeechModelResult?
    private var setup: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var pendingRead: AIDelayedPromise<StreamingSpeechPart?>?
    private var registration: AIAbortHandlerRegistration?
    private var response: AIResponseMetadata
    private var warnings: [AIWarning] = []
    private var hasAudio = false
    private var lastError: (any Error)?

    init(model: any StreamingSpeechModel, request: StreamingSpeechRequest, onError: @escaping @Sendable (any Error) async throws -> Void) {
        input = request.text; self.onError = onError
        providerID = model.providerID; modelID = model.modelID
        response = AIResponseMetadata(timestamp: Date(), modelID: model.modelID)
        registration = request.abortSignal?.addAbortHandler { [weak self, weak signal = request.abortSignal] reason in
            self?.fail(AIAbortError(reason: reason, reasonName: signal?.reasonName))
        }
        var observed = request
        observed.abortSignal = controller.signal
        observed.headers = withUserAgentSuffix(request.headers, "ai/7.0.153")
        let callRequest = observed
        setup = Task { [weak self] in
            guard let self else { return }
            do {
                try callRequest.abortSignal?.throwIfAborted()
                let result = try await model.stream(callRequest)
                let accepted = lock.withLock { () -> Bool in
                    guard !complete else { return false }
                    raw = result; iterator = result.stream.makeAsyncIterator()
                    response = result.responseMetadata
                    if response.modelID == nil { response.modelID = model.modelID }
                    if response.timestamp == nil { response.timestamp = Date() }
                    rawPromise.resolve(result)
                    return true
                }
                if !accepted { result.cancel() }
            } catch { fail(error) }
        }
    }

    func claimStream() throws {
        try lock.withLock {
            guard !owner else { throw AIError.invalidArgument(argument: "stream", message: "Speech audio, full parts, or result metadata can only claim one stream owner.") }
            owner = true
        }
    }

    func summary() async throws -> StreamingSpeechSummary {
        let drain = lock.withLock { () -> Bool in
            guard !owner else { return false }; owner = true; return true
        }
        if drain { Task { do { while try await self.next() != nil {} } catch {} } }
        return try await summaryPromise.value()
    }

    func next() async throws -> StreamingSpeechPart? {
        try await withTaskCancellationHandler {
            _ = try await rawPromise.value()
            while true {
                let nextIterator = try lock.withLock { () throws -> AsyncThrowingStream<StreamingSpeechPart, Error>.Iterator? in
                    if complete { return nil }
                    guard !reading else { throw AIError.invalidArgument(argument: "stream", message: "Concurrent speech iterator reads are unsupported.") }
                    reading = true
                    let value = iterator; iterator = nil; return value
                }
                guard let current = nextIterator else {
                    if summaryPromise.isRejected { _ = try await summaryPromise.value() }
                    return nil
                }
                let read = AIDelayedPromise<StreamingSpeechPart?>()
                let accepted = lock.withLock { () -> Bool in
                    guard !complete else { return false }; pendingRead = read; return true
                }
                guard accepted else { _ = try await summaryPromise.value(); return nil }
                let task = Task { [self] in
                    var current = current
                    do {
                        let value = try await current.next()
                        lock.withLock {
                            iterator = current; reading = false
                            if pendingRead === read { pendingRead = nil; read.resolve(value) }
                        }
                    } catch {
                        lock.withLock { reading = false }
                        fail(error)
                    }
                }
                let active = lock.withLock { () -> Bool in guard !complete else { return false }; readerTask = task; return true }
                if !active { task.cancel() }
                let part = try await read.value()
                if lock.withLock({ complete }) {
                    if summaryPromise.isRejected { _ = try await summaryPromise.value() }
                    return nil
                }
                guard let part else {
                    let error: any Error = lock.withLock {
                        hasAudio ? (lastError ?? AIStreamingSpeechError(provider: "speech", message: "The speech stream ended before it finished.")) : AINoSpeechGeneratedError(responses: [response], cause: lastError)
                    }
                    fail(error); throw error
                }
                switch part {
                case let .streamStart(value):
                    lock.withLock { warnings = value }
                    await AIWarningLogging.logWarnings(value, providerID: providerID, modelID: modelID)
                case let .responseMetadata(value):
                    lock.withLock {
                        response.timestamp = value.timestamp ?? response.timestamp
                        response.modelID = value.modelID ?? response.modelID
                        response.headers.merge(value.headers) { _, new in new }
                        response.body = value.body ?? response.body
                    }
                case let .audio(_, data, _, metadata):
                    if data.isEmpty && metadata.isEmpty { continue }
                    lock.withLock { hasAudio = hasAudio || !data.isEmpty }
                    return part
                case let .error(error):
                    lock.withLock { lastError = error }
                    Task { try? await onError(error) }
                    return part
                case .raw: return part
                case let .finish(usage, metadata):
                    let summary: StreamingSpeechSummary? = lock.withLock {
                        guard hasAudio else { return nil }
                        complete = true
                        iterator = nil; raw = nil; setup = nil; readerTask = nil
                        return StreamingSpeechSummary(usage: usage, warnings: warnings, responses: [response], providerMetadata: metadata)
                    }
                    guard let summary else {
                        let error = lock.withLock { AINoSpeechGeneratedError(responses: [response], cause: lastError) }
                        fail(error); throw error
                    }
                    registration?.cancel(); summaryPromise.resolve(summary)
                    return nil
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { fail(AIAbortError(reason: "Speech stream was cancelled.")) }
    func cancelIfIncomplete() { if !lock.withLock({ complete }) { cancel() } }

    private func fail(_ error: any Error) {
        let resources = lock.withLock { () -> (StreamingSpeechModelResult?, Task<Void, Never>?, Task<Void, Never>?, AIAbortHandlerRegistration?)? in
            guard !complete else { return nil }; complete = true
            pendingRead?.reject(error); pendingRead = nil
            if rawPromise.isPending { rawPromise.reject(error) }
            if summaryPromise.isPending { summaryPromise.reject(error) }
            let resources = (raw, setup, readerTask, registration)
            raw = nil; iterator = nil; setup = nil; readerTask = nil; registration = nil
            return resources
        }
        guard let resources else { return }
        controller.abort(reason: String(describing: error)); resources.3?.cancel()
        input.cancelFromConsumer(); resources.0?.cancel(); resources.1?.cancel(); resources.2?.cancel()
    }
}