import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


/// Lifecycle payload delivered before an experimental evaluation begins.
public struct AIEvaluationStartEvent: Equatable, Sendable {
    public var runtimeContext: [String: JSONValue]
    public var callID: String
    public var operationID: String
    public var providerID: String
    public var modelID: String
    public var state: JSONValue
    public var questions: [String: AIEvaluationQuestion]
    public var maxRetries: Int
    public var headers: [String: String]
    public var providerOptions: [String: JSONValue]

    public init(
        runtimeContext: [String: JSONValue],
        callID: String,
        operationID: String = "ai.evaluate",
        providerID: String,
        modelID: String,
        state: JSONValue,
        questions: [String: AIEvaluationQuestion],
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
        self.maxRetries = maxRetries
        self.headers = headers
        self.providerOptions = providerOptions
    }
}

/// Lifecycle payload delivered after an experimental evaluation succeeds.
public struct AIEvaluationEndEvent: Equatable, Sendable {
    public var runtimeContext: [String: JSONValue]
    public var callID: String
    public var operationID: String
    public var providerID: String
    public var modelID: String
    public var state: JSONValue
    public var questions: [String: AIEvaluationQuestion]
    public var maxRetries: Int
    public var headers: [String: String]
    public var providerOptions: [String: JSONValue]
    public var answers: [String: AIEvaluationAnswer]
    public var usage: AIEvaluationUsage
    public var warnings: [AIWarning]
    public var rounding: AIEvaluationRounding?
    public var providerMetadata: [String: JSONValue]
    public var response: AIEvaluationResponseMetadata

