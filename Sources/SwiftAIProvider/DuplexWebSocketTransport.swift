import Foundation


public struct AIDuplexWebSocketCloseMetadata: Equatable, Hashable, Sendable {
    public var code: Int
    public var reason: String?

    public init(code: Int, reason: String? = nil) {
        self.code = code
        self.reason = reason
    }

    public static let normalClosure = AIDuplexWebSocketCloseMetadata(code: 1000)
}