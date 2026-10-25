import Foundation
import SwiftAIProvider
/// Checks a complete ASCII DNS label, including the 63-byte limit.
public func isValidHostnamePart(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    func isAlphanumeric(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }
    guard (1...63).contains(bytes.count),
          let first = bytes.first, let last = bytes.last,
          isAlphanumeric(first), isAlphanumeric(last) else { return false }
    return bytes.allSatisfy { isAlphanumeric($0) || $0 == 45 }
}

public func validateHostnamePart(_ value: String, argument: String) throws {
    guard isValidHostnamePart(value) else {
        throw AIError.invalidArgument(argument: argument, message: "\(argument) must be a valid hostname part (1–63 ASCII letters, digits, or hyphens, without a leading or trailing hyphen).")
    }
}