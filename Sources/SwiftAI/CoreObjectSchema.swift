import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

public protocol AIObjectSchema: Sendable {
    associatedtype Output: Decodable & Sendable

    var jsonSchema: JSONValue { get }
    var name: String? { get }
    var description: String? { get }
}

public extension AIObjectSchema {
    var name: String? { nil }
    var description: String? { nil }
}


public struct AIJSONSchema<Output: Decodable & Sendable>: AIObjectSchema {
    public var jsonSchema: JSONValue
    public var name: String?
    public var description: String?

    public init(
        _ jsonSchema: JSONValue,
        name: String? = nil,
        description: String? = nil,
        as type: Output.Type = Output.self
    ) {
        self.jsonSchema = jsonSchema
        self.name = name
        self.description = description
    }
}