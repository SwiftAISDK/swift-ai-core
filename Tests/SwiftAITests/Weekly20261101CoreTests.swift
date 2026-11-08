import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider
import SwiftAITransport

private actor WeeklyCoreState {
    var requests: [LanguageModelRequest] = []
    var errors: [AIGenerateTextStepErrorEvent] = []
    var aborts: [AIStreamTextAbortEvent] = []
    var callbackErrors: [String] = []
    var steps: [AIPrepareStepContext] = []
    func request(_ value: LanguageModelRequest) -> Int { requests.append(value); return requests.count - 1 }
    func error(_ value: AIGenerateTextStepErrorEvent) { errors.append(value) }
    func abort(_ value: AIStreamTextAbortEvent) { aborts.append(value) }
    func callbackError(_ value: any Error) { callbackErrors.append(String(describing: value)) }
    func step(_ value: AIPrepareStepContext) { steps.append(value) }
}

private struct WeeklyCoreModel: LanguageModel {
    var providerID: String { "weekly" }
    var modelID: String { "model" }
    var generateBody: @Sendable (LanguageModelRequest) async throws -> TextGenerationResult
    var streamBody: (@Sendable (LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error>)? = nil
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult { try await generateBody(request) }
    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        if let streamBody { return streamBody(request) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await generateBody(request)
                    if !result.text.isEmpty { continuation.yield(.textDelta(result.text)) }
                    for call in result.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.finish(reason: result.finishReason, usage: result.usage))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor WeeklyTelemetry: Telemetry.Integration {
    var events: [Telemetry.Event] = []
    var wrapperVersions: [String?] = []
    func executeLanguageModelCall<Output: Sendable>(_ context: Telemetry.LanguageModelCallContext<Output>) async throws -> Output { wrapperVersions.append(context.aiVersion); return try await context.execute() }
    func executeTool<Output: Sendable>(_ context: Telemetry.ToolExecutionContext<Output>) async throws -> Output { wrapperVersions.append(context.aiVersion); return try await context.execute() }
    func record(_ event: Telemetry.Event) { events.append(event) }
}

private extension AIMessage {
    var text: String { content.compactMap { if case let .text(text, _) = $0 { return text }; return nil }.joined() }
}

private let weeklyFailure = AIError.invalidResponse(provider: "weekly", message: "failed")
private func weeklyText(_ text: String) -> TextGenerationResult { TextGenerationResult(text: text, finishReason: "stop", rawValue: [:]) }
private func weeklyParts(_ stream: AsyncThrowingStream<LanguageStreamPart, Error>) async throws -> [LanguageStreamPart] {
    var result: [LanguageStreamPart] = []
    for try await part in stream { result.append(part) }
    return result
}

@Suite("Weekly20261101 core upstream changes")
struct Weekly20261101CoreTests {
    @Test func negativeArrayPrefixRemainsValidPartialJSON() throws {
        for (input, expected) in [("[-", "[]"), ("[-1", "[-1]"), ("[1,-", "[1]"), ("{\"a\":[-", "{\"a\":[]}")] {
            #expect(fixJson(input) == expected)
            #expect(try secureJSONParse(fixJson(input)) != .null)
        }
    }

    @Test func steeringReceiptsDeduplicateAndNeverThrow() async throws {
        let steering = AI.experimentalCreateSteering()
        let receipt = steering.steer("first", id: "one")
        #expect(receipt === steering.steer("ignored", id: "one"))
        let model = WeeklyCoreModel { request in
            #expect(request.messages.map(\.text) == ["initial", "first"])
            return weeklyText("answer")
        }
        let result = try await AI.generateText(model: model, prompt: "initial", retryPolicy: .none, experimentalSteering: steering)
        #expect(await receipt.value == .delivered(id: "one", message: .user("first"), stepNumber: 0))
        #expect(result.steps[0].experimentalSteeringMessages == [.user("first")])
        let late = steering.steer("late", id: "late")
        #expect(await late.value == .notDelivered(id: "late", message: .user("late"), reason: .finished))
        await #expect(throws: AIError.self) { try await AI.generateText(model: model, prompt: "again", retryPolicy: .none, experimentalSteering: steering) }
    }

    @Test func steeringAppendsAcrossStepsAndRetainsOnlyAssistantResponseMessages() async throws {
        let state = WeeklyCoreState(), steering = AI.experimentalCreateSteering()
        let initial = steering.steer("before", id: "before")
        let model = WeeklyCoreModel { request in
            let index = await state.request(request)
            if index == 0 { _ = steering.steer("during", id: "during") }
            return weeklyText(index == 0 ? "first answer" : "final answer")
        }
        let result = try await AI.generateText(model: model, prompt: "initial", maxSteps: 3, prepareStep: { context in
            await state.step(context); return AIPrepareStepResult()
        }, retryPolicy: .none, experimentalSteering: steering)
        #expect(await initial.value == .delivered(id: "before", message: .user("before"), stepNumber: 0))
        #expect(result.text == "final answer")
        #expect(result.steps.count == 2)
        #expect(result.steps.map(\.experimentalSteeringMessages) == [[.user("before")], [.user("during")]])
        #expect(result.responseMessages.map(\.role) == [.assistant, .assistant])
        let requests = await state.requests
        #expect(requests[1].messages.map(\.text) == ["initial", "before", "first answer", "during"])
        let contexts = await state.steps
        #expect(contexts[1].experimentalSteeringMessages == [.user("during")])
        #expect(contexts[1].initialRequest.messages == [.user("initial")])
        #expect(contexts[1].steps[0].experimentalSteeringMessages == [.user("before")])
    }

    @Test func prepareStepReplacementAndContentCopySettleReceipts() async throws {
        for keep in [true, false] {
            let steering = AI.experimentalCreateSteering(), receipt = steering.steer("steer", id: "id")
            let model = WeeklyCoreModel { _ in weeklyText("ok") }
            let result = try await AI.generateText(model: model, prompt: "initial", prepareStep: { context in
                var request = context.initialRequest
                if keep { request.messages.append(AIMessage(role: .user, content: [.text("steer")], providerMetadata: ["ignored": true])) }
                return AIPrepareStepResult(request: request)
            }, retryPolicy: .none, experimentalSteering: steering)
            #expect(await receipt.value == (keep ? .delivered(id: "id", message: .user("steer"), stepNumber: 0) : .notDelivered(id: "id", message: .user("steer"), reason: .removedByPrepareStep)))
            #expect(result.steps[0].experimentalSteeringMessages.count == (keep ? 1 : 0))
        }
    }

    @Test(arguments: [false, true])
    func stopConditionSettlesPendingSteeringWithoutAnotherRequest(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = WeeklyCoreState()
        let model = WeeklyCoreModel { request in
            _ = await state.request(request); _ = steering.steer("next", id: "next")
            return weeklyText("done")
        }
        if streaming { _ = try await weeklyParts(AI.streamText(model: model, prompt: "initial", maxSteps: 4, stopWhen: [.isStepCount(1)], retryPolicy: .none, experimentalSteering: steering)) }
        else { _ = try await AI.generateText(model: model, prompt: "initial", maxSteps: 4, stopWhen: [.isStepCount(1)], retryPolicy: .none, experimentalSteering: steering) }
        #expect(await state.requests.count == 1)
        #expect(await steering.steer("duplicate", id: "next").value == .notDelivered(id: "next", message: .user("next"), reason: .stopCondition))
    }

    @Test func nonExecutableToolSettlesPendingSteeringAsWaiting() async throws {
        let steering = AI.experimentalCreateSteering()
        let model = WeeklyCoreModel { _ in
            _ = steering.steer("next", id: "next")
            return TextGenerationResult(text: "", finishReason: "tool-calls", toolCalls: [AIToolCall(id: "call", name: "external", arguments: "{}")], rawValue: [:])
        }
        let result = try await AI.generateText(model: model, request: LanguageModelRequest(messages: [.user("initial")], tools: ["external": ["type": "function", "name": "external", "parameters": ["type": "object"]]]), executableTools: [], maxSteps: 3, toolCallers: [:], retryPolicy: .none, experimentalSteering: steering)
        #expect(result.steps.count == 1)
        #expect(await steering.steer("duplicate", id: "next").value == .notDelivered(id: "next", message: .user("next"), reason: .waitingForToolResults))
    }

    @Test func generationStepErrorHasCorrectStepAndTelemetryVersion() async throws {
        let state = WeeklyCoreState(), steering = AI.experimentalCreateSteering(), telemetry = WeeklyTelemetry()
        let model = WeeklyCoreModel { request in
            if await state.request(request) == 0 { _ = steering.steer("next"); return weeklyText("first") }
            throw weeklyFailure
        }
        await #expect(throws: AIError.self) {
            try await AI.generateText(model: model, prompt: "initial", maxSteps: 3, retryPolicy: .none, telemetry: Telemetry.Options(integrations: [telemetry]), experimentalSteering: steering, onStepError: { event in await state.error(event) })
        }
        let errors = await state.errors
        #expect(errors.count == 1 && errors.first?.stepNumber == 1)
        #expect(errors.first?.providerID == "weekly")
        #expect(errors.first?.error as? AIError == weeklyFailure)
        let events = await telemetry.events
        #expect(events.allSatisfy { $0.aiVersion == "7.0.165" })
        #expect(events.filter { $0.kind == .stepError }.count == 1)
        #expect(events.first { $0.kind == .stepError }?.input?["stepNumber"] == 1)
        #expect(events.last?.kind == .error)
    }

    @Test func successDoesNotReportStepError() async throws {
        let state = WeeklyCoreState(), model = WeeklyCoreModel { _ in weeklyText("ok") }
        _ = try await AI.generateText(model: model, prompt: "hello", retryPolicy: .none, onStepError: { await state.error($0) })
        #expect(await state.errors.isEmpty)
    }

    @Test func agentReportsFailureButPreservesOriginalErrorWhenCallbackThrows() async throws {
        let state = WeeklyCoreState(), model = WeeklyCoreModel { _ in throw weeklyFailure }
        let agent = AIToolLoopAgent(model: model, retryPolicy: .none, onStepError: { await state.error($0) }, onError: { event in await state.callbackError(event.error); throw CancellationError() })
        do { _ = try await agent.generate(prompt: "hello"); Issue.record("Expected original error") }
        catch { #expect(error as? AIError == weeklyFailure) }
        #expect(await state.callbackErrors.count == 1)
        #expect(await state.errors.count == 1)
    }

    @Test func agentAbortedGenerationReportsOnlyStepError() async throws {
        let state = WeeklyCoreState(), abort = AIAbortController()
        let model = WeeklyCoreModel { _ in abort.abort(reason: "custom"); throw weeklyFailure }
        let agent = AIToolLoopAgent(model: model, retryPolicy: .none, onStepError: { await state.error($0) }, onError: { await state.callbackError($0.error) }, onAbort: { await state.abort($0) })
        await #expect(throws: (any Error).self) { try await agent.generate(prompt: "hello", options: AIAgentCallOptions(abortSignal: abort.signal)) }
        #expect(await state.errors.count == 1)
        #expect(await state.callbackErrors.isEmpty)
        #expect(await state.aborts.isEmpty)
    }

    @Test func abortCauseDetectionIsBoundedAndRecognizesNativeTimeouts() {
        func wrapper(_ error: any Error) -> NSError { NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: error]) }
        #expect(isCausedByAbort(CancellationError()))
        #expect(isCausedByAbort(AIError.timeout(durationNanoseconds: 1)))
        #expect(isCausedByAbort(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        #expect(isCausedByAbort(wrapper(wrapper(wrapper(wrapper(CancellationError()))))))
        #expect(!isCausedByAbort(wrapper(wrapper(wrapper(wrapper(wrapper(CancellationError())))))))
        #expect(!isCausedByAbort(weeklyFailure))
    }

