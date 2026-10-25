import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func withRetry<Output: Sendable>(
    policy: AIRetryPolicy,
    abortSignal: AIAbortSignal? = nil,
    onRetry: @escaping @Sendable (AIRetryAttemptTelemetry) async -> Void = { _ in },
    operation: @escaping @Sendable () async throws -> Output
) async throws -> Output {
    try validateRetryPolicy(policy)

    var errors: [String] = []
    var delay = policy.initialDelayNanoseconds

    while true {
        try Task.checkCancellation()
        try abortSignal?.throwIfAborted()
        do {
            return try await withTimeout(policy.timeoutNanoseconds, operation: operation)
        } catch is CancellationError {
            throw AIRetryError(reason: .cancelled, attempts: errors.count + 1, errors: errors)
        } catch let error as AIAbortError {
            throw error
        } catch {
            errors.append(String(describing: error))
            let attempts = errors.count
            guard policy.maxRetries > 0 else { throw error }
            guard isRetryable(error) else {
                if attempts == 1 { throw error }
                throw AIRetryError(reason: .errorNotRetryable, attempts: attempts, errors: errors)
            }
            guard attempts <= policy.maxRetries else {
                throw AIRetryError(reason: .maxRetriesExceeded, attempts: attempts, errors: errors)
            }
            let sleepDelay = retryDelayNanoseconds(from: error, exponentialBackoffDelay: delay)
            await onRetry(AIRetryAttemptTelemetry(
                attempt: attempts,
                maxRetries: policy.maxRetries,
                errorDescription: String(describing: error),
                delayNanoseconds: sleepDelay
            ))
            if sleepDelay > 0 {
                try await sleep(nanoseconds: sleepDelay, abortSignal: abortSignal)
            }
            delay = nextDelay(current: delay, policy: policy)
        }
    }
}

func sleep(nanoseconds: UInt64, abortSignal: AIAbortSignal?) async throws {
    try await sleepWithAbortSignal(nanoseconds: nanoseconds, abortSignal: abortSignal)
}

func validateRetryPolicy(_ policy: AIRetryPolicy) throws {
    guard policy.maxRetries >= 0 else {
        throw AIError.invalidArgument(argument: "maxRetries", message: "maxRetries must be >= 0.")
    }
    guard policy.backoffFactor >= 1 else {
        throw AIError.invalidArgument(argument: "backoffFactor", message: "backoffFactor must be >= 1.")
    }
    if let timeout = policy.timeoutNanoseconds {
        guard timeout > 0 else {
            throw AIError.invalidArgument(argument: "timeoutNanoseconds", message: "timeoutNanoseconds must be greater than zero.")
        }
    }
}

func withTimeout<Output: Sendable>(
    _ timeoutNanoseconds: UInt64?,
    operation: @escaping @Sendable () async throws -> Output
) async throws -> Output {
    guard let timeoutNanoseconds else {
        return try await operation()
    }

    return try await withThrowingTaskGroup(of: Output.self) { group in
        defer { group.cancelAll() }

        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw AIError.timeout(durationNanoseconds: timeoutNanoseconds)
        }

        guard let result = try await group.next() else {
            throw CancellationError()
        }
        return result
    }
}

func streamWithAbortSignal<Part: Sendable>(
    _ stream: AsyncThrowingStream<Part, Error>,
    abortSignal: AIAbortSignal?
) -> AsyncThrowingStream<Part, Error> {
    guard let abortSignal else { return stream }
    return AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try abortSignal.throwIfAborted()
                for try await part in stream {
                    try Task.checkCancellation()
                    try abortSignal.throwIfAborted()
                    continuation.yield(part)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let registration = abortSignal.addAbortHandler { _ in
            // Settle consumers before telemetry or provider cancellation can stall.
            continuation.finish(throwing: AIAbortError(reason: abortSignal.reason, reasonName: abortSignal.reasonName))
            task.cancel()
        }
        continuation.onTermination = { _ in
            registration.cancel()
            task.cancel()
        }
    }
}

