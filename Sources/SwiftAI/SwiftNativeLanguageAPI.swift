import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public struct ModelID: RawRepresentable, Codable, Equatable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String {
        rawValue
    }
}

public struct LanguageGenerationOptions: Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var seed: Int?
    public var maxOutputTokens: Int?
    public var stopSequences: [String]
    public var responseFormat: AIResponseFormat?
    public var reasoning: String?
    public var includeRawChunks: Bool
    public var includeResponseBody: Bool
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?
    public var retryPolicy: AIRetryPolicy
    public var telemetry: Telemetry.Options?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        responseFormat: AIResponseFormat? = nil,
        reasoning: String? = nil,
        includeRawChunks: Bool = false,
        includeResponseBody: Bool = false,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.seed = seed
        self.maxOutputTokens = maxOutputTokens
        self.stopSequences = stopSequences
        self.responseFormat = responseFormat
        self.reasoning = reasoning
        self.includeRawChunks = includeRawChunks
        self.includeResponseBody = includeResponseBody
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
        self.retryPolicy = retryPolicy
        self.telemetry = telemetry
    }

    public static let `default` = LanguageGenerationOptions()

    public func request(messages: [AIMessage], tools: LanguageToolOptions = .none) -> LanguageModelRequest {
        LanguageModelRequest(
            messages: messages,
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed,
            maxOutputTokens: maxOutputTokens,
            stopSequences: stopSequences,
            responseFormat: responseFormat,
            reasoning: reasoning,
            tools: tools.rawTools,
            toolContexts: tools.toolContexts,
            toolChoice: tools.choice,
            includeRawChunks: includeRawChunks,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal
        )
    }
}

public struct LanguageToolOptions: Sendable {
    public var rawTools: [String: JSONValue]
    public var toolContexts: [String: JSONValue]
    public var executableTools: [AITool]
    public var maxSteps: Int
    public var stopWhen: [AIStopCondition]
    public var prepareStep: AIPrepareStep?
    public var approval: AIToolApproval?
    public var choice: JSONValue?

    public init(
        rawTools: [String: JSONValue] = [:],
        toolContexts: [String: JSONValue] = [:],
        executableTools: [AITool] = [],
        maxSteps: Int = 5,
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        approval: AIToolApproval? = nil,
        choice: JSONValue? = nil
    ) {
        self.rawTools = rawTools
        self.toolContexts = toolContexts
        self.executableTools = executableTools
        self.maxSteps = maxSteps
        self.stopWhen = stopWhen
        self.prepareStep = prepareStep
        self.approval = approval
        self.choice = choice
    }

    public init(
        _ executableTools: [AITool],
        toolContexts: [String: JSONValue] = [:],
        maxSteps: Int = 5,
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        approval: AIToolApproval? = nil,
        choice: JSONValue? = nil
    ) {
        self.init(
            toolContexts: toolContexts,
            executableTools: executableTools,
            maxSteps: maxSteps,
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            approval: approval,
            choice: choice
        )
    }

    public static let none = LanguageToolOptions()

    public var usesToolLoop: Bool {
        !executableTools.isEmpty || prepareStep != nil
    }
}

public extension AIProvider {
    func languageModel(_ modelID: ModelID) throws -> any LanguageModel {
        try languageModel(modelID.rawValue)
    }

    func embeddingModel(_ modelID: ModelID) throws -> any EmbeddingModel {
        try embeddingModel(modelID.rawValue)
    }

    func imageModel(_ modelID: ModelID) throws -> any ImageModel {
        try imageModel(modelID.rawValue)
    }

    func transcriptionModel(_ modelID: ModelID) throws -> any TranscriptionModel {
        try transcriptionModel(modelID.rawValue)
    }

    func speechModel(_ modelID: ModelID) throws -> any SpeechModel {
        try speechModel(modelID.rawValue)
    }

    func videoModel(_ modelID: ModelID) throws -> any VideoModel {
        try videoModel(modelID.rawValue)
    }

    func rerankingModel(_ modelID: ModelID) throws -> any RerankingModel {
        try rerankingModel(modelID.rawValue)
    }
}


public extension LanguageModel {
    func generateText(
        _ prompt: String,
        options: LanguageGenerationOptions = .default,
        tools: LanguageToolOptions = .none
    ) async throws -> TextGenerationResult {
        try await AI.generateText(prompt, using: self, options: options, tools: tools)
    }

    func generateText(
        messages: [AIMessage],
        options: LanguageGenerationOptions = .default,
        tools: LanguageToolOptions = .none
    ) async throws -> TextGenerationResult {
        try await AI.generateText(messages: messages, using: self, options: options, tools: tools)
    }

