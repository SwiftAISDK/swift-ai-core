import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension AI {
    public static func embed(model: any EmbeddingModel, value: String, dimensions: Int? = nil, providerOptions: [String: JSONValue] = [:], extraBody: [String: JSONValue] = [:], headers: [String: String] = [:], abortSignal: AIAbortSignal? = nil, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> EmbeddingResult {
        try await embed(model: model, request: EmbeddingRequest(values: [value], dimensions: dimensions, providerOptions: providerOptions, extraBody: extraBody, headers: headers, abortSignal: abortSignal), retryPolicy: retryPolicy, telemetry: telemetry)
    }

    public static func embed(model: any EmbeddingModel, request: EmbeddingRequest, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> EmbeddingResult {
        try validateEmbeddingDimensions(request.dimensions)
        return try await withTelemetry(
            operationID: request.values.count == 1 ? "ai.embed" : "ai.embedMany",
            providerID: model.providerID,
            modelID: model.modelID,
            input: embeddingRequestTelemetryInput(request),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: embeddingTelemetryOutput,
            usage: { $0.usage },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata }
        ) {
            var result = try await model.embed(request)
            try validateEmbeddingResultCount(
                result.embeddings.count,
                expectedCount: request.values.count,
                providerID: model.providerID
            )
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = AIRequestMetadata(body: embeddingRequestMetadataBody(request), headers: request.headers)
            }
            return result
        }
    }

    public static func embedMany(
        model: any EmbeddingModel,
        values: [String],
        dimensions: Int? = nil,
        chunkSize: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> EmbeddingResult {
        try validateEmbeddingDimensions(dimensions)
        let effectiveMaxEmbeddingsPerCall: Int?
        switch (chunkSize, model.maxEmbeddingsPerCall) {
        case let (requested?, providerMaximum?):
            effectiveMaxEmbeddingsPerCall = min(requested, providerMaximum)
        case let (requested?, nil):
            effectiveMaxEmbeddingsPerCall = requested
        case let (nil, providerMaximum?):
            effectiveMaxEmbeddingsPerCall = providerMaximum
        case (nil, nil):
            effectiveMaxEmbeddingsPerCall = nil
        }
        let chunks = try embeddingValueChunks(
            values,
            maxEmbeddingsPerCall: effectiveMaxEmbeddingsPerCall,
            maxInputBytesPerCall: model.maxInputBytesPerCall
        )
        let shouldTransformProviderOptions = effectiveMaxEmbeddingsPerCall != nil
            || model.maxInputBytesPerCall != nil

        let request = EmbeddingRequest(values: values, dimensions: dimensions, providerOptions: providerOptions, extraBody: extraBody, headers: headers, abortSignal: abortSignal)
        if chunks.isEmpty {
            return try await withTelemetry(
                operationID: "ai.embedMany",
                providerID: model.providerID,
                modelID: model.modelID,
                input: embeddingRequestTelemetryInput(request),
                telemetry: telemetry,
                retryPolicy: retryPolicy,
                abortSignal: request.abortSignal,
                output: embeddingTelemetryOutput,
                usage: { $0.usage },
                warnings: { $0.warnings },
                providerMetadata: { $0.providerMetadata },
                responseMetadata: { $0.responseMetadata }
            ) {
                EmbeddingResult(
                    embeddings: [],
                    usage: TokenUsage(inputTokens: 0, totalTokens: 0),
                    rawValue: .array([JSONValue]()),
                    requestMetadata: AIRequestMetadata(body: embeddingRequestMetadataBody(request), headers: headers)
                )
            }
        }
        guard chunks.count > 1 else {
            let transformedOptions = if shouldTransformProviderOptions {
                try await model.providerOptionsTransformer?(
                    AIEmbeddingProviderOptionsTransformContext(
                        providerOptions: providerOptions,
                        values: values,
                        startIndex: 0,
                        endIndex: values.count
                    )
                ) ?? providerOptions
            } else {
                providerOptions
            }
            return try await embed(model: model, request: EmbeddingRequest(values: values, dimensions: dimensions, providerOptions: transformedOptions, extraBody: extraBody, headers: headers, abortSignal: abortSignal), retryPolicy: retryPolicy, telemetry: telemetry)
        }

        return try await withTelemetry(
            operationID: "ai.embedMany",
            providerID: model.providerID,
            modelID: model.modelID,
            input: embeddingRequestTelemetryInput(request),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: embeddingTelemetryOutput,
            usage: { $0.usage },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata }
        ) {
            var embeddings: [[Double]] = []
            var usage: TokenUsage?
            var rawValues: [JSONValue] = []
            var warnings: [AIWarning] = []
            var providerMetadata: [String: JSONValue] = [:]
            var requestMetadata = AIRequestMetadata(body: embeddingRequestMetadataBody(request), headers: request.headers)
            var responseMetadata = AIResponseMetadata()

            var nextChunkStartIndex = 0
            for chunk in chunks {
                let startIndex = nextChunkStartIndex
                let endIndex = startIndex + chunk.count
                nextChunkStartIndex = endIndex
                let chunkProviderOptions = try await model.providerOptionsTransformer?(
                    AIEmbeddingProviderOptionsTransformContext(
                        providerOptions: providerOptions,
                        values: values,
                        startIndex: startIndex,
                        endIndex: endIndex
                    )
                ) ?? providerOptions
                let result = try await withRetry(policy: retryPolicy) {
                    try await model.embed(EmbeddingRequest(values: chunk, dimensions: dimensions, providerOptions: chunkProviderOptions, extraBody: extraBody, headers: headers, abortSignal: abortSignal))
                }
                try validateEmbeddingResultCount(
                    result.embeddings.count,
                    expectedCount: chunk.count,
                    providerID: model.providerID
                )
                embeddings.append(contentsOf: result.embeddings)
                usage = sumTokenUsage(usage, result.usage)
                rawValues.append(result.rawValue)
                warnings.append(contentsOf: result.warnings)
                providerMetadata.merge(result.providerMetadata) { _, new in new }
                if requestMetadata.body == nil, result.requestMetadata.body != nil {
                    requestMetadata = result.requestMetadata
                }
                if responseMetadata == AIResponseMetadata() {
                    responseMetadata = result.responseMetadata
                }
            }

            return EmbeddingResult(
                embeddings: embeddings,
                usage: usage,
                rawValue: .array(rawValues),
                warnings: warnings,
                providerMetadata: providerMetadata,
                requestMetadata: requestMetadata,
                responseMetadata: responseMetadata
            )
        }
    }

    public static func generateImage(model: any ImageModel, request: ImageGenerationRequest, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> ImageGenerationResult {
        let attempts = ImageGenerationAttemptAccumulator()
        do {
            return try await withTelemetry(
                operationID: "ai.generateImage",
                providerID: model.providerID,
                modelID: model.modelID,
                input: imageRequestTelemetryInput(request),
                telemetry: telemetry,
                retryPolicy: retryPolicy,
                abortSignal: request.abortSignal,
                output: imageTelemetryOutput,
                usage: { $0.usage },
                warnings: { $0.warnings },
                providerMetadata: { $0.providerMetadata },
                responseMetadata: { $0.responseMetadata }
            ) {
                attempts.beginAttempt()
                var result = try await model.generateImage(request)
                if result.requestMetadata == AIRequestMetadata() {
                    result.requestMetadata = imageGenerationRequestMetadata(request)
                }
                if result.calls.isEmpty {
                    result.calls = [ImageGenerationCall(
                        urls: result.urls,
                        base64Images: result.base64Images,
                        warnings: result.warnings,
                        usage: result.usage,
                        providerMetadata: result.providerMetadata,
                        responseMetadata: result.responseMetadata
                    )]
                }
                attempts.record(result)
                guard !result.urls.isEmpty || !result.base64Images.isEmpty else {
                    if result.isRetryable == false {
                        throw AITerminalEmptyImageResultError()
                    }
                    throw AIRetryableEmptyImageResultError()
                }
                return attempts.merging(into: result)
            }
        } catch let error as AINoOutputError {
            throw error
        } catch {
            if attempts.lastAttemptWasEmpty {
                throw attempts.noOutputError(providerID: model.providerID)
            }
            throw error
        }
    }

    public static func generateImage(model: any ImageModel, prompt: String, size: String? = nil, aspectRatio: String? = nil, seed: Int? = nil, count: Int? = nil, files: [ImageInputFile] = [], mask: ImageInputFile? = nil, providerOptions: [String: JSONValue] = [:], extraBody: [String: JSONValue] = [:], headers: [String: String] = [:], abortSignal: AIAbortSignal? = nil, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> ImageGenerationResult {
        try await generateImage(model: model, request: ImageGenerationRequest(prompt: prompt, size: size, aspectRatio: aspectRatio, seed: seed, count: count, files: files, mask: mask, providerOptions: providerOptions, extraBody: extraBody, headers: headers, abortSignal: abortSignal), retryPolicy: retryPolicy, telemetry: telemetry)
    }

    public static func transcribe(model: any TranscriptionModel, request: AudioTranscriptionRequest, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> TranscriptionResult {
        try await withTelemetry(
            operationID: "ai.transcribe",
            providerID: model.providerID,
            modelID: model.modelID,
            input: transcriptionRequestTelemetryInput(request),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: transcriptionTelemetryOutput,
            usage: { _ in nil },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata },
            providerUsage: { $0.usage }
        ) {
            var result = try await model.transcribe(request)
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = AIRequestMetadata(body: transcriptionRequestMetadataBody(request), headers: request.headers)
            }
            guard !result.text.isEmpty else {
                throw AINoOutputError(kind: .transcript, responses: [result.responseMetadata])
            }
            return result
        }
    }

    public static func generateSpeech(model: any SpeechModel, request: SpeechRequest, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> SpeechResult {
        try await withTelemetry(
            operationID: "ai.generateSpeech",
            providerID: model.providerID,
            modelID: model.modelID,
            input: speechRequestTelemetryInput(request),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: speechTelemetryOutput,
            usage: { _ in nil },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { result in
                var metadata = result.responseMetadata
                metadata.body = nil
                return metadata
            },
            providerUsage: { $0.usage }
        ) {
            var result = try await model.speak(request)
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = AIRequestMetadata(body: speechRequestMetadataBody(request), headers: request.headers)
            }
            guard !result.audio.isEmpty else {
                throw AINoOutputError(kind: .speech, responses: [result.responseMetadata])
            }
            result.contentType = resolvedSpeechMediaType(
                audio: result.audio,
                responseHeaders: result.responseMetadata.headers,
                outputFormat: request.format,
                providerContentType: result.contentType
            )
            return result
        }
    }

    public static func generateAudio(model: any AudioGenerationModel, request: AudioGenerationRequest, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> AudioGenerationResult {
        try await withTelemetry(
            operationID: "ai.generateAudio",
            providerID: model.providerID,
            modelID: model.modelID,
            input: audioGenerationRequestTelemetryInput(request),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: audioGenerationTelemetryOutput,
            usage: { _ in nil },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata }
        ) {
            var result = try await model.generateAudio(request)
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = AIRequestMetadata(body: audioGenerationRequestMetadataBody(request), headers: request.headers)
            }
            guard !result.audio.isEmpty else {
                throw AINoOutputError(kind: .audio, responses: [result.responseMetadata])
            }
            return result
        }
    }

    public static func transformAudio(model: any AudioTransformationModel, request: AudioTransformationRequest, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> AudioTransformationResult {
        try await withTelemetry(
            operationID: "ai.transformAudio",
            providerID: model.providerID,
            modelID: model.modelID,
            input: audioTransformationRequestTelemetryInput(request),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: audioTransformationTelemetryOutput,
            usage: { _ in nil },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata }
        ) {
            var result = try await model.transformAudio(request)
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = AIRequestMetadata(body: audioTransformationRequestMetadataBody(request), headers: request.headers)
            }
            guard !result.audio.isEmpty else {
                throw AINoOutputError(kind: .audio, responses: [result.responseMetadata])
            }
            return result
        }
    }

    public static func generateVideo(
        model: any VideoModel,
        request: VideoGenerationRequest,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        poll: VideoGenerationPollOptions? = nil,
        webhook: VideoGenerationWebhookFactory? = nil
    ) async throws -> VideoGenerationResult {
        let normalized = normalizeVideoGenerationRequest(request, model: model)
        let operationOptionsRequested = poll != nil || webhook != nil
        let availableOperationModel = model as? any AsyncVideoModel
        let operationModel = availableOperationModel.flatMap { candidate in
            operationOptionsRequested || !model.supportsUnaryVideoGeneration ? candidate : nil
        }
        if !model.supportsUnaryVideoGeneration, availableOperationModel == nil {
            throw AIError.invalidArgument(
                argument: "model",
                message: "Video model \(model.modelID) does not implement unary generation or start/status operations."
            )
        }
        return try await withTelemetry(
            operationID: "ai.generateVideo",
            providerID: model.providerID,
            modelID: model.modelID,
            input: videoRequestTelemetryInput(normalized.request),
            telemetry: telemetry,
            // Start/status calls own their retry boundaries. Retrying this outer
            // closure after a successful billable start could create a second job.
            retryPolicy: operationModel == nil ? retryPolicy : .none,
            abortSignal: normalized.request.abortSignal,
            output: videoTelemetryOutput,
            usage: { _ in nil },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata },
            logEmptyWarnings: false
        ) {
            var result: VideoGenerationResult
            if let operationModel {
                result = try await generateVideoUsingOperations(
                    model: operationModel,
                    request: normalized.request,
                    poll: poll,
                    webhook: webhook,
                    retryPolicy: retryPolicy
                )
            } else {
                result = try await model.generateVideo(normalized.request)
                if operationOptionsRequested {
                    result.warnings.insert(AIWarning(
                        type: "other",
                        message: "poll/webhook options were provided but the model does not support start/status operations. Falling back to unary generateVideo."
                    ), at: 0)
                }
            }
            result.warnings = normalized.warnings + result.warnings
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = videoGenerationRequestMetadata(normalized.request)
            }
            guard !result.urls.isEmpty || !result.base64Videos.isEmpty else {
                throw AINoOutputError(kind: .video, responses: [result.responseMetadata])
            }
            return result
        }
    }

    public static func rerank(model: any RerankingModel, request: RerankingRequest, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> RerankingResult {
        try await withTelemetry(
            operationID: "ai.rerank",
            providerID: model.providerID,
            modelID: model.modelID,
            input: rerankingRequestTelemetryInput(request),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: rerankingTelemetryOutput,
            usage: { _ in nil },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata }
        ) {
            var result = try await model.rerank(request)
            let upperBound = request.documentsJSON.count
            if let invalid = result.results.first(where: { $0.index < 0 || $0.index >= upperBound }) {
                throw AIError.invalidResponse(
                    provider: model.providerID,
                    message: "Invalid ranking index \(invalid.index). Expected an integer between 0 and \(max(upperBound - 1, 0))."
                )
            }
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = AIRequestMetadata(body: rerankingRequestMetadataBody(request), headers: request.headers)
            }
            return result
        }
    }

    public static func uploadFile(client: any AIFileClient, request: FileUploadRequest, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> FileUploadResult {
        do {
            return try await withTelemetry(
                operationID: "ai.uploadFile",
                providerID: client.providerID,
                modelID: nil,
                input: fileUploadFacadeTelemetryInput(request),
                telemetry: telemetry,
                // A file stream is single-use and cannot be replayed safely.
                retryPolicy: request.fileData.isStream ? .none : retryPolicy,
                abortSignal: request.abortSignal,
                output: fileUploadFacadeTelemetryOutput,
                usage: { _ in nil },
                warnings: { $0.warnings },
                providerMetadata: { $0.providerMetadata },
                responseMetadata: { $0.responseMetadata }
            ) {
                var result = try await client.uploadFile(request)
                if result.requestMetadata == AIRequestMetadata() {
                    result.requestMetadata = AIRequestMetadata(
                        body: fileUploadFacadeMetadataBody(request),
                        headers: request.headers
                    )
                }
                return result
            }
        } catch {
            // The facade owns the same guarantee as upstream: every failed
            // upload releases a single-use caller stream, even for custom
            // clients that reject before reading it.
            await request.fileData.cancelStream()
            throw error
        }
    }

    public static func getFileMetadata(
        client: any AIFileClient,
        request: FileMetadataRequest,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> FileMetadataResult {
        try await withTelemetry(
            operationID: "ai.getFileMetadata",
            providerID: client.providerID,
            modelID: nil,
            input: fileOperationTelemetryInput(
                file: request.file,
                providerOptions: request.providerOptions,
                headers: request.headers
            ),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: fileMetadataFacadeTelemetryOutput,
            usage: { _ in nil },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata }
        ) {
            var result = try await client.getFileMetadata(request)
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = fileOperationRequestMetadata(
                    file: request.file,
                    providerOptions: request.providerOptions,
                    headers: request.headers
                )
            }
            return result
        }
    }

    public static func downloadFile(
        client: any AIFileClient,
        request: FileDownloadRequest,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> FileDownloadResult {
        try await withTelemetry(
            operationID: "ai.downloadFile",
            providerID: client.providerID,
            modelID: nil,
            input: fileOperationTelemetryInput(
                file: request.file,
                providerOptions: request.providerOptions,
                headers: request.headers
            ),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: fileDownloadFacadeTelemetryOutput,
            usage: { _ in nil },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata }
        ) {
            var result = try await client.downloadFile(request)
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = fileOperationRequestMetadata(
                    file: request.file,
                    providerOptions: request.providerOptions,
                    headers: request.headers
                )
            }
            return result
        }
    }

    public static func deleteFile(
        client: any AIFileClient,
        request: FileDeleteRequest,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> FileDeleteResult {
        try await withTelemetry(
            operationID: "ai.deleteFile",
            providerID: client.providerID,
            modelID: nil,
            input: fileOperationTelemetryInput(
                file: request.file,
                providerOptions: request.providerOptions,
                headers: request.headers
            ),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: fileDeleteFacadeTelemetryOutput,
            usage: { _ in nil },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata }
        ) {
            var result = try await client.deleteFile(request)
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = fileOperationRequestMetadata(
                    file: request.file,
                    providerOptions: request.providerOptions,
                    headers: request.headers
                )
            }
            return result
        }
    }

    public static func uploadSkill(client: any AISkillsClient, request: SkillUploadRequest, retryPolicy: AIRetryPolicy = .default, telemetry: Telemetry.Options? = nil) async throws -> SkillUploadResult {
        try await withTelemetry(
            operationID: "ai.uploadSkill",
            providerID: client.providerID,
            modelID: nil,
            input: skillUploadRequestTelemetryInput(request),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: skillUploadTelemetryOutput,
            usage: { _ in nil },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata }
        ) {
            var result = try await client.uploadSkill(request)
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = AIRequestMetadata(body: skillUploadRequestMetadataBody(request), headers: request.headers)
            }
            return result
        }
    }
}


