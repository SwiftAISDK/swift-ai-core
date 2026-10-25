import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public enum AIProviderRegistryError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidModelID(modelID: String, modelType: String, separator: String)
    case noSuchProvider(providerID: String, modelType: String, availableProviders: [String])
    case unsupportedFiles(providerID: String)
    case unsupportedSkills(providerID: String)

    public var description: String {
        switch self {
        case let .invalidModelID(modelID, modelType, separator):
            return "Invalid \(modelType) id for registry: \(modelID) (must be in the format \"providerId\(separator)modelId\")."
        case let .noSuchProvider(providerID, modelType, availableProviders):
            let available = availableProviders.sorted().joined(separator: ", ")
            return "No provider '\(providerID)' for \(modelType). Available providers: \(available)."
        case let .unsupportedFiles(providerID):
            return "The provider '\(providerID)' does not support file uploads. Make sure it conforms to AIFileProvider."
        case let .unsupportedSkills(providerID):
            return "The provider '\(providerID)' does not support skills. Make sure it conforms to AISkillsProvider."
        }
    }
}

public final class AIProviderRegistry: AIProvider, AIEvaluationProvider, AIDecisionProvider, @unchecked Sendable {
    public let providerID: String
    public let supportedCapabilities: Set<ModelCapability>

    private let providers: [String: any AIProvider]
    private let separator: String
    private let languageModelMiddleware: [AILanguageModelMiddleware]
    private let imageModelMiddleware: [AIImageModelMiddleware]

    public init(
        providers: [String: any AIProvider],
        separator: String = ":",
        providerID: String = "provider-registry",
        languageModelMiddleware: [AILanguageModelMiddleware] = [],
        imageModelMiddleware: [AIImageModelMiddleware] = []
    ) {
        self.providers = providers
        self.separator = separator
        self.languageModelMiddleware = languageModelMiddleware
        self.imageModelMiddleware = imageModelMiddleware
        self.providerID = providerID
        self.supportedCapabilities = providers.values.reduce(into: Set<ModelCapability>()) { result, provider in
            result.formUnion(provider.supportedCapabilities)
        }
    }

    public func languageModel(_ modelID: String) throws -> any LanguageModel {
        let (providerID, routedModelID) = try split(modelID, modelType: "languageModel")
        let model = try provider(providerID, modelType: "languageModel").languageModel(routedModelID)
        guard !languageModelMiddleware.isEmpty else {
            return model
        }
        return wrapLanguageModel(model, middleware: languageModelMiddleware)
    }

    public func embeddingModel(_ modelID: String) throws -> any EmbeddingModel {
        let (providerID, routedModelID) = try split(modelID, modelType: "embeddingModel")
        return try provider(providerID, modelType: "embeddingModel").embeddingModel(routedModelID)
    }

    public func imageModel(_ modelID: String) throws -> any ImageModel {
        let (providerID, routedModelID) = try split(modelID, modelType: "imageModel")
        let model = try provider(providerID, modelType: "imageModel").imageModel(routedModelID)
        guard !imageModelMiddleware.isEmpty else {
            return model
        }
        return wrapImageModel(model, middleware: imageModelMiddleware)
    }

    public func transcriptionModel(_ modelID: String) throws -> any TranscriptionModel {
        let (providerID, routedModelID) = try split(modelID, modelType: "transcriptionModel")
        return try provider(providerID, modelType: "transcriptionModel").transcriptionModel(routedModelID)
    }

    public func speechModel(_ modelID: String) throws -> any SpeechModel {
        let (providerID, routedModelID) = try split(modelID, modelType: "speechModel")
        return try provider(providerID, modelType: "speechModel").speechModel(routedModelID)
    }

    public func videoModel(_ modelID: String) throws -> any VideoModel {
        let (providerID, routedModelID) = try split(modelID, modelType: "videoModel")
        return try provider(providerID, modelType: "videoModel").videoModel(routedModelID)
    }

