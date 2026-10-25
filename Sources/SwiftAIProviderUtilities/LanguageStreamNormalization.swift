import Foundation
import SwiftAIProvider
import SwiftAITransport


private enum LanguageStreamRepresentation: String, Sendable {
    case legacy
    case canonical
}

private enum OpenLanguageStreamPartKind: Equatable, Sendable {
    case text
    case reasoning
    case toolInput
}

private struct OpenLanguageStreamPart: Sendable {
    var kind: OpenLanguageStreamPartKind
    var id: String
    var providerMetadata: [String: JSONValue]
}

/// Converts the pre-lifecycle language stream cases into the canonical
/// start/delta/end representation at SDK compatibility boundaries.
///
/// Representation is tracked independently for text, reasoning, and terminal
/// chunks. A model may use a legacy text channel together with a canonical
/// terminal, but it may not mix legacy and canonical chunks in the same
/// channel. This deliberately validates representation, not chunk values, so
/// equal legacy and canonical deltas are never mistaken for deduplication.
public struct LanguageStreamNormalizer: Sendable {
    private let providerID: String
    private var textRepresentation: LanguageStreamRepresentation?
    private var reasoningRepresentation: LanguageStreamRepresentation?
    private var terminalRepresentation: LanguageStreamRepresentation?
    private var legacyTextID: String?
    private var legacyReasoningID: String?
    private var nextLegacyTextID = 0
    private var nextLegacyReasoningID = 0
    private var terminalSeenInLifecycle = false
    private var openParts: [OpenLanguageStreamPart] = []

    public init(providerID: String) {
        self.providerID = providerID
    }

    public mutating func normalize(_ part: LanguageStreamPart) throws -> [LanguageStreamPart] {
        var output: [LanguageStreamPart] = []

        if beginsLogicalLifecycle(part), terminalSeenInLifecycle {
            output.append(contentsOf: closeOpenParts())
            resetLifecycleRepresentations()
        }

        switch part {
        case let .textDelta(delta):
            textRepresentation = try selected(.legacy, current: textRepresentation, channel: "text")
            let id: String
            if let legacyTextID {
                id = legacyTextID
            } else {
                id = "legacy-text-\(nextLegacyTextID)"
                nextLegacyTextID += 1
                legacyTextID = id
                output.append(.textStart(id: id))
                open(.text, id: id)
            }
            output.append(.textDeltaPart(id: id, delta: delta))

        case let .textStart(id, providerMetadata):
            textRepresentation = try selected(.canonical, current: textRepresentation, channel: "text")
            open(.text, id: id, providerMetadata: providerMetadata)
            output.append(part)

        case .textDeltaPart:
            textRepresentation = try selected(.canonical, current: textRepresentation, channel: "text")
            output.append(part)

        case let .textEnd(id, _), let .textEndWithCitations(id, _, _):
            textRepresentation = try selected(.canonical, current: textRepresentation, channel: "text")
            close(.text, id: id)
            output.append(part)

        case let .reasoningDelta(delta):
            reasoningRepresentation = try selected(.legacy, current: reasoningRepresentation, channel: "reasoning")
            let id: String
            if let legacyReasoningID {
                id = legacyReasoningID
            } else {
                id = "legacy-reasoning-\(nextLegacyReasoningID)"
                nextLegacyReasoningID += 1
                legacyReasoningID = id
                output.append(.reasoningStart(id: id))
                open(.reasoning, id: id)
            }
            output.append(.reasoningDeltaPart(id: id, delta: delta))

        case let .reasoningStart(id, providerMetadata):
            reasoningRepresentation = try selected(.canonical, current: reasoningRepresentation, channel: "reasoning")
            open(.reasoning, id: id, providerMetadata: providerMetadata)
            output.append(part)

        case .reasoningDeltaPart:
            reasoningRepresentation = try selected(.canonical, current: reasoningRepresentation, channel: "reasoning")
            output.append(part)

        case let .reasoningEnd(id, _):
            reasoningRepresentation = try selected(.canonical, current: reasoningRepresentation, channel: "reasoning")
            close(.reasoning, id: id)
            output.append(part)

        case let .toolInputStart(id, _, _, _, _, providerMetadata),
             let .toolInputStartText(id, _, _, _, _, providerMetadata):
            open(.toolInput, id: id, providerMetadata: providerMetadata)
            output.append(part)

        case let .toolInputEnd(id, _):
            close(.toolInput, id: id)
            output.append(part)

        case let .finish(reason, usage):
            try requireUnfinishedLifecycle()
            terminalRepresentation = try selected(.legacy, current: terminalRepresentation, channel: "terminal")
            output.append(contentsOf: closeOpenParts())
            output.append(.finishMetadata(reason: reason, usage: usage, providerMetadata: [:]))
            terminalSeenInLifecycle = true

        case .finishMetadata:
            try requireUnfinishedLifecycle()
            terminalRepresentation = try selected(.canonical, current: terminalRepresentation, channel: "terminal")
            output.append(contentsOf: closeOpenParts())
            output.append(part)
            terminalSeenInLifecycle = true

        default:
            output.append(part)
        }

        return output
    }

