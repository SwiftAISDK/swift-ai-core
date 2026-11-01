import Foundation
import SwiftAIProvider

/// A lazy credential resolved once per authenticated request. Static and
/// request-specific header overrides are applied before the supplier is called.
public struct AIAsyncCredential: Sendable {
    public let placeholder: String
    private let resolver: @Sendable () async throws -> String

    public init(_ resolver: @escaping @Sendable () async throws -> String) {
        self.placeholder = "__swift_ai_credential_\(UUID().uuidString)__"
        self.resolver = resolver
    }

    public func resolveHeaders(_ headers: [String: String]) async throws -> [String: String] {
        guard headers.values.contains(where: { $0.contains(placeholder) }) else { return headers }
        try Task.checkCancellation()
        let value = try await resolver()
        try Task.checkCancellation()
        return headers.mapValues { $0.replacingOccurrences(of: placeholder, with: value) }
    }

    public func resolvingTransport(_ transport: any AITransport) -> any AITransport {
        if let streaming = transport as? any AIStreamingTransport {
            return CredentialStreamingTransport(base: streaming, credential: self)
        }
        return CredentialTransport(base: transport, credential: self)
    }

    private func resolveRequest(_ request: AIHTTPRequest) async throws -> AIHTTPRequest {
        try request.abortSignal?.throwIfAborted()
        var request = request
        request.headers = try await resolveHeaders(request.headers)
        try request.abortSignal?.throwIfAborted()
        return request
    }

    private struct CredentialTransport: AITransport {
        let base: any AITransport
        let credential: AIAsyncCredential
        func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
            try await base.send(credential.resolveRequest(request))
        }
        func sendValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
            try await base.sendValidatedDownload(credential.resolveRequest(request))
        }
    }

    private struct CredentialStreamingTransport: AIStreamingTransport {
        let base: any AIStreamingTransport
        let credential: AIAsyncCredential
        func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
            try await base.send(credential.resolveRequest(request))
        }
        func sendValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
            try await base.sendValidatedDownload(credential.resolveRequest(request))
        }
        func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
            try await base.stream(credential.resolveRequest(request))
        }
        func streamValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
            try await base.streamValidatedDownload(credential.resolveRequest(request))
        }
    }
}
