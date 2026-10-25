import Foundation
import SwiftAIProvider
import SwiftAITransport


public final class JSONImageModel: ImageModel, @unchecked Sendable {
    public let providerID: String
    public let modelID: String
    private let config: JSONModelConfiguration
    private let path: String

    public init(modelID: String, path: String, config: JSONModelConfiguration) {
        self.providerID = config.providerID
        self.modelID = modelID
        self.path = path
        self.config = config
    }

    public func generateImage(_ request: ImageGenerationRequest) async throws -> ImageGenerationResult {
        var body: [String: JSONValue] = [
            "model": .string(modelID),
            "prompt": .string(request.prompt)
        ]
        if let size = request.size { body["size"] = .string(size) }
        if let count = request.count { body["n"] = .number(Double(count)) }
        body.merge(request.extraBody) { _, new in new }

        let response = try await config.sendJSONResponse(path: path, modelID: modelID, body: .object(body), headers: request.headers, abortSignal: request.abortSignal)
        let raw = response.json
        let urls = raw["data"]?.arrayValue?.compactMap { $0["url"]?.stringValue }
            ?? raw["images"]?.arrayValue?.compactMap { $0["url"]?.stringValue }
            ?? raw["output"]?.arrayValue?.compactMap(\.stringValue)
            ?? []
        let base64Images = raw["data"]?.arrayValue?.compactMap { $0["b64_json"]?.stringValue }
            ?? raw["images"]?.arrayValue?.compactMap { $0["b64"]?.stringValue }
            ?? []
        return ImageGenerationResult(
            urls: urls,
            base64Images: base64Images,
            rawValue: raw,
            requestMetadata: imageGenerationRequestMetadata(request, body: .object(body)),
            responseMetadata: aiResponseMetadata(from: raw, response: response.response, modelID: modelID)
        )
    }
}

public final class JSONTranscriptionModel: TranscriptionModel, @unchecked Sendable {
    public let providerID: String
    public let modelID: String
    private let config: JSONModelConfiguration
    private let path: String

    public init(modelID: String, path: String, config: JSONModelConfiguration) {
        self.providerID = config.providerID
        self.modelID = modelID
        self.path = path
        self.config = config
    }

    public func transcribe(_ request: AudioTranscriptionRequest) async throws -> TranscriptionResult {
        var body: [String: JSONValue] = [
            "model": .string(modelID),
            "audio": .string(request.audio.base64EncodedString()),
            "mime_type": .string(request.mimeType),
            "filename": .string(request.fileName)
        ]
        if let language = request.language { body["language"] = .string(language) }
        if let prompt = request.prompt { body["prompt"] = .string(prompt) }
        body.merge(request.extraBody) { _, new in new }

        let response = try await config.sendJSONResponse(path: path, modelID: modelID, body: .object(body), headers: request.headers, abortSignal: request.abortSignal)
        let raw = response.json
        let text = raw["text"]?.stringValue
            ?? raw["transcript"]?.stringValue
            ?? raw["results"]?["channels"]?[0]?["alternatives"]?[0]?["transcript"]?.stringValue
        guard let text else {
            throw AIError.invalidResponse(provider: providerID, message: "No transcription text found.")
        }
        let segments = standardTranscriptionSegments(from: raw)
        return TranscriptionResult(
            text: text,
            rawValue: raw,
            segments: segments,
            language: raw["language"]?.stringValue,
            durationInSeconds: raw["duration"]?.doubleValue ?? transcriptionDuration(from: segments),
            requestMetadata: AIRequestMetadata(body: .object(body), headers: request.headers),
            responseMetadata: aiResponseMetadata(from: raw, response: response.response, modelID: modelID)
        )
    }
}

public final class JSONSpeechModel: SpeechModel, @unchecked Sendable {
    public let providerID: String
    public let modelID: String
    private let config: JSONModelConfiguration
    private let path: String

    public init(modelID: String, path: String, config: JSONModelConfiguration) {
        self.providerID = config.providerID
        self.modelID = modelID
        self.path = path
        self.config = config
    }

    public func speak(_ request: SpeechRequest) async throws -> SpeechResult {
        var body: [String: JSONValue] = [
            "model": .string(modelID),
            "text": .string(request.text)
        ]
        if let voice = request.voice { body["voice"] = .string(voice) }
        if let format = request.format { body["format"] = .string(format) }
        body.merge(request.extraBody) { _, new in new }

        let response = try await config.transport.send(config.request(path: path, modelID: modelID, body: .object(body), headers: request.headers))
        guard (200..<300).contains(response.statusCode) else {
            throw config.rawHTTPStatusError(response)
        }
        if let raw = try? response.jsonValue(),
           let base64 = raw["audio"]?.stringValue ?? raw["audio_base64"]?.stringValue,
           let data = Data(base64Encoded: base64) {
            return SpeechResult(
                audio: data,
                contentType: raw["mime_type"]?.stringValue,
                requestMetadata: AIRequestMetadata(body: .object(body), headers: request.headers),
                responseMetadata: aiResponseMetadata(from: raw, response: response, modelID: modelID)
            )
        }
        return SpeechResult(
            audio: response.body,
            contentType: response.headers["content-type"] ?? response.headers["Content-Type"],
            requestMetadata: AIRequestMetadata(body: .object(body), headers: request.headers),
            responseMetadata: aiResponseMetadata(response: response, modelID: modelID)
        )
    }
}

