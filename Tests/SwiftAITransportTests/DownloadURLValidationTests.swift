import Foundation
import Testing
@testable import SwiftAITransport
import SwiftAIProvider

@Test func downloadURLValidationAllowsPublicHTTPAndDataURLs() throws {
    let allowed = [
        "https://example.com/image.png",
        "http://example.com/image.png",
        "https://example.com:8080/file",
        "data:text/plain;base64,aGVsbG8=",
        "http://172.15.0.1/file",
        "http://172.32.0.1/file",
        "http://100.63.0.1/file",
        "http://100.128.0.1/file",
        "http://198.20.0.1/file"
    ]

    for url in allowed {
        #expect(try validateDownloadURL(url).absoluteString == url)
    }
}

@Test func downloadURLValidationBlocksUnsafeSchemesAndMalformedURLs() {
    let blocked = [
        "file:///etc/passwd",
        "ftp://example.com/file",
        "javascript:alert(1)",
        "not-a-url"
    ]

    for url in blocked {
        #expect(throws: Error.self) {
            _ = try validateDownloadURL(url)
        }
    }
}

@Test func downloadURLValidationBlocksLocalHostnames() {
    let blocked = [
        "http://localhost/file",
        "http://localhost./file",
        "http://localhost:3000/file",
        "http://myhost.local/file",
        "http://myhost.local./file",
        "http://app.localhost/file",
        "http://app.localhost./file"
    ]

    for url in blocked {
        #expect(throws: Error.self) {
            _ = try validateDownloadURL(url)
        }
    }
}

@Test func downloadURLValidationBlocksPrivateIPv4Ranges() {
    let blocked = [
        "http://127.0.0.1/file",
        "http://127.255.0.1/file",
        "http://10.0.0.1/file",
        "http://172.16.0.1/file",
        "http://172.31.255.255/file",
        "http://192.168.1.1/file",
        "http://100.64.0.1/file",
        "http://100.127.255.255/file",
        "http://192.0.0.1/file",
        "http://192.0.0.8/file",
        "http://192.0.2.1/file",
        "http://198.18.0.1/file",
        "http://198.19.255.255/file",
        "http://198.51.100.1/file",
        "http://203.0.113.1/file",
        "http://224.0.0.1/file",
        "http://240.0.0.1/file",
        "http://255.255.255.255/file",
        "http://169.254.169.254/latest/meta-data/",
        "http://0.0.0.0/file"
    ]

    for url in blocked {
        #expect(throws: Error.self) {
            _ = try validateDownloadURL(url)
        }
    }
}

@Test func downloadURLValidationBlocksPrivateIPv6Ranges() {
    let blocked = [
        "http://[::1]/file",
        "http://[0:0:0:0:0:0:0:1]/file",
        "http://[::]/file",
        "http://[fc00::1]/file",
        "http://[fd12::1]/file",
        "http://[fe80::1]/file",
        "http://[fec0::1]/file",
        "http://[ff02::1]/file",
        "http://[2001:db8::1]/file",
        "http://[3fff::1]/file",
        "http://[::127.0.0.1]/file",
        "http://[::ffff:127.0.0.1]/file",
        "http://[::ffff:0:127.0.0.1]/file",
        "http://[::ffff:10.0.0.1]/file",
        "http://[::ffff:169.254.169.254]/file",
        "http://[::ffff:203.0.113.1]/file",
        "http://[::ffff:7f00:1]/file",
        "http://[64:ff9b::127.0.0.1]/file",
        "http://[64:ff9b::169.254.169.254]/file",
        "http://[64:ff9b::203.0.113.1]/file",
        "http://[64:ff9b:1::169.254.169.254]/file"
    ]

    for url in blocked {
        #expect(throws: Error.self) {
            _ = try validateDownloadURL(url)
        }
    }
}

@Test func downloadURLValidationBlocksNonDottedIPv4NotationsLikeUpstream() {
    let blocked = [
        "http://2130706433/file",
        "http://0x7f000001/file",
        "http://0177.0.0.1/file"
    ]

    for url in blocked {
        #expect(throws: Error.self) {
            _ = try validateDownloadURL(url)
        }
    }
}

@Test func downloadURLRejectsUnsafeFinalRedirectURL() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 200,
        headers: ["content-type": "image/png"],
        body: Data("png".utf8),
        url: URL(string: "http://127.0.0.1/private.png")!
    ))

    await #expect(throws: AIError.self) {
        _ = try await downloadURL("https://example.com/image.png", transport: transport)
    }

    let requests = await transport.requests()
    #expect(requests.count == 1)
    #expect(requests[0].url.absoluteString == "https://example.com/image.png")
    #expect(requests[0].maxResponseBytes == AIDefaultMaxDownloadSize)
}

@Test func downloadURLValidatesInitialURLBeforeFetchingLikeUpstream() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 200,
        headers: ["content-type": "image/png"],
        body: Data("should-not-fetch".utf8)
    ))

    await #expect(throws: AIError.self) {
        _ = try await downloadURL("http://localhost/file", transport: transport)
    }

    let requests = await transport.requests()
    #expect(requests.isEmpty)
}

@Test func downloadURLValidatesRedirectLocationBeforeFetchingNextHop() async throws {
    let transport = RecordingTransport(responses: [
        AIHTTPResponse(statusCode: 302, headers: ["location": "http://127.0.0.1/private.png"]),
        AIHTTPResponse(statusCode: 200, headers: ["content-type": "image/png"], body: Data("should-not-fetch".utf8))
    ])

    await #expect(throws: AIError.self) {
        _ = try await downloadURL("https://example.com/image.png", transport: transport)
    }

    let requests = await transport.requests()
    #expect(requests.count == 1)
    #expect(requests[0].url.absoluteString == "https://example.com/image.png")
    #expect(requests[0].followRedirects == false)
}

@Test func downloadURLFollowsSafeRedirectsWithValidation() async throws {
    let transport = RecordingTransport(responses: [
        AIHTTPResponse(statusCode: 302, headers: ["location": "/cdn/image.png"]),
        AIHTTPResponse(statusCode: 200, headers: ["content-type": "image/png"], body: Data("png".utf8), url: URL(string: "https://example.com/cdn/image.png")!)
    ])

    let response = try await downloadURL("https://example.com/image.png", transport: transport)

    #expect(response.body == Data("png".utf8))
    let requests = await transport.requests()
    #expect(requests.map { $0.url.absoluteString } == [
        "https://example.com/image.png",
        "https://example.com/cdn/image.png"
    ])
    #expect(requests.allSatisfy { $0.followRedirects == false })
}

@Test func downloadURLRejectsAfterRedirectLimitLikeUpstream() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 302,
        headers: ["location": "https://example.com/next"]
    ))

    await #expect(throws: AIDownloadError.self) {
        _ = try await downloadURL("https://example.com/start", transport: transport)
    }

    let requests = await transport.requests()
    #expect(requests.count == 11)
    #expect(requests.allSatisfy { $0.followRedirects == false })
}

@Test func downloadURLRejectsBodiesOverCustomSizeLimit() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 200,
        headers: ["content-type": "image/png"],
        body: Data("too-large".utf8),
        url: URL(string: "https://example.com/image.png")!
    ))

    await #expect(throws: AIDownloadError.self) {
        _ = try await downloadURL("https://example.com/image.png", transport: transport, maxBytes: 3)
    }

    let requests = await transport.requests()
    #expect(requests.count == 1)
    #expect(requests[0].maxResponseBytes == 3)
}