    public func rerankingModel(_ modelID: String) throws -> any RerankingModel {
        let (providerID, routedModelID) = try split(modelID, modelType: "rerankingModel")
        return try provider(providerID, modelType: "rerankingModel").rerankingModel(routedModelID)
    }

    public func evaluationModel(_ modelID: String) throws -> any AIEvaluationModelV4 {
        let (providerID, routedModelID) = try split(modelID, modelType: "evaluationModel")
        let provider = try provider(providerID, modelType: "evaluationModel")
        guard let evaluationProvider = provider as? any AIEvaluationProvider else {
            throw AIEvaluationModelResolutionError.noSuchModel(modelID: modelID)
        }
        return try validateEvaluationModelVersion(
            evaluationProvider.evaluationModel(routedModelID)
        )
    }

    public func decisionModel(_ modelID: String) throws -> any AIDecisionModelV4 {
        let (providerID, routedModelID) = try split(modelID, modelType: "decisionModel")
        let provider = try provider(providerID, modelType: "decisionModel")
        guard let decisionProvider = provider as? any AIDecisionProvider else {
            throw AIError.unsupportedModel(provider: providerID, capability: .decision, modelID: routedModelID)
        }
        return try validateDecisionModelVersion(decisionProvider.decisionModel(routedModelID))
    }

    public func files(_ providerID: String) throws -> any AIFileClient {
        guard let provider = try provider(providerID, modelType: "files") as? any AIFileProvider else {
            throw AIProviderRegistryError.unsupportedFiles(providerID: providerID)
        }
        return try provider.files()
    }

    public func skills(_ providerID: String) throws -> any AISkillsClient {
        guard let provider = try provider(providerID, modelType: "skills") as? any AISkillsProvider else {
            throw AIProviderRegistryError.unsupportedSkills(providerID: providerID)
        }
        return try provider.skills()
    }

    private func provider(_ providerID: String, modelType: String) throws -> any AIProvider {
        guard let provider = providers[providerID] else {
            throw AIProviderRegistryError.noSuchProvider(
                providerID: providerID,
                modelType: modelType,
                availableProviders: Array(providers.keys)
            )
        }
        return provider
    }

    private func split(_ modelID: String, modelType: String) throws -> (providerID: String, modelID: String) {
        guard let range = modelID.range(of: separator) else {
            throw AIProviderRegistryError.invalidModelID(modelID: modelID, modelType: modelType, separator: separator)
        }
        return (
            providerID: String(modelID[..<range.lowerBound]),
            modelID: String(modelID[range.upperBound...])
        )
    }
}

public func createProviderRegistry(
    _ providers: [String: any AIProvider],
    separator: String = ":",
    languageModelMiddleware: [AILanguageModelMiddleware] = [],
    imageModelMiddleware: [AIImageModelMiddleware] = []
) -> AIProviderRegistry {
    AIProviderRegistry(
        providers: providers,
        separator: separator,
        languageModelMiddleware: languageModelMiddleware,
        imageModelMiddleware: imageModelMiddleware
    )
}

public func createProviderRegistry(
    _ providers: [String: any AIProvider],
    separator: String = ":",
    languageModelMiddleware: AILanguageModelMiddleware,
    imageModelMiddleware: [AIImageModelMiddleware] = []
) -> AIProviderRegistry {
    createProviderRegistry(
        providers,
        separator: separator,
        languageModelMiddleware: [languageModelMiddleware],
        imageModelMiddleware: imageModelMiddleware
    )
}

public func createProviderRegistry(
    _ providers: [String: any AIProvider],
    separator: String = ":",
    languageModelMiddleware: [AILanguageModelMiddleware] = [],
    imageModelMiddleware: AIImageModelMiddleware
) -> AIProviderRegistry {
    createProviderRegistry(
        providers,
        separator: separator,
        languageModelMiddleware: languageModelMiddleware,
        imageModelMiddleware: [imageModelMiddleware]
    )
}

