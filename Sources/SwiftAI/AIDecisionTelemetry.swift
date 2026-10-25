import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


/// Lifecycle payload delivered before an experimental decision begins.
public struct AIDecisionStartEvent: Equatable, Sendable {
    public var runtimeContext: [String: JSONValue]
    public var callID: String
    public var operationID: String
    public var providerID: String
    public var modelID: String
    public var state: AIDecisionState
    public var questions: [String: AIDecisionQuestion]
    public var maxOutputTokens: Int?
    public var reasoning: String?
    public var maxRetries: Int
    public var headers: [String: String]
    public var providerOptions: [String: JSONValue]

    public init(
        runtimeContext: [String: JSONValue],
        callID: String,
        operationID: String = "ai.decide",
        providerID: String,
        modelID: String,
        state: AIDecisionState,
        questions: [String: AIDecisionQuestion],
        maxOutputTokens: Int? = nil,
        reasoning: String? = nil,
        maxRetries: Int,
        headers: [String: String],
        providerOptions: [String: JSONValue]
    ) {
        self.runtimeContext = runtimeContext
        self.callID = callID
        self.operationID = operationID
        self.providerID = providerID
        self.modelID = modelID
        self.state = state
        self.questions = questions
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.maxRetries = maxRetries
        self.headers = headers
        self.providerOptions = providerOptions
    }
}

/// Lifecycle payload delivered after an experimental decision succeeds.
public struct AIDecisionEndEvent: Equatable, Sendable {
    public var runtimeContext: [String: JSONValue]
    public var callID: String
    public var operationID: String
    public var providerID: String
    public var modelID: String
    public var state: AIDecisionState
    public var questions: [String: AIDecisionQuestion]
    public var maxOutputTokens: Int?
    public var reasoning: String?
    public var maxRetries: Int
    public var headers: [String: String]
    public var providerOptions: [String: JSONValue]
    public var answers: [String: AIDecisionAnswer]
    public var usage: AIDecisionUsage
    public var warnings: [AIWarning]
    public var rounding: AIDecisionRounding?
    public var providerMetadata: [String: JSONValue]
    public var response: AIDecisionResponseMetadata

    public init(
        runtimeContext: [String: JSONValue],
        callID: String,
        operationID: String = "ai.decide",
        providerID: String,
        modelID: String,
        state: AIDecisionState,
        questions: [String: AIDecisionQuestion],
        maxOutputTokens: Int? = nil,
        reasoning: String? = nil,
        maxRetries: Int,
        headers: [String: String],
        providerOptions: [String: JSONValue],
        answers: [String: AIDecisionAnswer],
        usage: AIDecisionUsage,
        warnings: [AIWarning],
        rounding: AIDecisionRounding?,
        providerMetadata: [String: JSONValue],
        response: AIDecisionResponseMetadata
    ) {
        self.runtimeContext = runtimeContext
        self.callID = callID
        self.operationID = operationID
        self.providerID = providerID
        self.modelID = modelID
        self.state = state
        self.questions = questions
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.maxRetries = maxRetries
        self.headers = headers
        self.providerOptions = providerOptions
        self.answers = answers
        self.usage = usage
        self.warnings = warnings
        self.rounding = rounding
        self.providerMetadata = providerMetadata
        self.response = response
    }
}

/// Telemetry payload emitted before the logical decision model call.
public struct AIDecisionModelCallStartEvent: Equatable, Sendable {
    public var callID: String
    public var operationID: String
    public var providerID: String
    public var modelID: String
    public var state: [AIDecisionStatePart]
    public var questions: [String: AIDecisionQuestion]

    public init(
        callID: String,
        operationID: String = "ai.decide.doDecide",
        providerID: String,
        modelID: String,
        state: [AIDecisionStatePart],
        questions: [String: AIDecisionQuestion]
    ) {
        self.callID = callID
        self.operationID = operationID
        self.providerID = providerID
        self.modelID = modelID
        self.state = state
        self.questions = questions
    }
}

/// Telemetry payload emitted after the logical decision model response validates.
public struct AIDecisionModelCallEndEvent: Equatable, Sendable {
    public var callID: String
    public var operationID: String
    public var providerID: String
    public var modelID: String
    public var state: [AIDecisionStatePart]
    public var questions: [String: AIDecisionQuestion]
    public var answers: [String: AIDecisionAnswer]
    public var usage: AIDecisionModelUsage?
    public var warnings: [AIWarning]
    public var rounding: AIDecisionRounding?
    public var providerMetadata: [String: JSONValue]
    public var response: AIResponseMetadata?

