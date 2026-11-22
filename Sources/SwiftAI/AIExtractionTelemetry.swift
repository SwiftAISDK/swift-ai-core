import SwiftAIProvider
import SwiftAIProviderUtilities

/// The trusted application callback receives original operation inputs.
public struct AIExtractionStartEvent: Equatable, Sendable {
    public let callID: String
    public let operationID = "ai.extract"
    public let providerID: String
    public let modelID: String
    public let state: AIDecisionState
    public let fields: [String: AIExtractionField]
    public let referenceDate: String?
    public let maxOutputTokens: Int?
    public let reasoning: String?
    public let maxRetries: Int
    public let headers: [String: String]
    public let providerOptions: [String: JSONValue]
    public let runtimeContext: [String: JSONValue]
}

/// Delivered after every answer has been validated and normalized.
public struct AIExtractionEndEvent: Equatable, Sendable {
    public let start: AIExtractionStartEvent
    public let result: AIExtractionResult
    public var callID: String { start.callID }
    public var operationID: String { start.operationID }
    public var runtimeContext: [String: JSONValue] { start.runtimeContext }
}

func extractionTelemetryInput(
    state: AIDecisionState,
    fields: [String: AIExtractionField],
    referenceDate: String?,
    maxOutputTokens: Int? = nil,
    reasoning: String? = nil
) -> JSONValue {
    let stateValue: JSONValue
    if case let .parts(parts) = state {
        stateValue = .array(parts.map { part in
            var value = decisionStatePartJSON(part)
            if case let .file(_, data, _, _) = part, var object = value.objectValue {
                switch data {
                case .reference, .url: object["data"] = "[redacted]"
                case .data, .base64: break
                }
                // File provider options are consumed by the adapter, not a telemetry integration.
                object.removeValue(forKey: "providerOptions")
                value = .object(object)
            }
            return value
        })
    } else {
        stateValue = decisionStateJSON(state)
    }
    let fieldValues = fields.mapValues { field in
        let values: [String: JSONValue?] = [
            "type": .string(field.type.rawValue),
            "instructions": field.instructions,
            "unit": field.unit.map(JSONValue.string),
            "integer": field.integer.map(JSONValue.bool),
            "decimals": field.decimals.map { .number(Double($0)) },
            "items": field.items.map { .string($0.rawValue) }
        ]
        return JSONValue.object(values)
    }
    let values: [String: JSONValue?] = [
        "state": stateValue,
        "fields": .object(fieldValues),
        "referenceDate": referenceDate.map(JSONValue.string),
        "maxOutputTokens": maxOutputTokens.map { .number(Double($0)) },
        "reasoning": reasoning.map(JSONValue.string)
    ]
    return .object(values)
}

func extractionTelemetryOutput(_ answers: [String: AIExtractionAnswer]) -> JSONValue {
    .object(["answers": .object(answers.mapValues { answer in
        let values: [String: JSONValue?] = [
            "type": .string(answer.type.rawValue),
            "value": answer.type == .refusal ? Optional.none : (answer.value ?? .null),
            "guess": answer.guess,
            "pNull": answer.pNull.map(JSONValue.number),
            "confidence": answer.confidence.map(JSONValue.number),
            "source": answer.source.map(extractionSourceTelemetryJSON),
            "items": answer.items.map { items in
                .array(items.map { item in
                    .object(["confidence": item.confidence.map(JSONValue.number),
                             "source": item.source.map(extractionSourceTelemetryJSON)])
                })
            }
        ]
        return .object(values)
    })])
}

private func extractionSourceTelemetryJSON(_ source: AIExtractionSource) -> JSONValue {
    switch source {
    case let .text(part, start, end):
        return ["type": "text", "part": .number(Double(part)), "start": .number(Double(start)), "end": .number(Double(end))]
    case let .file(part):
        return ["type": "file", "part": .number(Double(part))]
    }
}
