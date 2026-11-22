import SwiftAI
import Testing

// ai@7.0.179, packages/ai/src/batch/{batch.test.ts,batch-types.test-d.ts}.
private struct BatchOutputValue: Decodable, Equatable, Sendable {
    let text: String
}

private let batchOutputSchema: JSONValue = [
    "type": "object",
    "properties": ["text": ["type": "string"]],
    "required": ["text"],
    "additionalProperties": false
]

private let batchOutput = Output.object(schema: batchOutputSchema, as: BatchOutputValue.self)
private let batchOutputReference = AIBatchReference(id: "batch-123", providerID: "mock-provider")
private let batchOutputUsage = TokenUsage(
    inputTokens: 3,
    outputTokens: 5,
    inputTokensNoCache: 2,
    inputTokensCacheRead: 1,
    outputTextTokens: 4,
    outputReasoningTokens: 1
)

@Test func batchOutputSendsResponseFormatWithEveryTextRequest() async throws {
    let provider = BatchOutputMockProvider()
    let imageRequest = ImageGenerationRequest(prompt: "a cat")

    let started = try await AI.startBatch(
        provider: provider,
        requests: [
            batchOutputRequest(id: "request-1"),
            batchOutputRequest(id: "request-2"),
            .image(ImageBatchRequest(id: "request-3", modelID: "mock-image-model-id", request: imageRequest))
        ],
        output: batchOutput
    )

    #expect(started.batch.reference == batchOutputReference)
    let calls = await provider.startCalls
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    try #require(call.requests.count == 3)
    for (index, request) in call.requests.prefix(2).enumerated() {
        guard case let .text(text) = request else {
            Issue.record("Expected text request")
            return
        }
        #expect(text.id == "request-\(index + 1)")
        #expect(text.modelID == "mock-model-id")
        #expect(text.request.messages == [.user("translate")])
        #expect(text.request.responseFormat == .json(schema: batchOutputSchema))
    }
    guard case let .image(image) = call.requests[2] else {
        Issue.record("Expected image request")
        return
    }
    #expect(image.id == "request-3")
    #expect(image.modelID == "mock-image-model-id")
    #expect(image.request.prompt == "a cat")
    #expect(image.request.extraBody["responseFormat"] == nil)
}

@Test func batchOutputOmitsResponseFormatWithoutSpecification() async throws {
    let provider = BatchOutputMockProvider()
    let start = AI.startBatch(provider:requests:providerOptions:headers:idempotencyKey:webhookURL:abortSignal:timeoutNanoseconds:)
    _ = try await start(provider, [batchOutputRequest(id: "request-1")], [:], [:], nil, nil, nil, nil)

    let calls = await provider.startCalls
    let request = try #require(calls.first?.requests.first)
    guard case let .text(text) = request else {
        Issue.record("Expected text request")
        return
    }
    #expect(text.request.responseFormat == nil)
}

@Test func batchOutputParsesAndValidatesSucceededText() async throws {
    let text = #"{"text":"hello"}"#
    let results = try await collectBatchOutput([batchOutputText("ok", text: text)])

    try #require(results.count == 1)
    let result = try requireBatchOutput(results[0], id: "ok")
    #expect(result.generation.text == text)
    let value: BatchOutputValue? = result.output
    let error: AIBatchError? = result.outputError
    #expect(value == BatchOutputValue(text: "hello"))
    #expect(error == nil)
    guard case let .success(typedValue) = result.parsedOutput else {
        Issue.record("Expected typed output")
        return
    }
    #expect(typedValue.text == "hello")
}

@Test func batchOutputReportsParseFailuresPerItemWithoutDroppingTextAndUsage() async throws {
    let results = try await collectBatchOutput([
        batchOutputText("not-json", text: "oops"),
        batchOutputText("wrong-shape", text: #"{"text":1}"#),
        batchOutputText("ok", text: #"{"text":"fine"}"#)
    ])

    try #require(results.count == 3)
    let malformed = try requireBatchOutput(results[0], id: "not-json")
    #expect(malformed.generation.text == "oops")
    var expectedUsage = batchOutputUsage
    expectedUsage.totalTokens = 8
    #expect(malformed.generation.usage == expectedUsage)
    #expect(malformed.output == nil)
    #expect(malformed.outputError == AIBatchError(
        message: "No object generated: could not parse the response.",
        type: "AI_NoObjectGeneratedError"
    ))

    let invalid = try requireBatchOutput(results[1], id: "wrong-shape")
    #expect(invalid.generation.text == #"{"text":1}"#)
    #expect(invalid.output == nil)
    #expect(invalid.outputError == AIBatchError(
        message: "No object generated: response did not match schema.",
        type: "AI_NoObjectGeneratedError"
    ))

    let valid = try requireBatchOutput(results[2], id: "ok")
    #expect(valid.output == BatchOutputValue(text: "fine"))
    #expect(valid.outputError == nil)
}

