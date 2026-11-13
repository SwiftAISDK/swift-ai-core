import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities

private actor ExtractionAdapterCalls {
    var requests: [LanguageModelRequest] = []
    func record(_ request: LanguageModelRequest) { requests.append(request) }
}
private struct ExtractionLanguageMock: LanguageModel {
    let providerID = "mock.responses", modelID = "test"
    var generateBody: @Sendable (LanguageModelRequest) async throws -> TextGenerationResult
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult { try await generateBody(request) }
}

@Suite("Weekly20261114 structured language extraction adapter")
struct Weekly20261114ExtractionAdapterTests {
    @Test func nullableSchemaAndFieldIDsDoNotCollideWithProviderKeys() async throws {
        let calls = ExtractionAdapterCalls()
        let model = AIExtractionLanguageModel(model: ExtractionLanguageMock { request in
            await calls.record(request)
            return .init(text: #"{"f0":"Ada","f1":3.14159,"f2":[]}"#, finishReason: "stop", rawValue: [:])
        })
        let result = try await model.doExtract(.init(state: [.text("evidence"), .json(["key": 1])], fields: ["__proto__": .init(type: .text), "constructor": .init(type: .number, unit: "USD", decimals: 2), "toString": .init(type: .list, items: .text)], referenceDate: "2026-11-14", maxOutputTokens: 200, reasoning: "low", headers: ["x-test": "yes"], providerOptions: ["mock": ["option": true]]))
        #expect(result.answers["__proto__"]?.value == "Ada")
        #expect(result.answers["constructor"]?.value == 3.14)
        #expect(result.answers["toString"]?.value == nil)
        let request = try #require(await calls.requests.first)
        #expect(request.reasoning == "low" && request.maxOutputTokens == 200)
        #expect(request.headers == ["x-test": "yes"])
        #expect(request.providerOptions["mock"] == ["option": true])
        guard case let .json(schema, name, _) = request.responseFormat else { Issue.record("Expected JSON format"); return }
        #expect(name == "extraction")
        #expect(schema?["properties"]?["f1"]?["anyOf"]?[0]?["type"] == "number")
        #expect(schema?["properties"]?["f1"]?["anyOf"]?[1]?["type"] == "null")
        #expect(request.messages[0].role == .system)
    }

    @Test func chunksParallelCallsAndSumsOnlyCompleteUsage() async throws {
        let calls = ExtractionAdapterCalls()
        let model = AIExtractionLanguageModel(model: ExtractionLanguageMock { request in
            await calls.record(request)
            guard case let .json(schema, _, _) = request.responseFormat else { throw AIError.invalidResponse(provider: "mock", message: "schema") }
            let keys = schema?["properties"]?.objectValue?.keys.sorted() ?? []
            let object = JSONValue.object(Dictionary(uniqueKeysWithValues: keys.map { ($0, .string("value")) }))
            return .init(text: try decisionJSONText(object), finishReason: "stop", usage: .init(inputTokens: 2, outputTokens: keys.count), rawValue: [:], responseMetadata: .init(id: keys.count == 2 ? "first" : "last"))
        }, maxFieldsPerCall: 2)
        let fields = Dictionary(uniqueKeysWithValues: (0..<5).map { ("field\($0)", AIExtractionField(type: .text)) })
        let result = try await model.doExtract(.init(state: [.text("state")], fields: fields))
        #expect(result.answers.count == 5)
        #expect(result.usage?.inputTokens == 6 && result.usage?.outputTokens == 5)
        #expect(result.response?.id == "first")
        #expect(await calls.requests.count == 3)
    }

    @Test(arguments: ["invalid-json", "missing", "extra", "length", "content-filter", "empty"])
    func parsingAndRefusalOutcomes(_ kind: String) async throws {
        let model = AIExtractionLanguageModel(model: ExtractionLanguageMock { _ in
            let text = kind == "invalid-json" ? "invalid" : kind == "missing" ? "{}" : kind == "extra" ? #"{"f0":"v","f1":"v"}"# : #"{"f0":""}"#
            return .init(text: text, finishReason: kind == "length" ? "length" : kind == "content-filter" ? "content-filter" : "stop", rawValue: [:])
        })
        let options = AIExtractionModelV4CallOptions(state: [.text("state")], fields: ["x": .init(type: .text)])
        if kind == "content-filter" { #expect(try await model.doExtract(options).answers["x"]?.type == .refusal) }
        else if kind == "empty" { #expect(try await model.doExtract(options).answers["x"]?.value == nil) }
        else { await #expect(throws: AIError.self) { try await model.doExtract(options) } }
    }

    @Test func failureAbortsSiblingSignalsAndPreabortedCallsDoNotReachModel() async throws {
        let calls = ExtractionAdapterCalls(), controller = AIAbortController()
        controller.abort(reason: "caller")
        let model = AIExtractionLanguageModel(model: ExtractionLanguageMock { request in
            await calls.record(request)
            return .init(text: #"{"f0":"v"}"#, finishReason: "stop", rawValue: [:])
        })
        await #expect(throws: AIAbortError.self) { try await model.doExtract(.init(state: [.text("state")], fields: ["x": .init(type: .text)], abortSignal: controller.signal)) }
        #expect(await calls.requests.isEmpty)
        let failing = AIExtractionLanguageModel(model: ExtractionLanguageMock { request in
            await calls.record(request)
            if request.responseFormat == nil { return .init(text: "unused", rawValue: [:]) }
            throw AIError.invalidResponse(provider: "mock", message: "failure")
        }, maxFieldsPerCall: 1)
        await #expect(throws: (any Error).self) { try await failing.doExtract(.init(state: [.text("state")], fields: ["a": .init(type: .text), "b": .init(type: .text)])) }
        #expect(await calls.requests.allSatisfy { $0.abortSignal?.isAborted == true })
    }
}
