import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func parseObject<Object: Decodable>(
    _ type: Object.Type,
    from text: String,
    schema: JSONValue? = nil,
    repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)?,
    providerID: String
) async throws -> (object: Object, rawObject: JSONValue, text: String) {
    do {
        return try decodeAndValidateObject(Object.self, from: text, schema: schema)
    } catch {
        let failure = objectGenerationError(
            error,
            providerID: providerID,
            strategy: .object,
            text: text
        )
        let message = failure.description
        guard let repairText else {
            throw failure
        }
        guard let repaired = try await repairText(AIObjectRepairContext(text: text, errorMessage: message)) else {
            throw objectGenerationRepairAttemptedError(failure)
        }
        do {
            return try decodeAndValidateObject(Object.self, from: repaired, schema: schema)
        } catch {
            throw objectGenerationError(
                error,
                providerID: providerID,
                strategy: .object,
                text: repaired,
                repairAttempted: true
            )
        }
    }
}

func parseObjectArray<Element: Decodable>(
    _ type: Element.Type,
    from text: String,
    elementSchema: JSONValue,
    repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)?,
    providerID: String
) async throws -> (object: [Element], rawObject: JSONValue, text: String) {
    let schema = arrayOutputSchema(elementSchema: elementSchema)
    do {
        return try decodeAndValidateObjectArray(Element.self, from: text, schema: schema)
    } catch {
        let failure = objectGenerationError(
            error,
            providerID: providerID,
            strategy: .array,
            text: text
        )
        let message = failure.description
        guard let repairText else {
            throw failure
        }
        guard let repaired = try await repairText(AIObjectRepairContext(text: text, errorMessage: message)) else {
            throw objectGenerationRepairAttemptedError(failure)
        }
        do {
            return try decodeAndValidateObjectArray(Element.self, from: repaired, schema: schema)
        } catch {
            throw objectGenerationError(
                error,
                providerID: providerID,
                strategy: .array,
                text: repaired,
                repairAttempted: true
            )
        }
    }
}

func parseEnum(
    from text: String,
    values: [String],
    repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)?,
    providerID: String
) async throws -> (object: String, rawObject: JSONValue, text: String) {
    let schema = enumOutputSchema(values: values)
    do {
        return try decodeAndValidateEnum(from: text, schema: schema)
    } catch {
        let failure = objectGenerationError(
            error,
            providerID: providerID,
            strategy: .enumeration,
            text: text
        )
        let message = failure.description
        guard let repairText else {
            throw failure
        }
        guard let repaired = try await repairText(AIObjectRepairContext(text: text, errorMessage: message)) else {
            throw objectGenerationRepairAttemptedError(failure)
        }
        do {
            return try decodeAndValidateEnum(from: repaired, schema: schema)
        } catch {
            throw objectGenerationError(
                error,
                providerID: providerID,
                strategy: .enumeration,
                text: repaired,
                repairAttempted: true
            )
        }
    }
}

func parseJSONValueObject(
    from text: String,
    repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)?,
    providerID: String
) async throws -> (object: JSONValue, rawObject: JSONValue, text: String) {
    do {
        return try decodeJSONValueObject(from: text)
    } catch {
        let failure = objectGenerationError(
            error,
            providerID: providerID,
            strategy: .json,
            text: text
        )
        let message = failure.description
        guard let repairText else {
            throw failure
        }
        guard let repaired = try await repairText(AIObjectRepairContext(text: text, errorMessage: message)) else {
            throw objectGenerationRepairAttemptedError(failure)
        }
        do {
            return try decodeJSONValueObject(from: repaired)
        } catch {
            throw objectGenerationError(
                error,
                providerID: providerID,
                strategy: .json,
                text: repaired,
                repairAttempted: true
            )
        }
    }
}

func objectGenerationRepairAttemptedError(_ error: AIObjectGenerationError) -> AIObjectGenerationError {
    var output = error
    output.repairAttempted = true
    return output
}

func objectGenerationErrorWithResultMetadata(
    _ error: Error,
    finishReason: String?,
    usage: TokenUsage?,
    warnings: [AIWarning],
    providerMetadata: [String: JSONValue],
    responseMetadata: AIResponseMetadata
) -> Error {
    guard var output = error as? AIObjectGenerationError else {
        return error
    }
    output.finishReason = finishReason
    output.usage = usage
    output.warnings = warnings
    output.providerMetadata = providerMetadata
    output.responseMetadata = responseMetadata
    return output
}

