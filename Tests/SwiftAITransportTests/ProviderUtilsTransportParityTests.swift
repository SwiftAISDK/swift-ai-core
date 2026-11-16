import Foundation
import Testing
import SwiftAIProvider
@testable import SwiftAITransport

// Translations of @ai-sdk/provider-utils@5.0.81 transport-level helper tests:
// without-trailing-slash, validate-base-url, validate-download-url,
// encode-path-segment, is-valid-hostname-part, is-same-origin,
// normalize-headers and with-user-agent-suffix.

@Test func withoutTrailingSlashRemovesOneTrailingSlashLikeUpstream() {
    #expect(withoutTrailingSlash("https://example.com/") == "https://example.com")
    #expect(withoutTrailingSlash("") == "")
    // `url.replace(/\/$/, '')` removes a single slash only.
    #expect(withoutTrailingSlash("https://example.com/v1//") == "https://example.com/v1/")
    #expect(withoutTrailingSlash("https://example.com/v1") == "https://example.com/v1")
}

@Test func validateBaseURLMatchesUpstream() throws {
    #expect(try validateBaseURL("https://example.com/") == "https://example.com/")
    #expect(try validateBaseURL(nil) == nil)
    for baseURL in ["", "   "] {
        #expect(throws: AIError.invalidArgument(argument: "baseURL", message: "baseURL must be a non-empty string.")) {
            try validateBaseURL(baseURL)
        }
    }
}

private let upstreamAllowedDownloadURLs = [
    "https://example.com/image.png", "http://example.com/image.png", "https://8.8.8.8/file",
    "https://example.com:8080/file", "data:text/plain;base64,aGVsbG8=", "http://172.15.0.1/file",
    "http://172.32.0.1/file", "http://192.0.3.1/file", "http://198.51.101.1/file", "http://203.0.114.1/file",
    "http://[3fff:1000::1]/file", "http://[::ffff:8.8.8.8]/file", "https://example.com./image.png",
    "http://[64:ff9b::8.8.8.8]/file", "http://[2606:4700::1]/file", "http://100.63.0.1/file",
    "http://100.128.0.1/file", "https://internal.example.com/file", "https://service.internal.example.com/file",
    "https://service.notinternal/file", "https://example.com/service.internal"
]

private let upstreamBlockedDownloadURLs = [
    "file:///etc/passwd", "ftp://example.com/file", "javascript:alert(1)", "not-a-url",
    "http://localhost/file", "http://localhost:3000/file", "http://myhost.local/file", "http://app.localhost/file",
    "http://127.0.0.1/file", "http://127.255.0.1/file", "http://10.0.0.1/file", "http://172.16.0.1/file",
    "http://172.31.255.255/file", "http://192.168.1.1/file", "http://169.254.169.254/latest/meta-data/",
    "http://0.0.0.0/file", "http://224.0.0.1/file", "http://239.255.255.250/file", "http://192.0.2.1/file",
    "http://198.51.100.1/file", "http://203.0.113.1/file", "http://[::1]/file", "http://[::]/file",
    "http://[fc00::1]/file", "http://[fd12::1]/file", "http://[fe80::1]/file", "http://[2001:db8::1]/file",
    "http://[3fff::1]/file", "http://[3fff:fff::1]/file", "http://[::ffff:127.0.0.1]/file",
    "http://[::ffff:10.0.0.1]/file", "http://[::ffff:169.254.169.254]/file", "http://localhost./file",
    "http://myhost.local./file", "http://app.localhost./file", "http://2130706433/file", "http://0x7f000001/file",
    "http://0177.0.0.1/file", "http://[::127.0.0.1]/file", "http://[::ffff:0:127.0.0.1]/file",
    "http://[64:ff9b::127.0.0.1]/file", "http://[64:ff9b::169.254.169.254]/file",
    "http://[64:ff9b:1::169.254.169.254]/file", "http://100.64.0.1/file", "http://100.127.255.255/file",
    "http://198.18.0.1/file", "http://198.19.255.255/file", "http://192.0.0.1/file", "http://240.0.0.1/file",
    "http://255.255.255.255/file", "http://[fec0::1]/file", "http://[ff02::1]/file",
    "http://metadata.google.internal/file", "https://service.namespace.internal/file", "https://SERVICE.INTERNAL/file",
    "https://service.internal./file", "http://service.internal:8080/file"
]

@Test(arguments: upstreamAllowedDownloadURLs)
func validateDownloadURLAllowsUpstreamAllowedURL(_ url: String) {
    #expect(throws: Never.self) { try validateDownloadURL(url) }
}

@Test(arguments: upstreamBlockedDownloadURLs)
func validateDownloadURLBlocksUpstreamBlockedURL(_ url: String) {
    #expect((try? validateDownloadURL(url)) == nil)
}

@Test func encodePathSegmentMatchesUpstreamCases() throws {
    let cases: [(String, String)] = [
        ("job-123", "job-123"),
        ("abc/../../internal", "abc%2F..%2F..%2Finternal"),
        (".", "%252E"),
        ("..", "%252E%252E"),
        ("%2e%2e", "%252e%252e"),
        ("%2F", "%252F"),
        ("a?admin=true#fragment", "a%3Fadmin%3Dtrue%23fragment"),
        ("a\\..\\internal", "a%5C..%5Cinternal"),
        ("café", "caf%C3%A9"),
        ("a b", "a%20b"),
        ("", "")
    ]
    for (value, expected) in cases {
        let encoded = encodePathSegment(value)
        #expect(encoded == expected)
        let url = try #require(URL(string: "https://example.com/v1/jobs/\(encoded)/result"))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/v1/jobs/\(expected)/result")
        #expect(url.query == nil)
        #expect(url.fragment == nil)
    }

    let path = "operations/../internal?x#y".split(separator: "/", omittingEmptySubsequences: false)
        .map { encodePathSegment(String($0)) }
        .joined(separator: "/")
    let url = try #require(URL(string: "https://example.com/v1/\(path)"))
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/v1/operations/%252E%252E/internal%3Fx%23y")
}

