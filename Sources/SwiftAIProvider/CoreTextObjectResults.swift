import Foundation


public enum AIResultContentPart: Equatable, Hashable, Sendable {
    case text(String, providerMetadata: [String: JSONValue] = [:])
    /// Text with supporting references. The original `text` case remains available.
    case citedText(String, citations: [AICitation], providerMetadata: [String: JSONValue] = [:])
    case reasoning(String, providerMetadata: [String: JSONValue] = [:])
    case source(AISource)
    case file(AIStreamFile)
    case reasoningFile(AIStreamFile)
    case custom(JSONValue, providerMetadata: [String: JSONValue] = [:])
    case toolCall(AIToolCall)
    case toolResult(AIToolResult)
    case toolApprovalRequest(AIToolApprovalRequest)
    case toolApprovalResponse(AIToolApprovalResponse)
}

public struct TextGenerationResult: Sendable {
    public var content: [AIResultContentPart]
    public var text: String
    /// Optional text selected by the provider for JSON output parsing. An empty
    /// selection is explicit; generated text and content remain unchanged.
    public var structuredOutputText: String?
    public var reasoning: String
    public var finishReason: String?
    public var usage: TokenUsage?
    public var files: [AIStreamFile]
    public var toolCalls: [AIToolCall]
    public var toolResults: [AIToolResult]
    public var toolApprovalRequests: [AIToolApprovalRequest]
    public var toolApprovalResponses: [AIToolApprovalResponse]
    public var steps: [AIToolStep]
    public var sources: [AISource]
    public var responseMessages: [AIMessage]
    public var providerMetadata: [String: JSONValue]
    public var rawValue: JSONValue
    public var warnings: [AIWarning]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public var reasoningText: String { reasoning }
    public var citations: [AICitation] { content.flatMap(\.citations) }
    public var finalStep: AIToolStep? { steps.last }

    public init(
        text: String,
        structuredOutputText: String? = nil,
        content: [AIResultContentPart] = [],
        reasoning: String = "",
        finishReason: String? = nil,
        usage: TokenUsage? = nil,
        files: [AIStreamFile] = [],
        toolCalls: [AIToolCall] = [],
        toolResults: [AIToolResult] = [],
        toolApprovalRequests: [AIToolApprovalRequest] = [],
        toolApprovalResponses: [AIToolApprovalResponse] = [],
        steps: [AIToolStep] = [],
        sources: [AISource] = [],
        responseMessages: [AIMessage] = [],
        providerMetadata: [String: JSONValue] = [:],
        rawValue: JSONValue,
        warnings: [AIWarning] = [],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        let resolvedContent = content.isEmpty
            ? synthesizeResultContent(
                text: text,
                reasoning: reasoning,
                files: files,
                toolCalls: toolCalls,
                toolResults: toolResults,
                toolApprovalRequests: toolApprovalRequests,
                toolApprovalResponses: toolApprovalResponses,
                sources: sources
            )
            : content
        self.content = resolvedContent
        self.text = text
        self.structuredOutputText = structuredOutputText
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.usage = usage
        self.files = files.isEmpty ? resultFiles(from: resolvedContent) : files
        self.toolCalls = toolCalls.isEmpty ? resultToolCalls(from: resolvedContent) : toolCalls
        self.toolResults = toolResults.isEmpty ? resultToolResults(from: resolvedContent) : toolResults
        self.toolApprovalRequests = toolApprovalRequests.isEmpty ? resultToolApprovalRequests(from: resolvedContent) : toolApprovalRequests
        self.toolApprovalResponses = toolApprovalResponses.isEmpty ? resultToolApprovalResponses(from: resolvedContent) : toolApprovalResponses
        self.steps = steps
        self.sources = sources.isEmpty ? resultSources(from: resolvedContent) : sources
        self.responseMessages = responseMessages
        self.providerMetadata = providerMetadata
        self.rawValue = rawValue
        self.warnings = warnings
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }
}

package func synthesizeResultContent(
    text: String,
    reasoning: String,
    files: [AIStreamFile],
    toolCalls: [AIToolCall],
    toolResults: [AIToolResult],
    toolApprovalRequests: [AIToolApprovalRequest],
    toolApprovalResponses: [AIToolApprovalResponse],
    sources: [AISource]
) -> [AIResultContentPart] {
    var content: [AIResultContentPart] = []
    if !reasoning.isEmpty {
        content.append(.reasoning(reasoning))
    }
    if !text.isEmpty {
        content.append(.text(text))
    }
    content.append(contentsOf: sources.map(AIResultContentPart.source))
    content.append(contentsOf: files.map(AIResultContentPart.file))
    content.append(contentsOf: toolCalls.map(AIResultContentPart.toolCall))
    content.append(contentsOf: toolApprovalRequests.map(AIResultContentPart.toolApprovalRequest))
    content.append(contentsOf: toolApprovalResponses.map(AIResultContentPart.toolApprovalResponse))
    content.append(contentsOf: toolResults.map(AIResultContentPart.toolResult))
    return content
}

package func resultFiles(from content: [AIResultContentPart]) -> [AIStreamFile] {
    content.compactMap { part in
        if case let .file(file) = part {
            return file
        }
        return nil
    }
}

public func resultSources(from content: [AIResultContentPart]) -> [AISource] {
    content.compactMap { part in
        if case let .source(source) = part {
            return source
        }
        return nil
    }
}

public func resultToolCalls(from content: [AIResultContentPart]) -> [AIToolCall] {
    content.compactMap { part in
        if case let .toolCall(call) = part {
            return call
        }
        return nil
    }
}

public func resultToolResults(from content: [AIResultContentPart]) -> [AIToolResult] {
    content.compactMap { part in
        if case let .toolResult(result) = part {
            return result
        }
        return nil
    }
}

package func resultToolApprovalRequests(from content: [AIResultContentPart]) -> [AIToolApprovalRequest] {
    content.compactMap { part in
        if case let .toolApprovalRequest(request) = part {
            return request
        }
        return nil
    }
}

package func resultToolApprovalResponses(from content: [AIResultContentPart]) -> [AIToolApprovalResponse] {
    content.compactMap { part in
        if case let .toolApprovalResponse(response) = part {
            return response
        }
        return nil
    }
}