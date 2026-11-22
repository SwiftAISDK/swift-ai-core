import Foundation
import SwiftAI
import SwiftAIProvider
import SwiftAITransport
import Testing

// ai@7.0.179 packages/ai/src/extract/extract.test.ts and extract.test-d.ts.
@Suite struct ExtractionTelemetryUpstreamTests {
    private let state: AIDecisionState = .text("Invoice INV-2041, total due $1,250.00 by March 3, 2027 at 17:30. Call Ana or Bo within 2 hours.")
    private let fields: [String: AIExtractionField] = [
        "invoiceNumber": .init(type: .text, instructions: "The invoice number"),
        "total": .init(type: .number, instructions: "Total due", unit: "USD", decimals: 2),
        "dueDate": .init(type: .date, instructions: "Due date"),
        "dueTime": .init(type: .time, instructions: "Due time"),
        "dueAt": .init(type: .datetime, instructions: "Due date and time"),
        "callWithin": .init(type: .duration, instructions: "Call window", unit: "hours"),
        "contacts": .init(type: .list, instructions: "Contact names", items: .text)
    ]
    private let answers: [String: AIExtractionAnswer] = [
        "invoiceNumber": .init(type: .text, value: "INV-2041", confidence: 0.98, source: .text(part: 0, start: 8, end: 16)),
        "total": .init(type: .number, value: 1250, pNull: 0.01),
        "dueDate": .init(type: .date, value: "2027-03-03"),
        "dueTime": .init(type: .time, value: "17:30"),
        "dueAt": .init(type: .datetime, value: "2027-03-03T17:30"),
        "callWithin": .init(type: .duration, value: 2),
        "contacts": .init(type: .list, value: ["Ana", "Bo"], items: [
            .init(confidence: 0.9, source: .text(part: 0, start: 70, end: 73)),
            .init(confidence: 0.8)
        ])
    ]

    @Test(arguments: ["", " INV-2041 ", "   "])
    func normalizesOnlyEmptyValuesAndPreservesAnswerMetadata(value: String) async throws {
        var original = answers
        original["invoiceNumber"]?.value = .string(value)
        original["dueDate"] = .init(type: .date, value: "")
        original["contacts"] = .init(type: .list, value: [], pNull: 0.9, confidence: 0.8, items: [])
        let result = try await AI.experimentalExtract(model: ExtractTestModel(answers: original), state: state, fields: fields)
        var expected = original
        if value.isEmpty { expected["invoiceNumber"]?.value = nil }
        expected["dueDate"]?.value = nil
        expected["contacts"] = .init(type: .list, pNull: 0.9, confidence: 0.8)
        #expect(result.answers == expected)
        #expect(result.answers["contacts"]?.items == nil)
        #expect(original["contacts"] == .init(type: .list, value: [], pNull: 0.9, confidence: 0.8, items: []))
    }

