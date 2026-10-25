import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


/// Timeout controls that apply to a streamed language-model call.
///
/// `totalNanoseconds` limits the complete facade operation, while
/// `stepNanoseconds` limits each individual model-call step. The first-chunk
/// and inter-chunk timers are restarted for every model-call step and only
/// observe semantic output: non-empty text, reasoning or tool-input deltas,
/// files, and complete tool calls. Metadata, lifecycle, raw keep-alive, and
/// empty delta parts do not disarm or reset them.
public struct AIStreamTimeoutConfiguration: Equatable, Sendable {
    public var totalNanoseconds: UInt64?
    public var stepNanoseconds: UInt64?
    public var firstChunkNanoseconds: UInt64?
    public var chunkNanoseconds: UInt64?

    public init(
        totalNanoseconds: UInt64? = nil,
        stepNanoseconds: UInt64? = nil,
        firstChunkNanoseconds: UInt64? = nil,
        chunkNanoseconds: UInt64? = nil
    ) {
        self.totalNanoseconds = totalNanoseconds
        self.stepNanoseconds = stepNanoseconds
        self.firstChunkNanoseconds = firstChunkNanoseconds
        self.chunkNanoseconds = chunkNanoseconds
    }
}

public enum AIStreamTimeoutPhase: String, Equatable, Sendable {
    case firstChunk
    case chunk
}

public struct AIStreamTimeoutError: Error, Equatable, CustomStringConvertible, Sendable {
    public var phase: AIStreamTimeoutPhase
    public var durationNanoseconds: UInt64

    public init(phase: AIStreamTimeoutPhase, durationNanoseconds: UInt64) {
        self.phase = phase
        self.durationNanoseconds = durationNanoseconds
    }

    public var description: String {
        let label = switch phase {
        case .firstChunk: "First chunk"
        case .chunk: "Chunk"
        }
        return "\(label) timeout of \(durationNanoseconds) nanoseconds exceeded."
    }
}

func validateStreamTimeoutConfiguration(
    _ timeout: AIStreamTimeoutConfiguration?
) -> AIError? {
    guard let timeout else { return nil }
    let values: [(String, UInt64?)] = [
        ("timeout.totalNanoseconds", timeout.totalNanoseconds),
        ("timeout.stepNanoseconds", timeout.stepNanoseconds),
        ("timeout.firstChunkNanoseconds", timeout.firstChunkNanoseconds),
        ("timeout.chunkNanoseconds", timeout.chunkNanoseconds),
    ]
    for (argument, value) in values where value == 0 {
        return .invalidArgument(
            argument: argument,
            message: "\(argument) must be greater than zero."
        )
    }
    return nil
}

/// A step-scoped deadline whose signal stays active through model streaming
/// and client-side tool execution.
final class AIStreamTimeoutDeadline: @unchecked Sendable {
    let durationNanoseconds: UInt64?
    let label: String
    let abortController: AIAbortController?

    private let lock = NSLock()
    private var timer: Task<Void, Never>?
    private var started = false
    private var finished = false
    private var timedOut = false

    init(durationNanoseconds: UInt64?, label: String) {
        self.durationNanoseconds = durationNanoseconds
        self.label = label
        self.abortController = durationNanoseconds == nil ? nil : AIAbortController()
    }

    var signal: AIAbortSignal? {
        abortController?.signal
    }

    var hasTimedOut: Bool {
        lock.withLock { timedOut }
    }

    func start() {
        guard let durationNanoseconds else { return }
        lock.withLock {
            guard !started, !finished else { return }
            started = true
            timer = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: durationNanoseconds)
                } catch {
                    return
                }
                self?.fire()
            }
        }
    }

    func cancel() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            timer?.cancel()
            timer = nil
        }
    }

    func throwIfTimedOut() throws {
        guard hasTimedOut, let durationNanoseconds else { return }
        throw AIError.timeout(durationNanoseconds: durationNanoseconds)
    }

    private func fire() {
        let shouldAbort = lock.withLock {
            guard !finished else { return false }
            finished = true
            timedOut = true
            timer = nil
            return true
        }
        guard shouldAbort, let durationNanoseconds else { return }
        abortController?.abort(
            reason: "\(label) timeout of \(durationNanoseconds) nanoseconds exceeded.",
            reasonName: "TimeoutError"
        )
    }
}