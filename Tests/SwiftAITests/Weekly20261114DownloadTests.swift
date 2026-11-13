import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport

private actor November14Downloads: AITransport {
    var requests: [AIHTTPRequest] = []
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse { requests.append(request); return .init(statusCode: 200, headers: ["content-type": "image/png"], body: Data([1, 2, 3])) }
    func sendValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPResponse { try await send(request) }
}
private struct November14FileModel: LanguageModel {
    let providerID = "mock", modelID = "files"
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult {
        .init(text: "file", content: [.file(.init(mediaType: "image/png", url: "https://generated.example.com/image.png"))], finishReason: "stop", rawValue: [:])
    }
}

@Suite("Weekly20261114 explicit download forwarding")
struct Weekly20261114DownloadTests {
    @Test(arguments: [false, true])
    func customDownloaderMaterializesGeneratedFilesWithCancellation(_ streaming: Bool) async throws {
        let downloads = November14Downloads(), controller = AIAbortController()
        var request = LanguageModelRequest(messages: [.user("image")], abortSignal: controller.signal)
        request.experimentalDownload = createDownload(transport: downloads, maxBytes: 512)
        if streaming {
            var files: [AIStreamFile] = []
            for try await part in AI.streamText(model: November14FileModel(), request: request) { if case let .file(file) = part { files.append(file) } }
            #expect(files.first?.data == Data([1, 2, 3]))
        } else {
            let result = try await AI.generateText(model: November14FileModel(), request: request)
            #expect(result.files.first?.data == Data([1, 2, 3]))
            #expect(result.files.first?.url == nil)
        }
        let wire = try #require(await downloads.requests.first)
        #expect(wire.url.host == "generated.example.com")
        #expect(wire.maxResponseBytes == 512 && wire.abortSignal?.isAborted == false)
    }

    @Test func nilGeneratedFileDownloadIsAnError() async throws {
        var request = LanguageModelRequest(messages: [.user("image")])
        request.experimentalDownload = { _ in [nil] }
        await #expect(throws: AIDownloadError.self) { try await AI.generateText(model: November14FileModel(), request: request) }
    }

    @Test func downloaderReceivesSupportedPromptURLAndMayPreserveIt() async throws {
        let controller = AIAbortController()
        var request = LanguageModelRequest(messages: [AIMessage(role: .user, content: [.imageURL("https://input.example.com/image.png")])], abortSignal: controller.signal)
        request.experimentalDownload = { requests in
            #expect(requests.count == 1 && requests[0].isURLSupportedByModel && requests[0].abortSignal === controller.signal)
            return [nil]
        }
        let converted = try await downloadUnsupportedPromptAssets(in: request, supportedURLs: ["image/*": [.init { _ in true }]])
        #expect(converted.messages == request.messages)
    }

    @Test func preabortedDownloadsNeverInvokeInjectedTransport() async throws {
        let downloads = November14Downloads(), controller = AIAbortController()
        controller.abort(reason: "cancelled")
        await #expect(throws: AIAbortError.self) { try await downloadURL("https://files.example.com/image", transport: downloads, abortSignal: controller.signal) }
        #expect(await downloads.requests.isEmpty)
    }
}
