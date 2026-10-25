import Foundation


/// The question families supported by Evaluation Model V4.
public enum AIEvaluationQuestionType: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case choice
    case score
    case boolean
    case box
}

/// Shared question shape for experimental Evaluation and Decision Model V4.
/// Decision permits omitted non-Box instructions; legacy Evaluation requires them.
public enum AIEvaluationQuestion: Equatable, Sendable {
    /// Select one label from a nonempty criteria map.
    case choice(instructions: JSONValue = .null, criteria: [String: JSONValue])
    /// Return a fractional position over ordered rubric levels (Decision: one or more; Evaluation: two or more).
    case score(instructions: JSONValue = .null, criteria: [JSONValue])
    /// Return P(true), optionally using descriptions keyed by `true` and `false`.
    case boolean(instructions: JSONValue = .null, criteria: [String: JSONValue]? = nil)
    /// Locate a rectangle in image evidence using normalized edges.
    case box(instructions: JSONValue)

    public var type: AIEvaluationQuestionType {
        switch self {
        case .choice: .choice
        case .score: .score
        case .boolean: .boolean
        case .box: .box
        }
    }

    public var instructions: JSONValue {
        switch self {
        case let .choice(instructions, _),
             let .score(instructions, _),
             let .boolean(instructions, _),
             let .box(instructions):
            instructions
        }
    }
}

/// A provider answer for one Evaluation Model V4 question.
public enum AIEvaluationAnswer: Equatable, Sendable {
    case choice(choice: String, probabilities: [String: Double]? = nil)
    case score(score: Double, probabilities: [String: Double]? = nil)
    case boolean(probability: Double)
    case box(box: AIDecisionBox)

    public var type: AIEvaluationQuestionType {
        switch self {
        case .choice: .choice
        case .score: .score
        case .boolean: .boolean
        case .box: .box
        }
    }
}

/// Decimal precision declared by an evaluation provider for rounded values.
public struct AIEvaluationRounding: Equatable, Sendable {
    public var probabilityDecimals: Int?
    public var scoreDecimals: Int?

    public init(probabilityDecimals: Int? = nil, scoreDecimals: Int? = nil) {
        self.probabilityDecimals = probabilityDecimals
        self.scoreDecimals = scoreDecimals
    }
}

/// Token usage returned directly by an evaluation provider.
public struct AIEvaluationModelUsage: Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Normalized usage returned by the core evaluation facade.
public struct AIEvaluationUsage: Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

/// Response metadata normalized by the core evaluation facade.
public struct AIEvaluationResponseMetadata: Equatable, Sendable {
    public var id: String?
    public var timestamp: Date
    public var modelID: String
    public var headers: [String: String]
    public var body: JSONValue?

    public init(
        id: String? = nil,
        timestamp: Date,
        modelID: String,
        headers: [String: String] = [:],
        body: JSONValue? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modelID = modelID
        self.headers = headers
        self.body = body
    }
}

/// Options passed to an Evaluation Model V4 implementation.
public struct AIEvaluationModelV4CallOptions: Sendable {
    public var state: JSONValue
    public var stateParts: [AIDecisionStatePart]?
    public var questions: [String: AIEvaluationQuestion]
    public var abortSignal: AIAbortSignal?
    public var headers: [String: String]
    public var providerOptions: [String: JSONValue]

    public init(
        state: JSONValue,
        questions: [String: AIEvaluationQuestion],
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        providerOptions: [String: JSONValue] = [:]
    ) {
        self.state = state
        self.stateParts = nil
        self.questions = questions
        self.abortSignal = abortSignal
        self.headers = headers
        self.providerOptions = providerOptions
    }
}

public extension AIEvaluationModelV4CallOptions {
    /// Ordered state overload retaining the original JSON-state initializer.
    init(stateParts: [AIDecisionStatePart], questions: [String: AIEvaluationQuestion], abortSignal: AIAbortSignal? = nil, headers: [String: String] = [:], providerOptions: [String: JSONValue] = [:]) {
        self.init(state: .string(""), questions: questions, abortSignal: abortSignal, headers: headers, providerOptions: providerOptions)
        self.stateParts = stateParts
    }

    public var decisionOptions: AIDecisionModelV4CallOptions {
        AIDecisionModelV4CallOptions(state: stateParts ?? legacyEvaluationState(state), questions: questions, abortSignal: abortSignal, headers: headers, providerOptions: providerOptions)
    }
}