func objectGenerationError(
    _ error: Error,
    providerID: String,
    strategy: AIObjectOutputStrategy,
    text: String,
    repairAttempted: Bool = false
) -> AIObjectGenerationError {
    if let error = error as? AIObjectGenerationError {
        var output = error
        output.repairAttempted = output.repairAttempted || repairAttempted
        return output
    }
    if let issue = error as? AIJSONSchemaValidationIssue {
        return AIObjectGenerationError(
            provider: providerID,
            strategy: strategy,
            kind: .schemaValidation,
            message: issue.message,
            path: issue.path,
            text: text,
            repairAttempted: repairAttempted
        )
    }
    if let error = error as? DecodingError {
        return AIObjectGenerationError(
            provider: providerID,
            strategy: strategy,
            kind: .decoding,
            message: String(describing: error),
            text: text,
            repairAttempted: repairAttempted
        )
    }
    if let error = error as? AIError, case let .invalidArgument(argument, message) = error, argument == "text" {
        return AIObjectGenerationError(
            provider: providerID,
            strategy: strategy,
            kind: .noJSON,
            message: message,
            text: text,
            repairAttempted: repairAttempted
        )
    }
    return AIObjectGenerationError(
        provider: providerID,
        strategy: strategy,
        kind: repairAttempted ? .repairFailed : .decoding,
        message: String(describing: error),
        text: text,
        repairAttempted: repairAttempted
    )
}

func decodeAndValidateObject<Object: Decodable>(
    _ type: Object.Type,
    from text: String,
    schema: JSONValue?
) throws -> (object: Object, rawObject: JSONValue, text: String) {
    guard let schema else {
        return try decodeObject(Object.self, from: text)
    }
    let parsed = try decodeObject(JSONValue.self, from: text)
    try AIJSONSchemaValidator.validate(parsed.rawObject, schema: schema)
    let data = try encodeJSONBody(parsed.rawObject)
    return (try JSONDecoder().decode(Object.self, from: data), parsed.rawObject, parsed.text)
}

func decodeAndValidateObjectArray<Element: Decodable>(
    _ type: Element.Type,
    from text: String,
    schema: JSONValue
) throws -> (object: [Element], rawObject: JSONValue, text: String) {
    let parsed = try decodeObject(JSONValue.self, from: text)
    try AIJSONSchemaValidator.validate(parsed.rawObject, schema: schema)
    guard let elements = parsed.rawObject["elements"]?.arrayValue else {
        throw AIJSONSchemaValidationIssue(path: "$.elements", message: "Expected JSON object with an elements array.")
    }
    let rawArray = JSONValue.array(elements)
    let data = try encodeJSONBody(rawArray)
    let arrayText = String(decoding: data, as: UTF8.self)
    return (try JSONDecoder().decode([Element].self, from: data), rawArray, arrayText)
}

func decodeAndValidateEnum(
    from text: String,
    schema: JSONValue
) throws -> (object: String, rawObject: JSONValue, text: String) {
    let parsed = try decodeObject(JSONValue.self, from: text)
    try AIJSONSchemaValidator.validate(parsed.rawObject, schema: schema)
    guard let result = parsed.rawObject["result"]?.stringValue else {
        throw AIJSONSchemaValidationIssue(path: "$.result", message: "Expected JSON object with a result string.")
    }
    return (result, .string(result), result)
}

func decodeJSONValueObject(from text: String) throws -> (object: JSONValue, rawObject: JSONValue, text: String) {
    let jsonText = try extractJSONObjectText(from: text)
    let rawObject = try decodeJSONBody(Data(jsonText.utf8))
    return (rawObject, rawObject, jsonText)
}

func decodeObject<Object: Decodable>(_ type: Object.Type, from text: String) throws -> (object: Object, rawObject: JSONValue, text: String) {
    let jsonText = try extractJSONObjectText(from: text)
    let rawObject = try decodeJSONBody(Data(jsonText.utf8))
    let data = try encodeJSONBody(rawObject)
    return (try JSONDecoder().decode(Object.self, from: data), rawObject, jsonText)
}