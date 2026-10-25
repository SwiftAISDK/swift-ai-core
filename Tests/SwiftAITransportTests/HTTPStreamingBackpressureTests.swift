import Foundation
import Testing
@testable import SwiftAITransport
import SwiftAIProvider

@Suite("HTTP streaming backpressure")
struct HTTPStreamingBackpressureTests {
    @Test func unreadAndSlowConsumersDoNotPullAhead() async throws {
        let probe = ByteDemandProbe(limit: 1_048_576)
        let response = makeDemandDrivenHTTPBody(
            bytes: ProbedBytes(probe: probe), url: "https://example.com/large",
            maxBytes: 1_048_576, abortSignal: nil, cancel: { probe.cancel() }
        )
        for _ in 0..<100 { await Task.yield() }
        #expect(probe.readCount == 0)
        var iterator = response.body.makeAsyncIterator()
        for index in 0..<128 {
            #expect(try await iterator.next() == Data([UInt8(index % 256)]))
            #expect(probe.readCount == index + 1)
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(probe.readCount == 128)
        response.cancel()
        #expect(try await iterator.next() == nil)
        #expect(probe.cancelCount == 1)
    }

    @Test func completeBodyPreservesBytesAndReleasesProducer() async throws {
        let probe = ByteDemandProbe(limit: 4_096)
        let response = makeDemandDrivenHTTPBody(
            bytes: ProbedBytes(probe: probe), url: "https://example.com/bytes",
            maxBytes: 4_096, abortSignal: nil, cancel: { probe.cancel() }
        )
        var result = Data()
        for try await chunk in response.body { result.append(chunk) }
        #expect(result == Data((0..<4_096).map { UInt8($0 % 256) }))
        #expect(probe.cancelCount == 1)
        response.cancel()
        #expect(probe.cancelCount == 1)
    }

    @Test func limitStopsTheProducerWithoutDeliveringExcessBytes() async throws {
        let probe = ByteDemandProbe(limit: 10)
        let response = makeDemandDrivenHTTPBody(
            bytes: ProbedBytes(probe: probe), url: "https://example.com/limit",
            maxBytes: 3, abortSignal: nil, cancel: { probe.cancel() }
        )
        var result = Data()
        await #expect(throws: AIDownloadError.self) {
            for try await chunk in response.body { result.append(chunk) }
        }
        #expect(result == Data([0, 1, 2]))
        #expect(probe.readCount == 4)
        #expect(probe.cancelCount == 1)
    }

    @Test func abortBeforeReadingRetainsReasonWithoutPullingSource() async throws {
        let probe = ByteDemandProbe(limit: 100)
        let controller = AIAbortController()
        let response = makeDemandDrivenHTTPBody(
            bytes: ProbedBytes(probe: probe), url: "https://example.com/abort",
            maxBytes: 100, abortSignal: controller.signal, cancel: { probe.cancel() }
        )
        controller.abort(reason: "finished early", reasonName: "AbortError")
        await #expect(throws: AIAbortError(reason: "finished early", reasonName: "AbortError")) {
            for try await _ in response.body {}
        }
        #expect(probe.readCount == 0)
        #expect(probe.cancelCount == 1)
    }

    @Test func cancellingSuspendedReadReleasesUnderlyingSource() async throws {
        let probe = ByteDemandProbe(limit: 0)
        let pair = AsyncThrowingStream<UInt8, Error>.makeStream()
        let response = makeDemandDrivenHTTPBody(
            bytes: SuspendedProbedBytes(stream: pair.stream, probe: probe), url: "https://example.com/hanging",
            maxBytes: 100, abortSignal: nil,
            cancel: { probe.cancel(); pair.continuation.finish(throwing: CancellationError()) }
        )
        let read = Task {
            for try await _ in response.body {}
        }
        // Cancel an actual suspended source read. Cancelling before iteration
        // begins is short-circuited by AsyncThrowingStream itself.
        for _ in 0..<5_000 where !probe.startedReading {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard probe.startedReading else {
            read.cancel()
            response.cancel()
            Issue.record("Source read did not begin before the timeout")
            return
        }
        read.cancel()
        do { try await read.value } catch is CancellationError {} catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(probe.cancelCount == 1)
    }

    @Test func droppingUnreadBodyReleasesUnderlyingSource() {
        let probe = ByteDemandProbe(limit: 100)
        do {
            let response = makeDemandDrivenHTTPBody(
                bytes: ProbedBytes(probe: probe), url: "https://example.com/drop",
                maxBytes: 100, abortSignal: nil, cancel: { probe.cancel() }
            )
            withExtendedLifetime(response) { #expect(probe.cancelCount == 0) }
        }
        #expect(probe.readCount == 0)
        #expect(probe.cancelCount == 1)
    }
}

private struct ProbedBytes: AsyncSequence {
    typealias Element = UInt8
    let probe: ByteDemandProbe
    func makeAsyncIterator() -> Iterator { Iterator(probe: probe) }
    struct Iterator: AsyncIteratorProtocol {
        let probe: ByteDemandProbe
        mutating func next() async -> UInt8? { probe.read() }
    }
}

private struct SuspendedProbedBytes: AsyncSequence {
    typealias Element = UInt8
    let stream: AsyncThrowingStream<UInt8, Error>
    let probe: ByteDemandProbe
    func makeAsyncIterator() -> Iterator {
        Iterator(source: stream.makeAsyncIterator(), probe: probe)
    }
    struct Iterator: AsyncIteratorProtocol {
        var source: AsyncThrowingStream<UInt8, Error>.Iterator
        let probe: ByteDemandProbe
        mutating func next() async throws -> UInt8? {
            probe.beginRead()
            return try await source.next()
        }
    }
}

private final class ByteDemandProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var reads = 0
    private var cancellations = 0
    private var didBeginReading = false
    init(limit: Int) { self.limit = limit }
    var readCount: Int { lock.withLock { reads } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var startedReading: Bool { lock.withLock { didBeginReading } }
    func beginRead() { lock.withLock { didBeginReading = true } }
    func read() -> UInt8? {
        lock.withLock {
            guard reads < limit else { return nil }
            let result = UInt8(reads % 256)
            reads += 1
            return result
        }
    }
    func cancel() { lock.withLock { cancellations += 1 } }
}
