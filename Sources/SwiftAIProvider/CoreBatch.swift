import Foundation


/// Serializable error information for a durable batch or one of its items.
public struct AIBatchError: Error, Equatable, Codable, Sendable, CustomStringConvertible {
    public var message: String
    public var type: String?
    public var code: String?
    public var statusCode: Int?

    public init(message: String, type: String? = nil, code: String? = nil, statusCode: Int? = nil) {
        self.message = message
        self.type = type
        self.code = code
        self.statusCode = statusCode
    }

    public var description: String { message }
}

public enum AIBatchLifecycleStatus: String, Equatable, Hashable, Codable, Sendable {
    case pending
    case completed
    case failed
}

public struct AIBatchRequestCounts: Equatable, Codable, Sendable {
    public var total: Int
    public var pending: Int
    public var completed: Int
    public var failed: Int

    public init(total: Int, pending: Int, completed: Int, failed: Int) {
        self.total = total
        self.pending = pending
        self.completed = completed
        self.failed = failed
    }
}

// JSON numbers use IEEE-754 doubles throughout the provider adapters. Keep
// batch counters within JavaScript's exact integer range so converting them to
// `Int` cannot silently round a provider value or trap on overflow.
public let aiBatchMaximumSafeInteger = 9_007_199_254_740_991

public func normalizedBatchJSONInteger(_ value: JSONValue?) -> Int? {
    guard case let .number(number)? = value,
          number.isFinite,
          number >= 0,
          number <= Double(aiBatchMaximumSafeInteger),
          number.rounded(.towardZero) == number else {
        return nil
    }
    return Int(number)
}

public func checkedBatchSafeIntegerSum(_ values: [Int]) -> Int? {
    var sum = 0
    for value in values {
        guard (0...aiBatchMaximumSafeInteger).contains(value) else { return nil }
        let addition = sum.addingReportingOverflow(value)
        guard !addition.overflow,
              addition.partialValue <= aiBatchMaximumSafeInteger else {
            return nil
        }
        sum = addition.partialValue
    }
    return sum
}

public func normalizedBatchRequestCounts(
    total: Int?,
    pending: Int?,
    completed: Int?,
    failed: Int?
) -> AIBatchRequestCounts? {
    guard let total,
          let pending,
          let completed,
          let failed,
          (0...aiBatchMaximumSafeInteger).contains(total),
          let itemTotal = checkedBatchSafeIntegerSum([pending, completed, failed]),
          itemTotal == total else {
        return nil
    }
    return AIBatchRequestCounts(
        total: total,
        pending: pending,
        completed: completed,
        failed: failed
    )
}

/// Normalized, provider-independent lifecycle status for a durable batch.
public struct AIBatchStatus: Equatable, Codable, Sendable {
    public var status: AIBatchLifecycleStatus
    public var rawStatus: String?
    public var requestCounts: AIBatchRequestCounts?
    public var error: AIBatchError?
    public var createdAt: String?
    public var expiresAt: String?
    public var providerMetadata: [String: JSONValue]

    public init(
        status: AIBatchLifecycleStatus,
        rawStatus: String? = nil,
        requestCounts: AIBatchRequestCounts? = nil,
        error: AIBatchError? = nil,
        createdAt: String? = nil,
        expiresAt: String? = nil,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.status = status
        self.rawStatus = rawStatus
        self.requestCounts = requestCounts
        self.error = error
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.providerMetadata = providerMetadata
    }
}

public struct AIBatchWarning: Equatable, Sendable {
    public var requestID: String?
    public var warning: AIWarning

    public init(requestID: String? = nil, warning: AIWarning) {
        self.requestID = requestID
        self.warning = warning
    }
}

public struct AIBatchStartOptions<Request: Sendable>: Sendable {
    public var requests: [Request]
    public var providerOptions: [String: JSONValue]
    public var abortSignal: AIAbortSignal?
    public var headers: [String: String]
    /// Optional stable key forwarded to providers that implement idempotent batch creation.
    public var idempotencyKey: String?
    /// Optional callback URL for providers that support per-batch completion webhooks.
    public var webhookURL: String?

    public init(
        requests: [Request],
        providerOptions: [String: JSONValue] = [:],
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        idempotencyKey: String? = nil,
        webhookURL: String? = nil
    ) {
        self.requests = requests
        self.providerOptions = providerOptions
        self.abortSignal = abortSignal
        self.headers = headers
        self.idempotencyKey = idempotencyKey
        self.webhookURL = webhookURL
    }