func streamWithTimeout<Part: Sendable>(
    _ stream: AsyncThrowingStream<Part, Error>,
    timeoutNanoseconds: UInt64?,
    abortController: AIAbortController? = nil,
    timeoutLabel: String = "Operation"
) -> AsyncThrowingStream<Part, Error> {
    guard let timeoutNanoseconds else { return stream }
    guard timeoutNanoseconds > 0 else {
        return failingPartStream(AIError.invalidArgument(
            argument: "timeoutNanoseconds",
            message: "timeoutNanoseconds must be greater than zero."
        ))
    }

    return AsyncThrowingStream { continuation in
        let terminalState = AIStreamTimeoutTerminalState()
        let streamTask = Task {
            do {
                for try await part in stream {
                    try Task.checkCancellation()
                    guard !terminalState.hasFinished else { return }
                    continuation.yield(part)
                }
                if terminalState.claim() {
                    continuation.finish()
                }
            } catch {
                if terminalState.claim() {
                    continuation.finish(throwing: error)
                }
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard terminalState.claim() else { return }
            abortController?.abort(
                reason: "\(timeoutLabel) timeout of \(timeoutNanoseconds) nanoseconds exceeded.",
                reasonName: "TimeoutError"
            )
            streamTask.cancel()
            continuation.finish(throwing: AIError.timeout(
                durationNanoseconds: timeoutNanoseconds
            ))
        }

        continuation.onTermination = { _ in
            _ = terminalState.claim()
            streamTask.cancel()
            timeoutTask.cancel()
        }
    }
}

private final class AIStreamTimeoutTerminalState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var hasFinished: Bool {
        lock.withLock { finished }
    }

    func claim() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }
}

func minimumTimeoutNanoseconds(_ values: UInt64?...) -> UInt64? {
    values.compactMap { $0 }.min()
}

func streamWithSemanticOutputTimeouts(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    firstChunkNanoseconds: UInt64?,
    chunkNanoseconds: UInt64?,
    abortController: AIAbortController? = nil
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    guard firstChunkNanoseconds != nil || chunkNanoseconds != nil else { return stream }

    return AsyncThrowingStream { continuation in
        let watchdog = AIStreamOutputTimeoutWatchdog(
            firstChunkNanoseconds: firstChunkNanoseconds,
            chunkNanoseconds: chunkNanoseconds,
            onTimeout: { error in
                abortController?.abort(
                    reason: error.description,
                    reasonName: "TimeoutError"
                )
                continuation.finish(throwing: error)
            }
        )
        let task = Task {
            watchdog.start()
            do {
                for try await part in stream {
                    try Task.checkCancellation()
                    switch part {
                    case .finish, .finishMetadata, .error: watchdog.endModelOutput()
                    default: break
                    }
                    if isSemanticLanguageOutput(part) {
                        guard watchdog.recordSemanticOutput() else { return }
                    } else if watchdog.hasTimedOut {
                        return
                    }
                    continuation.yield(part)
                }
                if watchdog.finish() {
                    continuation.finish()
                }
            } catch {
                if watchdog.finish() {
                    continuation.finish(throwing: error)
                }
            }
        }

        continuation.onTermination = { _ in
            watchdog.cancel()
            task.cancel()
        }
    }
}

func streamWithSemanticOutputTimeouts<FinalOutput: Sendable, PartialOutput: Sendable>(
    _ stream: AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error>,
    firstChunkNanoseconds: UInt64?,
    chunkNanoseconds: UInt64?,
    abortController: AIAbortController? = nil
) -> AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error> {
    guard firstChunkNanoseconds != nil || chunkNanoseconds != nil else { return stream }

    return AsyncThrowingStream { continuation in
        let watchdog = AIStreamOutputTimeoutWatchdog(
            firstChunkNanoseconds: firstChunkNanoseconds,
            chunkNanoseconds: chunkNanoseconds,
            onTimeout: { error in
                abortController?.abort(
                    reason: error.description,
                    reasonName: "TimeoutError"
                )
                continuation.finish(throwing: error)
            }
        )
        let task = Task {
            watchdog.start()
            do {
                for try await part in stream {
                    try Task.checkCancellation()
                    switch part {
                    case .finish: watchdog.endModelOutput()
                    case let .raw(languagePart):
                        switch languagePart {
                        case .finish, .finishMetadata, .error: watchdog.endModelOutput()
                        default: break
                        }
                    default: break
                    }
                    if isSemanticOutput(part) {
                        guard watchdog.recordSemanticOutput() else { return }
                    } else if watchdog.hasTimedOut {
                        return
                    }
                    continuation.yield(part)
                }
                if watchdog.finish() {
                    continuation.finish()
                }
            } catch {
                if watchdog.finish() {
                    continuation.finish(throwing: error)
                }
            }
        }

        continuation.onTermination = { _ in
            watchdog.cancel()
            task.cancel()
        }
    }
}

