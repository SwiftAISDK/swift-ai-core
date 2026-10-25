import Foundation
import SwiftAIProvider
import SwiftAITransport


public final class AIDelayedPromise<Value: Sendable>: @unchecked Sendable {
    private enum Status {
        case pending
        case resolved(Value)
        case rejected(Error)
    }

    private let lock = NSLock()
    private var status: Status = .pending
    private var continuations: [UUID: CheckedContinuation<Value, Error>] = [:]

    public init() {}

    public var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .pending = status {
            return true
        }
        return false
    }

    public var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .resolved = status {
            return true
        }
        return false
    }

    public var isRejected: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .rejected = status {
            return true
        }
        return false
    }

    public func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            switch status {
            case .pending:
                continuations[UUID()] = continuation
                lock.unlock()
            case let .resolved(value):
                lock.unlock()
                continuation.resume(returning: value)
            case let .rejected(error):
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    public func resolve(_ value: Value) {
        complete(.resolved(value))
    }

    public func reject(_ error: Error) {
        complete(.rejected(error))
    }

    private func complete(_ nextStatus: Status) {
        lock.lock()
        status = nextStatus
        let continuations = Array(self.continuations.values)
        self.continuations.removeAll()
        lock.unlock()

        for continuation in continuations {
            switch nextStatus {
            case let .resolved(value):
                continuation.resume(returning: value)
            case let .rejected(error):
                continuation.resume(throwing: error)
            case .pending:
                break
            }
        }
    }
}