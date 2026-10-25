import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func generateObjectResult<Output: Sendable>(
    model: any LanguageModel,
    request: LanguageModelRequest,
    outputKind: String,
    schema: JSONValue?,
    schemaName: String?,
    schemaDescription: String?,
    retryPolicy: AIRetryPolicy,
    telemetry: Telemetry.Options?,
    callbacks: AIObjectGenerationCallbacks<Output>?,
    parse: @escaping @Sendable (String, String) async throws -> (object: Output, rawObject: JSONValue, text: String)
) async throws -> ObjectGenerationResult<Output> {
    await AIDeprecationLogging.objectWarning("generateObject")
    let callID = UUID().uuidString
    await callbacks?.onStart?(AIObjectGenerationStartEvent(
        callID: callID,
        operationID: "ai.generateObject",
        providerID: model.providerID,
        modelID: model.modelID,
        outputKind: outputKind,
        request: request,
        schema: schema,
        schemaName: schemaName,
        schemaDescription: schemaDescription,
        maxRetries: retryPolicy.maxRetries
    ))
    await callbacks?.onStepStart?(AIObjectGenerationStepStartEvent(
        callID: callID,
        stepNumber: 0,
        providerID: model.providerID,
        modelID: model.modelID,
        request: request
    ))

    return try await withTelemetry(
        operationID: "ai.generateObject",
        providerID: model.providerID,
        modelID: model.modelID,
        input: objectGenerationTelemetryInput(
            request,
            outputKind: outputKind,
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription
        ),
        telemetry: telemetry,
        retryPolicy: retryPolicy,
        abortSignal: request.abortSignal,
        callID: callID,
        output: objectGenerationTelemetryOutput,
        usage: { $0.usage },
        warnings: { $0.warnings },
        providerMetadata: { $0.providerMetadata },
        responseMetadata: { $0.responseMetadata }
    ) {
        var textResult: TextGenerationResult?
        do {
            let generatedResult = try await TelemetryDispatcher(options: telemetry).executeLanguageModelCall(
                callID: callID,
                operationID: "ai.generateObject",
                providerID: model.providerID,
                modelID: model.modelID
            ) {
                try await model.generate(request)
            }
            textResult = generatedResult
            await callbacks?.onStepFinish?(AIObjectGenerationStepFinishEvent(
                callID: callID,
                stepNumber: 0,
                providerID: model.providerID,
                modelID: model.modelID,
                text: generatedResult.text,
                reasoning: generatedResult.reasoning,
                finishReason: generatedResult.finishReason,
                usage: generatedResult.usage,
                warnings: generatedResult.warnings,
                providerMetadata: generatedResult.providerMetadata,
                responseMetadata: generatedResult.responseMetadata
            ))
            let parsed = try await parse(generatedResult.structuredOutputText ?? generatedResult.text, model.providerID)

            let result = ObjectGenerationResult(
                object: parsed.object,
                text: parsed.text,
                rawObject: parsed.rawObject,
                reasoning: generatedResult.reasoning,
                finishReason: generatedResult.finishReason,
                usage: generatedResult.usage,
                warnings: generatedResult.warnings,
                providerMetadata: generatedResult.providerMetadata,
                responseMetadata: generatedResult.responseMetadata,
                textResult: generatedResult
            )
            await callbacks?.onFinish?(AIObjectGenerationFinishEvent(
                callID: callID,
                object: result.object,
                text: result.text,
                rawObject: result.rawObject,
                reasoning: result.reasoning,
                finishReason: result.finishReason,
                usage: result.usage,
                warnings: result.warnings,
                providerMetadata: result.providerMetadata,
                responseMetadata: result.responseMetadata
            ))
            return result
        } catch {
            let enrichedError = objectGenerationErrorWithResultMetadata(
                error,
                finishReason: textResult?.finishReason,
                usage: textResult?.usage,
                warnings: textResult?.warnings ?? [],
                providerMetadata: textResult?.providerMetadata ?? [:],
                responseMetadata: textResult?.responseMetadata ?? AIResponseMetadata()
            )
            await callbacks?.onError?(AIObjectGenerationErrorEvent(
                callID: callID,
                providerID: model.providerID,
                modelID: model.modelID,
                text: textResult?.text ?? "",
                errorDescription: String(describing: enrichedError),
                finishReason: textResult?.finishReason,
                usage: textResult?.usage,
                warnings: textResult?.warnings ?? [],
                providerMetadata: textResult?.providerMetadata ?? [:],
                responseMetadata: textResult?.responseMetadata ?? AIResponseMetadata()
            ))
            throw enrichedError
        }
    }
}