    @Test func emitsOperationAndModelEventsInLifecycleOrder() async throws {
        let recorder = ExtractTestRecorder()
        var original = answers
        original["contacts"] = .init(type: .list, value: [])
        _ = try await AI.experimentalExtract(model: ExtractTestModel(answers: original, usage: .init(inputTokens: 40, outputTokens: 12)),
            state: state, fields: fields, referenceDate: "2026-11-18",
            telemetry: .init(includesInput: false, includesOutput: true, functionID: "extract-test", integrations: [recorder]),
            runtimeContext: ["requestId": "request-1", "secret": "hidden"],
            onStart: { await recorder.start($0) }, onEnd: { await recorder.end($0) })
        let events = await recorder.events
        #expect(await recorder.order == ["callback.start", "start", "modelCallStart", "modelCallEnd", "callback.end", "end"])
        #expect(events.map(\.operationID) == ["ai.extract", "ai.extract.doExtract", "ai.extract.doExtract", "ai.extract"])
        #expect(Set(events.map(\.callID)).count == 1)
        #expect(events.allSatisfy {
            $0.providerID == "mock-provider" && $0.modelID == "mock-model-id" && $0.aiVersion == "7.0.179" &&
                $0.functionID == "extract-test" && $0.input == nil && $0.runtimeContext.isEmpty
        })
        #expect(events.first?.maxRetries == 2)
        let modelEnd = try #require(events.first { $0.kind == .modelCallEnd })
        let end = try #require(events.last)
        #expect(modelEnd.usage?.inputTokens == 40 && modelEnd.usage?.outputTokens == 12)
        #expect(end.usage?.totalTokens == 52)
        #expect(modelEnd.output?["answers"]?["contacts"] == ["type": "list", "value": .null])
        #expect(end.output == modelEnd.output)
        let startPayload = try #require(await recorder.started)
        let endPayload = try #require(await recorder.ended)
        #expect(startPayload.callID == endPayload.callID && startPayload.callID == end.callID)
        #expect(startPayload.state == state && startPayload.fields == fields)
        #expect(startPayload.referenceDate == "2026-11-18")
        let context: [String: JSONValue] = endPayload.runtimeContext
        #expect(context == ["requestId": "request-1", "secret": "hidden"])
    }

    @Test func hidesOutputFromIntegrationsAndKeepsItInApplicationCallback() async throws {
        let recorder = ExtractTestRecorder()
        _ = try await AI.experimentalExtract(model: ExtractTestModel(answers: answers), state: state, fields: fields,
            telemetry: .init(includesOutput: false, integrations: [recorder]), onEnd: { await recorder.end($0) })
        let events = await recorder.events.filter { [.end, .modelCallEnd].contains($0.kind) }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.output == nil && $0.input?["fields"]?.objectValue?.count == fields.count })
        #expect(await recorder.ended?.result.answers == answers)
    }

    @Test(arguments: [true, false])
    func keepsHeadersAndBYOKOptionsOutOfTelemetry(recordInputs: Bool) async throws {
        let recorder = ExtractTestRecorder()
        let headers = ["authorization": "Bearer secret-token"]
        let options: [String: JSONValue] = ["gateway": ["byok": ["openai": [["apiKey": "secret-key"]]]]]
        _ = try await AI.experimentalExtract(model: ExtractTestModel(answers: answers), state: state, fields: fields,
            headers: headers, providerOptions: options, telemetry: .init(includesInput: recordInputs, integrations: [recorder]),
            onStart: { await recorder.start($0) })
        let events = await recorder.events
        #expect(events.allSatisfy { $0.input?["headers"] == nil && $0.input?["providerOptions"] == nil })
        #expect(!String(describing: events).contains("secret"))
        #expect(await recorder.started?.headers == headers)
        #expect(await recorder.started?.providerOptions == options)
    }

    @Test func redactsFileURLsAndReferencesFromIntegrations() async throws {
        let recorder = ExtractTestRecorder()
        let url = URL(string: "https://files.example.com/invoice.pdf?X-Amz-Signature=secret")!
        let parts: [AIDecisionStatePart] = [
            .text("Invoice"),
            .file(mediaType: "application/pdf", data: .url(url)),
            .file(mediaType: "application/pdf", data: .url(url)),
            .file(mediaType: "application/pdf", data: .reference("secret-reference")),
            .file(mediaType: "application/pdf", data: .reference("secret-bare-reference"))
        ]
        _ = try await AI.experimentalExtract(
            model: ExtractTestModel(answers: ["invoiceNumber": .init(type: .text, value: "INV-2041")]),
            state: .parts(parts), fields: ["invoiceNumber": try #require(fields["invoiceNumber"])],
            download: { $0.map { _ in .init(data: Data([1, 2, 3]), mediaType: "application/pdf") } },
            telemetry: .init(integrations: [recorder]), onStart: { await recorder.start($0) })
        let event = try #require(await recorder.events.first)
        #expect(!String(describing: event).contains("secret"))
        let redacted: JSONValue = ["type": "file", "mediaType": "application/pdf", "data": "[redacted]"]
        #expect(event.input?["state"] == [["type": "text", "text": "Invoice"], redacted, redacted, redacted, redacted])
        #expect(await recorder.started?.state == .parts(parts))
    }

    @Test func redactsFailedDownloadURLInErrorEvent() async throws {
        let recorder = ExtractTestRecorder()
        let url = URL(string: "https://files.example.com/invoice.pdf?X-Amz-Signature=secret")!
        let actual = AIDownloadError(url: url.absoluteString, message: "Download of \(url) exceeded maximum size of 10 bytes.")
        await #expect(throws: actual) {
            _ = try await AI.experimentalExtract(model: ExtractTestModel(answers: answers),
                state: .parts([.file(mediaType: "application/pdf", data: .url(url))]), fields: fields,
                download: { _ in throw actual }, telemetry: .init(integrations: [recorder]))
        }
        let events = await recorder.events
        #expect(events.map(\.kind) == [.start, .error])
        #expect(events.last?.errorDescription == "Failed to download a file.")
        #expect(!String(describing: events).contains("secret"))
    }

    @Test func includesOnlySelectedRuntimeContextFields() async throws {
        let recorder = ExtractTestRecorder()
        _ = try await AI.experimentalExtract(model: ExtractTestModel(answers: answers), state: state, fields: fields,
            telemetry: .init(includeRuntimeContext: ["requestId": true], integrations: [recorder]),
            runtimeContext: ["requestId": "request-1", "secret": "hidden"])
        let events = await recorder.events.filter { $0.kind == .start || $0.kind == .end }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.runtimeContext == ["requestId": "request-1"] })
    }

    @Test(arguments: [true, false])
    func failuresEmitErrorWithoutEndEvents(refusesField: Bool) async throws {
        let recorder = ExtractTestRecorder()
        var original = answers
        original["total"] = .init(type: .refusal)
        let failure = AIError.invalidResponse(provider: "mock-provider", message: "extraction failed")
        let model = ExtractTestModel(answers: original, failure: refusesField ? nil : failure)
        await #expect {
            _ = try await AI.experimentalExtract(model: model, state: state, fields: fields, maxRetries: 0,
                telemetry: .init(integrations: [recorder]), onEnd: { await recorder.end($0) })
        } throws: { error in
            if refusesField { return (error as? AIExtractionRefusalError)?.fieldIDs == ["total"] }
            return error as? AIError == failure
        }
        let events = await recorder.events
        #expect(events.map(\.kind) == [.start, .modelCallStart, .error])
        #expect(events.last?.aiVersion == "7.0.179")
        #expect(events.last?.callID == events.first?.callID)
        #expect(await recorder.ended == nil)
    }

    @Test func unsupportedFieldTypeEmitsNoEvents() async throws {
        let recorder = ExtractTestRecorder()
        let model = ExtractTestModel(supportedFieldTypes: [.text], answers: answers)
        await #expect(throws: AIExtractionUnsupportedFieldTypeError.self) {
            _ = try await AI.experimentalExtract(model: model, state: state, fields: fields,
                telemetry: .init(integrations: [recorder]), onStart: { await recorder.start($0) })
        }
        #expect(await recorder.events.isEmpty)
        #expect(await recorder.started == nil)
    }
}

