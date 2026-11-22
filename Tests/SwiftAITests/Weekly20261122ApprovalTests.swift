// ai@7.0.179, release ref 9b8c25e582bb2ca97e459ba3f8f6b325cb9dfb22.
// execute-tools-from-stream.test.ts, generate-text.test.ts, and stream-text.test.ts.
import Testing
@testable import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities

@Suite("Tool approval policy signatures")
struct Weekly20261122ApprovalTests {
    @Test(arguments: [false, true], [AIToolApprovalStatus.userApproval, .approved()])
    func approvalRequestsThatPermitExecutionAreSigned(_ streaming: Bool, _ status: AIToolApprovalStatus) async throws {
        let trace = ApprovalTrace()
        let result = try await callApprovalTool(streaming: streaming, status: status, trace: trace)
        let request = try #require(result.approvalRequest)
        #expect(request.toolCallID == "call-1")
        #expect(request.isAutomatic == (status == .approved()))
        #expect(request.providerMetadata["signature"] == expectedApprovalSignature(request))
        #expect(await trace.executions == (status == .approved() ? [["value": "test"]] : []))
        if streaming {
            #expect(result.parts.contains(.toolApprovalRequest(request)))
        }
    }

    @Test(arguments: [false, true])
    func automaticDenialIsUnsignedAndDoesNotExecute(_ streaming: Bool) async throws {
        let trace = ApprovalTrace()
        let result = try await callApprovalTool(streaming: streaming, status: .denied(), trace: trace)
        let request = try #require(result.approvalRequest)
        #expect(request.toolCallID == "call-1")
        #expect(request.isAutomatic == true)
        #expect(request.providerMetadata["signature"] == nil)
        #expect(await trace.executions.isEmpty)
        #expect(result.text == "done")
        if streaming {
            #expect(result.parts.contains(.toolApprovalRequest(request)))
            #expect(result.parts.contains(.toolApprovalResponse(.init(id: request.id, approved: false))))
        }
    }

    @Test(arguments: [false, true])
    func unsignedDenialCannotBeReplayedAsAnApproval(_ streaming: Bool) async throws {
        let trace = ApprovalTrace()
        let denied = try await callApprovalTool(streaming: streaming, status: .denied(), trace: trace)
        let approval = try #require(denied.approvalRequest)
        let assistantMessage = try #require(denied.messages.first)
        let history: [AIMessage] = [.user("test"), assistantMessage, .toolResponses(approvalResponses: [
            .init(id: approval.id, approved: true)
        ])]
        let replayTrace = ApprovalTrace()
        let expected = AIInvalidToolApprovalSignatureError(approvalID: approval.id, toolCallID: "call-1", reason: "missing signature")
        await #expect(throws: expected) {
            try await callApprovalTool(streaming: streaming, status: .notApplicable, messages: history, trace: replayTrace)
        }
        #expect(await trace.executions.isEmpty)
        #expect(await replayTrace.executions.isEmpty)
        #expect(await replayTrace.requests.isEmpty)
        if streaming {
            #expect(await replayTrace.errors.count == 1)
            #expect(await (replayTrace.errors.first as? AIInvalidToolApprovalSignatureError) == expected)
        }
    }

    @Test(arguments: [false, true])
    func unsignedDenialCanContinueViaOrdinaryConversationHistory(_ streaming: Bool) async throws {
        let trace = ApprovalTrace()
        let denied = try await callApprovalTool(streaming: streaming, status: .denied(), trace: trace)
        let assistantMessage = try #require(denied.messages.first)
        let toolMessage = try #require(denied.messages.dropFirst().first)
        #expect(assistantMessage.role == .assistant)
        #expect(toolMessage.role == .tool)
        let denialResponses = toolMessage.content.compactMap { part in
            if case let .toolApprovalResponse(response) = part, !response.approved { response } else { nil }
        }
        #expect(denialResponses.count == 1)
        let continuedTrace = ApprovalTrace()
        let continued = try await callApprovalTool(streaming: streaming, status: .denied(), messages: [.user("test"), assistantMessage, toolMessage], trace: continuedTrace)
        #expect(continued.text == "done")
        #expect(await trace.executions.isEmpty)
        #expect(await continuedTrace.executions.isEmpty)
    }

    @Test(arguments: [AIToolApprovalStatus.userApproval, .approved(), .denied()])
    func toolExecutionEmitsTheExpectedSignatureForEachStatus(_ status: AIToolApprovalStatus) async throws {
        let trace = ApprovalTrace()
        let tool = approvalFixtureTool(trace)
        let result = try await executeToolCalls(
            [approvalFixtureCall], toolsByName: [tool.name: tool], request: .init(messages: []),
            toolApproval: { _ in status }, toolApprovalSecret: approvalFixtureSecret
        )
        let request = try #require(result.approvalRequests.first)
        #expect(request.id == "approval-call-1")
        #expect(request.toolCallID == "call-1")
        if status == .denied() {
            #expect(request.isAutomatic == true)
            #expect(request.providerMetadata["signature"] == nil)
        } else {
            #expect(request.providerMetadata["signature"] == expectedApprovalSignature(request))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func approvalCallbacksReceiveTheirOwnStepsMessageValues(_ streaming: Bool, _ prepare: Bool) async throws {
        let trace = ApprovalTrace()
        let state = ApprovalTrace()
        let preparedMessages = [AIMessage.user("prepared-input")]
        let prepareStep: AIPrepareStep? = prepare ? { @Sendable context in
            var request = context.request
            request.messages = preparedMessages
            return .init(request: request)
        } : nil
        let model = SteeringFixtureModel { request in
            let step = await state.begin(request)
            if step > 1 { return .init(text: "done", finishReason: "stop", rawValue: [:]) }
            let toolCalls = [1, 2].map {
                AIToolCall(id: "call-\(step)-\($0)", name: "tool1", arguments: """
                    { "value": "value" }
                    """)
            }
            return .init(text: "", finishReason: "tool-calls", toolCalls: toolCalls, rawValue: [:])
        }
        let request = LanguageModelRequest(messages: [.user("test-input")])
        _ = try await runApprovalFixture(
            model, streaming: streaming, request: request, tool: approvalFixtureTool(trace),
            approve: { context in
                await trace.approve(context)
                return .approved()
            }, trace: trace, prepareStep: prepareStep
        )
        let snapshots = await trace.approvalMessages
        let providerRequests = await state.requests
        #expect(snapshots.count == 4)
        #expect(providerRequests.count == 3)
        let first = try #require(snapshots["call-0-1"])
        let second = try #require(snapshots["call-1-1"])
        #expect(snapshots["call-0-2"] == first)
        #expect(snapshots["call-1-2"] == second)
        #expect(first == providerRequests.first?.messages)
        let normalizedSecond = try prepareLanguageModelCallOptions(.init(messages: second)).messages
        #expect(normalizedSecond == providerRequests.dropFirst().first?.messages)
        if prepare {
            #expect(first == preparedMessages)
            #expect(second == preparedMessages)
        } else {
            #expect(first == [.user("test-input")])
            #expect(second.map(\.role) == [.user, .assistant, .tool])
            #expect(second != first)
        }
    }
}