    func generateText<FinalOutput: Sendable, PartialOutput: Sendable>(
        _ prompt: String,
        output: AIOutput<FinalOutput, PartialOutput>,
        options: LanguageGenerationOptions = .default,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> AIOutputGenerationResult<FinalOutput> {
        try await AI.generateText(
            prompt,
            using: self,
            output: output,
            options: options,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    func generateObject<Object: Decodable & Sendable>(
        _ prompt: String,
        as type: Object.Type = Object.self,
        schema: JSONValue? = nil,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        options: LanguageGenerationOptions = .default,
        callbacks: AIObjectGenerationCallbacks<Object>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<Object> {
        try await AI.generateObject(
            prompt,
            using: self,
            as: Object.self,
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            options: options,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    func generateObject<Schema: AIObjectSchema>(
        _ prompt: String,
        schema: Schema,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        options: LanguageGenerationOptions = .default,
        callbacks: AIObjectGenerationCallbacks<Schema.Output>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<Schema.Output> {
        try await AI.generateObject(
            prompt,
            using: self,
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            options: options,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    func streamText(
        _ prompt: String,
        options: LanguageGenerationOptions = .default,
        tools: LanguageToolOptions = .none,
        timeoutNanoseconds: UInt64? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        AI.streamText(prompt, using: self, options: options, tools: tools, timeoutNanoseconds: timeoutNanoseconds)
    }

    func streamText(
        messages: [AIMessage],
        options: LanguageGenerationOptions = .default,
        tools: LanguageToolOptions = .none,
        timeoutNanoseconds: UInt64? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        AI.streamText(messages: messages, using: self, options: options, tools: tools, timeoutNanoseconds: timeoutNanoseconds)
    }

    func streamText<FinalOutput: Sendable, PartialOutput: Sendable>(
        _ prompt: String,
        output: AIOutput<FinalOutput, PartialOutput>,
        options: LanguageGenerationOptions = .default,
        timeoutNanoseconds: UInt64? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error> {
        AI.streamText(
            prompt,
            using: self,
            output: output,
            options: options,
            timeoutNanoseconds: timeoutNanoseconds,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }
}


public extension EmbeddingModel {
    func embed(
        _ value: String,
        dimensions: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> EmbeddingResult {
        try await AI.embed(
            value,
            using: self,
            dimensions: dimensions,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }

    func embedMany(
        _ values: [String],
        dimensions: Int? = nil,
        chunkSize: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> EmbeddingResult {
        try await AI.embedMany(
            values,
            using: self,
            dimensions: dimensions,
            chunkSize: chunkSize,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }
}


public extension ImageModel {
    func generateImage(
        _ prompt: String,
        size: String? = nil,
        aspectRatio: String? = nil,
        seed: Int? = nil,
        count: Int? = nil,
        files: [ImageInputFile] = [],
        mask: ImageInputFile? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> ImageGenerationResult {
        try await AI.generateImage(
            prompt,
            using: self,
            size: size,
            aspectRatio: aspectRatio,
            seed: seed,
            count: count,
            files: files,
            mask: mask,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }
}


public extension TranscriptionModel {
    func transcribe(
        audio: Data,
        fileName: String = "audio.wav",
        mimeType: String = "audio/wav",
        language: String? = nil,
        prompt: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> TranscriptionResult {
        try await AI.transcribe(
            audio: audio,
            using: self,
            fileName: fileName,
            mimeType: mimeType,
            language: language,
            prompt: prompt,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }
}


public extension SpeechModel {
    func generateSpeech(
        _ text: String,
        voice: String? = nil,
        format: String? = nil,
        speed: Double? = nil,
        language: String? = nil,
        instructions: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> SpeechResult {
        try await AI.generateSpeech(
            text,
            using: self,
            voice: voice,
            format: format,
            speed: speed,
            language: language,
            instructions: instructions,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }
}


public extension AudioGenerationModel {
    func generateAudio(
        _ prompt: String,
        durationSeconds: Double? = nil,
        format: String? = nil,
        seed: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> AudioGenerationResult {
        try await AI.generateAudio(
            model: self,
            request: AudioGenerationRequest(
                prompt: prompt,
                durationSeconds: durationSeconds,
                format: format,
                seed: seed,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers,
                abortSignal: abortSignal
            ),
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }
}


public extension AudioTransformationModel {
    func transformAudio(
        audio: Data,
        fileName: String = "audio.wav",
        mimeType: String = "audio/wav",
        voice: String? = nil,
        format: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> AudioTransformationResult {
        try await AI.transformAudio(
            model: self,
            request: AudioTransformationRequest(
                audio: audio,
                fileName: fileName,
                mimeType: mimeType,
                voice: voice,
                format: format,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers,
                abortSignal: abortSignal
            ),
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }
}


public extension VideoModel {
    func generateVideo(
        _ prompt: String,
        aspectRatio: String? = nil,
        durationSeconds: Double? = nil,
        image: ImageInputFile? = nil,
        resolution: String? = nil,
        fps: Double? = nil,
        generateAudio: Bool? = nil,
        seed: Int? = nil,
        count: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> VideoGenerationResult {
        try await AI.generateVideo(
            prompt,
            using: self,
            aspectRatio: aspectRatio,
            durationSeconds: durationSeconds,
            image: image,
            resolution: resolution,
            fps: fps,
            generateAudio: generateAudio,
            seed: seed,
            count: count,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }
}


public extension RerankingModel {
    func rerank(
        query: String,
        documents: [String],
        topK: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> RerankingResult {
        try await AI.rerank(
            query: query,
            documents: documents,
            using: self,
            topK: topK,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }
}


public extension AI {
    static func generateText(
        _ prompt: String,
        using model: any LanguageModel,
        options: LanguageGenerationOptions = .default,
        tools: LanguageToolOptions = .none
    ) async throws -> TextGenerationResult {
        try await generateText(messages: [.user(prompt)], using: model, options: options, tools: tools)
    }

    static func generateText(
        messages: [AIMessage],
        using model: any LanguageModel,
        options: LanguageGenerationOptions = .default,
        tools: LanguageToolOptions = .none
    ) async throws -> TextGenerationResult {
        let request = options.request(messages: messages, tools: tools)
        guard tools.usesToolLoop else {
            return try await generateText(
                model: model,
                request: request,
                retryPolicy: options.retryPolicy,
                telemetry: options.telemetry,
                includeResponseBody: options.includeResponseBody
            )
        }

        return try await generateText(
            model: model,
            request: request,
            executableTools: tools.executableTools,
            maxSteps: tools.maxSteps,
            stopWhen: tools.stopWhen,
            prepareStep: tools.prepareStep,
            toolApproval: tools.approval,
            retryPolicy: options.retryPolicy,
            telemetry: options.telemetry,
            includeResponseBody: options.includeResponseBody
        )
    }

    static func generateText<FinalOutput: Sendable, PartialOutput: Sendable>(
        _ prompt: String,
        using model: any LanguageModel,
        output: AIOutput<FinalOutput, PartialOutput>,
        options: LanguageGenerationOptions = .default,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> AIOutputGenerationResult<FinalOutput> {
        try await generateText(
            model: model,
            request: options.request(messages: [.user(prompt)]),
            output: output,
            retryPolicy: options.retryPolicy,
            telemetry: options.telemetry,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    static func generateObject<Object: Decodable & Sendable>(
        _ prompt: String,
        using model: any LanguageModel,
        as type: Object.Type = Object.self,
        schema: JSONValue? = nil,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        options: LanguageGenerationOptions = .default,
        callbacks: AIObjectGenerationCallbacks<Object>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<Object> {
        var objectOptions = options
        objectOptions.responseFormat = .json(schema: schema, name: schemaName, description: schemaDescription)
        return try await generateObject(
            model: model,
            request: objectOptions.request(messages: [.user(prompt)]),
            as: Object.self,
            schema: schema,
            schemaName: schemaName,
            schemaDescription: schemaDescription,
            retryPolicy: options.retryPolicy,
            telemetry: options.telemetry,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    static func generateObject<Schema: AIObjectSchema>(
        _ prompt: String,
        using model: any LanguageModel,
        schema: Schema,
        schemaName: String? = nil,
        schemaDescription: String? = nil,
        options: LanguageGenerationOptions = .default,
        callbacks: AIObjectGenerationCallbacks<Schema.Output>? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> ObjectGenerationResult<Schema.Output> {
        try await generateObject(
            prompt,
            using: model,
            as: Schema.Output.self,
            schema: schema.jsonSchema,
            schemaName: schemaName ?? schema.name,
            schemaDescription: schemaDescription ?? schema.description,
            options: options,
            callbacks: callbacks,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    static func streamText(
        _ prompt: String,
        using model: any LanguageModel,
        options: LanguageGenerationOptions = .default,
        tools: LanguageToolOptions = .none,
        timeoutNanoseconds: UInt64? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        streamText(messages: [.user(prompt)], using: model, options: options, tools: tools, timeoutNanoseconds: timeoutNanoseconds)
    }

    static func streamText(
        messages: [AIMessage],
        using model: any LanguageModel,
        options: LanguageGenerationOptions = .default,
        tools: LanguageToolOptions = .none,
        timeoutNanoseconds: UInt64? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        let request = options.request(messages: messages, tools: tools)
        guard tools.usesToolLoop else {
            return streamText(
                model: model,
                request: request,
                timeoutNanoseconds: timeoutNanoseconds,
                retryPolicy: options.retryPolicy,
                telemetry: options.telemetry
            )
        }

        return streamText(
            model: model,
            request: request,
            executableTools: tools.executableTools,
            maxSteps: tools.maxSteps,
            stopWhen: tools.stopWhen,
            prepareStep: tools.prepareStep,
            toolApproval: tools.approval,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: options.retryPolicy,
            telemetry: options.telemetry
        )
    }

    static func streamText<FinalOutput: Sendable, PartialOutput: Sendable>(
        _ prompt: String,
        using model: any LanguageModel,
        output: AIOutput<FinalOutput, PartialOutput>,
        options: LanguageGenerationOptions = .default,
        timeoutNanoseconds: UInt64? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error> {
        streamText(
            model: model,
            request: options.request(messages: [.user(prompt)]),
            output: output,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: options.retryPolicy,
            telemetry: options.telemetry,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    static func embed(
        _ value: String,
        using model: any EmbeddingModel,
        dimensions: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> EmbeddingResult {
        try await embed(
            model: model,
            value: value,
            dimensions: dimensions,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }

    static func embedMany(
        _ values: [String],
        using model: any EmbeddingModel,
        dimensions: Int? = nil,
        chunkSize: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> EmbeddingResult {
        try await embedMany(
            model: model,
            values: values,
            dimensions: dimensions,
            chunkSize: chunkSize,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }

    static func generateImage(
        _ prompt: String,
        using model: any ImageModel,
        size: String? = nil,
        aspectRatio: String? = nil,
        seed: Int? = nil,
        count: Int? = nil,
        files: [ImageInputFile] = [],
        mask: ImageInputFile? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> ImageGenerationResult {
        try await generateImage(
            model: model,
            prompt: prompt,
            size: size,
            aspectRatio: aspectRatio,
            seed: seed,
            count: count,
            files: files,
            mask: mask,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }

    static func transcribe(
        audio: Data,
        using model: any TranscriptionModel,
        fileName: String = "audio.wav",
        mimeType: String = "audio/wav",
        language: String? = nil,
        prompt: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> TranscriptionResult {
        try await transcribe(
            model: model,
            request: AudioTranscriptionRequest(
                audio: audio,
                fileName: fileName,
                mimeType: mimeType,
                language: language,
                prompt: prompt,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers,
                abortSignal: abortSignal
            ),
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }

    static func generateSpeech(
        _ text: String,
        using model: any SpeechModel,
        voice: String? = nil,
        format: String? = nil,
        speed: Double? = nil,
        language: String? = nil,
        instructions: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> SpeechResult {
        try await generateSpeech(
            model: model,
            request: SpeechRequest(
                text: text,
                voice: voice,
                format: format,
                speed: speed,
                language: language,
                instructions: instructions,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers,
                abortSignal: abortSignal
            ),
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }

    static func generateAudio(
        _ prompt: String,
        using model: any AudioGenerationModel,
        durationSeconds: Double? = nil,
        format: String? = nil,
        seed: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> AudioGenerationResult {
        try await generateAudio(
            model: model,
            request: AudioGenerationRequest(
                prompt: prompt,
                durationSeconds: durationSeconds,
                format: format,
                seed: seed,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers,
                abortSignal: abortSignal
            ),
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }

    static func transformAudio(
        audio: Data,
        using model: any AudioTransformationModel,
        fileName: String = "audio.wav",
        mimeType: String = "audio/wav",
        voice: String? = nil,
        format: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> AudioTransformationResult {
        try await transformAudio(
            model: model,
            request: AudioTransformationRequest(
                audio: audio,
                fileName: fileName,
                mimeType: mimeType,
                voice: voice,
                format: format,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers,
                abortSignal: abortSignal
            ),
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }

    static func generateVideo(
        _ prompt: String,
        using model: any VideoModel,
        aspectRatio: String? = nil,
        durationSeconds: Double? = nil,
        image: ImageInputFile? = nil,
        resolution: String? = nil,
        fps: Double? = nil,
        generateAudio: Bool? = nil,
        seed: Int? = nil,
        count: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> VideoGenerationResult {
        try await generateVideo(
            model: model,
            request: VideoGenerationRequest(
                prompt: prompt,
                aspectRatio: aspectRatio,
                durationSeconds: durationSeconds,
                image: image,
                resolution: resolution,
                fps: fps,
                generateAudio: generateAudio,
                seed: seed,
                count: count,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers,
                abortSignal: abortSignal
            ),
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }

    static func rerank(
        query: String,
        documents: [String],
        using model: any RerankingModel,
        topK: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> RerankingResult {
        try await rerank(
            model: model,
            request: RerankingRequest(
                query: query,
                documents: documents,
                topK: topK,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers,
                abortSignal: abortSignal
            ),
            retryPolicy: retryPolicy,
            telemetry: telemetry
        )
    }
}
