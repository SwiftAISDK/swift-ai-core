import Foundation
import SwiftAIProvider
import SwiftAITransport


struct StandardizedPrompt: Equatable, Sendable {
    var instructions: [AIMessage]?
    var messages: [AIMessage]
}

func standardizePrompt(
    allowSystemInMessages: Bool = false,
    system: String? = nil,
    instructions: [AIMessage]? = nil,
    prompt: String? = nil,
    messages: [AIMessage]? = nil
) throws -> StandardizedPrompt {
    if prompt == nil && messages == nil {
        throw AIError.invalidArgument(argument: "prompt", message: "prompt or messages must be defined")
    }
    if prompt != nil && messages != nil {
        throw AIError.invalidArgument(argument: "prompt", message: "prompt and messages cannot be defined at the same time")
    }

    let resolvedInstructions = try resolveInstructions(instructions: instructions, system: system)
    let resolvedMessages = messages ?? prompt.map { [.user($0)] } ?? []

    guard !resolvedMessages.isEmpty else {
        throw AIError.invalidArgument(argument: "messages", message: "messages must not be empty")
    }
    if !allowSystemInMessages && resolvedMessages.contains(where: { $0.role == .system }) {
        throw AIError.invalidArgument(
            argument: "messages",
            message: "System messages are not allowed in the prompt or messages fields. Use the instructions option instead."
        )
    }
    if resolvedMessages.contains(where: { $0.role == .system && !isPlainSystemMessage($0) }) {
        throw AIError.invalidArgument(argument: "messages", message: "The messages do not match the ModelMessage[] schema.")
    }

    return StandardizedPrompt(instructions: resolvedInstructions, messages: resolvedMessages)
}

private func resolveInstructions(instructions: [AIMessage]?, system: String?) throws -> [AIMessage]? {
    if let instructions {
        guard instructions.allSatisfy(isPlainSystemMessage) else {
            throw AIError.invalidArgument(
                argument: "instructions",
                message: "instructions must be a string, SystemModelMessage, or array of SystemModelMessage"
            )
        }
        return instructions
    }
    return system.map { [.system($0)] }
}

private func isPlainSystemMessage(_ message: AIMessage) -> Bool {
    message.role == .system && message.content.count == 1 && message.content.first?.text != nil
}