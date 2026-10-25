import Foundation


public func getErrorMessage(_ value: Any?) -> String {
    guard let value else { return "unknown error" }
    if let string = value as? String { return string }
    if let jsonValue = value as? JSONValue { return errorMessageCompactJSONString(jsonValue) }
    if let bool = value as? Bool { return String(bool) }
    if let int = value as? Int { return String(int) }
    if let double = value as? Double { return errorMessageNumberString(double) }
    if let convertible = value as? CustomStringConvertible { return convertible.description }
    if let error = value as? Error { return String(describing: error) }
    return String(describing: value)
}

public struct AIAPICallError: Error, Equatable, CustomStringConvertible, Sendable {
    /// A provider's explanatory message, while responseBody retains the wire body.
    public var message: String? = nil
    public var provider: String
    public var url: String?
    public var requestBody: JSONValue?
    public var statusCode: Int
    public var responseHeaders: [String: String]
    public var responseBody: String
    public var isRetryable: Bool

    public init(
        provider: String,
        url: String? = nil,
        requestBody: JSONValue? = nil,
        statusCode: Int,
        responseHeaders: [String: String] = [:],
        responseBody: String,
        isRetryable: Bool? = nil
    ) {
        self.provider = provider
        self.url = url
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.isRetryable = isRetryable ?? Self.defaultRetryableStatus(statusCode)
    }

    public var description: String {
        "\(provider) request failed with HTTP \(statusCode): \(message ?? responseBody)"
    }

    private static func defaultRetryableStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
    }
}

private func errorMessageCompactJSONString(_ value: JSONValue) -> String {
    switch value {
    case let .string(string):
        return errorMessageJSONStringLiteral(string)
    case let .number(number):
        return errorMessageNumberString(number)
    case let .bool(bool):
        return String(bool)
    case let .array(array):
        return "[\(array.map(errorMessageCompactJSONString).joined(separator: ","))]"
    case let .object(object):
        return "{\(object.keys.sorted().map { "\(errorMessageJSONStringLiteral($0)):\(errorMessageCompactJSONString(object[$0] ?? .null))" }.joined(separator: ","))}"
    case .null:
        return "null"
    }
}

private func errorMessageNumberString(_ value: Double) -> String {
    if let integer = Int(exactly: value) {
        return String(integer)
    }
    return String(value)
}

private func errorMessageJSONStringLiteral(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let string = String(data: data, encoding: .utf8) else {
        return "\"\(value)\""
    }
    return string
}

public struct AITypeValidationContext: Equatable, Hashable, Sendable {
    public var field: String
    public var entityName: String

    public init(field: String, entityName: String) {
        self.field = field
        self.entityName = entityName
    }
}

public struct AITypeValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    public var value: JSONValue?
    public var schema: JSONValue?
    public var path: String
    public var message: String
    public var context: AITypeValidationContext?

    public init(
        value: JSONValue? = nil,
        schema: JSONValue? = nil,
        path: String,
        message: String,
        context: AITypeValidationContext? = nil
    ) {
        self.value = value
        self.schema = schema
        self.path = path
        self.message = message
        self.context = context
    }

    public var description: String {
        "\(path): \(message)"
    }
}

public struct AITooManyEmbeddingValuesForCallError: Error, Equatable, CustomStringConvertible, Sendable {
    public var provider: String
    public var modelID: String
    public var maxEmbeddingsPerCall: Int
    public var values: [String]

    public init(
        provider: String,
        modelID: String,
        maxEmbeddingsPerCall: Int,
        values: [String]
    ) {
        self.provider = provider
        self.modelID = modelID
        self.maxEmbeddingsPerCall = maxEmbeddingsPerCall
        self.values = values
    }

    public var description: String {
        "Too many values for a single embedding call. The \(provider) model \"\(modelID)\" can only embed up to \(maxEmbeddingsPerCall) values per call, but \(values.count) values were provided."
    }
}

public struct AINoSuchToolError: Error, Equatable, CustomStringConvertible, Sendable {
    public var toolName: String
    public var availableToolNames: [String]

