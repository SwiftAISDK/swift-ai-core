import Foundation
import SwiftAIProvider

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AIDuplexWebSocketMessage: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

public enum AIDuplexWebSocketEvent: Equatable, Sendable {
    case opened(protocol: String?)
    case message(AIDuplexWebSocketMessage)
    case closed(AIDuplexWebSocketCloseMetadata)
}

public struct AIDuplexWebSocketRequest: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var protocols: [String]
    public var abortSignal: AIAbortSignal?

    public init(
        url: URL,
        headers: [String: String] = [:],
        protocols: [String] = [],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.url = url
        self.headers = headers
        self.protocols = protocols
        self.abortSignal = abortSignal
    }
}

public protocol AIDuplexWebSocketConnection: Sendable {
    var events: AsyncThrowingStream<AIDuplexWebSocketEvent, Error> { get }

    func send(_ message: AIDuplexWebSocketMessage) async throws
    func close(code: Int, reason: Data?) async
}

public extension AIDuplexWebSocketConnection {
    func send(text: String) async throws {
        try await send(.text(text))
    }

    func send(binary: Data) async throws {
        try await send(.binary(binary))
    }

    func close() async {
        await close(
            code: AIDuplexWebSocketCloseMetadata.normalClosure.code,
            reason: nil
        )
    }

    func close(code: Int) async {
        await close(code: code, reason: nil)
    }
}


public protocol AIDuplexWebSocketTransport: Sendable {
    func connect(
        _ request: AIDuplexWebSocketRequest
    ) async throws -> any AIDuplexWebSocketConnection
}

/// A URLSession-backed duplex WebSocket transport.
///
/// A connection is returned as soon as its task is resumed. Consumers should
/// wait for the first ``AIDuplexWebSocketEvent/opened(protocol:)`` event before
/// sending application data.
public final class URLSessionDuplexWebSocketTransport:
    AIDuplexWebSocketTransport,
    @unchecked Sendable {
    public static let shared = URLSessionDuplexWebSocketTransport()

    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration.copy() as? URLSessionConfiguration
            ?? configuration
    }

    public func connect(
        _ request: AIDuplexWebSocketRequest
    ) async throws -> any AIDuplexWebSocketConnection {
        try request.abortSignal?.throwIfAborted()
        return URLSessionDuplexWebSocketConnection(
            request: request,
            configuration: configuration.copy() as? URLSessionConfiguration
                ?? configuration
        )
    }
}

