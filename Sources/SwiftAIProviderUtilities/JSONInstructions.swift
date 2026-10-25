import Foundation
import SwiftAIProvider
import SwiftAITransport



public func injectJSONInstruction(
    into messages: [AIMessage],
    schema: JSONValue?,
    instruction: AIJSONInstruction
) -> [AIMessage] {
    let existingSystemText: String?
    let tail: ArraySlice<AIMessage>
    if let first = messages.first, first.role == .system {
        existingSystemText = first.combinedText
        tail = messages.dropFirst()
    } else {
        existingSystemText = nil
        tail = messages[...]
    }

    let injected = jsonInstructionText(
        prompt: existingSystemText,
        schema: schema,
        instruction: instruction
    )
    return [AIMessage.system(injected)] + Array(tail)
}


func jsonInstructionText(
    prompt: String?,
    schema: JSONValue?,
    instruction: AIJSONInstruction
) -> String {
    let schemaPrefix = instruction.schemaPrefix ?? (schema == nil ? nil : "JSON schema:")
    let schemaSuffix = instruction.schemaSuffix ?? (schema == nil
        ? "You MUST answer with JSON."
        : "You MUST answer with a JSON object that matches the JSON schema above.")
    let promptValue = prompt?.isEmpty == false ? prompt : nil
    let schemaText = schema.flatMap(canonicalJSONText)

    return [
        promptValue,
        promptValue == nil ? nil : "",
        schemaPrefix,
        schemaText,
        schemaSuffix
    ]
    .compactMap { $0 }
    .joined(separator: "\n")
}


public func canonicalJSONText(_ value: JSONValue) -> String? {
    guard let data = try? encodeJSONBody(value) else { return nil }
    return String(data: data, encoding: .utf8)
}