/// Raw result returned by an Evaluation Model V4 implementation.
public struct AIEvaluationModelV4Result: Equatable, Sendable {
    public var answers: [String: AIEvaluationAnswer]
    public var rounding: AIEvaluationRounding?
    public var usage: AIEvaluationModelUsage?
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var response: AIResponseMetadata?

    public init(
        answers: [String: AIEvaluationAnswer],
        rounding: AIEvaluationRounding? = nil,
        usage: AIEvaluationModelUsage? = nil,
        warnings: [AIWarning],
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

/// Validated result returned by `AI.experimentalEvaluate`.
public struct AIEvaluationResult: Equatable, Sendable {
    public var answers: [String: AIEvaluationAnswer]
    public var usage: AIEvaluationUsage
    public var warnings: [AIWarning]
    public var rounding: AIEvaluationRounding?
    public var providerMetadata: [String: JSONValue]
    public var response: AIEvaluationResponseMetadata

    public init(
        answers: [String: AIEvaluationAnswer],
        usage: AIEvaluationUsage,
        warnings: [AIWarning],
        rounding: AIEvaluationRounding? = nil,
        providerMetadata: [String: JSONValue] = [:],
        response: AIEvaluationResponseMetadata
    ) {
        self.answers = answers
        self.usage = usage
        self.warnings = warnings
        self.rounding = rounding
        self.providerMetadata = providerMetadata
        self.response = response
    }
}

/// Experimental provider contract matching `@ai-sdk/provider` Evaluation Model V4.
public protocol AIEvaluationModelV4: Sendable {
    var specificationVersion: String { get }
    var providerID: String { get }
    var modelID: String { get }
    var supportedQuestionTypes: [AIEvaluationQuestionType] { get }
    func doEvaluate(_ options: AIEvaluationModelV4CallOptions) async throws -> AIEvaluationModelV4Result
}

public extension AIEvaluationModelV4 {
    var specificationVersion: String { "v4" }
}


/// Structural extension kept separate from the stable `AIProvider` protocol.
public protocol AIEvaluationProvider: Sendable {
    func evaluationModel(_ modelID: String) throws -> any AIEvaluationModelV4
}

/// A direct model or a model ID resolved by the configured default provider.
public enum AIEvaluationModelReference: Sendable, ExpressibleByStringLiteral {
    case model(any AIEvaluationModelV4)
    case modelID(String)

    public init(_ model: any AIEvaluationModelV4) {
        self = .model(model)
    }

    public init(_ modelID: String) {
        self = .modelID(modelID)
    }

    public init(stringLiteral value: String) {
        self = .modelID(value)
    }
}

public struct AIEvaluationUnsupportedQuestionTypeError: Error, Equatable, CustomStringConvertible, Sendable {
    public var questionID: String
    public var questionType: AIEvaluationQuestionType
    public var providerID: String
    public var modelID: String
    public var message: String

    public init(
        questionID: String,
        questionType: AIEvaluationQuestionType,
        providerID: String,
        modelID: String,
        message: String? = nil
    ) {
        self.questionID = questionID
        self.questionType = questionType
        self.providerID = providerID
        self.modelID = modelID
        self.message = message ?? "Question \"\(questionID)\" has type \"\(questionType.rawValue)\", which is not supported by provider \"\(providerID)\" and model \"\(modelID)\"."
    }

    public var description: String { message }
}

public enum AIEvaluationModelResolutionError: Error, Equatable, CustomStringConvertible, Sendable {
    case noSuchModel(modelID: String)
    case defaultProviderUnsupported(modelID: String)
    case unsupportedSpecificationVersion(version: String, providerID: String, modelID: String)

    public var description: String {
        switch self {
        case let .noSuchModel(modelID):
            "No evaluation model was found for '\(modelID)'."
        case let .defaultProviderUnsupported(modelID):
            "The default provider does not support evaluation model '\(modelID)'. Pass an evaluation model instance or configure a default provider that conforms to AIEvaluationProvider."
        case let .unsupportedSpecificationVersion(version, providerID, modelID):
            "Evaluation model '\(providerID)/\(modelID)' uses unsupported specification version '\(version)'; expected 'v4'."
        }
    }
}

// Upstream-compatible experimental aliases.
public typealias Experimental_EvaluationModelV4 = AIEvaluationModelV4
public typealias Experimental_EvaluationModelV4Input = JSONValue
public typealias Experimental_EvaluationModelV4Question = AIEvaluationQuestion
public typealias Experimental_EvaluationModelV4Answer = AIEvaluationAnswer
public typealias Experimental_EvaluationModelV4CallOptions = AIEvaluationModelV4CallOptions
public typealias Experimental_EvaluationModelV4Result = AIEvaluationModelV4Result
public typealias Experimental_EvaluationUnsupportedQuestionTypeError = AIEvaluationUnsupportedQuestionTypeError
public typealias Experimental_EvaluationModel = AIEvaluationModelReference
public typealias Experimental_EvaluationQuestion = AIEvaluationQuestion
public typealias Experimental_EvaluationAnswer = AIEvaluationAnswer
public typealias Experimental_EvaluationResult = AIEvaluationResult

public func validateEvaluationModelVersion(_ model: any AIEvaluationModelV4) throws -> any AIEvaluationModelV4 {
    guard model.specificationVersion == "v4" else {
        throw AIEvaluationModelResolutionError.unsupportedSpecificationVersion(
            version: model.specificationVersion,
            providerID: model.providerID,
            modelID: model.modelID
        )
    }
    return model
}

public func validateEvaluationInput(
    state: JSONValue,
    questions: [String: AIEvaluationQuestion],
    decision: Bool = false
) throws {
    guard isEvaluationInput(state) else {
        throw AIError.invalidArgument(
            argument: "state",
            message: "must be a JSON-compatible string, object, or array"
        )
    }
    guard !questions.isEmpty else {
        throw AIError.invalidArgument(
            argument: "questions",
            message: "must be a nonempty question map"
        )
    }

    for (id, question) in questions {
        let argument = "questions.\(id)"
        guard (decision && question.type != .box && question.instructions == .null) || isEvaluationInput(question.instructions) else {
            throw AIError.invalidArgument(
                argument: argument,
                message: "instructions must be a JSON-compatible string, object, or array"
            )
        }

        let criteria: [JSONValue]
        switch question {
        case .box:
            criteria = []
        case let .choice(_, options):
            guard !options.isEmpty else {
                throw AIError.invalidArgument(
                    argument: argument,
                    message: "choice criteria must be a nonempty option map"
                )
            }
            criteria = Array(options.values)
        case let .score(_, levels):
            guard levels.count >= (decision ? 1 : 2) else {
                throw AIError.invalidArgument(
                    argument: argument,
                    message: decision ? "score criteria must contain at least one ordered level" : "score criteria must contain at least two ordered levels"
                )
            }
            criteria = levels
        case let .boolean(_, descriptions):
            let descriptions = descriptions ?? [:]
            if decision && question.instructions == .null && !descriptions.values.contains(where: { $0 != .null }) {
                throw AIError.invalidArgument(argument: argument, message: "boolean questions require instructions or at least one non-null criterion")
            }
            guard descriptions.keys.allSatisfy({ $0 == "true" || $0 == "false" }) else {
                throw AIError.invalidArgument(
                    argument: argument,
                    message: "boolean criteria may only describe true and false"
                )
            }
            criteria = Array(descriptions.values)
        }

        guard criteria.allSatisfy({ $0 == .null || isEvaluationInput($0) }) else {
            throw AIError.invalidArgument(
                argument: argument,
                message: "criteria descriptions must be JSON-compatible strings, objects, arrays, or null"
            )
        }
    }
}

package func validateEvaluationAnswers(
    questions: [String: AIEvaluationQuestion],
    answers: [String: AIEvaluationAnswer],
    rounding: AIEvaluationRounding?,
    providerID: String
) throws {
    let probabilityError = try evaluationRoundingError(
        rounding?.probabilityDecimals,
        providerID: providerID
    )
    let scoreError = try evaluationRoundingError(
        rounding?.scoreDecimals,
        providerID: providerID
    )

    guard answers.count == questions.count,
          Set(answers.keys) == Set(questions.keys) else {
        throw invalidEvaluationResponse(
            providerID: providerID,
            "Evaluation must return exactly one answer for every question."
        )
    }

    for (id, question) in questions {
        guard let answer = answers[id], answer.type == question.type else {
            throw invalidEvaluationResponse(
                providerID: providerID,
                "Question \"\(id)\" returned an answer with the wrong type."
            )
        }

        switch (question, answer) {
        case let (.choice(_, criteria), .choice(choice, probabilities)):
            guard criteria.keys.contains(choice) else {
                throw invalidEvaluationResponse(
                    providerID: providerID,
                    "Question \"\(id)\" selected an unknown option."
                )
            }
            if let probabilities {
                try validateEvaluationDistribution(
                    probabilities,
                    keys: Array(criteria.keys),
                    questionID: id,
                    roundingError: probabilityError,
                    providerID: providerID
                )
                guard let selected = probabilities[choice],
                      !probabilities.values.contains(where: { $0 > selected + evaluationTolerance + 2 * probabilityError }) else {
                    throw invalidEvaluationResponse(
                        providerID: providerID,
                        "Question \"\(id)\" did not select a highest-probability option."
                    )
                }
            }
        case let (.score(_, criteria), .score(score, probabilities)):
            guard score.isFinite, score >= 0, score <= Double(criteria.count - 1) else {
                throw invalidEvaluationResponse(
                    providerID: providerID,
                    "Question \"\(id)\" score must be in [0, \(criteria.count - 1)]."
                )
            }
            if let probabilities {
                let keys = criteria.indices.map(String.init)
                try validateEvaluationDistribution(
                    probabilities,
                    keys: keys,
                    questionID: id,
                    roundingError: probabilityError,
                    providerID: providerID
                )
                let mean = probabilities.reduce(0.0) { total, entry in
                    total + (Double(entry.key) ?? 0) * entry.value
                }
                let meanRoundingError = keys.reduce(0.0) { total, key in
                    total + (Double(key) ?? 0) * probabilityError
                }
                guard abs(mean - score) <= evaluationTolerance + meanRoundingError + scoreError else {
                    throw invalidEvaluationResponse(
                        providerID: providerID,
                        "Question \"\(id)\" score must equal the probability-weighted mean within the declared rounding precision."
                    )
                }
            }
        case let (.box, .box(box)):
            guard box.isValid else {
                throw invalidEvaluationResponse(providerID: providerID, "Question \"\(id)\" must return box edges in [0, 1] with left < right and top < bottom.")
            }
        case let (.boolean, .boolean(probability)):
            guard isEvaluationProbability(probability) else {
                throw invalidEvaluationResponse(
                    providerID: providerID,
                    "Question \"\(id)\" must return P(true) as a finite probability in [0, 1]."
                )
            }
        default:
            throw invalidEvaluationResponse(
                providerID: providerID,
                "Question \"\(id)\" returned an answer with the wrong type."
            )
        }
    }
}

private let evaluationTolerance = 1e-6

private func isEvaluationInput(_ value: JSONValue) -> Bool {
    switch value {
    case .string:
        true
    case let .array(values):
        values.allSatisfy(isFiniteJSON)
    case let .object(values):
        values.values.allSatisfy(isFiniteJSON)
    case .number, .bool, .null:
        false
    }
}

public func isFiniteJSON(_ value: JSONValue) -> Bool {
    switch value {
    case .string, .bool, .null:
        true
    case let .number(number):
        number.isFinite
    case let .array(values):
        values.allSatisfy(isFiniteJSON)
    case let .object(values):
        values.values.allSatisfy(isFiniteJSON)
    }
}

private func evaluationRoundingError(
    _ decimals: Int?,
    providerID: String
) throws -> Double {
    guard let decimals else { return 0 }
    guard (0...15).contains(decimals) else {
        throw invalidEvaluationResponse(
            providerID: providerID,
            "Evaluation rounding decimals must be integers between 0 and 15."
        )
    }
    return 0.5 * pow(10, -Double(decimals))
}

private func validateEvaluationDistribution(
    _ probabilities: [String: Double],
    keys: [String],
    questionID: String,
    roundingError: Double,
    providerID: String
) throws {
    guard probabilities.count == keys.count,
          Set(probabilities.keys) == Set(keys),
          probabilities.values.allSatisfy(isEvaluationProbability) else {
        throw invalidEvaluationResponse(
            providerID: providerID,
            "Question \"\(questionID)\" must have a complete distribution of finite probabilities in [0, 1]."
        )
    }
    let sum = probabilities.values.reduce(0, +)
    guard abs(sum - 1) <= evaluationTolerance + Double(keys.count) * roundingError else {
        throw invalidEvaluationResponse(
            providerID: providerID,
            "Question \"\(questionID)\" probabilities must sum to 1 within the declared rounding precision."
        )
    }
}

private func isEvaluationProbability(_ value: Double) -> Bool {
    value.isFinite && value >= 0 && value <= 1
}

private func invalidEvaluationResponse(providerID: String, _ message: String) -> AIError {
    .invalidResponse(provider: providerID, message: message)
}