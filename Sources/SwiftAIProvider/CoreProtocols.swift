import Foundation


public struct AISupportedURLPattern: Sendable {
    private let matcher: @Sendable (String) -> Bool

    public init(_ matcher: @escaping @Sendable (String) -> Bool) {
        self.matcher = matcher
    }

    public func test(_ url: String) -> Bool {
        matcher(url)
    }
}

public func isURLSupported(
    mediaType: String,
    url: String,
    supportedURLs: [String: [AISupportedURLPattern]]
) -> Bool {
    let lowercasedMediaType = mediaType.lowercased()
    let isTopLevelOnly = !lowercasedMediaType.contains("/")

    return supportedURLs.contains { key, patterns in
        let lowercasedKey = key.lowercased()
        let mediaTypePrefix = (lowercasedKey == "*" || lowercasedKey == "*/*")
            ? ""
            : lowercasedKey.replacingOccurrences(of: "*", with: "")

        let mediaTypeMatches: Bool
        if mediaTypePrefix.isEmpty {
            mediaTypeMatches = true
        } else if isTopLevelOnly {
            mediaTypeMatches = "\(lowercasedMediaType)/" == mediaTypePrefix
        } else {
            mediaTypeMatches = lowercasedMediaType.hasPrefix(mediaTypePrefix)
        }

        return mediaTypeMatches && patterns.contains { $0.test(url) }
    }
}

public protocol LanguageModel: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    var supportedURLs: [String: [AISupportedURLPattern]] { get }
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult
    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error>
}

public extension LanguageModel {
    var supportedURLs: [String: [AISupportedURLPattern]] { [:] }

    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await generate(request)
                    try Task.checkCancellation()
                    continuation.yield(.streamStart(warnings: result.warnings))
                    if result.responseMetadata != AIResponseMetadata() {
                        continuation.yield(.responseMetadata(result.responseMetadata))
                    }

                    var nextPartID = 0
                    for contentPart in result.content {
                        try Task.checkCancellation()
                        switch contentPart {
                        case let .citedText(text, citations, providerMetadata):
                            let id = String(nextPartID)
                            nextPartID += 1
                            continuation.yield(.textStart(id: id, providerMetadata: providerMetadata))
                            continuation.yield(.textDeltaPart(id: id, delta: text, providerMetadata: providerMetadata))
                            continuation.yield(.textEnd(id: id, citations: citations, providerMetadata: providerMetadata))
                        case let .text(text, providerMetadata):
                            guard !text.isEmpty else { continue }
                            let id = String(nextPartID)
                            nextPartID += 1
                            continuation.yield(.textStart(id: id, providerMetadata: providerMetadata))
                            continuation.yield(.textDeltaPart(id: id, delta: text, providerMetadata: providerMetadata))
                            continuation.yield(.textEnd(id: id, providerMetadata: providerMetadata))
                        case let .reasoning(reasoning, providerMetadata):
                            guard !reasoning.isEmpty else { continue }
                            let id = String(nextPartID)
                            nextPartID += 1
                            continuation.yield(.reasoningStart(id: id, providerMetadata: providerMetadata))
                            continuation.yield(.reasoningDeltaPart(id: id, delta: reasoning, providerMetadata: providerMetadata))
                            continuation.yield(.reasoningEnd(id: id, providerMetadata: providerMetadata))
                        case let .source(source):
                            continuation.yield(.source(source))
                        case let .file(file):
                            continuation.yield(.file(file))
                        case let .reasoningFile(file):
                            continuation.yield(.reasoningFile(file))
                        case let .custom(value, providerMetadata):
                            continuation.yield(.custom(value, providerMetadata: providerMetadata))
                        case let .toolCall(toolCall):
                            continuation.yield(.toolCall(toolCall))
                        case let .toolResult(toolResult):
                            continuation.yield(.toolResult(toolResult))
                        case let .toolApprovalRequest(request):
                            continuation.yield(.toolApprovalRequest(request))
                        case let .toolApprovalResponse(response):
                            continuation.yield(.toolApprovalResponse(response))
                        }
                    }
                    try Task.checkCancellation()
                    continuation.yield(.finishMetadata(
                        reason: result.finishReason,
                        usage: result.usage,
                        providerMetadata: result.providerMetadata
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}


public protocol EmbeddingModel: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    /// Maximum number of values the model accepts in one embedding call.
    var maxEmbeddingsPerCall: Int? { get }
    /// Maximum aggregate UTF-8 input bytes the model accepts in one embedding call.
    var maxInputBytesPerCall: Int? { get }
    /// Transforms options for one automatic batch while retaining access to the full value list.
    var providerOptionsTransformer: AIEmbeddingProviderOptionsTransformer? { get }
    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResult
}

public extension EmbeddingModel {
    var maxEmbeddingsPerCall: Int? { nil }
    var maxInputBytesPerCall: Int? { nil }
    var providerOptionsTransformer: AIEmbeddingProviderOptionsTransformer? { nil }
}


public protocol ImageModel: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    /// Whether the model accepts reference images; nil means unknown.
    var supportsFileInputs: Bool? { get async }
    /// Whether the model accepts an editing mask; nil means unknown.
    var supportsMaskInputs: Bool? { get async }
    func generateImage(_ request: ImageGenerationRequest) async throws -> ImageGenerationResult
}

