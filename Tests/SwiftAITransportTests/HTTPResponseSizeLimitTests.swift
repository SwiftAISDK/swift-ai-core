import Foundation
import Testing
@testable import SwiftAITransport
import SwiftAIProvider

@Test func readResponseWithSizeLimitReadsResponseWithinLimitSuccessfully() async throws {
    let data = Data([1, 2, 3, 4, 5, 6, 7, 8])
    let response = sizeLimitResponse(body: data, contentLength: "8")

    let result = try await readResponseWithSizeLimit(
        response: response,
        url: "http://example.com/file",
        maxBytes: 100
    )

    #expect(result == data)
}

@Test func readResponseWithSizeLimitRejectsContentLengthOverLimitEarly() async {
    let response = sizeLimitResponse(body: Data(repeating: 0, count: 10), contentLength: "1000")

    await expectDownloadError(containing: "Content-Length: 1000") {
        _ = try await readResponseWithSizeLimit(
            response: response,
            url: "http://example.com/large",
            maxBytes: 100
        )
    }
}

@Test func readResponseWithSizeLimitAbortsWhenStreamedBytesExceedLimit() async {
    let response = sizeLimitResponse(body: Data(repeating: 42, count: 200))

    await expectDownloadError(containing: "exceeded maximum size of 50 bytes") {
        _ = try await readResponseWithSizeLimit(
            response: response,
            url: "http://example.com/streaming",
            maxBytes: 50
        )
    }
}

@Test func readResponseWithSizeLimitHandlesLyingContentLength() async {
    let response = sizeLimitResponse(body: Data(repeating: 42, count: 200), contentLength: "10")

    await expectDownloadError(containing: "exceeded maximum size of 50 bytes") {
        _ = try await readResponseWithSizeLimit(
            response: response,
            url: "http://example.com/liar",
            maxBytes: 50
        )
    }
}

@Test func readResponseWithSizeLimitHandlesEmptyBody() async throws {
    let response = sizeLimitResponse(body: Data())

    let result = try await readResponseWithSizeLimit(
        response: response,
        url: "http://example.com/empty",
        maxBytes: 100
    )

    #expect(result == Data())
}

@Test func readResponseWithSizeLimitRespectsCustomMaxBytes() async throws {
    let data = Data(repeating: 1, count: 10)
    let response = sizeLimitResponse(body: data, contentLength: "10")

    let result = try await readResponseWithSizeLimit(
        response: response,
        url: "http://example.com/custom",
        maxBytes: 10
    )

    #expect(result == data)
}

@Test func readResponseWithSizeLimitRejectsAtExactBoundaryPlusOne() async {
    let response = sizeLimitResponse(body: Data(repeating: 1, count: 11))

    await expectDownloadError(containing: "exceeded maximum size of 10 bytes") {
        _ = try await readResponseWithSizeLimit(
            response: response,
            url: "http://example.com/boundary",
            maxBytes: 10
        )
    }
}

@Test func readResponseWithSizeLimitParsesContentLengthLikeUpstream() async {
    let response = sizeLimitResponse(body: Data(repeating: 0, count: 10), contentLength: "1000 bytes")

    await expectDownloadError(containing: "Content-Length: 1000") {
        _ = try await readResponseWithSizeLimit(
            response: response,
            url: "http://example.com/large",
            maxBytes: 100
        )
    }
}

@Test func urlSessionTransportAppliesDefaultResponseLimitLikeProviderUtils501() async throws {
    OversizedResponseURLProtocol.handler = { request in
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": String(AIDefaultMaxDownloadSize + 1)]
        )!
        return (response, Data("{}".utf8))
    }
    defer { OversizedResponseURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OversizedResponseURLProtocol.self]
    let transport = URLSessionTransport(session: URLSession(configuration: configuration))

    await expectDownloadError(containing: "Content-Length: \(AIDefaultMaxDownloadSize + 1)") {
        _ = try await transport.send(AIHTTPRequest(
            method: "GET",
            url: URL(string: "https://example.com/oversized-json")!
        ))
    }
}

private func sizeLimitResponse(body: Data, contentLength: String? = nil) -> AIHTTPStreamResponse {
    var headers: [String: String] = [:]
    if let contentLength {
        headers["content-length"] = contentLength
    }

    return AIHTTPStreamResponse(
        statusCode: 200,
        headers: headers,
        body: AsyncThrowingStream { continuation in
            let chunkSize = 4
            var offset = 0
            while offset < body.count {
                let end = min(offset + chunkSize, body.count)
                continuation.yield(body.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    )
}

private func expectDownloadError(
    containing expectedMessage: String,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected AIDownloadError.")
    } catch let error as AIDownloadError {
        #expect(error.message.contains(expectedMessage))
    } catch {
        Issue.record("Expected AIDownloadError, got \(error).")
    }
}

private final class OversizedResponseURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
