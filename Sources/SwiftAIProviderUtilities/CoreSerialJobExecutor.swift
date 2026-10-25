import Foundation
import SwiftAIProvider
import SwiftAITransport


public final class AISerialJobExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init() {}

    public func run(_ job: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        lock.lock()
        generation &+= 1
        let previous = tail
        let task = Task {
            await previous?.value
            try await job()
        }
        tail = Task {
            _ = try? await task.value
            await Task.yield()
        }
        lock.unlock()
        return task
    }

    /// Waits for queued work, including jobs enqueued by a running job.
    public func waitForIdle() async {
        while true {
            let (current, revision) = snapshot()
            await current?.value
            if isCurrent(revision) { return }
        }
    }

    private func snapshot() -> (Task<Void, Never>?, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (tail, generation)
    }

    private func isCurrent(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == revision
    }
}