struct AIRetryableEmptyImageResultError: Error, CustomStringConvertible, Sendable {
    var description: String { "Image model returned no images (retryable)." }
}

struct AITerminalEmptyImageResultError: Error, CustomStringConvertible, Sendable {
    var description: String { "Image model returned no images (not retryable)." }
}

private final class ImageGenerationAttemptAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [ImageGenerationCall] = []
    private var storedWarnings: [AIWarning] = []
    private var storedUsage: TokenUsage?
    private var storedProviderMetadata: [String: JSONValue] = [:]
    private var storedLastAttemptWasEmpty = false

    var lastAttemptWasEmpty: Bool {
        lock.withLock { storedLastAttemptWasEmpty }
    }

    func beginAttempt() {
        lock.withLock { storedLastAttemptWasEmpty = false }
    }

    func record(_ result: ImageGenerationResult) {
        lock.withLock {
            storedCalls.append(contentsOf: result.calls)
            storedWarnings.append(contentsOf: result.warnings)
            storedUsage = sumTokenUsage(storedUsage, result.usage)
            storedProviderMetadata.merge(result.providerMetadata) { _, new in new }
            storedLastAttemptWasEmpty = result.urls.isEmpty && result.base64Images.isEmpty
        }
    }

    func merging(into result: ImageGenerationResult) -> ImageGenerationResult {
        lock.withLock {
            var output = result
            output.calls = storedCalls
            output.warnings = storedWarnings
            output.usage = storedUsage
            output.providerMetadata = storedProviderMetadata
            return output
        }
    }

    func noOutputError(providerID: String) -> AINoOutputError {
        lock.withLock {
            AINoOutputError(
                provider: providerID,
                kind: .image,
                responses: storedCalls.map(\.responseMetadata),
                calls: storedCalls
            )
        }
    }
}

