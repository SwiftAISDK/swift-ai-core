import Foundation


/// File bytes supplied to a Files V4 upload.
///
/// Buffered data remains the default so existing `FileUploadRequest(data:...)`
/// call sites keep their source and runtime behavior. Stream values are
/// single-use and are consumed (or cancelled) by a streaming-capable client.
public enum FileUploadData: Sendable {
    case data(Data)
    case stream(AsyncThrowingStream<Data, Error>)

    public var bufferedData: Data? {
        guard case let .data(data) = self else { return nil }
        return data
    }

    public var isStream: Bool {
        guard case .stream = self else { return false }
        return true
    }

    public var byteCount: Int? {
        bufferedData?.count
    }
}

public struct FileUploadRequest: Sendable {
    public var fileData: FileUploadData
    /// Backward-compatible access to buffered upload bytes. Stream-backed
    /// requests expose an empty value here; use `fileData` to distinguish them.
    public var data: Data {
        get { fileData.bufferedData ?? Data() }
        set { fileData = .data(newValue) }
    }
    public var mediaType: String
    public var filename: String?
    public var purpose: String?
    public var displayName: String?
    public var pollIntervalNanoseconds: UInt64
    public var pollTimeoutNanoseconds: UInt64
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        data: Data,
        mediaType: String,
        filename: String? = nil,
        purpose: String? = nil,
        displayName: String? = nil,
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        pollTimeoutNanoseconds: UInt64 = 300_000_000_000,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.init(
            fileData: .data(data),
            mediaType: mediaType,
            filename: filename,
            purpose: purpose,
            displayName: displayName,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            pollTimeoutNanoseconds: pollTimeoutNanoseconds,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal
        )
    }

    public init(
        stream: AsyncThrowingStream<Data, Error>,
        mediaType: String,
        filename: String? = nil,
        purpose: String? = nil,
        displayName: String? = nil,
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        pollTimeoutNanoseconds: UInt64 = 300_000_000_000,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.init(
            fileData: .stream(stream),
            mediaType: mediaType,
            filename: filename,
            purpose: purpose,
            displayName: displayName,
            pollIntervalNanoseconds: pollIntervalNanoseconds,
            pollTimeoutNanoseconds: pollTimeoutNanoseconds,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal
        )
    }

    public init(
        fileData: FileUploadData,
        mediaType: String,
        filename: String? = nil,
        purpose: String? = nil,
        displayName: String? = nil,
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        pollTimeoutNanoseconds: UInt64 = 300_000_000_000,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.fileData = fileData
        self.mediaType = mediaType
        self.filename = filename
        self.purpose = purpose
        self.displayName = displayName
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.pollTimeoutNanoseconds = pollTimeoutNanoseconds
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct FileUploadResult: Sendable {
    public var providerReference: [String: String]
    public var filename: String?
    public var mediaType: String?
    public var byteSize: Int?
    public var createdAt: Date?
    public var expiresAt: Date?
    public var metadata: [String: JSONValue]
    public var rawValue: JSONValue
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        providerReference: [String: String],
        filename: String? = nil,
        mediaType: String? = nil,
        byteSize: Int? = nil,
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        metadata: [String: JSONValue] = [:],
        rawValue: JSONValue,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.providerReference = providerReference
        self.filename = filename
        self.mediaType = mediaType
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.metadata = metadata
        self.rawValue = rawValue
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }

    /// Source-compatible initializer retained from before Files V4 exposed
    /// byte size and lifecycle timestamps.
    public init(
        providerReference: [String: String],
        filename: String? = nil,
        mediaType: String? = nil,
        metadata: [String: JSONValue] = [:],
        rawValue: JSONValue,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.init(
            providerReference: providerReference,
            filename: filename,
            mediaType: mediaType,
            byteSize: nil,
            createdAt: nil,
            expiresAt: nil,
            metadata: metadata,
            rawValue: rawValue,
            warnings: warnings,
            providerMetadata: providerMetadata,
            requestMetadata: requestMetadata,
            responseMetadata: responseMetadata
        )
    }
}

