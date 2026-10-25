import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public struct AIAgentCallOptions: Sendable {
    public var requestOptions: AIChatRequestOptions
    public var abortSignal: AIAbortSignal?
    public var timeoutNanoseconds: UInt64?
    public var streamTimeout: AIStreamTimeoutConfiguration?
    public var retryPolicy: AIRetryPolicy?
    public var telemetry: Telemetry.Options?

    public init(
        requestOptions: AIChatRequestOptions = AIChatRequestOptions(),
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil,
        streamTimeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy? = nil,
        telemetry: Telemetry.Options? = nil
    ) {
        self.requestOptions = requestOptions
        self.abortSignal = abortSignal
        self.timeoutNanoseconds = timeoutNanoseconds
        self.streamTimeout = streamTimeout
        self.retryPolicy = retryPolicy
        self.telemetry = telemetry
    }
}

public protocol AIAgent: Sendable {
    var version: String { get }
    var id: String? { get }
    var executableTools: [AITool] { get }

    func generate(prompt: String, options: AIAgentCallOptions) async throws -> TextGenerationResult
    func generate(messages: [AIMessage], options: AIAgentCallOptions) async throws -> TextGenerationResult
    func stream(prompt: String, options: AIAgentCallOptions) -> AsyncThrowingStream<LanguageStreamPart, Error>
    func stream(messages: [AIMessage], options: AIAgentCallOptions) -> AsyncThrowingStream<LanguageStreamPart, Error>
}

public extension AIAgent {
    var version: String { "agent-v1" }

    func generate(prompt: String) async throws -> TextGenerationResult {
        try await generate(prompt: prompt, options: AIAgentCallOptions())
    }

    func generate(messages: [AIMessage]) async throws -> TextGenerationResult {
        try await generate(messages: messages, options: AIAgentCallOptions())
    }

    func stream(prompt: String) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        stream(prompt: prompt, options: AIAgentCallOptions())
    }

    func stream(messages: [AIMessage]) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        stream(messages: messages, options: AIAgentCallOptions())
    }
}


public struct AIToolLoopAgent: AIAgent {
    public var id: String?
    public var model: any LanguageModel
    public var instructions: String?
    public var executableTools: [AITool]
    public var toolCallers: AIToolCallerRouting
    public var maxSteps: Int
    public var stopWhen: [AIStopCondition]
    public var allowSystemInMessages: Bool
    public var prepareStep: AIPrepareStep?
    public var toolApproval: AIToolApproval?
    public var requestOptions: AIChatRequestOptions
    public var timeoutNanoseconds: UInt64?
    public var streamTimeout: AIStreamTimeoutConfiguration?
    public var retryPolicy: AIRetryPolicy
    public var telemetry: Telemetry.Options?

    public init(
        id: String? = nil,
        model: any LanguageModel,
        instructions: String? = nil,
        executableTools: [AITool] = [],
        maxSteps: Int = 20,
        stopWhen: [AIStopCondition] = [],
        allowSystemInMessages: Bool = false,
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        requestOptions: AIChatRequestOptions = AIChatRequestOptions(),
        timeoutNanoseconds: UInt64? = nil,
        streamTimeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) {
        self.id = id
        self.model = model
        self.instructions = instructions
        self.executableTools = executableTools
        self.toolCallers = [:]
        self.maxSteps = maxSteps
        self.stopWhen = stopWhen
        self.allowSystemInMessages = allowSystemInMessages
        self.prepareStep = prepareStep
        self.toolApproval = toolApproval
        self.requestOptions = requestOptions
        self.timeoutNanoseconds = timeoutNanoseconds
        self.streamTimeout = streamTimeout
        self.retryPolicy = retryPolicy
        self.telemetry = telemetry
    }

    public init(
        id: String? = nil,
        model: any LanguageModel,
        instructions: String? = nil,
        executableTools: [AITool],
        toolCallers: AIToolCallerRouting,
        maxSteps: Int = 20,
        stopWhen: [AIStopCondition] = [],
        allowSystemInMessages: Bool = false,
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        requestOptions: AIChatRequestOptions = AIChatRequestOptions(),
        timeoutNanoseconds: UInt64? = nil,
        streamTimeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) {
        self.init(
            id: id,
            model: model,
            instructions: instructions,
            executableTools: executableTools,
            maxSteps: maxSteps,
            stopWhen: stopWhen,
            allowSystemInMessages: allowSystemInMessages,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            requestOptions: requestOptions,
            timeoutNanoseconds: timeoutNanoseconds,
            streamTimeout: streamTimeout,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
        self.toolCallers = toolCallers
    }

    public func generate(prompt: String, options: AIAgentCallOptions = AIAgentCallOptions()) async throws -> TextGenerationResult {
        try await generate(messages: [.user(prompt)], options: options)
    }

    public func generate(messages: [AIMessage], options: AIAgentCallOptions = AIAgentCallOptions()) async throws -> TextGenerationResult {
        try await AI.generateText(
            model: model,
            request: try request(messages: messages, options: options),
            executableTools: executableTools,
            maxSteps: maxSteps,
            toolCallers: toolCallers,
            stopWhen: effectiveStopConditions,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            retryPolicy: retryPolicy(for: options),
            telemetry: options.telemetry ?? telemetry
        )
    }

    public func stream(prompt: String, options: AIAgentCallOptions = AIAgentCallOptions()) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        stream(messages: [.user(prompt)], options: options)
    }

