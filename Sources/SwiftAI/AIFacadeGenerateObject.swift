import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension AI {
    public static func generateObject<Object: Decodable & Sendable>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        as type: Object.Type = Object.self,
        schema: JSONValue? = nil,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<Object>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<Object> {
        let objectRequest = objectRequest(
            from: request,
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            jsonInstruction: jsonInstruction
        )

        return try await generateObjectResult(
            model: model,
            request: objectRequest,
            outputKind: "object",
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks
        ) { text, providerID in
            try await parseObject(
                Object.self,
                from: text,
                schema: schema,
                repairText: repairText,
                providerID: providerID
            )
        }
    }

    public static func generateObject<Object: Decodable & Sendable>(
        model: any LanguageModel,
        prompt: String,
        as type: Object.Type = Object.self,
        schema: JSONValue? = nil,
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
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<Object>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<Object> {
        try await generateObject(
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
                responseFormat: .json(schema: schema, name: schemaName, description: schemaDescription),
                reasoning: reasoning,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers
            ),
            as: Object.self,
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func generateObject<Schema: AIObjectSchema>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        schema: Schema,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<Schema.Output>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<Schema.Output> {
        try await generateObject(
            model: model,
            request: request,
            as: Schema.Output.self,
            schema: schema.jsonSchema,
            schemaName: schemaName ?? schema.name,
            schemaDescription: schemaDescription ?? schema.description,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func generateObject<Schema: AIObjectSchema>(
        model: any LanguageModel,
        prompt: String,
        schema: Schema,
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
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<Schema.Output>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<Schema.Output> {
        try await generateObject(
            model: model,
            prompt: prompt,
            as: Schema.Output.self,
            schema: schema.jsonSchema,
            schemaName: schemaName ?? schema.name,
            schemaDescription: schemaDescription ?? schema.description,
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
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func generateObjectArray<Element: Decodable & Sendable>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        as type: Element.Type = Element.self,
        elementSchema: JSONValue,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<[Element]>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<[Element]> {
        let schema = arrayOutputSchema(elementSchema: elementSchema)
        let objectRequest = objectRequest(
            from: request,
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            jsonInstruction: jsonInstruction
        )

        return try await generateObjectResult(
            model: model,
            request: objectRequest,
            outputKind: "array",
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks
        ) { text, providerID in
            try await parseObjectArray(
                Element.self,
                from: text,
                elementSchema: elementSchema,
                repairText: repairText,
                providerID: providerID
            )
        }
    }

    public static func generateObjectArray<Element: Decodable & Sendable>(
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
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<[Element]>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<[Element]> {
        try await generateObjectArray(
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
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func generateObjectArray<ElementSchema: AIObjectSchema>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        elementSchema: ElementSchema,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<[ElementSchema.Output]>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<[ElementSchema.Output]> {
        try await generateObjectArray(
            model: model,
            request: request,
            as: ElementSchema.Output.self,
            elementSchema: elementSchema.jsonSchema,
            schemaName: schemaName ?? elementSchema.name,
            schemaDescription: schemaDescription ?? elementSchema.description,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func generateObjectArray<ElementSchema: AIObjectSchema>(
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
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<[ElementSchema.Output]>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<[ElementSchema.Output]> {
        try await generateObjectArray(
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
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func generateEnum(
        model: any LanguageModel,
        request: LanguageModelRequest,
        values: [String],
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<String>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<String> {
        guard !values.isEmpty else {
            throw AIError.invalidArgument(argument: "values", message: "Enum values are required.")
        }
        let schema = enumOutputSchema(values: values)
        let objectRequest = objectRequest(
            from: request,
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            jsonInstruction: jsonInstruction
        )

        return try await generateObjectResult(
            model: model,
            request: objectRequest,
            outputKind: "enum",
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks
        ) { text, providerID in
            try await parseEnum(
                from: text,
                values: values,
                repairText: repairText,
                providerID: providerID
            )
        }
    }

    public static func generateEnum(
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
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<String>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<String> {
        try await generateEnum(
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
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func generateJSON(
        model: any LanguageModel,
        request: LanguageModelRequest,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<JSONValue>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<JSONValue> {
        let objectRequest = objectRequest(
            from: request,
            schema: nil,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            jsonInstruction: jsonInstruction
        )

        return try await generateObjectResult(
            model: model,
            request: objectRequest,
            outputKind: "no-schema",
            schema: nil,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks
        ) { text, providerID in
            try await parseJSONValueObject(
                from: text,
                repairText: repairText,
                providerID: providerID
            )
        }
    }

    public static func generateJSON(
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
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        callbacks: AIObjectGenerationCallbacks<JSONValue>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<JSONValue> {
        try await generateJSON(
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
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }
}
