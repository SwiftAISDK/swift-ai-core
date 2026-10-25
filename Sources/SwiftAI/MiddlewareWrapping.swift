import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public func wrapLanguageModel(
    _ model: any LanguageModel,
    middleware: AILanguageModelMiddleware,
    modelID: String? = nil,
    providerID: String? = nil
) -> any LanguageModel {
    wrapLanguageModel(model, middleware: [middleware], modelID: modelID, providerID: providerID)
}

public func wrapLanguageModel(
    _ model: any LanguageModel,
    middleware: [AILanguageModelMiddleware],
    modelID: String? = nil,
    providerID: String? = nil
) -> any LanguageModel {
    middleware.reversed().reduce(model) { wrappedModel, nextMiddleware in
        AIWrappedLanguageModel(
            model: wrappedModel,
            middleware: nextMiddleware,
            modelID: modelID,
            providerID: providerID
        )
    }
}

public func wrapImageModel(
    _ model: any ImageModel,
    middleware: AIImageModelMiddleware,
    modelID: String? = nil,
    providerID: String? = nil
) -> any ImageModel {
    wrapImageModel(model, middleware: [middleware], modelID: modelID, providerID: providerID)
}

public func wrapImageModel(
    _ model: any ImageModel,
    middleware: [AIImageModelMiddleware],
    modelID: String? = nil,
    providerID: String? = nil
) -> any ImageModel {
    middleware.reversed().reduce(model) { wrappedModel, nextMiddleware in
        AIWrappedImageModel(
            model: wrappedModel,
            middleware: nextMiddleware,
            modelID: modelID,
            providerID: providerID
        )
    }
}

public func wrapEmbeddingModel(
    _ model: any EmbeddingModel,
    middleware: AIEmbeddingModelMiddleware,
    modelID: String? = nil,
    providerID: String? = nil
) -> any EmbeddingModel {
    wrapEmbeddingModel(model, middleware: [middleware], modelID: modelID, providerID: providerID)
}

public func wrapEmbeddingModel(
    _ model: any EmbeddingModel,
    middleware: [AIEmbeddingModelMiddleware],
    modelID: String? = nil,
    providerID: String? = nil
) -> any EmbeddingModel {
    middleware.reversed().reduce(model) { wrappedModel, nextMiddleware in
        AIWrappedEmbeddingModel(
            model: wrappedModel,
            middleware: nextMiddleware,
            modelID: modelID,
            providerID: providerID
        )
    }
}

public func wrapProvider(
    _ provider: any AIProvider,
    languageModelMiddleware: AILanguageModelMiddleware,
    imageModelMiddleware: [AIImageModelMiddleware] = [],
    embeddingModelMiddleware: [AIEmbeddingModelMiddleware] = []
) -> any AIProvider {
    wrapProvider(
        provider,
        languageModelMiddleware: [languageModelMiddleware],
        imageModelMiddleware: imageModelMiddleware,
        embeddingModelMiddleware: embeddingModelMiddleware
    )
}

public func wrapProvider(
    _ provider: any AIProvider,
    languageModelMiddleware: [AILanguageModelMiddleware],
    imageModelMiddleware: [AIImageModelMiddleware] = [],
    embeddingModelMiddleware: [AIEmbeddingModelMiddleware] = []
) -> any AIProvider {
    AIWrappedProvider(
        provider: provider,
        languageModelMiddleware: languageModelMiddleware,
        imageModelMiddleware: imageModelMiddleware,
        embeddingModelMiddleware: embeddingModelMiddleware
    )
}

public func wrapProvider(
    _ provider: any AIProvider,
    languageModelMiddleware: [AILanguageModelMiddleware] = [],
    imageModelMiddleware: AIImageModelMiddleware,
    embeddingModelMiddleware: [AIEmbeddingModelMiddleware] = []
) -> any AIProvider {
    wrapProvider(
        provider,
        languageModelMiddleware: languageModelMiddleware,
        imageModelMiddleware: [imageModelMiddleware],
        embeddingModelMiddleware: embeddingModelMiddleware
    )
}

