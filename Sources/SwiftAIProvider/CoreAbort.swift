import Foundation


public enum AIResponseFormat: Equatable, Hashable, Sendable {
    case text
    case json(schema: JSONValue? = nil, name: String? = nil, description: String? = nil)
}

public struct AIAbortError: Error, Equatable, Sendable, CustomStringConvertible {
    public var reason: String?
    public var reasonName: String?

    public init(reason: String? = nil, reasonName: String? = nil) {
        self.reason = reason
        self.reasonName = reasonName
    }

    public var description: String {
        if let reason, !reason.isEmpty {
            return "Operation aborted: \(reason)"
        }
        return "Operation aborted."
    }
}

public final class AIAbortController: @unchecked Sendable {
    public let signal: AIAbortSignal

    public init() {
        self.signal = AIAbortSignal()
    }

    public func abort(reason: String? = nil, reasonName: String? = nil) {
        signal.abort(reason: reason, reasonName: reasonName)
    }
}

public final class AIAbortSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var aborted = false
    private var abortReason: String?
    private var abortReasonName: String?
    private var handlers: [UUID: @Sendable (String?) -> Void] = [:]
    private var continuations: [UUID: CheckedContinuation<String?, Never>] = [:]

    public var isAborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return aborted
    }

    public var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return abortReason
    }

    public var reasonName: String? {
        lock.lock()
        defer { lock.unlock() }
        return abortReasonName
    }

    public func throwIfAborted() throws {
        if isAborted {
            throw AIAbortError(reason: reason, reasonName: reasonName)
        }
    }

    @discardableResult
    public func addAbortHandler(_ handler: @escaping @Sendable (String?) -> Void) -> AIAbortHandlerRegistration {
        lock.lock()
        if aborted {
            let reason = abortReason
            lock.unlock()
            handler(reason)
            return AIAbortHandlerRegistration {}
        }
        let id = UUID()
        handlers[id] = handler
        lock.unlock()

        return AIAbortHandlerRegistration { [weak self] in
            self?.removeHandler(id)
        }
    }

    public func waitUntilAborted() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if aborted {
                let reason = abortReason
                lock.unlock()
                continuation.resume(returning: reason)
                return
            }
            let id = UUID()
            continuations[id] = continuation
            lock.unlock()
        }
    }

    fileprivate func abort(reason: String?, reasonName: String?) {
        lock.lock()
        guard !aborted else {
            lock.unlock()
            return
        }
        aborted = true
        abortReason = reason
        abortReasonName = reasonName
        let handlers = Array(handlers.values)
        self.handlers.removeAll()
        let continuations = Array(continuations.values)
        self.continuations.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume(returning: reason)
        }
        for handler in handlers {
            handler(reason)
        }
    }

    private func removeHandler(_ id: UUID) {
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }
}

public final class AIAbortHandlerRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    fileprivate init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        let onCancel = self.onCancel
        self.onCancel = nil
        lock.unlock()
        onCancel?()
    }

    deinit {
        cancel()
    }
}

public enum AIAbortSource: Sendable {
    case signal(AIAbortSignal)
    case timeoutMilliseconds(Int)
}

@discardableResult
public func mergeAbortSignals(_ signals: AIAbortSignal?...) -> AIAbortSignal? {
    mergeAbortSignals(signals)
}

@discardableResult
public func mergeAbortSignals(_ signals: [AIAbortSignal?]) -> AIAbortSignal? {
    mergeNormalizedAbortSignals(signals.compactMap { $0 })
}

@discardableResult
public func mergeAbortSignals(sources: AIAbortSource?...) -> AIAbortSignal? {
    mergeAbortSignals(sources: sources)
}

@discardableResult
public func mergeAbortSignals(sources: [AIAbortSource?]) -> AIAbortSignal? {
    let signals = sources.compactMap { source -> AIAbortSignal? in
        guard let source else { return nil }
        switch source {
        case let .signal(signal):
            return signal
        case let .timeoutMilliseconds(timeoutMilliseconds):
            let controller = AIAbortController()
            setAbortTimeout(
                abortController: controller,
                label: "AbortSignal",
                timeoutMilliseconds: timeoutMilliseconds
            )
            return controller.signal
        }
    }
    return mergeNormalizedAbortSignals(signals)
}

