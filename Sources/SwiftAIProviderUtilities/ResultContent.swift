import Foundation
import SwiftAIProvider
import SwiftAITransport


func resolveGeneratedFile(
    _ file: AIStreamFile,
    abortSignal: AIAbortSignal?,
    transport: any AITransport = URLSessionTransport.shared
) async throws -> AIStreamFile {
    guard file.data == nil, file.providerReference == nil, let url = file.url else {
        return file
    }

    try abortSignal?.throwIfAborted()
    let response: AIHTTPResponse
    do {
        response = try await downloadURL(url, transport: transport, abortSignal: abortSignal)
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

    var resolved = file
    resolved.data = response.body
    resolved.url = nil
    return resolved
}

func materializeGeneratedFileContent(
    _ content: [AIResultContentPart],
    abortSignal: AIAbortSignal?,
    transport: any AITransport = URLSessionTransport.shared
) async throws -> [AIResultContentPart] {
    var output: [AIResultContentPart] = []
    output.reserveCapacity(content.count)

    for part in content {
        switch part {
        case let .file(file):
            output.append(.file(try await resolveGeneratedFile(
                file,
                abortSignal: abortSignal,
                transport: transport
            )))
        case let .reasoningFile(file):
            output.append(.reasoningFile(try await resolveGeneratedFile(
                file,
                abortSignal: abortSignal,
                transport: transport
            )))
        default:
            output.append(part)
        }
    }
    return output
}

package func materializeGeneratedFiles(
    in result: TextGenerationResult,
    abortSignal: AIAbortSignal?,
    transport: any AITransport = URLSessionTransport.shared
) async throws -> TextGenerationResult {
    var result = result
    result.content = try await materializeGeneratedFileContent(
        result.content,
        abortSignal: abortSignal,
        transport: transport
    )
    result.refreshDerivedContent()
    return result
}

package func resolvingGeneratedFileStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    abortSignal: AIAbortSignal?,
    transport: any AITransport = URLSessionTransport.shared
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await part in stream {
                    try Task.checkCancellation()
                    switch part {
                    case let .file(file):
                        continuation.yield(.file(try await resolveGeneratedFile(
                            file,
                            abortSignal: abortSignal,
                            transport: transport
                        )))
                    case let .reasoningFile(file):
                        continuation.yield(.reasoningFile(try await resolveGeneratedFile(
                            file,
                            abortSignal: abortSignal,
                            transport: transport
                        )))
                    default:
                        continuation.yield(part)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
    }
}

extension AIResultContentPart {
    package var responseMessagePart: AIContentPart? {
        switch self {
        case let .text(text, providerMetadata), let .citedText(text, _, providerMetadata):
            return .text(text, providerMetadata: providerMetadata)
        case let .reasoning(text, providerMetadata):
            return .reasoning(text, providerMetadata: providerMetadata)
        case .source:
            return nil
        case let .file(file):
            if let data = file.data {
                return .file(
                    mimeType: file.mediaType,
                    data: data,
                    filename: file.filename,
                    providerMetadata: file.providerMetadata
                )
            }
            if let url = file.url {
                return .imageURL(url, providerMetadata: file.providerMetadata)
            }
            return nil
        case let .reasoningFile(file):
            return .reasoningFile(file)
        case let .custom(value, providerMetadata):
            return .custom(value, providerMetadata: providerMetadata)
        case let .toolCall(call):
            return .toolCall(call)
        case let .toolResult(result):
            return .toolResult(result)
        case let .toolApprovalRequest(request):
            return .toolApprovalRequest(request)
        case let .toolApprovalResponse(response):
            return .toolApprovalResponse(response)
        }
    }
}


extension TextGenerationResult {
    package var responseMessageContentParts: [AIContentPart] {
        content.compactMap(\.responseMessagePart)
    }

    package mutating func refreshDerivedContent() {
        files = resultFiles(from: content)
        sources = resultSources(from: content)
        toolCalls = resultToolCalls(from: content)
        toolResults = resultToolResults(from: content)
        toolApprovalRequests = resultToolApprovalRequests(from: content)
        toolApprovalResponses = resultToolApprovalResponses(from: content)
    }

    package mutating func replaceToolCallContent(with calls: [AIToolCall]) {
        guard !calls.isEmpty else { return }
        var remaining = calls
        content = content.map { part in
            guard case let .toolCall(call) = part,
                  let index = remaining.firstIndex(where: { $0.id == call.id }) else {
                return part
            }
            let replacement = remaining.remove(at: index)
            return .toolCall(replacement)
        }
    }

    package mutating func appendGeneratedToolContent(
        approvalRequests: [AIToolApprovalRequest],
        approvalResponses: [AIToolApprovalResponse],
        toolResults: [AIToolResult]
    ) {
        let respondedApprovalIDs = Set(approvalResponses.map(\.id))
        let respondedApprovalRequests = approvalRequests.filter { respondedApprovalIDs.contains($0.id) }
        let pendingApprovalRequests = approvalRequests.filter { !respondedApprovalIDs.contains($0.id) }

        content.append(contentsOf: respondedApprovalRequests.map(AIResultContentPart.toolApprovalRequest))
        content.append(contentsOf: approvalResponses.map(AIResultContentPart.toolApprovalResponse))
        content.append(contentsOf: toolResults.map(AIResultContentPart.toolResult))
        content.append(contentsOf: pendingApprovalRequests.map(AIResultContentPart.toolApprovalRequest))
        refreshDerivedContent()
    }
}
