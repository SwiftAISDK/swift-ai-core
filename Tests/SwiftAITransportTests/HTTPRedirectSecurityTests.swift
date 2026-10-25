import Foundation
import Testing
@testable import SwiftAITransport
import SwiftAIProvider

@Test func downloadURLPreservesCredentialsAcrossSameOriginRedirects() async throws {
    let transport = RedirectSecurityTransport(responses: [
        AIHTTPResponse(statusCode: 302, headers: ["location": "/next"]),
        AIHTTPResponse(statusCode: 200, body: Data("done".utf8))
    ])

    _ = try await downloadURL(
        "https://api.example.com/start",
        transport: transport,
        headers: ["Authorization": "Bearer secret", "User-Agent": "SwiftAISDK/Test"]
    )

    let requests = await transport.requests()
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { !$0.followRedirects })
    #expect(requests[1].url.absoluteString == "https://api.example.com/next")
    #expect(requests[1].headers["Authorization"] == "Bearer secret")
}

@Test func downloadURLStripsCredentialsAcrossOriginsAndNeverAddsThemBack() async throws {
    let transport = RedirectSecurityTransport(responses: [
        AIHTTPResponse(statusCode: 302, headers: ["location": "https://cdn.example.net/signed"]),
        AIHTTPResponse(statusCode: 307, headers: ["location": "https://api.example.com/final"]),
        AIHTTPResponse(statusCode: 200, body: Data("done".utf8))
    ])

    _ = try await downloadURL(
        "https://api.example.com/start",
        transport: transport,
        headers: [
            "Authorization": "Bearer secret",
            "X-Custom-Secret": "do-not-forward",
            "User-Agent": "SwiftAISDK/Test"
        ]
    )

    let requests = await transport.requests()
    #expect(requests.count == 3)
    #expect(requests[1].headers == ["user-agent": "SwiftAISDK/Test"])
    #expect(requests[2].headers == ["user-agent": "SwiftAISDK/Test"])
    #expect(requests.allSatisfy { !$0.followRedirects })
}

@Test func downloadURLRejectsPrivateRedirectTargetsBeforeSendingTheNextRequest() async throws {
    let transport = RedirectSecurityTransport(responses: [
        AIHTTPResponse(statusCode: 302, headers: ["location": "http://127.0.0.1/admin"])
    ])

    await #expect(throws: AIError.self) {
        _ = try await downloadURL(
            "https://api.example.com/start",
            transport: transport,
            headers: ["Authorization": "Bearer secret"]
        )
    }

    #expect(await transport.requests().count == 1)
}

@Test func downloadAndStreamURLSanitizeBlockedHeadersBeforeTheFirstRequest() async throws {
    let bufferedTransport = RedirectSecurityTransport(responses: [
        AIHTTPResponse(statusCode: 200, body: Data("done".utf8))
    ])
    let streamingTransport = RedirectStreamingSecurityTransport(responses: [
        redirectSecurityStreamResponse(statusCode: 200)
    ])
    let headers = redirectSecurityHeadersIncludingBlockedNames()

    _ = try await downloadURL(
        "https://api.example.com/start",
        transport: bufferedTransport,
        headers: headers
    )
    _ = try await streamDownloadURL(
        "https://api.example.com/start",
        transport: streamingTransport,
        headers: headers
    )

    let bufferedRequest = try #require(await bufferedTransport.requests().first)
    let streamingRequest = try #require(await streamingTransport.requests().first)
    for request in [bufferedRequest, streamingRequest] {
        let normalized = normalizeHeaders(request.headers)
        #expect(redirectSecurityBlockedHeaderNames.count == 20)
        #expect(redirectSecurityBlockedHeaderNames.allSatisfy { normalized[$0] == nil })
        #expect(normalized["authorization"] == "Bearer secret")
        #expect(normalized["x-key"] == "provider-secret")
        #expect(normalized["user-agent"] == "SwiftAISDK/Test")
    }
}

@Test func streamDownloadURLCancelsRedirectBodyBeforeFollowingNextHop() async throws {
    let cancellation = RedirectBodyCancellationRecorder()
    let transport = RedirectStreamingSecurityTransport(responses: [
        redirectSecurityStreamResponse(
            statusCode: 302,
            headers: ["location": "/next"],
            cancelBody: { cancellation.record() }
        ),
        redirectSecurityStreamResponse(statusCode: 200)
    ])

    _ = try await streamDownloadURL(
        "https://api.example.com/start",
        transport: transport
    )

    #expect(cancellation.count == 1)
    #expect(await transport.requests().map(\.url.absoluteString) == [
        "https://api.example.com/start",
        "https://api.example.com/next"
    ])
}

