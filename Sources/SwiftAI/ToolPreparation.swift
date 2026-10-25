import Foundation
import CryptoKit
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


private let functionToolMetadataKeys: Set<String> = [
    "description",
    "inputExamples",
    "providerOptions",
    "strict"
]

func prepareTools(
    tools: [String: JSONValue]?,
    toolOrder: [String]? = nil
) -> [JSONValue]? {
    guard let tools, !tools.isEmpty else { return nil }

    return orderedToolEntries(tools: tools, toolOrder: toolOrder).map { name, tool in
        let object = tool.objectValue
        if object?["type"]?.stringValue == "provider" || object?["id"]?.stringValue != nil {
            return .object([
                "type": .string("provider"),
                "name": .string(name),
                "id": object?["id"] ?? .string(name),
                "args": object?["args"] ?? .object([:])
            ])
        }

        var output: [String: JSONValue] = [
            "type": .string("function"),
            "name": .string(name),
            "inputSchema": inputSchemaWithoutToolMetadata(tool)
        ]
        if let description = object?["description"] {
            output["description"] = description
        }
        if let inputExamples = object?["inputExamples"] {
            output["inputExamples"] = inputExamples
        }
        if let providerOptions = object?["providerOptions"] {
            output["providerOptions"] = providerOptions
        }
        if let strict = object?["strict"] {
            output["strict"] = strict
        }
        return .object(output)
    }
}

func filterActiveTools(
    tools: [String: JSONValue]?,
    activeTools: [String]?
) -> [String: JSONValue]? {
    guard let tools else { return nil }
    guard let activeTools else { return tools }

    return tools.filter { name, _ in activeTools.contains(name) }
}

func signToolApproval(
    secret: String,
    approvalID: String,
    toolCallID: String,
    toolName: String,
    input: JSONValue
) -> String {
    signToolApproval(
        secret: Data(secret.utf8),
        approvalID: approvalID,
        toolCallID: toolCallID,
        toolName: toolName,
        input: input
    )
}

func signToolApproval(
    secret: Data,
    approvalID: String,
    toolCallID: String,
    toolName: String,
    input: JSONValue
) -> String {
    let payload = toolApprovalSigningPayload(
        approvalID: approvalID,
        toolCallID: toolCallID,
        toolName: toolName,
        input: input
    )
    let signature = HMAC<SHA256>.authenticationCode(
        for: Data(payload.utf8),
        using: SymmetricKey(data: secret)
    )
    return toolApprovalBase64URL(Data(signature))
}

func verifyToolApprovalSignature(
    secret: String,
    signature: String,
    approvalID: String,
    toolCallID: String,
    toolName: String,
    input: JSONValue
) -> Bool {
    verifyToolApprovalSignature(
        secret: Data(secret.utf8),
        signature: signature,
        approvalID: approvalID,
        toolCallID: toolCallID,
        toolName: toolName,
        input: input
    )
}

func verifyToolApprovalSignature(
    secret: Data,
    signature: String,
    approvalID: String,
    toolCallID: String,
    toolName: String,
    input: JSONValue
) -> Bool {
    guard let signatureBytes = toolApprovalBase64URLData(signature) else { return false }
    let key = SymmetricKey(data: secret)
    let payload = toolApprovalSigningPayload(
        approvalID: approvalID,
        toolCallID: toolCallID,
        toolName: toolName,
        input: input
    )
    if HMAC<SHA256>.isValidAuthenticationCode(
        signatureBytes,
        authenticating: Data(payload.utf8),
        using: key
    ) {
        return true
    }

    guard !approvalID.contains("\n"),
          !toolCallID.contains("\n"),
          !toolName.contains("\n") else {
        return false
    }
    let legacyPayload = legacyToolApprovalSigningPayload(
        approvalID: approvalID,
        toolCallID: toolCallID,
        toolName: toolName,
        input: input
    )
    return HMAC<SHA256>.isValidAuthenticationCode(
        signatureBytes,
        authenticating: Data(legacyPayload.utf8),
        using: key
    )
}

func maybeSignApproval(
    secret: String?,
    approvalID: String,
    toolCallID: String,
    toolName: String,
    input: JSONValue
) -> String? {
    guard let secret else { return nil }
    return signToolApproval(
        secret: secret,
        approvalID: approvalID,
        toolCallID: toolCallID,
        toolName: toolName,
        input: input
    )
}

