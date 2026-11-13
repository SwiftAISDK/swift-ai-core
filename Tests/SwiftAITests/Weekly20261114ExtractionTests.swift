import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport

private actor ExtractionCalls {
    var options: [AIExtractionModelV4CallOptions] = []
    func append(_ options: AIExtractionModelV4CallOptions) -> Int { self.options.append(options); return self.options.count }
}
private struct ExtractionMock: AIExtractionModelV4 {
    var specificationVersion = "v4"
    let providerID = "mock.extraction", modelID = "extract"
    var supportedFieldTypes = AIExtractionFieldType.allCases
    var body: @Sendable (AIExtractionModelV4CallOptions) async throws -> AIExtractionModelV4Result
    func doExtract(_ options: AIExtractionModelV4CallOptions) async throws -> AIExtractionModelV4Result { try await body(options) }
}

@Suite("Weekly20261114 Extraction V4 facade")
struct Weekly20261114ExtractionTests {
    @Test func extractsAllFieldsAndPreservesNullAndResponseMetadata() async throws {
        let calls = ExtractionCalls()
        let model = ExtractionMock { options in
            _ = await calls.append(options)
            return .init(answers: ["name": .init(type: .text, value: "Ada", guess: "Ada", pNull: 0, confidence: 1, source: .text(part: 0, start: 0, end: 3)), "missing": .init(type: .date)], usage: .init(inputTokens: 5, outputTokens: 2), providerMetadata: ["mock": ["kept": true]], response: .init(id: "r", headers: ["x-request": "yes"], body: ["raw": true]))
        }
        let result = try await AI.experimentalExtract(model: model, state: "Ada", fields: ["name": .init(type: .text), "missing": .init(type: .date)], referenceDate: "2026-11-14", headers: ["user-agent": "client"], providerOptions: ["mock": ["option": true]])
        #expect(result.answers["name"]?.value == "Ada")
        #expect(result.answers["missing"]?.value == nil)
        #expect(result.usage.totalTokens == 7)
        #expect(result.response.id == "r" && result.response.modelID == "extract")
        #expect(result.response.body == ["raw": true])
        let options = try #require(await calls.options.first)
        #expect(options.referenceDate == "2026-11-14")
        #expect(options.headers.values.contains { $0.contains("ai/7.0.172") })
        #expect(options.providerOptions["mock"] == ["option": true])
    }

    @Test(arguments: ["version", "unsupported", "empty", "date", "decimals", "duration", "items", "finite", "limit"])
    func rejectsInvalidInputBeforeProviderIO(_ kind: String) async throws {
        let calls = ExtractionCalls()
        var model = ExtractionMock { options in _ = await calls.append(options); return .init(answers: [:]) }
        var fields: [String: AIExtractionField] = ["x": .init(type: .text)]
        var date: String?, limit: Int?
        if kind == "version" { model.specificationVersion = "v3" }
        if kind == "unsupported" { model.supportedFieldTypes = [.number] }
        if kind == "empty" { fields = [:] }
        if kind == "date" { date = "2026-02-30" }
        if kind == "decimals" { fields = ["x": .init(type: .number, decimals: 7)] }
        if kind == "duration" { fields = ["x": .init(type: .duration, unit: "parsecs")] }
        if kind == "items" { fields = ["x": .init(type: .list)] }
        if kind == "finite" { fields = ["x": .init(type: .text, instructions: .number(.infinity))] }
        if kind == "limit" { limit = 0 }
        await #expect(throws: (any Error).self) { try await AI.experimentalExtract(model: model, state: "state", fields: fields, referenceDate: date, maxOutputTokens: limit) }
        #expect(await calls.options.isEmpty)
    }

    @Test(arguments: ["missing", "extra", "type", "number", "integer", "decimal", "date", "time", "datetime", "duration", "list", "confidence", "guess", "source", "item-count", "item-source"])
    func rejectsMalformedProviderAnswers(_ kind: String) async throws {
        var field = AIExtractionField(type: .text)
        var answer = AIExtractionAnswer(type: .text, value: "valid")
        switch kind {
        case "type": answer.type = .number
        case "number": field = .init(type: .number); answer = .init(type: .number, value: .number(.infinity))
        case "integer": field = .init(type: .number, integer: true); answer = .init(type: .number, value: 1.5)
        case "decimal": field = .init(type: .number, decimals: 2); answer = .init(type: .number, value: 1.234)
        case "date": field = .init(type: .date); answer = .init(type: .date, value: "2026-02-30")
        case "time": field = .init(type: .time); answer = .init(type: .time, value: "24:00")
        case "datetime": field = .init(type: .datetime); answer = .init(type: .datetime, value: "2026-02-30T12:00Z")
        case "duration": field = .init(type: .duration); answer = .init(type: .duration, value: -1)
        case "list": field = .init(type: .list, items: .number); answer = .init(type: .list, value: ["wrong"])
        case "confidence": answer.confidence = 2
        case "guess": answer.guess = 1
        case "source": answer.source = .text(part: 0, start: 0, end: 4)
        case "item-count": field = .init(type: .list, items: .text); answer = .init(type: .list, value: ["yes"], items: [])
        case "item-source": field = .init(type: .list, items: .text); answer = .init(type: .list, value: ["yes"], items: [.init(source: .file(part: 0))])
        default: break
        }
        var answers = ["x": answer]
        if kind == "missing" { answers = [:] }
        if kind == "extra" { answers["extra"] = answer }
        let response = answers
        let model = ExtractionMock { _ in .init(answers: response) }
        await #expect(throws: AIError.self) { try await AI.experimentalExtract(model: model, state: "yes", fields: ["x": field], maxRetries: 0) }
    }