@Test func streamDownloadURLCancelsRedirectBodyBeforeRejectingPrivateTarget() async throws {
    let cancellation = RedirectBodyCancellationRecorder()
    let transport = RedirectStreamingSecurityTransport(responses: [
        redirectSecurityStreamResponse(
            statusCode: 302,
            headers: ["location": "http://127.0.0.1/admin"],
            cancelBody: { cancellation.record() }
        )
    ])

    await #expect(throws: AIError.self) {
        _ = try await streamDownloadURL(
            "https://api.example.com/start",
            transport: transport
        )
    }

    #expect(cancellation.count == 1)
    #expect(await transport.requests().count == 1)
}

private actor RedirectSecurityTransport: FixtureDownloadTransport {
    private var scriptedResponses: [AIHTTPResponse]
    private var recordedRequests: [AIHTTPRequest] = []

    init(responses: [AIHTTPResponse]) {
        scriptedResponses = responses
    }

    func requests() -> [AIHTTPRequest] { recordedRequests }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        recordedRequests.append(request)
        guard !scriptedResponses.isEmpty else {
            throw AIError.invalidResponse(provider: "redirect-test", message: "Missing scripted response.")
        }
        return scriptedResponses.removeFirst()
    }
}

private actor RedirectStreamingSecurityTransport: FixtureStreamingDownloadTransport {
    private var scriptedResponses: [AIHTTPStreamResponse]
    private var recordedRequests: [AIHTTPRequest] = []

    init(responses: [AIHTTPStreamResponse]) {
        scriptedResponses = responses
    }

    func requests() -> [AIHTTPRequest] { recordedRequests }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        throw AIError.invalidResponse(
            provider: "redirect-stream-test",
            message: "Buffered transport path should not be used."
        )
    }

    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        recordedRequests.append(request)
        guard !scriptedResponses.isEmpty else {
            throw AIError.invalidResponse(
                provider: "redirect-stream-test",
                message: "Missing scripted response."
            )
        }
        return scriptedResponses.removeFirst()
    }
}

private final class RedirectBodyCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.withLock { recordedCount }
    }

    func record() {
        lock.withLock { recordedCount += 1 }
    }
}

private func redirectSecurityStreamResponse(
    statusCode: Int,
    headers: [String: String] = [:],
    cancelBody: @escaping @Sendable () -> Void = {}
) -> AIHTTPStreamResponse {
    AIHTTPStreamResponse(
        statusCode: statusCode,
        headers: headers,
        body: AsyncThrowingStream { continuation in
            continuation.finish()
        },
        cancelBody: cancelBody
    )
}

private let redirectSecurityBlockedHeaderNames = [
    "connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade",
    "host",
    "forwarded", "proxy-authorization", "via", "x-forwarded-for", "x-forwarded-host",
    "x-forwarded-proto", "x-real-ip",
    "metadata", "metadata-flavor", "x-aws-ec2-metadata-token", "x-metadata-token",
    "cookie", "set-cookie"
]

private func redirectSecurityHeadersIncludingBlockedNames() -> [String: String] {
    [
        "CoNnEcTiOn": "blocked",
        "KEEP-ALIVE": "blocked",
        "Te": "blocked",
        "TRAILER": "blocked",
        "Transfer-Encoding": "blocked",
        "UPGRADE": "blocked",
        "Host": "metadata.internal",
        "Forwarded": "for=127.0.0.1",
        "Proxy-Authorization": "blocked",
        "Via": "blocked",
        "X-Forwarded-For": "127.0.0.1",
        "x-FORWARDED-host": "metadata.internal",
        "X-Forwarded-Proto": "http",
        "X-Real-IP": "127.0.0.1",
        "Metadata": "true",
        "Metadata-Flavor": "Google",
        "X-Aws-Ec2-Metadata-Token": "blocked",
        "X-Metadata-Token": "blocked",
        "Cookie": "session=secret",
        "Set-Cookie": "session=secret",
        "Authorization": "Bearer secret",
        "X-Key": "provider-secret",
        "User-Agent": "SwiftAISDK/Test"
    ]
}