    public func stream(messages: [AIMessage], options: AIAgentCallOptions = AIAgentCallOptions()) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        let preparedRequest: LanguageModelRequest
        do {
            preparedRequest = try request(messages: messages, options: options)
        } catch {
            return failingPartStream(error)
        }
        return AI.streamText(
            model: model,
            request: preparedRequest,
            executableTools: executableTools,
            maxSteps: maxSteps,
            stopWhen: effectiveStopConditions,
            prepareStep: prepareStep,
            toolCallers: toolCallers,
            toolApproval: toolApproval,
            timeoutNanoseconds: options.timeoutNanoseconds ?? timeoutNanoseconds,
            timeout: options.streamTimeout
                ?? (options.timeoutNanoseconds == nil ? streamTimeout : nil),
            retryPolicy: retryPolicy(for: options),
            telemetry: options.telemetry ?? telemetry
        )
    }

    private var effectiveStopConditions: [AIStopCondition] {
        guard stopWhen.isEmpty, maxSteps == 20 else { return stopWhen }
        return [AIStopCondition { context in
            guard context.steps.count == 20, let step = context.steps.last else { return false }
            await AIWarningLogging.logWarnings([AIWarning(type: "other", message:
                "The tool loop stopped because it reached the default stopWhen condition, isStepCount(20). " +
                "To allow more steps, set stopWhen to isStepCount(...) with a higher limit or provide a custom stop condition. " +
                "Learn more: https://ai-sdk.dev/docs/agents/loop-control"
            )], providerID: step.providerID, modelID: step.modelID)
            return true
        }]
    }

    private func request(messages: [AIMessage], options: AIAgentCallOptions) throws -> LanguageModelRequest {
        guard allowSystemInMessages || !messages.contains(where: { $0.role == .system }) else {
            throw AIError.invalidArgument(
                argument: "messages",
                message: "System messages are not allowed in the prompt or messages fields. Use the instructions option instead."
            )
        }

        let effectiveOptions = mergedRequestOptions(options.requestOptions)
        var requestMessages = messages
        if let instructions, !instructions.isEmpty {
            requestMessages.insert(.system(instructions), at: 0)
        }
        return effectiveOptions.languageModelRequest(
            messages: requestMessages,
            abortSignal: options.abortSignal
        )
    }

    private func mergedRequestOptions(_ options: AIChatRequestOptions) -> AIChatRequestOptions {
        var merged = requestOptions
        merged.temperature = options.temperature ?? merged.temperature
        merged.topP = options.topP ?? merged.topP
        merged.topK = options.topK ?? merged.topK
        merged.presencePenalty = options.presencePenalty ?? merged.presencePenalty
        merged.frequencyPenalty = options.frequencyPenalty ?? merged.frequencyPenalty
        merged.seed = options.seed ?? merged.seed
        merged.maxOutputTokens = options.maxOutputTokens ?? merged.maxOutputTokens
        if !options.stopSequences.isEmpty { merged.stopSequences = options.stopSequences }
        merged.responseFormat = options.responseFormat ?? merged.responseFormat
        merged.reasoning = options.reasoning ?? merged.reasoning
        if !options.tools.isEmpty { merged.tools.merge(options.tools) { _, new in new } }
        if !options.toolContexts.isEmpty { merged.toolContexts.merge(options.toolContexts) { _, new in new } }
        merged.toolCallConcurrency = options.toolCallConcurrency ?? merged.toolCallConcurrency
        merged.toolChoice = options.toolChoice ?? merged.toolChoice
        merged.includeRawChunks = options.includeRawChunks || merged.includeRawChunks
        if !options.providerOptions.isEmpty { merged.providerOptions.merge(options.providerOptions) { _, new in new } }
        if !options.extraBody.isEmpty { merged.extraBody.merge(options.extraBody) { _, new in new } }
        if !options.headers.isEmpty { merged.headers.merge(options.headers) { _, new in new } }
        return merged
    }

    private func retryPolicy(for options: AIAgentCallOptions) -> AIRetryPolicy {
        var policy = options.retryPolicy ?? retryPolicy
        if let timeoutNanoseconds = options.timeoutNanoseconds ?? timeoutNanoseconds {
            policy.timeoutNanoseconds = timeoutNanoseconds
        }
        return policy
    }
}