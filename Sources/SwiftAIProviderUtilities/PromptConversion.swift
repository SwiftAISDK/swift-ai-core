import Foundation
import SwiftAIProvider
import SwiftAITransport


package func downloadUnsupportedPromptAssets(
    in request: LanguageModelRequest,
    supportedURLs: [String: [AISupportedURLPattern]],
    transport: any AITransport = URLSessionTransport.shared
) async throws -> LanguageModelRequest {
    var output = request

    for messageIndex in output.messages.indices where output.messages[messageIndex].role == .user {
        for partIndex in output.messages[messageIndex].content.indices {
            guard case let .imageURL(url, providerMetadata) = output.messages[messageIndex].content[partIndex] else { continue }
            let supported = isURLSupported(mediaType: "image/*", url: url, supportedURLs: supportedURLs)
            if supported && output.experimentalDownload == nil { continue }

            try output.abortSignal?.throwIfAborted()
            let response: AIHTTPResponse
            do {
                if let custom = output.experimentalDownload {
                    guard let parsedURL = URL(string: url) else { throw AIDownloadError(url: url, message: "Invalid prompt URL.") }
                    let results = try await custom([.init(url: parsedURL, isURLSupportedByModel: supported, abortSignal: output.abortSignal)])
                    guard results.count == 1 else { throw AIDownloadError(url: url, message: "Download results must match requests.") }
                    guard let downloaded = results[0] else { continue }
                    response = .init(statusCode: 200, headers: downloaded.mediaType.map { ["content-type": $0] } ?? [:], body: downloaded.data)
                } else { response = try await downloadURL(url, transport: transport, abortSignal: output.abortSignal) }
            } catch {
                if error is AIAbortError || error is CancellationError { throw error }
                if let downloadError = error as? AIDownloadError { throw downloadError }
                throw AIDownloadError(url: url, message: String(describing: error))
            }
            guard (200..<300).contains(response.statusCode) else {
                throw AIDownloadError(
                    url: url,
                    message: "Download failed with HTTP status \(response.statusCode)."
                )
            }

            let responseMediaType = response.headerValue("content-type")?
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let mediaType = if let responseMediaType,
                               responseMediaType.contains("/") {
                responseMediaType
            } else {
                detectMediaType(data: response.body, topLevelType: "image") ?? "image/*"
            }
            output.messages[messageIndex].content[partIndex] = .data(
                mimeType: mediaType,
                data: response.body,
                providerMetadata: providerMetadata
            )
        }
    }

    var downloadedToolAssets: [String: AIHTTPResponse] = [:]
    for messageIndex in output.messages.indices {
        for partIndex in output.messages[messageIndex].content.indices {
            guard case var .toolResult(result) = output.messages[messageIndex].content[partIndex],
                  var modelOutput = (result.modelOutput ?? result.result).objectValue,
                  modelOutput["type"]?.stringValue == "content",
                  var items = modelOutput["value"]?.arrayValue else { continue }
            for index in items.indices {
                guard var item = items[index].objectValue else { continue }
                let type = item["type"]?.stringValue
                let urlString: String
                var mediaType: String
                switch type {
                case "file-url", "image-url":
                    guard let url = item["url"]?.stringValue else { continue }
                    urlString = url
                    mediaType = type == "image-url" ? "image" : item["mediaType"]?.stringValue ?? promptURLMediaType(url)
                case "file":
                    guard item["data"]?["type"]?.stringValue == "url", let url = item["data"]?["url"]?.stringValue else { continue }
                    urlString = url
                    mediaType = item["mediaType"]?.stringValue ?? "application/octet-stream"
                default: continue
                }
                item["type"] = "file"
                item.removeValue(forKey: "url")
                if !urlString.lowercased().hasPrefix("data:"), isURLSupported(mediaType: mediaType, url: urlString, supportedURLs: supportedURLs) {
                    item["data"] = ["type": "url", "url": .string(urlString)]
                } else {
                    try output.abortSignal?.throwIfAborted()
                    let response: AIHTTPResponse
                    if let cached = downloadedToolAssets[urlString] { response = cached }
                    else {
                        do {
                            if let custom = output.experimentalDownload {
                                guard let url = URL(string: urlString) else { throw AIDownloadError(url: urlString, message: "Invalid tool-result URL.") }
                                let results = try await custom([.init(url: url, isURLSupportedByModel: false, abortSignal: output.abortSignal)])
                                guard results.count == 1 else { throw AIDownloadError(url: urlString, message: "Download results must match requests.") }
                                guard let downloaded = results[0] else {
                                    item["data"] = ["type": "url", "url": .string(urlString)]
                                    item["mediaType"] = .string(mediaType); items[index] = .object(item); continue
                                }
                                response = .init(statusCode: 200, headers: downloaded.mediaType.map { ["content-type": $0] } ?? [:], body: downloaded.data)
                            } else { response = try await downloadURL(urlString, transport: transport, abortSignal: output.abortSignal) }
                        }
                        catch {
                            if error is AIAbortError || error is CancellationError || error is AIDownloadError { throw error }
                            throw AIDownloadError(url: urlString, message: String(describing: error))
                        }
                        guard (200..<300).contains(response.statusCode) else { throw AIDownloadError(url: urlString, message: "Download failed with HTTP status \(response.statusCode).") }
                        downloadedToolAssets[urlString] = response
                    }
                    let downloadedType = response.headerValue("content-type")?.split(separator: ";", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    if !isFullMediaType(mediaType), let downloadedType { mediaType = downloadedType }
                    if let imageType = detectMediaType(data: response.body, topLevelType: "image") { mediaType = imageType }
                    item["data"] = ["type": "data", "data": .string(response.body.base64EncodedString())]
                }
                item["mediaType"] = .string(mediaType)
                items[index] = .object(item)
            }
            modelOutput["value"] = .array(items)
            result.modelOutput = .object(modelOutput)
            output.messages[messageIndex].content[partIndex] = .toolResult(result)
        }
    }
    return output
}

private func promptURLMediaType(_ url: String) -> String {
    let types = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "avif": "image/avif", "heic": "image/heic", "bmp": "image/bmp", "tiff": "image/tiff", "tif": "image/tiff", "pdf": "application/pdf", "mp4": "video/mp4", "webm": "video/webm", "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg"]
    return URL(string: url).flatMap { types[$0.pathExtension.lowercased()] } ?? "application/octet-stream"
}