    /// Source-compatible initializer retained for clients built against Batch V4
    /// before completion webhooks were added.
    public init(
        requests: [Request],
        providerOptions: [String: JSONValue] = [:],
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        idempotencyKey: String? = nil
    ) {
        self.init(
            requests: requests,
            providerOptions: providerOptions,
            abortSignal: abortSignal,
            headers: headers,
            idempotencyKey: idempotencyKey,
            webhookURL: nil
        )
    }
}

public struct AIBatchStartResult: Equatable, Sendable {
    public var batchID: String
    public var status: AIBatchStatus
    public var warnings: [AIBatchWarning]
    /// Provider-specific metadata produced while creating the batch, such as
    /// an uploaded JSONL input file identifier and expiry timestamp.
    public var providerMetadata: [String: JSONValue]

    public init(
        batchID: String,
        status: AIBatchStatus,
        warnings: [AIBatchWarning] = [],
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.batchID = batchID
        self.status = status
        self.warnings = warnings
        self.providerMetadata = providerMetadata
    }

    /// Source-compatible initializer retained from before batch-start
    /// provider metadata was exposed.
    public init(
        batchID: String,
        status: AIBatchStatus,
        warnings: [AIBatchWarning] = []
    ) {
        self.init(
            batchID: batchID,
            status: status,
            warnings: warnings,
            providerMetadata: [:]
        )
    }
}

public struct AIBatchOperationOptions: Sendable {
    public var batchID: String
    public var providerOptions: [String: JSONValue]
    public var abortSignal: AIAbortSignal?
    public var headers: [String: String]

    public init(
        batchID: String,
        providerOptions: [String: JSONValue] = [:],
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:]
    ) {
        self.batchID = batchID
        self.providerOptions = providerOptions
        self.abortSignal = abortSignal
        self.headers = headers
    }
}

/// One terminal provider result. Individual failures do not terminate the result stream.
public enum AIBatchItemResult<Result: Sendable>: Sendable {
    case succeeded(id: String, result: Result)
    case failed(id: String, error: AIBatchError, providerMetadata: [String: JSONValue] = [:])
    case cancelled(id: String, error: AIBatchError? = nil, providerMetadata: [String: JSONValue] = [:])
    case expired(id: String, error: AIBatchError? = nil, providerMetadata: [String: JSONValue] = [:])

    public var id: String {
        switch self {
        case let .succeeded(id, _),
             let .failed(id, _, _),
             let .cancelled(id, _, _),
             let .expired(id, _, _):
            return id
        }
    }
}

public struct AILanguageModelBatchRequest: Sendable {
    public var id: String
    /// Provider-specific model identifier for provider-owned Batch V4 calls.
    /// `nil` is retained for the legacy model-owned compatibility surface.
    public var modelID: String?
    public var request: LanguageModelRequest

    /// Creates a provider-owned batch request with an explicit model selection.
    /// The default retains legacy factory-reference overload ranking.
    public init(id: String, modelID: String? = nil, request: LanguageModelRequest) {
        self.id = id
        self.modelID = modelID
        self.request = request
    }

    /// Creates a legacy model-owned batch request.
    public init(id: String, request: LanguageModelRequest) {
        self.init(id: id, modelID: nil, request: request)
    }
}

/// Durable Batch V4 capability for language models.
public protocol BatchLanguageModel: LanguageModel {
    func startBatch(_ options: AIBatchStartOptions<AILanguageModelBatchRequest>) async throws -> AIBatchStartResult
    func getBatchStatus(_ options: AIBatchOperationOptions) async throws -> AIBatchStatus
    func getBatchResults(
        _ options: AIBatchOperationOptions
    ) async throws -> AsyncThrowingStream<AIBatchItemResult<TextGenerationResult>, Error>
}

public enum AIBatchReferenceType: String, Equatable, Hashable, Codable, Sendable {
    case text
}

/// Persistable identity of a durable text batch.
public struct TextBatchReference: Equatable, Hashable, Codable, Sendable {
    public let version: Int
    public let type: AIBatchReferenceType
    public var id: String
    public var providerID: String
    public var modelID: String