    public init(toolName: String, availableToolNames: [String] = []) {
        self.toolName = toolName
        self.availableToolNames = availableToolNames.sorted()
    }

    public var description: String {
        guard !availableToolNames.isEmpty else {
            return "No such tool: \(toolName)."
        }
        return "No such tool: \(toolName). Available tools: \(availableToolNames.joined(separator: ", "))."
    }
}

public struct AIMissingToolResultsError: Error, Equatable, CustomStringConvertible, Sendable {
    public var toolCallIDs: [String]

    public init(toolCallIDs: [String]) {
        self.toolCallIDs = toolCallIDs
    }

    public var description: String {
        let plural = toolCallIDs.count > 1
        return "Tool result\(plural ? "s are" : " is") missing for tool call\(plural ? "s" : "") \(toolCallIDs.joined(separator: ", "))."
    }
}

public struct AIInvalidToolApprovalError: Error, Equatable, CustomStringConvertible, Sendable {
    public var approvalID: String

    public init(approvalID: String) {
        self.approvalID = approvalID
    }

    public var description: String {
        "Tool approval response references unknown approvalId: \"\(approvalID)\". No matching tool-approval-request found in message history."
    }
}

public struct AIToolCallNotFoundForApprovalError: Error, Equatable, CustomStringConvertible, Sendable {
    public var toolCallID: String
    public var approvalID: String

    public init(toolCallID: String, approvalID: String) {
        self.toolCallID = toolCallID
        self.approvalID = approvalID
    }

    public var description: String {
        "Tool call \"\(toolCallID)\" not found for approval request \"\(approvalID)\"."
    }
}

public struct AIInvalidToolApprovalSignatureError: Error, Equatable, CustomStringConvertible, Sendable {
    public var approvalID: String
    public var toolCallID: String
    public var reason: String

    public init(approvalID: String, toolCallID: String, reason: String) {
        self.approvalID = approvalID
        self.toolCallID = toolCallID
        self.reason = reason
    }

    public var description: String {
        "Invalid tool approval signature for approval \"\(approvalID)\" and tool call \"\(toolCallID)\": \(reason)."
    }
}

public struct AIInvalidToolInputError: Error, Equatable, CustomStringConvertible, Sendable {
    public var toolName: String
    public var toolCallID: String?
    public var input: JSONValue?
    public var message: String
    public var validationError: AITypeValidationError?

    public init(
        toolName: String,
        toolCallID: String? = nil,
        input: JSONValue? = nil,
        message: String,
        validationError: AITypeValidationError? = nil
    ) {
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.input = input
        self.message = message
        self.validationError = validationError
    }

    public var description: String {
        let idSuffix = toolCallID.map { " call \($0)" } ?? ""
        return "Invalid input for tool \(toolName)\(idSuffix): \(message)"
    }
}

public struct AIToolCallRepairError: Error, Equatable, CustomStringConvertible, Sendable {
    public var toolName: String
    public var toolCallID: String?
    public var originalError: String
    public var repairedInput: JSONValue?

    public init(
        toolName: String,
        toolCallID: String? = nil,
        originalError: String,
        repairedInput: JSONValue? = nil
    ) {
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.originalError = originalError
        self.repairedInput = repairedInput
    }

    public var description: String {
        let idSuffix = toolCallID.map { " call \($0)" } ?? ""
        return "Tool input repair failed for \(toolName)\(idSuffix): \(originalError)"
    }
}

public extension AIError {
    static func apiCall(
        provider: String,
        statusCode: Int,
        body: String,
        headers: [String: String] = [:]
    ) -> AIError {
        .apiCall(AIAPICallError(
            provider: provider,
            statusCode: statusCode,
            responseHeaders: headers,
            responseBody: body
        ))
    }

    var apiCallError: AIAPICallError? {
        switch self {
        case let .apiCall(error):
            return error
        case let .gateway(error):
            return AIAPICallError(
                provider: "gateway",
                statusCode: error.statusCode,
                responseHeaders: error.headers,
                responseBody: error.message,
                isRetryable: error.isRetryable
            )
        default:
            return nil
        }
    }
}
