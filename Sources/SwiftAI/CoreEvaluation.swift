import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func resolveEvaluationModel(_ reference: AIEvaluationModelReference) throws -> any AIEvaluationModelV4 {
    let model: any AIEvaluationModelV4
    switch reference {
    case let .model(value):
        model = value
    case let .modelID(modelID):
        throw AIEvaluationModelResolutionError.noSuchModel(modelID: modelID)
    }
    return try validateEvaluationModelVersion(model)
}