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
        if isAccessPolicyDenied {
            return "GatewayAccessPolicyDeniedError"
        }
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

    /// Whether a Gateway access policy denied the requested model or provider.
    public var isAccessPolicyDenied: Bool {
        type == .forbidden && upstreamType == "access_policy_denied"
    }

    /// IDs of the policies that apply to the denial, when provided by Gateway.
    public var policyIDs: [String]? { accessPolicyDetails["policyIds"] }

    /// Models omitted by the policies, when provided by Gateway.
    public var removedModels: [String]? { accessPolicyDetails["removedModels"] }

    /// Providers omitted by the policies, when provided by Gateway.
    public var removedProviders: [String]? { accessPolicyDetails["removedProviders"] }

    private var accessPolicyDetails: [String: [String]] {
        guard isAccessPolicyDenied,
              let parameters = (response?["error"]?["param"] ?? response?["param"])?.objectValue else {
            return [:]
        }
        var result: [String: [String]] = [:]
        for key in ["policyIds", "removedModels", "removedProviders"] {
            guard let field = parameters[key] else { continue }
            guard let items = field.arrayValue else { return [:] }
            let strings = items.compactMap(\.stringValue)
            guard strings.count == items.count else { return [:] }
            result[key] = strings
        }
        return result
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