public extension ImageModel {
    var supportsFileInputs: Bool? { nil }
    var supportsMaskInputs: Bool? { nil }
}


public protocol TranscriptionModel: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    func transcribe(_ request: AudioTranscriptionRequest) async throws -> TranscriptionResult
}

public protocol SpeechModel: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    func speak(_ request: SpeechRequest) async throws -> SpeechResult
}

public protocol AudioGenerationModel: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    func generateAudio(_ request: AudioGenerationRequest) async throws -> AudioGenerationResult
}

public protocol AudioTransformationModel: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    func transformAudio(_ request: AudioTransformationRequest) async throws -> AudioTransformationResult
}

public protocol VideoModel: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    /// Whether this model has a native unary implementation. Async-only V4
    /// models set this to `false` so the facade selects start/status without
    /// requiring poll or webhook options.
    var supportsUnaryVideoGeneration: Bool { get }
    func generateVideo(_ request: VideoGenerationRequest) async throws -> VideoGenerationResult
}

public extension VideoModel {
    var supportsUnaryVideoGeneration: Bool { true }

    func generateVideo(_ request: VideoGenerationRequest) async throws -> VideoGenerationResult {
        throw AIError.invalidArgument(
            argument: "model",
            message: "Video model \(modelID) does not implement unary video generation."
        )
    }
}


public protocol RerankingModel: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    func rerank(_ request: RerankingRequest) async throws -> RerankingResult
}

public protocol AIFileClient: Sendable {
    var providerID: String { get }
    var supportedFileOperations: Set<AIFileOperation> { get }
    func uploadFile(_ request: FileUploadRequest) async throws -> FileUploadResult
    func getFileMetadata(_ request: FileMetadataRequest) async throws -> FileMetadataResult
    func downloadFile(_ request: FileDownloadRequest) async throws -> FileDownloadResult
    func deleteFile(_ request: FileDeleteRequest) async throws -> FileDeleteResult
}

public enum AIFileOperation: String, Hashable, Sendable {
    case upload
    case getMetadata
    case download
    case delete
}

public extension AIFileClient {
    var supportedFileOperations: Set<AIFileOperation> { [.upload] }

    func getFileMetadata(_ request: FileMetadataRequest) async throws -> FileMetadataResult {
        throw unsupportedFileOperation("metadata retrieval")
    }

    func downloadFile(_ request: FileDownloadRequest) async throws -> FileDownloadResult {
        throw unsupportedFileOperation("download")
    }

    func deleteFile(_ request: FileDeleteRequest) async throws -> FileDeleteResult {
        throw unsupportedFileOperation("deletion")
    }

    private func unsupportedFileOperation(_ operation: String) -> AIError {
        .invalidArgument(
            argument: "client",
            message: "The \(providerID) files client does not support file \(operation)."
        )
    }
}


public protocol AISkillsClient: Sendable {
    var providerID: String { get }
    func uploadSkill(_ request: SkillUploadRequest) async throws -> SkillUploadResult
}

public protocol AIProvider: Sendable {
    var providerID: String { get }
    var supportedCapabilities: Set<ModelCapability> { get }
    func languageModel(_ modelID: String) throws -> any LanguageModel
    func embeddingModel(_ modelID: String) throws -> any EmbeddingModel
    func imageModel(_ modelID: String) throws -> any ImageModel
    func transcriptionModel(_ modelID: String) throws -> any TranscriptionModel
    func speechModel(_ modelID: String) throws -> any SpeechModel
    func videoModel(_ modelID: String) throws -> any VideoModel
    func rerankingModel(_ modelID: String) throws -> any RerankingModel
}

public protocol AIFileProvider: AIProvider {
    func files() throws -> any AIFileClient
}

public protocol AISkillsProvider: AIProvider {
    func skills() throws -> any AISkillsClient
}

public extension AIProvider {
    func callAsFunction(_ modelID: String) throws -> any LanguageModel {
        try languageModel(modelID)
    }

    func chat(_ modelID: String) throws -> any LanguageModel {
        try languageModel(modelID)
    }

    func embedding(_ modelID: String) throws -> any EmbeddingModel {
        try embeddingModel(modelID)
    }

    func textEmbeddingModel(_ modelID: String) throws -> any EmbeddingModel {
        try embeddingModel(modelID)
    }

    func textEmbedding(_ modelID: String) throws -> any EmbeddingModel {
        try embeddingModel(modelID)
    }

    func image(_ modelID: String) throws -> any ImageModel {
        try imageModel(modelID)
    }

    func transcription(_ modelID: String) throws -> any TranscriptionModel {
        try transcriptionModel(modelID)
    }

    func speech(_ modelID: String) throws -> any SpeechModel {
        try speechModel(modelID)
    }

    func video(_ modelID: String) throws -> any VideoModel {
        try videoModel(modelID)
    }

    func reranking(_ modelID: String) throws -> any RerankingModel {
        try rerankingModel(modelID)
    }
}

/// A video model that validates its own raw input combinations before normalization.
public protocol RawVideoGenerationInputModel: VideoModel {}
