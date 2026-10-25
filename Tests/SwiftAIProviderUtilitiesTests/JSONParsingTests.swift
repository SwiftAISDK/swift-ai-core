import Foundation
import Testing
@testable import SwiftAIProviderUtilities
import SwiftAIProvider
import SwiftAITransport

@Test func jsonValueIntValueTruncatesFiniteValuesAndRejectsUnrepresentableValues() {
    #expect(JSONValue.number(3.75).intValue == 3)
    #expect(JSONValue.number(-3.75).intValue == -3)
    #expect(JSONValue.number(.infinity).intValue == nil)
    #expect(JSONValue.number(-.infinity).intValue == nil)
    #expect(JSONValue.number(.nan).intValue == nil)
    #expect(JSONValue.number(.greatestFiniteMagnitude).intValue == nil)
}

@Test func secureJSONParseParsesJSONValuesAndRejectsPrototypePayloads() throws {
    #expect(try secureJSONParse(#"{"a":5,"b":6}"#) == ["a": 5, "b": 6])
    #expect(try secureJSONParse("null") == .null)
    #expect(try secureJSONParse("0") == 0)
    #expect(try secureJSONParse(#""X""#) == "X")
    #expect(try secureJSONParse(#"{ "constructor": "string value" }"#) == ["constructor": "string value"])
    #expect(try secureJSONParse(#"{ "constructor": null }"#) == ["constructor": .null])
    #expect(try secureJSONParse(#"{ "constructor": { "x": 7 } }"#) == ["constructor": ["x": 7]])

    #expect(throws: AIJSONParseError.self) {
        _ = try secureJSONParse(#"{ "__proto__": { "isAdmin": true } }"#)
    }
    #expect(throws: AIJSONParseError.self) {
        _ = try secureJSONParse(#"{ "\u005f\u005fproto__": { "isAdmin": true } }"#)
    }
    #expect(throws: AIJSONParseError.self) {
        _ = try secureJSONParse(#"{ "constructor": { "prototype": { "isAdmin": true } } }"#)
    }
    #expect(throws: AIJSONParseError.self) {
        _ = try secureJSONParse(#"{ "\u0063\u006f\u006e\u0073\u0074\u0072\u0075\u0063\u0074\u006f\u0072": { "prototype": { "isAdmin": true } } }"#)
    }
}

@Test func secureJSONParseRejectsNestedPrototypePayloadsLikeUpstream() {
    #expect(throws: AIJSONParseError.self) {
        _ = try secureJSONParse(#"{ "a": 5, "b": 6, "__proto__": { "x": 7 }, "c": { "d": 0, "e": "text", "__proto__": { "y": 8 }, "f": { "g": 2 } } }"#)
    }
    #expect(throws: AIJSONParseError.self) {
        _ = try secureJSONParse(#"{ "a": 5, "b": 6, "constructor": { "prototype": { "x": 7 } }, "c": { "d": 0, "e": "text", "f": { "g": 2 } } }"#)
    }
    #expect(throws: AIJSONParseError.self) {
        _ = try secureJSONParse(#"{ "\u005f\u005f\u0070\u0072\u006f\u0074\u006f\u005f\u005f": { "isAdmin": true } }"#)
    }
    #expect(throws: AIJSONParseError.self) {
        _ = try secureJSONParse(#"{ "\u0063\u006fnstructor": { "prototype": { "isAdmin": true } } }"#)
    }
}

@Test func parseJSONValidatesOptionalSchema() throws {
    let schema: JSONValue = [
        "type": "object",
        "properties": ["foo": ["type": "string"]],
        "required": ["foo"],
        "additionalProperties": false
    ]

    #expect(try parseJSON(#"{"foo":"bar"}"#, schema: schema) == ["foo": "bar"])
    #expect(throws: AIJSONSchemaValidationIssue.self) {
        _ = try parseJSON(#"{"foo":42}"#, schema: schema)
    }
    #expect(throws: AIJSONParseError.self) {
        _ = try parseJSON("invalid json")
    }
}

