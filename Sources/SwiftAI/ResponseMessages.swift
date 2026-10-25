import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public func toResponseMessages(
    content: [AIContentPart],
    toolsByName: [String: AITool] = [:]
) async throws -> [AIMessage] {
    var assistantParts: [AIContentPart] = []
    var toolParts: [AIContentPart] = []
    var toolCallsByID: [String: AIToolCall] = [:]
    var toolCallOrderByID: [String: Int] = [:]
    var approvalRequestsByID: [String: AIToolApprovalRequest] = [:]
    let explicitToolResultIDs = Set(content.compactMap { part -> String? in
        if case let .toolResult(result) = part {
            return result.toolCallID
        }
        return nil
    })

    for part in content {
        switch part {
        case let .text(text, _) where text.isEmpty:
            continue
        case let .reasoning(text, _) where text.isEmpty:
            continue
        case let .toolCall(call):
            if toolCallOrderByID[call.id] == nil {
                toolCallOrderByID[call.id] = toolCallOrderByID.count
            }
            toolCallsByID[call.id] = call
            assistantParts.append(.toolCall(sanitizedToolCall(call)))
        case let .toolApprovalRequest(request):
            approvalRequestsByID[request.id] = request
            assistantParts.append(part)
        case let .toolApprovalResponse(response):
            toolParts.append(part)
            if !response.approved,
               let request = approvalRequestsByID[response.id],
               let toolCallID = request.toolCallID,
               !explicitToolResultIDs.contains(toolCallID) {
                toolParts.append(.toolResult(AIToolResult(
                    toolCallID: toolCallID,
                    toolName: request.toolName,
                    result: executionDeniedResult(reason: response.reason),
                    providerMetadata: response.providerMetadata
                )))
            }
        case let .toolResult(result):
            let providerExecuted = result.providerExecuted || (toolCallsByID[result.toolCallID]?.providerExecuted ?? false)
            let messagePart = try await responseToolResultPart(
                result,
                toolCall: toolCallsByID[result.toolCallID],
                toolsByName: toolsByName
            )
            if providerExecuted {
                assistantParts.append(messagePart)
            } else {
                toolParts.append(messagePart)
            }
        default:
            assistantParts.append(part)
        }
    }

    var messages: [AIMessage] = []
    if !assistantParts.isEmpty {
        messages.append(AIMessage(role: .assistant, content: assistantParts))
    }
    if !toolParts.isEmpty {
        messages.append(AIMessage(
            role: .tool,
            content: sortToolResultsByToolCallOrder(toolParts, orderByToolCallID: toolCallOrderByID)
        ))
    }
    return messages
}

private func sortToolResultsByToolCallOrder(
    _ parts: [AIContentPart],
    orderByToolCallID: [String: Int]
) -> [AIContentPart] {
    let sortedResults = parts.enumerated().compactMap { index, part -> (index: Int, part: AIContentPart, order: Int?)? in
        guard case let .toolResult(result) = part else { return nil }
        return (index, part, orderByToolCallID[result.toolCallID])
    }
    .sorted { lhs, rhs in
        switch (lhs.order, rhs.order) {
        case let (lhsOrder?, rhsOrder?):
            return lhsOrder == rhsOrder ? lhs.index < rhs.index : lhsOrder < rhsOrder
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.index < rhs.index
        }
    }

    guard !sortedResults.isEmpty else { return parts }

    var resultIndex = 0
    return parts.map { part in
        guard case .toolResult = part else { return part }
        defer { resultIndex += 1 }
        return sortedResults[resultIndex].part
    }
}

private func sanitizedToolCall(_ call: AIToolCall) -> AIToolCall {
    guard let input = try? toolArguments(from: call),
          case .object = input else {
        var sanitized = call
        sanitized.arguments = "{}"
        return sanitized
    }
    return call
}

private func responseToolResultPart(
    _ result: AIToolResult,
    toolCall: AIToolCall?,
    toolsByName: [String: AITool]
) async throws -> AIContentPart {
    guard result.modelOutput == nil,
          let tool = toolsByName[result.toolName] else {
        return .toolResult(result)
    }
    let input: JSONValue
    if let toolCall {
        input = (try? toolArguments(from: toolCall)) ?? .object([:])
    } else {
        input = .object([:])
    }
    var converted = result
    converted.modelOutput = try await tool.toModelOutput?(AIToolModelOutputContext(
        toolCallID: result.toolCallID,
        input: input,
        output: result.result
    ))
    return .toolResult(converted)
}