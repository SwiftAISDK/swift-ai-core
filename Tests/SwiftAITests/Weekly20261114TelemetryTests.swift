import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities

private actor November14Telemetry: Telemetry.Integration {
    var events: [Telemetry.Event] = []
    var resultBodies: [JSONValue?] = []
    var errorBodies: [JSONValue?] = []
    func record(_ event: Telemetry.Event) { events.append(event) }
    func executeLanguageModelCall<Output: Sendable>(_ context: Telemetry.LanguageModelCallContext<Output>) async throws -> Output {
        do {
            let result = try await context.execute()
            if let result = result as? TextGenerationResult { resultBodies.append(result.requestMetadata.body) }
            return result
        } catch {
            if let error = error as? AIError, case let .apiCall(call) = error { errorBodies.append(call.requestBody) }
            throw error
        }
    }
}
private struct November14RedactedModel: LanguageModel {
    let providerID = "mock", modelID = "mock"
    var telemetryRedactor: AITelemetryRedactor? { { value in
        guard var object = value.objectValue else { return value }
        if object["secret"] != nil { object["secret"] = "[redacted]" }
        return .object(object)
    } }
    var fails = false
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult {
        if fails { throw AIError.apiCall(.init(provider: providerID, requestBody: ["secret": "credential"], statusCode: 400, responseBody: "bad")) }
        return .init(text: "user credential text", finishReason: "stop", rawValue: ["secret": "credential"], requestMetadata: .init(body: ["secret": "credential"]), responseMetadata: .init(body: ["secret": "credential"]))
    }
}

@Suite("Weekly20261114 provider-owned telemetry views")
struct Weekly20261114TelemetryTests {
    @Test func nestedIntegrationsSeeCopiesAndApplicationsGetOriginalResults() async throws {
        let first = November14Telemetry(), second = November14Telemetry()
        let result = try await AI.generateText(model: November14RedactedModel(), request: .init(messages: [.user("credential in user input")], tools: ["known": ["args": ["secret": "credential"]]]), telemetry: .init(integrations: [first, second]), includeResponseBody: true)
        #expect(result.rawValue == ["secret": "credential"])
        #expect(result.requestMetadata.body == ["secret": "credential"])
        #expect(result.responseMetadata.body == ["secret": "credential"])
        #expect(await first.resultBodies == [["secret": "[redacted]"]])
        #expect(await second.resultBodies == [["secret": "[redacted]"]])
        let events = await first.events
        #expect(events.first?.input?["messages"]?[0]?["content"]?[0]?["text"] == "credential in user input")
        #expect(events.first?.input?["tools"]?["known"]?["args"]?["secret"] == "[redacted]")
        #expect(events.last?.output?["rawValue"]?["secret"] == "[redacted]")
        #expect(events.last?.responseMetadata.body?["secret"] == "[redacted]")
    }

    @Test func nestedIntegrationsSeeRedactedProviderErrorsAndOriginalErrorIsRethrown() async throws {
        let first = November14Telemetry(), second = November14Telemetry()
        do {
            _ = try await AI.generateText(model: November14RedactedModel(fails: true), request: .init(messages: [.user("hello")]), retryPolicy: .none, telemetry: .init(integrations: [first, second]))
            Issue.record("Expected provider failure")
        } catch let error as AIError {
            guard case let .apiCall(call) = error else { Issue.record("Expected typed API error"); return }
            #expect(call.requestBody == ["secret": "credential"])
            #expect(call.responseBody == "bad")
        }
        #expect(await first.errorBodies == [["secret": "[redacted]"]])
        #expect(await second.errorBodies == [["secret": "[redacted]"]])
    }

    @Test func failingRedactorOmitsMetadataAndNeverTraversesApplicationData() {
        struct BrokenRedactor: Error {}
        let input: JSONValue = ["tools": ["tool": ["args": ["secret": "credential"]]], "messages": [["content": ["secret": "user"]]], "runtimeContext": ["secret": "context"]]
        let redacted = redactTelemetryCredentials(input, redactor: { _ in throw BrokenRedactor() })
        #expect(redacted["tools"]?["tool"]?["args"] == nil)
        #expect(redacted["messages"] == input["messages"])
        #expect(redacted["runtimeContext"] == input["runtimeContext"])
        #expect(input["tools"]?["tool"]?["args"]?["secret"] == "credential")
    }
}
