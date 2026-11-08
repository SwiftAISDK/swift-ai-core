import Foundation
import Testing
import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport

@Suite struct Weekly20261108CoreSelectorTests {
    @Test func originalAudioConstructorRetainsFieldsAndNoTimingDefault() {
        let make: (Data, String, String, String?, String?, [String: JSONValue], [String: JSONValue], [String: String], AIAbortSignal?) -> AudioTranscriptionRequest = AudioTranscriptionRequest.init(audio:fileName:mimeType:language:prompt:providerOptions:extraBody:headers:abortSignal:)
        let abort = AIAbortController()
        let value = make(Data([1]), "in.ogg", "audio/ogg", "en", "hint", ["p": true], ["extra": 2], ["x-test": "yes"], abort.signal)
        #expect(value.audio == Data([1]) && value.fileName == "in.ogg" && value.mimeType == "audio/ogg")
        #expect(value.language == "en" && value.prompt == "hint" && value.providerOptions == ["p": true])
        #expect(value.extraBody == ["extra": 2] && value.headers == ["x-test": "yes"] && value.abortSignal === abort.signal)
        #expect(value.timestampGranularities == nil)
        #expect(AudioTranscriptionRequest(audio: Data()).fileName == "audio.wav")
        #expect(AudioTranscriptionRequest(audio: Data(), timestampGranularities: [.word]).timestampGranularities == [.word])
        #expect(AudioURLTranscriptionRequest(audio: URL(string: "https://example.com/audio")!).timestampGranularities == nil)
    }

    @Test func bothOriginalTranscriptionResultSelectorsForwardWithoutInventingWords() {
        let plain: (String, JSONValue, [TranscriptionSegment], String?, Double?, [AIWarning], [String: JSONValue], AIRequestMetadata, AIResponseMetadata) -> TranscriptionResult = TranscriptionResult.init(text:rawValue:segments:language:durationInSeconds:warnings:providerMetadata:requestMetadata:responseMetadata:)
        let billed: (String, JSONValue, [TranscriptionSegment], String?, Double?, [AIWarning], [String: JSONValue], AIRequestMetadata, AIResponseMetadata, [String: JSONValue]?) -> TranscriptionResult = TranscriptionResult.init(text:rawValue:segments:language:durationInSeconds:warnings:providerMetadata:requestMetadata:responseMetadata:usage:)
        let segments = [TranscriptionSegment(text: "hello", startSecond: 0, endSecond: 1)]
        let request = AIRequestMetadata(body: ["body": true], headers: ["x": "yes"])
        let response = AIResponseMetadata(id: "id", modelID: "model")
        let warnings = [AIWarning(type: "other", message: "fixture")]
        let first = plain("hello", ["raw": true], segments, "en", 1, warnings, ["p": true], request, response)
        let second = billed("hello", ["raw": true], segments, "en", 1, warnings, ["p": true], request, response, ["seconds": 1])
        for value in [first, second] {
            #expect(value.text == "hello" && value.segments == segments && value.language == "en" && value.durationInSeconds == 1)
            #expect(value.rawValue == ["raw": true] && value.warnings == warnings && value.providerMetadata == ["p": true])
            #expect(value.requestMetadata == request && value.responseMetadata == response && value.words == nil)
        }
        #expect(first.usage == nil && second.usage == ["seconds": 1])
        #expect(TranscriptionResult(text: "new", rawValue: [:], words: segments).words == segments)
        #expect(TranscriptionResult(text: "new", rawValue: [:], usage: ["seconds": 0], words: []).words == [])
    }