public func experimentalCreateProviderRegistry(
    _ providers: [String: any AIProvider],
    separator: String = ":",
    languageModelMiddleware: [AILanguageModelMiddleware] = [],
    imageModelMiddleware: [AIImageModelMiddleware] = []
) -> AIProviderRegistry {
    createProviderRegistry(
        providers,
        separator: separator,
        languageModelMiddleware: languageModelMiddleware,
        imageModelMiddleware: imageModelMiddleware
    )
}

public func experimentalCreateProviderRegistry(
    _ providers: [String: any AIProvider],
    separator: String = ":",
    languageModelMiddleware: AILanguageModelMiddleware,
    imageModelMiddleware: [AIImageModelMiddleware] = []
) -> AIProviderRegistry {
    createProviderRegistry(
        providers,
        separator: separator,
        languageModelMiddleware: languageModelMiddleware,
        imageModelMiddleware: imageModelMiddleware
    )
}

public func experimentalCreateProviderRegistry(
    _ providers: [String: any AIProvider],
    separator: String = ":",
    languageModelMiddleware: [AILanguageModelMiddleware] = [],
    imageModelMiddleware: AIImageModelMiddleware
) -> AIProviderRegistry {
    createProviderRegistry(
        providers,
        separator: separator,
        languageModelMiddleware: languageModelMiddleware,
        imageModelMiddleware: imageModelMiddleware
    )
}

public final class AICustomProvider: AIFileProvider, AISkillsProvider, AIEvaluationProvider, AIDecisionProvider, @unchecked Sendable {
    public let providerID: String
    public let supportedCapabilities: Set<ModelCapability>

    private let languageModels: [String: any LanguageModel]
    private let embeddingModels: [String: any EmbeddingModel]
    private let imageModels: [String: any ImageModel]
    private let transcriptionModels: [String: any TranscriptionModel]
    private let speechModels: [String: any SpeechModel]
    private let videoModels: [String: any VideoModel]
    private let rerankingModels: [String: any RerankingModel]
    private let evaluationModels: [String: AIEvaluationModelReference]
    private let decisionModels: [String: AIDecisionModelReference]
    private let filesClient: (any AIFileClient)?
    private let skillsClient: (any AISkillsClient)?
    private let fallbackProvider: (any AIProvider)?

    private var decisionModelIDResolver: (@Sendable (String) throws -> any AIDecisionModelV4)?
    private var evaluationModelIDResolver: (@Sendable (String) throws -> any AIEvaluationModelV4)?

    public init(
        providerID: String = "custom",
        languageModels: [String: any LanguageModel] = [:],
        embeddingModels: [String: any EmbeddingModel] = [:],
        imageModels: [String: any ImageModel] = [:],
        transcriptionModels: [String: any TranscriptionModel] = [:],
        speechModels: [String: any SpeechModel] = [:],
        videoModels: [String: any VideoModel] = [:],
        rerankingModels: [String: any RerankingModel] = [:],
        decisionModels: [String: AIDecisionModelReference],
        evaluationModels: [String: AIEvaluationModelReference] = [:],
        files: (any AIFileClient)? = nil,
        skills: (any AISkillsClient)? = nil,
        fallbackProvider: (any AIProvider)? = nil
    ) {
        self.providerID = providerID
        self.languageModels = languageModels
        self.embeddingModels = embeddingModels
        self.imageModels = imageModels
        self.transcriptionModels = transcriptionModels
        self.speechModels = speechModels
        self.videoModels = videoModels
        self.rerankingModels = rerankingModels
        self.evaluationModels = evaluationModels
        self.decisionModels = decisionModels
        self.filesClient = files
        self.skillsClient = skills
        self.fallbackProvider = fallbackProvider

        var capabilities = fallbackProvider?.supportedCapabilities ?? []
        if !languageModels.isEmpty { capabilities.insert(.language) }
        if !embeddingModels.isEmpty { capabilities.insert(.embedding) }
        if !imageModels.isEmpty { capabilities.insert(.image) }
        if !transcriptionModels.isEmpty { capabilities.insert(.transcription) }
        if !speechModels.isEmpty { capabilities.insert(.speech) }
        if !videoModels.isEmpty { capabilities.insert(.video) }
        if !rerankingModels.isEmpty { capabilities.insert(.reranking) }
        if !evaluationModels.isEmpty { capabilities.insert(.evaluation) }
        if !decisionModels.isEmpty { capabilities.insert(.decision) }
        self.supportedCapabilities = capabilities
    }