    @Test func streamSteeringContinuesAfterFinalAnswerAndExposesStepContext() async throws {
        let state = WeeklyCoreState(), steering = AI.experimentalCreateSteering()
        let model = WeeklyCoreModel { request in
            let index = await state.request(request)
            if index == 0 { _ = steering.steer("next", id: "next") }
            return weeklyText(index == 0 ? "first" : "second")
        }
        let parts = try await weeklyParts(AI.streamText(model: model, prompt: "hello", maxSteps: 3, prepareStep: { context in
            await state.step(context); return AIPrepareStepResult()
        }, retryPolicy: .none, experimentalSteering: steering))
        #expect(parts.compactMap { part -> String? in if case let .textDeltaPart(_, text, _) = part { return text }; return nil } == ["first", "second"])
        #expect(await steering.steer("duplicate", id: "next").value == .delivered(id: "next", message: .user("next"), stepNumber: 1))
        let contexts = await state.steps
        #expect(contexts[1].experimentalSteeringMessages == [.user("next")])
        #expect(contexts[1].steps[0].experimentalSteeringMessages.isEmpty)
    }

    @Test func streamReportsThrownAndEmptyStepErrorsOnce() async throws {
        for empty in [false, true] {
            let state = WeeklyCoreState(), telemetry = WeeklyTelemetry()
            let model = WeeklyCoreModel(generateBody: { _ in throw weeklyFailure }, streamBody: { _ in
                AsyncThrowingStream { continuation in
                    if empty { continuation.finish() } else { continuation.finish(throwing: weeklyFailure) }
                }
            })
            await #expect(throws: (any Error).self) {
                try await weeklyParts(AI.streamText(model: model, prompt: "hello", retryPolicy: .none, telemetry: Telemetry.Options(integrations: [telemetry]), onStepError: { await state.error($0) }, onError: { await state.callbackError($0.error) }))
            }
            #expect(await state.errors.count == 1)
            #expect(await state.callbackErrors.count == 1)
            let events = await telemetry.events
            #expect(events.filter { $0.kind == .stepError }.count == 1)
            #expect(events.suffix(2).map(\.kind) == [.stepError, .error])
        }
    }

    @Test func streamInBandErrorCompletesStepWithoutStepError() async throws {
        let state = WeeklyCoreState()
        let model = WeeklyCoreModel(generateBody: { _ in throw weeklyFailure }, streamBody: { _ in AsyncThrowingStream { c in c.yield(.error(message: "provider", rawValue: nil)); c.finish() } })
        let parts = try await weeklyParts(AI.streamText(model: model, prompt: "hello", retryPolicy: .none, onStepError: { await state.error($0) }, onError: { await state.callbackError($0.error) }))
        #expect(await state.errors.isEmpty)
        #expect(await state.callbackErrors.count == 1)
        #expect(parts.contains { if case .finishMetadata(reason: "error", usage: _, providerMetadata: _) = $0 { return true }; return false })
    }

    @Test func streamAbortSettlesPendingSteeringAndCallsAgentAbortOnly() async throws {
        let state = WeeklyCoreState(), steering = AI.experimentalCreateSteering(), abort = AIAbortController()
        let model = WeeklyCoreModel { request in
            _ = steering.steer("pending", id: "pending")
            abort.abort(reason: "custom stop")
            try request.abortSignal?.throwIfAborted()
            return weeklyText("unreachable")
        }
        let agent = AIToolLoopAgent(model: model, retryPolicy: .none, onStepError: { await state.error($0) }, onError: { await state.callbackError($0.error) }, onAbort: { await state.abort($0) })
        _ = try await weeklyParts(agent.stream(prompt: "hello", options: AIAgentCallOptions(abortSignal: abort.signal, experimentalSteering: steering)))
        #expect(await state.aborts.count == 1)
        #expect(await state.aborts.first?.reason == "custom stop")
        #expect(await state.errors.isEmpty)
        #expect(await state.callbackErrors.isEmpty)
        #expect(await steering.steer("duplicate", id: "pending").value == .notDelivered(id: "pending", message: .user("pending"), reason: .aborted))
    }

    @Test func telemetryAddsVersionWithoutMutatingCallerEvent() async {
        let recorder = WeeklyTelemetry()
        let dispatcher = TelemetryDispatcher(options: Telemetry.Options(integrations: [recorder]))
        var original = Telemetry.Event(kind: .stepError, callID: "id", operationID: "operation", providerID: "weekly", runtimeContext: ["secret": "value"])
        original.aiVersion = "caller"
        await dispatcher.record(original)
        #expect(original.aiVersion == "caller")
        #expect(await recorder.events.first?.aiVersion == "7.0.165")
    }

    @Test func typedOutputSupportsSteeringAndCallbacks() async throws {
        let steering = AI.experimentalCreateSteering(), receipt = steering.steer("please", id: "id")
        let model = WeeklyCoreModel { _ in weeklyText("{\"ok\":true}") }
        let result = try await AI.generateText(model: model, prompt: "JSON", output: Output.json(), retryPolicy: .none, experimentalSteering: steering)
        #expect(result.output == ["ok": true])
        #expect(await receipt.value == .delivered(id: "id", message: .user("please"), stepNumber: 0))
    }

    @Test func streamContinuationFailureReportsSecondStepOnce() async throws {
        let steering = AI.experimentalCreateSteering(), state = WeeklyCoreState(), recorder = WeeklyTelemetry()
        let model = WeeklyCoreModel { request in
            if await state.request(request) == 0 { _ = steering.steer("next"); return weeklyText("first") }
            throw weeklyFailure
        }
        await #expect(throws: (any Error).self) {
            try await weeklyParts(AI.streamText(model: model, prompt: "hello", maxSteps: 3, retryPolicy: .none, telemetry: Telemetry.Options(integrations: [recorder]), experimentalSteering: steering, onStepError: { await state.error($0) }, onError: { await state.callbackError($0.error) }))
        }
        #expect(await state.errors.map(\.stepNumber) == [1])
        #expect(await state.callbackErrors.count == 1)
        #expect(await recorder.events.filter { $0.kind == .stepError }.count == 1)
    }

    @Test func erroredFinishDoesNotContinueOrDeliverPendingSteering() async throws {
        let steering = AI.experimentalCreateSteering(), state = WeeklyCoreState()
        let model = WeeklyCoreModel { request in
            _ = await state.request(request)
            _ = steering.steer("pending", id: "pending")
            return TextGenerationResult(text: "", finishReason: "error", rawValue: [:])
        }
        _ = try await AI.generateText(model: model, prompt: "hello", maxSteps: 3, retryPolicy: .none, experimentalSteering: steering)
        #expect(await state.requests.count == 1)
        #expect(await steering.steer("duplicate", id: "pending").value == .notDelivered(id: "pending", message: .user("pending"), reason: .error))
    }

    @Test func generationTimeoutSettlesPendingSteeringAsAborted() async throws {
        let steering = AI.experimentalCreateSteering(), state = WeeklyCoreState()
        let model = WeeklyCoreModel { _ in
            _ = steering.steer("pending", id: "pending")
            throw AIError.timeout(durationNanoseconds: 1)
        }
        let agent = AIToolLoopAgent(model: model, retryPolicy: .none, onStepError: { await state.error($0) }, onError: { await state.callbackError($0.error) })
        await #expect(throws: AIError.self) { try await agent.generate(prompt: "hello", options: AIAgentCallOptions(experimentalSteering: steering)) }
        #expect(await state.errors.count == 1)
        #expect(await state.callbackErrors.isEmpty)
        #expect(await steering.steer("duplicate", id: "pending").value == .notDelivered(id: "pending", message: .user("pending"), reason: .aborted))
    }


    @Test(arguments: [false, true])
    func steeringContinuesAfterLengthFinish(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = WeeklyCoreState()
        let model = WeeklyCoreModel { request in
            let index = await state.request(request)
            if index == 0 { _ = steering.steer("next", id: "next") }
            return TextGenerationResult(text: index == 0 ? "first" : "last", finishReason: index == 0 ? "length" : "stop", rawValue: [:])
        }
        if streaming { _ = try await weeklyParts(AI.streamText(model: model, prompt: "hello", maxSteps: 3, retryPolicy: .none, experimentalSteering: steering)) }
        else { _ = try await AI.generateText(model: model, prompt: "hello", maxSteps: 3, retryPolicy: .none, experimentalSteering: steering) }
        #expect(await state.requests.count == 2)
        #expect(await steering.steer("duplicate", id: "next").value == .delivered(id: "next", message: .user("next"), stepNumber: 1))
    }

    @Test func telemetryWrappersReceiveEmittingVersion() async throws {
        let recorder = WeeklyTelemetry(), dispatcher = TelemetryDispatcher(options: Telemetry.Options(integrations: [recorder]))
        _ = try await dispatcher.executeLanguageModelCall(callID: "call", operationID: "operation", providerID: "weekly", modelID: "model") { "result" }
        _ = try await dispatcher.executeTool(callID: "call", toolCallID: "tool", toolName: "name") { "result" }
        #expect(await recorder.wrapperVersions == ["7.0.165", "7.0.165"])
    }


    @Test(arguments: [false, true])
    func interruptedStepDoesNotContinueSteering(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = WeeklyCoreState()
        let model = WeeklyCoreModel { request in
            _ = await state.request(request)
            _ = steering.steer("pending", id: "pending")
            return TextGenerationResult(text: "interrupted", finishReason: "interrupted", rawValue: [:])
        }
        if streaming { _ = try await weeklyParts(AI.streamText(model: model, prompt: "hello", maxSteps: 3, retryPolicy: .none, experimentalSteering: steering)) }
        else { _ = try await AI.generateText(model: model, prompt: "hello", maxSteps: 3, retryPolicy: .none, experimentalSteering: steering) }
        #expect(await state.requests.count == 1)
        let outcome = await steering.steer("duplicate", id: "pending").value
        #expect(outcome == .notDelivered(id: "pending", message: .user("pending"), reason: .finished))
    }

    @Test func partialStreamFailureReportsOneUnfinishedStep() async throws {
        let state = WeeklyCoreState()
        let model = WeeklyCoreModel(generateBody: { _ in weeklyText("unused") }, streamBody: { _ in AsyncThrowingStream { c in
            c.yield(.textDelta("partial")); c.finish(throwing: weeklyFailure)
        } })
        await #expect(throws: (any Error).self) {
            try await weeklyParts(AI.streamText(model: model, prompt: "hello", retryPolicy: .none, onStepError: { await state.error($0) }))
        }
        #expect(await state.errors.count == 1)
    }

    @Test func streamTimeoutCallsAbortAndExcludesStepError() async throws {
        let state = WeeklyCoreState(), steering = AI.experimentalCreateSteering()
        let model = WeeklyCoreModel { _ in
            _ = steering.steer("pending", id: "pending")
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return weeklyText("unreachable")
        }
        let agent = AIToolLoopAgent(model: model, streamTimeout: AIStreamTimeoutConfiguration(stepNanoseconds: 30_000_000), retryPolicy: .none, onStepError: { await state.error($0) }, onError: { await state.callbackError($0.error) }, onAbort: { await state.abort($0) })
        await #expect(throws: AIError.self) {
            try await weeklyParts(agent.stream(prompt: "hello", options: AIAgentCallOptions(experimentalSteering: steering)))
        }
        #expect(await state.aborts.count == 1)
        #expect(await state.errors.isEmpty)
        #expect(await state.callbackErrors.isEmpty)
        #expect(await steering.steer("duplicate", id: "pending").value == .notDelivered(id: "pending", message: .user("pending"), reason: .aborted))
    }


    @Test func nativeOptionsForwardSteeringAndStepErrors() async throws {
        let steering = AI.experimentalCreateSteering(), receipt = steering.steer("native", id: "native")
        let model = WeeklyCoreModel { _ in weeklyText("answer") }
        let result = try await model.generateText("hello", options: LanguageGenerationOptions(retryPolicy: .none, experimentalSteering: steering))
        #expect(result.steps[0].experimentalSteeringMessages == [.user("native")])
        #expect(await receipt.value == .delivered(id: "native", message: .user("native"), stepNumber: 0))
        let state = WeeklyCoreState(), failed = WeeklyCoreModel { _ in throw weeklyFailure }
        await #expect(throws: AIError.self) { try await failed.generateText("hello", options: LanguageGenerationOptions(retryPolicy: .none, onStepError: { await state.error($0) })) }
        #expect(await state.errors.count == 1)
    }


    @Test func invalidRequestDoesNotReportAnUnstartedStep() async throws {
        let state = WeeklyCoreState(), model = WeeklyCoreModel { _ in Issue.record("Must not call model"); return weeklyText("unused") }
        await #expect(throws: AIError.self) {
            try await weeklyParts(AI.streamText(model: model, prompt: "hello", maxOutputTokens: 0, retryPolicy: .none, onStepError: { await state.error($0) }))
        }
        #expect(await state.errors.isEmpty)
    }

    @Test func typedStreamingSteeringParsesOnlyFinalStep() async throws {
        let state = WeeklyCoreState(), steering = AI.experimentalCreateSteering()
        let model = WeeklyCoreModel { request in
            let index = await state.request(request)
            if index == 0 { _ = steering.steer("next") }
            return weeklyText(index == 0 ? "{\"value\":1}" : "{\"value\":2}")
        }
        var final: JSONValue?
        var finalSteps: [AIToolStep] = []
        for try await part in AI.streamText(model: model, request: LanguageModelRequest(messages: [.user("hello")]), output: Output.json(), executableTools: [], maxSteps: 3, retryPolicy: .none, experimentalSteering: steering) {
            if case let .output(result) = part { final = result.output; finalSteps = result.textResult.steps }
        }
        #expect(final == ["value": 2])
        #expect(finalSteps.count == 2)
        #expect(finalSteps.last?.experimentalSteeringMessages == [.user("next")])
    }


    @Test func nestedModelStreamKeepsItsOwnStepLedger() async throws {
        let outerSteering = AI.experimentalCreateSteering()
        let model = WeeklyCoreModel { _ in
            let innerSteering = AI.experimentalCreateSteering()
            let inner = WeeklyCoreModel { _ in weeklyText("nested") }
            _ = try await weeklyParts(AI.streamText(model: inner, request: LanguageModelRequest(messages: [.user("nested")]), executableTools: [], maxSteps: 1, retryPolicy: .none, experimentalSteering: innerSteering))
            return weeklyText("{\"value\":1}")
        }
        var steps: [AIToolStep] = []
        for try await part in AI.streamText(model: model, request: LanguageModelRequest(messages: [.user("hello")]), output: Output.json(), executableTools: [], maxSteps: 1, retryPolicy: .none, experimentalSteering: outerSteering) {
            if case let .output(result) = part { steps = result.textResult.steps }
        }
        #expect(steps.count == 1)
        #expect(steps.first?.text == "{\"value\":1}")
    }

}
