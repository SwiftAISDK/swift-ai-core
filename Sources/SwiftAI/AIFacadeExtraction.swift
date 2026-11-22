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
        try await experimentalExtract(model: model, state: state, fields: fields, referenceDate: referenceDate,
            maxOutputTokens: maxOutputTokens, reasoning: reasoning, maxRetries: maxRetries, abortSignal: abortSignal,
            download: download, headers: headers, providerOptions: providerOptions, telemetry: nil)
    }

    /// Extracts values with lifecycle callbacks and opt-in, redacted telemetry.
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
        providerOptions: [String: JSONValue] = [:],
        telemetry: Telemetry.Options? = nil,
        runtimeContext: [String: JSONValue] = [:],
        onStart: AICallback<AIExtractionStartEvent>? = nil,
        onEnd: AICallback<AIExtractionEndEvent>? = nil
    ) async throws -> AIExtractionResult {
        guard model.specificationVersion == "v4" else { throw AIError.invalidArgument(argument: "model", message: "Extraction requires an ExtractionModelV4 implementation.") }
        if let maxOutputTokens, maxOutputTokens < 1 { throw AIError.invalidArgument(argument: "maxOutputTokens", message: "must be an integer greater than or equal to 1") }
        try validateExtractionInput(state: state, fields: fields, referenceDate: referenceDate)
        for (id, field) in fields where !model.supportedFieldTypes.contains(field.type) {
            throw AIExtractionUnsupportedFieldTypeError(fieldID: id, fieldType: field.type, providerID: model.providerID, modelID: model.modelID)
        }
        let policy = try prepareRetries(maxRetries: maxRetries)
        let dispatcher = TelemetryDispatcher(options: telemetry)
        let callID = UUID().uuidString
        let started = DispatchTime.now().uptimeNanoseconds
        let start = AIExtractionStartEvent(callID: callID, providerID: model.providerID, modelID: model.modelID,
            state: state, fields: fields, referenceDate: referenceDate, maxOutputTokens: maxOutputTokens,
            reasoning: reasoning, maxRetries: policy.maxRetries, headers: headers, providerOptions: providerOptions,
            runtimeContext: runtimeContext)
        let context = filterDecisionRuntimeContext(runtimeContext, include: telemetry?.includeRuntimeContext)
        let input: JSONValue? = dispatcher.isEnabled && telemetry?.includesInput == true
            ? extractionTelemetryInput(state: state, fields: fields, referenceDate: referenceDate, maxOutputTokens: maxOutputTokens, reasoning: reasoning)
            : Optional.none
        await notify(event: start, callback: onStart)
        await dispatcher.record(telemetryEvent(kind: .start, callID: callID, operationID: start.operationID,
            providerID: model.providerID, modelID: model.modelID, options: telemetry,
            maxRetries: policy.maxRetries, input: input, runtimeContext: context))

        do {
            let prepared = try await prepareDecisionState(state, abortSignal: abortSignal, download: download)
            let options = AIExtractionModelV4CallOptions(state: prepared, fields: fields, referenceDate: referenceDate,
                maxOutputTokens: maxOutputTokens, reasoning: reasoning, abortSignal: abortSignal,
                headers: withUserAgentSuffix(headers, "ai/7.0.179"), providerOptions: providerOptions)
            let modelInput = input.map { _ in extractionTelemetryInput(state: .parts(prepared), fields: fields, referenceDate: referenceDate) }
            let modelStarted = DispatchTime.now().uptimeNanoseconds
            await dispatcher.record(telemetryEvent(kind: .modelCallStart, callID: callID, operationID: "ai.extract.doExtract",
                providerID: model.providerID, modelID: model.modelID, options: telemetry, input: modelInput))
            let result = try await withRetry(policy: policy, abortSignal: abortSignal) {
                try abortSignal?.throwIfAborted()
                return try await model.doExtract(options)
            }
            try abortSignal?.throwIfAborted()
            let answers = result.answers.mapValues(normalizedExtractionAnswer)
            try validateExtractionAnswers(fields: fields, state: prepared, answers: answers, providerID: model.providerID)
            let refused = fields.keys.sorted().filter { answers[$0]?.type == .refusal }
            guard refused.isEmpty else { throw AIExtractionRefusalError(fieldIDs: refused, providerID: model.providerID, modelID: model.modelID) }
            let output: JSONValue? = dispatcher.isEnabled && telemetry?.includesOutput == true
                ? extractionTelemetryOutput(answers) : Optional.none
            await dispatcher.record(telemetryEvent(kind: .modelCallEnd, callID: callID, operationID: "ai.extract.doExtract",
                providerID: model.providerID, modelID: model.modelID, options: telemetry,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - modelStarted, input: modelInput, output: output,
                usage: decisionTokenUsage(result.usage), warnings: result.warnings, providerMetadata: result.providerMetadata,
                responseMetadata: result.response ?? .init()))
            await AIWarningLogging.logWarnings(result.warnings, providerID: model.providerID, modelID: model.modelID)

            let inputTokens = result.usage?.inputTokens
            let outputTokens = result.usage?.outputTokens
            let total = decisionTokenUsage(result.usage)?.totalTokens
            let response = result.response ?? AIResponseMetadata()
            let extraction = AIExtractionResult(answers: answers,
                usage: .init(inputTokens: inputTokens, outputTokens: outputTokens, totalTokens: total),
                warnings: result.warnings, providerMetadata: result.providerMetadata,
                response: .init(id: response.id, timestamp: response.timestamp ?? Date(),
                    modelID: response.modelID ?? model.modelID, headers: response.headers, body: response.body))
            await notify(event: AIExtractionEndEvent(start: start, result: extraction), callback: onEnd)
            await dispatcher.record(telemetryEvent(kind: .end, callID: callID, operationID: start.operationID,
                providerID: model.providerID, modelID: model.modelID, options: telemetry, maxRetries: policy.maxRetries,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started, input: input, output: output,
                usage: decisionTokenUsage(extraction.usage), warnings: extraction.warnings,
                providerMetadata: extraction.providerMetadata, responseMetadata: decisionResponseMetadata(extraction.response),
                runtimeContext: context))
            return extraction
        } catch {
            await dispatcher.record(telemetryEvent(kind: .error, callID: callID, operationID: start.operationID,
                providerID: model.providerID, modelID: model.modelID, options: telemetry, maxRetries: policy.maxRetries,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started, errorDescription: telemetryErrorDescription(error),
                runtimeContext: context))
            throw error
        }
    }
}

private func normalizedExtractionAnswer(_ answer: AIExtractionAnswer) -> AIExtractionAnswer {
    guard answer.type != .refusal, let value = answer.value,
          value.stringValue == "" || value.arrayValue?.isEmpty == true else {
        return answer
    }
    var normalized = answer
    normalized.value = nil
    if normalized.type == .list { normalized.items = nil }
    return normalized
}
