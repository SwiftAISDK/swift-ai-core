import Foundation


public typealias AIDecisionQuestionType = AIEvaluationQuestionType
public typealias AIDecisionQuestion = AIEvaluationQuestion
public typealias AIDecisionRounding = AIEvaluationRounding
public typealias AIDecisionModelUsage = AIEvaluationModelUsage
public typealias AIDecisionUsage = AIEvaluationUsage
public typealias AIDecisionResponseMetadata = AIEvaluationResponseMetadata

/// Shared text, JSON data, or ordered evidence for an experimental decision.
public enum AIDecisionState: Equatable, Sendable, ExpressibleByStringLiteral {
    case text(String)
    case object([String: JSONValue])
    case parts([AIDecisionStatePart])

    public init(stringLiteral value: String) { self = .text(value) }
}

/// File content accepted by the decision core. URLs are downloaded before provider I/O.
public enum AIDecisionFileData: Equatable, Sendable {
    case data(Data)
    case base64(String)
    case url(URL)
    /// Provider-native references can be used only by adapters that support them.
    case reference(String)
}

/// Ordered state part matching the Decision Model V4 evidence envelope.
public enum AIDecisionStatePart: Equatable, Sendable {
    case text(String)
    case json(JSONValue)
    case file(mediaType: String, data: AIDecisionFileData, filename: String? = nil, providerOptions: [String: JSONValue] = [:])
}

public enum AIDecisionAnswerType: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case choice
    case score
    case boolean
    case box
    case refusal
}

/// Native provider answer; a refusal is valid for any question family.
public enum AIDecisionAnswer: Equatable, Sendable {
    case choice(choice: String, probabilities: [String: Double]? = nil)
    case score(score: Double, probabilities: [String: Double]? = nil)
    case boolean(probability: Double)
    case box(box: AIDecisionBox)
    case refusal

    public var type: AIDecisionAnswerType {
        switch self {
        case .choice: .choice
        case .score: .score
        case .boolean: .boolean
        case .box: .box
        case .refusal: .refusal
        }
    }

    public var questionType: AIDecisionQuestionType? {
        switch self {
        case .choice: .choice
        case .score: .score
        case .boolean: .boolean
        case .box: .box
        case .refusal: nil
        }
    }
}

public struct AIDecisionModelV4CallOptions: Sendable {
    public var state: [AIDecisionStatePart]
    public var questions: [String: AIDecisionQuestion]
    public var maxOutputTokens: Int?
    public var reasoning: String?
    public var abortSignal: AIAbortSignal?
    public var headers: [String: String]
    public var providerOptions: [String: JSONValue]

    public init(
        state: [AIDecisionStatePart],
        questions: [String: AIDecisionQuestion],
        maxOutputTokens: Int? = nil,
        reasoning: String? = nil,
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        providerOptions: [String: JSONValue] = [:]
    ) {
        self.state = state
        self.questions = questions
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.abortSignal = abortSignal
        self.headers = headers
        self.providerOptions = providerOptions
    }
}

public struct AIDecisionModelV4Result: Equatable, Sendable {
    public var answers: [String: AIDecisionAnswer]
    public var rounding: AIDecisionRounding?
    public var usage: AIDecisionModelUsage?
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var response: AIResponseMetadata?

    public init(
        answers: [String: AIDecisionAnswer],
        rounding: AIDecisionRounding? = nil,
        usage: AIDecisionModelUsage? = nil,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        response: AIResponseMetadata? = nil
    ) {
        self.answers = answers
        self.rounding = rounding
        self.usage = usage
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.response = response
    }
}

/// Validated decision result. Core rejects the entire operation when any question is refused.
public struct AIDecisionResult: Equatable, Sendable {
    public var answers: [String: AIDecisionAnswer]
    public var usage: AIDecisionUsage
    public var warnings: [AIWarning]
    public var rounding: AIDecisionRounding?
    public var providerMetadata: [String: JSONValue]
    public var response: AIDecisionResponseMetadata

    public init(
        answers: [String: AIDecisionAnswer],
        usage: AIDecisionUsage,
        warnings: [AIWarning] = [],
        rounding: AIDecisionRounding? = nil,
        providerMetadata: [String: JSONValue] = [:],
        response: AIDecisionResponseMetadata
    ) {
        self.answers = answers
        self.usage = usage
        self.warnings = warnings
        self.rounding = rounding
        self.providerMetadata = providerMetadata
        self.response = response
    }
}

/// Experimental decision contract matching `@ai-sdk/provider` Decision Model V4.
public protocol AIDecisionModelV4: Sendable {
    var specificationVersion: String { get }
    var providerID: String { get }
    var modelID: String { get }
    var supportedQuestionTypes: [AIDecisionQuestionType] { get }
    func doDecide(_ options: AIDecisionModelV4CallOptions) async throws -> AIDecisionModelV4Result
}

public extension AIDecisionModelV4 {
    var specificationVersion: String { "v4" }
}


public protocol AIDecisionProvider: Sendable {
    func decisionModel(_ modelID: String) throws -> any AIDecisionModelV4
}

public enum AIDecisionModelReference: Sendable, ExpressibleByStringLiteral {
    case model(any AIDecisionModelV4)
    case modelID(String)

