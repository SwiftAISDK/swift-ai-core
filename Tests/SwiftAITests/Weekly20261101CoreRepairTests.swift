import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport

private actor RepairLog {
    var requests: [LanguageModelRequest] = []
    var signals: [Bool] = []
    var stopEvaluations = 0
    func request(_ value: LanguageModelRequest) -> Int { requests.append(value); return requests.count - 1 }
    func signal(_ matches: Bool) { signals.append(matches) }
    func stop() { stopEvaluations += 1 }
}

private struct RepairModel: LanguageModel {
    var providerID: String { "repair" }
    var modelID: String { "model" }
    var body: @Sendable (LanguageModelRequest) async throws -> TextGenerationResult
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult { try await body(request) }
}

private func repairCollect(_ stream: AsyncThrowingStream<LanguageStreamPart, Error>) async throws -> [LanguageStreamPart] {
    var parts: [LanguageStreamPart] = []
    for try await part in stream { parts.append(part) }
    return parts
}

private final class RepairCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private struct RejectedRepairSpeechModel: StreamingSpeechModel {
    let providerID = "repair", modelID = "speech"
    func speak(_ request: SpeechRequest) async throws -> SpeechResult { SpeechResult(audio: Data()) }
    func stream(_ request: StreamingSpeechRequest) async throws -> StreamingSpeechModelResult { throw AIStreamingSpeechError(provider: providerID, message: "setup rejected") }
}

@Suite("Weekly20261101 core compatibility repair")
struct Weekly20261101CoreRepairTests {
    @Test(arguments: [false, true])
    func approvalHistoryIsResolvedBeforePromptValidation(_ streaming: Bool) async throws {
        for steer in [false, true] {
            let log = RepairLog()
            let call = AIToolCall(id: "call", name: "lookup", arguments: "{}")
            let approval = AIToolApprovalRequest(id: "approval", toolName: "lookup", arguments: "{}", toolCallID: "call")
            let messages: [AIMessage] = [.user("hello"), .assistant(toolCalls: [call], toolApprovalRequests: [approval]), .toolResponses(approvalResponses: [AIToolApprovalResponse(id: "approval", approved: true)])]
            let tool = AITool(name: "lookup", parameters: ["type": "object"]) { _ in "approved" }
            let model = RepairModel { request in _ = await log.request(request); return TextGenerationResult(text: "done", finishReason: "stop", rawValue: [:]) }
            let steering = steer ? AI.experimentalCreateSteering() : nil
            if streaming {
                let parts = try await repairCollect(AI.streamText(model: model, request: LanguageModelRequest(messages: messages), executableTools: [tool], maxSteps: 2, retryPolicy: .none, experimentalSteering: steering))
                #expect(parts.contains { if case let .toolResult(result) = $0 { return result.result == "approved" }; return false })
            } else {
                let result = try await AI.generateText(model: model, request: LanguageModelRequest(messages: messages), executableTools: [tool], maxSteps: 2, toolCallers: [:], retryPolicy: .none, experimentalSteering: steering)
                #expect(result.responseMessages.first?.role == .tool)
            }
            let request = try #require(await log.requests.first)
            #expect(request.messages.flatMap(\.content).contains { if case let .toolResult(result) = $0 { return result.result == "approved" }; return false })
            #expect(await log.requests.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func hallucinatedToolsRemainTypedErrorResults(_ streaming: Bool) async throws {
        for steer in [false, true] {
            let known = AITool(name: "lookup", parameters: ["type": "object"]) { _ in "unused" }
            let model = RepairModel { _ in TextGenerationResult(text: "", finishReason: "tool-calls", toolCalls: [AIToolCall(id: "missing", name: "hallucinated", arguments: "{}")], rawValue: [:]) }
            let steering = steer ? AI.experimentalCreateSteering() : nil
            let results: [AIToolResult]
            if streaming {
                let parts = try await repairCollect(AI.streamText(model: model, request: LanguageModelRequest(messages: [.user("hello")]), executableTools: [known], maxSteps: 1, retryPolicy: .none, experimentalSteering: steering))
                results = parts.compactMap { if case let .toolResult(result) = $0 { return result }; return nil }
            } else {
                results = try await AI.generateText(model: model, prompt: "hello", executableTools: [known], maxSteps: 1, retryPolicy: .none, experimentalSteering: steering).toolResults
            }
            let result = try #require(results.first)
            #expect(result.isError)
            #expect(result.result["value"]?.stringValue?.contains("No such tool: hallucinated") == true)
        }
    }

    @Test func unchangedAbortSignalIdentityReachesInputAndExecutionCallbacks() async throws {
        let controller = AIAbortController(), log = RepairLog()
        let tool = AITool(name: "lookup", parameters: ["type": "object"], onInputAvailable: { await log.signal($0.abortSignal === controller.signal) }, executeWithContext: { _, context in
            await log.signal(context.abortSignal === controller.signal); return "ok"
        }) { _ in "unused" }
        let model = RepairModel { _ in TextGenerationResult(text: "", finishReason: "tool-calls", toolCalls: [AIToolCall(id: "call", name: "lookup", arguments: "{}")], rawValue: [:]) }
        _ = try await AI.generateText(model: model, prompt: "hello", executableTools: [tool], maxSteps: 1, retryPolicy: .none, abortSignal: controller.signal)
        #expect(await log.signals == [true, true])
    }

    @Test func naturalCompletionDoesNotEvaluateContinuationStopConditions() async throws {
        let log = RepairLog()
        let tool = AITool(name: "lookup", parameters: ["type": "object"]) { _ in "unused" }
        let model = RepairModel { _ in TextGenerationResult(text: "finished", finishReason: "stop", rawValue: [:]) }
        _ = try await AI.generateText(model: model, prompt: "hello", executableTools: [tool], maxSteps: 1, stopWhen: [AIStopCondition { _ in await log.stop(); return true }], retryPolicy: .none)
        #expect(await log.stopEvaluations == 0)
    }

    @Test func objectStreamTimeoutRemainsAThrownError() async throws {
        let model = RepairModel { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return TextGenerationResult(text: "{}", rawValue: [:]) }
        do {
            for try await _ in AI.streamObject(model: model, prompt: "hello", as: JSONValue.self, timeoutNanoseconds: 10_000_000, retryPolicy: .none) {}
            Issue.record("Timeout must reject the consumer")
        } catch let error as AIError {
            #expect(error == .timeout(durationNanoseconds: 10_000_000))
        }
    }

    @Test func rejectedSpeechSetupCancelsInputBeforePublishingFailure() async throws {
        for _ in 0..<20 {
            let cancelled = RepairCounter()
            let input = AIStreamingTextInput(AsyncThrowingStream { c in c.yield(SpeechTextPart(text: "x")); c.finish() }, onConsumerCancel: { cancelled.add() })
            let result = try AI.experimentalStreamSpeech(model: RejectedRepairSpeechModel(), request: StreamingSpeechRequest(text: input))
            do { _ = try await result.usage; Issue.record("Expected setup rejection") }
            catch let error as AIStreamingSpeechError { #expect(error.message == "setup rejected") }
            #expect(cancelled.value == 1)
        }
    }

    @Test func timeoutCauseDetectionPreservesThrowingForWrappedErrors() {
        let timeout = AIError.timeout(durationNanoseconds: 1)
        let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: timeout])
        #expect(isCausedByAbort(wrapped))
        #expect(isTextStreamTimeout(wrapped))
        #expect(!isCancellationTelemetryError(timeout))
        #expect(!isCancellationTelemetryError(wrapped))
    }

}