private func validateEmbeddingDimensions(_ dimensions: Int?) throws {
    if let dimensions, dimensions <= 0 {
        throw AIError.invalidArgument(argument: "dimensions", message: "dimensions must be a positive integer.")
    }
}

private func validateEmbeddingResultCount(
    _ actualCount: Int,
    expectedCount: Int,
    providerID: String
) throws {
    guard actualCount == expectedCount else {
        throw AIError.invalidResponse(
            provider: providerID,
            message: "Expected \(expectedCount) embeddings, but received \(actualCount)."
        )
    }
}

private func fileUploadFacadeTelemetryInput(_ request: FileUploadRequest) -> JSONValue {
    var values = fileUploadFacadeMetadataValues(request)
    if !request.headers.isEmpty {
        values["headers"] = .object(request.headers.mapValues(JSONValue.string))
    }
    return .object(values)
}

private func fileUploadFacadeMetadataBody(_ request: FileUploadRequest) -> JSONValue {
    .object(fileUploadFacadeMetadataValues(request))
}

private func fileUploadFacadeMetadataValues(_ request: FileUploadRequest) -> [String: JSONValue] {
    var values: [String: JSONValue] = [
        "mediaType": .string(request.mediaType),
        "dataType": .string(request.fileData.isStream ? "stream" : "data")
    ]
    if let byteCount = request.fileData.byteCount {
        values["byteLength"] = .number(Double(byteCount))
    }
    if let filename = request.filename { values["filename"] = .string(filename) }
    if let purpose = request.purpose { values["purpose"] = .string(purpose) }
    if let displayName = request.displayName { values["displayName"] = .string(displayName) }
    if !request.providerOptions.isEmpty { values["providerOptions"] = .object(request.providerOptions) }
    if !request.extraBody.isEmpty { values["extraBody"] = .object(request.extraBody) }
    return values
}

