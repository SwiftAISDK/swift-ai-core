import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities

// Upstream evidence: ai@7.0.173 packages/ai/src/embed/embed-many.ts,
// packages/ai/src/rerank/rerank.ts and
// packages/provider-utils/src/retry-with-exponential-backoff.ts.

private actor ParityCounter {
    var count = 0
    var embedRequests: [EmbeddingRequest] = []
    var rerankRequests: [RerankingRequest] = []
    func next() -> Int { count += 1; return count }
    func record(_ request: EmbeddingRequest) { embedRequests.append(request) }
    func record(_ request: RerankingRequest) { rerankRequests.append(request) }
}

private actor ParityTelemetry: Telemetry.Integration {
    var events: [Telemetry.Event] = []
    func record(_ event: Telemetry.Event) { events.append(event) }
}

private struct ParityEmbeddingModel: EmbeddingModel {
    let providerID = "mock-provider"
    let modelID = "mock-model-id"
    var maxEmbeddingsPerCall: Int?
    let state: ParityCounter
    let respond: @Sendable (Int, EmbeddingRequest) -> EmbeddingResult

    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResult {
        await state.record(request)
        return respond(await state.next(), request)
    }
}

private struct ParityRerankingModel: RerankingModel {
    let providerID = "mock-provider"
    let modelID = "mock-model-id"
    let state: ParityCounter
    var result: RerankingResult

    func rerank(_ request: RerankingRequest) async throws -> RerankingResult {
        await state.record(request)
        _ = await state.next()
        return result
    }
}

private actor ParityRequestRecorder {
    var requests: [LanguageModelRequest] = []
    func record(_ request: LanguageModelRequest) -> Int { requests.append(request); return requests.count - 1 }
}

private struct ParityLanguageModel: LanguageModel {
    let providerID = "mock-provider"
    let modelID = "mock-model-id"
    let recorder: ParityRequestRecorder
    let respond: @Sendable (Int) -> TextGenerationResult

    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult {
        respond(await recorder.record(request))
    }

    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIError.invalidArgument(argument: "stream", message: "unused")) }
    }
}

