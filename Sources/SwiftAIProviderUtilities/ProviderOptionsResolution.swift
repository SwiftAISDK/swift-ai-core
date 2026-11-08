import SwiftAIProvider

public enum ProviderOptionsResolution: Sendable {
    /// The first present namespace wins as a whole, including an empty object.
    case first
    /// Parse every present namespace; later namespaces override earlier keys.
    case merge
}

public struct ResolvedProviderOptions: Equatable, Sendable {
    public var options: [String: JSONValue]?
    public var namespaces: [String]
    public init(options: [String: JSONValue]?, namespaces: [String]) { self.options = options; self.namespaces = namespaces }
}

/// Resolves aliases before provider-specific schema validation. Nil and null namespaces are absent.
/// The validator runs once per contributing namespace and may normalize or reject its options.
public func resolveProviderOptions(
    providerOptions: [String: JSONValue],
    namespaces: [String],
    resolution: ProviderOptionsResolution,
    validate: (([String: JSONValue]) throws -> [String: JSONValue])? = nil
) throws -> ResolvedProviderOptions {
    var seen: Set<String> = []
    var matched: [String] = []
    var result: [String: JSONValue]?
    for namespace in namespaces where seen.insert(namespace).inserted {
        guard let value = providerOptions[namespace], value != .null else { continue }
        guard let object = value.objectValue else { throw AIError.invalidArgument(argument: "providerOptions.\(namespace)", message: "Expected an object.") }
        let parsed = try validate?(object) ?? object
        if resolution == .first { return .init(options: parsed, namespaces: [namespace]) }
        matched.append(namespace)
        if result == nil { result = [:] }
        result?.merge(parsed) { _, new in new }
    }
    return .init(options: result, namespaces: matched)
}
