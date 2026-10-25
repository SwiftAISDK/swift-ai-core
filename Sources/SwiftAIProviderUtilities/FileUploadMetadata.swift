import Foundation
import SwiftAIProvider
import SwiftAITransport
public func fileInteger(_ value: JSONValue?) -> Int? {
    guard let number = value?.doubleValue,
          number.isFinite,
          number.rounded(.towardZero) == number,
          let integer = Int(exactly: number) else {
        return nil
    }
    return integer
}
public func fileDate(_ value: JSONValue?) -> Date? {
    guard let seconds = value?.doubleValue, seconds.isFinite else { return nil }
    return Date(timeIntervalSince1970: seconds)
}
public func unsupportedStreamingFileUpload(providerID: String) -> AIError {
    .invalidArgument(
        argument: "data",
        message: "\(providerID) does not support streaming file upload."
    )
}
public func fileMetadata(from raw: JSONValue) -> [String: JSONValue] {
    guard case let .object(object) = raw else { return [:] }
    return object
}
public func fileProviderMetadata(from raw: JSONValue) -> JSONValue {
    var metadata: [String: JSONValue] = [:]
    metadata["filename"] = raw["filename"]
    metadata["mimeType"] = raw["mime_type"]
    metadata["sizeBytes"] = raw["size_bytes"]
    metadata["createdAt"] = raw["created_at"]
    if let downloadable = raw["downloadable"], downloadable != .null {
        metadata["downloadable"] = downloadable
    }
    return .object(metadata.compactMapValues { $0 })
}
public struct MultipartFileProviderOptions {
    public init(purpose: String? = nil, expiresAfter: Double? = nil) {
        self.purpose = purpose
        self.expiresAfter = expiresAfter
    }
    public var purpose: String?
    public var expiresAfter: Double?
}
public func multipartFileProviderOptions(_ providerOptions: [String: JSONValue], providerOptionsName: String?) throws -> MultipartFileProviderOptions {
    guard let providerOptionsName,
          let value = providerOptions[providerOptionsName],
          value != .null else {
        return MultipartFileProviderOptions()
    }
    guard let options = value.objectValue else {
        throw AIError.invalidArgument(argument: "providerOptions", message: "invalid \(providerOptionsName) provider options")
    }

    let purpose: String?
    if let value = options["purpose"] {
        guard let parsed = value.stringValue else {
            throw AIError.invalidArgument(argument: "providerOptions", message: "invalid \(providerOptionsName) provider options")
        }
        purpose = parsed
    } else {
        purpose = nil
    }

    let expiresAfter: Double?
    if let value = options["expiresAfter"] {
        guard let parsed = value.doubleValue, parsed.isFinite else {
            throw AIError.invalidArgument(argument: "providerOptions", message: "invalid \(providerOptionsName) provider options")
        }
        expiresAfter = parsed
    } else {
        expiresAfter = nil
    }

    return MultipartFileProviderOptions(purpose: purpose, expiresAfter: expiresAfter)
}
public func multipartFileUploadRequestMetadata(_ request: FileUploadRequest, includePurpose: Bool, defaultFilename: String, options: MultipartFileProviderOptions) -> AIRequestMetadata {
    var body: [String: JSONValue] = [
        "file": .object(fileUploadMetadata(request, defaultFilename: defaultFilename)),
        "mediaType": .string(request.mediaType)
    ]
    if includePurpose {
        body["purpose"] = .string(options.purpose ?? request.purpose ?? "assistants")
    }
    if let expiresAfter = options.expiresAfter {
        body["expiresAfter"] = .number(expiresAfter)
    }
    if let displayName = request.displayName {
        body["displayName"] = .string(displayName)
    }
    for (key, value) in request.extraBody where jsonScalarString(value) != nil {
        body[key] = value
    }
    return AIRequestMetadata(body: .object(body), headers: request.headers)
}
public func multipartFileUploadWarnings(_ request: FileUploadRequest, includePurpose: Bool) -> [AIWarning] {
    var warnings: [AIWarning] = []
    if request.displayName != nil {
        warnings.append(AIWarning(type: "unsupported", feature: "displayName"))
    }
    if !includePurpose, request.purpose != nil {
        warnings.append(AIWarning(type: "unsupported", feature: "purpose"))
    }
    return warnings
}
public func fileUploadMetadata(_ request: FileUploadRequest, defaultFilename: String) -> [String: JSONValue] {
    var metadata: [String: JSONValue] = [
        "filename": .string(request.filename ?? defaultFilename),
        "mediaType": .string(request.mediaType),
        "type": .string(request.fileData.isStream ? "stream" : "data")
    ]
    if let byteCount = request.fileData.byteCount {
        metadata["byteLength"] = .number(Double(byteCount))
    }
    return metadata
}
