// ai@7.0.179, release ref 9b8c25e582bb2ca97e459ba3f8f6b325cb9dfb22.
// stream-text-steering-interrupt.test.ts and stream-text.test.ts.
import Testing
@testable import SwiftAI
import SwiftAIProvider

@Suite("Steering streamed lifecycle")
struct Weekly20261122StreamSteeringTests {
    @Test func closesOpenTextAndReasoningWithoutCompletingTheCancelledAttempt() async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let model = SteeringFixtureModel(stream: { request, stream in
            if await state.begin(request) == 1 {
                stream.yield(.streamStart(warnings: []))
                stream.yield(.reasoningStart(id: "0"))
                stream.yield(.textStart(id: "1"))
                try await waitForSteeringAbort(request)
            }
            for part in steeringTextParts() { stream.yield(part) }
        })
        let result = try await runSteeringFixture(
            model, streaming: true, steering: steering, telemetry: .init(integrations: [state]), trace: state, onPart: { part in
            if case .textStart("1", _) = part {
                await state.track(steering.steer(steeringCorrection, id: "steer-1", interrupt: true))
            }
        })
        // Swift exposes provider stream-start parts and logical step boundaries through telemetry.
        #expect(result.streamParts == [
            .streamStart(warnings: []), .reasoningStart(id: "0"), .textStart(id: "1"),
            .textEnd(id: "1"), .reasoningEnd(id: "0"),
            .steeringMessage(id: "steer-1", message: .user(steeringCorrection), stepNumber: 0)
        ] + steeringTextParts())
        #expect(result.steps.count == 1)
        #expect(result.steps.first?.content == [.text(steeringAnswer)])
        #expect(await state.events.filter { $0.kind == .stepStart }.count == 1)
        #expect(await state.events.filter { $0.kind == .stepEnd }.count == 1)
        #expect(await state.requests.count == 2)
        #expect(await steeringTestOutcomes(state) == [delivered("steer-1", steeringCorrection)])
    }

    @Test func replacementRequestAndWarningsBecomeTheStepMetadata() async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let cancelledWarning = AIWarning(type: "other", message: "cancelled call")
        let redoWarning = AIWarning(type: "other", message: "redo call")
        let model = SteeringFixtureModel(stream: { request, stream in
            if await state.begin(request) == 1 {
                stream.yield(.requestMetadata(.init(body: "cancelled request")))
                stream.yield(.streamStart(warnings: [cancelledWarning]))
                stream.yield(.textStart(id: "1"))
                try await waitForSteeringAbort(request)
            }
            stream.yield(.requestMetadata(.init(body: "redo request")))
            stream.yield(.streamStart(warnings: [redoWarning]))
            for part in steeringTextParts().dropFirst() { stream.yield(part) }
        })
        let result = try await runSteeringFixture(model, streaming: true, steering: steering, onPart: { part in
            if case .textStart("1", _) = part {
                await state.track(steering.steer(steeringCorrection, id: "correction", interrupt: true))
            }
        })
        let step = try #require(result.steps.first)
        #expect(await state.requests.count == 2)
        #expect(step.requestMetadata?.body == "redo request")
        #expect(step.warnings == [redoWarning])
        #expect(step.content == [.text(steeringAnswer)])
        #expect(await steeringTestOutcomes(state) == [delivered("correction", steeringCorrection)])
    }

    @Test func interruptionWhileRetryWaitsForProviderRedoesStep() async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let model = SteeringFixtureModel(stream: { request, stream in
            switch await state.begin(request) {
            case 1:
                stream.yield(.streamStart(warnings: []))
                stream.yield(.error(message: "overloaded", rawValue: ["statusCode": 503, "isRetryable": true]))
            case 2:
                await state.track(steering.steer(steeringCorrection, id: "retry", interrupt: true))
                try await waitForSteeringAbort(request)
            default:
                for part in steeringTextParts() { stream.yield(part) }
            }
        })
        let result = try await runSteeringFixture(model, streaming: true, steering: steering, streamRetries: 1, trace: state)
        let calls = await state.requests
        #expect(calls.count == 3)
        #expect(calls.dropFirst().first?.abortSignal?.isAborted == true)
        #expect(calls.last?.messages.last == .user(steeringCorrection))
        #expect(result.streamParts.allSatisfy { if case .error = $0 { false } else { true } })
        #expect(await state.errors.isEmpty)
        #expect(result.text == steeringAnswer)
        #expect(result.steps.count == 1)
        #expect(await steeringTestOutcomes(state) == [delivered("retry", steeringCorrection)])
    }

    @Test(arguments: [false, true])
    func visibleTextAndToolInputStartCloseTheInterruptWindow(_ toolInput: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let release = AIAbortController()
        let model = SteeringFixtureModel(stream: { request, stream in
            if await state.begin(request) == 1 {
                stream.yield(.streamStart(warnings: []))
                if toolInput {
                    stream.yield(.toolInputStart(id: "call-1", name: "weather"))
                } else {
                    stream.yield(.textStart(id: "1"))
                    stream.yield(.textDeltaPart(id: "1", delta: "It is "))
                }
                try? await delay(3_000, abortSignal: release.signal)
                try request.abortSignal?.throwIfAborted()
                if toolInput {
                    stream.yield(.toolInputEnd(id: "call-1"))
                } else {
                    stream.yield(.textDeltaPart(id: "1", delta: "sunny in Paris."))
                    stream.yield(.textEnd(id: "1"))
                }
                stream.yield(.finishMetadata(reason: "stop", usage: steeringUsage(10)))
            } else {
                for part in steeringTextParts() { stream.yield(part) }
            }
        })
        let tool = steeringWeatherTool { _ in Issue.record("An unfinished tool argument block must not invoke a tool"); return .null }
        let result = try await runSteeringFixture(model, streaming: true, steering: steering, tools: [tool], maxSteps: 3, stopWhen: [.isStepCount(3)], onPart: { part in
            switch part {
            case .toolInputStart("call-1", _, _, _, _, _), .textDeltaPart("1", "It is ", _):
                await state.track(steering.steer(steeringCorrection, id: "next", interrupt: true))
                release.abort()
            default:
                break
            }
        })
        #expect(await state.requests.first?.abortSignal?.isAborted == false)
        #expect(result.steps.count == 2)
        #expect(result.steps.first?.text == (toolInput ? "" : "It is sunny in Paris."))
        #expect(await steeringTestOutcomes(state) == [delivered("next", steeringCorrection, step: 1)])
    }

    @Test func preliminaryProviderToolOutputIsStreamedAndExcludedFromFinalContent() async throws {
        let partial = AIToolResult(toolCallID: "call-1", toolName: "image_generation", result: ["result": "partial-image"], preliminary: true)
        let final = AIToolResult(toolCallID: "call-1", toolName: "image_generation", result: ["result": "final-image"])
        let call = AIToolCall(id: "call-1", name: "image_generation", arguments: "{}", providerExecuted: true)
        let model = SteeringFixtureModel(stream: { _, stream in
            stream.yield(.toolCall(call))
            stream.yield(.toolResult(partial))
            stream.yield(.toolResult(final))
            stream.yield(.finishMetadata(reason: "stop", usage: steeringUsage(10)))
        })
        let request = LanguageModelRequest(messages: [.user("Generate an image")], tools: [
            "image_generation": ["type": "provider", "id": "test.image_generation", "args": [:]]
        ])
        let result = try await runSteeringFixture(model, streaming: true, steering: AI.experimentalCreateSteering(), request: request)
        let streamed = result.streamParts.compactMap { if case let .toolResult(value) = $0 { value } else { nil } }
        var providerPartial = partial
        providerPartial.providerExecuted = true
        var providerFinal = final
        providerFinal.providerExecuted = true
        #expect(streamed == [providerPartial, providerFinal])
        #expect(result.steps.first?.toolResults == [providerFinal])
        #expect(result.steps.first?.content == [.toolCall(call), .toolResult(providerFinal)])
    }
}
