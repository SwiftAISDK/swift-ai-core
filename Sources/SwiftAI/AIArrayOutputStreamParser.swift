import Foundation
import SwiftAIProvider

/// Each stream owns its scanner. Completed elements are decoded once; the last
/// element stays pending until another begins or the enclosing object closes.
final class AIArrayOutputStreamParser<Element: Sendable>: @unchecked Sendable {
    enum Update { case unchanged, snapshot(raw: [JSONValue], elements: [Element]), fallback }
    private enum Phase { case prefix, elements, suffix, done, fallback }
    private var phase = Phase.prefix
    private var prefix = ""
    private var elementText = ""
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var afterComma = false
    private var pending: (JSONValue, Element)?
    private var raw: [JSONValue] = []
    private var elements: [Element] = []
    private var publishedCount: Int?
    private let skipInvalidElements: Bool
    private let decode: @Sendable (JSONValue) throws -> Element

    init(skipInvalidElements: Bool, decode: @escaping @Sendable (JSONValue) throws -> Element) { self.skipInvalidElements = skipInvalidElements; self.decode = decode }
    private func publishPending() { if let pending { raw.append(pending.0); elements.append(pending.1); self.pending = nil } }
    private func finishElement() -> Bool {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(elementText.utf8)) else { return false }
        do { pending = (value, try decode(value)) }
        catch { if !skipInvalidElements { return false } }
        elementText = ""; return true
    }
    func append(_ delta: String) -> Update {
        if phase == .fallback { return .fallback }
        for char in delta {
            if phase == .prefix {
                prefix.append(char)
                if char == "[" {
                    guard prefix.range(of: #"^\s*\{\s*"elements"\s*:\s*\[$"#, options: .regularExpression) != nil else { phase = .fallback; return .fallback }
                    phase = .elements
                } else if prefix.utf16.count > 256 { phase = .fallback; return .fallback }
                continue
            }
            if phase == .suffix || phase == .done {
                if char.isWhitespace { continue }
                if phase == .suffix && char == "}" { publishPending(); phase = .done; continue }
                phase = .fallback; return .fallback
            }
            if !inString && depth == 0 && (char == "," || char == "]") {
                if !elementText.isEmpty {
                    guard finishElement() else { phase = .fallback; return .fallback }
                } else if char == "," || afterComma { phase = .fallback; return .fallback }
                afterComma = char == ","
                if char == "]" { phase = .suffix }
                continue
            }
            if elementText.isEmpty {
                if char.isWhitespace { continue }
                publishPending(); afterComma = false
            }
            elementText.append(char)
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" { inString = true }
            else if char == "{" || char == "[" { depth += 1 }
            else if char == "}" || char == "]" { depth -= 1 }
        }
        guard phase != .prefix, publishedCount != elements.count else { return .unchanged }
        publishedCount = elements.count
        return .snapshot(raw: raw, elements: elements)
    }
}
