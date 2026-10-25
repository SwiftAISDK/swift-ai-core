import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func resolveDecisionModel(_ reference: AIDecisionModelReference) throws -> any AIDecisionModelV4 {
    let model: any AIDecisionModelV4
    switch reference {
    case let .model(value): model = value
    case let .modelID(id): throw AIDecisionModelResolutionError.noSuchModel(modelID: id)
    }
    return try validateDecisionModelVersion(model)
}