private func isSemanticOutput<FinalOutput: Sendable, PartialOutput: Sendable>(
    _ part: AIOutputStreamPart<FinalOutput, PartialOutput>
) -> Bool {
    switch part {
    case let .textDelta(delta):
        return !delta.isEmpty
    case .partialOutput:
        return true
    case let .raw(part):
        return isSemanticLanguageOutput(part)
    case .output,
         .warning,
         .source,
         .metadata,
         .responseMetadata,
         .finish:
        return false
    }
}

private func isSemanticLanguageOutput(_ part: LanguageStreamPart) -> Bool {
    switch part {
    case let .textDelta(delta),
         let .reasoningDelta(delta):
        return !delta.isEmpty
    case let .textDeltaPart(_, delta, _),
         let .reasoningDeltaPart(_, delta, _),
         let .toolInputDelta(_, delta, _):
        return !delta.isEmpty
    case let .toolCallDelta(_, _, argumentsDelta, _):
        return !argumentsDelta.isEmpty
    case .file, .reasoningFile, .toolCall:
        return true
    case .streamStart,
         .textStart,
         .textEnd,
         .textEndWithCitations,
         .reasoningStart,
         .reasoningEnd,
         .toolInputStart,
         .toolInputStartText,
         .toolInputEnd,
         .toolResult,
         .toolApprovalRequest,
         .toolApprovalResponse,
         .custom,
         .source,
         .metadata,
         .responseMetadata,
         .raw,
         .error,
         .finish,
         .finishMetadata:
        return false
    }
}

private final class AIStreamOutputTimeoutWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let firstChunkNanoseconds: UInt64?
    private let chunkNanoseconds: UInt64?
    private let onTimeout: @Sendable (AIStreamTimeoutError) -> Void
    private var timer: Task<Void, Never>?
    private var generation = 0
    private var didFinish = false
    private var modelOutputEnded = false

    init(
        firstChunkNanoseconds: UInt64?,
        chunkNanoseconds: UInt64?,
        onTimeout: @escaping @Sendable (AIStreamTimeoutError) -> Void
    ) {
        self.firstChunkNanoseconds = firstChunkNanoseconds
        self.chunkNanoseconds = chunkNanoseconds
        self.onTimeout = onTimeout
    }

    var hasTimedOut: Bool {
        lock.withLock { didFinish }
    }

    func start() {
        lock.withLock {
            guard !didFinish, let firstChunkNanoseconds else { return }
            armLocked(phase: .firstChunk, durationNanoseconds: firstChunkNanoseconds)
        }
    }

    @discardableResult
    func recordSemanticOutput() -> Bool {
        lock.withLock {
            guard !didFinish else { return false }
            guard !modelOutputEnded else { return true }
            timer?.cancel()
            timer = nil
            if let chunkNanoseconds {
                armLocked(phase: .chunk, durationNanoseconds: chunkNanoseconds)
            }
            return true
        }
    }

    func endModelOutput() {
        lock.withLock {
            modelOutputEnded = true
            generation += 1
            timer?.cancel()
            timer = nil
        }
    }

    @discardableResult
    func finish() -> Bool {
        lock.withLock {
            guard !didFinish else { return false }
            didFinish = true
            timer?.cancel()
            timer = nil
            return true
        }
    }

    func cancel() {
        _ = finish()
    }

    private func armLocked(phase: AIStreamTimeoutPhase, durationNanoseconds: UInt64) {
        generation += 1
        let token = generation
        timer = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: durationNanoseconds)
            } catch {
                return
            }
            self?.fire(
                token: token,
                phase: phase,
                durationNanoseconds: durationNanoseconds
            )
        }
    }

    private func fire(
        token: Int,
        phase: AIStreamTimeoutPhase,
        durationNanoseconds: UInt64
    ) {
        let shouldNotify = lock.withLock {
            guard !didFinish, generation == token else { return false }
            didFinish = true
            timer = nil
            return true
        }
        if shouldNotify {
            onTimeout(AIStreamTimeoutError(
                phase: phase,
                durationNanoseconds: durationNanoseconds
            ))
        }
    }
}

func failingPartStream<Part: Sendable>(_ error: Error) -> AsyncThrowingStream<Part, Error> {
    AsyncThrowingStream { continuation in
        continuation.finish(throwing: error)
    }
}

func isRetryable(_ error: Error) -> Bool {
    if error is AIRetryableEmptyImageResultError {
        return true
    }
    if error is AITerminalEmptyImageResultError {
        return false
    }
    if let error = error as? AIError {
        if let apiError = error.apiCallError {
            return apiError.isRetryable
        }
        if case let .gateway(gatewayError) = error {
            return gatewayError.isRetryable
        }
        return false
    }
    if let error = error as? AIAPICallError {
        return error.isRetryable
    }
    if let error = error as? URLError {
        switch error.code {
        case .cancelled, .userCancelledAuthentication:
            return false
        default:
            return true
        }
    }
    return false
}