    public init(_ model: any AIDecisionModelV4) { self = .model(model) }
    public init(_ modelID: String) { self = .modelID(modelID) }
    public init(stringLiteral value: String) { self = .modelID(value) }
}

public typealias AIDecisionUnsupportedQuestionTypeError = AIEvaluationUnsupportedQuestionTypeError

public struct AIDecisionRefusalError: Error, Equatable, CustomStringConvertible, Sendable {
    public var questionIDs: [String]
    public var providerID: String
    public var modelID: String
    public var message: String

    public init(questionIDs: [String], providerID: String, modelID: String, message: String? = nil) {
        self.questionIDs = questionIDs
        self.providerID = providerID
        self.modelID = modelID
        let quotedIDs = questionIDs.map { (try? decisionJSONText(.string($0))) ?? "\"\($0)\"" }.joined(separator: ", ")
        self.message = message ?? "Decision model \"\(modelID)\" from provider \"\(providerID)\" refused \(questionIDs.count == 1 ? "question" : "questions") \(quotedIDs)."
    }
    public var description: String { message }
}

public enum AIDecisionModelResolutionError: Error, Equatable, CustomStringConvertible, Sendable {
    case noSuchModel(modelID: String)
    case defaultProviderUnsupported(modelID: String)
    case unsupportedSpecificationVersion(version: String, providerID: String, modelID: String)

    public var description: String {
        switch self {
        case let .noSuchModel(modelID):
            "No decision model was found for '\(modelID)'."
        case let .defaultProviderUnsupported(modelID):
            "The default provider does not support decision model '\(modelID)'. Configure an AIDecisionProvider or pass a model instance."
        case let .unsupportedSpecificationVersion(version, providerID, modelID):
            "Decision model '\(providerID)/\(modelID)' uses unsupported specification version '\(version)'; expected 'v4'."
        }
    }
}

public typealias Experimental_DecisionModelV4 = AIDecisionModelV4
public typealias Experimental_DecisionModelV4Input = JSONValue
public typealias Experimental_DecisionModelV4State = [AIDecisionStatePart]
public typealias Experimental_DecisionModelV4StatePart = AIDecisionStatePart
public typealias Experimental_DecisionModelV4Question = AIDecisionQuestion
public typealias Experimental_DecisionModelV4Answer = AIDecisionAnswer
public typealias Experimental_DecisionModelV4CallOptions = AIDecisionModelV4CallOptions
public typealias Experimental_DecisionModelV4Result = AIDecisionModelV4Result
public typealias Experimental_DecisionModel = AIDecisionModelReference
public typealias Experimental_DecisionState = AIDecisionState
public typealias Experimental_DecisionStatePart = AIDecisionStatePart
public typealias Experimental_DecisionQuestion = AIDecisionQuestion
public typealias Experimental_DecisionAnswer = AIDecisionAnswer
public typealias Experimental_DecisionResult = AIDecisionResult
public typealias Experimental_DecisionRefusalError = AIDecisionRefusalError
public typealias Experimental_DecisionUnsupportedQuestionTypeError = AIDecisionUnsupportedQuestionTypeError

public func validateDecisionModelVersion(_ model: any AIDecisionModelV4) throws -> any AIDecisionModelV4 {
    guard model.specificationVersion == "v4" else {
        throw AIDecisionModelResolutionError.unsupportedSpecificationVersion(
            version: model.specificationVersion,
            providerID: model.providerID,
            modelID: model.modelID
        )
    }
    return model
}

func legacyEvaluationState(_ state: JSONValue) -> [AIDecisionStatePart] {
    if case let .string(text) = state { return [.text(text)] }
    return [.json(state)]
}

package func evaluationAnswers(from answers: [String: AIDecisionAnswer], providerID: String, modelID: String) throws -> [String: AIEvaluationAnswer] {
    let refused = answers.keys.sorted().filter { answers[$0] == .refusal }
    guard refused.isEmpty else {
        throw AIDecisionRefusalError(questionIDs: refused, providerID: providerID, modelID: modelID)
    }
    return answers.compactMapValues { answer in
        switch answer {
        case let .choice(choice, probabilities): .choice(choice: choice, probabilities: probabilities)
        case let .score(score, probabilities): .score(score: score, probabilities: probabilities)
        case let .boolean(probability): .boolean(probability: probability)
        case let .box(box): .box(box: box)
        case .refusal: nil
        }
    }
}

public func evaluationResult(from result: AIDecisionModelV4Result, providerID: String, modelID: String) throws -> AIEvaluationModelV4Result {
    AIEvaluationModelV4Result(
        answers: try evaluationAnswers(from: result.answers, providerID: providerID, modelID: modelID),
        rounding: result.rounding,
        usage: result.usage,
        warnings: result.warnings,
        providerMetadata: result.providerMetadata,
        response: result.response
    )
}

/// A decision adapter cannot process the supplied evidence type.
public struct AIDecisionUnsupportedFunctionalityError: Error, Equatable, CustomStringConvertible, Sendable {
    public var functionality: String
    public init(functionality: String) { self.functionality = functionality }
    public var description: String { "Unsupported functionality: \(functionality)" }
}