private func fileOperationTelemetryInput(
    file: [String: String],
    providerOptions: [String: JSONValue],
    headers: [String: String]
) -> JSONValue {
    .object([
        "file": .object(file.mapValues(JSONValue.string)),
        "providerOptions": providerOptions.isEmpty ? nil : .object(providerOptions),
        "headers": headers.isEmpty ? nil : .object(headers.mapValues(JSONValue.string))
    ])
}

private func fileOperationRequestMetadata(
    file: [String: String],
    providerOptions: [String: JSONValue],
    headers: [String: String]
) -> AIRequestMetadata {
    AIRequestMetadata(body: .object([
        "file": .object(file.mapValues(JSONValue.string)),
        "providerOptions": providerOptions.isEmpty ? nil : .object(providerOptions)
    ]), headers: headers)
}

private func fileUploadFacadeTelemetryOutput(_ result: FileUploadResult) -> JSONValue {
    .object([
        "providerReference": .object(result.providerReference.mapValues(JSONValue.string)),
        "filename": result.filename.map(JSONValue.string),
        "mediaType": result.mediaType.map(JSONValue.string),
        "byteSize": result.byteSize.map { .number(Double($0)) },
        "createdAt": result.createdAt.map { .number($0.timeIntervalSince1970) },
        "expiresAt": result.expiresAt.map { .number($0.timeIntervalSince1970) },
        "metadata": result.metadata.isEmpty ? nil : .object(result.metadata),
        "rawValue": result.rawValue
    ])
}

