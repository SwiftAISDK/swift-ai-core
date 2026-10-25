import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public struct AIStopConditionContext: Sendable {
    public var steps: [AIToolStep]

    public init(steps: [AIToolStep]) {
        self.steps = steps
    }
}

public struct AIStopCondition: Sendable {
    public var evaluate: @Sendable (AIStopConditionContext) async throws -> Bool

    public init(_ evaluate: @escaping @Sendable (AIStopConditionContext) async throws -> Bool) {
        self.evaluate = evaluate
    }

    public static func isStepCount(_ stepCount: Int) -> AIStopCondition {
        AIStopCondition { context in
            context.steps.count == stepCount
        }
    }

    public static func isLoopFinished() -> AIStopCondition {
        AIStopCondition { _ in false }
    }

    public static func hasToolCall(_ toolNames: String...) -> AIStopCondition {
        AIStopCondition { context in
            guard let lastStep = context.steps.last else { return false }
            return lastStep.toolCalls.contains { toolNames.contains($0.name) }
        }
    }
}

public struct AIPrepareStepContext: Sendable {
    public var model: any LanguageModel
    public var stepNumber: Int
    public var steps: [AIToolStep]
    public var request: LanguageModelRequest
    public var initialRequest: LanguageModelRequest
    public var responseMessages: [AIMessage]

    public init(
        model: any LanguageModel,
        stepNumber: Int,
        steps: [AIToolStep],
        request: LanguageModelRequest,
        initialRequest: LanguageModelRequest,
        responseMessages: [AIMessage]
    ) {
        self.model = model
        self.stepNumber = stepNumber
        self.steps = steps
        self.request = request
        self.initialRequest = initialRequest
        self.responseMessages = responseMessages
    }
}

public struct AIPrepareStepResult: Sendable {
    public var model: (any LanguageModel)?
    public var request: LanguageModelRequest?
    public var executableTools: [AITool]?

    public init(
        model: (any LanguageModel)? = nil,
        request: LanguageModelRequest? = nil,
        executableTools: [AITool]? = nil
    ) {
        self.model = model
        self.request = request
        self.executableTools = executableTools
    }
}

public typealias AIPrepareStep = @Sendable (AIPrepareStepContext) async throws -> AIPrepareStepResult?

final class AIToolApprovalReasonCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ reason: String?) {
        lock.lock()
        defer { lock.unlock() }
        value = reason
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public struct AIToolApprovalContext: Sendable {
    public var toolCall: AIToolCall
    public var arguments: JSONValue
    public var tool: AITool
    public var request: LanguageModelRequest
    public var toolContext: JSONValue?
    let approvalReasonCapture: AIToolApprovalReasonCapture?

    public init(
        toolCall: AIToolCall,
        arguments: JSONValue,
        tool: AITool,
        request: LanguageModelRequest,
        toolContext: JSONValue? = nil
    ) {
        self.toolCall = toolCall
        self.arguments = arguments
        self.tool = tool
        self.request = request
        self.toolContext = toolContext
        self.approvalReasonCapture = nil
    }

    init(
        toolCall: AIToolCall,
        arguments: JSONValue,
        tool: AITool,
        request: LanguageModelRequest,
        toolContext: JSONValue?,
        approvalReasonCapture: AIToolApprovalReasonCapture
    ) {
        self.toolCall = toolCall
        self.arguments = arguments
        self.tool = tool
        self.request = request
        self.toolContext = toolContext
        self.approvalReasonCapture = approvalReasonCapture
    }

    /// Requests human approval and attaches an optional policy reason to the
    /// emitted `AIToolApprovalRequest`.
    public func userApproval(reason: String? = nil) -> AIToolApprovalStatus {
        approvalReasonCapture?.set(reason)
        return .userApproval
    }
}

public typealias AIToolApproval = @Sendable (AIToolApprovalContext) async throws -> AIToolApprovalStatus?

public struct AIToolNeedsApprovalContext: Sendable {
    public var toolCallID: String
    public var messages: [AIMessage]
    public var context: JSONValue?

    public init(toolCallID: String, messages: [AIMessage], context: JSONValue? = nil) {
        self.toolCallID = toolCallID
        self.messages = messages
        self.context = context
    }
}

public typealias AIToolNeedsApproval = @Sendable (JSONValue, AIToolNeedsApprovalContext) async throws -> Bool

public struct AIToolInputStartContext: Sendable {
    public var toolCallID: String
    public var messages: [AIMessage]
    public var abortSignal: AIAbortSignal?
    public var toolContext: JSONValue?