@Test func safeParseJSONPreservesRawValueForValidationFailures() {
    let schema: JSONValue = [
        "type": "object",
        "properties": ["age": ["type": "number"]],
        "required": ["age"]
    ]

    let success = safeParseJSON(#"{"age":42}"#, schema: schema)
    #expect(success.success)
    #expect(success.value == ["age": 42])
    #expect(success.rawValue == ["age": 42])

    let validationFailure = safeParseJSON(#"{"age":"twenty"}"#, schema: schema)
    #expect(!validationFailure.success)
    #expect(validationFailure.value == nil)
    #expect(validationFailure.rawValue == ["age": "twenty"])

    let parseFailure = safeParseJSON("invalid json")
    #expect(!parseFailure.success)
    #expect(parseFailure.rawValue == nil)
}

@Test func validateTypesEquivalentReturnsValidatedObjectLikeUpstream() throws {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "name": ["type": "string"],
            "age": ["type": "number"]
        ],
        "required": ["name", "age"]
    ]

    let input = #"{"name":"John","age":30}"#
    #expect(try parseJSON(input, schema: schema) == ["name": "John", "age": 30])
}

@Test func validateTypesEquivalentThrowsTypedErrorForInvalidInputLikeUpstream() throws {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "name": ["type": "string"],
            "age": ["type": "number"]
        ],
        "required": ["name", "age"]
    ]
    let input: JSONValue = ["name": "John", "age": "30"]

    do {
        _ = try parseJSON(#"{"name":"John","age":"30"}"#, schema: schema)
        Issue.record("Expected AITypeValidationError to be thrown.")
    } catch let error as AITypeValidationError {
        #expect(error.value == input)
        #expect(error.schema == schema)
        #expect(error.path == "$.age")
        #expect(error.message.contains("expected number"))
        #expect(error.description.contains("expected number"))
    }
}

@Test func safeValidateTypesEquivalentReturnsSuccessAndRawValueLikeUpstream() {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "name": ["type": "string"],
            "age": ["type": "number"]
        ],
        "required": ["name", "age"]
    ]
    let input: JSONValue = ["name": "John", "age": 30]

    let result = safeParseJSON(#"{"name":"John","age":30}"#, schema: schema)

    #expect(result.success)
    #expect(result.value == input)
    #expect(result.rawValue == input)
    #expect(result.errorDescription == nil)
}

@Test func safeValidateTypesEquivalentReturnsTypedErrorAndRawValueLikeUpstream() {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "name": ["type": "string"],
            "age": ["type": "number"]
        ],
        "required": ["name", "age"]
    ]
    let input: JSONValue = ["name": "John", "age": "30"]

    let result = safeParseJSON(#"{"name":"John","age":"30"}"#, schema: schema)

    #expect(!result.success)
    #expect(result.value == nil)
    #expect(result.rawValue == input)
    #expect(result.errorDescription?.contains("$.age") == true)
    #expect(result.errorDescription?.contains("expected number") == true)
}

@Test func isParsableJSONUsesSecureParser() {
    #expect(isParsableJSON(#"{"foo":"bar"}"#))
    #expect(isParsableJSON("[1,2,3]"))
    #expect(!isParsableJSON("invalid"))
    #expect(!isParsableJSON(#"{ "__proto__": { "isAdmin": true } }"#))
}

@Test func isJSONSerializableMatchesJSONBoundaryRules() {
    final class TestClass {}

    #expect(isJSONSerializable(nil))
    #expect(isJSONSerializable("test"))
    #expect(isJSONSerializable(42))
    #expect(isJSONSerializable(true))
    #expect(isJSONSerializable(false))
    #expect(isJSONSerializable(["test", 42, true, nil, ["nested": ["value"]]] as [Any?]))
    #expect(isJSONSerializable(["string": "test", "nested": ["array": ["value"]]] as [String: Any]))

    #expect(!isJSONSerializable(["test", Date()] as [Any]))
    #expect(!isJSONSerializable(["nested": ["callback": Date()]] as [String: Any]))
    #expect(!isJSONSerializable(Date()))
    #expect(!isJSONSerializable(NSRegularExpression()))
    #expect(!isJSONSerializable(TestClass()))
}