func validateToolContext(
    toolName: String,
    context: JSONValue,
    contextSchema: JSONValue?
) throws -> JSONValue {
    guard let contextSchema else { return context }

    do {
        try AIJSONSchemaValidator.validate(context, schema: contextSchema)
        return context
    } catch let error as AITypeValidationError {
        throw AITypeValidationError(
            value: error.value,
            schema: error.schema,
            path: error.path,
            message: error.message,
            context: AITypeValidationContext(field: "tool context", entityName: toolName)
        )
    }
}

struct AICollectedToolApproval: Equatable, Sendable {
    var approvalRequest: AIToolApprovalRequest
    var approvalResponse: AIToolApprovalResponse
    var toolCall: AIToolCall
}

struct AICollectedToolApprovals: Equatable, Sendable {
    var approvedToolApprovals: [AICollectedToolApproval]
    var deniedToolApprovals: [AICollectedToolApproval]
    var invalidToolApprovals: [AIInvalidCollectedToolApproval] = []

    static var empty: AICollectedToolApprovals {
        AICollectedToolApprovals(approvedToolApprovals: [], deniedToolApprovals: [], invalidToolApprovals: [])
    }
}

struct AIInvalidCollectedToolApproval: Equatable, Sendable {
    var approval: AICollectedToolApproval
    var error: AIInvalidToolInputError
}

func collectToolApprovals(messages: [AIMessage]) throws -> AICollectedToolApprovals {
    guard let lastMessage = messages.last, lastMessage.role == .tool else {
        return .empty
    }

    var toolCallsByID: [String: AIToolCall] = [:]
    var toolCallOrder: [String: Int] = [:]
    var nextToolCallIndex = 0
    var approvalRequestsByID: [String: AIToolApprovalRequest] = [:]
    for message in messages where message.role == .assistant {
        for part in message.content {
            switch part {
            case let .toolCall(toolCall):
                toolCallsByID[toolCall.id] = toolCall
                toolCallOrder[toolCall.id] = nextToolCallIndex
                nextToolCallIndex += 1
            case let .toolApprovalRequest(request):
                approvalRequestsByID[request.id] = request
            case .text, .reasoning, .reasoningFile, .custom, .imageURL, .data, .file, .providerReference, .toolResult, .toolApprovalResponse:
                break
            }
        }
    }

    var toolResultsByToolCallID: [String: AIToolResult] = [:]
    for part in lastMessage.content {
        if case let .toolResult(result) = part {
            toolResultsByToolCallID[result.toolCallID] = result
        }
    }

    var approvedToolApprovals: [AICollectedToolApproval] = []
    var deniedToolApprovals: [AICollectedToolApproval] = []
    var collectedToolCallIDs = Set<String>()
    for part in lastMessage.content {
        guard case let .toolApprovalResponse(response) = part else { continue }
        guard let request = approvalRequestsByID[response.id] else {
            throw AIInvalidToolApprovalError(approvalID: response.id)
        }
        guard let toolCallID = request.toolCallID,
              let toolCall = toolCallsByID[toolCallID] else {
            throw AIToolCallNotFoundForApprovalError(
                toolCallID: request.toolCallID ?? "",
                approvalID: request.id
            )
        }
        if toolResultsByToolCallID[toolCallID] != nil {
            continue
        }
        guard collectedToolCallIDs.insert(toolCallID).inserted else { continue }

        let approval = AICollectedToolApproval(
            approvalRequest: request,
            approvalResponse: response,
            toolCall: toolCall
        )
        if response.approved {
            approvedToolApprovals.append(approval)
        } else {
            deniedToolApprovals.append(approval)
        }
    }

    approvedToolApprovals.sort { (toolCallOrder[$0.toolCall.id] ?? 0) < (toolCallOrder[$1.toolCall.id] ?? 0) }
    return AICollectedToolApprovals(
        approvedToolApprovals: approvedToolApprovals,
        deniedToolApprovals: deniedToolApprovals,
        invalidToolApprovals: []
    )
}