    public init(
        toolCallID: String,
        messages: [AIMessage] = [],
        abortSignal: AIAbortSignal? = nil,
        toolContext: JSONValue? = nil
    ) {
        self.toolCallID = toolCallID
        self.messages = messages
        self.abortSignal = abortSignal
        self.toolContext = toolContext
    }
}

public struct AIToolInputDeltaContext: Sendable {
    public var toolCallID: String
    public var inputTextDelta: String
    public var messages: [AIMessage]
    public var abortSignal: AIAbortSignal?
    public var toolContext: JSONValue?

    public init(
        toolCallID: String,
        inputTextDelta: String,
        messages: [AIMessage] = [],
        abortSignal: AIAbortSignal? = nil,
        toolContext: JSONValue? = nil
    ) {
        self.toolCallID = toolCallID
        self.inputTextDelta = inputTextDelta
        self.messages = messages
        self.abortSignal = abortSignal
        self.toolContext = toolContext
    }
}

public struct AIToolInputAvailableContext: Sendable {
    public var toolCallID: String
    public var input: JSONValue
    public var messages: [AIMessage]
    public var abortSignal: AIAbortSignal?
    public var toolContext: JSONValue?

    public init(
        toolCallID: String,
        input: JSONValue,
        messages: [AIMessage] = [],
        abortSignal: AIAbortSignal? = nil,
        toolContext: JSONValue? = nil
    ) {
        self.toolCallID = toolCallID
        self.input = input
        self.messages = messages
        self.abortSignal = abortSignal
        self.toolContext = toolContext
    }
}

public typealias AIToolInputStartCallback = @Sendable (AIToolInputStartContext) async -> Void
public typealias AIToolInputDeltaCallback = @Sendable (AIToolInputDeltaContext) async -> Void
public typealias AIToolInputAvailableCallback = @Sendable (AIToolInputAvailableContext) async -> Void

public struct AIToolCallRepairContext: @unchecked Sendable {
    public var toolCall: AIToolCall
    public var toolsByName: [String: AITool]
    public var request: LanguageModelRequest?
    public var error: any Error

    public init(
        toolCall: AIToolCall,
        toolsByName: [String: AITool],
        request: LanguageModelRequest? = nil,
        error: any Error
    ) {
        self.toolCall = toolCall
        self.toolsByName = toolsByName
        self.request = request
        self.error = error
    }

    public func inputSchema(for toolName: String) throws -> JSONValue {
        guard let tool = toolsByName[toolName] else {
            throw AINoSuchToolError(toolName: toolName, availableToolNames: Array(toolsByName.keys))
        }
        return tool.parameters
    }
}

public typealias AIToolCallRepair = @Sendable (AIToolCallRepairContext) async throws -> AIToolCall?

public struct AIToolExecutionContext: Sendable {
    public var toolCallID: String?
    public var messages: [AIMessage]
    public var abortSignal: AIAbortSignal?
    public var metadata: [String: JSONValue]
    public var toolContext: JSONValue?

    public init(
        toolCallID: String? = nil,
        messages: [AIMessage] = [],
        abortSignal: AIAbortSignal? = nil,
        metadata: [String: JSONValue] = [:],
        toolContext: JSONValue? = nil
    ) {
        self.toolCallID = toolCallID
        self.messages = messages
        self.abortSignal = abortSignal
        self.metadata = metadata
        self.toolContext = toolContext
    }
}

public struct AIToolModelOutputContext: Sendable {
    public var toolCallID: String
    public var input: JSONValue
    public var output: JSONValue

    public init(toolCallID: String, input: JSONValue, output: JSONValue) {
        self.toolCallID = toolCallID
        self.input = input
        self.output = output
    }
}


public let AIDirectToolCallerName = "AI_SDK_DIRECT_TOOL_CALL"

public enum AIToolCallerDefinition: Sendable {
    case local(
        bind: @Sendable (_ tools: [String: AITool]) -> AITool,
        prepareModelMessage: (@Sendable (_ tools: [String: AITool]) -> String?)? = nil
    )
    case provider(
        prepareProviderOptions: @Sendable (
            _ providerOptions: [String: JSONValue]
        ) -> [String: JSONValue]
    )
}

public typealias AIToolCallerRouting = [String: [String]]
public struct AITool: Sendable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue
    public var dynamic: Bool
    public var providerMetadata: [String: JSONValue]
    public var providerOptions: [String: JSONValue]
    public var strict: Bool?
    public var inputExamples: [JSONValue]
    public var contextSchema: JSONValue?
    public var needsApproval: AIToolNeedsApproval?
    public var deferLoading: Bool
    public var toolCaller: AIToolCallerDefinition?
    var toolSearchMarker: Bool
    var toolSearchFunction: AIToolSearchFunction? = nil
    var toolSearchMaxResults: Int = 5
    public var onInputStart: AIToolInputStartCallback?
    public var onInputDelta: AIToolInputDeltaCallback?
    public var onInputAvailable: AIToolInputAvailableCallback?
    public var refineArguments: (@Sendable (JSONValue) async throws -> JSONValue)?
    public var execute: @Sendable (JSONValue) async throws -> JSONValue
    public var executeWithContext: @Sendable (JSONValue, AIToolExecutionContext) async throws -> JSONValue
    public var toModelOutput: (@Sendable (AIToolModelOutputContext) async throws -> JSONValue)?