    /// Explicit alias resolvers for applications adapting a default-provider API.
    public convenience init(
        providerID: String = "custom",
        languageModels: [String: any LanguageModel] = [:],
        embeddingModels: [String: any EmbeddingModel] = [:],
        imageModels: [String: any ImageModel] = [:],
        transcriptionModels: [String: any TranscriptionModel] = [:],
        speechModels: [String: any SpeechModel] = [:],
        videoModels: [String: any VideoModel] = [:],
        rerankingModels: [String: any RerankingModel] = [:],
        decisionModels: [String: AIDecisionModelReference],
        evaluationModels: [String: AIEvaluationModelReference] = [:],
        files: (any AIFileClient)? = nil,
        skills: (any AISkillsClient)? = nil,
        fallbackProvider: (any AIProvider)? = nil,
        resolveDecisionModelID: @escaping @Sendable (String) throws -> any AIDecisionModelV4,
        resolveEvaluationModelID: @escaping @Sendable (String) throws -> any AIEvaluationModelV4
    ) {
        self.init(providerID: providerID, languageModels: languageModels, embeddingModels: embeddingModels, imageModels: imageModels, transcriptionModels: transcriptionModels, speechModels: speechModels, videoModels: videoModels, rerankingModels: rerankingModels, decisionModels: decisionModels, evaluationModels: evaluationModels, files: files, skills: skills, fallbackProvider: fallbackProvider)
        self.decisionModelIDResolver = resolveDecisionModelID
        self.evaluationModelIDResolver = resolveEvaluationModelID
    }

    /// Retains the evaluation-era initializer while decision maps are additive.
    public convenience init(
        providerID: String = "custom",
        languageModels: [String: any LanguageModel] = [:],
        embeddingModels: [String: any EmbeddingModel] = [:],
        imageModels: [String: any ImageModel] = [:],
        transcriptionModels: [String: any TranscriptionModel] = [:],
        speechModels: [String: any SpeechModel] = [:],
        videoModels: [String: any VideoModel] = [:],
        rerankingModels: [String: any RerankingModel] = [:],
        evaluationModels: [String: AIEvaluationModelReference] = [:],
        files: (any AIFileClient)? = nil,
        skills: (any AISkillsClient)? = nil,
        fallbackProvider: (any AIProvider)? = nil
    ) {
        self.init(providerID: providerID, languageModels: languageModels, embeddingModels: embeddingModels, imageModels: imageModels, transcriptionModels: transcriptionModels, speechModels: speechModels, videoModels: videoModels, rerankingModels: rerankingModels, decisionModels: [:], evaluationModels: evaluationModels, files: files, skills: skills, fallbackProvider: fallbackProvider)
    }

    /// Source-compatible initializer retained from SwiftAISDK 1.7.0.
    public convenience init(
        providerID: String = "custom",
        languageModels: [String: any LanguageModel] = [:],
        embeddingModels: [String: any EmbeddingModel] = [:],
        imageModels: [String: any ImageModel] = [:],
        transcriptionModels: [String: any TranscriptionModel] = [:],
        speechModels: [String: any SpeechModel] = [:],
        videoModels: [String: any VideoModel] = [:],
        rerankingModels: [String: any RerankingModel] = [:],
        files: (any AIFileClient)? = nil,
        skills: (any AISkillsClient)? = nil,
        fallbackProvider: (any AIProvider)? = nil
    ) {
        self.init(
            providerID: providerID,
            languageModels: languageModels,
            embeddingModels: embeddingModels,
            imageModels: imageModels,
            transcriptionModels: transcriptionModels,
            speechModels: speechModels,
            videoModels: videoModels,
            rerankingModels: rerankingModels,
            evaluationModels: [String: AIEvaluationModelReference](),
            files: files,
            skills: skills,
            fallbackProvider: fallbackProvider
        )
    }

