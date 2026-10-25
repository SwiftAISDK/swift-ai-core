import Foundation
import SwiftAIProvider

/// Shared HTTP request construction without provider routing or response policy.
public struct AIProviderHTTPClient: Sendable {
    public var providerID: String
    public var headers: [String: String]
    public var transport: any AITransport
    public var dynamicHeaders: (@Sendable () -> [String: String])?
    public var userAgentSuffix: String?
    public var requestModelID: String?
    public var url: @Sendable (String, String) throws -> URL

    public init(providerID: String, headers: [String: String] = [:], transport: any AITransport,
                dynamicHeaders: (@Sendable () -> [String: String])? = nil,
                userAgentSuffix: String? = nil, requestModelID: String? = nil,
                url: @escaping @Sendable (String, String) throws -> URL) {
        self.providerID = providerID
        self.headers = headers
        self.transport = transport
        self.dynamicHeaders = dynamicHeaders
        self.userAgentSuffix = userAgentSuffix
        self.requestModelID = requestModelID
        self.url = url
    }

    public func request(path: String, modelID: String, body: JSONValue, headers requestHeaders: [String: String] = [:], abortSignal: AIAbortSignal? = nil) throws -> AIHTTPRequest {
        try rawRequest(
            path: path,
            modelID: modelID,
            body: try encodeJSONBody(body),
            contentType: "application/json",
            headers: requestHeaders,
            abortSignal: abortSignal
        )
    }

    public func rawRequest(path: String, modelID: String, body: Data, contentType: String?, headers requestHeaders: [String: String] = [:], abortSignal: AIAbortSignal? = nil) throws -> AIHTTPRequest {
        var providerHeaders = self.headers
        if let dynamicHeaders { providerHeaders.merge(dynamicHeaders()) { _, dynamic in dynamic } }
        if let userAgentSuffix { providerHeaders = withUserAgentSuffix(providerHeaders, userAgentSuffix) }
        var headers = providerHeaders.mergingHeaders(requestHeaders)
        if let contentType {
            headers["content-type"] = headers["content-type"] ?? contentType
        }
        headers["user-agent"] = headers["user-agent"] ?? userAgent(providerID)
        return AIHTTPRequest(
            method: "POST",
            url: try url(requestModelID ?? modelID, path),
            headers: headers,
            body: body,
            abortSignal: abortSignal
        )
    }

    public func streamRequest(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        let streamingTransport = try requireStreamingTransport(transport, providerID: providerID)
        return try await streamingTransport.stream(request)
    }

}
