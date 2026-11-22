import Foundation
import SwiftAIProvider

public enum AISteeringNotDeliveredReason: String, Equatable, Sendable {
    case finished
    case removedByPrepareStep = "removed-by-prepare-step"
    case stopCondition = "stop-condition"
    case waitingForToolResults = "waiting-for-tool-results"
    case aborted
    case error
}

public enum AISteeringOutcome: Equatable, Sendable {
    case delivered(id: String, message: AIMessage, stepNumber: Int)
    case notDelivered(id: String, message: AIMessage, reason: AISteeringNotDeliveredReason)
}

/// A never-throwing delivery receipt. Repeated IDs return the same receipt.
public final class AISteeringReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var result: AISteeringOutcome?
    private var waiters: [CheckedContinuation<AISteeringOutcome, Never>] = []
    public var value: AISteeringOutcome {
        get async {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> AISteeringOutcome? in
                    if let result { return result }
                    waiters.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
    fileprivate func resolve(_ result: AISteeringOutcome) {
        let pending = lock.withLock { () -> [CheckedContinuation<AISteeringOutcome, Never>] in
            guard self.result == nil else { return [] }
            self.result = result
            defer { waiters.removeAll() }
            return waiters
        }
        for continuation in pending { continuation.resume(returning: result) }
    }
}

struct AISteeringDeliveredMessage: Sendable { var id: String; var message: AIMessage }

/// Adds user messages at model-step boundaries or interrupts a pre-output model call.
/// One object belongs to one run.
public final class AISteering: @unchecked Sendable {
    private struct Pending { var id: String; var message: AIMessage; var receipt: AISteeringReceipt }
    private struct InterruptWatcher {
        let id: UUID
        let notify: @Sendable () -> Void
    }
    private enum State { case idle, running, ended }
    private let lock = NSLock()
    private var state: State = .idle
    private var pending: [Pending] = []
    private var queued: [Pending] = []
    private var taken: [Pending] = []
    private var receipts: [String: AISteeringReceipt] = [:]
    private var interruptRequested = false
    private var interruptWatcher: InterruptWatcher?
    fileprivate init() {}

    public func steer(_ text: String, id: String? = nil) -> AISteeringReceipt {
        steer(text, id: id, interrupt: false)
    }
    /// Restarts the current model call in the same step when it has yet to produce output.
    /// After output starts, the message waits for the next step boundary.
    public func steer(_ text: String, id: String? = nil, interrupt: Bool) -> AISteeringReceipt {
        enqueue(.user(text), id: id, interrupt: interrupt)
    }
    public func steer(content: [AIContentPart], providerMetadata: [String: JSONValue] = [:], id: String? = nil) -> AISteeringReceipt {
        steer(content: content, providerMetadata: providerMetadata, id: id, interrupt: false)
    }
    /// The structured-content form of `steer(_:id:interrupt:)`.
    public func steer(content: [AIContentPart], providerMetadata: [String: JSONValue] = [:], id: String? = nil, interrupt: Bool) -> AISteeringReceipt {
        enqueue(AIMessage(role: .user, content: content, providerMetadata: providerMetadata), id: id, interrupt: interrupt)
    }
    public func queue(_ text: String, id: String? = nil) -> AISteeringReceipt {
        enqueue(.user(text), id: id, queued: true)
    }
    public func queue(content: [AIContentPart], providerMetadata: [String: JSONValue] = [:], id: String? = nil) -> AISteeringReceipt {
        enqueue(AIMessage(role: .user, content: content, providerMetadata: providerMetadata), id: id, queued: true)
    }
    private func enqueue(_ message: AIMessage, id: String?, queued: Bool = false, interrupt: Bool = false) -> AISteeringReceipt {
        var notify: (@Sendable () -> Void)?
        let receipt = lock.withLock {
            let id = id ?? "steer-\(UUID().uuidString)"
            if let existing = receipts[id] { return existing }
            let receipt = AISteeringReceipt()
            receipts[id] = receipt
            if state == .ended { receipt.resolve(.notDelivered(id: id, message: message, reason: .finished)) }
            else if queued { self.queued.append(Pending(id: id, message: message, receipt: receipt)) }
            else {
                pending.append(Pending(id: id, message: message, receipt: receipt))
                if interrupt {
                    notify = interruptWatcher?.notify
                    interruptWatcher = nil
                    interruptRequested = notify == nil
                }
            }
            return receipt
        }
        notify?()
        return receipt
    }
    func start() throws {
        try lock.withLock {
            guard state == .idle else { throw AIError.invalidArgument(argument: "experimentalSteering", message: "The steering object was already used by a generation. Create a new one with experimentalCreateSteering() for each call.") }
            state = .running
        }
    }
    var hasPendingMessages: Bool { lock.withLock { state == .running && !pending.isEmpty } }
    var hasUndeliveredMessages: Bool { lock.withLock { !pending.isEmpty || !queued.isEmpty || !taken.isEmpty } }
    func promoteQueuedMessage() -> Bool {
        lock.withLock {
            guard state == .running, !queued.isEmpty else { return false }
            pending.append(queued.removeFirst())
            return true
        }
    }
    func takeMessages() -> [AIMessage] {
        lock.withLock {
            guard state == .running else { return [] }
            taken.append(contentsOf: pending)
            pending.removeAll()
            interruptRequested = false
            return taken.map(\.message)
        }
    }
    func watchInterrupt(_ notify: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        let notifyImmediately = lock.withLock {
            guard state == .running else { return false }
            if interruptRequested {
                interruptRequested = false
                return true
            }
            interruptWatcher = InterruptWatcher(id: id, notify: notify)
            return false
        }
        if notifyImmediately { notify() }
        return { [weak self] in
            guard let self else { return }
            lock.withLock {
                if interruptWatcher?.id == id { interruptWatcher = nil }
            }
        }
    }
    func resolveTakenMessages(stepNumber: Int, sentMessages: [AIMessage]) -> [AISteeringDeliveredMessage] {
        let messages = lock.withLock { () -> [Pending] in defer { taken.removeAll() }; return taken }
        var delivered: [AISteeringDeliveredMessage] = []
        for item in messages {
            if sentMessages.contains(where: { $0.role == .user && $0.content == item.message.content }) {
                delivered.append(.init(id: item.id, message: item.message))
                item.receipt.resolve(.delivered(id: item.id, message: item.message, stepNumber: stepNumber))
            } else { item.receipt.resolve(.notDelivered(id: item.id, message: item.message, reason: .removedByPrepareStep)) }
        }
        return delivered
    }
    func end(_ reason: AISteeringNotDeliveredReason) {
        let messages = lock.withLock { () -> [Pending] in
            guard state == .running else { return [] }
            state = .ended
            interruptWatcher = nil
            interruptRequested = false
            defer { pending.removeAll(); taken.removeAll(); queued.removeAll() }
            return taken + pending + queued
        }
        for item in messages { item.receipt.resolve(.notDelivered(id: item.id, message: item.message, reason: reason)) }
    }
}

struct AISteeringInterruptedAttempt: Error {}

/// Holds the interrupt window and the provider-only signal for one model attempt.
final class AISteeringModelAttempt: @unchecked Sendable {
    private enum State { case waiting, interrupted, closed }

    private let lock = NSLock()
    private let steering: AISteering
    private let controller = AIAbortController()
    private let baseSignal: AIAbortSignal?
    private var baseAbortRegistration: AIAbortHandlerRegistration?
    private var stopWatching: (@Sendable () -> Void)?
    private var state: State = .waiting

    init(steering: AISteering, baseSignal: AIAbortSignal?) {
        self.steering = steering
        self.baseSignal = baseSignal
        baseAbortRegistration = baseSignal?.addAbortHandler { [weak controller, weak baseSignal] reason in
            controller?.abort(reason: reason, reasonName: baseSignal?.reasonName)
        }
    }

    var signal: AIAbortSignal { controller.signal }
    var isInterrupted: Bool { lock.withLock { state == .interrupted } }

    func cancel() {
        controller.abort(reason: "The model call was cancelled.")
    }

    func watch() {
        guard lock.withLock({ state == .waiting && stopWatching == nil }) else { return }
        let stop = steering.watchInterrupt { [weak self] in self?.interrupt() }
        lock.withLock { stopWatching = stop }
    }

    func closeWindow() {
        let stop = lock.withLock {
            if state == .waiting { state = .closed }
            defer { stopWatching = nil }
            return stopWatching
        }
        stop?()
    }

    func checkForInterrupt() throws {
        if isInterrupted { throw AISteeringInterruptedAttempt() }
    }

    func shouldRedo() throws -> Bool {
        closeWindow()
        guard isInterrupted else { return false }
        try Task.checkCancellation()
        try baseSignal?.throwIfAborted()
        return true
    }

    private func interrupt() {
        let shouldAbort = lock.withLock {
            guard state == .waiting else { return false }
            state = .interrupted
            return true
        }
        if shouldAbort { controller.abort(reason: "The model call was interrupted by steering.") }
    }

    deinit { stopWatching?() }
}

extension AI {
    public static func experimentalCreateSteering() -> AISteering { AISteering() }
}

public struct AIGenerateTextStepErrorEvent: Sendable {
    public var stepNumber: Int
    public var providerID: String
    public var modelID: String
    public var request: LanguageModelRequest
    public var steps: [AIToolStep] = []
    public var error: any Error
    public init(stepNumber: Int, providerID: String, modelID: String, request: LanguageModelRequest, error: any Error) { self.stepNumber = stepNumber; self.providerID = providerID; self.modelID = modelID; self.request = request; self.error = error }
}
public typealias AIGenerateTextOnStepError = @Sendable (AIGenerateTextStepErrorEvent) async throws -> Void

/// Checks the error and up to four underlying errors for abort/timeout causes.
public func isCausedByAbort(_ error: any Error) -> Bool {
    var current: (any Error)? = error
    for _ in 0..<5 {
        guard let value = current else { return false }
        if value is CancellationError || value is AIAbortError || value is AIStreamTimeoutError { return true }
        if let ai = value as? AIError, case .timeout = ai { return true }
        if let retry = value as? AIRetryError, retry.reason == .cancelled { return true }
        let ns = value as NSError
        if ns.domain == NSURLErrorDomain && [NSURLErrorCancelled, NSURLErrorTimedOut].contains(ns.code) { return true }
        current = ns.userInfo[NSUnderlyingErrorKey] as? any Error
    }
    return false
}


public struct AIGenerationErrorEvent: Sendable {
    public var error: any Error
    public init(error: any Error) { self.error = error }
}
public typealias AIGenerationOnError = @Sendable (AIGenerationErrorEvent) async throws -> Void

public struct AIStreamTextAbortEvent: Sendable {
    public var steps: [AIToolStep]
    public var reason: String?
    public init(steps: [AIToolStep], reason: String? = nil) { self.steps = steps; self.reason = reason }
}
public typealias AIStreamTextOnAbort = @Sendable (AIStreamTextAbortEvent) async throws -> Void

final class AISteeringStepResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [AIToolStep] = []
    func append(_ step: AIToolStep) { lock.withLock { results.append(step) } }
    var steps: [AIToolStep] { lock.withLock { results } }
}

enum AITelemetryStepContext {
    @TaskLocal static var stepNumber: Int = 0
}


func steeringCompletionReason(finishReason: String?, waitingForToolResults: Bool, stopped: Bool, reachedStepLimit: Bool) -> AISteeringNotDeliveredReason {
    if finishReason == "interrupted" { return .finished }
    if waitingForToolResults { return .waitingForToolResults }
    if finishReason == "error" { return .error }
    if stopped || reachedStepLimit { return .stopCondition }
    return .finished
}


enum AISteeringContext {
    @TaskLocal static var streamResults: AISteeringStepResults?
}


func isTextStreamTimeout(_ error: any Error) -> Bool {
    var current: (any Error)? = error
    for _ in 0..<5 {
        guard let value = current else { return false }
        if value is AIStreamTimeoutError { return true }
        if let value = value as? AIError, case .timeout = value { return true }
        if let value = value as? AIAbortError, value.reasonName == "TimeoutError" { return true }
        let underlying = value as NSError
        if underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorTimedOut { return true }
        current = underlying.userInfo[NSUnderlyingErrorKey] as? any Error
    }
    return false
}
