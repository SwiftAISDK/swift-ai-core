import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public enum AINoOutputKind: String, Equatable, Sendable {
    case output
    case content
    case image
    case video
    case audio
    case speech
    case transcript
}

public struct AINoOutputError: Error, Equatable, CustomStringConvertible, Sendable {
    public var provider: String?
    public var kind: AINoOutputKind
    public var structuredOutputKind: AIOutputKind?
    public var responses: [AIResponseMetadata]
    /// Underlying image-model call diagnostics. This is empty for non-image
    /// no-output failures.
    public var calls: [ImageGenerationCall]
    public var message: String

    public init(
        provider: String? = nil,
        kind: AINoOutputKind = .output,
        structuredOutputKind: AIOutputKind? = nil,
        responses: [AIResponseMetadata] = [],
        calls: [ImageGenerationCall] = [],
        message: String? = nil
    ) {
        self.provider = provider
        self.kind = kind
        self.structuredOutputKind = structuredOutputKind
        self.responses = responses
        self.calls = calls
        self.message = message ?? Self.defaultMessage(kind: kind, structuredOutputKind: structuredOutputKind)
    }

    /// Source-compatible initializer retained from before image-call
    /// diagnostics were attached to no-output errors.
    public init(
        provider: String? = nil,
        kind: AINoOutputKind = .output,
        structuredOutputKind: AIOutputKind? = nil,
        responses: [AIResponseMetadata] = [],
        message: String? = nil
    ) {
        self.init(
            provider: provider,
            kind: kind,
            structuredOutputKind: structuredOutputKind,
            responses: responses,
            calls: [],
            message: message
        )
    }

    public var description: String {
        let providerPrefix = provider.map { "\($0) " } ?? ""
        return "\(providerPrefix)\(message)"
    }

    private static func defaultMessage(kind: AINoOutputKind, structuredOutputKind: AIOutputKind?) -> String {
        switch kind {
        case .output:
            if let structuredOutputKind {
                return "No \(structuredOutputKind.rawValue) output was generated."
            }
            return "No output was generated."
        case .content:
            return "No content was generated."
        case .image:
            return "No image was generated."
        case .video:
            return "No video was generated."
        case .audio:
            return "No audio was generated."
        case .speech:
            return "No speech audio was generated."
        case .transcript:
            return "No transcript was generated."
        }
    }
}