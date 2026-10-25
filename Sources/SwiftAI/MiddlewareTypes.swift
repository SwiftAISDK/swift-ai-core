import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public enum AILanguageModelCallType: String, Sendable {
    case generate
    case stream
}

public struct AILanguageModelTransformContext: Sendable {
    public var type: AILanguageModelCallType
    public var request: LanguageModelRequest
    public var model: any LanguageModel

    public init(type: AILanguageModelCallType, request: LanguageModelRequest, model: any LanguageModel) {
        self.type = type
        self.request = request
        self.model = model
    }
}

public struct AILanguageModelGenerateContext: Sendable {
    public var doGenerate: @Sendable () async throws -> TextGenerationResult
    public var doStream: @Sendable () -> AsyncThrowingStream<LanguageStreamPart, Error>
    public var request: LanguageModelRequest
    public var model: any LanguageModel

    public init(
        doGenerate: @escaping @Sendable () async throws -> TextGenerationResult,
        doStream: @escaping @Sendable () -> AsyncThrowingStream<LanguageStreamPart, Error>,
        request: LanguageModelRequest,
        model: any LanguageModel
    ) {
        self.doGenerate = doGenerate
        self.doStream = doStream
        self.request = request
        self.model = model
    }
}

public struct AILanguageModelStreamContext: Sendable {
    public var doGenerate: @Sendable () async throws -> TextGenerationResult
    public var doStream: @Sendable () -> AsyncThrowingStream<LanguageStreamPart, Error>
    public var request: LanguageModelRequest
    public var model: any LanguageModel

    public init(
        doGenerate: @escaping @Sendable () async throws -> TextGenerationResult,
        doStream: @escaping @Sendable () -> AsyncThrowingStream<LanguageStreamPart, Error>,
        request: LanguageModelRequest,
        model: any LanguageModel
    ) {
        self.doGenerate = doGenerate
        self.doStream = doStream
        self.request = request
        self.model = model
    }
}

public struct AILanguageModelMiddleware: Sendable {
    public var overrideProviderID: (@Sendable (_ model: any LanguageModel) -> String)?
    public var overrideModelID: (@Sendable (_ model: any LanguageModel) -> String)?
    public var transformRequest: (@Sendable (AILanguageModelTransformContext) async throws -> LanguageModelRequest)?
    public var wrapGenerate: (@Sendable (AILanguageModelGenerateContext) async throws -> TextGenerationResult)?
    public var wrapStream: (@Sendable (AILanguageModelStreamContext) -> AsyncThrowingStream<LanguageStreamPart, Error>)?

    public init(
        overrideProviderID: (@Sendable (_ model: any LanguageModel) -> String)? = nil,
        overrideModelID: (@Sendable (_ model: any LanguageModel) -> String)? = nil,
        transformRequest: (@Sendable (AILanguageModelTransformContext) async throws -> LanguageModelRequest)? = nil,
        wrapGenerate: (@Sendable (AILanguageModelGenerateContext) async throws -> TextGenerationResult)? = nil,
        wrapStream: (@Sendable (AILanguageModelStreamContext) -> AsyncThrowingStream<LanguageStreamPart, Error>)? = nil
    ) {
        self.overrideProviderID = overrideProviderID
        self.overrideModelID = overrideModelID
        self.transformRequest = transformRequest
        self.wrapGenerate = wrapGenerate
        self.wrapStream = wrapStream
    }
}

public struct AIImageModelTransformContext: Sendable {
    public var request: ImageGenerationRequest
    public var model: any ImageModel

    public init(request: ImageGenerationRequest, model: any ImageModel) {
        self.request = request
        self.model = model
    }
}

public struct AIImageModelGenerateContext: Sendable {
    public var doGenerate: @Sendable () async throws -> ImageGenerationResult
    public var request: ImageGenerationRequest
    public var model: any ImageModel

    public init(
        doGenerate: @escaping @Sendable () async throws -> ImageGenerationResult,
        request: ImageGenerationRequest,
        model: any ImageModel
    ) {
        self.doGenerate = doGenerate
        self.request = request
        self.model = model
    }
}

