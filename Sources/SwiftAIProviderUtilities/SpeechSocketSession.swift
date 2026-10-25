import Foundation
import SwiftAIProvider
import SwiftAITransport

/// Shared native socket lifecycle. Async sends apply transport backpressure;
/// every terminal path releases both input and connection.
public final class SpeechSocketSession: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: any AIDuplexWebSocketConnection
    private let input: AIStreamingTextInput
    private let abortSignal: AIAbortSignal?
    private let startFrame: JSONValue
    private let initialParts: [StreamingSpeechPart]
    private let decode: @Sendable (String) throws -> [StreamingSpeechPart]
    private let inputPump: @Sendable (SpeechSocketSession) async throws -> Void
    private let connectionError: @Sendable (any Error) -> any Error
    private let keepaliveFrame: JSONValue?
    private var continuation: AsyncThrowingStream<StreamingSpeechPart, Error>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var registration: AIAbortHandlerRegistration?
    private var completed = false
    private var inputEnded = false
    private var lastSend = Date()
    private var serverError: (any Error)?

    public init(connection: any AIDuplexWebSocketConnection, input: AIStreamingTextInput, abortSignal: AIAbortSignal?, startFrame: JSONValue,
         initialParts: [StreamingSpeechPart] = [], keepaliveFrame: JSONValue? = nil,
         decode: @escaping @Sendable (String) throws -> [StreamingSpeechPart],
         inputPump: @escaping @Sendable (SpeechSocketSession) async throws -> Void,
         connectionError: @escaping @Sendable (any Error) -> any Error = { $0 }) {
        self.connection = connection; self.input = input; self.abortSignal = abortSignal; self.startFrame = startFrame
        self.initialParts = initialParts; self.keepaliveFrame = keepaliveFrame; self.decode = decode
        self.inputPump = inputPump; self.connectionError = connectionError
    }

    public func makeStream() -> AsyncThrowingStream<StreamingSpeechPart, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.onTermination = { [weak self] termination in if case .cancelled = termination { self?.cancel() } }
            let registration = abortSignal?.addAbortHandler { [weak self, weak signal = abortSignal] reason in self?.finish(AIAbortError(reason: reason, reasonName: signal?.reasonName)) }
            let accepted = lock.withLock { () -> Bool in if completed { return false }; self.registration = registration; return true }
            if !accepted { registration?.cancel() }
            let task = Task { [self] in await consumeEvents() }; add(task)
        }
    }

    public func send(_ frame: JSONValue) async throws {
        try Task.checkCancellation(); try abortSignal?.throwIfAborted()
        guard lock.withLock({ !completed && serverError == nil }) else { throw CancellationError() }
        let text = String(decoding: try encodeJSONBody(frame), as: UTF8.self)
        try await connection.send(text: text)
        lock.withLock { lastSend = Date() }
    }

    public func cancel() { finish(AIAbortError(reason: "Speech stream was cancelled.")) }

    private func add(_ task: Task<Void, Never>) { let active = lock.withLock { () -> Bool in if completed { return false }; tasks.append(task); return true }; if !active { task.cancel() } }

    private func consumeEvents() async {
        do {
            for try await event in connection.events {
                if lock.withLock({ completed }) { return }
                switch event {
                case .opened:
                    for part in initialParts { lock.withLock { continuation }?.yield(part) }
                    try await send(startFrame)
                    let task = Task { [self] in
                        do { try await inputPump(self); lock.withLock { inputEnded = true } }
                        catch { if !lock.withLock({ completed || serverError != nil }) { finish(connectionError(error)) } }
                    }; add(task)
                    if let keepaliveFrame {
                        add(Task { [self] in
                            do {
                                while !Task.isCancelled {
                                    try await Task.sleep(nanoseconds: 1_000_000_000)
                                    let idle = lock.withLock { !completed && !inputEnded && Date().timeIntervalSince(lastSend) >= 15 }
                                    if idle { try await send(keepaliveFrame) }
                                }
                            } catch { if !lock.withLock({ completed || inputEnded }) { finish(error) } }
                        })
                    }
                case let .message(.text(text)):
                    for part in try decode(text) {
                        if case let .error(error) = part { lock.withLock { serverError = error }; input.cancelFromConsumer() }
                        lock.withLock { continuation }?.yield(part)
                        if case .finish = part { finish(nil); return }
                    }
                case .message(.binary): break
                case let .closed(metadata):
                    let error: any Error = lock.withLock {
                        if let serverError { return serverError }
                        return AIStreamingSpeechError(provider: "speech", message: "Speech stream closed before completion (code \(metadata.code)\(metadata.reason.map { ": " + $0 } ?? "")).")
                    }
                    finish(connectionError(error)); return
                }
            }
            if !lock.withLock({ completed }) {
                let failure: (any Error)? = lock.withLock { serverError }
                let error: any Error = failure ?? AIStreamingSpeechError(provider: "speech", message: "Speech stream ended before completion.")
                finish(error)
            }
        } catch { finish(connectionError(error)) }
    }

    private func finish(_ error: (any Error)?) {
        let resources = lock.withLock { () -> (AsyncThrowingStream<StreamingSpeechPart, Error>.Continuation?, [Task<Void, Never>], AIAbortHandlerRegistration?) in
            guard !completed else { return (nil, [], nil) }; completed = true
            let values = (continuation, tasks, registration); continuation = nil; tasks = []; registration = nil; return values
        }
        guard let continuation = resources.0 else { return }
        resources.2?.cancel(); for task in resources.1 { task.cancel() }; input.cancelFromConsumer()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        Task { await connection.close(code: 1000) }
    }
}