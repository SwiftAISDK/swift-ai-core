import Foundation
import SwiftAIProvider
import SwiftAITransport


public enum AIStreamingToolCallTypeValidation: Sendable {
    case none
    case ifPresent
    case required
}

public struct AIStreamingToolCallDelta: Equatable, Sendable {
    public var index: Int?
    public var id: String?
    public var type: String?
    public var functionName: String?
    public var arguments: String?
    public var rawValue: JSONValue?

    public init(
        index: Int? = nil,
        id: String? = nil,
        type: String? = nil,
        functionName: String? = nil,
        arguments: String? = nil,
        rawValue: JSONValue? = nil
    ) {
        self.index = index
        self.id = id
        self.type = type
        self.functionName = functionName
        self.arguments = arguments
        self.rawValue = rawValue
    }
}

public struct AIStreamingToolCallTracker: Sendable {
    public var generateID: @Sendable () -> String
    public var typeValidation: AIStreamingToolCallTypeValidation
    public var extractMetadata: (@Sendable (AIStreamingToolCallDelta) -> [String: JSONValue]?)?
    public var buildToolCallProviderMetadata: (@Sendable ([String: JSONValue]?) -> [String: JSONValue]?)?

    private var toolCalls: [TrackedStreamingToolCall] = []
    private var toolCallPositionsByID: [String: [Int]] = [:]
    private var toolCallPositionsByIndex: [Int: [Int]] = [:]
    private var usedToolCallIDs: Set<String> = []
    private var nextGeneratedIDSuffixes: [String: Int] = [:]

    public init(
        generateID: @escaping @Sendable () -> String = { UUID().uuidString },
        typeValidation: AIStreamingToolCallTypeValidation = .none,
        extractMetadata: (@Sendable (AIStreamingToolCallDelta) -> [String: JSONValue]?)? = nil,
        buildToolCallProviderMetadata: (@Sendable ([String: JSONValue]?) -> [String: JSONValue]?)? = nil
    ) {
        self.generateID = generateID
        self.typeValidation = typeValidation
        self.extractMetadata = extractMetadata
        self.buildToolCallProviderMetadata = buildToolCallProviderMetadata
    }

    public mutating func processDelta(_ delta: AIStreamingToolCallDelta) throws -> [LanguageStreamPart] {
        let wireID = nonBlank(delta.id)
        let name = nonBlank(delta.functionName)
        let hasExplicitStart = name != nil && delta.arguments?.first(where: { !$0.isWhitespace }).map { $0 == "{" || $0 == "[" } == true
        let hasEmptyArguments = delta.arguments?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let resolution = resolve(wireID: wireID, index: delta.index, name: name, hasExplicitStart: hasExplicitStart, hasEmptyArguments: hasEmptyArguments)
        let resolvedPosition: Int
        let parts: [LanguageStreamPart]
        switch resolution {
        case .ambiguous:
            return []
        case .existing(let position):
            resolvedPosition = position
            if let wireID { associate(position, withID: wireID) }
            parts = processExistingToolCall(position: position, delta: delta)
        case .new:
            if delta.functionName != nil && name == nil { return [] }
            let created = try processNewToolCall(delta: delta, wireID: wireID, name: name)
            resolvedPosition = created.position
            parts = created.parts
        }

        if let index = delta.index {
            if !toolCallPositionsByIndex[index, default: []].contains(resolvedPosition) {
                toolCallPositionsByIndex[index, default: []].append(resolvedPosition)
            }
        }
        return parts
    }

    public mutating func flush() -> [LanguageStreamPart] {
        var parts: [LanguageStreamPart] = []
        let positions = toolCalls.allSatisfy { $0.index != nil }
            ? toolCalls.indices.sorted { toolCalls[$0].index == toolCalls[$1].index ? $0 < $1 : toolCalls[$0].index! < toolCalls[$1].index! }
            : Array(toolCalls.indices)
        for position in positions where !toolCalls[position].hasFinished {
            parts.append(contentsOf: finishToolCall(position: position))
        }
        return parts
    }

    private enum Resolution { case new, existing(Int), ambiguous }

    private func resolve(wireID: String?, index: Int?, name: String?, hasExplicitStart: Bool, hasEmptyArguments: Bool) -> Resolution {
        let indexed = index.flatMap { toolCallPositionsByIndex[$0] }
        let matchingIndexed = (indexed ?? []).filter { name == nil || toolCalls[$0].name == name }
        if let wireID {
            if let byID = toolCallPositionsByID[wireID] {
                if index != nil {
                    let matching = matchingIndexed.filter { byID.contains($0) }
                    let result = resolveMatching(matching, hasExplicitStart: hasExplicitStart)
                    if case .new = result {} else { return result }
                    if name != nil { return .new }
                    if indexed != nil { return .ambiguous }
                    return resolveMatching(byID, hasExplicitStart: false)
                }
                return resolveMatching(byID.filter { name == nil || toolCalls[$0].name == name }, hasExplicitStart: name != nil && hasExplicitStart)
            }
            if !matchingIndexed.isEmpty {
                return hasExplicitStart ? .new : resolveMatching(matchingIndexed, hasExplicitStart: name != nil && hasEmptyArguments)
            }
            return .new
        }
        if indexed != nil { return resolveMatching(matchingIndexed, hasExplicitStart: hasExplicitStart) }
        if name != nil { return .new }
        let unfinished = toolCalls.indices.filter { !toolCalls[$0].hasFinished }
        return resolveMatching(unfinished, hasExplicitStart: false)
    }