@Suite("ai core parity 2026-11-16")
struct AiCoreParity20261116Tests {
    // embed-many.test.ts: "merges metadata for provider %s as an own property"
    @Test(arguments: ["__proto__", "constructor", "toString"])
    func embedManyMergesProviderMetadataAcrossChunks(providerName: String) async throws {
        let state = ParityCounter()
        let model = ParityEmbeddingModel(maxEmbeddingsPerCall: 1, state: state) { call, _ in
            switch call {
            case 1:
                return EmbeddingResult(embeddings: [[1]], rawValue: .null, providerMetadata: ["other": .object([:])])
            case 2:
                return EmbeddingResult(embeddings: [[2]], rawValue: .null, providerMetadata: [providerName: .object(["first": true])])
            default:
                return EmbeddingResult(embeddings: [[3]], rawValue: .null, providerMetadata: [providerName: .object(["second": true])])
            }
        }

        let result = try await AI.embedMany(model: model, values: ["a", "b", "c"], retryPolicy: .none)

        #expect(result.embeddings == [[1], [2], [3]])
        #expect(result.providerMetadata == [
            "other": .object([:]),
            providerName: .object(["first": true, "second": true]),
        ])
    }

    // embed-many.test.ts: "should include provider metadata when returned by the model"
    @Test func embedManyKeepsSingleCallProviderMetadata() async throws {
        let state = ParityCounter()
        let metadata: [String: JSONValue] = ["gateway": ["routing": ["resolvedProvider": "test-provider"]]]
        let model = ParityEmbeddingModel(maxEmbeddingsPerCall: 3, state: state) { _, request in
            EmbeddingResult(
                embeddings: request.values.map { _ in [0.1, 0.2, 0.3] },
                rawValue: .null,
                providerMetadata: metadata
            )
        }

        let result = try await AI.embedMany(
            model: model,
            values: ["sunny day at the beach", "rainy afternoon in the city", "snowy night in the mountains"],
            retryPolicy: .none
        )

        #expect(result.providerMetadata == metadata)
        #expect(await state.count == 1)
    }

    // embed-many.ts reports `operationId: 'ai.embedMany'` for every embedMany call.
    @Test func embedManyUsesEmbedManyOperationIDForOneValue() async throws {
        let state = ParityCounter()
        let telemetry = ParityTelemetry()
        let model = ParityEmbeddingModel(maxEmbeddingsPerCall: nil, state: state) { _, _ in
            EmbeddingResult(embeddings: [[0.1]], rawValue: .null)
        }

        _ = try await AI.embedMany(
            model: model,
            values: ["only"],
            retryPolicy: .none,
            telemetry: Telemetry.Options(integrations: [telemetry])
        )

        let operationIDs = Set(await telemetry.events.map(\.operationID))
        #expect(operationIDs == ["ai.embedMany"])
    }

    // rerank.test.ts: "should fire callbacks for empty documents"; rerank.ts returns before doRerank.
    @Test func rerankWithEmptyDocumentsDoesNotCallModel() async throws {
        let state = ParityCounter()
        let telemetry = ParityTelemetry()
        let model = ParityRerankingModel(
            state: state,
            result: RerankingResult(results: [RerankedDocument(index: 0, score: 1)], rawValue: .null)
        )

        let result = try await AI.rerank(
            model: model,
            request: RerankingRequest(query: "rainy day", documents: [String]()),
            telemetry: Telemetry.Options(integrations: [telemetry])
        )

        #expect(result.results.isEmpty)
        #expect(result.providerMetadata.isEmpty)
        #expect(result.responseMetadata.modelID == "mock-model-id")
        #expect(result.responseMetadata.timestamp != nil)
        #expect(await state.count == 0)
        let events = await telemetry.events
        #expect(events.count == 2)
        #expect(Set(events.map(\.callID)).count == 1)
    }

    // rerank.ts: `modelId: response?.modelId ?? model.modelId`, `timestamp: response?.timestamp ?? new Date()`.
    @Test func rerankDefaultsMissingResponseModelIDAndTimestamp() async throws {
        let state = ParityCounter()
        let model = ParityRerankingModel(
            state: state,
            result: RerankingResult(results: [RerankedDocument(index: 1, score: 0.9)], rawValue: .null)
        )

        let result = try await AI.rerank(
            model: model,
            request: RerankingRequest(query: "q", documents: ["a", "b"]),
            retryPolicy: .none
        )

        #expect(result.responseMetadata.modelID == "mock-model-id")
        #expect(result.responseMetadata.timestamp != nil)

        let provided = Date(timeIntervalSince1970: 1_735_689_600)
        let explicitModel = ParityRerankingModel(
            state: state,
            result: RerankingResult(
                results: [],
                rawValue: .null,
                responseMetadata: AIResponseMetadata(id: "mock-response-id", timestamp: provided, modelID: "mock-response-model-id")
            )
        )
        let explicit = try await AI.rerank(
            model: explicitModel,
            request: RerankingRequest(query: "q", documents: ["a"]),
            retryPolicy: .none
        )
        #expect(explicit.responseMetadata == AIResponseMetadata(id: "mock-response-id", timestamp: provided, modelID: "mock-response-model-id"))
    }

    // rerank.test.ts: "should reject invalid provider ranking index %s" (integer cases).
    @Test(arguments: [3, -1, 5])
    func rerankRejectsInvalidRankingIndexWithoutRetrying(index: Int) async throws {
        let state = ParityCounter()
        let model = ParityRerankingModel(
            state: state,
            result: RerankingResult(results: [RerankedDocument(index: index, score: 0.9)], rawValue: .null)
        )

        do {
            _ = try await AI.rerank(model: model, request: RerankingRequest(query: "q", documents: ["a", "b", "c"]))
            Issue.record("Expected invalid ranking index error")
        } catch let error as AIError {
            #expect(String(describing: error).contains("Invalid ranking index \(index). Expected an integer between 0 and 2."))
        }
        #expect(await state.count == 1)
    }

    // retry-with-exponential-backoff.ts checks `tryNumber > maxRetries` before `shouldRetry`.
    @Test func retryReportsMaxRetriesExceededWhenFinalAttemptIsNotRetryable() async throws {
        let state = ParityCounter()
        do {
            _ = try await withRetry(policy: AIRetryPolicy(maxRetries: 2, initialDelayNanoseconds: 0)) { () async throws -> String in
                let attempt = await state.next()
                throw AIError.apiCall(AIAPICallError(
                    provider: "mock",
                    statusCode: attempt < 3 ? 429 : 400,
                    responseBody: "attempt \(attempt)"
                ))
            }
            Issue.record("Expected retry error")
        } catch let error as AIRetryError {
            #expect(error.reason == .maxRetriesExceeded)
            #expect(error.attempts == 3)
        }
        #expect(await state.count == 3)
    }

    @Test func retryStillReportsNonRetryableBeforeTheBudgetIsExhausted() async throws {
        let state = ParityCounter()
        do {
            _ = try await withRetry(policy: AIRetryPolicy(maxRetries: 2, initialDelayNanoseconds: 0)) { () async throws -> String in
                let attempt = await state.next()
                throw AIError.apiCall(AIAPICallError(
                    provider: "mock",
                    statusCode: attempt == 1 ? 429 : 400,
                    responseBody: "attempt \(attempt)"
                ))
            }
            Issue.record("Expected retry error")
        } catch let error as AIRetryError {
            #expect(error.reason == .errorNotRetryable)
            #expect(error.attempts == 2)
        }
    }

    // getRetryDelayInMs: a numeric `retry-after-ms` suppresses `retry-after` even when out of range,
    // and both headers are parsed with JavaScript `parseFloat` prefix semantics.
    @Test func retryAfterMillisecondsTakesPrecedenceEvenWhenOutOfRange() {
        let backoff: UInt64 = 2_000_000_000
        let negative = AIAPICallError(
            provider: "mock",
            statusCode: 429,
            responseHeaders: ["retry-after-ms": "-1000", "retry-after": "5"],
            responseBody: ""
        )
        #expect(retryDelayNanoseconds(from: negative, exponentialBackoffDelay: backoff) == backoff)

        let suffixed = AIAPICallError(
            provider: "mock",
            statusCode: 429,
            responseHeaders: ["retry-after-ms": "1500ms"],
            responseBody: ""
        )
        #expect(retryDelayNanoseconds(from: suffixed, exponentialBackoffDelay: backoff) == 1_500_000_000)

        let invalid = AIAPICallError(
            provider: "mock",
            statusCode: 429,
            responseHeaders: ["retry-after-ms": "invalid", "retry-after": "3"],
            responseBody: ""
        )
        #expect(retryDelayNanoseconds(from: invalid, exponentialBackoffDelay: backoff) == 3_000_000_000)
    }

    @Test func leadingDecimalNumberMatchesParseFloatPrefixes() {
        #expect(leadingDecimalNumber(in: "12") == 12)
        #expect(leadingDecimalNumber(in: " 1.5s") == 1.5)
        #expect(leadingDecimalNumber(in: ".5") == 0.5)
        #expect(leadingDecimalNumber(in: "-3e2x") == -300)
        #expect(leadingDecimalNumber(in: "Infinity") == .infinity)
        #expect(leadingDecimalNumber(in: "abc") == nil)
        #expect(leadingDecimalNumber(in: "") == nil)
        #expect(leadingDecimalNumber(in: "Wed, 21 Oct 2015 07:28:00 GMT") == nil)
    }

    // to-response-messages.test.ts: "should include reasoning array with redacted reasoning in the assistant message";
    // to-response-messages.ts only skips empty *text* without provider metadata, never reasoning.
    @Test func toResponseMessagesKeepsRedactedAndEmptyReasoning() async throws {
        let parts: [AIContentPart] = [
            .reasoning("redacted-data", providerMetadata: ["testProvider": ["isRedacted": true]]),
            .reasoning("Thinking text", providerMetadata: ["testProvider": ["signature": "sig"]]),
            .reasoning("", providerMetadata: ["openai": ["itemId": "rs_1", "reasoningEncryptedContent": "enc"]]),
            .text("Final text"),
        ]

        let messages = try await toResponseMessages(content: parts)

        #expect(messages == [AIMessage(role: .assistant, content: parts)])
    }

    // generate-text.ts replays the previous step's response messages, so encrypted reasoning
    // with empty text must reach the next tool-loop step request.
    @Test func toolLoopReplaysEmptyEncryptedReasoningToNextStep() async throws {
        let recorder = ParityRequestRecorder()
        let reasoningMetadata: [String: JSONValue] = ["openai": ["itemId": "rs_1", "reasoningEncryptedContent": "enc"]]
        let model = ParityLanguageModel(recorder: recorder) { index in
            if index == 0 {
                return TextGenerationResult(
                    text: "",
                    content: [
                        .reasoning("", providerMetadata: reasoningMetadata),
                        .toolCall(AIToolCall(id: "call-1", name: "lookup", arguments: "{}")),
                    ],
                    finishReason: "tool-calls",
                    rawValue: .null
                )
            }
            return TextGenerationResult(text: "done", finishReason: "stop", rawValue: .null)
        }
        let tool = AITool(name: "lookup", parameters: ["type": "object"], execute: { _ in .string("ok") })

        _ = try await AI.generateText(
            model: model,
            request: LanguageModelRequest(messages: [.user("hi")]),
            executableTools: [tool],
            retryPolicy: .none
        )

        let requests = await recorder.requests
        #expect(requests.count == 2)
        let assistant = try #require(requests.last?.messages.first { $0.role == .assistant })
        #expect(assistant.content.first == .reasoning("", providerMetadata: reasoningMetadata))
    }
}