public func wrapProvider(
    _ provider: any AIProvider,
    languageModelMiddleware: [AILanguageModelMiddleware] = [],
    imageModelMiddleware: [AIImageModelMiddleware] = [],
    embeddingModelMiddleware: AIEmbeddingModelMiddleware
) -> any AIProvider {
    wrapProvider(
        provider,
        languageModelMiddleware: languageModelMiddleware,
        imageModelMiddleware: imageModelMiddleware,
        embeddingModelMiddleware: [embeddingModelMiddleware]
    )
}

final class AIWrappedLanguageModel: LanguageModel, @unchecked Sendable {
    private let model: any LanguageModel
    private let middleware: AILanguageModelMiddleware
    let providerID: String
    let modelID: String
    var supportedURLs: [String: [AISupportedURLPattern]] {
        model.supportedURLs
    }

    init(
        model: any LanguageModel,
        middleware: AILanguageModelMiddleware,
        modelID: String?,
        providerID: String?
    ) {
        self.model = model
        self.middleware = middleware
        self.providerID = providerID ?? middleware.overrideProviderID?(model) ?? model.providerID
        self.modelID = modelID ?? middleware.overrideModelID?(model) ?? model.modelID
    }

    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult {
        let transformed = try await transform(request, type: .generate)
        let doGenerate: @Sendable () async throws -> TextGenerationResult = { [model] in
            try await model.generate(transformed)
        }
        let doStream: @Sendable () -> AsyncThrowingStream<LanguageStreamPart, Error> = { [model] in
            model.stream(transformed)
        }

        guard let wrapGenerate = middleware.wrapGenerate else {
            return try await doGenerate()
        }
        return try await wrapGenerate(AILanguageModelGenerateContext(
            doGenerate: doGenerate,
            doStream: doStream,
            request: transformed,
            model: model
        ))
    }

    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let transformed = try await transform(request, type: .stream)
                    let doGenerate: @Sendable () async throws -> TextGenerationResult = { [model] in
                        try await model.generate(transformed)
                    }
                    let doStream: @Sendable () -> AsyncThrowingStream<LanguageStreamPart, Error> = { [model] in
                        model.stream(transformed)
                    }
                    let stream = middleware.wrapStream?(AILanguageModelStreamContext(
                        doGenerate: doGenerate,
                        doStream: doStream,
                        request: transformed,
                        model: model
                    )) ?? doStream()

                    for try await part in canonicalLanguageStream(stream, providerID: providerID) {
                        continuation.yield(part)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func transform(_ request: LanguageModelRequest, type: AILanguageModelCallType) async throws -> LanguageModelRequest {
        guard let transformRequest = middleware.transformRequest else {
            return request
        }
        return try await transformRequest(AILanguageModelTransformContext(
            type: type,
            request: request,
            model: model
        ))
    }
}

final class AIWrappedImageModel: ImageModel, @unchecked Sendable {
    private let model: any ImageModel
    private let middleware: AIImageModelMiddleware
    let providerID: String
    let modelID: String

    var supportsFileInputs: Bool? {
        get async {
            if let override = middleware.overrideSupportsFileInputs { return await override(model) }
            return await model.supportsFileInputs
        }
    }

    var supportsMaskInputs: Bool? {
        get async {
            if let override = middleware.overrideSupportsMaskInputs { return await override(model) }
            return await model.supportsMaskInputs
        }
    }

    init(
        model: any ImageModel,
        middleware: AIImageModelMiddleware,
        modelID: String?,
        providerID: String?
    ) {
        self.model = model
        self.middleware = middleware
        self.providerID = providerID ?? middleware.overrideProviderID?(model) ?? model.providerID
        self.modelID = modelID ?? middleware.overrideModelID?(model) ?? model.modelID
    }

    func generateImage(_ request: ImageGenerationRequest) async throws -> ImageGenerationResult {
        let transformed = try await transform(request)
        let doGenerate: @Sendable () async throws -> ImageGenerationResult = { [model] in
            try await model.generateImage(transformed)
        }
        guard let wrapGenerate = middleware.wrapGenerate else {
            return try await doGenerate()
        }
        return try await wrapGenerate(AIImageModelGenerateContext(
            doGenerate: doGenerate,
            request: transformed,
            model: model
        ))
    }