private struct ExtractTestModel: AIExtractionModelV4 {
    let providerID = "mock-provider"
    let modelID = "mock-model-id"
    var supportedFieldTypes = AIExtractionFieldType.allCases
    let answers: [String: AIExtractionAnswer]
    var usage: AIDecisionModelUsage? = nil
    var failure: AIError? = nil

    func doExtract(_ options: AIExtractionModelV4CallOptions) async throws -> AIExtractionModelV4Result {
        if let failure { throw failure }
        return .init(answers: answers, usage: usage)
    }
}

private actor ExtractTestRecorder: Telemetry.Integration {
    private(set) var events: [Telemetry.Event] = []
    private(set) var order: [String] = []
    private(set) var started: AIExtractionStartEvent?
    private(set) var ended: AIExtractionEndEvent?

    func record(_ event: Telemetry.Event) async {
        events.append(event)
        order.append(event.kind.rawValue)
    }
    func start(_ event: AIExtractionStartEvent) {
        started = event
        order.append("callback.start")
    }
    func end(_ event: AIExtractionEndEvent) {
        ended = event
        order.append("callback.end")
    }
}

// ai@7.0.179 packages/ai/src/registry/extraction-model.test.ts.
@Suite struct ExtractionRegistryUpstreamTests {
    @Test func aliasesPreserveModelIdentityBeforeFallbackLookup() throws {
        let model = ExtractionAliasModel(id: "model:version")
        let fallback = AICustomProvider(extractionModels: ["model:version": .model(model)])
        let provider = AIProviders.customProvider(extractionModels: ["alias": .model(model)], fallbackProvider: fallback)
        #expect(provider.supportedCapabilities.contains(.extraction))
        #expect(try provider.extractionModel("alias") as? ExtractionAliasModel === model)
        #expect(try provider.extractionModel("model:version") as? ExtractionAliasModel === model)
        let stringAlias = AIProviders.customProvider(extractionModels: ["alias": "model:version"], fallbackProvider: fallback)
        #expect(try stringAlias.extractionModel("alias") as? ExtractionAliasModel === model)
    }

