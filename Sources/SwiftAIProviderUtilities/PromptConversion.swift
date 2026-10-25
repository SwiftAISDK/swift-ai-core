import Foundation
import SwiftAIProvider
import SwiftAITransport


package func downloadUnsupportedPromptAssets(
    in request: LanguageModelRequest,
    supportedURLs: [String: [AISupportedURLPattern]],
    transport: any AITransport = URLSessionTransport.shared
) async throws -> LanguageModelRequest {
    var output = request

    for messageIndex in output.messages.indices where output.messages[messageIndex].role == .user {
        for partIndex in output.messages[messageIndex].content.indices {
            guard case let .imageURL(url, providerMetadata) = output.messages[messageIndex].content[partIndex],
                  !isURLSupported(mediaType: "image/*", url: url, supportedURLs: supportedURLs) else {
                continue
            }

            try output.abortSignal?.throwIfAborted()
            let response: AIHTTPResponse
            do {
                response = try await downloadURL(
                    url,
                    transport: transport,
                    abortSignal: output.abortSignal
                )
            } catch {
                if error is AIAbortError || error is CancellationError { throw error }
                if let downloadError = error as? AIDownloadError { throw downloadError }
                throw AIDownloadError(url: url, message: String(describing: error))
            }
            guard (200..<300).contains(response.statusCode) else {
                throw AIDownloadError(
                    url: url,
                    message: "Download failed with HTTP status \(response.statusCode)."
                )
            }

            let responseMediaType = response.headerValue("content-type")?
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let mediaType = if let responseMediaType,
                               responseMediaType.contains("/") {
                responseMediaType
            } else {
                detectMediaType(data: response.body, topLevelType: "image") ?? "image/*"
            }
            output.messages[messageIndex].content[partIndex] = .data(
                mimeType: mediaType,
                data: response.body,
                providerMetadata: providerMetadata
            )
        }
    }

    return output
}

func convertToLanguageModelPrompt(_ prompt: StandardizedPrompt) throws -> [AIMessage] {
    let messages = (prompt.instructions ?? []) + prompt.messages.map(convertToLanguageModelMessage)
    var combinedMessages: [AIMessage] = []

    for message in messages {
        guard message.role == .tool, combinedMessages.last?.role == .tool else {
            combinedMessages.append(message)
            continue
        }
        let previousIndex = combinedMessages.count - 1
        let previousContentWasEmpty = combinedMessages[previousIndex].content.isEmpty
        if let contentIndex = combinedMessages[previousIndex].content.indices.last,
           !combinedMessages[previousIndex].providerMetadata.isEmpty {
            combinedMessages[previousIndex].content[contentIndex] = mergingToolPartProviderMetadata(
                combinedMessages[previousIndex].providerMetadata,
                into: combinedMessages[previousIndex].content[contentIndex]
            )
        }
        combinedMessages[previousIndex].content.append(contentsOf: message.content)
        combinedMessages[previousIndex].providerMetadata = previousContentWasEmpty
            ? deepMergeProviderMetadata(combinedMessages[previousIndex].providerMetadata, message.providerMetadata)
            : message.providerMetadata
    }

    let filteredMessages = combinedMessages.filter { message in
        message.role != .tool || !message.content.isEmpty
    }
    try validateToolResultAvailability(in: filteredMessages)
    return filteredMessages
}

func convertToLanguageModelMessage(_ message: AIMessage) -> AIMessage {
    var converted = message

    switch message.role {
    case .system:
        return message
    case .user:
        converted.content = message.content.filter { part in
            if case let .text(text, providerMetadata) = part {
                return !text.isEmpty || !providerMetadata.isEmpty
            }
            return true
        }
    case .assistant:
        converted.content = message.content.filter { part in
            switch part {
            case let .text(text, providerMetadata):
                return !text.isEmpty || !providerMetadata.isEmpty
            case .toolApprovalRequest:
                return false
            default:
                return true
            }
        }
    case .tool:
        converted.content = message.content.filter { part in
            switch part {
            case .toolResult:
                return true
            case let .toolApprovalResponse(response):
                return response.providerExecuted
            default:
                return false
            }
        }
    }

    return converted
}

private func mergingToolPartProviderMetadata(
    _ messageMetadata: [String: JSONValue],
    into part: AIContentPart
) -> AIContentPart {
    let merged = deepMergeProviderMetadata(messageMetadata, part.providerMetadata)
    switch part {
    case let .toolResult(value):
        var result = value
        result.providerMetadata = merged
        return .toolResult(result)
    case let .toolApprovalResponse(value):
        var response = value
        response.providerMetadata = merged
        return .toolApprovalResponse(response)
    default:
        return part
    }
}

private func deepMergeProviderMetadata(
    _ base: [String: JSONValue],
    _ overrides: [String: JSONValue]
) -> [String: JSONValue] {
    var merged = base
    for (key, override) in overrides {
        if case let .object(baseObject) = merged[key],
           case let .object(overrideObject) = override {
            merged[key] = .object(deepMergeProviderMetadata(baseObject, overrideObject))
        } else {
            merged[key] = override
        }
    }
    return merged
}