func convertToLanguageModelPrompt(_ prompt: StandardizedPrompt) throws -> [AIMessage] {
    let messages = (prompt.instructions ?? []) + prompt.messages.map(convertToLanguageModelMessage)
    var combinedMessages: [AIMessage] = []

    for message in messages {
        guard message.role == .tool, combinedMessages.last?.role == .tool else {
            combinedMessages.append(message)
            continue
        }
        let previousIndex = combinedMessages.count - 1
        let previousContentWasEmpty = combinedMessages[previousIndex].content.isEmpty
        if let contentIndex = combinedMessages[previousIndex].content.indices.last,
           !combinedMessages[previousIndex].providerMetadata.isEmpty {
            combinedMessages[previousIndex].content[contentIndex] = mergingToolPartProviderMetadata(
                combinedMessages[previousIndex].providerMetadata,
                into: combinedMessages[previousIndex].content[contentIndex]
            )
        }
        combinedMessages[previousIndex].content.append(contentsOf: message.content)
        combinedMessages[previousIndex].providerMetadata = previousContentWasEmpty
            ? deepMergeProviderMetadata(combinedMessages[previousIndex].providerMetadata, message.providerMetadata)
            : message.providerMetadata
    }

    let filteredMessages = combinedMessages.filter { message in
        message.role != .tool || !message.content.isEmpty
    }
    try validateToolResultAvailability(in: filteredMessages)
    return filteredMessages
}

func convertToLanguageModelMessage(_ message: AIMessage) -> AIMessage {
    var converted = message

    switch message.role {
    case .system:
        return message
    case .user:
        converted.content = message.content.filter { part in
            if case let .text(text, providerMetadata) = part {
                return !text.isEmpty || !providerMetadata.isEmpty
            }
            return true
        }
    case .assistant:
        converted.content = message.content.filter { part in
            switch part {
            case let .text(text, providerMetadata):
                return !text.isEmpty || !providerMetadata.isEmpty
            case .toolApprovalRequest:
                return false
            default:
                return true
            }
        }
    case .tool:
        converted.content = message.content.filter { part in
            switch part {
            case .toolResult:
                return true
            case let .toolApprovalResponse(response):
                return response.providerExecuted
            default:
                return false
            }
        }
    }

    return converted
}

private func mergingToolPartProviderMetadata(
    _ messageMetadata: [String: JSONValue],
    into part: AIContentPart
) -> AIContentPart {
    let merged = deepMergeProviderMetadata(messageMetadata, part.providerMetadata)
    switch part {
    case let .toolResult(value):
        var result = value
        result.providerMetadata = merged
        return .toolResult(result)
    case let .toolApprovalResponse(value):
        var response = value
        response.providerMetadata = merged
        return .toolApprovalResponse(response)
    default:
        return part
    }
}

private func deepMergeProviderMetadata(
    _ base: [String: JSONValue],
    _ overrides: [String: JSONValue]
) -> [String: JSONValue] {
    var merged = base
    for (key, override) in overrides {
        if case let .object(baseObject) = merged[key],
           case let .object(overrideObject) = override {
            merged[key] = .object(deepMergeProviderMetadata(baseObject, overrideObject))
        } else {
            merged[key] = override
        }
    }
    return merged
}