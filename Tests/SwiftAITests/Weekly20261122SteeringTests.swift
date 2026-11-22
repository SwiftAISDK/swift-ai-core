// ai@7.0.179, release ref 9b8c25e582bb2ca97e459ba3f8f6b325cb9dfb22.
// generate-text-steering-interrupt.test.ts and stream-text-steering-interrupt.test.ts.
import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider

@Suite("Steering model attempts")
struct Weekly20261122SteeringTests {
    @Test(arguments: [false, true])
    func interruptsWithoutOutputAndKeepsOneStep(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let model = SteeringFixtureModel { request in
            if await state.begin(request) == 1 {
                await state.track(steering.steer(steeringCorrection, id: "correction", interrupt: true))
                try await waitForSteeringAbort(request)
            }
            return steeringText()
        }
        let result = try await runSteeringFixture(model, streaming: streaming, steering: steering, trace: state)
        let calls = await state.requests
        #expect(calls.count == 2)
        #expect(calls.first?.abortSignal?.isAborted == true)
        #expect(calls.last?.messages.last == .user(steeringCorrection))
        #expect(result.steps.count == 1)
        #expect(result.text == steeringAnswer)
        #expect(result.steps.first?.experimentalSteeringMessages == [.user(steeringCorrection)])
        #expect(result.usage?.outputTokens == 10)
        #expect(await steeringTestOutcomes(state) == [delivered("correction", steeringCorrection)])
        #expect(await state.failedSteps.isEmpty)
        #expect(await state.errors.isEmpty)
        #expect(await state.aborts.isEmpty)
        if streaming {
            #expect(result.streamParts.filter { if case .finishMetadata = $0 { true } else { false } }.count == 1)
            #expect(result.streamParts.filter { if case .steeringMessage = $0 { true } else { false } }
                == [.steeringMessage(id: "correction", message: .user(steeringCorrection), stepNumber: 0)])
        }
    }

    @Test(arguments: [false, true])
    func replaysSuccessfullyDeliveredMessagesInOrder(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let earlier = steering.steer("Answer in Celsius.", id: "earlier")
        let model = SteeringFixtureModel { request in
            let call = await state.begin(request)
            if call <= 2 {
                let text = "Correction \(call)."
                await state.track(steering.steer(text, id: "correction-\(call)", interrupt: true))
                try await waitForSteeringAbort(request)
            }
            return steeringText("It is 22 degrees in Paris, Texas.")
        }
        let result = try await runSteeringFixture(model, streaming: streaming, steering: steering)
        let calls = await state.requests
        #expect(calls.count == 3)
        #expect(calls.prefix(2).allSatisfy { $0.abortSignal?.isAborted == true })
        #expect(calls.last?.messages == [.user(steeringQuestion), .user("Answer in Celsius."), .user("Correction 1."), .user("Correction 2.")])
        #expect(result.steps.count == 1)
        #expect(result.steps.first?.experimentalSteeringMessages == [.user("Answer in Celsius."), .user("Correction 1."), .user("Correction 2.")])
        #expect(await earlier.value == delivered("earlier", "Answer in Celsius."))
        #expect(await steeringTestOutcomes(state) == [delivered("correction-1", "Correction 1."), delivered("correction-2", "Correction 2.")])
        if streaming {
            #expect(result.streamParts.filter { if case .finishMetadata = $0 { true } else { false } }.count == 1)
            #expect(result.streamParts.compactMap { if case let .steeringMessage(id, _, _) = $0 { id } else { nil } }
                == ["earlier", "correction-1", "correction-2"])
        }
    }

    @Test(arguments: [false, true])
    func redoesLaterStepWithPriorToolResult(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let tool = steeringWeatherTool { input in await state.executeTool(input); return ["temperature": 72] }
        let model = SteeringFixtureModel { request in
            switch await state.begin(request) {
            case 1: return steeringWeatherResponse
            case 2:
                await state.track(steering.steer("Answer in Celsius.", id: "celsius", interrupt: true))
                try await waitForSteeringAbort(request)
            default: return steeringText("It is 22 degrees in Paris.")
            }
        }
        let result = try await runSteeringFixture(model, streaming: streaming, steering: steering, tools: [tool], maxSteps: 3, stopWhen: [.isStepCount(3)])
        let calls = await state.requests
        #expect(calls.count == 3)
        #expect(await state.toolInputs == [["city": "Paris"]])
        #expect(calls.last?.messages.map(\.role) == [.user, .assistant, .tool, .user])
        #expect(calls.last?.messages.last == .user("Answer in Celsius."))
        #expect(result.steps.count == 2)
        #expect(result.steps.first?.toolResults.first?.result == ["temperature": 72])
        #expect(result.text == "It is 22 degrees in Paris.")
        #expect(await steeringTestOutcomes(state) == [delivered("celsius", "Answer in Celsius.", step: 1)])
    }

    @Test(arguments: [false, true])
    func preparesAgainFromOriginalInstructionsAndContextAndRecordsOneStep(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let model = SteeringFixtureModel { request in
            if await state.begin(request) == 1 {
                await state.track(steering.steer(steeringCorrection, id: "correction", interrupt: true))
                try await waitForSteeringAbort(request)
            }
            return steeringText()
        }
        let request = LanguageModelRequest(
            messages: [.system("Answer briefly."), .user(steeringQuestion)],
            toolContexts: ["weather": ["unit": "fahrenheit"]], providerOptions: ["prepareStepCalls": 0]
        )
        let tool = steeringWeatherTool { _ in ["temperature": 72] }
        let result = try await runSteeringFixture(
            model, streaming: streaming, steering: steering, request: request, tools: [tool],
            prepare: { context in
                await state.prepare(context)
                var updated = context.request
                updated.messages[0] = .system("Answer briefly. Use Celsius.")
                updated.providerOptions["prepareStepCalls"] = .number((updated.providerOptions["prepareStepCalls"]?.doubleValue ?? 0) + 1)
                updated.toolContexts["weather"] = ["unit": "celsius"]
                return .init(request: updated)
            }, telemetry: .init(integrations: [state]), trace: state
        )
        let prepared = await state.prepared
        #expect(prepared.count == 2)
        #expect(prepared.map(\.stepNumber) == [0, 0])
        #expect(prepared.map(\.experimentalSteeringMessages) == [[], [.user(steeringCorrection)]])
        #expect(prepared.map { $0.request.messages.first } == [.system("Answer briefly."), .system("Answer briefly.")])
        #expect(prepared.map { $0.request.toolContexts } == [request.toolContexts, request.toolContexts])
        #expect(prepared.map { $0.request.providerOptions } == [request.providerOptions, request.providerOptions])
        let calls = await state.requests
        #expect(calls.last?.messages.first == .system("Answer briefly. Use Celsius."))
        #expect(calls.last?.providerOptions["prepareStepCalls"] == 1)
        #expect(calls.last?.toolContexts["weather"] == ["unit": "celsius"])
        let eventKinds = await state.events.map(\.kind)
        let steps = eventKinds.filter { $0 == .stepStart || $0 == .stepEnd }
        let failureKinds: [Telemetry.Event.Kind] = [.abort, .stepError, .error]
        #expect(await state.modelCalls == 2)
        #expect(steps == [.stepStart, .stepEnd])
        #expect(eventKinds.allSatisfy { !failureKinds.contains($0) })
        #expect(eventKinds.filter { $0 == .end }.count == 1)
        #expect(await state.failedSteps.isEmpty)
        #expect(result.steps.count == 1)
    }

    @Test(arguments: [false, true])
    func prepareCanRemoveInterruptingMessageFromRedo(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let model = SteeringFixtureModel { request in
            if await state.begin(request) == 1 {
                await state.track(steering.steer(steeringCorrection, id: "correction", interrupt: true))
                try await waitForSteeringAbort(request)
            }
            return steeringText("It is sunny in Paris.")
        }
        let result = try await runSteeringFixture(model, streaming: streaming, steering: steering, prepare: { context in
            var request = context.request
            request.messages.removeAll { $0 == .user(steeringCorrection) }
            return .init(request: request)
        })
        #expect(await state.requests.count == 2)
        #expect(await state.requests.last?.messages.last == .user(steeringQuestion))
        #expect(result.steps.first?.experimentalSteeringMessages.isEmpty == true)
        #expect(result.streamParts.allSatisfy { if case .steeringMessage = $0 { false } else { true } })
        #expect(await steeringTestOutcomes(state) == [.notDelivered(id: "correction", message: .user(steeringCorrection), reason: .removedByPrepareStep)])
    }

    @Test(arguments: [false, true])
    func interruptDuringPreparationRedoesTheAttempt(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let model = SteeringFixtureModel { request in
            if await state.begin(request) == 1 { try await waitForSteeringAbort(request) }
            return steeringText()
        }
        _ = try await runSteeringFixture(model, streaming: streaming, steering: steering, prepare: { _ in
            if await state.receipts.isEmpty {
                await state.track(steering.steer(steeringCorrection, id: "prepare", interrupt: true))
            }
            return nil
        })
        #expect(await state.requests.count == 2)
        #expect(await state.requests.last?.messages.last == .user(steeringCorrection))
        #expect(await steeringTestOutcomes(state) == [delivered("prepare", steeringCorrection)])
    }

    @Test(arguments: [false, true])
    func interruptBeforeRunIsDeliveredWithoutAborting(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let message = AIMessage.user(steeringCorrection)
        let receipt = steering.steer(content: message.content, id: "start", interrupt: true)
        let model = SteeringFixtureModel { request in
            _ = await state.begin(request)
            return steeringText("Sunny.")
        }
        _ = try await runSteeringFixture(model, streaming: streaming, steering: steering)
        #expect(await state.requests.count == 1)
        #expect(await state.requests.first?.abortSignal?.isAborted == false)
        #expect(await state.requests.first?.messages.last == message)
        #expect(await receipt.value == delivered("start", steeringCorrection))
    }

    @Test(arguments: [false, true])
    func interruptDuringToolExecutionWaitsForNextStep(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let tool = steeringWeatherTool { input in
            await state.executeTool(input)
            await state.track(steering.steer(steeringCorrection, id: "tool", interrupt: true))
            try await delay(5)
            return ["temperature": 72]
        }
        let model = SteeringFixtureModel { request in
            if await state.begin(request) == 1 { return steeringWeatherResponse }
            let text = request.messages.last?.content.compactMap { part in
                if case let .text(value, _) = part { value } else { nil }
            }.joined() ?? ""
            return steeringText("answer for \(text)")
        }
        let result = try await runSteeringFixture(model, streaming: streaming, steering: steering, tools: [tool], maxSteps: 3, stopWhen: [.isStepCount(3)])
        #expect(await state.toolInputs == [["city": "Paris"]])
        #expect(await state.requests.count == 2)
        #expect(await state.requests.first?.abortSignal?.isAborted == false)
        #expect(result.steps.first?.toolResults.first?.result == ["temperature": 72])
        #expect(result.text == "answer for \(steeringCorrection)")
        #expect(await steeringTestOutcomes(state) == [delivered("tool", steeringCorrection, step: 1)])
    }

    @Test(arguments: [false, true])
    func ordinarySteerKeepsTheFirstAttemptRunning(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let model = SteeringFixtureModel { request in
            if await state.begin(request) == 1 {
                await state.track(steering.steer(steeringCorrection, id: "regular"))
                try await delay(5)
                #expect(request.abortSignal?.isAborted == false)
                return steeringText("It is sunny in Paris.")
            }
            return steeringText()
        }
        let result = try await runSteeringFixture(model, streaming: streaming, steering: steering, maxSteps: 3, stopWhen: [.isStepCount(3)])
        #expect(await state.requests.count == 2)
        #expect(result.steps.map(\.text) == ["It is sunny in Paris.", steeringAnswer])
        #expect(await steeringTestOutcomes(state) == [delivered("regular", steeringCorrection, step: 1)])
    }

    @Test(arguments: [false, true])
    func callerAbortBeatsSteeringInterrupt(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let caller = AIAbortController()
        let model = SteeringFixtureModel { request in
            _ = await state.begin(request)
            let receipt = steering.steer(steeringCorrection, id: "correction", interrupt: true)
            caller.abort(reason: "stopped by user")
            await state.track(receipt)
            try await waitForSteeringAbort(request)
        }
        let request = LanguageModelRequest(messages: [.user(steeringQuestion)], abortSignal: caller.signal)
        if streaming {
            let result = try await runSteeringFixture(model, streaming: true, steering: steering, request: request, trace: state)
            #expect(result.steps.isEmpty)
            #expect(await state.aborts.count == 1)
            #expect(await state.aborts.first?.reason == "stopped by user")
            #expect(await state.errors.isEmpty)
        } else {
            await #expect(throws: AIAbortError(reason: "stopped by user")) {
                try await runSteeringFixture(model, streaming: false, steering: steering, request: request)
            }
        }
        #expect(await state.requests.count == 1)
        #expect(await steeringTestOutcomes(state) == [.notDelivered(id: "correction", message: .user(steeringCorrection), reason: .aborted)])
    }

    @Test(arguments: [false, true])
    func duplicateIDCannotInterruptAgain(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let model = SteeringFixtureModel { request in
            if await state.begin(request) == 1 {
                await state.track(steering.steer(steeringCorrection, id: "steer-1", interrupt: true))
                try await waitForSteeringAbort(request)
            }
            let repeated = steering.steer(steeringCorrection, id: "steer-1", interrupt: true)
            #expect(repeated === (await state.receipts.first))
            #expect(request.abortSignal?.isAborted == false)
            return steeringText()
        }
        let result = try await runSteeringFixture(model, streaming: streaming, steering: steering)
        #expect(await state.requests.count == 2)
        #expect(result.steps.count == 1)
        #expect(await steeringTestOutcomes(state) == [delivered("steer-1", steeringCorrection)])
    }

    @Test(arguments: [false, true])
    func callerAbortDuringReplacementPreparationDoesNotReportDelivery(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let caller = AIAbortController()
        let model = SteeringFixtureModel { request in
            _ = await state.begin(request)
            await state.track(steering.steer(steeringCorrection, id: "replacement", interrupt: true))
            try await waitForSteeringAbort(request)
        }
        let prepare: AIPrepareStep = { context in
            if !context.experimentalSteeringMessages.isEmpty { caller.abort(reason: "cancelled during prepareStep") }
            return nil
        }
        let request = LanguageModelRequest(messages: [.user(steeringQuestion)], abortSignal: caller.signal)
        if streaming {
            let result = try await runSteeringFixture(model, streaming: true, steering: steering, request: request, prepare: prepare, trace: state)
            #expect(result.steps.isEmpty)
            #expect(result.streamParts.isEmpty)
            #expect(await state.aborts.first?.reason == "cancelled during prepareStep")
        } else {
            await #expect(throws: AIAbortError(reason: "cancelled during prepareStep")) {
                try await runSteeringFixture(model, streaming: false, steering: steering, request: request, prepare: prepare)
            }
        }
        #expect(await state.requests.count == 1)
        #expect(await steeringTestOutcomes(state) == [.notDelivered(id: "replacement", message: .user(steeringCorrection), reason: .aborted)])
    }

    @Test(arguments: [false, true])
    func deadlineStaysArmedAcrossRedo(_ streaming: Bool) async throws {
        let steering = AI.experimentalCreateSteering(), state = SteeringTestTrace()
        let caller = AIAbortController()
        let model = SteeringFixtureModel { request in
            if await state.begin(request) == 1 {
                try await delay(120, abortSignal: request.abortSignal)
                _ = steering.steer(steeringCorrection, interrupt: true)
                try await waitForSteeringAbort(request)
            }
            // A 200ms deadline reset here would still be running after 110ms.
            try await delay(110, abortSignal: request.abortSignal)
            throw SteeringFixtureError.expectedAbort
        }
        let timer = streaming ? nil : setAbortTimeout(abortController: caller, label: "Caller", timeoutMilliseconds: 200)
        defer { timer?.cancel() }
        let request = LanguageModelRequest(messages: [.user(steeringQuestion)], abortSignal: streaming ? nil : caller.signal)
        do {
            _ = try await runSteeringFixture(model, streaming: streaming, steering: steering, request: request,
                                            timeout: .init(stepNanoseconds: 200_000_000), trace: state)
            Issue.record("Expected the original deadline to end the replacement call")
        } catch {
            if streaming {
                #expect(error as? AIError == .timeout(durationNanoseconds: 200_000_000))
                #expect(await state.aborts.count == 1)
                #expect(await state.aborts.first?.steps.isEmpty == true)
            } else {
                #expect((error as? AIAbortError)?.reason == "Caller timeout of 200ms exceeded")
            }
        }
        #expect(await state.requests.count == 2)
        #expect(await state.requests.last?.abortSignal?.reasonName == "TimeoutError")
        let failures = await state.failedSteps
        #expect(failures.count == (streaming ? 0 : 1))
        if !streaming { #expect(failures.first?.stepNumber == 0) }
        #expect(await state.errors.isEmpty)
    }
}

func delivered(_ id: String, _ text: String, step: Int = 0) -> AISteeringOutcome {
    .delivered(id: id, message: .user(text), stepNumber: step)
}