private func fileMetadataFacadeTelemetryOutput(_ result: FileMetadataResult) -> JSONValue {
    .object([
        "providerReference": .object(result.providerReference.mapValues(JSONValue.string)),
        "filename": result.filename.map(JSONValue.string),
        "mediaType": result.mediaType.map(JSONValue.string),
        "byteSize": result.byteSize.map { .number(Double($0)) },
        "createdAt": result.createdAt.map { .number($0.timeIntervalSince1970) },
        "expiresAt": result.expiresAt.map { .number($0.timeIntervalSince1970) }
    ])
}

private func fileDownloadFacadeTelemetryOutput(_ result: FileDownloadResult) -> JSONValue {
    .object(["mediaType": result.mediaType.map(JSONValue.string)])
}

private func fileDeleteFacadeTelemetryOutput(_ result: FileDeleteResult) -> JSONValue {
    .object([
        "providerReference": .object(result.providerReference.mapValues(JSONValue.string)),
        "deleted": .bool(result.deleted)
    ])
}

private func embeddingValueChunks(
    _ values: [String],
    maxEmbeddingsPerCall: Int?,
    maxInputBytesPerCall: Int?
) throws -> [[String]] {
    if let maxEmbeddingsPerCall, maxEmbeddingsPerCall <= 0 {
        throw AIError.invalidArgument(
            argument: "maxEmbeddingsPerCall",
            message: "maxEmbeddingsPerCall must be greater than zero."
        )
    }
    if let maxInputBytesPerCall, maxInputBytesPerCall <= 0 {
        throw AIError.invalidArgument(
            argument: "maxInputBytesPerCall",
            message: "maxInputBytesPerCall must be greater than zero."
        )
    }
    guard !values.isEmpty else { return [] }
    guard maxEmbeddingsPerCall != nil || maxInputBytesPerCall != nil else { return [values] }

    var chunks: [[String]] = []
    var current: [String] = []
    var currentInputBytes = 0

    for value in values {
        let inputBytes = value.utf8.count
        let exceedsCount = maxEmbeddingsPerCall.map { current.count >= $0 } ?? false
        let exceedsBytes = maxInputBytesPerCall.map { currentInputBytes + inputBytes > $0 } ?? false
        if !current.isEmpty, exceedsCount || exceedsBytes {
            chunks.append(current)
            current = []
            currentInputBytes = 0
        }
        current.append(value)
        currentInputBytes += inputBytes
    }

    chunks.append(current)
    return chunks
}

