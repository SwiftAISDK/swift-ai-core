import Foundation


public struct AIJSONParseError: Error, Equatable, CustomStringConvertible, Sendable {
    public var text: String
    public var message: String

    public init(text: String, message: String) {
        self.text = text
        self.message = message
    }

    public var description: String {
        "Failed to parse JSON: \(message)"
    }
}

public func secureJSONParse(_ text: String) throws -> JSONValue {
    let value: JSONValue
    do {
        value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    } catch {
        throw AIJSONParseError(text: text, message: String(describing: error))
    }
    try validateSecureJSONObject(value, text: text)
    return value
}

private func validateSecureJSONObject(_ value: JSONValue, text: String) throws {
    switch value {
    case let .object(object):
        if object.keys.contains("__proto__") {
            throw AIJSONParseError(text: text, message: "Object contains forbidden prototype property")
        }
        if case let .object(constructor)? = object["constructor"],
           constructor.keys.contains("prototype") {
            throw AIJSONParseError(text: text, message: "Object contains forbidden prototype property")
        }
        for nested in object.values {
            try validateSecureJSONObject(nested, text: text)
        }
    case let .array(array):
        for nested in array {
            try validateSecureJSONObject(nested, text: text)
        }
    case .string, .number, .bool, .null:
        break
    }
}