private final class URLSessionDuplexWebSocketConnection:
    NSObject,
    AIDuplexWebSocketConnection,
    URLSessionWebSocketDelegate,
    @unchecked Sendable {
    let events: AsyncThrowingStream<AIDuplexWebSocketEvent, Error>

    private let lock = NSLock()
    private let continuation:
        AsyncThrowingStream<AIDuplexWebSocketEvent, Error>.Continuation
    private let abortSignal: AIAbortSignal?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var abortRegistration: AIAbortHandlerRegistration?
    private var terminal = false
    private var receiveStarted = false

    init(
        request: AIDuplexWebSocketRequest,
        configuration: URLSessionConfiguration
    ) {
        let pair = AsyncThrowingStream<AIDuplexWebSocketEvent, Error>
            .makeStream()
        events = pair.stream
        continuation = pair.continuation
        abortSignal = request.abortSignal
        super.init()

        let urlRequest = urlSessionWebSocketURLRequest(from: request)

        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        self.session = session
        let task = session.webSocketTask(with: urlRequest)
        self.task = task

        abortRegistration = request.abortSignal?.addAbortHandler {
            [weak self, weak signal = request.abortSignal] reason in
            self?.fail(AIAbortError(
                reason: reason,
                reasonName: signal?.reasonName
            ))
        }
        continuation.onTermination = { [weak self] _ in
            self?.stopAfterConsumerTermination()
        }
        task.resume()
    }

    func send(_ message: AIDuplexWebSocketMessage) async throws {
        try abortSignal?.throwIfAborted()
        let task = try activeTask()
        let urlSessionMessage: URLSessionWebSocketTask.Message
        switch message {
        case let .text(text):
            urlSessionMessage = .string(text)
        case let .binary(data):
            urlSessionMessage = .data(data)
        }
        try await task.send(urlSessionMessage)
    }

    func close(code: Int, reason: Data?) async {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code)
            ?? .normalClosure
        finish(
            closeMetadata: AIDuplexWebSocketCloseMetadata(
                code: closeCode.rawValue,
                reason: reason.flatMap { String(data: $0, encoding: .utf8) }
            ),
            cancelCode: closeCode,
            cancelReason: reason
        )
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        guard !terminal else {
            lock.unlock()
            return
        }
        let shouldStartReceive = !receiveStarted
        receiveStarted = true
        lock.unlock()

        continuation.yield(.opened(protocol: `protocol`))
        if shouldStartReceive {
            startReceiveLoop()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(
            closeMetadata: AIDuplexWebSocketCloseMetadata(
                code: closeCode.rawValue,
                reason: reason.flatMap { String(data: $0, encoding: .utf8) }
            ),
            cancelCode: nil,
            cancelReason: nil
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !isTerminal else { return }
        if let abortSignal, abortSignal.isAborted {
            fail(AIAbortError(
                reason: abortSignal.reason,
                reasonName: abortSignal.reasonName
            ))
            return
        }
        if let error {
            fail(error)
            return
        }
        if let webSocketTask = task as? URLSessionWebSocketTask,
           webSocketTask.closeCode != .invalid {
            finish(
                closeMetadata: AIDuplexWebSocketCloseMetadata(
                    code: webSocketTask.closeCode.rawValue,
                    reason: webSocketTask.closeReason.flatMap {
                        String(data: $0, encoding: .utf8)
                    }
                ),
                cancelCode: nil,
                cancelReason: nil
            )
        } else {
            finish(
                closeMetadata: .normalClosure,
                cancelCode: nil,
                cancelReason: nil
            )
        }
    }

    private func startReceiveLoop() {
        let receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveMessages()
        }

        lock.lock()
        if terminal {
            lock.unlock()
            receiveTask.cancel()
            return
        }
        self.receiveTask = receiveTask
        lock.unlock()
    }

    private func receiveMessages() async {
        do {
            while !Task.isCancelled {
                let task = try activeTask()
                let message = try await task.receive()
                let eventMessage: AIDuplexWebSocketMessage
                switch message {
                case let .string(text):
                    eventMessage = .text(text)
                case let .data(data):
                    eventMessage = .binary(data)
                @unknown default:
                    continue
                }
                continuation.yield(.message(eventMessage))
            }
        } catch {
            if isTerminal {
                return
            }
            if let abortSignal, abortSignal.isAborted {
                fail(AIAbortError(
                    reason: abortSignal.reason,
                    reasonName: abortSignal.reasonName
                ))
                return
            }

            let task = currentTask
            if let task, task.closeCode != .invalid {
                finish(
                    closeMetadata: AIDuplexWebSocketCloseMetadata(
                        code: task.closeCode.rawValue,
                        reason: task.closeReason.flatMap {
                            String(data: $0, encoding: .utf8)
                        }
                    ),
                    cancelCode: nil,
                    cancelReason: nil
                )
            } else if error is CancellationError {
                finish(
                    closeMetadata: .normalClosure,
                    cancelCode: nil,
                    cancelReason: nil
                )
            } else {
                fail(error)
            }
        }
    }

    private func activeTask() throws -> URLSessionWebSocketTask {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, let task else {
            throw CancellationError()
        }
        return task
    }

    private var currentTask: URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    private var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }

    private func finish(
        closeMetadata: AIDuplexWebSocketCloseMetadata,
        cancelCode: URLSessionWebSocketTask.CloseCode?,
        cancelReason: Data?
    ) {
        let resources = takeResources()
        guard resources.didFinish else { return }

        continuation.yield(.closed(closeMetadata))
        continuation.finish()
        resources.registration?.cancel()
        resources.receiveTask?.cancel()
        if let cancelCode {
            resources.task?.cancel(with: cancelCode, reason: cancelReason)
        }
        resources.session?.finishTasksAndInvalidate()
    }

    private func fail(_ error: Error) {
        let resources = takeResources()
        guard resources.didFinish else { return }

        continuation.finish(throwing: error)
        resources.registration?.cancel()
        resources.receiveTask?.cancel()
        resources.task?.cancel(with: .normalClosure, reason: nil)
        resources.session?.invalidateAndCancel()
    }

    private func stopAfterConsumerTermination() {
        let resources = takeResources()
        guard resources.didFinish else { return }
        resources.registration?.cancel()
        resources.receiveTask?.cancel()
        resources.task?.cancel(with: .normalClosure, reason: nil)
        resources.session?.invalidateAndCancel()
    }

    private func takeResources() -> (
        didFinish: Bool,
        registration: AIAbortHandlerRegistration?,
        receiveTask: Task<Void, Never>?,
        task: URLSessionWebSocketTask?,
        session: URLSession?
    ) {
        lock.lock()
        guard !terminal else {
            lock.unlock()
            return (false, nil, nil, nil, nil)
        }
        terminal = true
        let resources = (
            true,
            abortRegistration,
            receiveTask,
            task,
            session
        )
        abortRegistration = nil
        receiveTask = nil
        task = nil
        session = nil
        lock.unlock()
        return resources
    }
}

func urlSessionWebSocketURLRequest(
    from request: AIDuplexWebSocketRequest
) -> URLRequest {
    var urlRequest = URLRequest(url: request.url)
    for (name, value) in request.headers {
        urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    if !request.protocols.isEmpty,
       urlRequest.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == nil {
        urlRequest.setValue(
            request.protocols.joined(separator: ", "),
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )
    }
    return urlRequest
}