import Foundation
import SwiftAIProvider

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