public final class JSONVideoModel: VideoModel, @unchecked Sendable {
    public let providerID: String
    public let modelID: String
    private let config: JSONModelConfiguration
    private let path: String

    public init(modelID: String, path: String, config: JSONModelConfiguration) {
        self.providerID = config.providerID
        self.modelID = modelID
        self.path = path
        self.config = config
    }

    public func generateVideo(_ request: VideoGenerationRequest) async throws -> VideoGenerationResult {
        var body: [String: JSONValue] = [
            "model": .string(modelID),
            "prompt": .string(request.prompt)
        ]
        if let aspectRatio = request.aspectRatio { body["aspect_ratio"] = .string(aspectRatio) }
        if let durationSeconds = request.durationSeconds { body["duration"] = .number(durationSeconds) }
        body.merge(request.extraBody) { _, new in new }

        let response = try await config.sendJSONResponse(path: path, modelID: modelID, body: .object(body), headers: request.headers, abortSignal: request.abortSignal)
        let raw = response.json
        let urls = raw["data"]?.arrayValue?.compactMap { $0["url"]?.stringValue }
            ?? raw["videos"]?.arrayValue?.compactMap { $0["url"]?.stringValue }
            ?? raw["output"]?.arrayValue?.compactMap(\.stringValue)
            ?? []
        return VideoGenerationResult(
            urls: urls,
            operationID: raw["id"]?.stringValue ?? raw["operation"]?["name"]?.stringValue,
            rawValue: raw,
            requestMetadata: videoGenerationRequestMetadata(request, body: .object(body)),
            responseMetadata: aiResponseMetadata(from: raw, response: response.response, modelID: modelID)
        )
    }
}

public final class JSONRerankingModel: RerankingModel, @unchecked Sendable {
    public let providerID: String
    public let modelID: String
    private let config: JSONModelConfiguration
    private let path: String

    public init(modelID: String, path: String, config: JSONModelConfiguration) {
        self.providerID = config.providerID
        self.modelID = modelID
        self.path = path
        self.config = config
    }

    public func rerank(_ request: RerankingRequest) async throws -> RerankingResult {
        var body: [String: JSONValue] = [
            "model": .string(modelID),
            "query": .string(request.query),
            "documents": .array(request.documents)
        ]
        if let topK = request.topK { body["top_k"] = .number(Double(topK)) }
        body.merge(request.extraBody) { _, new in new }

        let response = try await config.sendJSONResponse(path: path, modelID: modelID, body: .object(body), headers: request.headers, abortSignal: request.abortSignal)
        let raw = response.json
        let results = raw["results"]?.arrayValue?.compactMap { item -> RerankedDocument? in
            guard let index = item["index"]?.intValue ?? item["document_index"]?.intValue,
                  let score = item["relevance_score"]?.doubleValue ?? item["score"]?.doubleValue else {
                return nil
            }
            return RerankedDocument(index: index, score: score, document: item["document"]?.stringValue)
        } ?? []
        return RerankingResult(
            results: results,
            rawValue: raw,
            requestMetadata: AIRequestMetadata(body: .object(body), headers: request.headers),
            responseMetadata: aiResponseMetadata(from: raw, response: response.response, modelID: modelID)
        )
    }
}
/// Neutral configuration for the legacy JSON media adapters. Custom wire protocols
/// can provide error parsing without importing a built-in provider.
public struct JSONModelConfiguration: AIProviderHTTPConfiguration {
    public var http: AIProviderHTTPClient
    public var errorHandler: (@Sendable (AIHTTPResponse) -> AIError)?
    public var rawErrorHandler: (@Sendable (AIHTTPResponse) -> AIError)?
    public init(http: AIProviderHTTPClient,
                errorHandler: (@Sendable (AIHTTPResponse) -> AIError)? = nil,
                rawErrorHandler: (@Sendable (AIHTTPResponse) -> AIError)? = nil) {
        self.http = http; self.errorHandler = errorHandler; self.rawErrorHandler = rawErrorHandler
    }
    public func httpStatusError(_ response: AIHTTPResponse) -> AIError {
        errorHandler?(response) ?? apiCallError(provider: providerID, response: response)
    }
    func rawHTTPStatusError(_ response: AIHTTPResponse) -> AIError {
        rawErrorHandler?(response) ?? apiCallError(provider: providerID, response: response)
    }
}