private let approvalFixtureSecret = "test-hmac-secret-do-not-use-in-production"
private let approvalFixtureCall = AIToolCall(id: "call-1", name: "tool1", arguments: """
    { "value": "test" }
    """)

private func expectedApprovalSignature(_ approval: AIToolApprovalRequest) -> JSONValue {
    .string(signToolApproval(secret: approvalFixtureSecret, approvalID: approval.id, toolCallID: "call-1", toolName: "tool1", input: ["value": "test"]))
}

private func approvalFixtureTool(_ trace: ApprovalTrace) -> AITool {
    AITool(name: "tool1", parameters: [
        "type": "object", "properties": ["value": ["type": "string"]], "required": ["value"]
    ]) { input in
        await trace.execute(input)
        return "result1"
    }
}

private actor ApprovalTrace {
    var requests: [LanguageModelRequest] = []
    var executions: [JSONValue] = []
    var errors: [any Error] = []
    var approvalMessages: [String: [AIMessage]] = [:]

    func begin(_ request: LanguageModelRequest) -> Int {
        defer { requests.append(request) }
        return requests.count
    }
    func execute(_ input: JSONValue) { executions.append(input) }
    func error(_ event: AIGenerationErrorEvent) { errors.append(event.error) }
    func approve(_ context: AIToolApprovalContext) { approvalMessages[context.toolCall.id] = context.request.messages }
}

private struct ApprovalFixtureResult {
    let text: String
    let messages: [AIMessage]
    let parts: [LanguageStreamPart]

    var approvalRequest: AIToolApprovalRequest? {
        messages.filter { $0.role == .assistant }.flatMap(\.content).compactMap {
            if case let .toolApprovalRequest(request) = $0 { request } else { nil }
        }.first
    }
}

private func callApprovalTool(
    streaming: Bool,
    status: AIToolApprovalStatus,
    messages: [AIMessage] = [.user("test")],
    trace: ApprovalTrace
) async throws -> ApprovalFixtureResult {
    let model = SteeringFixtureModel { request in
        if await trace.begin(request) == 0 {
            return .init(text: "", finishReason: "tool-calls", toolCalls: [approvalFixtureCall], rawValue: [:])
        }
        return .init(text: "done", finishReason: "stop", rawValue: [:])
    }
    return try await runApprovalFixture(
        model, streaming: streaming, request: .init(messages: messages), tool: approvalFixtureTool(trace),
        approve: { _ in status }, trace: trace
    )
}

private func runApprovalFixture(
    _ model: SteeringFixtureModel,
    streaming: Bool,
    request: LanguageModelRequest,
    tool: AITool,
    approve: @escaping AIToolApproval,
    trace: ApprovalTrace,
    prepareStep: AIPrepareStep? = nil
) async throws -> ApprovalFixtureResult {
    if streaming {
        let results = AISteeringStepResults()
        let stream = AISteeringContext.$streamResults.withValue(results) {
            AI.streamText(model: model, request: request, executableTools: [tool], maxSteps: 3,
                          stopWhen: [.isStepCount(3)], prepareStep: prepareStep, toolApproval: approve,
                          toolApprovalSecret: approvalFixtureSecret, retryPolicy: .none, onError: { await trace.error($0) })
        }
        var parts: [LanguageStreamPart] = []
        for try await part in stream { parts.append(part) }
        let messages = try await toResponseMessages(
            content: results.steps.flatMap(\.content).compactMap(\.responseMessagePart), toolsByName: [tool.name: tool]
        )
        return .init(text: results.steps.last?.text ?? "", messages: messages, parts: parts)
    }
    let result = try await AI.generateText(model: model, request: request, executableTools: [tool], maxSteps: 3,
                                          stopWhen: [.isStepCount(3)], prepareStep: prepareStep,
                                          toolApproval: approve, toolApprovalSecret: approvalFixtureSecret, retryPolicy: .none)
    return .init(text: result.text, messages: result.responseMessages, parts: [])
}
