import Foundation
import SwiftAIProvider
import SwiftAITransport


public struct AIJSONParseResult: Equatable, Sendable {
    public var value: JSONValue?
    public var rawValue: JSONValue?
    public var errorDescription: String?

    public var success: Bool {
        errorDescription == nil
    }

    public static func success(value: JSONValue, rawValue: JSONValue) -> AIJSONParseResult {
        AIJSONParseResult(value: value, rawValue: rawValue, errorDescription: nil)
    }

    public static func failure(error: Error, rawValue: JSONValue?) -> AIJSONParseResult {
        AIJSONParseResult(value: nil, rawValue: rawValue, errorDescription: String(describing: error))
    }
}

public func parseJSON(_ text: String, schema: JSONValue? = nil) throws -> JSONValue {
    let value = try secureJSONParse(text)
    if let schema {
        try AIJSONSchemaValidator.validate(value, schema: schema)
    }
    return value
}

public func safeParseJSON(_ text: String, schema: JSONValue? = nil) -> AIJSONParseResult {
    let rawValue: JSONValue
    do {
        rawValue = try secureJSONParse(text)
    } catch {
        return .failure(error: error, rawValue: nil)
    }

    if let schema {
        do {
            try AIJSONSchemaValidator.validate(rawValue, schema: schema)
        } catch {
            return .failure(error: error, rawValue: rawValue)
        }
    }

    return .success(value: rawValue, rawValue: rawValue)
}

public func isParsableJSON(_ input: String) -> Bool {
    (try? secureJSONParse(input)) != nil
}

public func isJSONSerializable(_ value: Any?) -> Bool {
    guard let value else {
        return true
    }

    switch value {
    case is JSONValue, is String, is Bool, is Int, is Int8, is Int16, is Int32, is Int64,
         is UInt, is UInt8, is UInt16, is UInt32, is UInt64, is Double, is Float, is Decimal, is NSNull:
        return true
    case let array as [Any?]:
        return array.allSatisfy(isJSONSerializable)
    case let array as [Any]:
        return array.allSatisfy { isJSONSerializable($0) }
    case let object as [String: Any?]:
        return object.values.allSatisfy(isJSONSerializable)
    case let object as [String: Any]:
        return object.values.allSatisfy { isJSONSerializable($0) }
    default:
        return false
    }
}