import Foundation
import SwiftAIProvider

public func validateExtractionInput(state: AIDecisionState, fields: [String: AIExtractionField], referenceDate: String?) throws {
    // Reuse the state rules without inventing an extraction question.
    try validateDecisionInput(state: state, questions: ["state": .boolean(instructions: "Validate shared extraction evidence.", criteria: nil)])
    guard !fields.isEmpty else { throw AIError.invalidArgument(argument: "fields", message: "must be a nonempty field map") }
    if let referenceDate, !extractionIsDate(referenceDate) { throw AIError.invalidArgument(argument: "referenceDate", message: "must be a YYYY-MM-DD calendar date") }
    for (id, field) in fields {
        if let instructions = field.instructions, !extractionFiniteJSON(instructions) { throw AIError.invalidArgument(argument: "fields.\(id)", message: "instructions must contain finite JSON") }
        if let decimals = field.decimals, !(0...6).contains(decimals) { throw AIError.invalidArgument(argument: "fields.\(id)", message: "decimals must be an integer from 0 to 6") }
        if field.type == .duration, let unit = field.unit, !["seconds", "minutes", "hours", "days", "weeks", "months", "years"].contains(unit) { throw AIError.invalidArgument(argument: "fields.\(id)", message: "duration unit must be seconds, minutes, hours, days, weeks, months, or years") }
        if field.type == .list, field.items == nil { throw AIError.invalidArgument(argument: "fields.\(id)", message: "list items must be text, number, or date") }
    }
}

public func validateExtractionAnswers(fields: [String: AIExtractionField], state: [AIDecisionStatePart], answers: [String: AIExtractionAnswer], providerID: String) throws {
    func invalid(_ message: String) -> AIError { .invalidResponse(provider: providerID, message: message) }
    guard Set(fields.keys) == Set(answers.keys) else { throw invalid("Extraction must return exactly one answer for every field.") }
    for (id, field) in fields {
        let answer = answers[id]!
        if answer.type == .refusal { continue }
        guard answer.type.rawValue == field.type.rawValue else { throw invalid("Field \"\(id)\" returned an answer with the wrong type.") }
        guard [answer.pNull, answer.confidence].allSatisfy(extractionProbability) else { throw invalid("Field \"\(id)\" must return pNull and confidence as finite probabilities in [0, 1].") }
        if field.type == .list {
            if let value = answer.value, value != .null {
                guard let values = value.arrayValue, let itemType = field.items,
                      values.allSatisfy({ extractionValue(.init(type: AIExtractionFieldType(rawValue: itemType.rawValue)!, integer: field.integer, decimals: field.decimals), $0) }) else { throw invalid("Field \"\(id)\" must return null or a list of \(field.items?.rawValue ?? "valid") values.") }
            }
            if let items = answer.items {
                guard let values = answer.value?.arrayValue, items.count == values.count,
                      items.allSatisfy({ extractionProbability($0.confidence) && extractionSource($0.source, state: state) }) else { throw invalid("Field \"\(id)\" must return one item entry per list value, with valid confidence and source.") }
            }
        } else {
            if let value = answer.value, value != .null, !extractionValue(field, value) { throw invalid("Field \"\(id)\" must return null or a valid \(field.type.rawValue) value.") }
            if let guess = answer.guess, !extractionValue(field, guess) { throw invalid("Field \"\(id)\" must return a valid \(field.type.rawValue) guess.") }
            if !extractionSource(answer.source, state: state) { throw invalid("Field \"\(id)\" returned a source outside the state.") }
        }
    }
}

private func extractionProbability(_ value: Double?) -> Bool { value.map { $0.isFinite && (0...1).contains($0) } ?? true }
private func extractionFiniteJSON(_ value: JSONValue) -> Bool {
    switch value { case let .number(n): n.isFinite; case let .array(a): a.allSatisfy(extractionFiniteJSON); case let .object(o): o.values.allSatisfy(extractionFiniteJSON); default: true }
}
private func extractionIsDate(_ value: String) -> Bool {
    guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
    let pieces = value.split(separator: "-").compactMap { Int($0) }; guard pieces.count == 3 else { return false }
    let year = pieces[0], month = pieces[1], day = pieces[2]
    guard (1...12).contains(month), day >= 1 else { return false }
    let leap = year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return day <= days[month - 1]
}
private func extractionValue(_ field: AIExtractionField, _ value: JSONValue) -> Bool {
    switch field.type {
    case .text: return value.stringValue != nil
    case .number, .duration:
        guard case let .number(number) = value, number.isFinite, field.type != .duration || number >= 0 else { return false }
        if field.integer == true, number.rounded(.towardZero) != number { return false }
        if let decimals = field.decimals { let scale = pow(10, Double(decimals)); if (number * scale).rounded() / scale != number { return false } }
        return true
    case .date: return value.stringValue.map(extractionIsDate) ?? false
    case .time: return value.stringValue?.range(of: #"^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$"#, options: .regularExpression) != nil
    case .datetime:
        guard let text = value.stringValue, text.range(of: #"^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d(\.\d{1,9})?)?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)?$"#, options: .regularExpression) != nil else { return false }
        return extractionIsDate(String(text.prefix(10)))
    case .list: return false
    }
}
private func extractionSource(_ source: AIExtractionSource?, state: [AIDecisionStatePart]) -> Bool {
    guard let source else { return true }
    switch source {
    case let .file(part): return state.indices.contains(part) && { if case .file = state[part] { true } else { false } }()
    case let .text(part, start, end):
        guard state.indices.contains(part), case let .text(text) = state[part] else { return false }
        return start >= 0 && start < end && end <= text.utf16.count
    }
}
