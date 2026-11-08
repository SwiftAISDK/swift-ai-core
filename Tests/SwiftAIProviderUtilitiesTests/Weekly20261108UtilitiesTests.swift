import Foundation
import Testing
import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport

private actor NovemberToolAssets: AITransport {
    var requests: [AIHTTPRequest] = []
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        return .init(statusCode: 200, headers: ["content-type": "application/octet-stream"], body: Data([0x89, 0x50, 0x4e, 0x47]))
    }
    func sendValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPResponse { try await send(request) }
}

@Suite("Weekly20261108 provider utilities")
struct Weekly20261108UtilitiesTests {
    @Test func firstAliasWinsWithoutMergingEvenWhenEmpty() throws {
        let result = try resolveProviderOptions(providerOptions: ["canonical": [:], "alias": ["value": true]], namespaces: ["canonical", "alias"], resolution: .first)
        #expect(result.options == [:])
        #expect(result.namespaces == ["canonical"])
    }
    @Test func mergeTracksEachNamespaceOnceAndLaterKeysWin() throws {
        let result = try resolveProviderOptions(providerOptions: ["base": ["a": 1, "b": 1], "alias": ["b": 2]], namespaces: ["base", "alias", "base"], resolution: .merge)
        #expect(result.options == ["a": 1, "b": 2])
        #expect(result.namespaces == ["base", "alias"])
        #expect(try resolveProviderOptions(providerOptions: ["base": .null], namespaces: ["base"], resolution: .merge).options == nil)
    }
    @Test func firstSkipsUnvisitedInvalidAliasAndMergeRejectsIt() throws {
        let options: [String: JSONValue] = ["base": ["ok": true], "alias": "invalid"]
        #expect(try resolveProviderOptions(providerOptions: options, namespaces: ["base", "alias"], resolution: .first).options == ["ok": true])
        #expect(throws: AIError.self) { try resolveProviderOptions(providerOptions: options, namespaces: ["base", "alias"], resolution: .merge) }
    }
    @Test func pingBypassesSmoothingWithoutFlushingBufferedText() async throws {
        let input = AsyncThrowingStream<LanguageStreamPart, Error> { c in
            c.yield(.textStart(id: "t")); c.yield(.textDeltaPart(id: "t", delta: "hel")); c.yield(.ping)
            c.yield(.textDeltaPart(id: "t", delta: "lo ")); c.yield(.textEnd(id: "t")); c.yield(.finish(reason: "stop", usage: nil)); c.finish()
        }
        var parts: [LanguageStreamPart] = []
        for try await part in smoothStream(input, delayNanoseconds: 0) { parts.append(part) }
        let ping = try #require(parts.firstIndex(of: .ping))
        let text = try #require(parts.firstIndex { if case .textDeltaPart = $0 { return true }; return false })
        #expect(ping < text)
        #expect(parts[text] == .textDeltaPart(id: "t", delta: "hello "))
    }

    @Test(arguments: [false, true])
    func legacyURLToolOutputsRespectModelSupportAndPreserveOptions(_ supported: Bool) async throws {
        let transport = NovemberToolAssets()
        let metadata: JSONValue = ["openai": ["detail": "high"]]
        let output: JSONValue = ["type": "content", "value": [["type": "file-url", "url": "https://example.com/asset.pdf", "mediaType": "application/pdf", "providerOptions": metadata]]]
        let request = LanguageModelRequest(messages: [.init(role: .assistant, content: [.toolResult(.init(toolCallID: "call", toolName: "asset", result: output))])])
        let prepared = try await downloadUnsupportedPromptAssets(in: request, supportedURLs: supported ? ["application/pdf": [.init { _ in true }]] : [:], transport: transport)
        let expectedCount = supported ? 0 : 1
        #expect(await transport.requests.count == expectedCount)
        guard case let .toolResult(result) = prepared.messages[0].content[0] else { Issue.record("Missing result"); return }
        let file = try #require(result.modelOutput?["value"]?[0])
        #expect(file["type"] == "file")
        #expect(file["providerOptions"] == metadata)
        #expect(file["data"]?["type"] == (supported ? "url" : "data"))
        #expect(file["mediaType"] == (supported ? "application/pdf" : "image/png"))
        #expect(result.result == output)
    }

