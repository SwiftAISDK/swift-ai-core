import Foundation
import SwiftAIProvider


/// Adapts bytes on consumer demand. In particular, an unread response never
/// creates a queue containing one allocated Data value per response byte.
func makeDemandDrivenHTTPBody<Source: AsyncSequence>(
    bytes: Source,
    url: String,
    maxBytes: Int,
    abortSignal: AIAbortSignal?,
    cancel: @escaping @Sendable () -> Void
) -> (body: AsyncThrowingStream<Data, Error>, cancel: @Sendable () -> Void)
where Source.Element == UInt8, Source.AsyncIterator: SendableMetatype {
    let reader = HTTPByteBodyReader(
        iterator: bytes.makeAsyncIterator(),
        url: url,
        maxBytes: maxBytes,
        abortSignal: abortSignal,
        cancel: cancel
    )
    reader.installAbortHandler()
    return (
        AsyncThrowingStream(unfolding: { try await reader.next() }),
        { reader.finish() }
    )
}

/// The iterator has exactly one owner: storage under the lock, or the active
/// next() invocation. Cancellation touches only the state and underlying task,
/// never the iterator that is currently suspended in next().
private final class HTTPByteBodyReader<Iterator: AsyncIteratorProtocol & SendableMetatype>: @unchecked Sendable
where Iterator.Element == UInt8 {
    private let lock = NSLock()
    private var iterator: Iterator?
    private var finished = false
    private var totalBytes = 0
    private var registration: AIAbortHandlerRegistration?
    private let url: String
    private let maxBytes: Int
    private let abortSignal: AIAbortSignal?
    private let cancelSource: @Sendable () -> Void

    init(
        iterator: Iterator,
        url: String,
        maxBytes: Int,
        abortSignal: AIAbortSignal?,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.iterator = iterator
        self.url = url
        self.maxBytes = maxBytes
        self.abortSignal = abortSignal
        self.cancelSource = cancel
    }

    func installAbortHandler() {
        let registration = abortSignal?.addAbortHandler { [weak self] _ in
            self?.finish()
        }
        let keep = lock.withLock {
            guard !finished else { return false }
            self.registration = registration
            return true
        }
        if !keep { registration?.cancel() }
    }

    func next() async throws -> Data? {
        try abortSignal?.throwIfAborted()
        if Task.isCancelled {
            finish()
            throw CancellationError()
        }
        guard var iterator = try takeIterator() else { return nil }
        return try await withTaskCancellationHandler {
            do {
                let byte = try await iterator.next()
                try abortSignal?.throwIfAborted()
                try Task.checkCancellation()
                guard let byte else {
                    finish()
                    return nil
                }
                let accepted = try lock.withLock {
                    guard !finished else { return false }
                    guard totalBytes < maxBytes else {
                        throw AIDownloadError(
                            url: url,
                            message: "Download of \(url) exceeded maximum size of \(maxBytes) bytes."
                        )
                    }
                    totalBytes += 1
                    self.iterator = iterator
                    return true
                }
                return accepted ? Data([byte]) : nil
            } catch {
                finish()
                try abortSignal?.throwIfAborted()
                throw error
            }
        } onCancel: {
            self.finish()
        }
    }

    private func takeIterator() throws -> Iterator? {
        try lock.withLock {
            guard !finished else { return nil }
            guard let iterator else {
                throw AIError.invalidArgument(
                    argument: "response.body",
                    message: "An HTTP response body supports only one active read."
                )
            }
            self.iterator = nil
            return iterator
        }
    }

    func finish() {
        let state: (Bool, AIAbortHandlerRegistration?) = lock.withLock {
            guard !finished else { return (false, nil) }
            finished = true
            iterator = nil
            let registration = self.registration
            self.registration = nil
            return (true, registration)
        }
        guard state.0 else { return }
        state.1?.cancel()
        cancelSource()
    }

    deinit { finish() }
}