    @Test func originalMetadataAndVideoSelectorsPreserveLegacyDefaults() {
        let metadata: (JSONValue?, [String: String]) -> AIRequestMetadata = AIRequestMetadata.init(body:headers:)
        let video: ([String], [String], String?, String?, JSONValue, [AIWarning], [String: JSONValue], AIRequestMetadata, AIResponseMetadata) -> VideoGenerationResult = VideoGenerationResult.init(urls:base64Videos:operationID:mediaType:rawValue:warnings:providerMetadata:requestMetadata:responseMetadata:)
        let request = metadata(["in": true], ["x": "yes"])
        #expect(request.url == nil && request.body == ["in": true] && request.headers == ["x": "yes"])
        let response = AIResponseMetadata(id: "id")
        let value = video(["https://example.com/video"], ["AQI="], "op", "video/mp4", ["raw": true], [], ["p": true], request, response)
        #expect(value.uploadedVideos.isEmpty && value.urls == ["https://example.com/video"] && value.base64Videos == ["AQI="])
        #expect(value.operationID == "op" && value.mediaType == "video/mp4" && value.providerMetadata == ["p": true])
        #expect(value.rawValue == ["raw": true] && value.requestMetadata == request && value.responseMetadata == response)
        #expect(AIRequestMetadata().url == nil)
        #expect(AIRequestMetadata(url: "https://example.com").url == "https://example.com")
        #expect(VideoGenerationResult(urls: [], rawValue: [:], uploadedVideos: [.init(mediaType: "video/mp4")]).uploadedVideos.count == 1)
    }

    @Test func originalNameMappingAndCapabilitiesSelectorsRetainNewOptionalPaths() {
        let mapping: ([String: String]) -> AIToolNameMapping = AIToolNameMapping.init(customToolNameToProviderToolName:)
        let old = mapping(["lookup": "search"])
        #expect(old.toProviderToolName("lookup") == "search" && old.toCustomToolName("search") == "lookup")
        #expect(AIToolNameMapping().toProviderToolName("pass") == "pass")
        let aliases = AIToolNameMapping(customToolNameToProviderToolName: ["declared": "search", "inline": "search"], preferredCustomToolNames: ["declared"])
        #expect(aliases.toCustomToolName("search") == "declared" && aliases.toProviderToolName("inline") == "search")
        let capabilities: (AIModelCapabilities.Language?, AIModelCapabilities.Embedding?, AIModelCapabilities.Image?, AIModelCapabilities.Transcription?, AIModelCapabilities.SpeechTranslation?, AIModelCapabilities.Speech?, AIModelCapabilities.Realtime?) -> AIModelCapabilities = AIModelCapabilities.init(language:embedding:image:transcription:speechTranslation:speech:realtime:)
        let realtime = AIModelCapabilities.Realtime(conversation: .turnBased, transports: [.websocket], connections: [.serverWebSocket])
        let value = capabilities(nil, nil, nil, nil, nil, .init(instructions: .supported), realtime)
        #expect(value.speech?.instructions == .supported && value.realtime == realtime)
        #expect(value.video == nil && value.reranking == nil && value.decision == nil)
        #expect(AIModelCapabilities() == AIModelCapabilities(video: nil, reranking: nil, decision: nil))
    }

    @Test func originalFullToolSelectorRetainsCallbacksAndRouting() async throws {
        typealias Execute = @Sendable (JSONValue) async throws -> JSONValue
        typealias ContextExecute = @Sendable (JSONValue, AIToolExecutionContext) async throws -> JSONValue
        typealias ModelOutput = @Sendable (AIToolModelOutputContext) async throws -> JSONValue
        let make: (String, String?, JSONValue, Bool, [String: JSONValue], [String: JSONValue], Bool?, [JSONValue], JSONValue?, AIToolNeedsApproval?, Bool, AIToolCallerDefinition?, AIToolInputStartCallback?, AIToolInputDeltaCallback?, AIToolInputAvailableCallback?, Execute?, ModelOutput?, ContextExecute?, @escaping Execute) -> AITool = AITool.init(name:description:parameters:dynamic:providerMetadata:providerOptions:strict:inputExamples:contextSchema:needsApproval:deferLoading:toolCaller:onInputStart:onInputDelta:onInputAvailable:refineArguments:toModelOutput:executeWithContext:execute:)
        let value = make("tool", "description", ["type": "object"], true, ["p": true], ["option": 1], false, [["x": 1]], ["type": "object"], nil, true, .provider(prepareProviderOptions: { $0 }), nil, nil, nil, { ["refined": $0] }, nil, { input, _ in ["context": input] }, { ["executed": $0] })
        #expect(value.name == "tool" && value.description == "description" && value.dynamic && value.deferLoading)
        #expect(value.strict == false && value.title == nil && value.metadata == nil)
        #expect(value.providerMetadata == ["p": true] && value.providerOptions == ["option": 1] && value.inputExamples == [["x": 1]])
        #expect(try await value.execute("x") == ["executed": "x"])
        #expect(try await value.executeWithContext("y", .init()) == ["context": "y"])
        #expect(try await value.refineArguments?("z") == ["refined": "z"])
        guard case .provider = value.toolCaller else { Issue.record("Tool caller was dropped"); return }
        let titled = AITool(name: "new", parameters: [:], title: "Title", metadata: ["label": true], execute: { $0 })
        #expect(titled.title == "Title" && titled.metadata == ["label": true])
        #expect(AITool(name: "old", parameters: [:], execute: { $0 }).title == nil)
    }