    @Test func legacyImageDataURLNormalizesWithoutNetwork() async throws {
        let transport = NovemberToolAssets()
        let output: JSONValue = ["type": "content", "value": [["type": "image-url", "url": "data:image/png;base64,iVBORw=="]]]
        let request = LanguageModelRequest(messages: [.init(role: .tool, content: [.toolResult(.init(toolCallID: "call", toolName: "asset", result: output))])])
        let prepared = try await downloadUnsupportedPromptAssets(in: request, supportedURLs: [:], transport: transport)
        guard case let .toolResult(result) = prepared.messages[0].content[0] else { Issue.record("Missing result"); return }
        #expect(await transport.requests.isEmpty)
        #expect(result.modelOutput?["value"]?[0]?["mediaType"] == "image/png")
        #expect(result.modelOutput?["value"]?[0]?["data"]?["data"] == "iVBORw==")
    }

    @Test func reverseToolAliasesPreferDeclaredNamesWithoutDroppingForwardAliases() {
        let mapping = AIToolNameMapping(customToolNameToProviderToolName: ["declared": "computer", "inline": "computer"], preferredCustomToolNames: ["declared"])
        #expect(mapping.toProviderToolName("inline") == "computer")
        #expect(mapping.toProviderToolName("declared") == "computer")
        #expect(mapping.toCustomToolName("computer") == "declared")
    }

    @Test(arguments: [false, true])
    func googleLiveUsagePreservesGrossCountsAndKnownModalities(_ terminal: Bool) {
        let raw: JSONValue = ["usageMetadata": [
            "promptTokenCount": 30, "toolUsePromptTokenCount": 3,
            "responseTokenCount": 9, "thoughtsTokenCount": 7,
            "cachedContentTokenCount": 8,
            "promptTokensDetails": [
                ["modality": "audio", "tokenCount": 20],
                ["modality": "AUDIO", "tokenCount": 10],
                ["modality": "TEXT", "tokenCount": 0],
                ["modality": "IMAGE", "tokenCount": 100]
            ],
            "responseTokensDetails": [["modality": "AUDIO", "tokenCount": 9]]
        ]]
        let event: AIRealtimeServerEvent = terminal
            ? .responseDone(responseID: "r", status: "completed", raw: raw)
            : .custom(rawType: "usageMetadata", raw: raw)
        #expect(event.usage == .init(inputTokens: 33, outputTokens: 16,
            cachedInputTokens: 8, inputTextTokens: 0, inputAudioTokens: 30,
            outputAudioTokens: 9))
        #expect(AIRealtimeServerEvent.custom(rawType: "setupComplete", raw: raw).usage == nil)
    }

    @Test func googleLiveUsageDoesNotInferMissingCountsOrCarrySnapshots() {
        let partial: JSONValue = ["usageMetadata": [
            "toolUsePromptTokenCount": 3, "thoughtsTokenCount": 7,
            "cachedContentTokenCount": 0, "candidatesTokenCount": 99,
            "promptTokensDetails": [["modality": "TEXT", "tokenCount": 0]],
            "responseTokensDetails": [["modality": "AUDIO", "tokenCount": .null]]
        ]]
        #expect(AIRealtimeServerEvent.custom(rawType: "usageMetadata", raw: partial).usage
            == .init(cachedInputTokens: 0, inputTextTokens: 0))
        #expect(AIRealtimeServerEvent.responseDone(responseID: "r", status: "completed", raw: [:]).usage == nil)
        #expect(AIRealtimeServerEvent.custom(rawType: "usageMetadata", raw: ["usageMetadata": [:]]).usage == nil)
    }
}