    public init(
        name: String,
        description: String? = nil,
        parameters: JSONValue,
        dynamic: Bool = false,
        providerMetadata: [String: JSONValue] = [:],
        providerOptions: [String: JSONValue] = [:],
        strict: Bool? = nil,
        inputExamples: [JSONValue] = [],
        contextSchema: JSONValue? = nil,
        needsApproval: AIToolNeedsApproval? = nil,
        deferLoading: Bool = false,
        toolCaller: AIToolCallerDefinition? = nil,
        onInputStart: AIToolInputStartCallback? = nil,
        onInputDelta: AIToolInputDeltaCallback? = nil,
        onInputAvailable: AIToolInputAvailableCallback? = nil,
        refineArguments: (@Sendable (JSONValue) async throws -> JSONValue)? = nil,
        toModelOutput: (@Sendable (AIToolModelOutputContext) async throws -> JSONValue)? = nil,
        executeWithContext: (@Sendable (JSONValue, AIToolExecutionContext) async throws -> JSONValue)? = nil,
        execute: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.dynamic = dynamic
        self.providerMetadata = providerMetadata
        self.providerOptions = providerOptions
        self.strict = strict
        self.inputExamples = inputExamples
        self.contextSchema = contextSchema
        self.needsApproval = needsApproval
        self.onInputStart = onInputStart
        self.deferLoading = deferLoading
        self.toolCaller = toolCaller
        self.toolSearchMarker = false
        self.onInputDelta = onInputDelta
        self.onInputAvailable = onInputAvailable
        self.refineArguments = refineArguments
        self.toModelOutput = toModelOutput
        self.execute = execute
        self.executeWithContext = executeWithContext ?? { arguments, _ in
            try await execute(arguments)
        }
    }

    /// Preserves the initializer released in 1.7.0 before deferred tool callers were added.
    public init(
        name: String,
        description: String? = nil,
        parameters: JSONValue,
        dynamic: Bool = false,
        providerMetadata: [String: JSONValue] = [:],
        providerOptions: [String: JSONValue] = [:],
        strict: Bool? = nil,
        inputExamples: [JSONValue] = [],
        contextSchema: JSONValue? = nil,
        needsApproval: AIToolNeedsApproval? = nil,
        onInputStart: AIToolInputStartCallback? = nil,
        onInputDelta: AIToolInputDeltaCallback? = nil,
        onInputAvailable: AIToolInputAvailableCallback? = nil,
        refineArguments: (@Sendable (JSONValue) async throws -> JSONValue)? = nil,
        toModelOutput: (@Sendable (AIToolModelOutputContext) async throws -> JSONValue)? = nil,
        executeWithContext: (@Sendable (JSONValue, AIToolExecutionContext) async throws -> JSONValue)? = nil,
        execute: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) {
        self.init(
            name: name,
            description: description,
            parameters: parameters,
            dynamic: dynamic,
            providerMetadata: providerMetadata,
            providerOptions: providerOptions,
            strict: strict,
            inputExamples: inputExamples,
            contextSchema: contextSchema,
            needsApproval: needsApproval,
            deferLoading: false,
            toolCaller: nil,
            onInputStart: onInputStart,
            onInputDelta: onInputDelta,
            onInputAvailable: onInputAvailable,
            refineArguments: refineArguments,
            toModelOutput: toModelOutput,
            executeWithContext: executeWithContext,
            execute: execute
        )
    }

    public static func dynamic(
        name: String,
        description: String? = nil,
        parameters: JSONValue,
        providerMetadata: [String: JSONValue] = [:],
        providerOptions: [String: JSONValue] = [:],
        strict: Bool? = nil,
        inputExamples: [JSONValue] = [],
        contextSchema: JSONValue? = nil,
        needsApproval: AIToolNeedsApproval? = nil,
        onInputStart: AIToolInputStartCallback? = nil,
        deferLoading: Bool = false,
        toolCaller: AIToolCallerDefinition? = nil,
        onInputDelta: AIToolInputDeltaCallback? = nil,
        onInputAvailable: AIToolInputAvailableCallback? = nil,
        refineArguments: (@Sendable (JSONValue) async throws -> JSONValue)? = nil,
        toModelOutput: (@Sendable (AIToolModelOutputContext) async throws -> JSONValue)? = nil,
        executeWithContext: (@Sendable (JSONValue, AIToolExecutionContext) async throws -> JSONValue)? = nil,
        execute: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) -> AITool {
        AITool(
            name: name,
            description: description,
            parameters: parameters,
            dynamic: true,
            providerMetadata: providerMetadata,
            providerOptions: providerOptions,
            strict: strict,
            inputExamples: inputExamples,
            contextSchema: contextSchema,
            needsApproval: needsApproval,
            deferLoading: deferLoading,
            toolCaller: toolCaller,
            onInputStart: onInputStart,
            onInputDelta: onInputDelta,
            onInputAvailable: onInputAvailable,
            refineArguments: refineArguments,
            toModelOutput: toModelOutput,
            executeWithContext: executeWithContext,
            execute: execute
        )
    }

