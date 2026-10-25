import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func extractJSONObjectText(from text: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if (try? decodeJSONBody(Data(trimmed.utf8))) != nil {
        return trimmed
    }

    if let fenced = fencedJSONText(from: trimmed), (try? decodeJSONBody(Data(fenced.utf8))) != nil {
        return fenced
    }

    if let balanced = balancedJSONText(from: trimmed), (try? decodeJSONBody(Data(balanced.utf8))) != nil {
        return balanced
    }

    throw AIError.invalidArgument(argument: "text", message: "Expected JSON object or array text.")
}

func fencedJSONText(from text: String) -> String? {
    guard let opening = text.range(of: "```") else { return nil }
    let afterOpening = text[opening.upperBound...]
    let contentStart = afterOpening.firstIndex(of: "\n").map { text.index(after: $0) } ?? afterOpening.startIndex
    guard let closing = text[contentStart...].range(of: "```") else { return nil }
    return String(text[contentStart..<closing.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

func balancedJSONText(from text: String) -> String? {
    guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
    let opening = text[start]
    let closing: Character = opening == "{" ? "}" : "]"
    var depth = 0
    var inString = false
    var escaped = false
    var index = start

    while index < text.endIndex {
        let character = text[index]
        if inString {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString = false
            }
        } else if character == "\"" {
            inString = true
        } else if character == opening {
            depth += 1
        } else if character == closing {
            depth -= 1
            if depth == 0 {
                return String(text[start...index])
            }
        }
        index = text.index(after: index)
    }

    return nil
}

extension Array {
    func chunked(size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