    public convenience init(
        providerID: String = "custom",
        languageModels: [String: any LanguageModel] = [:],
        embeddingModels: [String: any EmbeddingModel] = [:],
        imageModels: [String: any ImageModel] = [:],
        transcriptionModels: [String: any TranscriptionModel] = [:],
        speechModels: [String: any SpeechModel] = [:],
        videoModels: [String: any VideoModel] = [:],
        rerankingModels: [String: any RerankingModel] = [:],
        evaluationModels: [String: any AIEvaluationModelV4],
        files: (any AIFileClient)? = nil,
        skills: (any AISkillsClient)? = nil,
        fallbackProvider: (any AIProvider)? = nil
    ) {
        self.init(
            providerID: providerID,
            languageModels: languageModels,
            embeddingModels: embeddingModels,
            imageModels: imageModels,
            transcriptionModels: transcriptionModels,
            speechModels: speechModels,
            videoModels: videoModels,
            rerankingModels: rerankingModels,
            evaluationModels: evaluationModels.mapValues { .model($0) },
            files: files,
            skills: skills,
            fallbackProvider: fallbackProvider
        )
    }

    public func languageModel(_ modelID: String) throws -> any LanguageModel {
        if let model = languageModels[modelID] {
            return model
        }
        if let fallbackProvider {
            return try fallbackProvider.languageModel(modelID)
        }
        throw AIError.unsupportedModel(provider: providerID, capability: .language, modelID: modelID)
    }

    public func embeddingModel(_ modelID: String) throws -> any EmbeddingModel {
        if let model = embeddingModels[modelID] {
            return model
        }
        if let fallbackProvider {
            return try fallbackProvider.embeddingModel(modelID)
        }
        throw AIError.unsupportedModel(provider: providerID, capability: .embedding, modelID: modelID)
    }

    public func imageModel(_ modelID: String) throws -> any ImageModel {
        if let model = imageModels[modelID] {
            return model
        }
        if let fallbackProvider {
            return try fallbackProvider.imageModel(modelID)
        }
        throw AIError.unsupportedModel(provider: providerID, capability: .image, modelID: modelID)
    }

    public func transcriptionModel(_ modelID: String) throws -> any TranscriptionModel {
        if let model = transcriptionModels[modelID] {
            return model
        }
        if let fallbackProvider {
            return try fallbackProvider.transcriptionModel(modelID)
        }
        throw AIError.unsupportedModel(provider: providerID, capability: .transcription, modelID: modelID)
    }

    public func speechModel(_ modelID: String) throws -> any SpeechModel {
        if let model = speechModels[modelID] {
            return model
        }
        if let fallbackProvider {
            return try fallbackProvider.speechModel(modelID)
        }
        throw AIError.unsupportedModel(provider: providerID, capability: .speech, modelID: modelID)
    }

    public func videoModel(_ modelID: String) throws -> any VideoModel {
        if let model = videoModels[modelID] {
            return model
        }
        if let fallbackProvider {
            return try fallbackProvider.videoModel(modelID)
        }
        throw AIError.unsupportedModel(provider: providerID, capability: .video, modelID: modelID)
    }

    public func rerankingModel(_ modelID: String) throws -> any RerankingModel {
        if let model = rerankingModels[modelID] {
            return model
        }
        if let fallbackProvider {
            return try fallbackProvider.rerankingModel(modelID)
        }
        throw AIError.unsupportedModel(provider: providerID, capability: .reranking, modelID: modelID)
    }

    public func evaluationModel(_ modelID: String) throws -> any AIEvaluationModelV4 {
        if let reference = evaluationModels[modelID] {
            if case let .modelID(id) = reference, let evaluationModelIDResolver {
                return try validateEvaluationModelVersion(evaluationModelIDResolver(id))
            }
            return try resolveEvaluationModel(reference)
        }
        if let fallback = fallbackProvider as? any AIEvaluationProvider {
            return try validateEvaluationModelVersion(fallback.evaluationModel(modelID))
        }
        throw AIEvaluationModelResolutionError.noSuchModel(modelID: modelID)
    }