    public mutating func finish() -> [LanguageStreamPart] {
        closeOpenParts()
    }

    private func selected(
        _ representation: LanguageStreamRepresentation,
        current: LanguageStreamRepresentation?,
        channel: String
    ) throws -> LanguageStreamRepresentation {
        if let current, current != representation {
            throw AIError.invalidResponse(
                provider: providerID,
                message: "Language stream mixed legacy and canonical \(channel) chunks. Emit exactly one representation per channel."
            )
        }
        return representation
    }

    private func requireUnfinishedLifecycle() throws {
        guard !terminalSeenInLifecycle else {
            throw AIError.invalidResponse(
                provider: providerID,
                message: "Language stream emitted more than one terminal chunk for a single logical response."
            )
        }
    }

    private mutating func open(
        _ kind: OpenLanguageStreamPartKind,
        id: String,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        guard !openParts.contains(where: { $0.kind == kind && $0.id == id }) else { return }
        openParts.append(OpenLanguageStreamPart(kind: kind, id: id, providerMetadata: providerMetadata))
    }

    private mutating func close(_ kind: OpenLanguageStreamPartKind, id: String) {
        openParts.removeAll { $0.kind == kind && $0.id == id }
        if kind == .text, legacyTextID == id {
            legacyTextID = nil
        } else if kind == .reasoning, legacyReasoningID == id {
            legacyReasoningID = nil
        }
    }

    private mutating func closeOpenParts() -> [LanguageStreamPart] {
        let output = openParts.map { part -> LanguageStreamPart in
            switch part.kind {
            case .text:
                return .textEnd(id: part.id, providerMetadata: part.providerMetadata)
            case .reasoning:
                return .reasoningEnd(id: part.id, providerMetadata: part.providerMetadata)
            case .toolInput:
                return .toolInputEnd(id: part.id, providerMetadata: part.providerMetadata)
            }
        }
        openParts.removeAll()
        legacyTextID = nil
        legacyReasoningID = nil
        return output
    }

    private mutating func resetLifecycleRepresentations() {
        textRepresentation = nil
        reasoningRepresentation = nil
        terminalRepresentation = nil
        terminalSeenInLifecycle = false
        openParts.removeAll()
    }

    private func beginsLogicalLifecycle(_ part: LanguageStreamPart) -> Bool {
        switch part {
        case .streamStart, .responseMetadata, .textStart, .textDelta,
             .reasoningStart, .reasoningDelta, .toolInputStart, .toolInputStartText:
            return true
        default:
            return false
        }
    }
}

package func canonicalLanguageStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    providerID: String
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var normalizer = LanguageStreamNormalizer(providerID: providerID)
            do {
                for try await part in stream {
                    try Task.checkCancellation()
                    for normalizedPart in try normalizer.normalize(part) {
                        continuation.yield(normalizedPart)
                    }
                }
                for normalizedPart in normalizer.finish() {
                    continuation.yield(normalizedPart)
                }
                continuation.finish()
            } catch {
                for normalizedPart in normalizer.finish() {
                    continuation.yield(normalizedPart)
                }
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}