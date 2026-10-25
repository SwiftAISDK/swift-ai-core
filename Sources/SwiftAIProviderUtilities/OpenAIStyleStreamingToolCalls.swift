import Foundation
import SwiftAIProvider
import SwiftAITransport


struct OpenAIStyleToolCallBuffer {
    var id: String?
    var name: String?
    var arguments: String = ""
    var inputStarted = false
    var rawValue: JSONValue?
    var providerMetadata: [String: JSONValue] = [:]
    var fallbackIndex: Int
}

public struct OpenAIStyleStreamingToolCalls {
    private let thoughtSignatureNamespace: String?
    private var buffers: [OpenAIStyleToolCallBuffer] = []
    private var positionsByID: [String: Int] = [:]
    private var positionsByIndex: [Int: Int] = [:]
    private var latestPosition: Int?

    public init(thoughtSignatureNamespace: String? = nil) {
        self.thoughtSignatureNamespace = thoughtSignatureNamespace
    }

    public func hasMatchingBuffer(for delta: JSONValue) -> Bool {
        resolvedPosition(for: delta) != nil
    }

    public mutating func apply(delta: JSONValue) -> [LanguageStreamPart] {
        let incomingIndex = delta["index"]?.intValue
        let position = resolvedPosition(for: delta) ?? buffers.endIndex
        if position == buffers.endIndex {
            buffers.append(OpenAIStyleToolCallBuffer(fallbackIndex: incomingIndex ?? position))
        }

        var buffer = buffers[position]
        if let id = delta["id"]?.stringValue, !id.isEmpty {
            buffer.id = id
            positionsByID[id] = position
        }
        if let name = delta["function"]?["name"]?.stringValue, !name.isEmpty {
            buffer.name = name
        }
        let argumentsDelta = delta["function"]?["arguments"]?.stringValue ?? ""
        if !argumentsDelta.isEmpty {
            buffer.arguments += argumentsDelta
        }
        buffer.rawValue = delta
        if let namespace = thoughtSignatureNamespace,
           let thoughtSignature = delta["extra_content"]?["google"]?["thought_signature"]?.stringValue,
           !thoughtSignature.isEmpty {
            buffer.providerMetadata[namespace] = .object([
                "thoughtSignature": .string(thoughtSignature)
            ])
        }

        let id = buffer.id ?? "tool-call-\(buffer.fallbackIndex)"
        var parts: [LanguageStreamPart] = []
        if !buffer.inputStarted, let name = buffer.name {
            parts.append(.toolInputStart(id: id, name: name))
            buffer.inputStarted = true
        }
        parts.append(.toolCallDelta(
            id: buffer.id,
            name: buffer.name,
            argumentsDelta: argumentsDelta,
            index: incomingIndex
        ))
        if !argumentsDelta.isEmpty, buffer.inputStarted {
            parts.append(.toolInputDelta(id: id, delta: argumentsDelta))
        }
        buffers[position] = buffer
        if let incomingIndex {
            positionsByIndex[incomingIndex] = position
        }
        latestPosition = position
        return parts
    }

    public mutating func finishedParts() -> [LanguageStreamPart] {
        var parts: [LanguageStreamPart] = []
        for position in buffers.indices {
            var buffer = buffers[position]
            guard let name = buffer.name else { continue }
            let id = buffer.id ?? "tool-call-\(buffer.fallbackIndex)"
            if !buffer.inputStarted {
                parts.append(.toolInputStart(id: id, name: name))
                buffer.inputStarted = true
                buffers[position] = buffer
            }
            parts.append(.toolInputEnd(id: id))
            parts.append(.toolCall(AIToolCall(
                id: id,
                name: name,
                arguments: buffer.arguments,
                providerMetadata: buffer.providerMetadata,
                rawValue: buffer.rawValue
            )))
        }
        return parts
    }

    private func resolvedPosition(for delta: JSONValue) -> Int? {
        if let id = delta["id"]?.stringValue, !id.isEmpty {
            return positionsByID[id]
        }
        if let index = delta["index"]?.intValue {
            return positionsByIndex[index]
        }
        return latestPosition
    }
}