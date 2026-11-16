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

/// Parses JSON with the grammar of ECMAScript `JSON.parse`, then rejects
/// prototype-pollution payloads like provider-utils `secureJsonParse`.
///
/// Unlike Foundation's decoder this rejects trailing commas and a leading byte
/// order mark, keeps the last value of a duplicate key, and maps out-of-range
/// numbers to infinity. Lone UTF-16 surrogates, which Swift strings cannot
/// hold, decode to U+FFFD.
public func secureJSONParse(_ text: String) throws -> JSONValue {
    var parser = StrictJSONParser(text: text)
    let value: JSONValue
    do {
        value = try parser.parseDocument()
    } catch let error as StrictJSONParser.Failure {
        throw AIJSONParseError(text: text, message: error.message)
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

private struct StrictJSONParser {
    struct Failure: Error {
        var message: String
    }

    /// Matches Foundation's previous nesting limit so recursion stays bounded
    /// on small cooperative-thread stacks.
    private static let maximumDepth = 512

    private let bytes: [UInt8]
    private var position = 0
    private var depth = 0

    init(text: String) {
        bytes = Array(text.utf8)
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard position == bytes.count else {
            throw unexpected()
        }
        return value
    }

    private mutating func parseValue() throws -> JSONValue {
        guard position < bytes.count else {
            throw Failure(message: "Unexpected end of JSON input")
        }
        switch bytes[position] {
        case UInt8(ascii: "{"):
            return try parseObject()
        case UInt8(ascii: "["):
            return try parseArray()
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .number(try parseNumber())
        default:
            throw unexpected()
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        position += 1
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if consume(UInt8(ascii: "}")) {
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
                throw position < bytes.count
                    ? Failure(message: "Expected double-quoted property name in JSON at position \(position)")
                    : Failure(message: "Unexpected end of JSON input")
            }
            let key = try parseString()
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else {
                throw position < bytes.count
                    ? Failure(message: "Expected ':' after property name in JSON at position \(position)")
                    : Failure(message: "Unexpected end of JSON input")
            }
            skipWhitespace()
            // JSON.parse keeps the last occurrence of a duplicate key.
            object[key] = try parseValue()
            skipWhitespace()
            if consume(UInt8(ascii: ",")) {
                continue
            }
            if consume(UInt8(ascii: "}")) {
                return .object(object)
            }
            throw position < bytes.count
                ? Failure(message: "Expected ',' or '}' after property value in JSON at position \(position)")
                : Failure(message: "Unexpected end of JSON input")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        position += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if consume(UInt8(ascii: "]")) {
            return .array(array)
        }
        while true {
            skipWhitespace()
            array.append(try parseValue())
            skipWhitespace()
            if consume(UInt8(ascii: ",")) {
                continue
            }
            if consume(UInt8(ascii: "]")) {
                return .array(array)
            }
            throw position < bytes.count
                ? Failure(message: "Expected ',' or ']' after array element in JSON at position \(position)")
                : Failure(message: "Unexpected end of JSON input")
        }
    }

    private mutating func parseString() throws -> String {
        position += 1
        let start = position
        // Fast path: no escapes.
        while position < bytes.count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                let string = String(decoding: bytes[start..<position], as: UTF8.self)
                position += 1
                return string
            }
            if byte == UInt8(ascii: "\\") {
                break
            }
            if byte < 0x20 {
                throw Failure(message: "Bad control character in string literal in JSON at position \(position)")
            }
            position += 1
        }

        var utf8 = Array(bytes[start..<position])
        var pendingHighSurrogate: UInt16?

        func flushPendingSurrogate() {
            if pendingHighSurrogate != nil {
                utf8.append(contentsOf: [0xEF, 0xBF, 0xBD])
                pendingHighSurrogate = nil
            }
        }

        while position < bytes.count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                flushPendingSurrogate()
                position += 1
                return String(decoding: utf8, as: UTF8.self)
            }
            if byte < 0x20 {
                throw Failure(message: "Bad control character in string literal in JSON at position \(position)")
            }
            guard byte == UInt8(ascii: "\\") else {
                flushPendingSurrogate()
                utf8.append(byte)
                position += 1
                continue
            }
            position += 1
            guard position < bytes.count else { break }
            let escape = bytes[position]
            position += 1
            if escape == UInt8(ascii: "u") {
                let unit = try parseHexEscape()
                if (0xD800...0xDBFF).contains(unit) {
                    flushPendingSurrogate()
                    pendingHighSurrogate = unit
                } else if (0xDC00...0xDFFF).contains(unit), let high = pendingHighSurrogate {
                    pendingHighSurrogate = nil
                    let scalarValue = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)
                    appendScalar(scalarValue, to: &utf8)
                } else {
                    flushPendingSurrogate()
                    appendScalar(UInt32(unit), to: &utf8)
                }
                continue
            }
            flushPendingSurrogate()
            switch escape {
            case UInt8(ascii: "\""): utf8.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"): utf8.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "/"): utf8.append(UInt8(ascii: "/"))
            case UInt8(ascii: "b"): utf8.append(0x08)
            case UInt8(ascii: "f"): utf8.append(0x0C)
            case UInt8(ascii: "n"): utf8.append(0x0A)
            case UInt8(ascii: "r"): utf8.append(0x0D)
            case UInt8(ascii: "t"): utf8.append(0x09)
            default:
                throw Failure(message: "Bad escaped character in JSON at position \(position - 1)")
            }
        }
        throw Failure(message: "Unterminated string in JSON at position \(position)")
    }

    private mutating func parseHexEscape() throws -> UInt16 {
        guard position + 4 <= bytes.count else {
            throw Failure(message: "Bad Unicode escape in JSON at position \(position)")
        }
        var value: UInt16 = 0
        for offset in 0..<4 {
            let byte = bytes[position + offset]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default:
                throw Failure(message: "Bad Unicode escape in JSON at position \(position)")
            }
            value = value << 4 | UInt16(digit)
        }
        position += 4
        return value
    }

    private func appendScalar(_ value: UInt32, to utf8: inout [UInt8]) {
        let scalar = Unicode.Scalar(value) ?? "\u{FFFD}"
        utf8.append(contentsOf: Array(String(Character(scalar)).utf8))
    }

    private mutating func parseNumber() throws -> Double {
        let start = position
        _ = consume(UInt8(ascii: "-"))
        guard position < bytes.count else {
            throw Failure(message: "No number after minus sign in JSON at position \(position)")
        }
        if bytes[position] == UInt8(ascii: "0") {
            position += 1
        } else if isDigit(bytes[position]) {
            while position < bytes.count, isDigit(bytes[position]) { position += 1 }
        } else {
            throw Failure(message: "No number after minus sign in JSON at position \(position)")
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
            position += 1
            guard position < bytes.count, isDigit(bytes[position]) else {
                throw Failure(message: "Unterminated fractional number in JSON at position \(position)")
            }
            while position < bytes.count, isDigit(bytes[position]) { position += 1 }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
                position += 1
            }
            guard position < bytes.count, isDigit(bytes[position]) else {
                throw Failure(message: "Exponent part is missing a number in JSON at position \(position)")
            }
            while position < bytes.count, isDigit(bytes[position]) { position += 1 }
        }
        let literal = String(decoding: bytes[start..<position], as: UTF8.self)
        // Like JSON.parse, magnitudes beyond Double range become infinity.
        guard let number = Double(literal) else {
            throw Failure(message: "Invalid number in JSON at position \(start)")
        }
        return number
    }

    private mutating func expectLiteral(_ literal: StaticString) throws {
        let literalBytes = UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)
        for byte in literalBytes {
            guard position < bytes.count else {
                throw Failure(message: "Unexpected end of JSON input")
            }
            guard bytes[position] == byte else {
                throw unexpected()
            }
            position += 1
        }
    }

    private mutating func enterContainer() throws {
        depth += 1
        guard depth <= Self.maximumDepth else {
            throw Failure(message: "JSON nesting exceeds the maximum depth of \(Self.maximumDepth)")
        }
    }

    private mutating func skipWhitespace() {
        // ECMA-404 whitespace only; a byte order mark is a syntax error.
        while position < bytes.count {
            switch bytes[position] {
            case 0x20, 0x09, 0x0A, 0x0D:
                position += 1
            default:
                return
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else {
            return false
        }
        position += 1
        return true
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private func unexpected() -> Failure {
        guard position < bytes.count else {
            return Failure(message: "Unexpected end of JSON input")
        }
        let scalarEnd = bytes[position...].dropFirst().firstIndex { $0 & 0xC0 != 0x80 } ?? bytes.count
        let token = String(decoding: bytes[position..<scalarEnd], as: UTF8.self)
        return Failure(message: "Unexpected token '\(token)' in JSON at position \(position)")
    }
}
