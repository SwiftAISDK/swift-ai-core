import Foundation


public struct AIToolStep: Sendable {
    public var index: Int
    public var providerID: String?
    public var modelID: String?
    public var content: [AIResultContentPart]
    public var text: String
    public var reasoning: String
    public var finishReason: String?
    public var usage: TokenUsage?
    public var files: [AIStreamFile]
    public var toolCalls: [AIToolCall]
    public var toolResults: [AIToolResult]
    public var toolApprovalRequests: [AIToolApprovalRequest]
    public var toolApprovalResponses: [AIToolApprovalResponse]
    public var sources: [AISource]
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var responseMetadata: AIResponseMetadata

    public init(
        index: Int,
        providerID: String? = nil,
        modelID: String? = nil,
        content: [AIResultContentPart] = [],
        text: String,
        reasoning: String = "",
        finishReason: String? = nil,
        usage: TokenUsage? = nil,
        files: [AIStreamFile] = [],
        toolCalls: [AIToolCall] = [],
        toolResults: [AIToolResult] = [],
        toolApprovalRequests: [AIToolApprovalRequest] = [],
        toolApprovalResponses: [AIToolApprovalResponse] = [],
        sources: [AISource] = [],
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.index = index
        self.providerID = providerID
        self.modelID = modelID
        self.content = content
        self.text = text
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.usage = usage
        self.files = files
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.toolApprovalRequests = toolApprovalRequests
        self.toolApprovalResponses = toolApprovalResponses
        self.sources = sources
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.responseMetadata = responseMetadata
    }

    /// Preserves the initializer released in 1.7.0 before step model identity was added.
    public init(
        index: Int,
        content: [AIResultContentPart] = [],
        text: String,
        reasoning: String = "",
        finishReason: String? = nil,
        usage: TokenUsage? = nil,
        files: [AIStreamFile] = [],
        toolCalls: [AIToolCall] = [],
        toolResults: [AIToolResult] = [],
        toolApprovalRequests: [AIToolApprovalRequest] = [],
        toolApprovalResponses: [AIToolApprovalResponse] = [],
        sources: [AISource] = [],
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.init(
            index: index,
            providerID: nil,
            modelID: nil,
            content: content,
            text: text,
            reasoning: reasoning,
            finishReason: finishReason,
            usage: usage,
            files: files,
            toolCalls: toolCalls,
            toolResults: toolResults,
            toolApprovalRequests: toolApprovalRequests,
            toolApprovalResponses: toolApprovalResponses,
            sources: sources,
            warnings: warnings,
            providerMetadata: providerMetadata,
            responseMetadata: responseMetadata
        )
    }
}

public struct AISource: Equatable, Hashable, Sendable {
    public var id: String
    public var sourceType: String
    public var url: String?
    public var title: String?
    public var mediaType: String?
    public var filename: String?
    public var providerMetadata: [String: JSONValue]
    public var rawValue: JSONValue?

    public init(
        id: String,
        sourceType: String,
        url: String? = nil,
        title: String? = nil,
        mediaType: String? = nil,
        filename: String? = nil,
        providerMetadata: [String: JSONValue] = [:],
        rawValue: JSONValue? = nil
    ) {
        self.id = id
        self.sourceType = sourceType
        self.url = url
        self.title = title
        self.mediaType = mediaType
        self.filename = filename
        self.providerMetadata = providerMetadata
        self.rawValue = rawValue
    }
}

public struct AIToolCall: Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String
    /// UI delta encoding; final arguments remain JSON-encoded.
    public var inputEncoding: AIToolInputEncoding = .json
    /// Unfinished text-encoded deltas, retained for native UI resume.
    public var rawInputText: String? = nil
    public var providerExecuted: Bool
    public var dynamic: Bool
    public var title: String?
    public var providerMetadata: [String: JSONValue]
    public var rawValue: JSONValue?

    public init(
        id: String,
        name: String,
        arguments: String,
        providerExecuted: Bool = false,
        dynamic: Bool = false,
        title: String? = nil,
        providerMetadata: [String: JSONValue] = [:],
        rawValue: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.providerExecuted = providerExecuted
        self.dynamic = dynamic
        self.title = title
        self.providerMetadata = providerMetadata
        self.rawValue = rawValue
    }
}