    @Test(arguments: ["0000-02-29", "2024-02-29", "2026-11-14T12:15", "2026-11-14T12:15:20.123456789+09:00"])
    func acceptsCalendarDatesAndPreciseOffsetDatetimes(_ text: String) async throws {
        let type: AIExtractionFieldType = text.contains("T") ? .datetime : .date
        let model = ExtractionMock { _ in .init(answers: ["x": .init(type: AIExtractionAnswerType(rawValue: type.rawValue)!, value: .string(text))]) }
        #expect(try await AI.experimentalExtract(model: model, state: "value", fields: ["x": .init(type: type)]).answers["x"]?.value == .string(text))
    }

    @Test func sourceOffsetsUseUTF16AndRefusalRejectsWholeOperation() async throws {
        let model = ExtractionMock { _ in .init(answers: ["emoji": .init(type: .text, value: "😀", source: .text(part: 1, start: 0, end: 2)), "file": .init(type: .text, value: "file", source: .file(part: 2))]) }
        let state = AIDecisionState.parts([.text("prefix"), .text("😀"), .file(mediaType: "application/pdf", data: .data(Data([1])))])
        let fields: [String: AIExtractionField] = ["emoji": .init(type: .text), "file": .init(type: .text)]
        #expect(try await AI.experimentalExtract(model: model, state: state, fields: fields).answers.count == 2)
        let refusal = ExtractionMock { _ in .init(answers: ["x": .init(type: .refusal)]) }
        do { _ = try await AI.experimentalExtract(model: refusal, state: "state", fields: ["x": .init(type: .text)]); Issue.record("Expected refusal") }
        catch let error as AIExtractionRefusalError { #expect(error.fieldIDs == ["x"]) }
    }

    @Test func retriesTransientFailuresAndHonorsCancellation() async throws {
        let calls = ExtractionCalls(), controller = AIAbortController()
        let model = ExtractionMock { options in
            if await calls.append(options) == 1 { throw AIError.apiCall(.init(provider: "mock", statusCode: 503, responseBody: "retry")) }
            return .init(answers: ["x": .init(type: .text, value: "done")])
        }
        #expect(try await AI.experimentalExtract(model: model, state: "state", fields: ["x": .init(type: .text)], maxRetries: 1).answers["x"]?.value == "done")
        #expect(await calls.options.count == 2)
        controller.abort(reason: "cancelled")
        await #expect(throws: AIAbortError.self) { try await AI.experimentalExtract(model: model, state: "state", fields: ["x": .init(type: .text)], abortSignal: controller.signal) }
        #expect(await calls.options.count == 2)
    }

    @Test func forwardsCustomFileDownloaderAndNeverCallsProviderAfterDownloadFailure() async throws {
        let calls = ExtractionCalls(), controller = AIAbortController()
        let model = ExtractionMock { options in _ = await calls.append(options); return .init(answers: ["x": .init(type: .text, value: "yes")]) }
        let state = AIDecisionState.parts([.file(mediaType: "application/pdf", data: .url(URL(string: "https://files.example.com/a.pdf")!))])
        let result = try await AI.experimentalExtract(model: model, state: state, fields: ["x": .init(type: .text)], abortSignal: controller.signal, download: { requests in
            #expect(requests.count == 1 && requests[0].abortSignal === controller.signal && !requests[0].isURLSupportedByModel)
            return [.init(data: Data([1, 2]), mediaType: "application/pdf")]
        })
        #expect(result.answers["x"]?.value == "yes")
        let options = try #require(await calls.options.first)
        #expect(options.state == [.file(mediaType: "application/pdf", data: .data(Data([1, 2])))])
        await #expect(throws: AIDownloadError.self) { try await AI.experimentalExtract(model: model, state: state, fields: ["x": .init(type: .text)], download: { _ in [nil] }) }
        #expect(await calls.options.count == 1)
    }
}