    public func decisionModel(_ modelID: String) throws -> any AIDecisionModelV4 {
        if let reference = decisionModels[modelID] {
            if case let .modelID(id) = reference, let decisionModelIDResolver {
                return try validateDecisionModelVersion(decisionModelIDResolver(id))
            }
            return try resolveDecisionModel(reference)
        }
        if let fallback = fallbackProvider as? any AIDecisionProvider {
            return try validateDecisionModelVersion(fallback.decisionModel(modelID))
        }
        throw AIError.unsupportedModel(provider: providerID, capability: .decision, modelID: modelID)
    }

    public func files() throws -> any AIFileClient {
        if let filesClient {
            return filesClient
        }
        if let fallback = fallbackProvider as? any AIFileProvider {
            return try fallback.files()
        }
        throw AIError.invalidArgument(argument: "files", message: "Provider '\(providerID)' does not support file uploads.")
    }

    public func skills() throws -> any AISkillsClient {
        if let skillsClient {
            return skillsClient
        }
        if let fallback = fallbackProvider as? any AISkillsProvider {
            return try fallback.skills()
        }
        throw AIError.invalidArgument(argument: "skills", message: "Provider '\(providerID)' does not support skills.")
    }
}

extension AIProviders {
    /// Source-compatible factory retained from SwiftAISDK 1.7.0.
    public static func customProvider(
        providerID: String = "custom",
        languageModels: [String: any LanguageModel] = [:],
        embeddingModels: [String: any EmbeddingModel] = [:],
        imageModels: [String: any ImageModel] = [:],
        transcriptionModels: [String: any TranscriptionModel] = [:],
        speechModels: [String: any SpeechModel] = [:],
        videoModels: [String: any VideoModel] = [:],
        rerankingModels: [String: any RerankingModel] = [:],
        files: (any AIFileClient)? = nil,
        skills: (any AISkillsClient)? = nil,
        fallbackProvider: (any AIProvider)? = nil
    ) -> AICustomProvider {
        customProvider(
            providerID: providerID,
            languageModels: languageModels,
            embeddingModels: embeddingModels,
            imageModels: imageModels,
            transcriptionModels: transcriptionModels,
            speechModels: speechModels,
            videoModels: videoModels,
            rerankingModels: rerankingModels,
            evaluationModels: [String: AIEvaluationModelReference](),
            files: files,
            skills: skills,
            fallbackProvider: fallbackProvider
        )
    }

    public static func customProvider(
        providerID: String = "custom",
        languageModels: [String: any LanguageModel] = [:],
        embeddingModels: [String: any EmbeddingModel] = [:],
        imageModels: [String: any ImageModel] = [:],
        transcriptionModels: [String: any TranscriptionModel] = [:],
        speechModels: [String: any SpeechModel] = [:],
        videoModels: [String: any VideoModel] = [:],
        rerankingModels: [String: any RerankingModel] = [:],
        evaluationModels: [String: AIEvaluationModelReference] = [:],
        files: (any AIFileClient)? = nil,
        skills: (any AISkillsClient)? = nil,
        fallbackProvider: (any AIProvider)? = nil
    ) -> AICustomProvider {
        AICustomProvider(
            providerID: providerID,
            languageModels: languageModels,
            embeddingModels: embeddingModels,
            imageModels: imageModels,
            transcriptionModels: transcriptionModels,
            speechModels: speechModels,
            videoModels: videoModels,
            rerankingModels: rerankingModels,
            evaluationModels: evaluationModels,
            files: files,
            skills: skills,
            fallbackProvider: fallbackProvider
        )
    }