func validateApprovedToolApprovals(
    approvedToolApprovals: [AICollectedToolApproval],
    toolsByName: [String: AITool],
    request: LanguageModelRequest,
    toolApproval: AIToolApproval?,
    toolApprovalSecret: String? = nil
) async throws -> AICollectedToolApprovals {
    var approved: [AICollectedToolApproval] = []
    var denied: [AICollectedToolApproval] = []
    var invalid: [AIInvalidCollectedToolApproval] = []

    for approval in approvedToolApprovals {
        let toolCall = approval.toolCall
        guard let tool = toolsByName[toolCall.name] else {
            throw AINoSuchToolError(toolName: toolCall.name, availableToolNames: Array(toolsByName.keys))
        }
        let arguments: JSONValue
        do {
            arguments = try toolArguments(from: toolCall)
        } catch let error as AIInvalidToolInputError {
            invalid.append(AIInvalidCollectedToolApproval(approval: approval, error: error))
            continue
        }

        if let toolApprovalSecret {
            let signature = approval.approvalRequest.providerMetadata["signature"]?.stringValue
            guard let signature else {
                throw AIInvalidToolApprovalSignatureError(
                    approvalID: approval.approvalRequest.id,
                    toolCallID: toolCall.id,
                    reason: "missing signature"
                )
            }

            let valid = verifyToolApprovalSignature(
                secret: toolApprovalSecret,
                signature: signature,
                approvalID: approval.approvalRequest.id,
                toolCallID: toolCall.id,
                toolName: toolCall.name,
                input: arguments
            )
            guard valid else {
                throw AIInvalidToolApprovalSignatureError(
                    approvalID: approval.approvalRequest.id,
                    toolCallID: toolCall.id,
                    reason: "invalid signature"
                )
            }
        }

        let inputSchemaInput = approval.approvalRequest.inputSchemaInput ?? arguments
        do {
            try validateToolArguments(inputSchemaInput, schema: tool.parameters, call: toolCall)
        } catch let error as AIInvalidToolInputError {
            invalid.append(AIInvalidCollectedToolApproval(approval: approval, error: error))
            continue
        }

        let revalidatedArguments: JSONValue
        do {
            revalidatedArguments = try await tool.refineArguments?(inputSchemaInput) ?? inputSchemaInput
        } catch {
            invalid.append(AIInvalidCollectedToolApproval(
                approval: approval,
                error: AIInvalidToolInputError(
                    toolName: toolCall.name,
                    toolCallID: toolCall.id,
                    input: inputSchemaInput,
                    message: "Approved tool input could not be refined: \(error)"
                )
            ))
            continue
        }
        guard revalidatedArguments == arguments else {
            invalid.append(AIInvalidCollectedToolApproval(
                approval: approval,
                error: AIInvalidToolInputError(
                    toolName: toolCall.name,
                    toolCallID: toolCall.id,
                    input: inputSchemaInput,
                    message: "Approved tool input does not match the validated schema output."
                )
            ))
            continue
        }

        let approvalStatus = try await resolveToolApproval(
            toolsByName: toolsByName,
            toolCall: toolCall,
            arguments: arguments,
            request: request,
            toolApproval: toolApproval
        )

        if case let .denied(reason) = approvalStatus {
            var deniedApproval = approval
            deniedApproval.approvalResponse.approved = false
            deniedApproval.approvalResponse.reason = reason ?? deniedApproval.approvalResponse.reason
            denied.append(deniedApproval)
        } else {
            approved.append(approval)
        }
    }

    return AICollectedToolApprovals(
        approvedToolApprovals: approved,
        deniedToolApprovals: denied,
        invalidToolApprovals: invalid
    )
}

private func toolApprovalSigningPayload(
    approvalID: String,
    toolCallID: String,
    toolName: String,
    input: JSONValue
) -> String {
    let inputDigest = toolApprovalBase64URL(Data(SHA256.hash(data: Data(toolApprovalCanonicalJSON(input).utf8))))
    let fields = [
        "ai-sdk-tool-approval-v1",
        approvalID,
        toolCallID,
        toolName,
        inputDigest
    ]
    .map(toolApprovalJSONStringLiteral)
    .joined(separator: ",")
    return "[\(fields)]"
}

private func legacyToolApprovalSigningPayload(
    approvalID: String,
    toolCallID: String,
    toolName: String,
    input: JSONValue
) -> String {
    let inputDigest = toolApprovalBase64URL(Data(SHA256.hash(data: Data(toolApprovalCanonicalJSON(input).utf8))))
    return "\(approvalID)\n\(toolCallID)\n\(toolName)\n\(inputDigest)"
}

