import Foundation


public typealias AIProviderReference = [String: String]

public struct AINoSuchProviderReferenceError: Error, Equatable, CustomStringConvertible, Sendable {
    public var provider: String
    public var reference: AIProviderReference

    public init(provider: String, reference: AIProviderReference) {
        self.provider = provider
        self.reference = reference
    }

    public var description: String {
        "No provider reference found for provider '\(provider)'."
    }
}

public func isProviderReference(_ reference: AIProviderReference) -> Bool {
    true
}

public func isProviderReference(_ value: JSONValue) -> Bool {
    guard case let .object(object) = value else {
        return false
    }
    return object["type"] == nil
}

public func resolveProviderReference(reference: AIProviderReference, provider: String) throws -> String {
    if let id = reference[provider] {
        return id
    }
    throw AINoSuchProviderReferenceError(provider: provider, reference: reference)
}

public func resolveProviderReference(_ reference: AIProviderReference, provider: String) throws -> String {
    try resolveProviderReference(reference: reference, provider: provider)
}

public extension FileUploadResult {
    func providerID(for provider: String) throws -> String {
        try resolveProviderReference(providerReference, provider: provider)
    }
}


public extension SkillUploadResult {
    func providerID(for provider: String) throws -> String {
        try resolveProviderReference(providerReference, provider: provider)
    }
}