    public static func customProvider(
        providerID: String = "custom",
        languageModels: [String: any LanguageModel] = [:],
        embeddingModels: [String: any EmbeddingModel] = [:],
        imageModels: [String: any ImageModel] = [:],
        transcriptionModels: [String: any TranscriptionModel] = [:],
        speechModels: [String: any SpeechModel] = [:],
        videoModels: [String: any VideoModel] = [:],
        rerankingModels: [String: any RerankingModel] = [:],
        evaluationModels: [String: any AIEvaluationModelV4],
        files: (any AIFileClient)? = nil,
        skills: (any AISkillsClient)? = nil,
        fallbackProvider: (any AIProvider)? = nil
    ) -> AICustomProvider {
        AICustomProvider(
            providerID: providerID,
            languageModels: languageModels,
            embeddingModels: embeddingModels,
            imageModels: imageModels,
            transcriptionModels: transcriptionModels,
            speechModels: speechModels,
            videoModels: videoModels,
            rerankingModels: rerankingModels,
            evaluationModels: evaluationModels,
            files: files,
            skills: skills,
            fallbackProvider: fallbackProvider
        )
    }

    public static func providerRegistry(
        _ providers: [String: any AIProvider],
        separator: String = ":",
        languageModelMiddleware: [AILanguageModelMiddleware] = [],
        imageModelMiddleware: [AIImageModelMiddleware] = []
    ) -> AIProviderRegistry {
        createProviderRegistry(
            providers,
            separator: separator,
            languageModelMiddleware: languageModelMiddleware,
            imageModelMiddleware: imageModelMiddleware
        )
    }

    public static func providerRegistry(
        _ providers: [String: any AIProvider],
        separator: String = ":",
        languageModelMiddleware: AILanguageModelMiddleware,
        imageModelMiddleware: [AIImageModelMiddleware] = []
    ) -> AIProviderRegistry {
        createProviderRegistry(
            providers,
            separator: separator,
            languageModelMiddleware: languageModelMiddleware,
            imageModelMiddleware: imageModelMiddleware
        )
    }

    public static func providerRegistry(
        _ providers: [String: any AIProvider],
        separator: String = ":",
        languageModelMiddleware: [AILanguageModelMiddleware] = [],
        imageModelMiddleware: AIImageModelMiddleware
    ) -> AIProviderRegistry {
        createProviderRegistry(
            providers,
            separator: separator,
            languageModelMiddleware: languageModelMiddleware,
            imageModelMiddleware: imageModelMiddleware
        )
    }

    public static func experimentalCreateProviderRegistry(
        _ providers: [String: any AIProvider],
        separator: String = ":",
        languageModelMiddleware: [AILanguageModelMiddleware] = [],
        imageModelMiddleware: [AIImageModelMiddleware] = []
    ) -> AIProviderRegistry {
        createProviderRegistry(
            providers,
            separator: separator,
            languageModelMiddleware: languageModelMiddleware,
            imageModelMiddleware: imageModelMiddleware
        )
    }

    public static func experimentalCreateProviderRegistry(
        _ providers: [String: any AIProvider],
        separator: String = ":",
        languageModelMiddleware: AILanguageModelMiddleware,
        imageModelMiddleware: [AIImageModelMiddleware] = []
    ) -> AIProviderRegistry {
        createProviderRegistry(
            providers,
            separator: separator,
            languageModelMiddleware: languageModelMiddleware,
            imageModelMiddleware: imageModelMiddleware
        )
    }

    public static func experimentalCreateProviderRegistry(
        _ providers: [String: any AIProvider],
        separator: String = ":",
        languageModelMiddleware: [AILanguageModelMiddleware] = [],
        imageModelMiddleware: AIImageModelMiddleware
    ) -> AIProviderRegistry {
        createProviderRegistry(
            providers,
            separator: separator,
            languageModelMiddleware: languageModelMiddleware,
            imageModelMiddleware: imageModelMiddleware
        )
    }
}

public extension AIProviders {
    static func customProvider(
        providerID: String = "custom",
        languageModels: [String: any LanguageModel] = [:],
        decisionModels: [String: AIDecisionModelReference],
        fallbackProvider: (any AIProvider)? = nil
    ) -> AICustomProvider {
        AICustomProvider(providerID: providerID, languageModels: languageModels, decisionModels: decisionModels, fallbackProvider: fallbackProvider)
    }
}