public func delay(_ delayInMilliseconds: Int? = nil, abortSignal: AIAbortSignal? = nil) async throws {
    guard let delayInMilliseconds else {
        return
    }
    let milliseconds = UInt64(max(0, delayInMilliseconds))
    let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
    try await sleepWithAbortSignal(
        nanoseconds: overflow ? UInt64.max : nanoseconds,
        abortSignal: abortSignal
    )
}

@discardableResult
public func setAbortTimeout(
    abortController: AIAbortController?,
    label: String,
    timeoutMilliseconds: Int?
) -> Task<Void, Never>? {
    guard let abortController,
          let timeoutMilliseconds else {
        return nil
    }
    let milliseconds = UInt64(max(0, timeoutMilliseconds))
    let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
    return Task {
        do {
            try await Task.sleep(nanoseconds: overflow ? UInt64.max : nanoseconds)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        abortController.abort(
            reason: "\(label) timeout of \(timeoutMilliseconds)ms exceeded",
            reasonName: "TimeoutError"
        )
    }
}

private final class AIMergedAbortSignalsState: @unchecked Sendable {
    private let lock = NSLock()
    private let controller: AIAbortController
    private var registrations: [AIAbortHandlerRegistration] = []
    private var completed = false

    init(controller: AIAbortController) {
        self.controller = controller
    }

    func addRegistration(_ registration: AIAbortHandlerRegistration) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            registration.cancel()
            return
        }
        registrations.append(registration)
        lock.unlock()
    }

    func abort(reason: String?, reasonName: String?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let registrations = self.registrations
        self.registrations.removeAll()
        lock.unlock()

        controller.abort(reason: reason, reasonName: reasonName)
        for registration in registrations {
            registration.cancel()
        }
    }
}

private func mergeNormalizedAbortSignals(_ signals: [AIAbortSignal]) -> AIAbortSignal? {
    guard !signals.isEmpty else { return nil }
    guard signals.count > 1 else { return signals[0] }

    let controller = AIAbortController()
    let state = AIMergedAbortSignalsState(controller: controller)

    if let signal = signals.first(where: { $0.isAborted }) {
        controller.abort(reason: signal.reason, reasonName: signal.reasonName)
        return controller.signal
    }

    for signal in signals {
        let registration = signal.addAbortHandler { reason in
            state.abort(reason: reason, reasonName: signal.reasonName)
        }
        state.addRegistration(registration)
    }

    return controller.signal
}

private final class AIAbortableSleepState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var registration: AIAbortHandlerRegistration?
    private var task: Task<Void, Never>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func setRegistration(_ registration: AIAbortHandlerRegistration) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            registration.cancel()
            return
        }
        self.registration = registration
        lock.unlock()
    }

    func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func resume() {
        complete(.success(()))
    }

    func resume(throwing error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let registration = self.registration
        self.registration = nil
        let task = self.task
        self.task = nil
        lock.unlock()

        registration?.cancel()
        task?.cancel()
        continuation.resume(with: result)
    }
}

public func sleepWithAbortSignal(nanoseconds: UInt64, abortSignal: AIAbortSignal?) async throws {
    guard let abortSignal else {
        try await Task.sleep(nanoseconds: nanoseconds)
        return
    }
    try abortSignal.throwIfAborted()
    try await withCheckedThrowingContinuation { continuation in
        let state = AIAbortableSleepState(continuation: continuation)
        let registration = abortSignal.addAbortHandler { reason in
            state.resume(throwing: AIAbortError(reason: reason))
        }
        state.setRegistration(registration)
        let task = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                state.resume()
            } catch {
                state.resume(throwing: error)
            }
        }
        state.setTask(task)
    }
}