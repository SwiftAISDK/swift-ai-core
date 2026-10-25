import Foundation




public struct AIJSONInstruction: Equatable, Hashable, Sendable {
    public var isEnabled: Bool
    public var schemaPrefix: String?
    public var schemaSuffix: String?

    public init(
        isEnabled: Bool = true,
        schemaPrefix: String? = nil,
        schemaSuffix: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.schemaPrefix = schemaPrefix
        self.schemaSuffix = schemaSuffix
    }

    public static let automatic = AIJSONInstruction()
    public static let disabled = AIJSONInstruction(isEnabled: false)
}
