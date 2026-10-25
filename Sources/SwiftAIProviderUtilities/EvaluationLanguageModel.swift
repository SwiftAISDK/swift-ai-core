import Foundation
import SwiftAIProvider
import SwiftAITransport


/// Compatibility adapter retaining Evaluation Model V4 signatures.
/// New requests use the published Decision structured-output schema and ordered state.
public final class EvaluationLanguageModel: AIEvaluationModelV4, @unchecked Sendable {
    public let specificationVersion = "v4"
    public let supportedQuestionTypes: [AIEvaluationQuestionType] = [.choice, .score, .boolean]
    private let decision: DecisionLanguageModel
    public var providerID: String { decision.providerID }
    public var modelID: String { decision.modelID }

    public init(model: any LanguageModel, providerID: String? = nil) {
        decision = DecisionLanguageModel(model: model, providerID: providerID ?? "\(model.providerID).evaluation")
    }

    public func doEvaluate(_ options: AIEvaluationModelV4CallOptions) async throws -> AIEvaluationModelV4Result {
        try validateEvaluationInput(state: options.state, questions: options.questions)
        let result = try await decision.doDecide(options.decisionOptions)
        return try evaluationResult(from: result, providerID: providerID, modelID: modelID)
    }
}