    private func transform(_ request: ImageGenerationRequest) async throws -> ImageGenerationRequest {
        guard let transformRequest = middleware.transformRequest else {
            return request
        }
        return try await transformRequest(AIImageModelTransformContext(request: request, model: model))
    }
}

final class AIWrappedEmbeddingModel: EmbeddingModel, @unchecked Sendable {
    private let model: any EmbeddingModel
    private let middleware: AIEmbeddingModelMiddleware
    let providerID: String
    let modelID: String
    var maxEmbeddingsPerCall: Int? { model.maxEmbeddingsPerCall }
    var maxInputBytesPerCall: Int? { model.maxInputBytesPerCall }
    var providerOptionsTransformer: AIEmbeddingProviderOptionsTransformer? { model.providerOptionsTransformer }

    init(
        model: any EmbeddingModel,
        middleware: AIEmbeddingModelMiddleware,
        modelID: String?,
        providerID: String?
    ) {
        self.model = model
        self.middleware = middleware
        self.providerID = providerID ?? middleware.overrideProviderID?(model) ?? model.providerID
        self.modelID = modelID ?? middleware.overrideModelID?(model) ?? model.modelID
    }

    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResult {
        let transformed = try await transform(request)
        let doEmbed: @Sendable () async throws -> EmbeddingResult = { [model] in
            try await model.embed(transformed)
        }
        guard let wrapEmbed = middleware.wrapEmbed else {
            return try await doEmbed()
        }
        return try await wrapEmbed(AIEmbeddingModelEmbedContext(
            doEmbed: doEmbed,
            request: transformed,
            model: model
        ))
    }

    private func transform(_ request: EmbeddingRequest) async throws -> EmbeddingRequest {
        guard let transformRequest = middleware.transformRequest else {
            return request
        }
        return try await transformRequest(AIEmbeddingModelTransformContext(request: request, model: model))
    }
}

final class AIWrappedProvider: AIFileProvider, AISkillsProvider, @unchecked Sendable {
    private let provider: any AIProvider
    private let languageModelMiddleware: [AILanguageModelMiddleware]
    private let imageModelMiddleware: [AIImageModelMiddleware]
    private let embeddingModelMiddleware: [AIEmbeddingModelMiddleware]

    let providerID: String
    let supportedCapabilities: Set<ModelCapability>

    init(
        provider: any AIProvider,
        languageModelMiddleware: [AILanguageModelMiddleware],
        imageModelMiddleware: [AIImageModelMiddleware],
        embeddingModelMiddleware: [AIEmbeddingModelMiddleware]
    ) {
        self.provider = provider
        self.languageModelMiddleware = languageModelMiddleware
        self.imageModelMiddleware = imageModelMiddleware
        self.embeddingModelMiddleware = embeddingModelMiddleware
        self.providerID = provider.providerID
        self.supportedCapabilities = provider.supportedCapabilities
    }

    func languageModel(_ modelID: String) throws -> any LanguageModel {
        wrapLanguageModel(try provider.languageModel(modelID), middleware: languageModelMiddleware)
    }

    func embeddingModel(_ modelID: String) throws -> any EmbeddingModel {
        let model = try provider.embeddingModel(modelID)
        guard !embeddingModelMiddleware.isEmpty else {
            return model
        }
        return wrapEmbeddingModel(model, middleware: embeddingModelMiddleware)
    }

    func imageModel(_ modelID: String) throws -> any ImageModel {
        let model = try provider.imageModel(modelID)
        guard !imageModelMiddleware.isEmpty else {
            return model
        }
        return wrapImageModel(model, middleware: imageModelMiddleware)
    }

    func transcriptionModel(_ modelID: String) throws -> any TranscriptionModel {
        try provider.transcriptionModel(modelID)
    }

    func speechModel(_ modelID: String) throws -> any SpeechModel {
        try provider.speechModel(modelID)
    }

    func videoModel(_ modelID: String) throws -> any VideoModel {
        try provider.videoModel(modelID)
    }

    func rerankingModel(_ modelID: String) throws -> any RerankingModel {
        try provider.rerankingModel(modelID)
    }

    func files() throws -> any AIFileClient {
        guard let fileProvider = provider as? any AIFileProvider else {
            throw AIProviderRegistryError.unsupportedFiles(providerID: provider.providerID)
        }
        return try fileProvider.files()
    }

    func skills() throws -> any AISkillsClient {
        guard let skillsProvider = provider as? any AISkillsProvider else {
            throw AIProviderRegistryError.unsupportedSkills(providerID: provider.providerID)
        }
        return try skillsProvider.skills()
    }
}