func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
    statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
}

func retryDelayNanoseconds(from error: Error, exponentialBackoffDelay: UInt64, now: Date = Date()) -> UInt64 {
    retryHeaderDelayNanoseconds(
        from: error,
        exponentialBackoffDelay: exponentialBackoffDelay,
        now: now
    ) ?? exponentialBackoffDelay
}

func retryHeaderDelayNanoseconds(from error: Error, exponentialBackoffDelay: UInt64, now: Date = Date()) -> UInt64? {
    guard let headers = httpHeaders(from: error) else { return nil }
    var delayNanoseconds: UInt64?

    if let retryAfterMs = headerValue("retry-after-ms", in: headers),
       let parsedDelay = retryAfterDelayNanoseconds(fromMilliseconds: retryAfterMs) {
        delayNanoseconds = parsedDelay
    }

    if delayNanoseconds == nil,
       let retryAfter = headerValue("retry-after", in: headers) {
        delayNanoseconds = retryAfterDelayNanoseconds(from: retryAfter, now: now)
    }

    guard let delayNanoseconds,
          isReasonableRetryDelay(delayNanoseconds, exponentialBackoffDelay: exponentialBackoffDelay) else {
        return nil
    }
    return delayNanoseconds
}

func httpHeaders(from error: Error) -> [String: String]? {
    if let error = error as? AIError {
        if let apiError = error.apiCallError {
            return apiError.responseHeaders
        }
        if case let .gateway(gatewayError) = error {
            return gatewayError.headers
        }
    }
    if let error = error as? AIAPICallError {
        return error.responseHeaders
    }
    return nil
}

func headerValue(_ name: String, in headers: [String: String]) -> String? {
    if let value = headers[name] {
        return value
    }
    let lowercasedName = name.lowercased()
    return headers.first { key, _ in key.lowercased() == lowercasedName }?.value
}

func retryAfterDelayNanoseconds(from value: String, now: Date) -> UInt64? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let seconds = Double(trimmed) {
        return nanoseconds(fromSeconds: seconds)
    }
    guard let date = httpDate(from: trimmed) else { return nil }
    return nanoseconds(fromSeconds: date.timeIntervalSince(now))
}

func retryAfterDelayNanoseconds(fromMilliseconds value: String) -> UInt64? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let milliseconds = Double(trimmed) else { return nil }
    return nanoseconds(fromMilliseconds: milliseconds)
}

func isReasonableRetryDelay(_ delayNanoseconds: UInt64, exponentialBackoffDelay: UInt64) -> Bool {
    delayNanoseconds < 60_000_000_000 || delayNanoseconds < exponentialBackoffDelay
}

func nanoseconds(fromMilliseconds milliseconds: Double) -> UInt64? {
    guard milliseconds.isFinite else { return nil }
    guard milliseconds >= 0 else { return nil }
    let nanoseconds = milliseconds * 1_000_000
    guard nanoseconds.isFinite else { return UInt64.max }
    if nanoseconds >= Double(UInt64.max) {
        return UInt64.max
    }
    return UInt64(nanoseconds.rounded(.up))
}

func nanoseconds(fromSeconds seconds: Double) -> UInt64? {
    guard seconds.isFinite else { return nil }
    guard seconds >= 0 else { return nil }
    guard seconds > 0 else { return 0 }
    let nanoseconds = seconds * 1_000_000_000
    guard nanoseconds.isFinite else { return UInt64.max }
    if nanoseconds >= Double(UInt64.max) {
        return UInt64.max
    }
    return UInt64(nanoseconds.rounded(.up))
}

func httpDate(from value: String) -> Date? {
    let formats = [
        "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
        "EEEE',' dd'-'MMM'-'yy HH':'mm':'ss zzz",
        "EEE MMM d HH':'mm':'ss yyyy"
    ]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        if let date = formatter.date(from: value) {
            return date
        }
    }
    return nil
}

func nextDelay(current: UInt64, policy: AIRetryPolicy) -> UInt64 {
    guard current > 0 else { return 0 }
    let next = Double(current) * policy.backoffFactor
    guard next.isFinite, next < Double(UInt64.max) else {
        return policy.maxDelayNanoseconds
    }
    return Swift.min(UInt64(next), policy.maxDelayNanoseconds)
}