import Foundation
import SwiftAIProvider

/// Shared HTTP request construction without provider routing or response policy.
public struct AIProviderHTTPClient: Sendable {
    public var providerID: String
    public var headers: [String: String]
    private var baseTransport: any AITransport
    public var credentialResolver: AIAsyncCredential?
    public var transport: any AITransport {
        get { credentialResolver?.resolvingTransport(baseTransport) ?? baseTransport }
        set { baseTransport = newValue }
    }
    public var dynamicHeaders: (@Sendable () -> [String: String])?
    public var userAgentSuffix: String?
    public var requestModelID: String?
    public var url: @Sendable (String, String) throws -> URL

    public init(providerID: String, headers: [String: String] = [:], transport: any AITransport,
                credentialResolver: AIAsyncCredential? = nil,
                dynamicHeaders: (@Sendable () -> [String: String])? = nil,
                userAgentSuffix: String? = nil, requestModelID: String? = nil,
                url: @escaping @Sendable (String, String) throws -> URL) {
        self.providerID = providerID
        self.headers = headers
        self.baseTransport = transport
        self.credentialResolver = credentialResolver
        self.dynamicHeaders = dynamicHeaders
        self.userAgentSuffix = userAgentSuffix
        self.requestModelID = requestModelID
        self.url = url
    }

    /// Resolves authentication immediately before a WebSocket connection.
    public func resolvedHeaders(_ requestHeaders: [String: String] = [:]) async throws -> [String: String] {
        var headers = self.headers
        if let dynamicHeaders { headers.merge(dynamicHeaders()) { _, dynamic in dynamic } }
        if let userAgentSuffix { headers = withUserAgentSuffix(headers, userAgentSuffix) }
        headers = mergingRequestHeaders(requestHeaders, into: headers)
        return try await credentialResolver?.resolveHeaders(headers) ?? headers
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
        var headers = mergingRequestHeaders(requestHeaders, into: providerHeaders)
        // Defaults yield to caller headers in any letter case, as with the
        // case-insensitive Headers object upstream; never send both spellings.
        if let contentType, !headers.keys.contains(where: { $0.caseInsensitiveCompare("content-type") == .orderedSame }) {
            headers["content-type"] = contentType
        }
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("user-agent") == .orderedSame }) {
            headers["user-agent"] = userAgent(providerID)
        }
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

    private func mergingRequestHeaders(_ requestHeaders: [String: String], into providerHeaders: [String: String]) -> [String: String] {
        var result = providerHeaders
        for (key, value) in requestHeaders {
            for existing in result.keys.filter({ $0.caseInsensitiveCompare(key) == .orderedSame }) {
                result.removeValue(forKey: existing)
            }
            result[key] = value
        }
        return result
    }

}
