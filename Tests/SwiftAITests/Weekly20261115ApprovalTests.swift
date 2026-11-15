// ai@7.0.173, exact test ref 0e8e0543aeda7d4dd4ce6eade0d5b7d5a43644c1.
// Swift JSON schemas are immutable JSON values and expose no custom validator
// callback. A mutating refiner tests the same approved-operation invariant;
// the JavaScript custom-schema mutation itself is a platform-only exclusion.
import Foundation
import Testing
import SwiftAIProvider
import SwiftAIProviderUtilities
@testable import SwiftAI

@Suite("Weekly20261115Approval", .serialized)
struct Weekly20261115ApprovalTests {
    @Test func ordinaryCallsStillRefineAndValidateBeforeExecution() async throws {
        let executions = WeeklyApprovalExecutions()
        let tool = AITool(name: "record", parameters: ["type": "object", "properties": [
            "counter": ["type": "object", "properties": ["value": ["type": "number", "enum": [2]]], "required": ["value"]]
        ], "required": ["counter"]], refineArguments: incrementWeeklyCounter) { value in
            await executions.record(value); return "recorded"
        }
        let result = try await executeToolCalls([.init(id: "new-call", name: "record", arguments: "{\"counter\":{\"value\":1}}")],
            toolsByName: ["record": tool], request: .init(messages: []), toolApproval: nil)
        let executed = await executions.inputs
        #expect(executed == [["counter": ["value": 2]]])
        #expect(result.results.count == 1)
        #expect(result.results.first?.isError == false)
    }

    @Test func signedApprovalRejectsMutationAndPreservesOriginalApproval() async throws {
        let input: JSONValue = ["counter": ["value": 2]]
        let arguments = try decisionJSONText(input)
        let signature = signToolApproval(secret: "test-secret", approvalID: "approval-1", toolCallID: "call-1", toolName: "tool1", input: input)
        let approval = AICollectedToolApproval(
            approvalRequest: .init(id: "approval-1", toolName: "tool1", arguments: arguments, toolCallID: "call-1", providerMetadata: ["signature": .string(signature)]),
            approvalResponse: .init(id: "approval-1", approved: true), toolCall: .init(id: "call-1", name: "tool1", arguments: arguments))
        let originalApproval = approval
        let tool = AITool(name: "tool1", parameters: ["type": "object"], refineArguments: incrementWeeklyCounter) { _ in
            Issue.record("Invalid approval must not execute"); return "ok"
        }
        let result = try await validateApprovedToolApprovals(approvedToolApprovals: [approval], toolsByName: ["tool1": tool],
            request: .init(messages: []), toolApproval: nil, toolApprovalSecret: "test-secret")
        #expect(result.approvedToolApprovals.isEmpty)
        #expect(result.invalidToolApprovals.count == 1)
        let invalid = try #require(result.invalidToolApprovals.first)
        #expect(invalid.error.message.contains("does not match the validated schema output"))
        #expect(invalid.approval == originalApproval)
        #expect(approval == originalApproval)
        #expect(verifyToolApprovalSignature(secret: "test-secret", signature: signature, approvalID: "approval-1", toolCallID: "call-1", toolName: "tool1", input: input))
        #expect(!verifyToolApprovalSignature(secret: "test-secret", signature: signature, approvalID: "approval-1", toolCallID: "call-1", toolName: "tool1", input: ["counter": ["value": 3]]))
    }

    @Test(arguments: [false, true])
    func signedReplayExecutesExactlyTheApprovedCounter(_ hasSchemaInput: Bool) async throws {
        let input: JSONValue = ["counter": ["value": 2]], arguments = try decisionJSONText(input)
        let signature = signToolApproval(secret: "test-secret", approvalID: "approval", toolCallID: "call", toolName: "record", input: input)
        let history: [AIMessage] = [
            .assistant(toolCalls: [.init(id: "call", name: "record", arguments: arguments)], toolApprovalRequests: [
                .init(id: "approval", toolName: "record", arguments: arguments, toolCallID: "call",
                      inputSchemaInput: hasSchemaInput ? ["counter": ["value": 1]] : nil, providerMetadata: ["signature": .string(signature)])]),
            .toolResponses(approvalResponses: [.init(id: "approval", approved: true)])
        ]
        let original = history, executions = WeeklyApprovalExecutions()
        let tool = AITool(name: "record", parameters: ["type": "object"], refineArguments: incrementWeeklyCounter) { value in
            await executions.record(value); return "recorded"
        }
        let result = try await executeHistoricalToolApprovals(request: .init(messages: history), toolsByName: ["record": tool],
                                                             toolApproval: { _ in .userApproval }, toolApprovalSecret: "test-secret")
        let executed = await executions.inputs
        #expect(executed == (hasSchemaInput ? [input] : []))
        #expect(history == original)
        #expect(result.toolResults.count == 1)
        let toolResult = try #require(result.toolResults.first)
        #expect(toolResult.toolCallID == "call")
        #expect(toolResult.toolName == "record")
        if hasSchemaInput {
            #expect(!toolResult.isError)
            #expect(toolResult.result == "recorded")
        } else {
            #expect(toolResult.isError)
            #expect(toolResult.result["type"] == "error-text")
            #expect(toolResult.result["value"]?.stringValue?.contains("does not match the validated schema output") == true)
        }
    }
}

private func incrementWeeklyCounter(_ input: JSONValue) async throws -> JSONValue {
    var object = try #require(input.objectValue), counter = try #require(object["counter"]?.objectValue)
    let value = try #require(counter["value"]?.doubleValue)
    counter["value"] = .number(value + 1)
    object["counter"] = .object(counter)
    return .object(object)
}

private actor WeeklyApprovalExecutions {
    var inputs: [JSONValue] = []
    func record(_ input: JSONValue) { inputs.append(input) }
}
