import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport

private actor NovemberState {
    var requests: [LanguageModelRequest] = []
    var binary: [AudioTranscriptionRequest] = []
    var urls: [AudioURLTranscriptionRequest] = []
    var events: [Telemetry.Event] = []
    func request(_ value: LanguageModelRequest) -> Int { requests.append(value); return requests.count - 1 }
    func audio(_ value: AudioTranscriptionRequest) { binary.append(value) }
    func url(_ value: AudioURLTranscriptionRequest) { urls.append(value) }
    func event(_ value: Telemetry.Event) { events.append(value) }
}

private struct NovemberLanguage: LanguageModel {
    let providerID = "november"
    let modelID = "test"
    var generateBody: @Sendable (LanguageModelRequest) async throws -> TextGenerationResult
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult { try await generateBody(request) }
    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await generateBody(request)
                    continuation.yield(.requestMetadata(result.requestMetadata))
                    continuation.yield(.ping)
                    continuation.yield(.textDelta(result.text))
                    continuation.yield(.finish(reason: result.finishReason, usage: nil))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct NovemberTranscript: TranscriptionModel {
    let providerID = "november"
    let modelID = "test"
    let state: NovemberState
    var native = true
    func transcribe(_ request: AudioTranscriptionRequest) async throws -> TranscriptionResult {
        await state.audio(request)
        return .init(text: "binary", rawValue: [:], words: [.init(text: "binary", startSecond: 0, endSecond: 1)])
    }
    func transcribeFromURL(_ request: AudioURLTranscriptionRequest) async throws -> TranscriptionResult? {
        await state.url(request)
        return native ? .init(text: "native", rawValue: [:]) : nil
    }
}

private actor NovemberDownload: AITransport {
    var count = 0
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        count += 1
        #expect(request.headers["Authorization"] == nil)
        return .init(statusCode: 200, headers: ["content-type": " AuDiO/FlAc ; charset=binary"], body: Data([0x66, 0x4c, 0x61, 0x43]))
    }
    func sendValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPResponse { try await send(request) }
}

private struct NovemberVideo: VideoModel {
    let providerID = "november"
    let modelID = "test"
    func generateVideo(_ request: VideoGenerationRequest) async throws -> VideoGenerationResult {
        .init(urls: [], rawValue: [:], uploadedVideos: [.init(mediaType: "video/mp4")])
    }
}

private actor NovemberTelemetry: Telemetry.Integration {
    let state: NovemberState
    init(_ state: NovemberState) { self.state = state }
    func record(_ event: Telemetry.Event) async { await state.event(event) }
}

private func novemberCollect(_ stream: AsyncThrowingStream<LanguageStreamPart, Error>) async throws -> [LanguageStreamPart] {
    var parts: [LanguageStreamPart] = []
    for try await part in stream { parts.append(part) }
    return parts
}

@Suite("Weekly20261108 core published deltas")
struct Weekly20261108CoreTests {
    @Test(arguments: [false, true])
    func queuesOneMessageAfterEachCompleteTask(_ streaming: Bool) async throws {
        let state = NovemberState(), steering = AI.experimentalCreateSteering()
        let first = steering.queue("second", id: "2"), second = steering.queue("third", id: "3")
        #expect(first === steering.steer("duplicate", id: "2"))
        let model = NovemberLanguage { request in
            let index = await state.request(request)
            return .init(text: "answer-\(index)", finishReason: "stop", rawValue: [:])
        }
        if streaming {
            let parts = try await novemberCollect(AI.streamText(model: model, prompt: "first", maxSteps: 4, retryPolicy: .none, experimentalSteering: steering))
            let delivered = parts.compactMap { part -> String? in if case let .steeringMessage(id, _, _) = part { return id }; return nil }
            #expect(delivered == ["2", "3"])
        } else {
            let result = try await AI.generateText(model: model, prompt: "first", maxSteps: 4, retryPolicy: .none, experimentalSteering: steering)
            #expect(result.steps.map(\.experimentalSteeringMessages) == [[], [.user("second")], [.user("third")]])
            #expect(result.text == "answer-2")
        }
        #expect(await state.requests.count == 3)
        #expect(await first.value == .delivered(id: "2", message: .user("second"), stepNumber: 1))
        #expect(await second.value == .delivered(id: "3", message: .user("third"), stepNumber: 2))
    }

    @Test(arguments: ["length", "content-filter"])
    func truncationDoesNotStartAQueuedTask(_ reason: String) async throws {
        let state = NovemberState(), steering = AI.experimentalCreateSteering()
        let receipt = steering.queue("later", id: "later")
        let model = NovemberLanguage { request in
            _ = await state.request(request)
            return .init(text: "partial", finishReason: reason, rawValue: [:])
        }
        _ = try await AI.generateText(model: model, prompt: "first", maxSteps: 3, retryPolicy: .none, experimentalSteering: steering)
        #expect(await state.requests.count == 1)
        #expect(await receipt.value == .notDelivered(id: "later", message: .user("later"), reason: .finished))
    }

