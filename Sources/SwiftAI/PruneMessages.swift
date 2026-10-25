import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public enum AIPruneReasoning: Equatable, Hashable, Sendable {
    case none
    case all
    case beforeLastMessage
}

public enum AIPruneEmptyMessages: Equatable, Hashable, Sendable {
    case keep
    case remove
}

public struct AIPruneToolCalls: Equatable, Hashable, Sendable {
    public enum Scope: Equatable, Hashable, Sendable {
        case all
        case beforeLastMessages(Int)
    }

    public var scope: Scope
    public var tools: Set<String>?

    public init(scope: Scope, tools: Set<String>? = nil) {
        self.scope = scope
        self.tools = tools
    }

    public static func all(tools: Set<String>? = nil) -> AIPruneToolCalls {
        AIPruneToolCalls(scope: .all, tools: tools)
    }

    public static func beforeLastMessage(tools: Set<String>? = nil) -> AIPruneToolCalls {
        AIPruneToolCalls(scope: .beforeLastMessages(1), tools: tools)
    }

    public static func beforeLastMessages(_ count: Int, tools: Set<String>? = nil) -> AIPruneToolCalls {
        AIPruneToolCalls(scope: .beforeLastMessages(count), tools: tools)
    }
}

public func pruneMessages(
    _ messages: [AIMessage],
    reasoning: AIPruneReasoning = .none,
    toolCalls: [AIPruneToolCalls] = [],
    emptyMessages: AIPruneEmptyMessages = .remove
) -> [AIMessage] {
    var messages = messages

    switch reasoning {
    case .none:
        break
    case .all, .beforeLastMessage:
        messages = messages.enumerated().map { index, message in
            guard message.role == .assistant,
                  reasoning != .beforeLastMessage || index != messages.count - 1 else {
                return message
            }
            var output = message
            output.reasoning = nil
            output.content = message.content.filter { part in
                switch part {
                case .reasoning, .reasoningFile:
                    false
                default:
                    true
                }
            }
            return output
        }
    }

    for setting in toolCalls {
        messages = pruneToolCalls(messages, setting: setting)
    }

    if emptyMessages == .remove {
        messages = messages.filter { !$0.isEmptyAfterPruning }
    }

    return messages
}

private func pruneToolCalls(_ messages: [AIMessage], setting: AIPruneToolCalls) -> [AIMessage] {
    let keepLastMessagesCount: Int?
    switch setting.scope {
    case .all:
        keepLastMessagesCount = nil
    case let .beforeLastMessages(count):
        keepLastMessagesCount = max(count, 0)
    }

    var keptToolCallIDs = Set<String>()
    var keptApprovalIDs = Set<String>()
    if let keepLastMessagesCount {
        for message in messages.suffix(keepLastMessagesCount) where message.role == .assistant || message.role == .tool {
            for part in message.content {
                switch part {
                case let .toolCall(call):
                    keptToolCallIDs.insert(call.id)
                case let .toolResult(result):
                    keptToolCallIDs.insert(result.toolCallID)
                case let .toolApprovalRequest(request):
                    keptApprovalIDs.insert(request.id)
                case let .toolApprovalResponse(response):
                    keptApprovalIDs.insert(response.id)
                case .text, .reasoning, .reasoningFile, .custom, .imageURL, .data, .file, .providerReference:
                    break
                }
            }
        }
    }

    // A retained approval response is only useful together with the approval
    // request and tool call that originated it, even when they fall before the
    // pruning boundary.
    var approvalIDToToolCallID: [String: String] = [:]
    for message in messages where message.role == .assistant {
        for part in message.content {
            guard case let .toolApprovalRequest(request) = part,
                  let toolCallID = request.toolCallID else {
                continue
            }
            approvalIDToToolCallID[request.id] = toolCallID
        }
    }
    for approvalID in keptApprovalIDs {
        if let toolCallID = approvalIDToToolCallID[approvalID] {
            keptToolCallIDs.insert(toolCallID)
        }
    }

    var toolCallIDToToolName: [String: String] = [:]
    for message in messages where message.role == .assistant || message.role == .tool {
        for part in message.content {
            switch part {
            case let .toolCall(call):
                toolCallIDToToolName[call.id] = call.name
            case let .toolResult(result):
                toolCallIDToToolName[result.toolCallID] = result.toolName
            case .text, .reasoning, .reasoningFile, .custom, .imageURL, .data, .file, .providerReference, .toolApprovalRequest, .toolApprovalResponse:
                break
            }
        }
    }

    var approvalIDToToolName: [String: String] = [:]
    for message in messages where message.role == .assistant || message.role == .tool {
        for part in message.content {
            if case let .toolApprovalRequest(request) = part {
                let toolName = request.toolCallID.flatMap { toolCallIDToToolName[$0] } ?? request.toolName
                approvalIDToToolName[request.id] = toolName
            }
        }
    }

    return messages.enumerated().map { index, message in
        guard message.role == .assistant || message.role == .tool else {
            return message
        }
        if let keepLastMessagesCount, index >= messages.count - keepLastMessagesCount {
            return message
        }

        var output = message
        var keepParts = message.content.map { part in
            switch part {
            case .text, .reasoning, .reasoningFile, .custom, .imageURL, .data, .file, .providerReference:
                return true
            case let .toolCall(call):
                if keptToolCallIDs.contains(call.id) {
                    return true
                }
                return shouldKeepToolPart(toolName: call.name, tools: setting.tools)
            case let .toolResult(result):
                if keptToolCallIDs.contains(result.toolCallID) {
                    return true
                }
                return shouldKeepToolPart(toolName: result.toolName, tools: setting.tools)
            case let .toolApprovalRequest(request):
                if keptApprovalIDs.contains(request.id) {
                    return true
                }
                return shouldKeepToolPart(toolName: approvalIDToToolName[request.id], tools: setting.tools)
            case let .toolApprovalResponse(response):
                if keptApprovalIDs.contains(response.id) {
                    return true
                }
                return shouldKeepToolPart(toolName: approvalIDToToolName[response.id], tools: setting.tools)
            }
        }
        if message.role == .assistant {
            var index = 0
            while index < message.content.count {
                guard isPrunableReasoning(message.content[index]) else { index += 1; continue }
                let start = index
                while index < message.content.count && isPrunableReasoning(message.content[index]) { index += 1 }
                let end = index
                while index < message.content.count && !isPrunableReasoning(message.content[index]) { index += 1 }
                if end < index && !keepParts[end..<index].contains(true) {
                    for reasoningIndex in start..<end { keepParts[reasoningIndex] = false }
                }
            }
            // The native shorthand reasoning field precedes all content.
            if !message.content.isEmpty && !keepParts.contains(true) { output.reasoning = nil }
        }
        output.content = message.content.enumerated().compactMap { keepParts[$0.offset] ? $0.element : nil }
        return output
    }
}

private func isPrunableReasoning(_ part: AIContentPart) -> Bool {
    switch part {
    case .reasoning, .reasoningFile: return true
    default: return false
    }
}

private func shouldKeepToolPart(toolName: String?, tools: Set<String>?) -> Bool {
    guard let tools else { return false }
    guard let toolName else { return false }
    return !tools.contains(toolName)
}

private extension AIMessage {
    var isEmptyAfterPruning: Bool {
        content.isEmpty && (reasoning == nil || reasoning?.isEmpty == true)
    }
}
