import Foundation


public struct AIEmbeddingProviderOptionsTransformContext: Sendable {
    public var providerOptions: [String: JSONValue]
    public var values: [String]
    public var startIndex: Int
    public var endIndex: Int

    public init(
        providerOptions: [String: JSONValue],
        values: [String],
        startIndex: Int,
        endIndex: Int
    ) {
        self.providerOptions = providerOptions
        self.values = values
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}

public typealias AIEmbeddingProviderOptionsTransformer = @Sendable (
    AIEmbeddingProviderOptionsTransformContext
) async throws -> [String: JSONValue]

public struct EmbeddingRequest: Sendable {
    public var values: [String]
    public var dimensions: Int?
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        values: [String],
        dimensions: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.values = values
        self.dimensions = dimensions
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct EmbeddingResult: Sendable {
    public var embeddings: [[Double]]
    public var usage: TokenUsage?
    public var rawValue: JSONValue
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        embeddings: [[Double]],
        usage: TokenUsage? = nil,
        rawValue: JSONValue,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.embeddings = embeddings
        self.usage = usage
        self.rawValue = rawValue
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct ImageGenerationRequest: Sendable {
    public var prompt: String
    public var size: String?
    public var aspectRatio: String?
    public var seed: Int?
    public var count: Int?
    public var files: [ImageInputFile]
    public var mask: ImageInputFile?
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        prompt: String,
        size: String? = nil,
        aspectRatio: String? = nil,
        seed: Int? = nil,
        count: Int? = nil,
        files: [ImageInputFile] = [],
        mask: ImageInputFile? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.prompt = prompt
        self.size = size
        self.aspectRatio = aspectRatio
        self.seed = seed
        self.count = count
        self.files = files
        self.mask = mask
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct ImageInputFile: Sendable, Equatable {
    public var data: Data?
    public var url: String?
    public var mediaType: String?
    public var fileName: String?

    public init(data: Data, mediaType: String, fileName: String? = nil) {
        self.data = data
        self.url = nil
        self.mediaType = mediaType
        self.fileName = fileName
    }

    public init(url: String, mediaType: String? = nil, fileName: String? = nil) {
        self.data = nil
        self.url = url
        self.mediaType = mediaType
        self.fileName = fileName
    }
}

public func convertImageModelFileToDataURI(_ file: ImageInputFile) throws -> String {
    if let url = file.url {
        return url
    }
    guard let data = file.data else {
        throw AIError.invalidArgument(argument: "file", message: "Image file must contain either data or URL.")
    }
    let mediaType = file.mediaType ?? "image/png"
    return "data:\(mediaType);base64,\(data.base64EncodedString())"
}

/// The result of one underlying image-model call.
public struct ImageGenerationCall: Equatable, Sendable {
    public var urls: [String]
    public var base64Images: [String]
    public var warnings: [AIWarning]
    public var usage: TokenUsage?
    public var providerMetadata: [String: JSONValue]
    public var responseMetadata: AIResponseMetadata

    public init(
        urls: [String],
        base64Images: [String] = [],
        warnings: [AIWarning] = [],
        usage: TokenUsage? = nil,
        providerMetadata: [String: JSONValue] = [:],
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.urls = urls
        self.base64Images = base64Images
        self.warnings = warnings
        self.usage = usage
        self.providerMetadata = providerMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct ImageGenerationResult: Sendable {
    public var urls: [String]
    public var base64Images: [String]
    public var rawValue: JSONValue
    public var warnings: [AIWarning]
    public var usage: TokenUsage?
    public var providerMetadata: [String: JSONValue]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata
    /// Provider classification for empty-image results. `false` makes an empty
    /// result terminal; `true` and `nil` retain the SDK's retry behavior.
    public var isRetryable: Bool?
    /// Per-call results, preserving response and provider metadata scopes.
    public var calls: [ImageGenerationCall]

    public init(
        urls: [String],
        base64Images: [String] = [],
        rawValue: JSONValue,
        warnings: [AIWarning] = [],
        usage: TokenUsage? = nil,
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata(),
        isRetryable: Bool?,
        calls: [ImageGenerationCall] = []
    ) {
        self.urls = urls
        self.base64Images = base64Images
        self.rawValue = rawValue
        self.warnings = warnings
        self.usage = usage
        self.providerMetadata = providerMetadata
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
        self.isRetryable = isRetryable
        self.calls = calls
    }

    /// Source-compatible initializer retained for callers that provide per-call
    /// results but do not classify empty results for retry.
    public init(
        urls: [String],
        base64Images: [String] = [],
        rawValue: JSONValue,
        warnings: [AIWarning] = [],
        usage: TokenUsage? = nil,
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata(),
        calls: [ImageGenerationCall] = []
    ) {
        self.init(
            urls: urls,
            base64Images: base64Images,
            rawValue: rawValue,
            warnings: warnings,
            usage: usage,
            providerMetadata: providerMetadata,
            requestMetadata: requestMetadata,
            responseMetadata: responseMetadata,
            isRetryable: nil,
            calls: calls
        )
    }

    /// Source-compatible initializer retained from the aggregate-only image result.
    public init(
        urls: [String],
        base64Images: [String] = [],
        rawValue: JSONValue,
        warnings: [AIWarning] = [],
        usage: TokenUsage? = nil,
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.init(
            urls: urls,
            base64Images: base64Images,
            rawValue: rawValue,
            warnings: warnings,
            usage: usage,
            providerMetadata: providerMetadata,
            requestMetadata: requestMetadata,
            responseMetadata: responseMetadata,
            isRetryable: nil,
            calls: []
        )
    }
}