public struct FileMetadataRequest: Sendable {
    public var file: [String: String]
    public var providerOptions: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        file: [String: String],
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.file = file
        self.providerOptions = providerOptions
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct FileMetadataResult: Sendable {
    public var providerReference: [String: String]
    public var filename: String?
    public var mediaType: String?
    public var byteSize: Int?
    public var createdAt: Date?
    public var expiresAt: Date?
    public var providerMetadata: [String: JSONValue]
    public var warnings: [AIWarning]
    public var rawValue: JSONValue
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        providerReference: [String: String],
        filename: String? = nil,
        mediaType: String? = nil,
        byteSize: Int? = nil,
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        providerMetadata: [String: JSONValue] = [:],
        warnings: [AIWarning] = [],
        rawValue: JSONValue = .null,
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.providerReference = providerReference
        self.filename = filename
        self.mediaType = mediaType
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.providerMetadata = providerMetadata
        self.warnings = warnings
        self.rawValue = rawValue
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct FileDownloadRequest: Sendable {
    public var file: [String: String]
    public var providerOptions: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        file: [String: String],
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.file = file
        self.providerOptions = providerOptions
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct FileDownloadResult: Sendable {
    public var content: AsyncThrowingStream<Data, Error>
    public var mediaType: String?
    public var providerMetadata: [String: JSONValue]
    public var warnings: [AIWarning]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        content: AsyncThrowingStream<Data, Error>,
        mediaType: String? = nil,
        providerMetadata: [String: JSONValue] = [:],
        warnings: [AIWarning] = [],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.content = content
        self.mediaType = mediaType
        self.providerMetadata = providerMetadata
        self.warnings = warnings
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct FileDeleteRequest: Sendable {
    public var file: [String: String]
    public var providerOptions: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        file: [String: String],
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.file = file
        self.providerOptions = providerOptions
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct FileDeleteResult: Sendable {
    public var providerReference: [String: String]
    public var deleted: Bool
    public var providerMetadata: [String: JSONValue]
    public var warnings: [AIWarning]
    public var rawValue: JSONValue
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        providerReference: [String: String],
        deleted: Bool,
        providerMetadata: [String: JSONValue] = [:],
        warnings: [AIWarning] = [],
        rawValue: JSONValue = .null,
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.providerReference = providerReference
        self.deleted = deleted
        self.providerMetadata = providerMetadata
        self.warnings = warnings
        self.rawValue = rawValue
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct SkillUploadFile: Equatable, Sendable {
    public var path: String
    public var data: Data
    public var mediaType: String

    public init(path: String, data: Data, mediaType: String = "application/octet-stream") {
        self.path = path
        self.data = data
        self.mediaType = mediaType
    }
}

public struct SkillUploadRequest: Sendable {
    public var files: [SkillUploadFile]
    public var displayTitle: String?
    public var providerOptions: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        files: [SkillUploadFile],
        displayTitle: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.files = files
        self.displayTitle = displayTitle
        self.providerOptions = providerOptions
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct AIWarning: Equatable, Sendable {
    public var type: String
    public var feature: String?
    public var setting: String?
    public var message: String?

    public init(type: String, feature: String? = nil, setting: String? = nil, message: String? = nil) {
        self.type = type
        self.feature = feature
        self.setting = setting
        self.message = message
    }
}

public struct SkillUploadResult: Sendable {
    public var providerReference: [String: String]
    public var displayTitle: String?
    public var name: String?
    public var description: String?
    public var latestVersion: String?
    public var providerMetadata: [String: JSONValue]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata
    public var warnings: [AIWarning]
    public var rawValue: JSONValue

    public init(
        providerReference: [String: String],
        displayTitle: String? = nil,
        name: String? = nil,
        description: String? = nil,
        latestVersion: String? = nil,
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata(),
        warnings: [AIWarning] = [],
        rawValue: JSONValue
    ) {
        self.providerReference = providerReference
        self.displayTitle = displayTitle
        self.name = name
        self.description = description
        self.latestVersion = latestVersion
        self.providerMetadata = providerMetadata
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
        self.warnings = warnings
        self.rawValue = rawValue
    }
}

public struct TokenUsage: Equatable, Codable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var inputTokensNoCache: Int?
    public var inputTokensCacheRead: Int?
    public var inputTokensCacheWrite: Int?
    public var outputTextTokens: Int?
    public var outputReasoningTokens: Int?
    public var rawValue: JSONValue?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        inputTokensNoCache: Int? = nil,
        inputTokensCacheRead: Int? = nil,
        inputTokensCacheWrite: Int? = nil,
        outputTextTokens: Int? = nil,
        outputReasoningTokens: Int? = nil,
        rawValue: JSONValue? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.inputTokensNoCache = inputTokensNoCache
        self.inputTokensCacheRead = inputTokensCacheRead
        self.inputTokensCacheWrite = inputTokensCacheWrite
        self.outputTextTokens = outputTextTokens
        self.outputReasoningTokens = outputReasoningTokens
        self.rawValue = rawValue
    }
}