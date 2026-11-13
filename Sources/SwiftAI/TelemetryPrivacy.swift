import Foundation
import SwiftAIProvider
import SwiftAIProviderUtilities

/// HTTP origin only: credentials, path, query and fragment never cross the language-result boundary.
public func requestOrigin(_ endpoint: String?) -> String? {
    guard let endpoint, var components = URLComponents(string: endpoint),
          let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = components.host, !host.isEmpty else { return nil }
    components.scheme = scheme; components.host = host.lowercased()
    components.user = nil; components.password = nil; components.path = ""; components.query = nil; components.fragment = nil
    if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
    return components.string
}

func sanitizedRequestMetadata(_ request: AIRequestMetadata) -> AIRequestMetadata {
    var result = request; result.url = requestOrigin(request.url); return result
}

func filteredTelemetryEvent(_ event: Telemetry.Event) -> Telemetry.Event {
    guard !event.includesInput || !event.includesOutput else { return event }
    var result = event
    if !event.includesInput { result.input = nil }
    if !event.includesOutput { result.output = nil }
    else if let output = result.output { result.output = filterTelemetryPayload(output, hideInputs: !event.includesInput, hideOutputs: !event.includesOutput) }
    result.providerMetadata = [:]
    result.responseMetadata.body = nil
    if result.errorDescription != nil { result.errorDescription = "AI SDK operation failed" }
    return result
}

private func filterTelemetryPayload(_ value: JSONValue, hideInputs: Bool, hideOutputs: Bool) -> JSONValue {
    guard case let .object(object) = value else { return value }
    var result = object
    for key in ["rawValue", "providerMetadata"] { result.removeValue(forKey: key) }
    for key in ["requestMetadata", "responseMetadata", "request", "response"] {
        if var metadata = result[key]?.objectValue { metadata.removeValue(forKey: "body"); result[key] = .object(metadata) }
    }
    if hideInputs {
        for key in ["messages", "promptMessages", "experimentalSteeringMessages", "tools", "stepTools", "schema", "schemaName", "schemaDescription", "providerOptions", "query", "documents", "state", "questions", "instructions", "prompt", "input", "arguments"] { result.removeValue(forKey: key) }
    }
    if hideOutputs {
        for key in ["content", "text", "reasoning", "reasoningText", "files", "sources", "toolCalls", "toolResults", "responseMessages", "object", "embedding", "embeddings", "ranking", "answers", "segments", "words", "output"] { result.removeValue(forKey: key) }
    }
    for key in ["steps", "finalStep", "toolCall", "toolOutput"] {
        if let child = result[key] {
            if let array = child.arrayValue { result[key] = .array(array.map { filterTelemetryPayload($0, hideInputs: hideInputs, hideOutputs: hideOutputs) }) }
            else { result[key] = filterTelemetryPayload(child, hideInputs: hideInputs, hideOutputs: hideOutputs) }
        }
    }
    return .object(result)
}

protocol AILanguageRequestMetadataProviding {
    var telemetryRequestMetadata: AIRequestMetadata { get }
}
extension TextGenerationResult: AILanguageRequestMetadataProviding {
    var telemetryRequestMetadata: AIRequestMetadata { requestMetadata }
}
extension ObjectGenerationResult: AILanguageRequestMetadataProviding {
    var telemetryRequestMetadata: AIRequestMetadata { textResult.requestMetadata }
}

func redactedTelemetryEvent(_ event: Telemetry.Event, redactor: AITelemetryRedactor?) -> Telemetry.Event {
    guard let redactor else { return event }
    var copy = event
    copy.input = event.input.map { redactTelemetryCredentials($0, redactor: redactor) }
    copy.output = event.output.map { redactTelemetryCredentials($0, redactor: redactor) }
    if let body = event.responseMetadata.body { copy.responseMetadata.body = try? redactor(body) }
    if event.errorDescription != nil { copy.errorDescription = "AI SDK operation failed" }
    return copy
}

/// Typed telemetry integrations receive sanitized copies and SDK callers get
/// the original value/error back when the integration forwards that view.
actor AITelemetryCallViews<Output: Sendable> {
    private var original: Output?
    private var sanitizedResult: TextGenerationResult?
    private var originalError: (any Error)?
    private var sanitizedError: AIError?

    func view(_ output: Output, redactor: AITelemetryRedactor) -> Output {
        guard var copy = output as? TextGenerationResult else { return output }
        original = output
        copy.rawValue = (try? redactor(copy.rawValue)) ?? .null
        if let body = copy.requestMetadata.body { copy.requestMetadata.body = try? redactor(body) }
        if let body = copy.responseMetadata.body { copy.responseMetadata.body = try? redactor(body) }
        for index in copy.steps.indices {
            if let body = copy.steps[index].requestMetadata?.body { copy.steps[index].requestMetadata?.body = try? redactor(body) }
            if let body = copy.steps[index].responseMetadata.body { copy.steps[index].responseMetadata.body = try? redactor(body) }
        }
        sanitizedResult = copy
        return (copy as? Output) ?? output
    }
    func view(_ error: any Error, redactor: AITelemetryRedactor) -> any Error {
        originalError = error
        let sanitized: AIError
        if let typed = error as? AIError, case var .apiCall(call) = typed {
            if let body = call.requestBody { call.requestBody = try? redactor(body) }
            if let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(call.responseBody.utf8)), let body = try? redactor(parsed) {
                call.responseBody = (try? decisionJSONText(body)) ?? "AI SDK provider request failed"
            } else { call.responseBody = "AI SDK provider request failed" }
            call.message = "AI SDK provider request failed"
            sanitized = .apiCall(call)
        } else { sanitized = .invalidResponse(provider: "telemetry", message: "AI SDK operation failed") }
        sanitizedError = sanitized
        return sanitized
    }
    func restore(_ output: Output) -> Output {
        guard let original = original as? TextGenerationResult, let sanitizedResult, var copy = output as? TextGenerationResult else { return output }
        // Restore only forwarded metadata fields so integration changes to the
        // result's other public fields are preserved under Swift value semantics.
        if copy.rawValue == sanitizedResult.rawValue { copy.rawValue = original.rawValue }
        if copy.requestMetadata.body == sanitizedResult.requestMetadata.body { copy.requestMetadata.body = original.requestMetadata.body }
        if copy.responseMetadata.body == sanitizedResult.responseMetadata.body { copy.responseMetadata.body = original.responseMetadata.body }
        if copy.steps.count == original.steps.count, copy.steps.count == sanitizedResult.steps.count {
            for index in copy.steps.indices {
                if copy.steps[index].requestMetadata?.body == sanitizedResult.steps[index].requestMetadata?.body { copy.steps[index].requestMetadata?.body = original.steps[index].requestMetadata?.body }
                if copy.steps[index].responseMetadata.body == sanitizedResult.steps[index].responseMetadata.body { copy.steps[index].responseMetadata.body = original.steps[index].responseMetadata.body }
            }
        }
        return (copy as? Output) ?? output
    }
    func restore(_ error: any Error) -> any Error {
        if let originalError, let sanitizedError, let forwarded = error as? AIError, sanitizedError == forwarded { return originalError }
        return error
    }
}