// Strict providers validate the distinct original image/frame/reference inputs.
// Legacy normalization copies first_frame into image and discards references;
// those transformations would hide invalid combinations from these providers.


func normalizeVideoGenerationRequest(_ request: VideoGenerationRequest, model: (any VideoModel)? = nil) -> (request: VideoGenerationRequest, warnings: [AIWarning]) {
    if model is any RawVideoGenerationInputModel { return (request, []) }
    var normalized = request
    var warnings: [AIWarning] = []

    if !normalized.frameImages.isEmpty, !normalized.inputReferences.isEmpty {
        normalized.inputReferences = []
        warnings.append(AIWarning(
            type: "other",
            message: "inputReferences were ignored because frameImages were provided; frameImages and inputReferences cannot be combined."
        ))
    }

    if let firstFrame = normalized.frameImages.first(where: { $0.frameType == .firstFrame }) {
        if normalized.image != nil, normalized.image != firstFrame.image {
            warnings.append(AIWarning(
                type: "other",
                message: "prompt.image was ignored because a first_frame frameImage was provided; the first_frame frameImage takes precedence as the start image."
            ))
        }
        normalized.image = firstFrame.image
    }

    return (normalized, warnings)
}

private func resolvedSpeechMediaType(
    audio: Data,
    responseHeaders: [String: String],
    outputFormat: String?,
    providerContentType: String?
) -> String {
    if let detected = detectMediaType(data: audio, topLevelType: "audio") {
        return detected
    }

    if let header = responseHeaders.first(where: {
        $0.key.caseInsensitiveCompare("content-type") == .orderedSame
    })?.value {
        let mediaType = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if mediaType.hasPrefix("audio/") && mediaType.count > "audio/".count {
            return mediaType
        }
    }

    let normalizedOutputFormat = outputFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalizedOutputFormat {
    case "pcm", "audio/pcm":
        return "audio/pcm"
    case "audio/l16":
        return "audio/l16"
    case "mulaw", "audio/mulaw":
        return "audio/mulaw"
    case "alaw", "audio/alaw":
        return "audio/alaw"
    default:
        break
    }

    if let providerContentType {
        let mediaType = providerContentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if mediaType.hasPrefix("audio/") && mediaType.count > "audio/".count {
            return mediaType
        }
    }

    return "audio/mp3"
}