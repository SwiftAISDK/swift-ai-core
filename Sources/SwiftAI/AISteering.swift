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

/// Adds user messages at model-step boundaries. One object belongs to one run.
public final class AISteering: @unchecked Sendable {
    private struct Pending { var id: String; var message: AIMessage; var receipt: AISteeringReceipt }
    private enum State { case idle, running, ended }
    private let lock = NSLock()
    private var state: State = .idle
    private var pending: [Pending] = []
    private var queued: [Pending] = []
    private var taken: [Pending] = []
    private var receipts: [String: AISteeringReceipt] = [:]
    fileprivate init() {}

    public func steer(_ text: String, id: String? = nil) -> AISteeringReceipt {
        enqueue(.user(text), id: id)
    }
    public func steer(content: [AIContentPart], providerMetadata: [String: JSONValue] = [:], id: String? = nil) -> AISteeringReceipt {
        enqueue(AIMessage(role: .user, content: content, providerMetadata: providerMetadata), id: id)
    }
    public func queue(_ text: String, id: String? = nil) -> AISteeringReceipt {
        enqueue(.user(text), id: id, queued: true)
    }
    public func queue(content: [AIContentPart], providerMetadata: [String: JSONValue] = [:], id: String? = nil) -> AISteeringReceipt {
        enqueue(AIMessage(role: .user, content: content, providerMetadata: providerMetadata), id: id, queued: true)
    }
    private func enqueue(_ message: AIMessage, id: String?, queued: Bool = false) -> AISteeringReceipt {
        lock.withLock {
            let id = id ?? "steer-\(UUID().uuidString)"
            if let existing = receipts[id] { return existing }
            let receipt = AISteeringReceipt()
            receipts[id] = receipt
            if state == .ended { receipt.resolve(.notDelivered(id: id, message: message, reason: .finished)) }
            else if queued { self.queued.append(Pending(id: id, message: message, receipt: receipt)) }
            else { pending.append(Pending(id: id, message: message, receipt: receipt)) }
            return receipt
        }
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
            taken.append(contentsOf: pending); pending.removeAll()
            return taken.map(\.message)
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
            defer { pending.removeAll(); taken.removeAll(); queued.removeAll() }
            return taken + pending + queued
        }
        for item in messages { item.receipt.resolve(.notDelivered(id: item.id, message: item.message, reason: reason)) }
    }
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