    /// Preserves the dynamic-tool factory released in 1.7.0.
    public static func dynamic(
        name: String,
        description: String? = nil,
        parameters: JSONValue,
        providerMetadata: [String: JSONValue] = [:],
        providerOptions: [String: JSONValue] = [:],
        strict: Bool? = nil,
        inputExamples: [JSONValue] = [],
        contextSchema: JSONValue? = nil,
        needsApproval: AIToolNeedsApproval? = nil,
        onInputStart: AIToolInputStartCallback? = nil,
        onInputDelta: AIToolInputDeltaCallback? = nil,
        onInputAvailable: AIToolInputAvailableCallback? = nil,
        refineArguments: (@Sendable (JSONValue) async throws -> JSONValue)? = nil,
        toModelOutput: (@Sendable (AIToolModelOutputContext) async throws -> JSONValue)? = nil,
        executeWithContext: (@Sendable (JSONValue, AIToolExecutionContext) async throws -> JSONValue)? = nil,
        execute: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) -> AITool {
        dynamic(
            name: name,
            description: description,
            parameters: parameters,
            providerMetadata: providerMetadata,
            providerOptions: providerOptions,
            strict: strict,
            inputExamples: inputExamples,
            contextSchema: contextSchema,
            needsApproval: needsApproval,
            onInputStart: onInputStart,
            deferLoading: false,
            toolCaller: nil,
            onInputDelta: onInputDelta,
            onInputAvailable: onInputAvailable,
            refineArguments: refineArguments,
            toModelOutput: toModelOutput,
            executeWithContext: executeWithContext,
            execute: execute
        )
    }

    public var schema: JSONValue {
        var object = parameters.objectValue ?? ["type": .string("object")]
        if let description {
            object["description"] = .string(description)
        }
        if !providerOptions.isEmpty {
            object["providerOptions"] = .object(providerOptions)
        }
        if let strict {
            object["strict"] = .bool(strict)
        }
        if !inputExamples.isEmpty {
            object["inputExamples"] = .array(inputExamples)
        }
        return .object(object)
    }
}

public func experimentalToolCaller(
    _ tool: AITool,
    definition: AIToolCallerDefinition
) -> AITool {
    var tool = tool
    tool.toolCaller = definition
    return tool
}

public func toolSearch(name: String = "toolSearch") -> AITool {
    var tool = AITool(
        name: name,
        description: "Search for tools by keywords in their names and descriptions. Returns up to five matching tools. Matches become available on the next model step, after this execution finishes. Wait for their tool definitions before calling the discovered tools. If no tools match, try different keywords.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "minLength": .number(1)
                ])
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false)
        ]),
        execute: { _ in
            throw AIError.invalidArgument(
                argument: "toolSearch",
                message: "toolSearch must be bound by an AI SDK generation."
            )
        }
    )
    tool.toolSearchMarker = true
    return tool
}

public struct AIToolSearchCandidate: Equatable, Sendable {
    public var name: String
    public var description: String?
    public init(name: String, description: String? = nil) { self.name = name; self.description = description }
}

public typealias AIToolSearchFunction = @Sendable (_ query: String, _ tools: [AIToolSearchCandidate]) async throws -> [String]

public func toolSearch(name: String = "toolSearch", maxResults: Int, search: AIToolSearchFunction? = nil) throws -> AITool {
    guard maxResults > 0, maxResults <= 9_007_199_254_740_991 else {
        throw AIError.invalidArgument(argument: "maxResults", message: "maxResults must be a positive safe integer.")
    }
    var tool = toolSearch(name: name)
    tool.toolSearchFunction = search
    tool.toolSearchMaxResults = maxResults
    let introduction = search == nil ? "Search for tools by keywords in their names and descriptions." : "Search for tools matching a query."
    tool.description = "\(introduction) Returns up to \(maxResults == 5 ? "five" : String(maxResults)) matching tools. Matches become available on the next model step, after this execution finishes. Wait for their tool definitions before calling the discovered tools. If no tools match, try different keywords."
    return tool
}

public func toolSearch(name: String = "toolSearch", search: @escaping AIToolSearchFunction) -> AITool {
    // Five is always a valid limit.
    try! toolSearch(name: name, maxResults: 5, search: search)
}