@Test func isValidHostnamePartMatchesUpstreamCases() {
    for value in ["a", "0", "us-east-1", "MY-resource", "global", String(repeating: "a", count: 63)] {
        #expect(isValidHostnamePart(value), "accepts \(value)")
    }
    for value in [
        "", String(repeating: "a", count: 64), "-a", "a-", "a.b", "a_b", "é", "user@internal:8080/#",
        "evil.example.com/#", "169.254.169.254:80/x#", "us-east-1/../..", "us east 1", "a\n", "a\r", "a\t", "a\0", "%61"
    ] {
        #expect(!isValidHostnamePart(value), "rejects \(value.debugDescription)")
    }
}

@Test func isSameOriginMatchesUpstreamCases() {
    #expect(isSameOrigin("https://api.example.com/v1/file", "https://api.example.com"))
    #expect(isSameOrigin("https://api.example.com/a?x=1", "https://api.example.com/b"))
    #expect(!isSameOrigin("https://cdn.evil.com/file", "https://api.example.com"))
    #expect(!isSameOrigin("http://api.example.com/file", "https://api.example.com"))
    #expect(!isSameOrigin("https://api.example.com:8443/file", "https://api.example.com"))
    #expect(!isSameOrigin("not-a-url", "https://api.example.com"))
    #expect(!isSameOrigin("https://api.example.com/file", "not-a-url"))
}

@Test func normalizeHeadersMatchesUpstreamCases() {
    #expect(normalizeHeaders(nil as [String: String?]?) == [:])
    #expect(normalizeHeaders(["Authorization": "Bearer token", "X-Feature": "beta"]) == [
        "authorization": "Bearer token", "x-feature": "beta"
    ])
    #expect(normalizeHeaderEntries([("Authorization", "Bearer token"), ("X-Feature", "beta"), ("X-Ignore", nil)]) == [
        "authorization": "Bearer token", "x-feature": "beta"
    ])
    #expect(normalizeHeaders(["Authorization": "Bearer token", "X-Feature": nil, "Content-Type": "application/json"]) == [
        "authorization": "Bearer token", "content-type": "application/json"
    ])
    #expect(normalizeHeaders([String: String]()) == [:])
    #expect(normalizeHeaders(["CONTENT-TYPE": "application/json", "X-CUSTOM-HEADER": "test-value"]) == [
        "content-type": "application/json", "x-custom-header": "test-value"
    ])
}

@Test func withUserAgentSuffixMatchesUpstreamCases() {
    var result = withUserAgentSuffix(
        ["content-type": "application/json", "authorization": "Bearer token123"],
        "ai-sdk/0.0.0-test", "provider/test-openai"
    )
    #expect(result == [
        "user-agent": "ai-sdk/0.0.0-test provider/test-openai",
        "content-type": "application/json",
        "authorization": "Bearer token123"
    ])

    result = withUserAgentSuffix(["user-agent": "TestApp/0.0.0-test", "accept": "application/json"], "ai-sdk/0.0.0-test", "provider/test-anthropic")
    #expect(result["user-agent"] == "TestApp/0.0.0-test ai-sdk/0.0.0-test provider/test-anthropic")
    #expect(result["accept"] == "application/json")

    let optionalHeaders: [String: String?] = [
        "content-type": "application/json", "authorization": nil, "user-agent": "TestApp/0.0.0-test",
        "accept": "application/json", "cache-control": nil
    ]
    result = withUserAgentSuffix(optionalHeaders, "ai-sdk/0.0.0-test")
    #expect(result == [
        "user-agent": "TestApp/0.0.0-test ai-sdk/0.0.0-test",
        "content-type": "application/json",
        "accept": "application/json"
    ])

    result = withUserAgentSuffix(["Authorization": "Bearer token123", "X-Custom": "value"], "ai-sdk/0.0.0-test")
    #expect(result == ["authorization": "Bearer token123", "x-custom": "value", "user-agent": "ai-sdk/0.0.0-test"])
}

@Test func providerHTTPClientDefaultsYieldToCallerHeadersInAnyCase() throws {
    let client = AIProviderHTTPClient(
        providerID: "test",
        headers: ["Authorization": "Bearer key"],
        transport: URLSessionTransport.shared,
        url: { _, path in URL(string: "https://example.com\(path)")! }
    )

    let request = try client.rawRequest(
        path: "/upload",
        modelID: "model",
        body: Data(),
        contentType: "application/json",
        headers: ["Content-Type": "multipart/form-data; boundary=x", "User-Agent": "App/1.0"]
    )
    #expect(request.headers == [
        "Authorization": "Bearer key",
        "Content-Type": "multipart/form-data; boundary=x",
        "User-Agent": "App/1.0"
    ])

    let defaults = try client.rawRequest(path: "/json", modelID: "model", body: Data(), contentType: "application/json")
    #expect(defaults.headers["content-type"] == "application/json")
    #expect(defaults.headers["user-agent"] == userAgent("test"))
}