public struct AIImageModelMiddleware: Sendable {
    public var overrideSupportsFileInputs: (@Sendable (_ model: any ImageModel) async -> Bool?)? = nil
    public var overrideSupportsMaskInputs: (@Sendable (_ model: any ImageModel) async -> Bool?)? = nil
    public var overrideProviderID: (@Sendable (_ model: any ImageModel) -> String)?
    public var overrideModelID: (@Sendable (_ model: any ImageModel) -> String)?
    public var transformRequest: (@Sendable (AIImageModelTransformContext) async throws -> ImageGenerationRequest)?
    public var wrapGenerate: (@Sendable (AIImageModelGenerateContext) async throws -> ImageGenerationResult)?

    public init(
        overrideProviderID: (@Sendable (_ model: any ImageModel) -> String)? = nil,
        overrideModelID: (@Sendable (_ model: any ImageModel) -> String)? = nil,
        transformRequest: (@Sendable (AIImageModelTransformContext) async throws -> ImageGenerationRequest)? = nil,
        wrapGenerate: (@Sendable (AIImageModelGenerateContext) async throws -> ImageGenerationResult)? = nil
    ) {
        self.overrideProviderID = overrideProviderID
        self.overrideModelID = overrideModelID
        self.transformRequest = transformRequest
        self.wrapGenerate = wrapGenerate
    }

    public init(
        overrideSupportsFileInputs: (@Sendable (_ model: any ImageModel) async -> Bool?)?,
        overrideSupportsMaskInputs: (@Sendable (_ model: any ImageModel) async -> Bool?)? = nil,
        overrideProviderID: (@Sendable (_ model: any ImageModel) -> String)? = nil,
        overrideModelID: (@Sendable (_ model: any ImageModel) -> String)? = nil,
        transformRequest: (@Sendable (AIImageModelTransformContext) async throws -> ImageGenerationRequest)? = nil,
        wrapGenerate: (@Sendable (AIImageModelGenerateContext) async throws -> ImageGenerationResult)? = nil
    ) {
        self.init(overrideProviderID: overrideProviderID, overrideModelID: overrideModelID,
                  transformRequest: transformRequest, wrapGenerate: wrapGenerate)
        self.overrideSupportsFileInputs = overrideSupportsFileInputs
        self.overrideSupportsMaskInputs = overrideSupportsMaskInputs
    }
}

public struct AIEmbeddingModelTransformContext: Sendable {
    public var request: EmbeddingRequest
    public var model: any EmbeddingModel

    public init(request: EmbeddingRequest, model: any EmbeddingModel) {
        self.request = request
        self.model = model
    }
}

public struct AIEmbeddingModelEmbedContext: Sendable {
    public var doEmbed: @Sendable () async throws -> EmbeddingResult
    public var request: EmbeddingRequest
    public var model: any EmbeddingModel

    public init(
        doEmbed: @escaping @Sendable () async throws -> EmbeddingResult,
        request: EmbeddingRequest,
        model: any EmbeddingModel
    ) {
        self.doEmbed = doEmbed
        self.request = request
        self.model = model
    }
}

public struct AIEmbeddingModelMiddleware: Sendable {
    public var overrideProviderID: (@Sendable (_ model: any EmbeddingModel) -> String)?
    public var overrideModelID: (@Sendable (_ model: any EmbeddingModel) -> String)?
    public var transformRequest: (@Sendable (AIEmbeddingModelTransformContext) async throws -> EmbeddingRequest)?
    public var wrapEmbed: (@Sendable (AIEmbeddingModelEmbedContext) async throws -> EmbeddingResult)?

    public init(
        overrideProviderID: (@Sendable (_ model: any EmbeddingModel) -> String)? = nil,
        overrideModelID: (@Sendable (_ model: any EmbeddingModel) -> String)? = nil,
        transformRequest: (@Sendable (AIEmbeddingModelTransformContext) async throws -> EmbeddingRequest)? = nil,
        wrapEmbed: (@Sendable (AIEmbeddingModelEmbedContext) async throws -> EmbeddingResult)? = nil
    ) {
        self.overrideProviderID = overrideProviderID
        self.overrideModelID = overrideModelID
        self.transformRequest = transformRequest
        self.wrapEmbed = wrapEmbed
    }
}