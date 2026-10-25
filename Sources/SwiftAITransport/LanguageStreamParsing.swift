import Foundation
import SwiftAIProvider


public func serverSentEvents(from body: AsyncThrowingStream<Data, Error>) -> IncrementalServerSentEventSequence {
    IncrementalServerSentEventSequence(body: body)
}

public struct IncrementalServerSentEventSequence: AsyncSequence {
    public typealias Element = ServerSentEvent

    let body: AsyncThrowingStream<Data, Error>

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bodyIterator: body.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var bodyIterator: AsyncThrowingStream<Data, Error>.AsyncIterator
        var parser = ServerSentEventParser()
        var pendingEvents: [ServerSentEvent] = []
        var pendingIndex = 0
        var reachedEnd = false

        public mutating func next() async throws -> ServerSentEvent? {
            while true {
                if pendingIndex < pendingEvents.count {
                    defer { pendingIndex += 1 }
                    return pendingEvents[pendingIndex]
                }
                pendingEvents.removeAll(keepingCapacity: true)
                pendingIndex = 0

                guard !reachedEnd else { return nil }
                if let chunk = try await bodyIterator.next() {
                    pendingEvents = try parser.append(chunk)
                } else {
                    reachedEnd = true
                    pendingEvents = try parser.finish()
                }
            }
        }
    }
}

public func bufferedHTTPResponse(
    from response: AIHTTPStreamResponse,
    request: AIHTTPRequest
) async throws -> AIHTTPResponse {
    let body = try await readResponseWithSizeLimit(
        response: response,
        url: request.url.absoluteString,
        maxBytes: request.maxResponseBytes ?? AIDefaultMaxDownloadSize
    )
    return AIHTTPResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        body: body,
        url: request.url
    )
}

public func httpResponseHead(
    from response: AIHTTPStreamResponse,
    request: AIHTTPRequest
) -> AIHTTPResponse {
    AIHTTPResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        url: request.url
    )
}