    @Test func immediateSteeringPrecedesQueuedTasks() async throws {
        let state = NovemberState(), steering = AI.experimentalCreateSteering()
        _ = steering.queue("queued")
        let model = NovemberLanguage { request in
            let index = await state.request(request)
            if index == 0 { _ = steering.steer("immediate") }
            return .init(text: "answer", finishReason: "stop", rawValue: [:])
        }
        _ = try await AI.generateText(model: model, prompt: "first", maxSteps: 4, retryPolicy: .none, experimentalSteering: steering)
        let requests = await state.requests
        #expect(requests[1].messages.last == .user("immediate"))
        #expect(requests[2].messages.last == .user("queued"))
    }

    @Test(arguments: [false, true])
    func requestURLsExposeOnlyOrigins(_ streaming: Bool) async throws {
        let model = NovemberLanguage { _ in .init(text: "ok", finishReason: "stop", rawValue: [:], requestMetadata: .init(body: ["ok": true], url: "https://user:secret@example.com:443/v1/responses?key=secret#token")) }
        if streaming {
            let parts = try await novemberCollect(AI.streamText(model: model, prompt: "hi", retryPolicy: .none))
            #expect(parts.contains(.requestMetadata(.init(body: ["ok": true], url: "https://example.com"))))
        } else {
            let result = try await AI.generateText(model: model, prompt: "hi", retryPolicy: .none)
            #expect(result.requestMetadata.url == "https://example.com")
            #expect(result.requestMetadata.body == ["ok": true])
        }
        #expect(requestOrigin("file:///secret") == nil)
        #expect(requestOrigin("not a URL") == nil)
        #expect(requestOrigin("http://example.com:8080/path") == "http://example.com:8080")
    }

    @Test func nativeURLTranscriptionDoesNotDownloadOrLeakProviderHeaders() async throws {
        let state = NovemberState()
        let request = AudioURLTranscriptionRequest(audio: URL(string: "https://audio.example/clip.wav")!, timestampGranularities: [.word], headers: ["Authorization": "secret"])
        let result = try await AI.transcribe(model: NovemberTranscript(state: state), request: request, retryPolicy: .none)
        #expect(result.text == "native")
        #expect(await state.binary.isEmpty)
        #expect(await state.urls.first?.timestampGranularities == [.word])
    }

