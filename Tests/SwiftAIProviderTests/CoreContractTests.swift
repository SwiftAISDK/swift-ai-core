import Foundation
import Testing
import SwiftAIProvider


@Test func languageModelRequestCarriesV4CallOptions() {
    let request = LanguageModelRequest(
        messages: [.user("hello")],
        temperature: 0.2,
        topP: 0.9,
        topK: 40,
        presencePenalty: 0.1,
        frequencyPenalty: 0.3,
        seed: 123,
        maxOutputTokens: 256,
        stopSequences: ["END"],
        responseFormat: .json(schema: .object(["type": .string("object")]), name: "Answer", description: "Structured answer"),
        reasoning: "high",
        tools: ["lookup": .object(["type": .string("function")])],
        toolChoice: .object(["type": .string("auto")]),
        includeRawChunks: true,
        providerOptions: ["openai": .object(["parallelToolCalls": .bool(false)])],
        extraBody: ["user": .string("user-1")],
        headers: ["x-test": "1"]
    )

    #expect(request.topK == 40)
    #expect(request.presencePenalty == 0.1)
    #expect(request.frequencyPenalty == 0.3)
    #expect(request.seed == 123)
    #expect(request.responseFormat == .json(schema: .object(["type": .string("object")]), name: "Answer", description: "Structured answer"))
    #expect(request.reasoning == "high")
    #expect(request.toolChoice?["type"]?.stringValue == "auto")
    #expect(request.includeRawChunks)
    #expect(request.providerOptions["openai"]?["parallelToolCalls"]?.boolValue == false)
    #expect(request.extraBody["user"]?.stringValue == "user-1")
}


@Test func languageStreamPartRepresentsV4LifecycleMetadataAndToolParts() {
    let response = AIResponseMetadata(
        id: "resp-1",
        timestamp: Date(timeIntervalSince1970: 1_772_078_479),
        modelID: "model-1",
        headers: ["x-request-id": "req-1"],
        body: .object(["id": .string("resp-1")])
    )
    let toolResult = AIToolResult(
        toolCallID: "call-1",
        toolName: "lookup",
        result: .object(["ok": .bool(true)]),
        preliminary: true,
        dynamic: true,
        providerMetadata: ["provider": .object(["trace": .string("trace-1")])]
    )
    let approval = AIToolApprovalRequest(id: "approval-1", toolName: "lookup", arguments: "{\"q\":\"hi\"}")
    let file = AIStreamFile(id: "file-1", mediaType: "application/pdf", filename: "report.pdf")

    let parts: [LanguageStreamPart] = [
        .streamStart(warnings: [AIWarning(type: "unsupported", feature: "seed")]),
        .textStart(id: "text-1", providerMetadata: ["provider": .object(["block": .number(1)])]),
        .textDeltaPart(id: "text-1", delta: "hello"),
        .textEnd(id: "text-1"),
        .reasoningStart(id: "reasoning-1"),
        .reasoningDeltaPart(id: "reasoning-1", delta: "thinking"),
        .reasoningEnd(id: "reasoning-1"),
        .toolInputStart(id: "call-1", name: "lookup", providerExecuted: true, dynamic: true, title: "Lookup"),
        .toolInputDelta(id: "call-1", delta: "{\"q\""),
        .toolInputEnd(id: "call-1"),
        .toolResult(toolResult),
        .toolApprovalRequest(approval),
        .file(file),
        .reasoningFile(file),
        .custom(.object(["type": .string("provider-event")]), providerMetadata: ["provider": .object(["kind": .string("custom")])]),
        .responseMetadata(response),
        .error(message: "provider error", rawValue: .object(["code": .string("bad")]))
    ]

    #expect(parts.first == .streamStart(warnings: [AIWarning(type: "unsupported", feature: "seed")]))
    #expect(parts.contains(.toolResult(toolResult)))
    #expect(parts.contains(.toolApprovalRequest(approval)))
    #expect(parts.contains(.responseMetadata(response)))
    #expect(parts.contains(.error(message: "provider error", rawValue: .object(["code": .string("bad")]))))
}
