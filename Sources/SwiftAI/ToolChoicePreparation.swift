import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


/// Raised when a provider response does not satisfy an enforced tool choice.
public struct AIToolChoiceViolationError: Error, CustomStringConvertible, Sendable {
    public var toolChoice: JSONValue
    public var finishReason: String?
    public var providerID: String
    public var modelID: String
    public var content: [AIResultContentPart]

    public init(
        toolChoice: JSONValue,
        finishReason: String?,
        providerID: String,
        modelID: String,
        content: [AIResultContentPart]
    ) {
        self.toolChoice = toolChoice
        self.finishReason = finishReason
        self.providerID = providerID
        self.modelID = modelID
        self.content = content
    }

    public var description: String {
        let choice = prepareToolChoice(toolChoice)
        if choice["type"]?.stringValue == "none" {
            return "Model response contained a tool call even though tool choice was none."
        }
        if choice["type"]?.stringValue == "tool" {
            let name = choice["toolName"]?.stringValue ?? ""
            return "Model response did not contain a call to the required tool '\(name)'."
        }
        return "Model response did not contain a tool call even though tool choice was required."
    }
}

func prepareToolChoice(_ toolChoice: JSONValue?) -> JSONValue {
    guard let toolChoice else {
        return ["type": "auto"]
    }
    if let string = toolChoice.stringValue {
        return ["type": .string(string)]
    }
    if let type = toolChoice["type"]?.stringValue {
        switch type {
        case "auto", "none", "required":
            return ["type": .string(type)]
        case "tool":
            var output: [String: JSONValue] = ["type": "tool"]
            if let toolName = toolChoice["toolName"] ?? toolChoice["name"] {
                output["toolName"] = toolName
            }
            return .object(output)
        default:
            return toolChoice
        }
    }
    var output: [String: JSONValue] = ["type": "tool"]
    if let toolName = toolChoice["toolName"] ?? toolChoice["name"] {
        output["toolName"] = toolName
    }
    return .object(output)
}

func validateEnforcedToolChoice(
    _ toolChoice: JSONValue?,
    result: TextGenerationResult,
    providerID: String,
    modelID: String
) throws {
    let prepared = prepareToolChoice(toolChoice)
    switch prepared["type"]?.stringValue {
    case "none":
        guard !result.toolCalls.isEmpty else { return }
    case "required":
        guard result.finishReason != "interrupted" else { return }
        guard result.toolCalls.isEmpty else { return }
    case "tool":
        guard result.finishReason != "interrupted" else { return }
        guard let requiredName = prepared["toolName"]?.stringValue,
              !result.toolCalls.contains(where: { $0.name == requiredName }) else {
            return
        }
    default:
        return
    }
    throw AIToolChoiceViolationError(
        toolChoice: prepared,
        finishReason: result.finishReason,
        providerID: providerID,
        modelID: modelID,
        content: result.content
    )
}