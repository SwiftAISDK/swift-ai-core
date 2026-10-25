import Foundation
import SwiftAITransport


actor RecordingTransport: FixtureStreamingDownloadTransport {
    private var _requests: [AIHTTPRequest] = []
    private var _sendRequests: [AIHTTPRequest] = []
    private var _streamRequests: [AIHTTPRequest] = []
    private var responses: [AIHTTPResponse]

    init(response: AIHTTPResponse) {
        self.responses = [response]
    }

    init(responses: [AIHTTPResponse]) {
        self.responses = responses
    }

    func requests() -> [AIHTTPRequest] {
        _requests
    }

    func sendRequests() -> [AIHTTPRequest] {
        _sendRequests
    }

    func streamRequests() -> [AIHTTPRequest] {
        _streamRequests
    }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        _requests.append(request)
        _sendRequests.append(request)
        return nextResponse()
    }

    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        _requests.append(request)
        _streamRequests.append(request)
        let response = nextResponse()
        return AIHTTPStreamResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: AsyncThrowingStream { continuation in
                continuation.yield(response.body)
                continuation.finish()
            }
        )
    }

    private func nextResponse() -> AIHTTPResponse {
        if responses.count > 1 {
            return responses.removeFirst()
        }
        return responses[0]
    }
}
