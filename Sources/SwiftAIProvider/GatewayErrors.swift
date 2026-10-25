import Foundation


public enum GatewayErrorType: String, Equatable, Hashable, Sendable {
    case authenticationError = "authentication_error"
    case invalidRequestError = "invalid_request_error"
    case rateLimitExceeded = "rate_limit_exceeded"
    case modelNotFound = "model_not_found"
    case failedDependency = "failed_dependency"
    case forbidden = "forbidden"
    case internalServerError = "internal_server_error"
    case responseError = "response_error"
    case timeoutError = "timeout_error"

    /// Source-compatible spelling for Gateway's generic `not_found` error.
    /// Inspect ``GatewayError/upstreamType`` when distinguishing it from
    /// `model_not_found`, since adding a public enum case would break
    /// exhaustive switches compiled against earlier SwiftAISDK releases.
    public static let notFound = GatewayErrorType.modelNotFound
}

public struct GatewayError: Error, Equatable, Sendable, CustomStringConvertible {
    public var type: GatewayErrorType
    public var message: String
    public var statusCode: Int
    public var generationID: String?
    public var modelID: String?
    public var response: JSONValue?
    public var headers: [String: String]
    public var isRetryable: Bool
    public var cause: AIAPICallError?

    public init(
        type: GatewayErrorType,
        message: String,
        statusCode: Int = 500,
        generationID: String? = nil,
        modelID: String? = nil,
        response: JSONValue? = nil,
        headers: [String: String] = [:],
        isRetryable: Bool? = nil,
        cause: AIAPICallError? = nil
    ) {
        self.type = type
        self.message = message
        self.statusCode = statusCode
        self.generationID = generationID
        self.modelID = modelID
        self.response = response
        self.headers = headers
        self.isRetryable = isRetryable ?? gatewayStatusIsRetryable(statusCode)
        self.cause = cause
    }

    public var name: String {
        if isNotFound {
            return "GatewayNotFoundError"
        }
        switch type {
        case .authenticationError:
            return "GatewayAuthenticationError"
        case .invalidRequestError:
            return "GatewayInvalidRequestError"
        case .rateLimitExceeded:
            return "GatewayRateLimitError"
        case .modelNotFound:
            return "GatewayModelNotFoundError"
        case .failedDependency:
            return "GatewayFailedDependencyError"
        case .forbidden:
            return "GatewayForbiddenError"
        case .internalServerError:
            return "GatewayInternalServerError"
        case .responseError:
            return "GatewayResponseError"
        case .timeoutError:
            return "GatewayTimeoutError"
        }
    }

    /// The exact upstream Gateway error discriminator when it is available.
    public var upstreamType: String {
        if let rawType = response?["error"]?["type"]?.stringValue {
            return rawType
        }
        if response?["type"]?.stringValue == "error",
           let rawType = response?["errorType"]?.stringValue {
            return rawType
        }
        return type.rawValue
    }

    /// Whether Gateway returned its generic `not_found` discriminator.
    public var isNotFound: Bool {
        upstreamType == "not_found"
    }

    public var description: String {
        if let generationID {
            return "\(message) [\(generationID)]"
        }
        return message
    }
}
private func gatewayStatusIsRetryable(_ statusCode: Int) -> Bool {
    statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
}