    @Test(arguments: [false, true])
    func explicitDownloadForcesBinaryAndNormalizesMediaType(_ native: Bool) async throws {
        let state = NovemberState()
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45])
        let result = try await AI.transcribe(model: NovemberTranscript(state: state, native: native), request: .init(audio: URL(string: "https://audio.example/clip")!, timestampGranularities: [.word, .segment]), download: { _, _ in
            .init(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: wav)
        }, retryPolicy: .none)
        #expect(result.text == "binary")
        #expect(result.words?.first?.text == "binary")
        #expect(await state.urls.isEmpty)
        #expect(await state.binary.first?.mimeType == "audio/wav")
        #expect(await state.binary.first?.timestampGranularities == [.word, .segment])
    }

    @Test func hiddenInputsRedactRawPayloadAndErrorsWithoutMutatingResult() async throws {
        let state = NovemberState()
        let model = NovemberLanguage { _ in .init(text: "answer", providerMetadata: ["secret": "raw"], rawValue: ["private": true], requestMetadata: .init(body: ["prompt": "secret"])) }
        let result = try await AI.generateText(model: model, prompt: "private", retryPolicy: .none, telemetry: .init(includesInput: false, integrations: [NovemberTelemetry(state)]))
        #expect(result.text == "answer")
        #expect(result.providerMetadata == ["secret": "raw"])
        let events = await state.events
        #expect(events.allSatisfy { $0.input == nil && $0.providerMetadata.isEmpty && $0.responseMetadata.body == nil })
        let end = try #require(events.last)
        #expect(end.output?["rawValue"] == nil)
        #expect(end.output?["requestMetadata"]?["body"] == nil)
    }

    @Test func emptyTextWithMetadataSurvivesResponseReplay() async throws {
        let messages = try await toResponseMessages(content: [.text(""), .text("", providerMetadata: ["anthropic": ["signature": "kept"]])])
        #expect(messages.first?.content == [.text("", providerMetadata: ["anthropic": ["signature": "kept"]])])
    }

    @Test func nativeURLDeclineFallsBackWithoutForwardingProviderCredentials() async throws {
        let state = NovemberState(), download = NovemberDownload()
        let result = try await AI.transcribe(model: NovemberTranscript(state: state, native: false), request: .init(audio: URL(string: "https://audio.example/clip")!, timestampGranularities: [.segment], headers: ["Authorization": "provider-secret"]), downloadTransport: download, retryPolicy: .none)
        #expect(result.text == "binary")
        #expect(await state.urls.count == 1)
        #expect(await download.count == 1)
        #expect(await state.binary.first?.mimeType == "audio/flac")
        #expect(await state.binary.first?.headers == ["Authorization": "provider-secret"])
    }

    @Test func uploadOnlyVideosAreSuccessfulWithoutDownloadableOutput() async throws {
        let result = try await AI.generateVideo(model: NovemberVideo(), request: .init(prompt: "clip"), retryPolicy: .none)
        #expect(result.urls.isEmpty && result.base64Videos.isEmpty)
        #expect(result.uploadedVideos == [.init(mediaType: "video/mp4")])
    }

    @Test(arguments: [false, true])
    func approvalPolicyUsesCurrentDefinitionMetadata(_ dynamic: Bool) async throws {
        let tool = AITool(name: "lookup", parameters: ["type": "object"], dynamic: dynamic, title: "Trusted title", metadata: ["requiresAdmin": true]) { _ in "ok" }
        var call = AIToolCall(id: "call", name: "lookup", arguments: "{}", dynamic: !dynamic, title: "Spoofed title")
        call.toolMetadata = ["requiresAdmin": false]
        let original = AICollectedToolApproval(approvalRequest: .init(id: "approval", toolName: "lookup", arguments: "{}", toolCallID: "call"), approvalResponse: .init(id: "approval", approved: true), toolCall: call)
        let result = try await validateApprovedToolApprovals(approvedToolApprovals: [original], toolsByName: ["lookup": tool], request: .init(messages: [.user("lookup")]), toolApproval: { context in
            #expect(context.toolCall.toolMetadata == ["requiresAdmin": true])
            #expect(context.toolCall.dynamic == dynamic)
            #expect(context.toolCall.title == "Trusted title")
            return .denied(reason: "Admin required")
        })
        #expect(result.approvedToolApprovals.isEmpty)
        #expect(result.deniedToolApprovals.first?.approvalResponse.reason == "Admin required")
        #expect(original.toolCall.title == "Spoofed title")
    }

    @Test func decisionBoxMayOmitInstructions() throws {
        try validateDecisionInput(state: .text("screen"), questions: ["target": .box()])
        #expect(throws: AIError.self) { try validateEvaluationInput(state: "screen", questions: ["target": .box()]) }
    }

    @Test func queuedMessageWaitsForToolTaskToFinish() async throws {
        let state = NovemberState(), steering = AI.experimentalCreateSteering()
        let receipt = steering.queue("next task", id: "queued")
        let model = NovemberLanguage { request in
            let index = await state.request(request)
            if index == 0 { return .init(text: "", finishReason: "tool-calls", toolCalls: [.init(id: "call", name: "lookup", arguments: "{}")], rawValue: [:]) }
            return .init(text: "answer", finishReason: "stop", rawValue: [:])
        }
        let tool = AITool(name: "lookup", parameters: ["type": "object"]) { _ in "found" }
        _ = try await AI.generateText(model: model, prompt: "first", executableTools: [tool], maxSteps: 5, retryPolicy: .none, experimentalSteering: steering)
        let requests = await state.requests
        #expect(requests.count == 3)
        #expect(!requests[1].messages.contains(.user("next task")))
        #expect(requests[2].messages.last == .user("next task"))
        #expect(await receipt.value == .delivered(id: "queued", message: .user("next task"), stepNumber: 2))
    }

    @Test func objectGenerationAlsoSanitizesRequestOrigins() async throws {
        let model = NovemberLanguage { _ in .init(text: "{\"answer\":\"ok\"}", finishReason: "stop", rawValue: [:], requestMetadata: .init(url: "https://user:secret@example.com/generate?key=secret")) }
        let result = try await AI.generateObject(model: model, prompt: "answer", as: [String: String].self, retryPolicy: .none)
        #expect(result.textResult.requestMetadata.url == "https://example.com")
        var streamed: ObjectGenerationResult<[String: String]>?
        for try await part in AI.streamObject(model: model, prompt: "answer", as: [String: String].self, retryPolicy: .none) {
            if case let .object(result) = part { streamed = result }
        }
        #expect(streamed?.textResult.requestMetadata.url == "https://example.com")
    }

    @Test func telemetryKeepsSafeOriginWhenContentRecordingIsDisabled() async throws {
        let state = NovemberState()
        let model = NovemberLanguage { _ in .init(text: "answer", rawValue: [:], requestMetadata: .init(url: "https://user:secret@example.com/v1?secret")) }
        _ = try await AI.generateText(model: model, prompt: "private", retryPolicy: .none, telemetry: .init(includesInput: false, includesOutput: false, integrations: [NovemberTelemetry(state)]))
        let end = try #require(await state.events.last)
        #expect(end.input == nil && end.output == nil)
        #expect(end.requestURL == "https://example.com")
    }
}