@Test func batchOutputPrefersStructuredOutputTextForJSON() async throws {
    let draft = #"draft {"text":"final"}"#
    let selected = #"{"text":"final"}"#
    let results = try await collectBatchOutput([
        batchOutputText("structured", text: draft, structuredOutputText: selected),
        batchOutputText("different", text: #"{"text":"draft"}"#, structuredOutputText: selected)
    ])

    try #require(results.count == 2)
    let result = try requireBatchOutput(results[0], id: "structured")
    #expect(result.generation.text == draft)
    #expect(result.generation.content == [.text(draft)])
    #expect(result.output == BatchOutputValue(text: "final"))
    let different = try requireBatchOutput(results[1], id: "different")
    #expect(different.generation.text == #"{"text":"draft"}"#)
    #expect(different.output == BatchOutputValue(text: "final"))
}

@Test func batchOutputReportsMissingOutputForToolCalls() async throws {
    let call = AIToolCall(id: "call-1", name: "weather", arguments: "{}")
    let results = try await collectBatchOutput([
        .text(.succeeded(id: "tool-call", result: TextGenerationResult(
            text: "",
            content: [.toolCall(call)],
            finishReason: "tool-calls",
            usage: batchOutputUsage,
            rawValue: ["stop_reason": "tool_use"]
        )))
    ])

    try #require(results.count == 1)
    let result = try requireBatchOutput(results[0], id: "tool-call")
    #expect(result.generation.content == [.toolCall(call)])
    #expect(result.generation.finishReason == "tool-calls")
    #expect(result.generation.rawFinishReason == "tool_use")
    #expect(result.output == nil)
    #expect(result.outputError == AIBatchError(message: "No output generated.", type: "AI_NoOutputGeneratedError"))
}

@Test func batchOutputLeavesFailedItemsAndUntypedResultsIntact() async throws {
    let failure = AIBatchError(message: "boom")
    let text = #"{"text":"x"}"#
    let provider = BatchOutputMockProvider(results: [
        .text(.failed(id: "failed", error: failure)),
        batchOutputText("plain", text: text)
    ])

    let withOutput = try AI.getBatchResults(provider: provider, batch: batchOutputReference, output: batchOutput, retryPolicy: .none)
    var parsedItems: [BatchOutputItemResult<BatchOutputValue>] = []
    for try await item in withOutput { parsedItems.append(item) }
    try #require(parsedItems.count == 2)
    guard case let .text(.failed(id, error, metadata)) = parsedItems[0] else {
        Issue.record("Expected original failed item")
        return
    }
    #expect(id == "failed")
    #expect(error == failure)
    #expect(metadata.isEmpty)

    let getResults = AI.getBatchResults(provider:batch:providerOptions:headers:abortSignal:timeoutNanoseconds:retryPolicy:)
    let withoutOutput = try getResults(provider, batchOutputReference, [:], [:], nil, nil, .none)
    var items: [BatchItemResult] = []
    for try await item in withoutOutput { items.append(item) }
    try #require(items.count == 2)
    guard case let .text(.succeeded(plainID, result)) = items[1] else {
        Issue.record("Expected untyped text result")
        return
    }
    #expect(plainID == "plain")
    #expect(result.text == text)
    let fields = Mirror(reflecting: result).children.compactMap(\.label)
    #expect(!fields.contains("output"))
    #expect(!fields.contains("outputError"))
}

@Test func batchOutputKeepsImageAndOtherTerminalItems() async throws {
    let metadata: [String: JSONValue] = ["mock": ["item": true]]
    let url = "https://example.com/a-cat.png"
    let results = try await collectBatchOutput([
        .image(.succeeded(id: "image", result: ImageGenerationResult(
            urls: [url], rawValue: .null, providerMetadata: metadata, isRetryable: nil
        ))),
        .text(.cancelled(id: "cancelled", providerMetadata: metadata)),
        .text(.expired(id: "expired", providerMetadata: metadata))
    ])

    try #require(results.count == 3)
    guard case let .image(.succeeded("image", image)) = results[0],
          case let .text(.cancelled("cancelled", nil, cancelledMetadata)) = results[1],
          case let .text(.expired("expired", nil, expiredMetadata)) = results[2] else {
        Issue.record("Expected unchanged image, cancelled and expired items")
        return
    }
    #expect(image.urls == [url])
    #expect(image.providerMetadata == metadata)
    #expect(cancelledMetadata == metadata)
    #expect(expiredMetadata == metadata)
}

@Test func batchOutputValidatesCompleteJSONAndKeepsExplicitEmptySelection() async throws {
    let valid = #"{"text":"fine"}"#
    let results = try await collectBatchOutput([
        batchOutputText("prefixed", text: "draft \(valid)"),
        batchOutputText("empty", text: valid, structuredOutputText: ""),
        batchOutputText("length", text: valid, finishReason: "length")
    ])

    try #require(results.count == 3)
    let prefixed = try requireBatchOutput(results[0], id: "prefixed")
    let empty = try requireBatchOutput(results[1], id: "empty")
    #expect(prefixed.outputError?.message == "No object generated: could not parse the response.")
    #expect(empty.outputError == prefixed.outputError)
    let length = try requireBatchOutput(results[2], id: "length")
    #expect(length.output == BatchOutputValue(text: "fine"))
}

@Test func batchOutputTextUsesOriginalTextEvenWithJSONSelection() async throws {
    let provider = BatchOutputMockProvider(results: [
        batchOutputText("text", text: "draft", structuredOutputText: #"{"text":"final"}"#)
    ])
    let stream = try AI.getBatchResults(provider: provider, batch: batchOutputReference, output: Output.text(), retryPolicy: .none)
    var iterator = stream.makeAsyncIterator()
    guard case let .text(.succeeded("text", result))? = try await iterator.next() else {
        Issue.record("Expected succeeded text item")
        return
    }
    #expect(result.output == "draft")
    #expect(result.outputError == nil)
    #expect(try await iterator.next() == nil)
}

private func batchOutputRequest(id: String) -> AIBatchRequest {
    .text(TextBatchRequest(
        id: id,
        modelID: "mock-model-id",
        request: LanguageModelRequest(messages: [.user("translate")])
    ))
}

private func batchOutputText(
    _ id: String,
    text: String,
    structuredOutputText: String? = nil,
    finishReason: String = "stop"
) -> AIBatchV4ItemResult {
    .text(.succeeded(id: id, result: TextGenerationResult(
        text: text,
        structuredOutputText: structuredOutputText,
        content: [.text(text)],
        finishReason: finishReason,
        usage: batchOutputUsage,
        rawValue: ["stop_reason": .string(finishReason)]
    )))
}

private func collectBatchOutput(_ items: [AIBatchV4ItemResult]) async throws -> [BatchOutputItemResult<BatchOutputValue>] {
    let stream = try AI.getBatchResults(
        provider: BatchOutputMockProvider(results: items),
        batch: batchOutputReference,
        output: batchOutput,
        retryPolicy: .none
    )
    var results: [BatchOutputItemResult<BatchOutputValue>] = []
    for try await item in stream { results.append(item) }
    return results
}

private func requireBatchOutput(
    _ item: BatchOutputItemResult<BatchOutputValue>,
    id: String
) throws -> TextBatchOutputResult<BatchOutputValue> {
    let result: TextBatchOutputResult<BatchOutputValue>?
    if case let .text(.succeeded(resultID, value)) = item, resultID == id {
        result = value
    } else {
        result = nil
    }
    return try #require(result, "Expected succeeded text item \(id)")
}

private actor BatchOutputMockProvider: AIBatchProvider {
    nonisolated let providerID = "mock-provider"
    private let results: [AIBatchV4ItemResult]
    private(set) var startCalls: [AIBatchStartOptions<AIBatchRequest>] = []

    init(results: [AIBatchV4ItemResult] = []) {
        self.results = results
    }

    func startBatch(_ options: AIBatchStartOptions<AIBatchRequest>) async throws -> AIBatchStartResult {
        startCalls.append(options)
        return AIBatchStartResult(batchID: "batch-123", status: AIBatchStatus(status: .pending))
    }

    func getBatchStatus(_ options: AIBatchOperationOptions) async throws -> AIBatchStatus {
        AIBatchStatus(status: .pending)
    }

    func getBatchResults(_ options: AIBatchOperationOptions) async throws -> AsyncThrowingStream<AIBatchV4ItemResult, Error> {
        AsyncThrowingStream { continuation in
            for result in results { continuation.yield(result) }
            continuation.finish()
        }
    }
}