    public init(
        callID: String,
        operationID: String = "ai.decide.doDecide",
        providerID: String,
        modelID: String,
        state: [AIDecisionStatePart],
        questions: [String: AIDecisionQuestion],
        answers: [String: AIDecisionAnswer],
        usage: AIDecisionModelUsage?,
        warnings: [AIWarning],
        rounding: AIDecisionRounding?,
        providerMetadata: [String: JSONValue],
        response: AIResponseMetadata?
    ) {
        self.callID = callID
        self.operationID = operationID
        self.providerID = providerID
        self.modelID = modelID
        self.state = state
        self.questions = questions
        self.answers = answers
        self.usage = usage
        self.warnings = warnings
        self.rounding = rounding
        self.providerMetadata = providerMetadata
        self.response = response
    }
}

public typealias Experimental_DecideStartEvent = AIDecisionStartEvent
public typealias Experimental_DecideEndEvent = AIDecisionEndEvent
public typealias Experimental_DecisionModelCallStartEvent = AIDecisionModelCallStartEvent
public typealias Experimental_DecisionModelCallEndEvent = AIDecisionModelCallEndEvent

func decisionTelemetryInput(
    state: AIDecisionState,
    questions: [String: AIDecisionQuestion],
    maxOutputTokens: Int? = nil,
    reasoning: String? = nil,
    headers: [String: String]? = nil,
    providerOptions: [String: JSONValue]? = nil
) -> JSONValue {
    .object([
        "state": decisionStateJSON(state),
        "questions": decisionQuestionsTelemetryJSON(questions),
        "maxOutputTokens": maxOutputTokens.map { .number(Double($0)) },
        "reasoning": reasoning.map(JSONValue.string),
        "headers": headers.flatMap { $0.isEmpty ? nil : .object($0.mapValues(JSONValue.string)) },
        "providerOptions": providerOptions.flatMap { $0.isEmpty ? nil : .object($0) }
    ])
}

func decisionModelTelemetryOutput(_ result: AIDecisionModelV4Result) -> JSONValue {
    .object([
        "answers": decisionAnswersTelemetryJSON(result.answers),
        "usage": result.usage.map(decisionModelUsageTelemetryJSON),
        "warnings": .array(result.warnings.map(aiWarningJSON)),
        "rounding": result.rounding.map(decisionRoundingTelemetryJSON),
        "providerMetadata": result.providerMetadata.isEmpty ? nil : .object(result.providerMetadata),
        "response": result.response.map(decisionResponseTelemetryJSON)
    ])
}

func decisionResultTelemetryOutput(_ result: AIDecisionResult) -> JSONValue {
    .object([
        "answers": decisionAnswersTelemetryJSON(result.answers),
        "usage": decisionUsageTelemetryJSON(result.usage),
        "warnings": .array(result.warnings.map(aiWarningJSON)),
        "rounding": result.rounding.map(decisionRoundingTelemetryJSON),
        "providerMetadata": result.providerMetadata.isEmpty ? nil : .object(result.providerMetadata),
        "response": decisionResponseTelemetryJSON(result.response)
    ])
}

func decisionTokenUsage(_ usage: AIDecisionModelUsage?) -> TokenUsage? {
    guard let usage else { return nil }
    return decisionTokenUsage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens)
}

func decisionTokenUsage(_ usage: AIDecisionUsage) -> TokenUsage {
    TokenUsage(
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        totalTokens: usage.totalTokens
    )
}

func decisionResponseMetadata(_ response: AIDecisionResponseMetadata) -> AIResponseMetadata {
    AIResponseMetadata(
        id: response.id,
        timestamp: response.timestamp,
        modelID: response.modelID,
        headers: response.headers,
        body: response.body
    )
}

func filterDecisionRuntimeContext(
    _ runtimeContext: [String: JSONValue],
    include: [String: Bool]?
) -> [String: JSONValue] {
    runtimeContext.filter { include?[$0.key] == true }
}

private func decisionTokenUsage(inputTokens: Int?, outputTokens: Int?) -> TokenUsage {
    let totalTokens: Int?
    if let inputTokens, let outputTokens {
        let total = inputTokens.addingReportingOverflow(outputTokens)
        totalTokens = total.overflow ? nil : total.partialValue
    } else {
        totalTokens = nil
    }
    return TokenUsage(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        totalTokens: totalTokens
    )
}

func decisionQuestionsTelemetryJSON(_ questions: [String: AIDecisionQuestion]) -> JSONValue {
    .object(questions.mapValues(decisionQuestionTelemetryJSON))
}

private func decisionQuestionTelemetryJSON(_ question: AIDecisionQuestion) -> JSONValue {
    switch question {
    case let .choice(instructions, criteria):
        return .object([
            "type": .string("choice"),
            "instructions": instructions,
            "criteria": .object(criteria)
        ])
    case let .score(instructions, criteria):
        return .object([
            "type": .string("score"),
            "instructions": instructions,
            "criteria": .array(criteria)
        ])
    case let .box(instructions):
        return .object(["type": "box", "instructions": instructions])
    case let .boolean(instructions, criteria):
        return .object([
            "type": .string("boolean"),
            "instructions": instructions,
            "criteria": criteria.map { .object($0) }
        ])
    }
}