    @Test(arguments: [":", "::"])
    func registryPreservesSeparatorsInTheModelID(separator: String) throws {
        let id = "model\(separator)version"
        let model = ExtractionAliasModel(id: id)
        let provider = AICustomProvider(extractionModels: [id: .model(model)])
        let registry = createProviderRegistry(["provider": provider], separator: separator)
        #expect(try registry.extractionModel("provider\(separator)\(id)") as? ExtractionAliasModel === model)
    }

    @Test(arguments: ["missing", "toString", "constructor", "__proto__"])
    func missingAliasesAreNotImplicitProperties(id: String) {
        let provider = AICustomProvider(extractionModels: ["known": .model(ExtractionAliasModel(id: "known"))])
        #expect(throws: AIError.unsupportedModel(provider: "custom", capability: .extraction, modelID: id)) {
            _ = try provider.extractionModel(id)
        }
    }

    @Test func registryAndFactoryErrorsRemainTyped() {
        let provider = AICustomProvider(providerID: "known")
        let registry = createProviderRegistry(["known": provider])
        #expect(throws: AIProviderRegistryError.noSuchProvider(providerID: "missing", modelType: "extractionModel",
            availableProviders: ["known"])) { _ = try registry.extractionModel("missing:model") }
        #expect(throws: AIProviderRegistryError.invalidModelID(modelID: "model", modelType: "extractionModel",
            separator: ":")) { _ = try registry.extractionModel("model") }
        #expect(throws: AIError.unsupportedModel(provider: "known", capability: .extraction, modelID: "model")) {
            _ = try registry.extractionModel("known:model")
        }
        let specific = AIError.invalidResponse(provider: "known", message: "missing")
        let aliased = AICustomProvider(extractionModels: ["alias": "missing"], resolveExtractionModelID: { _ in throw specific })
        #expect(throws: specific) { _ = try aliased.extractionModel("alias") }
    }

    @Test func rejectsUnsupportedModelVersionsOnDirectAndRegistryRoutes() async {
        let model = ExtractionAliasModel(id: "invalid", version: "v3")
        let provider = AICustomProvider(extractionModels: ["invalid": .model(model)])
        let registry = createProviderRegistry(["provider": provider])
        let error = AIError.invalidArgument(argument: "model", message:
            "Extraction model 'mock-provider/invalid' uses unsupported specification version 'v3'; expected 'v4'.")
        #expect(throws: error) { _ = try provider.extractionModel("invalid") }
        #expect(throws: error) { _ = try registry.extractionModel("provider:invalid") }
        await #expect(throws: AIError.invalidArgument(argument: "model", message: "Extraction requires an ExtractionModelV4 implementation.")) {
            _ = try await AI.experimentalExtract(model: model, state: .text("Invoice from Acme."), fields: ["vendor": .init(type: .text)])
        }
    }
}

private final class ExtractionAliasModel: AIExtractionModelV4 {
    let modelID: String
    let specificationVersion: String
    let providerID = "mock-provider"
    let supportedFieldTypes: [AIExtractionFieldType] = [.text]

    init(id: String, version: String = "v4") {
        modelID = id
        specificationVersion = version
    }

    func doExtract(_ options: AIExtractionModelV4CallOptions) async throws -> AIExtractionModelV4Result {
        .init(answers: ["vendor": .init(type: .text, value: "Acme")], usage: .init(inputTokens: 10, outputTokens: 2))
    }
}