    public init(
        runtimeContext: [String: JSONValue],
        callID: String,
        operationID: String = "ai.evaluate",
        providerID: String,
        modelID: String,
        state: JSONValue,
        questions: [String: AIEvaluationQuestion],
        maxRetries: Int,
        headers: [String: String],
        providerOptions: [String: JSONValue],
        answers: [String: AIEvaluationAnswer],
        usage: AIEvaluationUsage,
        warnings: [AIWarning],
        rounding: AIEvaluationRounding?,
        providerMetadata: [String: JSONValue],
        response: AIEvaluationResponseMetadata
    ) {
        self.runtimeContext = runtimeContext
        self.callID = callID
        self.operationID = operationID
        self.providerID = providerID
        self.modelID = modelID
        self.state = state
        self.questions = questions
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

/// Telemetry payload emitted before the logical evaluation model call.
public struct AIEvaluationModelCallStartEvent: Equatable, Sendable {
    public var callID: String
    public var operationID: String
    public var providerID: String
    public var modelID: String
    public var state: JSONValue
    public var questions: [String: AIEvaluationQuestion]

    public init(
        callID: String,
        operationID: String = "ai.evaluate.doEvaluate",
        providerID: String,
        modelID: String,
        state: JSONValue,
        questions: [String: AIEvaluationQuestion]
    ) {
        self.callID = callID
        self.operationID = operationID
        self.providerID = providerID
        self.modelID = modelID
        self.state = state
        self.questions = questions
    }
}

/// Telemetry payload emitted after the logical evaluation model response validates.
public struct AIEvaluationModelCallEndEvent: Equatable, Sendable {
    public var callID: String
    public var operationID: String
    public var providerID: String
    public var modelID: String
    public var state: JSONValue
    public var questions: [String: AIEvaluationQuestion]
    public var answers: [String: AIEvaluationAnswer]
    public var usage: AIEvaluationModelUsage?
    public var warnings: [AIWarning]
    public var rounding: AIEvaluationRounding?
    public var providerMetadata: [String: JSONValue]
    public var response: AIResponseMetadata?

    public init(
        callID: String,
        operationID: String = "ai.evaluate.doEvaluate",
        providerID: String,
        modelID: String,
        state: JSONValue,
        questions: [String: AIEvaluationQuestion],
        answers: [String: AIEvaluationAnswer],
        usage: AIEvaluationModelUsage?,
        warnings: [AIWarning],
        rounding: AIEvaluationRounding?,
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

public typealias Experimental_EvaluateStartEvent = AIEvaluationStartEvent
public typealias Experimental_EvaluateEndEvent = AIEvaluationEndEvent
public typealias Experimental_EvaluationModelCallStartEvent = AIEvaluationModelCallStartEvent
public typealias Experimental_EvaluationModelCallEndEvent = AIEvaluationModelCallEndEvent

func evaluationTelemetryInput(
    state: JSONValue,
    questions: [String: AIEvaluationQuestion],
    headers: [String: String]? = nil,
    providerOptions: [String: JSONValue]? = nil
) -> JSONValue {
    .object([
        "state": state,
        "questions": evaluationQuestionsTelemetryJSON(questions),
        "headers": headers.flatMap { $0.isEmpty ? nil : .object($0.mapValues(JSONValue.string)) },
        "providerOptions": providerOptions.flatMap { $0.isEmpty ? nil : .object($0) }
    ])
}

func evaluationModelTelemetryOutput(_ result: AIEvaluationModelV4Result) -> JSONValue {
    .object([
        "answers": evaluationAnswersTelemetryJSON(result.answers),
        "usage": result.usage.map(evaluationModelUsageTelemetryJSON),
        "warnings": .array(result.warnings.map(aiWarningJSON)),
        "rounding": result.rounding.map(evaluationRoundingTelemetryJSON),
        "providerMetadata": result.providerMetadata.isEmpty ? nil : .object(result.providerMetadata),
        "response": result.response.map(evaluationResponseTelemetryJSON)
    ])
}

func evaluationResultTelemetryOutput(_ result: AIEvaluationResult) -> JSONValue {
    .object([
        "answers": evaluationAnswersTelemetryJSON(result.answers),
        "usage": evaluationUsageTelemetryJSON(result.usage),
        "warnings": .array(result.warnings.map(aiWarningJSON)),
        "rounding": result.rounding.map(evaluationRoundingTelemetryJSON),
        "providerMetadata": result.providerMetadata.isEmpty ? nil : .object(result.providerMetadata),
        "response": evaluationResponseTelemetryJSON(result.response)
    ])
}

func evaluationTokenUsage(_ usage: AIEvaluationModelUsage?) -> TokenUsage? {
    guard let usage else { return nil }
    return evaluationTokenUsage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens)
}

func evaluationTokenUsage(_ usage: AIEvaluationUsage) -> TokenUsage {
    TokenUsage(
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        totalTokens: usage.totalTokens
    )
}

func evaluationResponseMetadata(_ response: AIEvaluationResponseMetadata) -> AIResponseMetadata {
    AIResponseMetadata(
        id: response.id,
        timestamp: response.timestamp,
        modelID: response.modelID,
        headers: response.headers,
        body: response.body
    )
}

func filterEvaluationRuntimeContext(
    _ runtimeContext: [String: JSONValue],
    include: [String: Bool]?
) -> [String: JSONValue] {
    runtimeContext.filter { include?[$0.key] == true }
}

private func evaluationTokenUsage(inputTokens: Int?, outputTokens: Int?) -> TokenUsage {
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

private func evaluationQuestionsTelemetryJSON(_ questions: [String: AIEvaluationQuestion]) -> JSONValue {
    .object(questions.mapValues(evaluationQuestionTelemetryJSON))
}

private func evaluationQuestionTelemetryJSON(_ question: AIEvaluationQuestion) -> JSONValue {
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

private func evaluationAnswersTelemetryJSON(_ answers: [String: AIEvaluationAnswer]) -> JSONValue {
    .object(answers.mapValues(evaluationAnswerTelemetryJSON))
}

private func evaluationAnswerTelemetryJSON(_ answer: AIEvaluationAnswer) -> JSONValue {
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
    case let .box(box):
        return .object(["type": "box", "box": box.jsonValue])
    case let .boolean(probability):
        return .object([
            "type": .string("boolean"),
            "probability": .number(probability)
        ])
    }
}

private func evaluationModelUsageTelemetryJSON(_ usage: AIEvaluationModelUsage) -> JSONValue {
    .object([
        "inputTokens": usage.inputTokens.map { .number(Double($0)) },
        "outputTokens": usage.outputTokens.map { .number(Double($0)) }
    ])
}

private func evaluationUsageTelemetryJSON(_ usage: AIEvaluationUsage) -> JSONValue {
    .object([
        "inputTokens": usage.inputTokens.map { .number(Double($0)) },
        "outputTokens": usage.outputTokens.map { .number(Double($0)) },
        "totalTokens": usage.totalTokens.map { .number(Double($0)) }
    ])
}

private func evaluationRoundingTelemetryJSON(_ rounding: AIEvaluationRounding) -> JSONValue {
    .object([
        "probabilityDecimals": rounding.probabilityDecimals.map { .number(Double($0)) },
        "scoreDecimals": rounding.scoreDecimals.map { .number(Double($0)) }
    ])
}

private func evaluationResponseTelemetryJSON(_ response: AIResponseMetadata) -> JSONValue {
    .object([
        "id": response.id.map(JSONValue.string),
        "timestamp": response.timestamp.map { .number($0.timeIntervalSince1970) },
        "modelId": response.modelID.map(JSONValue.string),
        "headers": response.headers.isEmpty ? nil : .object(response.headers.mapValues(JSONValue.string)),
        "body": response.body
    ])
}

private func evaluationResponseTelemetryJSON(_ response: AIEvaluationResponseMetadata) -> JSONValue {
    .object([
        "id": response.id.map(JSONValue.string),
        "timestamp": .number(response.timestamp.timeIntervalSince1970),
        "modelId": .string(response.modelID),
        "headers": response.headers.isEmpty ? nil : .object(response.headers.mapValues(JSONValue.string)),
        "body": response.body
    ])
}