    public init(
        version: Int = 1,
        type: AIBatchReferenceType = .text,
        id: String,
        providerID: String,
        modelID: String
    ) {
        self.version = version
        self.type = type
        self.id = id
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct TextBatch: Equatable, Codable, Sendable {
    public var reference: TextBatchReference
    public var status: AIBatchStatus

    public init(reference: TextBatchReference, status: AIBatchStatus) {
        self.reference = reference
        self.status = status
    }
}

public struct TextBatchRequest: Sendable {
    public var id: String
    /// Model selected for this request on the provider-owned Batch V4 surface.
    /// The legacy `startTextBatch(model:requests:)` overload may leave it unset.
    public var modelID: String?
    public var request: LanguageModelRequest

    public init(id: String, request: LanguageModelRequest) {
        self.id = id
        self.modelID = nil
        self.request = request
    }

    /// Creates a provider-owned text request. The optional default keeps an
    /// uncontextualized reference to `TextBatchRequest.init` source-compatible.
    public init(id: String, modelID: String? = nil, request: LanguageModelRequest) {
        self.id = id
        self.modelID = modelID
        self.request = request
    }
}

public struct StartTextBatchResult: Equatable, Sendable {
    public var batch: TextBatch
    public var warnings: [AIBatchWarning]
    public var providerMetadata: [String: JSONValue]

    public init(
        batch: TextBatch,
        warnings: [AIBatchWarning] = [],
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.batch = batch
        self.warnings = warnings
        self.providerMetadata = providerMetadata
    }

    /// Source-compatible initializer retained from before batch-start
    /// provider metadata was exposed.
    public init(
        batch: TextBatch,
        warnings: [AIBatchWarning] = []
    ) {
        self.init(
            batch: batch,
            warnings: warnings,
            providerMetadata: [:]
        )
    }
}

public struct TextBatchGenerationResult: Sendable {
    public var text: String
    public var content: [AIResultContentPart]
    public var finishReason: String?
    public var rawFinishReason: String?
    public var usage: TokenUsage
    public var response: AIResponseMetadata?
    public var providerMetadata: [String: JSONValue]

    public init(
        text: String,
        content: [AIResultContentPart] = [],
        finishReason: String? = nil,
        rawFinishReason: String? = nil,
        usage: TokenUsage = TokenUsage(),
        response: AIResponseMetadata? = nil,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.text = text
        self.content = content
        self.finishReason = finishReason
        self.rawFinishReason = rawFinishReason
        self.usage = usage
        self.response = response
        self.providerMetadata = providerMetadata
    }

    /// Source-compatible initializer retained from the text-only batch result.
    public init(
        text: String,
        finishReason: String? = nil,
        rawFinishReason: String? = nil,
        usage: TokenUsage = TokenUsage(),
        response: AIResponseMetadata? = nil,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.init(
            text: text,
            content: [],
            finishReason: finishReason,
            rawFinishReason: rawFinishReason,
            usage: usage,
            response: response,
            providerMetadata: providerMetadata
        )
    }
}

public enum TextBatchItemResult: Sendable {
    case succeeded(id: String, result: TextBatchGenerationResult)
    case failed(id: String, error: AIBatchError, providerMetadata: [String: JSONValue] = [:])
    case cancelled(id: String, error: AIBatchError? = nil, providerMetadata: [String: JSONValue] = [:])
    case expired(id: String, error: AIBatchError? = nil, providerMetadata: [String: JSONValue] = [:])

    public var id: String {
        switch self {
        case let .succeeded(id, _),
             let .failed(id, _, _),
             let .cancelled(id, _, _),
             let .expired(id, _, _):
            return id
        }
    }
}

// MARK: - Provider-owned Batch V4

/// One image-generation request in a provider-owned batch.
public struct ImageBatchRequest: Sendable {
    public var id: String
    public var modelID: String
    public var request: ImageGenerationRequest

    public init(id: String, modelID: String, request: ImageGenerationRequest) {
        self.id = id
        self.modelID = modelID
        self.request = request
    }
}

/// A provider-owned Batch V4 request, discriminated by modality before any I/O.
public enum AIBatchRequest: Sendable {
    case text(TextBatchRequest)
    case image(ImageBatchRequest)

    public var id: String {
        switch self {
        case let .text(request): request.id
        case let .image(request): request.id
        }
    }

    public var modelID: String? {
        switch self {
        case let .text(request): request.modelID
        case let .image(request): request.modelID
        }
    }
}

/// Persistable identity of a provider-owned Batch V4 operation.
public struct AIBatchReference: Equatable, Hashable, Codable, Sendable {
    public let version: Int
    public var id: String
    public var providerID: String

    public init(version: Int = 2, id: String, providerID: String) {
        self.version = version
        self.id = id
        self.providerID = providerID
    }
}

/// A provider-owned batch together with its latest normalized status.
public struct AIBatch: Equatable, Codable, Sendable {
    public var reference: AIBatchReference
    public var status: AIBatchStatus

    public init(reference: AIBatchReference, status: AIBatchStatus) {
        self.reference = reference
        self.status = status
    }
}

public struct StartBatchResult: Equatable, Sendable {
    public var batch: AIBatch
    public var warnings: [AIBatchWarning]
    public var providerMetadata: [String: JSONValue]

    public init(
        batch: AIBatch,
        warnings: [AIBatchWarning] = [],
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.batch = batch
        self.warnings = warnings
        self.providerMetadata = providerMetadata
    }
}

public struct AIBatchCancelResult: Equatable, Sendable {
    public var providerMetadata: [String: JSONValue]

    public init(providerMetadata: [String: JSONValue] = [:]) {
        self.providerMetadata = providerMetadata
    }
}

public struct AIBatchListOptions: Sendable {
    public var providerOptions: [String: JSONValue]
    public var limit: Int?
    public var cursor: String?
    public var abortSignal: AIAbortSignal?
    public var headers: [String: String]

    public init(
        providerOptions: [String: JSONValue] = [:],
        limit: Int? = nil,
        cursor: String? = nil,
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:]
    ) {
        self.providerOptions = providerOptions
        self.limit = limit
        self.cursor = cursor
        self.abortSignal = abortSignal
        self.headers = headers
    }
}

public struct AIBatchListItem: Equatable, Sendable {
    public var batchID: String
    public var status: AIBatchStatus