public struct AIToolResult: Equatable, Hashable, Sendable {
    public var toolCallID: String
    public var toolName: String
    public var result: JSONValue
    public var modelOutput: JSONValue?
    public var isError: Bool
    public var preliminary: Bool
    public var dynamic: Bool
    public var providerExecuted: Bool
    public var providerMetadata: [String: JSONValue]

    public init(
        toolCallID: String,
        toolName: String,
        result: JSONValue,
        modelOutput: JSONValue? = nil,
        isError: Bool = false,
        preliminary: Bool = false,
        dynamic: Bool = false,
        providerExecuted: Bool = false,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.result = result
        self.modelOutput = modelOutput
        self.isError = isError
        self.preliminary = preliminary
        self.dynamic = dynamic
        self.providerExecuted = providerExecuted
        self.providerMetadata = providerMetadata
    }
}

public struct AIToolApprovalRequest: Equatable, Hashable, Sendable {
    public var id: String
    public var toolCallID: String?
    public var toolName: String
    public var arguments: String
    /// Original input validated by the tool schema before `refineArguments`
    /// transformed it. This is preserved only when it differs from `arguments`
    /// so approved operations can be reconstructed and revalidated safely.
    public var inputSchemaInput: JSONValue?
    /// Provider-computed information that UI clients can use when presenting
    /// the approval request. The SDK preserves this value without interpreting it.
    public var descriptor: JSONValue?
    /// Reason shown to the human approver for why this operation requires approval.
    public var reason: String?
    public var isAutomatic: Bool
    public var providerMetadata: [String: JSONValue]

    public init(
        id: String,
        toolName: String,
        arguments: String,
        toolCallID: String? = nil,
        inputSchemaInput: JSONValue? = nil,
        descriptor: JSONValue? = nil,
        reason: String? = nil,
        isAutomatic: Bool = false,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.arguments = arguments
        self.inputSchemaInput = inputSchemaInput
        self.descriptor = descriptor
        self.reason = reason
        self.isAutomatic = isAutomatic
        self.providerMetadata = providerMetadata
    }

    /// Source-compatible initializer retained from SwiftAISDK 1.9.0, before
    /// approval requests preserved their pre-refinement schema input.
    public init(
        id: String,
        toolName: String,
        arguments: String,
        toolCallID: String? = nil,
        descriptor: JSONValue? = nil,
        reason: String? = nil,
        isAutomatic: Bool = false,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.init(
            id: id,
            toolName: toolName,
            arguments: arguments,
            toolCallID: toolCallID,
            inputSchemaInput: nil,
            descriptor: descriptor,
            reason: reason,
            isAutomatic: isAutomatic,
            providerMetadata: providerMetadata
        )
    }

    /// Source-compatible initializer retained from approval requests that
    /// exposed a policy reason before provider descriptors were added.
    public init(
        id: String,
        toolName: String,
        arguments: String,
        toolCallID: String? = nil,
        reason: String? = nil,
        isAutomatic: Bool = false,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.init(
            id: id,
            toolName: toolName,
            arguments: arguments,
            toolCallID: toolCallID,
            inputSchemaInput: nil,
            descriptor: nil,
            reason: reason,
            isAutomatic: isAutomatic,
            providerMetadata: providerMetadata
        )
    }

    /// Source-compatible initializer retained from approval requests without a
    /// policy reason.
    public init(
        id: String,
        toolName: String,
        arguments: String,
        toolCallID: String? = nil,
        isAutomatic: Bool = false,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.init(
            id: id,
            toolName: toolName,
            arguments: arguments,
            toolCallID: toolCallID,
            inputSchemaInput: nil,
            descriptor: nil,
            reason: nil,
            isAutomatic: isAutomatic,
            providerMetadata: providerMetadata
        )
    }
}

public struct AIToolApprovalResponse: Equatable, Hashable, Sendable {
    public var id: String
    public var approved: Bool
    public var reason: String?
    public var providerExecuted: Bool
    public var providerMetadata: [String: JSONValue]

    public init(
        id: String,
        approved: Bool,
        reason: String? = nil,
        providerExecuted: Bool = false,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.approved = approved
        self.reason = reason
        self.providerExecuted = providerExecuted
        self.providerMetadata = providerMetadata
    }
}

public enum AIToolApprovalStatus: Equatable, Hashable, Sendable {
    case notApplicable
    case approved(reason: String? = nil)
    case denied(reason: String? = nil)
    case userApproval
}

