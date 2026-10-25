import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public struct StreamingSpeechSummary: Sendable {
    public var usage: [String: JSONValue]
    public var warnings: [AIWarning]
    public var responses: [AIResponseMetadata]
    public var providerMetadata: [String: JSONValue]
}

/// One pull-based owner consumes the audio, full parts, or final metadata. This
/// result never retains a replay buffer of generated audio.
public struct StreamingSpeechResult: Sendable {
    let engine: SpeechResultEngine
    public var fullStream: StreamingSpeechPartStream { get throws { try engine.claimStream(); return StreamingSpeechPartStream(engine: engine) } }
    public var audioStream: StreamingSpeechAudioStream { get throws { try engine.claimStream(); return StreamingSpeechAudioStream(engine: engine) } }
    public var usage: [String: JSONValue] { get async throws { try await engine.summary().usage } }
    public var warnings: [AIWarning] { get async throws { try await engine.summary().warnings } }
    public var responses: [AIResponseMetadata] { get async throws { try await engine.summary().responses } }
    public var providerMetadata: [String: JSONValue] { get async throws { try await engine.summary().providerMetadata } }
    public func cancel() { engine.cancel() }
}

public struct StreamingSpeechPartStream: AsyncSequence, Sendable {
    public typealias Element = StreamingSpeechPart
    let engine: SpeechResultEngine
    public struct AsyncIterator: AsyncIteratorProtocol {
        let lease: SpeechIteratorLease
        public mutating func next() async throws -> StreamingSpeechPart? { try await lease.engine.next() }
    }
    public func makeAsyncIterator() -> AsyncIterator { .init(lease: SpeechIteratorLease(engine)) }
}

public struct StreamingSpeechAudioStream: AsyncSequence, Sendable {
    public typealias Element = Data
    let engine: SpeechResultEngine
    public struct AsyncIterator: AsyncIteratorProtocol {
        let lease: SpeechIteratorLease
        public mutating func next() async throws -> Data? {
            while let part = try await lease.engine.next() {
                if case let .audio(_, audio, _, _) = part, !audio.isEmpty { return audio }
            }
            return nil
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { .init(lease: SpeechIteratorLease(engine)) }
}

final class SpeechIteratorLease {
    let engine: SpeechResultEngine
    init(_ engine: SpeechResultEngine) { self.engine = engine }
    deinit { engine.cancelIfIncomplete() }
}