    @Test func originalConnectSelectorForwardsConversationWhileExplicitIntentRemainsAvailable() async throws {
        let connect: (any AIRealtimeModelV4, AIRealtimeSessionConfiguration, any AIDuplexWebSocketTransport, AIAbortSignal?) async throws -> AIRealtimeSession = AIRealtimeSession.connectServer(model:sessionConfiguration:webSocketTransport:abortSignal:)
        let state = SelectorConnectionState(), socket = SelectorSocketTransport()
        let model = SelectorRealtimeModel(state: state)
        let first = try await connect(model, .init(instructions: "old"), socket, nil)
        await first.close()
        let second = try await AIRealtimeSession.connectServer(model: model, webSocketTransport: socket, intent: .transcription)
        await second.close()
        #expect(await state.intents == [.conversation, .transcription])
        #expect(await socket.count == 2)
    }
}

private actor SelectorConnectionState {
    var intents: [AIRealtimeSessionIntent] = []
    func record(_ intent: AIRealtimeSessionIntent) { intents.append(intent) }
}
private struct SelectorRealtimeModel: AIRealtimeModelV4 {
    let specificationVersion = "v4", providerID = "selector", modelID = "test"
    let state: SelectorConnectionState
    var capabilities: AIRealtimeModelCapabilities? { .init(conversation: .turnBased, transports: [.webSocket], connections: [.serverWebSocket]) }
    func getResolvedServerWebSocketConfig(intent: AIRealtimeSessionIntent) async throws -> AIRealtimeWebSocketConfiguration { await state.record(intent); return .init(url: "wss://example.com") }
    func getWebSocketConfig(token: String, url: String) -> AIRealtimeWebSocketConfiguration { .init(url: url) }
    func serializeClientEvent(_ event: AIRealtimeClientEvent) async throws -> AIRealtimeWireMessage? { nil }
    func buildSessionConfig(_ config: AIRealtimeSessionConfiguration) -> JSONValue { [:] }
}
private actor SelectorSocketTransport: AIDuplexWebSocketTransport {
    var count = 0
    func connect(_ request: AIDuplexWebSocketRequest) async throws -> any AIDuplexWebSocketConnection { count += 1; return SelectorSocket() }
}
private final class SelectorSocket: AIDuplexWebSocketConnection, @unchecked Sendable {
    let events: AsyncThrowingStream<AIDuplexWebSocketEvent, Error>
    let continuation: AsyncThrowingStream<AIDuplexWebSocketEvent, Error>.Continuation
    init() { let pair = AsyncThrowingStream<AIDuplexWebSocketEvent, Error>.makeStream(); events = pair.stream; continuation = pair.continuation; continuation.yield(.opened(protocol: nil)) }
    func send(_ message: AIDuplexWebSocketMessage) async throws { }
    func close(code: Int, reason: Data?) async { continuation.finish() }
}
