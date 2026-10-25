import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension AI {
public static func streamEnum(
        model: any LanguageModel,
        request: LanguageModelRequest,
        values: [String],
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<String>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<ObjectStreamPart<String>, Error> {
        guard !values.isEmpty else {
            return failingPartStream(AIError.invalidArgument(argument: "values", message: "Enum values are required."))
        }
        let schema = enumOutputSchema(values: values)
        return mapEnumObjectStream(
            streamObject(
                model: model,
                request: request,
                as: AIEnumEnvelope.self,
                schema: schema,
                schemaName: schemaName,
                schemaDescription: schemaDescription,
                timeoutNanoseconds: timeoutNanoseconds,
                retryPolicy: retryPolicy,
                telemetry: telemetry,
                callbacks: enumEnvelopeCallbacks(callbacks),
                jsonInstruction: jsonInstruction,
                repairText: repairText
            ),
            values: values
        )
    }

    public static func streamEnum(
        model: any LanguageModel,
        prompt: String,
        values: [String],
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        reasoning: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<String>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<ObjectStreamPart<String>, Error> {
        streamEnum(
            model: model,
            request: LanguageModelRequest(
                messages: [.user(prompt)],
                temperature: temperature,
                topP: topP,
                topK: topK,
                presencePenalty: presencePenalty,
                frequencyPenalty: frequencyPenalty,
                seed: seed,
                maxOutputTokens: maxOutputTokens,
                stopSequences: stopSequences,
                responseFormat: .json(
                    schema: enumOutputSchema(values: values),
                    name: schemaName,
                    description: schemaDescription
                ),
                reasoning: reasoning,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers
            ),
            values: values,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func streamJSON(
        model: any LanguageModel,
        request: LanguageModelRequest,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<JSONValue>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<ObjectStreamPart<JSONValue>, Error> {
        streamObject(
            model: model,
            request: request,
            as: JSONValue.self,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func streamJSON(
        model: any LanguageModel,
        prompt: String,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        reasoning: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<JSONValue>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<ObjectStreamPart<JSONValue>, Error> {
        streamJSON(
            model: model,
            request: LanguageModelRequest(
                messages: [.user(prompt)],
                temperature: temperature,
                topP: topP,
                topK: topK,
                presencePenalty: presencePenalty,
                frequencyPenalty: frequencyPenalty,
                seed: seed,
                maxOutputTokens: maxOutputTokens,
                stopSequences: stopSequences,
                responseFormat: .json(name: schemaName, description: schemaDescription),
                reasoning: reasoning,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers
            ),
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }
}