public struct AIStreamFile: Equatable, Hashable, Sendable {
    public var id: String?
    public var mediaType: String
    public var data: Data?
    public var url: String?
    public var filename: String?
    public var providerReference: AIProviderReference?
    public var providerMetadata: [String: JSONValue]
    public var rawValue: JSONValue?

    public init(
        id: String? = nil,
        mediaType: String,
        data: Data? = nil,
        url: String? = nil,
        filename: String? = nil,
        providerReference: AIProviderReference? = nil,
        providerMetadata: [String: JSONValue] = [:],
        rawValue: JSONValue? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.data = data
        self.url = url
        self.filename = filename
        self.providerReference = providerReference
        self.providerMetadata = providerMetadata
        self.rawValue = rawValue
    }
}

public struct AIResponseMetadata: Equatable, Hashable, Sendable {
    public var id: String?
    public var timestamp: Date?
    public var modelID: String?
    public var headers: [String: String]
    public var body: JSONValue?

    public init(id: String? = nil, timestamp: Date? = nil, modelID: String? = nil, headers: [String: String] = [:], body: JSONValue? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.modelID = modelID
        self.headers = headers
        self.body = body
    }
}

public struct AIRequestMetadata: Equatable, Hashable, Sendable {
    public var body: JSONValue?
    public var headers: [String: String]

    public init(body: JSONValue? = nil, headers: [String: String] = [:]) {
        self.body = body
        self.headers = headers
    }
}

public enum LanguageStreamPart: Equatable, Sendable {
    case streamStart(warnings: [AIWarning])
    case textStart(id: String, providerMetadata: [String: JSONValue] = [:])
    /// Legacy text delta without an explicit lifecycle or part identifier.
    ///
    /// Custom models may continue to return this case for source compatibility;
    /// SDK facades normalize a legacy-only text channel to `textStart`,
    /// `textDeltaPart`, and `textEnd`.
    case textDelta(String)
    case textDeltaPart(id: String, delta: String, providerMetadata: [String: JSONValue] = [:])
    case textEnd(id: String, providerMetadata: [String: JSONValue] = [:])
    case textEndWithCitations(id: String, citations: [AICitation], providerMetadata: [String: JSONValue] = [:])
    case reasoningStart(id: String, providerMetadata: [String: JSONValue] = [:])
    /// Legacy reasoning delta without an explicit lifecycle or part identifier.
    /// SDK facades normalize a legacy-only reasoning channel to its canonical
    /// start/delta/end representation.
    case reasoningDelta(String)
    case reasoningDeltaPart(id: String, delta: String, providerMetadata: [String: JSONValue] = [:])
    case reasoningEnd(id: String, providerMetadata: [String: JSONValue] = [:])
    case toolInputStart(id: String, name: String, providerExecuted: Bool = false, dynamic: Bool = false, title: String? = nil, providerMetadata: [String: JSONValue] = [:])
    case toolInputStartText(id: String, name: String, providerExecuted: Bool = false, dynamic: Bool = false, title: String? = nil, providerMetadata: [String: JSONValue] = [:])
    case toolInputDelta(id: String, delta: String, providerMetadata: [String: JSONValue] = [:])
    case toolInputEnd(id: String, providerMetadata: [String: JSONValue] = [:])
    case toolCallDelta(id: String?, name: String?, argumentsDelta: String, index: Int?)
    case toolCall(AIToolCall)
    case toolResult(AIToolResult)
    case toolApprovalRequest(AIToolApprovalRequest)
    case toolApprovalResponse(AIToolApprovalResponse)
    case file(AIStreamFile)
    case reasoningFile(AIStreamFile)
    case custom(JSONValue, providerMetadata: [String: JSONValue] = [:])
    case source(AISource)
    case metadata([String: JSONValue])
    case responseMetadata(AIResponseMetadata)
    case raw(JSONValue)
    case error(message: String, rawValue: JSONValue? = nil)
    /// Legacy terminal chunk without provider metadata.
    /// SDK facades normalize this case to `finishMetadata`.
    case finish(reason: String?, usage: TokenUsage?)
    case finishMetadata(
        reason: String?,
        usage: TokenUsage?,
        providerMetadata: [String: JSONValue] = [:]
    )
}