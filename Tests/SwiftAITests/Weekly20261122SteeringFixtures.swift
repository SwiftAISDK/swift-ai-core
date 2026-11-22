import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider

let steeringQuestion = "What is the weather in Paris?"
let steeringCorrection = "Use Paris, Texas instead."
let steeringAnswer = "It is sunny in Paris, Texas."

func steeringUsage(_ output: Int) -> TokenUsage {
    .init(inputTokens: 3, outputTokens: output, inputTokensNoCache: 3, outputTextTokens: output)
}

func steeringText(_ text: String = steeringAnswer) -> TextGenerationResult {
    .init(text: text, finishReason: "stop", usage: steeringUsage(10), rawValue: [:])
}

let steeringWeatherCall = AIToolCall(id: "call-1", name: "weather", arguments: """
    { "city": "Paris" }
    """)

let steeringWeatherResponse = TextGenerationResult(
    text: "", finishReason: "tool-calls", usage: steeringUsage(5), toolCalls: [steeringWeatherCall], rawValue: [:]
)

func steeringWeatherTool(_ execute: @escaping @Sendable (JSONValue) async throws -> JSONValue) -> AITool {
    AITool(name: "weather", parameters: [
        "type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]
    ], execute: execute)
}

func waitForSteeringAbort(_ request: LanguageModelRequest) async throws -> Never {
    let signal = try #require(request.abortSignal)
    try await delay(3_000, abortSignal: signal)
    throw SteeringFixtureError.expectedAbort
}

enum SteeringFixtureError: Error { case expectedAbort, unexpectedGenerate, providerFailure }

struct SteeringFixtureModel: LanguageModel {
    typealias Continuation = AsyncThrowingStream<LanguageStreamPart, Error>.Continuation
    let providerID = "steering-fixture"
    let modelID = "weather"
    private let respond: @Sendable (LanguageModelRequest) async throws -> TextGenerationResult
    private let streamResponse: (@Sendable (LanguageModelRequest, Continuation) async throws -> Void)?

    init(_ respond: @escaping @Sendable (LanguageModelRequest) async throws -> TextGenerationResult) {
        self.respond = respond
        self.streamResponse = nil
    }

    init(stream: @escaping @Sendable (LanguageModelRequest, Continuation) async throws -> Void) {
        self.respond = { _ in throw SteeringFixtureError.unexpectedGenerate }
        self.streamResponse = stream
    }

    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult {
        try await respond(request)
    }

    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let streamResponse {
                        try await streamResponse(request, continuation)
                    } else {
                        let response = try await respond(request)
                        if response.requestMetadata != AIRequestMetadata() {
                            continuation.yield(.requestMetadata(response.requestMetadata))
                        }
                        continuation.yield(.streamStart(warnings: response.warnings))
                        for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                        if !response.text.isEmpty {
                            continuation.yield(.textStart(id: "2"))
                            continuation.yield(.textDeltaPart(id: "2", delta: response.text))
                            continuation.yield(.textEnd(id: "2"))
                        }
                        continuation.yield(.finishMetadata(reason: response.finishReason, usage: response.usage))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

actor SteeringTestTrace: Telemetry.Integration {
    var requests: [LanguageModelRequest] = []
    var prepared: [AIPrepareStepContext] = []
    var receipts: [AISteeringReceipt] = []
    var toolInputs: [JSONValue] = []
    var events: [Telemetry.Event] = []
    var modelCalls = 0
    var aborts: [AIStreamTextAbortEvent] = []
    var failedSteps: [AIGenerateTextStepErrorEvent] = []
    var errors: [any Error] = []

    func begin(_ request: LanguageModelRequest) -> Int {
        requests.append(request)
        return requests.count
    }
    func prepare(_ context: AIPrepareStepContext) { prepared.append(context) }
    func track(_ receipt: AISteeringReceipt) { receipts.append(receipt) }
    func executeTool(_ value: JSONValue) { toolInputs.append(value) }
    func record(_ event: Telemetry.Event) async { events.append(event) }
    func abort(_ event: AIStreamTextAbortEvent) { aborts.append(event) }
    func stepError(_ event: AIGenerateTextStepErrorEvent) { failedSteps.append(event) }
    func error(_ event: AIGenerationErrorEvent) { errors.append(event.error) }

    func executeLanguageModelCall<Output: Sendable>(_ context: Telemetry.LanguageModelCallContext<Output>) async throws -> Output {
        modelCalls += 1
        return try await context.execute()
    }
}

struct SteeringTestResult {
    let steps: [AIToolStep]
    let text: String
    let usage: TokenUsage?
    let streamParts: [LanguageStreamPart]
}

func runSteeringFixture(
    _ model: SteeringFixtureModel,
    streaming: Bool,
    steering: AISteering,
    request: LanguageModelRequest = .init(messages: [.user(steeringQuestion)]),
    tools: [AITool] = [],
    maxSteps: Int = 1,
    stopWhen: [AIStopCondition] = [],
    prepare: AIPrepareStep? = nil,
    streamRetries: Int? = nil,
    timeout: AIStreamTimeoutConfiguration? = nil,
    telemetry: Telemetry.Options? = nil,
    trace: SteeringTestTrace? = nil,
    onPart: ((LanguageStreamPart) async -> Void)? = nil
) async throws -> SteeringTestResult {
    if streaming {
        let results = AISteeringStepResults()
        let stream = AISteeringContext.$streamResults.withValue(results) {
            AI.streamText(
                model: model, request: request, executableTools: tools, maxSteps: maxSteps,
                stopWhen: stopWhen, prepareStep: prepare, timeout: timeout,
                retryPolicy: .none, streamRetries: streamRetries, telemetry: telemetry,
                experimentalSteering: steering,
                onStepError: { await trace?.stepError($0) },
                onError: { await trace?.error($0) },
                onAbort: { await trace?.abort($0) }
            )
        }
        var parts: [LanguageStreamPart] = []
        var usage: TokenUsage?
        for try await part in stream {
            parts.append(part)
            if case let .finishMetadata(_, stepUsage, _) = part { usage = sumTokenUsage(usage, stepUsage) }
            await onPart?(part)
        }
        let steps = results.steps
        return .init(steps: steps, text: steps.last?.text ?? "", usage: usage, streamParts: parts)
    }
    let result = try await AI.generateText(
        model: model, request: request, executableTools: tools, maxSteps: maxSteps,
        stopWhen: stopWhen, prepareStep: prepare, retryPolicy: .none, telemetry: telemetry,
        experimentalSteering: steering, onStepError: { await trace?.stepError($0) }
    )
    return .init(steps: result.steps, text: result.text, usage: result.usage, streamParts: [])
}

func steeringTestOutcomes(_ state: SteeringTestTrace) async -> [AISteeringOutcome] {
    var outcomes: [AISteeringOutcome] = []
    for receipt in await state.receipts { outcomes.append(await receipt.value) }
    return outcomes
}

func steeringTextParts(_ text: String = steeringAnswer, id: String = "2") -> [LanguageStreamPart] {
    [
        .streamStart(warnings: []), .textStart(id: id), .textDeltaPart(id: id, delta: text),
        .textEnd(id: id), .finishMetadata(reason: "stop", usage: steeringUsage(10))
    ]
}