private func toolApprovalCanonicalJSON(_ value: JSONValue) -> String {
    switch value {
    case let .string(string):
        return toolApprovalJSONStringLiteral(string)
    case let .number(number):
        return toolApprovalJSONNumber(number)
    case let .bool(bool):
        return bool ? "true" : "false"
    case let .array(array):
        return "[\(array.map(toolApprovalCanonicalJSON).joined(separator: ","))]"
    case let .object(object):
        let entries = object.keys.sorted {
            $0.utf16.lexicographicallyPrecedes($1.utf16)
        }.map { key in
            "\(toolApprovalJSONStringLiteral(key)):\(toolApprovalCanonicalJSON(object[key] ?? .null))"
        }
        return "{\(entries.joined(separator: ","))}"
    case .null:
        return "null"
    }
}

private func toolApprovalJSONNumber(_ number: Double) -> String {
    guard number.isFinite else {
        return "null"
    }
    guard number != 0 else {
        return "0"
    }

    let isNegative = number < 0
    let components = String(abs(number)).split(
        separator: "e",
        maxSplits: 1,
        omittingEmptySubsequences: false
    )
    let mantissa = components[0]
    let exponent = components.count == 2 ? Int(components[1]) ?? 0 : 0
    let decimalOffset = mantissa.firstIndex(of: ".").map {
        mantissa.distance(from: mantissa.startIndex, to: $0)
    } ?? mantissa.count

    var digits = String(mantissa.filter { $0 != "." })
    let leadingZeroCount = digits.prefix(while: { $0 == "0" }).count
    digits.removeFirst(leadingZeroCount)
    let decimalPosition = decimalOffset + exponent - leadingZeroCount

    while digits.last == "0" {
        digits.removeLast()
    }
    guard !digits.isEmpty else {
        return "0"
    }

    let unsigned: String
    // Match ECMAScript Number::toString, which JSON.stringify uses:
    // fixed notation from 1e-6 through values below 1e21, scientific otherwise.
    if decimalPosition > 0, decimalPosition <= 21 {
        if decimalPosition >= digits.count {
            unsigned = digits + String(repeating: "0", count: decimalPosition - digits.count)
        } else {
            let splitIndex = digits.index(digits.startIndex, offsetBy: decimalPosition)
            unsigned = "\(digits[..<splitIndex]).\(digits[splitIndex...])"
        }
    } else if decimalPosition <= 0, decimalPosition > -6 {
        unsigned = "0." + String(repeating: "0", count: -decimalPosition) + digits
    } else {
        let exponent = decimalPosition - 1
        let significand: String
        if digits.count == 1 {
            significand = digits
        } else {
            significand = "\(digits.first!).\(digits.dropFirst())"
        }
        unsigned = "\(significand)e\(exponent >= 0 ? "+" : "")\(exponent)"
    }

    return isNegative ? "-\(unsigned)" : unsigned
}

private func toolApprovalJSONStringLiteral(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let string = String(data: data, encoding: .utf8) else {
        return "\"\(value)\""
    }
    return string.replacingOccurrences(of: "\\/", with: "/")
}

private func toolApprovalBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func toolApprovalBase64URLData(_ string: String) -> Data? {
    var base64 = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    base64.append(String(repeating: "=", count: padding))
    return Data(base64Encoded: base64)
}

private func orderedToolEntries(
    tools: [String: JSONValue],
    toolOrder: [String]?
) -> [(String, JSONValue)] {
    guard let toolOrder else {
        return tools.map { ($0.key, $0.value) }
    }

    let ordered = tools
        .filter { name, _ in toolOrder.contains(name) }
        .sorted { lhs, rhs in
            (toolOrder.firstIndex(of: lhs.key) ?? Int.max) < (toolOrder.firstIndex(of: rhs.key) ?? Int.max)
        }
        .map { ($0.key, $0.value) }

    let unordered = tools
        .filter { name, _ in !toolOrder.contains(name) }
        .sorted { lhs, rhs in lhs.key < rhs.key }
        .map { ($0.key, $0.value) }

    return ordered + unordered
}

private func inputSchemaWithoutToolMetadata(_ tool: JSONValue) -> JSONValue {
    guard var object = tool.objectValue else { return tool }
    for key in functionToolMetadataKeys {
        object.removeValue(forKey: key)
    }
    return .object(object)
}