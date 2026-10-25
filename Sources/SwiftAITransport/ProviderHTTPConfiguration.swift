import Foundation
import SwiftAIProvider

/// Shared HTTP mechanics for provider-owned configurations. Wire options and
/// model routing stay in the provider package; errors may use its own policy.
public protocol AIProviderHTTPConfiguration: Sendable {
    var http: AIProviderHTTPClient { get set }
    func httpStatusError(_ response: AIHTTPResponse) -> AIError
}

public extension AIProviderHTTPConfiguration {
    var providerID: String { http.providerID }
    var headers: [String: String] { http.headers }
    var transport: any AITransport { http.transport }
    var requestModelID: String? { http.requestModelID }
    var url: @Sendable (String, String) throws -> URL { http.url }

    func withProviderID(_ providerID: String) -> Self {
        var copy = self; copy.http.providerID = providerID; return copy
    }

    func withRequestModelID(_ modelID: String) -> Self {
        var copy = self; copy.http.requestModelID = modelID; return copy
    }

    func request(path: String, modelID: String, body: JSONValue, headers: [String: String] = [:],
                 abortSignal: AIAbortSignal? = nil) throws -> AIHTTPRequest {
        try http.request(path: path, modelID: modelID, body: body, headers: headers, abortSignal: abortSignal)
    }

    func rawRequest(path: String, modelID: String, body: Data, contentType: String?, headers: [String: String] = [:],
                    abortSignal: AIAbortSignal? = nil) throws -> AIHTTPRequest {
        try http.rawRequest(path: path, modelID: modelID, body: body, contentType: contentType, headers: headers, abortSignal: abortSignal)
    }

    func streamRequest(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        try await http.streamRequest(request)
    }

    func sendJSONResponse(path: String, modelID: String, body: JSONValue, headers: [String: String] = [:],
                          abortSignal: AIAbortSignal? = nil) async throws -> (json: JSONValue, response: AIHTTPResponse) {
        let response = try await transport.send(request(path: path, modelID: modelID, body: body, headers: headers, abortSignal: abortSignal))
        guard (200..<300).contains(response.statusCode) else { throw httpStatusError(response) }
        return (try response.jsonValue(), response)
    }

    func sendJSON(path: String, modelID: String, body: JSONValue, headers: [String: String] = [:],
                  abortSignal: AIAbortSignal? = nil) async throws -> JSONValue {
        try await sendJSONResponse(path: path, modelID: modelID, body: body, headers: headers, abortSignal: abortSignal).json
    }

    func httpStatusError(_ response: AIHTTPResponse) -> AIError {
        apiCallError(provider: providerID, response: response)
    }
}
