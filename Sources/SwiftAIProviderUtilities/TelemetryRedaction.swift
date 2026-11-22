import SwiftAIProvider

/// Visits only SDK-owned metadata containers. Prompt text, tool outputs and
/// application runtime context are never traversed. Failures omit the affected
/// metadata so a broken provider hook cannot expose credentials or fail a call.
public func redactTelemetryCredentials(_ value: JSONValue, redactor: AITelemetryRedactor) -> JSONValue {
    guard var object = value.objectValue else { return value }
    if let args = object["args"] { object["args"] = try? redactor(args) }
    for key in ["tools", "stepTools"] {
        if let tools = object[key]?.arrayValue { object[key] = .array(tools.map { redactTool($0, redactor: redactor) }) }
        else if let tools = object[key]?.objectValue { object[key] = .object(tools.mapValues { redactTool($0, redactor: redactor) }) }
    }
    for key in ["request", "response", "requestMetadata", "responseMetadata"] {
        if let metadata = object[key]?.arrayValue { object[key] = .array(metadata.map { redactMetadata($0, redactor: redactor) }) }
        else if let metadata = object[key] { object[key] = redactMetadata(metadata, redactor: redactor) }
    }
    for key in ["requestBodyValues", "rawValue"] {
        if let body = object[key] { object[key] = try? redactor(body) }
    }
    for key in ["steps", "finalStep", "error", "cause", "errors", "lastError"] {
        if let children = object[key]?.arrayValue { object[key] = .array(children.map { redactTelemetryCredentials($0, redactor: redactor) }) }
        else if let child = object[key] { object[key] = redactTelemetryCredentials(child, redactor: redactor) }
    }
    return .object(object)
}

private func redactTool(_ value: JSONValue, redactor: AITelemetryRedactor) -> JSONValue {
    guard var tool = value.objectValue, tool["id"]?.stringValue != nil, let args = tool["args"] else {
        return redactTelemetryCredentials(value, redactor: redactor)
    }
    // Provider-defined tools supply a wrapper so a hook can distinguish
    // credential fields from identical application-provided arguments.
    let contextualArgs = (try? redactor(value))?["args"]
    if contextualArgs == args {
        return redactTelemetryCredentials(value, redactor: redactor)
    }
    tool.removeValue(forKey: "args")
    var result = redactTelemetryCredentials(.object(tool), redactor: redactor).objectValue ?? tool
    result["args"] = contextualArgs
    return .object(result)
}

private func redactMetadata(_ value: JSONValue, redactor: AITelemetryRedactor) -> JSONValue {
    guard var object = value.objectValue else { return value }
    if let body = object["body"] { object["body"] = (try? redactor(body)).map { redactTelemetryCredentials($0, redactor: redactor) } }
    return .object(object)
}