    private func resolveMatching(_ positions: [Int], hasExplicitStart: Bool) -> Resolution {
        if positions.isEmpty { return .new }
        if !hasExplicitStart && positions.count == 1 { return .existing(positions[0]) }
        let candidates = positions.filter { !toolCalls[$0].argumentState.complete }
        if candidates.count == 1 { return .existing(candidates[0]) }
        if candidates.count > 1 || !hasExplicitStart { return .ambiguous }
        return .new
    }

    private func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private mutating func associate(_ position: Int, withID id: String) {
        if !toolCallPositionsByID[id, default: []].contains(position) {
            toolCallPositionsByID[id, default: []].append(position)
        }
    }

    private mutating func createID(_ wireID: String?) -> String {
        if let wireID, usedToolCallIDs.insert(wireID).inserted { return wireID }
        let generated = nonBlank(generateID()) ?? "tool-call"
        if usedToolCallIDs.insert(generated).inserted { return generated }
        let initial = nextGeneratedIDSuffixes[generated] ?? 1
        for suffix in initial...(initial + usedToolCallIDs.count) {
            let candidate = "\(generated)-\(suffix)"
            if usedToolCallIDs.insert(candidate).inserted {
                nextGeneratedIDSuffixes[generated] = suffix + 1
                return candidate
            }
        }
        preconditionFailure("Failed to create a unique tool call ID.")
    }

    private mutating func processNewToolCall(delta: AIStreamingToolCallDelta, wireID: String?, name: String?) throws -> (position: Int, parts: [LanguageStreamPart]) {
        switch typeValidation {
        case .required:
            guard delta.type == "function" else {
                throw AIError.invalidResponse(provider: "provider-utils", message: "Expected 'function' type.")
            }
        case .ifPresent:
            guard delta.type == nil || delta.type == "function" else {
                throw AIError.invalidResponse(provider: "provider-utils", message: "Expected 'function' type.")
            }
        case .none:
            break
        }

        guard let name else {
            throw AIError.invalidResponse(provider: "provider-utils", message: "Expected 'function.name' to be a string.")
        }

        let arguments = delta.arguments ?? ""
        let id = createID(wireID)
        var argumentState = StreamingToolArgumentState()
        argumentState.append(arguments)
        let metadata = extractMetadata?(delta)
        let toolCall = TrackedStreamingToolCall(
            id: id,
            index: delta.index,
            name: name,
            arguments: arguments,
            argumentState: argumentState,
            hasFinished: false,
            metadata: metadata,
            rawValue: delta.rawValue
        )
        let position = toolCalls.endIndex
        toolCalls.append(toolCall)
        if let wireID { associate(position, withID: wireID) }

        var parts: [LanguageStreamPart] = [
            .toolInputStart(id: id, name: name)
        ]
        if !arguments.isEmpty {
            parts.append(.toolInputDelta(id: id, delta: arguments))
        }
        return (position, parts)
    }

    private mutating func processExistingToolCall(position: Int, delta: AIStreamingToolCallDelta) -> [LanguageStreamPart] {
        guard toolCalls.indices.contains(position), !toolCalls[position].hasFinished else {
            return []
        }

        guard let arguments = delta.arguments else {
            return []
        }
        toolCalls[position].arguments += arguments
        toolCalls[position].argumentState.append(arguments)
        toolCalls[position].rawValue = delta.rawValue ?? toolCalls[position].rawValue
        return [.toolInputDelta(id: toolCalls[position].id, delta: arguments)]
    }

    private mutating func finishToolCall(position: Int) -> [LanguageStreamPart] {
        let toolCall = toolCalls[position]
        toolCalls[position].hasFinished = true

        let providerMetadata = buildToolCallProviderMetadata?(toolCall.metadata) ?? [:]
        return [
            .toolInputEnd(id: toolCall.id),
            .toolCall(AIToolCall(
                id: toolCall.id,
                name: toolCall.name,
                arguments: toolCall.arguments,
                providerMetadata: providerMetadata,
                rawValue: toolCall.rawValue
            ))
        ]
    }
}

private struct TrackedStreamingToolCall: Sendable {
    var id: String
    var index: Int?
    var name: String
    var arguments: String
    var argumentState: StreamingToolArgumentState
    var hasFinished: Bool
    var metadata: [String: JSONValue]?
    var rawValue: JSONValue?
}

/// Structural completeness is only correlation evidence. Calls still finish on
/// flush because even parsable JSON may be followed by more argument text.
private struct StreamingToolArgumentState: Sendable {
    var complete = false
    private var started = false
    private var invalid = false
    private var stack: [Character] = []
    private var inString = false
    private var escaped = false

    mutating func append(_ delta: String) {
        for character in delta {
            if invalid || complete { continue }
            if !started {
                if character.isWhitespace { continue }
                guard character == "{" || character == "[" else { invalid = true; continue }
                started = true
                stack.append(character)
            } else if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "[" {
                stack.append(character)
            } else if character == "}" || character == "]" {
                guard stack.last == (character == "}" ? "{" : "[") else { invalid = true; continue }
                stack.removeLast()
                complete = stack.isEmpty
            }
        }
    }
}