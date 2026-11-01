import Foundation
import Testing
@testable import SwiftAITransport
import SwiftAIProvider

private actor CredentialCounter {
    private(set) var count = 0
    func next() -> String { count += 1; return "token-\(count)" }
}

@Suite("Weekly20261101 lazy per-request credentials")
struct Weekly20261101CredentialTests {
    @Test func credentialsRotateAndHeaderOverridesStayAuthoritative() async throws {
        let counter = CredentialCounter()
        let credential = AIAsyncCredential { await counter.next() }
        let transport = RecordingTransport(responses: [.init(statusCode: 200), .init(statusCode: 200), .init(statusCode: 200)])
        let client = AIProviderHTTPClient(providerID: "test", headers: ["Authorization": "Bearer \(credential.placeholder)", "x-config": "preserved"], transport: transport, credentialResolver: credential, url: { _, _ in URL(string: "https://example.com/api")! })
        #expect(await counter.count == 0)
        for _ in 0..<2 { _ = try await client.transport.send(client.request(path: "/", modelID: "m", body: [:])) }
        _ = try await client.transport.send(client.request(path: "/", modelID: "m", body: [:], headers: ["authorization": "Bearer override"]))
        let requests = await transport.requests()
        #expect(requests.map { $0.headers.first { $0.key.lowercased() == "authorization" }?.value } == ["Bearer token-1", "Bearer token-2", "Bearer override"])
        #expect(await counter.count == 2)
        #expect(requests.allSatisfy { $0.headers["x-config"] == "preserved" })
    }

    @Test func unauthenticatedHeadersNeverCallCredentialSupplier() async throws {
        let counter = CredentialCounter()
        let credential = AIAsyncCredential { await counter.next() }
        #expect(try await credential.resolveHeaders([:]).isEmpty)
        #expect(try await credential.resolveHeaders(["Authorization": "custom"]) == ["Authorization": "custom"])
        #expect(await counter.count == 0)
    }

    @Test func supplierFailureAndAbortPreventSending() async throws {
        enum Failure: Error { case refresh }
        let credential = AIAsyncCredential { throw Failure.refresh }
        let transport = RecordingTransport(responses: [])
        var client = AIProviderHTTPClient(providerID: "test", headers: ["x-api-key": credential.placeholder], transport: transport, url: { _, _ in URL(string: "https://example.com")! })
        client.credentialResolver = credential
        await #expect(throws: Failure.refresh) {
            _ = try await client.transport.send(client.request(path: "/", modelID: "m", body: [:]))
        }
        #expect(await transport.requests().isEmpty)
        let controller = AIAbortController(); controller.abort()
        await #expect(throws: AIAbortError.self) {
            _ = try await client.transport.send(client.request(path: "/", modelID: "m", body: [:], abortSignal: controller.signal))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func asyncWebSocketHeadersResolveOnceAfterRequestOverrides() async throws {
        let counter = CredentialCounter()
        let credential = AIAsyncCredential { await counter.next() }
        let client = AIProviderHTTPClient(providerID: "test", headers: ["x-api-key": credential.placeholder], transport: RecordingTransport(responses: []), credentialResolver: credential, url: { _, _ in URL(string: "https://example.com")! })
        #expect(try await client.resolvedHeaders()["x-api-key"] == "token-1")
        #expect(try await client.resolvedHeaders(["X-Api-Key": "override"]).values.contains("override"))
        #expect(await counter.count == 1)
    }
}

private final class WeeklyBodyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}
private actor WeeklyStreamingCredentialProbe: AIStreamingTransport {
    private(set) var requests: [AIHTTPRequest] = []
    let cancellation: WeeklyBodyCancellation
    init(cancellation: WeeklyBodyCancellation) { self.cancellation = cancellation }
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse { requests.append(request); return .init(statusCode: 200) }
    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        requests.append(request)
        return .init(statusCode: 200, body: AsyncThrowingStream { continuation in continuation.yield(Data([42])); continuation.finish() }, cancelBody: { [cancellation] in cancellation.cancel() })
    }
    func streamValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse { try await stream(request) }
}

extension Weekly20261101CredentialTests {
    @Test func streamingAndUncredentialedDownloadsPreserveTheTransportContract() async throws {
        let counter = CredentialCounter()
        let credential = AIAsyncCredential { await counter.next() }
        let cancellation = WeeklyBodyCancellation()
        let base = WeeklyStreamingCredentialProbe(cancellation: cancellation)
        let transport = try #require(credential.resolvingTransport(base) as? any AIStreamingTransport)
        let response = try await transport.stream(.init(url: URL(string: "https://api.example.com/stream")!, headers: ["authorization": "Bearer \(credential.placeholder)"]))
        #expect(try await readResponseWithSizeLimit(response: response, url: "https://api.example.com/stream", maxBytes: 8) == Data([42]))
        #expect(cancellation.isCancelled)
        #expect(await counter.count == 1)
        let download = try await transport.streamValidatedDownload(.init(method: "GET", url: URL(string: "https://cdn.example.com/result")!))
        download.cancelBody()
        #expect(await counter.count == 1)
        let requests = await base.requests
        #expect(requests[0].headers["authorization"] == "Bearer token-1")
        #expect(requests[1].headers.isEmpty)
    }
}
