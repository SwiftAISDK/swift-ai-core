import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public struct AIChatRequestOptions: Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var seed: Int?
    public var maxOutputTokens: Int?
    public var stopSequences: [String]
    public var responseFormat: AIResponseFormat?
    public var reasoning: String?
    public var tools: [String: JSONValue]
    public var toolContexts: [String: JSONValue]
    public var toolCallConcurrency: Int? = nil
    public var toolChoice: JSONValue?
    public var includeRawChunks: Bool
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        responseFormat: AIResponseFormat? = nil,
        reasoning: String? = nil,
        tools: [String: JSONValue] = [:],
        toolContexts: [String: JSONValue] = [:],
        toolChoice: JSONValue? = nil,
        includeRawChunks: Bool = false,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:]
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.seed = seed
        self.maxOutputTokens = maxOutputTokens
        self.stopSequences = stopSequences
        self.responseFormat = responseFormat
        self.reasoning = reasoning
        self.tools = tools
        self.toolContexts = toolContexts
        self.toolChoice = toolChoice
        self.includeRawChunks = includeRawChunks
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
    }

    public func languageModelRequest(
        messages: [AIMessage],
        abortSignal: AIAbortSignal? = nil,
        headers additionalHeaders: [String: String] = [:]
    ) -> LanguageModelRequest {
        var request = LanguageModelRequest(
            messages: messages,
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed,
            maxOutputTokens: maxOutputTokens,
            stopSequences: stopSequences,
            responseFormat: responseFormat,
            reasoning: reasoning,
            tools: tools,
            toolContexts: toolContexts,
            toolChoice: toolChoice,
            includeRawChunks: includeRawChunks,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers.merging(additionalHeaders) { _, new in new },
            abortSignal: abortSignal
        )
        request.toolCallConcurrency = toolCallConcurrency
        return request
    }
}