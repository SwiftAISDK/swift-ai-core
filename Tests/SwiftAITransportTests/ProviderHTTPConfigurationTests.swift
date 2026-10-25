import Foundation
import Testing
import SwiftAIProvider
import SwiftAITransport

private struct HTTPConfigurationFixture: AIProviderHTTPConfiguration {
    var http: AIProviderHTTPClient
}

private struct HTTPConfigurationWithErrorPolicy: AIProviderHTTPConfiguration {
    var http: AIProviderHTTPClient
    func httpStatusError(_ response: AIHTTPResponse) -> AIError {
        .invalidResponse(provider: providerID, message: "adapter failure \(response.statusCode)")
    }
}

@Test func providerHTTPConfigurationPreservesRoutingHeadersAbortAndCopies() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: [:], body: Data("{\"ok\":true}".utf8)))
    let original = HTTPConfigurationFixture(http: AIProviderHTTPClient(providerID: "fixture", headers: ["x-static": "kept"],
        transport: transport, dynamicHeaders: { ["x-dynamic": "fresh"] },
        url: { model, path in URL(string: "https://example.com/\(model)\(path)")! }))
    let copy = original.withProviderID("hosted").withRequestModelID("deployment")
    let controller = AIAbortController()
    let result = try await copy.sendJSONResponse(path: "/generate", modelID: "model", body: ["prompt": "hello"],
        headers: ["x-request": "kept"], abortSignal: controller.signal)
    #expect(result.json["ok"]?.boolValue == true)
    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://example.com/deployment/generate")
    #expect(request.headers["x-static"] == "kept")
    #expect(request.headers["x-dynamic"] == "fresh")
    #expect(request.headers["x-request"] == "kept")
    controller.abort(reason: "stop")
    #expect(request.abortSignal?.isAborted == true)
    #expect(original.providerID == "fixture")
    #expect(original.requestModelID == nil)
}

@Test func providerHTTPConfigurationDispatchesAdapterFailureBeforeParsingJSON() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 503, headers: [:], body: Data("not JSON".utf8)))
    let config = HTTPConfigurationWithErrorPolicy(http: AIProviderHTTPClient(providerID: "hosted", transport: transport,
        url: { _, _ in URL(string: "https://example.com/generate")! }))
    await #expect(throws: AIError.invalidResponse(provider: "hosted", message: "adapter failure 503")) {
        try await config.sendJSON(path: "/generate", modelID: "model", body: [:])
    }
}
