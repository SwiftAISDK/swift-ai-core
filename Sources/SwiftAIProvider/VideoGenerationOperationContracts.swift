import Foundation

/// A provider-owned reference to an asynchronous video generation operation.
///
/// `operation` must remain JSON serializable so callers can persist it and
/// resume status checks in a later process.
public struct VideoGenerationOperationStartResult: Sendable {
    public var operation: JSONValue
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var responseMetadata: AIResponseMetadata

    public init(
        operation: JSONValue,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.operation = operation
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.responseMetadata = responseMetadata
    }
}

/// The result of one status check for an asynchronous video operation.
public enum VideoGenerationOperationStatusResult: Sendable {
    case pending(
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    )
    case completed(VideoGenerationResult)
    case failed(
        message: String,
        providerMetadata: [String: JSONValue] = [:],
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    )
}

public struct VideoGenerationOperationStartRequest: Sendable {
    public var request: VideoGenerationRequest
    public var webhookURL: String?

    public init(request: VideoGenerationRequest, webhookURL: String? = nil) {
        self.request = request
        self.webhookURL = webhookURL
    }
}

public struct VideoGenerationOperationStatusRequest: Sendable {
    public var operation: JSONValue
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        operation: JSONValue,
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.operation = operation
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

/// The notification delivered to a webhook endpoint for an asynchronous video operation.
public struct VideoGenerationOperationWebhook: Sendable, Equatable {
    public var headers: [String: String]
    public var body: JSONValue

    public init(headers: [String: String] = [:], body: JSONValue) {
        self.headers = headers
        self.body = body
    }
}

/// A webhook endpoint and the cancellation-aware receiver for its first notification.
public struct VideoGenerationWebhookRegistration: Sendable {
    public var url: String
    private let receiveImplementation: @Sendable (AIAbortSignal?) async throws -> VideoGenerationOperationWebhook

    public init(
        url: String,
        receive: @escaping @Sendable (AIAbortSignal?) async throws -> VideoGenerationOperationWebhook
    ) {
        self.url = url
        self.receiveImplementation = receive
    }

    public func receive(abortSignal: AIAbortSignal? = nil) async throws -> VideoGenerationOperationWebhook {
        try abortSignal?.throwIfAborted()
        return try await receiveImplementation(abortSignal)
    }
}

public typealias VideoGenerationWebhookFactory = @Sendable () async throws -> VideoGenerationWebhookRegistration
public typealias VideoGenerationDelay = @Sendable (_ milliseconds: Int, _ abortSignal: AIAbortSignal?) async throws -> Void

/// Polling and webhook-wait configuration for asynchronous video generation.
public struct VideoGenerationPollOptions: Sendable {
    public var intervalMilliseconds: Int
    public var timeoutMilliseconds: Int
    public var delay: VideoGenerationDelay

    public init(
        intervalMilliseconds: Int = 5_000,
        timeoutMilliseconds: Int = 600_000,
        delay: @escaping VideoGenerationDelay = { milliseconds, abortSignal in
            try await SwiftAIProvider.delay(milliseconds, abortSignal: abortSignal)
        }
    ) {
        self.intervalMilliseconds = intervalMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
        self.delay = delay
    }
}

public enum VideoGenerationOperationError: Error, Equatable, Sendable, CustomStringConvertible {
    case timedOut(milliseconds: Int)
    case providerFailed(String)
    case incompleteAfterWebhook

    public var description: String {
        switch self {
        case let .timedOut(milliseconds):
            return "Video generation timed out after \(milliseconds)ms."
        case let .providerFailed(message):
            return message
        case .incompleteAfterWebhook:
            return "Video generation did not complete after webhook notification."
        }
    }
}

/// A video model that exposes the provider V4 start/status operation surface.
///
/// Conformance is additive to `VideoModel`, so existing unary
/// `generateVideo(_:)` calls remain source compatible.
public protocol AsyncVideoModel: VideoModel {
    /// Maximum number of videos one start operation can request. Upstream V4
    /// defaults to one when a provider does not advertise a larger batch.
    var maxVideosPerCall: Int { get }
    var supportsVideoGenerationWebhooks: Bool { get }

    func handleVideoGenerationWebhookOption(
        _ factory: @escaping VideoGenerationWebhookFactory
    ) async throws -> VideoGenerationWebhookRegistration

    func startVideoGeneration(
        _ request: VideoGenerationOperationStartRequest
    ) async throws -> VideoGenerationOperationStartResult

    func videoGenerationStatus(
        _ request: VideoGenerationOperationStatusRequest
    ) async throws -> VideoGenerationOperationStatusResult
}

public extension AsyncVideoModel {
    var maxVideosPerCall: Int { 1 }
    var supportsVideoGenerationWebhooks: Bool { false }

    func handleVideoGenerationWebhookOption(
        _ factory: @escaping VideoGenerationWebhookFactory
    ) async throws -> VideoGenerationWebhookRegistration {
        try await factory()
    }
}
