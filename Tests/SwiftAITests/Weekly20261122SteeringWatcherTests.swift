// ai@7.0.179, release ref 9b8c25e582bb2ca97e459ba3f8f6b325cb9dfb22, steering.test.ts.
import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider

@Suite("Steering interrupt watcher")
struct Weekly20261122SteeringWatcherTests {
    private func runningSteering() throws -> AISteering {
        let steering = AI.experimentalCreateSteering()
        try steering.start()
        return steering
    }

    @Test func invokesWatcherAndLeavesMessagePending() throws {
        let steering = try runningSteering(), watcher = InterruptWatcherCounter()
        _ = steering.watchInterrupt(watcher.record)
        _ = steering.steer("stop", interrupt: true)
        #expect(watcher.count == 1)
        #expect(steering.hasPendingMessages)
    }

    @Test func ordinarySteersAndQueuedTasksLeaveWatcherIdle() throws {
        let steering = try runningSteering(), watcher = InterruptWatcherCounter()
        _ = steering.watchInterrupt(watcher.record)
        _ = steering.steer("later")
        _ = steering.queue("after the task", id: "queued")
        #expect(watcher.count == 0)
    }

    @Test func waitingInterruptImmediatelyInvokesNewWatcher() throws {
        let steering = try runningSteering(), watcher = InterruptWatcherCounter()
        _ = steering.steer("stop", interrupt: true)
        _ = steering.watchInterrupt(watcher.record)
        #expect(watcher.count == 1)
    }

    @Test func takingMessageAtStepBoundaryClearsWaitingInterrupt() throws {
        let steering = try runningSteering(), watcher = InterruptWatcherCounter()
        _ = steering.steer("stop", interrupt: true)
        #expect(steering.takeMessages() == [.user("stop")])
        _ = steering.watchInterrupt(watcher.record)
        #expect(watcher.count == 0)
    }

    @Test func cancellingWatcherPreventsNotification() throws {
        let steering = try runningSteering(), watcher = InterruptWatcherCounter()
        let stop = steering.watchInterrupt(watcher.record)
        stop()
        _ = steering.steer("stop", interrupt: true)
        #expect(watcher.count == 0)
    }

    @Test func eachWatcherIsNotifiedAtMostOnce() throws {
        let steering = try runningSteering(), watcher = InterruptWatcherCounter()
        _ = steering.watchInterrupt(watcher.record)
        _ = steering.steer("stop", interrupt: true)
        _ = steering.steer("stop again", interrupt: true)
        #expect(watcher.count == 1)
    }

    @Test func duplicateOrdinarySteerCannotInterrupt() throws {
        let steering = try runningSteering(), watcher = InterruptWatcherCounter()
        let original = steering.steer("stop", id: "steer-1")
        _ = steering.watchInterrupt(watcher.record)
        #expect(steering.steer("stop", id: "steer-1", interrupt: true) === original)
        #expect(watcher.count == 0)
    }

    @Test func endedRunRejectsInterruptAndStopsWatcher() async throws {
        let steering = try runningSteering(), watcher = InterruptWatcherCounter()
        _ = steering.watchInterrupt(watcher.record)
        steering.end(.finished)
        let outcome = await steering.steer("stop", id: "ended", interrupt: true).value
        #expect(watcher.count == 0)
        #expect(outcome == .notDelivered(id: "ended", message: .user("stop"), reason: .finished))
    }

    @Test func watcherCanReenterSteering() throws {
        let steering = try runningSteering(), watcher = InterruptWatcherCounter()
        _ = steering.watchInterrupt {
            #expect(steering.hasPendingMessages)
            watcher.record()
        }
        _ = steering.steer("stop", interrupt: true)
        #expect(watcher.count == 1)
    }
}

private final class InterruptWatcherCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var notifications = 0

    var count: Int { lock.withLock { notifications } }
    func record() { lock.withLock { notifications += 1 } }
}
