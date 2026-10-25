import Foundation
import SwiftAIProvider
import SwiftAITransport


package func prepareLanguageModelCallOptions(_ request: LanguageModelRequest) throws -> LanguageModelRequest {
    if let maxOutputTokens = request.maxOutputTokens, maxOutputTokens < 1 {
        throw AIError.invalidArgument(argument: "maxOutputTokens", message: "maxOutputTokens must be >= 1")
    }
    if let concurrency = request.toolCallConcurrency, concurrency < 1 {
        throw AIError.invalidArgument(argument: "toolCallConcurrency", message: "toolCallConcurrency must be >= 1")
    }
    var prepared = request
    prepared.messages = try convertToLanguageModelPrompt(StandardizedPrompt(messages: request.messages))
    return prepared
}

func validateToolResultAvailability(
    in messages: [AIMessage],
    preapprovedToolCallIDs: Set<String> = []
) throws {
    var missingToolCallIDs: [String] = []
    var pendingToolCallIDs: Set<String> = []

    for message in messages {
        switch message.role {
        case .assistant:
            for part in message.content {
                guard case let .toolCall(call) = part, !call.providerExecuted else { continue }
                if pendingToolCallIDs.insert(call.id).inserted {
                    missingToolCallIDs.append(call.id)
                }
            }
        case .tool:
            for part in message.content {
                guard case let .toolResult(result) = part else { continue }
                missingToolCallIDs.removeAll { $0 == result.toolCallID }
                pendingToolCallIDs.remove(result.toolCallID)
            }
        case .user, .system:
            if !missingToolCallIDs.isEmpty {
                throw AIMissingToolResultsError(toolCallIDs: missingToolCallIDs)
            }
        }
    }

    if !missingToolCallIDs.isEmpty {
        throw AIMissingToolResultsError(toolCallIDs: missingToolCallIDs)
    }
}