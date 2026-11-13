import Foundation

/// Experimental fields extracted from the same ordered evidence state.
public enum AIExtractionFieldType: String, CaseIterable, Codable, Sendable {
    case text, number, date, time, datetime, duration, list
}
public enum AIExtractionListItemType: String, CaseIterable, Codable, Sendable {
    case text, number, date
}
public enum AIExtractionAnswerType: String, Codable, Sendable {
    case text, number, date, time, datetime, duration, list, refusal
}
public struct AIExtractionField: Equatable, Sendable {
    public var type: AIExtractionFieldType
    public var instructions: JSONValue?
    public var unit: String?
    public var integer: Bool?
    public var decimals: Int?
    public var items: AIExtractionListItemType?
    public init(type: AIExtractionFieldType, instructions: JSONValue? = nil, unit: String? = nil, integer: Bool? = nil, decimals: Int? = nil, items: AIExtractionListItemType? = nil) {
        self.type = type; self.instructions = instructions; self.unit = unit; self.integer = integer; self.decimals = decimals; self.items = items
    }
}
/// Text offsets use UTF-16 code units, matching the upstream contract.
public enum AIExtractionSource: Equatable, Sendable {
    case text(part: Int, start: Int, end: Int)
    case file(part: Int)
}
public struct AIExtractionItem: Equatable, Sendable {
    public var confidence: Double?
    public var source: AIExtractionSource?
    public init(confidence: Double? = nil, source: AIExtractionSource? = nil) { self.confidence = confidence; self.source = source }
}
public struct AIExtractionAnswer: Equatable, Sendable {
    public var type: AIExtractionAnswerType
    /// Nil denotes the upstream null value: the field was not present in the evidence.
    public var value: JSONValue?
    public var guess: JSONValue?
    public var pNull: Double?
    public var confidence: Double?
    public var source: AIExtractionSource?
    public var items: [AIExtractionItem]?
    public init(type: AIExtractionAnswerType, value: JSONValue? = nil, guess: JSONValue? = nil, pNull: Double? = nil, confidence: Double? = nil, source: AIExtractionSource? = nil, items: [AIExtractionItem]? = nil) {
        self.type = type; self.value = value; self.guess = guess; self.pNull = pNull; self.confidence = confidence; self.source = source; self.items = items
    }
}
public struct AIExtractionModelV4CallOptions: Sendable {
    public var state: [AIDecisionStatePart]
    public var fields: [String: AIExtractionField]
    public var referenceDate: String?
    public var maxOutputTokens: Int?
    public var reasoning: String?
    public var abortSignal: AIAbortSignal?
    public var headers: [String: String]
    public var providerOptions: [String: JSONValue]
    public init(state: [AIDecisionStatePart], fields: [String: AIExtractionField], referenceDate: String? = nil, maxOutputTokens: Int? = nil, reasoning: String? = nil, abortSignal: AIAbortSignal? = nil, headers: [String: String] = [:], providerOptions: [String: JSONValue] = [:]) {
        self.state = state; self.fields = fields; self.referenceDate = referenceDate; self.maxOutputTokens = maxOutputTokens; self.reasoning = reasoning; self.abortSignal = abortSignal; self.headers = headers; self.providerOptions = providerOptions
    }
}
public struct AIExtractionModelV4Result: Equatable, Sendable {
    public var answers: [String: AIExtractionAnswer]
    public var usage: AIDecisionModelUsage?
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var response: AIResponseMetadata?
    public init(answers: [String: AIExtractionAnswer], usage: AIDecisionModelUsage? = nil, warnings: [AIWarning] = [], providerMetadata: [String: JSONValue] = [:], response: AIResponseMetadata? = nil) {
        self.answers = answers; self.usage = usage; self.warnings = warnings; self.providerMetadata = providerMetadata; self.response = response
    }
}
public struct AIExtractionResult: Equatable, Sendable {
    public var answers: [String: AIExtractionAnswer]
    public var usage: AIDecisionUsage
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var response: AIDecisionResponseMetadata
    public init(answers: [String: AIExtractionAnswer], usage: AIDecisionUsage, warnings: [AIWarning] = [], providerMetadata: [String: JSONValue] = [:], response: AIDecisionResponseMetadata) {
        self.answers = answers; self.usage = usage; self.warnings = warnings; self.providerMetadata = providerMetadata; self.response = response
    }
}
public protocol AIExtractionModelV4: Sendable {
    var specificationVersion: String { get }
    var providerID: String { get }
    var modelID: String { get }
    var supportedFieldTypes: [AIExtractionFieldType] { get }
    func doExtract(_ options: AIExtractionModelV4CallOptions) async throws -> AIExtractionModelV4Result
}
public extension AIExtractionModelV4 { var specificationVersion: String { "v4" } }
public protocol AIExtractionProvider: Sendable { func extractionModel(_ modelID: String) throws -> any AIExtractionModelV4 }
public struct AIExtractionRefusalError: Error, Equatable, CustomStringConvertible, Sendable {
    public var fieldIDs: [String]
    public var providerID: String
    public var modelID: String
    public var message: String
    public init(fieldIDs: [String], providerID: String, modelID: String, message: String? = nil) {
        self.fieldIDs = fieldIDs; self.providerID = providerID; self.modelID = modelID
        let quoted = fieldIDs.map { (try? decisionJSONText(.string($0))) ?? "\"\($0)\"" }.joined(separator: ", ")
        self.message = message ?? "Extraction model \"\(modelID)\" from provider \"\(providerID)\" refused \(fieldIDs.count == 1 ? "field" : "fields") \(quoted)."
    }
    public var description: String { message }
}
public struct AIExtractionUnsupportedFieldTypeError: Error, Equatable, CustomStringConvertible, Sendable {
    public var fieldID: String
    public var fieldType: AIExtractionFieldType
    public var providerID: String
    public var modelID: String
    public var message: String
    public init(fieldID: String, fieldType: AIExtractionFieldType, providerID: String, modelID: String, message: String? = nil) {
        self.fieldID = fieldID; self.fieldType = fieldType; self.providerID = providerID; self.modelID = modelID
        self.message = message ?? "Field \"\(fieldID)\" has type \"\(fieldType.rawValue)\", which is not supported by provider \"\(providerID)\" and model \"\(modelID)\"."
    }
    public var description: String { message }
}
public typealias Experimental_ExtractionModelV4 = AIExtractionModelV4
public typealias Experimental_ExtractionModelV4CallOptions = AIExtractionModelV4CallOptions
public typealias Experimental_ExtractionModelV4Field = AIExtractionField
public typealias Experimental_ExtractionModelV4Answer = AIExtractionAnswer
public typealias Experimental_ExtractionModelV4Source = AIExtractionSource
public typealias Experimental_ExtractionModelV4Result = AIExtractionModelV4Result
public typealias Experimental_ExtractionRefusalError = AIExtractionRefusalError
public typealias Experimental_ExtractionUnsupportedFieldTypeError = AIExtractionUnsupportedFieldTypeError

public func validateExtractionModelVersion(_ model: any AIExtractionModelV4) throws -> any AIExtractionModelV4 {
    guard model.specificationVersion == "v4" else { throw AIError.invalidArgument(argument: "model", message: "Extraction model '\(model.providerID)/\(model.modelID)' uses unsupported specification version '\(model.specificationVersion)'; expected 'v4'.") }
    return model
}

public enum AIExtractionDurationUnit: String, CaseIterable, Codable, Sendable { case seconds, minutes, hours, days, weeks, months, years }
public typealias Experimental_ExtractionModelV4DurationUnit = AIExtractionDurationUnit
public typealias Experimental_ExtractionModelV4Input = JSONValue
public typealias Experimental_ExtractionModel = AIExtractionModelV4
public typealias Experimental_ExtractionField = AIExtractionField
public typealias Experimental_ExtractionSource = AIExtractionSource
public typealias Experimental_ExtractionAnswer = AIExtractionAnswer
public typealias Experimental_ExtractionResult = AIExtractionResult
public typealias Experimental_ExtractionState = AIDecisionState
public typealias Experimental_ExtractionStatePart = AIDecisionStatePart