    public init(batchID: String, status: AIBatchStatus) {
        self.batchID = batchID
        self.status = status
    }
}

public struct AIBatchListResult: Equatable, Sendable {
    public var batches: [AIBatchListItem]
    public var nextCursor: String?
    public var providerMetadata: [String: JSONValue]

    public init(
        batches: [AIBatchListItem],
        nextCursor: String? = nil,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.batches = batches
        self.nextCursor = nextCursor
        self.providerMetadata = providerMetadata
    }
}

/// Low-level terminal result emitted by a provider-owned batch implementation.
public enum AIBatchV4ItemResult: Sendable {
    case text(AIBatchItemResult<TextGenerationResult>)
    case image(AIBatchItemResult<ImageGenerationResult>)
}

/// Normalized successful image batch result.
public struct ImageBatchGenerationResult: Sendable {
    public var urls: [String]
    public var base64Images: [String]
    public var warnings: [AIWarning]
    public var usage: TokenUsage?
    public var response: AIResponseMetadata
    public var providerMetadata: [String: JSONValue]

    public init(
        urls: [String],
        base64Images: [String] = [],
        warnings: [AIWarning] = [],
        usage: TokenUsage? = nil,
        response: AIResponseMetadata = AIResponseMetadata(),
        providerMetadata: [String: JSONValue] = [:]
    ) {
        self.urls = urls
        self.base64Images = base64Images
        self.warnings = warnings
        self.usage = usage
        self.response = response
        self.providerMetadata = providerMetadata
    }
}

public enum ImageBatchItemResult: Sendable {
    case succeeded(id: String, result: ImageBatchGenerationResult)
    case failed(id: String, error: AIBatchError, providerMetadata: [String: JSONValue] = [:])
    case cancelled(id: String, error: AIBatchError? = nil, providerMetadata: [String: JSONValue] = [:])
    case expired(id: String, error: AIBatchError? = nil, providerMetadata: [String: JSONValue] = [:])

    public var id: String {
        switch self {
        case let .succeeded(id, _),
             let .failed(id, _, _),
             let .cancelled(id, _, _),
             let .expired(id, _, _):
            id
        }
    }
}

/// Normalized provider-owned result, preserving the text/image discriminator.
public enum BatchItemResult: Sendable {
    case text(TextBatchItemResult)
    case image(ImageBatchItemResult)
}

/// Durable Batch V4 belongs to the provider, allowing each request to select
/// its own model and modality.
public protocol AIBatchProvider: Sendable {
    var providerID: String { get }
    var supportedURLs: [String: [AISupportedURLPattern]] { get }

    func startBatch(_ options: AIBatchStartOptions<AIBatchRequest>) async throws -> AIBatchStartResult
    func getBatchStatus(_ options: AIBatchOperationOptions) async throws -> AIBatchStatus
    func getBatchResults(
        _ options: AIBatchOperationOptions
    ) async throws -> AsyncThrowingStream<AIBatchV4ItemResult, Error>
    func cancelBatch(_ options: AIBatchOperationOptions) async throws -> AIBatchCancelResult
    func listBatches(_ options: AIBatchListOptions) async throws -> AIBatchListResult
}

public extension AIBatchProvider {
    var supportedURLs: [String: [AISupportedURLPattern]] { [:] }

    func cancelBatch(_ options: AIBatchOperationOptions) async throws -> AIBatchCancelResult {
        throw AIError.invalidArgument(
            argument: "provider",
            message: "The provider does not support batch cancellation."
        )
    }

    func listBatches(_ options: AIBatchListOptions) async throws -> AIBatchListResult {
        throw AIError.invalidArgument(
            argument: "provider",
            message: "The provider does not support listing batches."
        )
    }
}
