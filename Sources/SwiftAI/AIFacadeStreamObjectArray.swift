import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension AI {
public static func streamObjectArray<Element: Decodable & Sendable>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        as type: Element.Type = Element.self,
        elementSchema: JSONValue,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<[Element]>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<ObjectStreamPart<[Element]>, Error> {
        let schema = arrayOutputSchema(elementSchema: elementSchema)
        return mapArrayObjectStream(
            streamObject(
                model: model,
                request: request,
                as: AIObjectArrayEnvelope<Element>.self,
                schema: schema,
                schemaName: schemaName,
                schemaDescription: schemaDescription,
                timeoutNanoseconds: timeoutNanoseconds,
                retryPolicy: retryPolicy,
                telemetry: telemetry,
                callbacks: arrayEnvelopeCallbacks(callbacks),
                jsonInstruction: jsonInstruction,
                repairText: repairText
            )
        )
    }

    public static func streamObjectArray<Element: Decodable & Sendable>(
        model: any LanguageModel,
        prompt: String,
        as type: Element.Type = Element.self,
        elementSchema: JSONValue,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
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
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<[Element]>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<ObjectStreamPart<[Element]>, Error> {
        streamObjectArray(
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
                responseFormat: .json(schema: arrayOutputSchema(elementSchema: elementSchema), name: schemaName, description: schemaDescription),
                reasoning: reasoning,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers
            ),
            as: Element.self,
            elementSchema: elementSchema,
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

    public static func streamObjectArray<ElementSchema: AIObjectSchema>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        elementSchema: ElementSchema,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<[ElementSchema.Output]>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<ObjectStreamPart<[ElementSchema.Output]>, Error> {
        streamObjectArray(
            model: model,
            request: request,
            as: ElementSchema.Output.self,
            elementSchema: elementSchema.jsonSchema,
            schemaName: schemaName ?? elementSchema.name,
            schemaDescription: schemaDescription ?? elementSchema.description,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func streamObjectArray<ElementSchema: AIObjectSchema>(
        model: any LanguageModel,
        prompt: String,
        elementSchema: ElementSchema,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
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
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<[ElementSchema.Output]>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<ObjectStreamPart<[ElementSchema.Output]>, Error> {
        streamObjectArray(
            model: model,
            prompt: prompt,
            as: ElementSchema.Output.self,
            elementSchema: elementSchema.jsonSchema,
            schemaName: schemaName ?? elementSchema.name,
            schemaDescription: schemaDescription ?? elementSchema.description,
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed,
            maxOutputTokens: maxOutputTokens,
            stopSequences: stopSequences,
            reasoning: reasoning,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }
}
