import Foundation


public enum ModelCapability: String, Hashable, Codable, CaseIterable, Sendable {
    case language
    case completion
    case embedding
    case image
    case transcription
    case speech
    case audioGeneration
    case audioTransformation
    case dubbing
    case video
    case reranking
    case evaluation
    case decision
}

public enum MessageRole: String, Codable, Hashable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public enum AIContentPart: Equatable, Hashable, Sendable {
    case text(String, providerMetadata: [String: JSONValue] = [:])
    case reasoning(String, providerMetadata: [String: JSONValue] = [:])
    case imageURL(String, providerMetadata: [String: JSONValue] = [:])
    case data(mimeType: String, data: Data, providerMetadata: [String: JSONValue] = [:])
    case file(mimeType: String, data: Data, filename: String? = nil, providerMetadata: [String: JSONValue] = [:])
    case reasoningFile(AIStreamFile)
    case custom(JSONValue, providerMetadata: [String: JSONValue] = [:])
    case providerReference(mimeType: String, reference: AIProviderReference, filename: String? = nil, providerMetadata: [String: JSONValue] = [:])
    case toolCall(AIToolCall)
    case toolResult(AIToolResult)
    case toolApprovalRequest(AIToolApprovalRequest)
    case toolApprovalResponse(AIToolApprovalResponse)

    public var text: String? {
        if case let .text(value, _) = self { value } else { nil }
    }

    public var filePayload: (mimeType: String, data: Data, filename: String?)? {
        switch self {
        case let .data(mimeType, data, _):
            return (mimeType, data, nil)
        case let .file(mimeType, data, filename, _):
            return (mimeType, data, filename)
        case .text, .reasoning, .reasoningFile, .custom, .imageURL, .providerReference, .toolCall, .toolResult, .toolApprovalRequest, .toolApprovalResponse:
            return nil
        }
    }

    public var providerMetadata: [String: JSONValue] {
        switch self {
        case let .text(_, providerMetadata),
             let .reasoning(_, providerMetadata),
             let .imageURL(_, providerMetadata),
             let .data(_, _, providerMetadata),
             let .file(_, _, _, providerMetadata),
             let .custom(_, providerMetadata),
             let .providerReference(_, _, _, providerMetadata):
            return providerMetadata
        case let .reasoningFile(file):
            return file.providerMetadata
        case let .toolCall(toolCall):
            return toolCall.providerMetadata
        case let .toolResult(toolResult):
            return toolResult.providerMetadata
        case let .toolApprovalRequest(request):
            return request.providerMetadata
        case let .toolApprovalResponse(response):
            return response.providerMetadata
        }
    }
}

public extension AIContentPart {
    /// Creates a hosted video input for supported OpenAI-compatible chat and MiniMax M3.1+ models.
    static func videoURL(
        _ url: String,
        mediaType: String = "video/*",
        providerMetadata: [String: JSONValue] = [:]
    ) -> AIContentPart {
        .providerReference(
            mimeType: mediaType,
            reference: ["openaiCompatible": url],
            providerMetadata: providerMetadata
        )
    }
}


public struct AIMessage: Equatable, Hashable, Sendable {
    public var role: MessageRole
    public var content: [AIContentPart]
    public var reasoning: String?
    public var providerMetadata: [String: JSONValue]

    public init(
        role: MessageRole,
        content: [AIContentPart],
        reasoning: String? = nil,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.providerMetadata = providerMetadata
    }

    public static func system(_ text: String) -> AIMessage {
        AIMessage(role: .system, content: [.text(text)])
    }

    public static func user(_ text: String) -> AIMessage {
        AIMessage(role: .user, content: [.text(text)])
    }

    public static func assistant(_ text: String, reasoning: String? = nil) -> AIMessage {
        AIMessage(role: .assistant, content: [.text(text)], reasoning: reasoning)
    }

    public static func assistant(
        text: String = "",
        reasoning: String? = nil,
        toolCalls: [AIToolCall],
        toolApprovalRequests: [AIToolApprovalRequest] = []
    ) -> AIMessage {
        AIMessage(
            role: .assistant,
            content: (text.isEmpty ? [] : [.text(text)])
                + toolCalls.map(AIContentPart.toolCall)
                + toolApprovalRequests.map(AIContentPart.toolApprovalRequest),
            reasoning: reasoning
        )
    }

    public static func toolResult(_ result: AIToolResult) -> AIMessage {
        AIMessage(role: .tool, content: [.toolResult(result)])
    }

    public static func toolResponses(
        approvalResponses: [AIToolApprovalResponse] = [],
        toolResults: [AIToolResult] = []
    ) -> AIMessage {
        AIMessage(
            role: .tool,
            content: approvalResponses.map(AIContentPart.toolApprovalResponse)
                + toolResults.map(AIContentPart.toolResult)
        )
    }

    public var combinedText: String {
        content.compactMap(\.text).joined(separator: "\n")
    }
}