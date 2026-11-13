import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

extension AI {
    /// Extracts every requested field from shared evidence or fails the entire call.
    public static func experimentalExtract(
        model: any AIExtractionModelV4,
        state: AIDecisionState,
        fields: [String: AIExtractionField],
        referenceDate: String? = nil,
        maxOutputTokens: Int? = nil,
        reasoning: String? = nil,
        maxRetries: Int? = nil,
        abortSignal: AIAbortSignal? = nil,
        download: AIDownloadFunction? = nil,
        headers: [String: String] = [:],
        providerOptions: [String: JSONValue] = [:]
    ) async throws -> AIExtractionResult {
        guard model.specificationVersion == "v4" else { throw AIError.invalidArgument(argument: "model", message: "Extraction requires an ExtractionModelV4 implementation.") }
        if let maxOutputTokens, maxOutputTokens < 1 { throw AIError.invalidArgument(argument: "maxOutputTokens", message: "must be an integer greater than or equal to 1") }
        try validateExtractionInput(state: state, fields: fields, referenceDate: referenceDate)
        for (id, field) in fields where !model.supportedFieldTypes.contains(field.type) {
            throw AIExtractionUnsupportedFieldTypeError(fieldID: id, fieldType: field.type, providerID: model.providerID, modelID: model.modelID)
        }
        let policy = try prepareRetries(maxRetries: maxRetries)
        let prepared = try await prepareDecisionState(state, abortSignal: abortSignal, download: download)
        let options = AIExtractionModelV4CallOptions(state: prepared, fields: fields, referenceDate: referenceDate, maxOutputTokens: maxOutputTokens, reasoning: reasoning, abortSignal: abortSignal, headers: withUserAgentSuffix(headers, "ai/7.0.172"), providerOptions: providerOptions)
        let result = try await withRetry(policy: policy, abortSignal: abortSignal) {
            try abortSignal?.throwIfAborted()
            return try await model.doExtract(options)
        }
        try abortSignal?.throwIfAborted()
        try validateExtractionAnswers(fields: fields, state: prepared, answers: result.answers, providerID: model.providerID)
        let refused = fields.keys.sorted().filter { result.answers[$0]?.type == .refusal }
        guard refused.isEmpty else { throw AIExtractionRefusalError(fieldIDs: refused, providerID: model.providerID, modelID: model.modelID) }
        await AIWarningLogging.logWarnings(result.warnings, providerID: model.providerID, modelID: model.modelID)
        let input = result.usage?.inputTokens, output = result.usage?.outputTokens
        var total: Int?
        if let input, let output { let sum = input.addingReportingOverflow(output); if !sum.overflow { total = sum.partialValue } }
        let response = result.response ?? AIResponseMetadata()
        return .init(answers: result.answers, usage: .init(inputTokens: input, outputTokens: output, totalTokens: total), warnings: result.warnings, providerMetadata: result.providerMetadata, response: .init(id: response.id, timestamp: response.timestamp ?? Date(), modelID: response.modelID ?? model.modelID, headers: response.headers, body: response.body))
    }
}