func decisionAnswersTelemetryJSON(_ answers: [String: AIDecisionAnswer]) -> JSONValue {
    .object(answers.mapValues(decisionAnswerTelemetryJSON))
}

private func decisionAnswerTelemetryJSON(_ answer: AIDecisionAnswer) -> JSONValue {
    switch answer {
    case let .choice(choice, probabilities):
        return .object([
            "type": .string("choice"),
            "choice": .string(choice),
            "probabilities": probabilities.map { .object($0.mapValues(JSONValue.number)) }
        ])
    case let .score(score, probabilities):
        return .object([
            "type": .string("score"),
            "score": .number(score),
            "probabilities": probabilities.map { .object($0.mapValues(JSONValue.number)) }
        ])
    case .refusal:
        return .object(["type": .string("refusal")])
    case let .box(box):
        return .object(["type": "box", "box": box.jsonValue])
    case let .boolean(probability):
        return .object([
            "type": .string("boolean"),
            "probability": .number(probability)
        ])
    }
}

private func decisionModelUsageTelemetryJSON(_ usage: AIDecisionModelUsage) -> JSONValue {
    .object([
        "inputTokens": usage.inputTokens.map { .number(Double($0)) },
        "outputTokens": usage.outputTokens.map { .number(Double($0)) }
    ])
}

private func decisionUsageTelemetryJSON(_ usage: AIDecisionUsage) -> JSONValue {
    .object([
        "inputTokens": usage.inputTokens.map { .number(Double($0)) },
        "outputTokens": usage.outputTokens.map { .number(Double($0)) },
        "totalTokens": usage.totalTokens.map { .number(Double($0)) }
    ])
}

private func decisionRoundingTelemetryJSON(_ rounding: AIDecisionRounding) -> JSONValue {
    .object([
        "probabilityDecimals": rounding.probabilityDecimals.map { .number(Double($0)) },
        "scoreDecimals": rounding.scoreDecimals.map { .number(Double($0)) }
    ])
}

private func decisionResponseTelemetryJSON(_ response: AIResponseMetadata) -> JSONValue {
    .object([
        "id": response.id.map(JSONValue.string),
        "timestamp": response.timestamp.map { .number($0.timeIntervalSince1970) },
        "modelId": response.modelID.map(JSONValue.string),
        "headers": response.headers.isEmpty ? nil : .object(response.headers.mapValues(JSONValue.string)),
        "body": response.body
    ])
}

private func decisionResponseTelemetryJSON(_ response: AIDecisionResponseMetadata) -> JSONValue {
    .object([
        "id": response.id.map(JSONValue.string),
        "timestamp": .number(response.timestamp.timeIntervalSince1970),
        "modelId": .string(response.modelID),
        "headers": response.headers.isEmpty ? nil : .object(response.headers.mapValues(JSONValue.string)),
        "body": response.body
    ])
}

func decisionTelemetryInput(state: [AIDecisionStatePart], questions: [String: AIDecisionQuestion], maxOutputTokens: Int? = nil, reasoning: String? = nil) -> JSONValue {
    decisionTelemetryInput(state: .parts(state), questions: questions, maxOutputTokens: maxOutputTokens, reasoning: reasoning)
}

func decisionStateJSON(_ state: AIDecisionState) -> JSONValue {
    switch state {
    case let .text(text): .string(text)
    case let .object(value): .object(value)
    case let .parts(parts): .array(parts.map(decisionStatePartJSON))
    }
}

func decisionState(from value: JSONValue) -> AIDecisionState? {
    if let text = value.stringValue { return .text(text) }
    if let object = value.objectValue { return .object(object) }
    guard let parts = decisionStateParts(from: value) else { return nil }
    return .parts(parts)
}

func decisionStateParts(from value: JSONValue) -> [AIDecisionStatePart]? {
    guard let array = value.arrayValue else { return nil }
    var parts: [AIDecisionStatePart] = []
    for value in array {
        switch value["type"]?.stringValue {
        case "text":
            guard let text = value["text"]?.stringValue else { return nil }
            parts.append(.text(text))
        case "json":
            guard let json = value["value"] else { return nil }
            parts.append(.json(json))
        case "file":
            guard let mediaType = value["mediaType"]?.stringValue, let data = value["data"] else { return nil }
            let fileData: AIDecisionFileData
            switch data["type"]?.stringValue {
            case "data":
                guard let base64 = data["data"]?.stringValue else { return nil }
                fileData = .base64(base64)
            case "url":
                guard let text = data["url"]?.stringValue, let url = URL(string: text) else { return nil }
                fileData = .url(url)
            case "reference":
                guard let reference = data["reference"]?.stringValue else { return nil }
                fileData = .reference(reference)
            default: return nil
            }
            parts.append(.file(mediaType: mediaType, data: fileData, filename: value["filename"]?.stringValue, providerOptions: value["providerOptions"]?.objectValue ?? [:]))
        default: return nil
        }
    }
    return parts
}