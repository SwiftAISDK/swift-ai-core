import Foundation


/// A source supporting one generated text block, independently of retrieved sources.
public struct AICitation: Equatable, Hashable, Sendable {
    public var source: AISource
    /// Provider offsets use UTF-16 code units; `endIndex` is exclusive.
    public var startIndex: Int?
    public var endIndex: Int?
    public var citedText: String?

    public init(source: AISource, startIndex: Int? = nil, endIndex: Int? = nil, citedText: String? = nil) {
        self.source = source
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.citedText = citedText
    }
}

public extension AIResultContentPart {
    static func text(_ text: String, citations: [AICitation], providerMetadata: [String: JSONValue] = [:]) -> Self {
        citations.isEmpty ? .text(text, providerMetadata: providerMetadata)
            : .citedText(text, citations: citations, providerMetadata: providerMetadata)
    }

    var citations: [AICitation] {
        if case let .citedText(_, citations, _) = self { return citations }
        return []
    }

    var textValue: String? {
        switch self {
        case let .text(text, _), let .citedText(text, _, _): text
        default: nil
        }
    }
}


public enum AIToolInputEncoding: String, Equatable, Hashable, Codable, Sendable {
    case json
    case text
}

public extension LanguageStreamPart {
    static func textEnd(id: String, citations: [AICitation], providerMetadata: [String: JSONValue] = [:]) -> Self {
        citations.isEmpty ? .textEnd(id: id, providerMetadata: providerMetadata)
            : .textEndWithCitations(id: id, citations: citations, providerMetadata: providerMetadata)
    }

    static func toolInputStart(
        id: String, name: String, inputEncoding: AIToolInputEncoding,
        providerExecuted: Bool = false, dynamic: Bool = false,
        title: String? = nil, providerMetadata: [String: JSONValue] = [:]
    ) -> Self {
        inputEncoding == .text
            ? .toolInputStartText(id: id, name: name, providerExecuted: providerExecuted, dynamic: dynamic, title: title, providerMetadata: providerMetadata)
            : .toolInputStart(id: id, name: name, providerExecuted: providerExecuted, dynamic: dynamic, title: title, providerMetadata: providerMetadata)
    }

    var citations: [AICitation] {
        if case let .textEndWithCitations(_, citations, _) = self { return citations }
        return []
    }

    var inputEncoding: AIToolInputEncoding? {
        switch self {
        case .toolInputStart: .json
        case .toolInputStartText: .text
        default: nil
        }
    }
}
