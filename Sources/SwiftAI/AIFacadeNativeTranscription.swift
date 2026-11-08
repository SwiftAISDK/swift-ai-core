import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

/// A custom download hook forces local downloading instead of native provider URL fetching.
public typealias AITranscriptionDownload = @Sendable (URL, AIAbortSignal?) async throws -> AIHTTPResponse

extension AI {
    public static func transcribe(
        model: any TranscriptionModel,
        request: AudioURLTranscriptionRequest,
        download: AITranscriptionDownload? = nil,
        downloadTransport: any AITransport = URLSessionTransport.shared,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) async throws -> TranscriptionResult {
        let state = AudioURLTranscriptionPreparation()
        return try await withTelemetry(
            operationID: "ai.transcribe", providerID: model.providerID, modelID: model.modelID,
            input: .object(["timestampGranularities": request.timestampGranularities.map { .array($0.map { .string($0.rawValue) }) }, "providerOptions": .object(request.providerOptions)]),
            telemetry: telemetry, retryPolicy: retryPolicy, abortSignal: request.abortSignal,
            output: transcriptionTelemetryOutput, usage: { _ in nil }, warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata }, responseMetadata: { $0.responseMetadata }, providerUsage: { $0.usage }
        ) {
            try request.abortSignal?.throwIfAborted()
            var bytes = await state.downloaded
            if bytes == nil && download == nil && ["http", "https"].contains(request.audio.scheme?.lowercased() ?? ""),
               let native = try await model.transcribeFromURL(request) {
                guard !native.text.isEmpty else { throw AINoOutputError(kind: .transcript, responses: [native.responseMetadata]) }
                return native
            }
            if bytes == nil {
                let response: AIHTTPResponse
                if let download { response = try await download(request.audio, request.abortSignal) }
                else { response = try await downloadURL(request.audio.absoluteString, transport: downloadTransport, abortSignal: request.abortSignal) }
                guard (200..<300).contains(response.statusCode) else { throw AIDownloadError(url: request.audio.absoluteString, message: "Download failed with HTTP status \(response.statusCode).") }
                bytes = response
                await state.setDownloaded(response)
            }
            guard let response = bytes else { throw AIError.invalidResponse(provider: model.providerID, message: "Audio download produced no response.") }
            let contentType = response.headerValue("content-type")?.split(separator: ";", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let mediaType = contentType.flatMap { topLevelMediaType($0) == "audio" && isFullMediaType($0) ? $0 : nil }
                ?? detectMediaType(data: response.body, topLevelType: "audio") ?? "audio/wav"
            let binary = AudioTranscriptionRequest(audio: response.body, fileName: "audio.\(mediaTypeToExtension(mediaType))", mimeType: mediaType, language: request.language, prompt: request.prompt, providerOptions: request.providerOptions, extraBody: request.extraBody, headers: request.headers, abortSignal: request.abortSignal, timestampGranularities: request.timestampGranularities)
            var result = try await model.transcribe(binary)
            if result.requestMetadata == AIRequestMetadata() { result.requestMetadata = .init(body: transcriptionRequestMetadataBody(binary), headers: request.headers) }
            guard !result.text.isEmpty else { throw AINoOutputError(kind: .transcript, responses: [result.responseMetadata]) }
            return result
        }
    }
}

private actor AudioURLTranscriptionPreparation {
    var downloaded: AIHTTPResponse?
    func setDownloaded(_ response: AIHTTPResponse) { downloaded = response }
}
