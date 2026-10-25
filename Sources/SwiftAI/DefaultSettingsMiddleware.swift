import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public struct AIDefaultLanguageModelSettings: Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var seed: Int?
    public var maxOutputTokens: Int?
    public var stopSequences: [String]?
    public var responseFormat: AIResponseFormat?
    public var reasoning: String?
    public var tools: [String: JSONValue]
    public var toolChoice: JSONValue?
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
        stopSequences: [String]? = nil,
        responseFormat: AIResponseFormat? = nil,
        reasoning: String? = nil,
        tools: [String: JSONValue] = [:],
        toolChoice: JSONValue? = nil,
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
        self.toolChoice = toolChoice
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
    }
}

public func defaultSettingsMiddleware(settings: AIDefaultLanguageModelSettings) -> AILanguageModelMiddleware {
    AILanguageModelMiddleware(transformRequest: { context in
        applyingDefaultSettings(settings, to: context.request)
    })
}

public func defaultInstructionsMiddleware(instructions: String) -> AILanguageModelMiddleware {
    defaultInstructionsMiddleware(instructions: [.system(instructions)])
}

public func defaultInstructionsMiddleware(instructions: [AIMessage]) -> AILanguageModelMiddleware {
    let systemMessages = instructions.map { message in
        AIMessage(
            role: .system,
            content: message.content,
            reasoning: message.reasoning,
            providerMetadata: message.providerMetadata
        )
    }
    return AILanguageModelMiddleware(transformRequest: { context in
        applyingDefaultInstructions(systemMessages, to: context.request)
    })
}

public struct AIDefaultEmbeddingModelSettings: Sendable {
    public var providerOptions: [String: JSONValue]
    public var headers: [String: String]

    public init(
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:]
    ) {
        self.providerOptions = providerOptions
        self.headers = headers
    }
}

public func defaultEmbeddingSettingsMiddleware(settings: AIDefaultEmbeddingModelSettings) -> AIEmbeddingModelMiddleware {
    AIEmbeddingModelMiddleware(transformRequest: { context in
        applyingDefaultEmbeddingSettings(settings, to: context.request)
    })
}

func applyingDefaultSettings(_ settings: AIDefaultLanguageModelSettings, to request: LanguageModelRequest) -> LanguageModelRequest {
    var output = request
    output.temperature = output.temperature ?? settings.temperature
    output.topP = output.topP ?? settings.topP
    output.topK = output.topK ?? settings.topK
    output.presencePenalty = output.presencePenalty ?? settings.presencePenalty
    output.frequencyPenalty = output.frequencyPenalty ?? settings.frequencyPenalty
    output.seed = output.seed ?? settings.seed
    output.maxOutputTokens = output.maxOutputTokens ?? settings.maxOutputTokens
    if output.stopSequences.isEmpty, let stopSequences = settings.stopSequences {
        output.stopSequences = stopSequences
    }
    output.responseFormat = output.responseFormat ?? settings.responseFormat
    output.reasoning = output.reasoning ?? settings.reasoning
    output.tools = mergeJSONDictionaries(settings.tools, output.tools)
    output.toolChoice = output.toolChoice ?? settings.toolChoice
    output.providerOptions = mergeJSONDictionaries(settings.providerOptions, output.providerOptions)
    output.extraBody = mergeJSONDictionaries(settings.extraBody, output.extraBody)
    output.headers = settings.headers.merging(output.headers) { _, request in request }
    return output
}

func applyingDefaultInstructions(_ instructions: [AIMessage], to request: LanguageModelRequest) -> LanguageModelRequest {
    guard !instructions.isEmpty,
          !request.messages.contains(where: { $0.role == .system }) else {
        return request
    }
    var output = request
    output.messages.insert(contentsOf: instructions, at: 0)
    return output
}

func applyingDefaultEmbeddingSettings(
    _ settings: AIDefaultEmbeddingModelSettings,
    to request: EmbeddingRequest
) -> EmbeddingRequest {
    var output = request
    output.providerOptions = mergeJSONDictionaries(settings.providerOptions, output.providerOptions)
    output.headers = settings.headers.merging(output.headers) { _, request in request }
    return output
}

func mergeJSONDictionaries(_ defaults: [String: JSONValue], _ overrides: [String: JSONValue]) -> [String: JSONValue] {
    mergeObjects(defaults, overrides) ?? [:]
}