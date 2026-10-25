import Foundation
import SwiftAIProvider
import SwiftAITransport


/// A structured failure reported after a provider response stream has started.
public struct AIStreamProviderError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var type: String?
    /// Provider-defined string or numeric code.
    public var code: JSONValue?
    public var statusCode: Int?
    public var isRetryable: Bool
    /// Original provider payload.
    public var data: JSONValue?

    public init(
        message: String,
        type: String? = nil,
        code: JSONValue? = nil,
        statusCode: Int? = nil,
        isRetryable: Bool? = nil,
        data: JSONValue? = nil
    ) {
        self.message = message
        self.type = type
        self.code = code
        self.statusCode = statusCode
        self.isRetryable = isRetryable ?? Self.retryableStatusCode(statusCode)
        self.data = data
    }

    public var description: String { message }

    private static func retryableStatusCode(_ statusCode: Int?) -> Bool {
        guard let statusCode else { return false }
        return statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
    }
}

public extension LanguageStreamPart {
    /// Creates the source-compatible stream error case while preserving typed provider metadata.
    static func providerError(_ error: AIStreamProviderError) -> LanguageStreamPart {
        var value: [String: JSONValue] = [
            "_aiSDKProviderStreamError": true,
            "message": .string(error.message),
            "isRetryable": .bool(error.isRetryable)
        ]
        if let type = error.type { value["type"] = .string(type) }
        if let code = error.code { value["code"] = code }
        if let statusCode = error.statusCode { value["statusCode"] = .number(Double(statusCode)) }
        if let data = error.data { value["data"] = data }
        return .error(message: error.message, rawValue: .object(value))
    }

    /// Typed view of an in-band provider error. Returns `nil` for non-error chunks.
    var streamProviderError: AIStreamProviderError? {
        guard case let .error(message, rawValue) = self else { return nil }
        return normalizeStreamProviderError(message: message, rawValue: rawValue)
    }
}


func normalizeStreamProviderError(
    message fallbackMessage: String,
    rawValue: JSONValue?
) -> AIStreamProviderError {
    let outer = rawValue?.objectValue
    let details = outer?["response"]?["error"]?.objectValue
        ?? outer?["error"]?.objectValue
        ?? outer
    let message = details?["message"]?.stringValue ?? fallbackMessage
    let type = details?["type"]?.stringValue ?? outer?["type"]?.stringValue
    let code = streamProviderErrorCode(details?["code"] ?? outer?["code"])
    let explicitStatusCode = [
        details?["statusCode"], outer?["statusCode"],
        details?["status_code"], outer?["status_code"],
        details?["status"], outer?["status"],
        details?["code"], outer?["code"]
    ].lazy.compactMap(streamProviderHTTPStatusCode).first
    let inferred = inferredStreamProviderErrorMetadata(message: message)
    let statusCode = explicitStatusCode ?? inferred?.statusCode
    let explicitRetryability = [
        details?["isRetryable"]?.boolValue, outer?["isRetryable"]?.boolValue,
        details?["is_retryable"]?.boolValue, outer?["is_retryable"]?.boolValue
    ].compactMap { $0 }.first
    let isRetryable = explicitRetryability
        ?? inferred?.isRetryable
        ?? (statusCode.map { $0 == 408 || $0 == 409 || $0 == 429 || $0 >= 500 } ?? false)
    let data = outer?["_aiSDKProviderStreamError"]?.boolValue == true
        ? outer?["data"]
        : rawValue

    return AIStreamProviderError(
        message: message,
        type: type,
        code: code,
        statusCode: statusCode,
        isRetryable: isRetryable,
        data: data
    )
}

private func streamProviderErrorCode(_ value: JSONValue?) -> JSONValue? {
    guard let value else { return nil }
    if value.stringValue != nil || value.doubleValue != nil { return value }
    return nil
}

private func streamProviderHTTPStatusCode(_ value: JSONValue?) -> Int? {
    guard let value else { return nil }
    if case let .number(number) = value,
       number.isFinite,
       number.rounded(.towardZero) == number,
       (400.0...599.0).contains(number) {
        return Int(number)
    }
    if let stringValue = value.stringValue,
              stringValue.count == 3,
              stringValue.allSatisfy(\.isNumber),
       let statusCode = Int(stringValue),
       400...599 ~= statusCode {
        return statusCode
    }
    return nil
}

private func inferredStreamProviderErrorMetadata(
    message: String
) -> (statusCode: Int, isRetryable: Bool)? {
    switch message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "overloaded", "overloaded error", "model overloaded", "service unavailable":
        return (503, true)
    case "internal server error":
        return (500, true)
    default:
        return nil
    }
}