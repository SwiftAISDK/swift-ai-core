import Foundation


/// Normalized edges measured from an image's top-left corner.
public struct AIDecisionBox: Equatable, Hashable, Codable, Sendable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double

    public init(top: Double, bottom: Double, left: Double, right: Double) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }

    public var isValid: Bool {
        [top, bottom, left, right].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && left < right && top < bottom
    }

    public var jsonValue: JSONValue {
        .object(["top": .number(top), "bottom": .number(bottom), "left": .number(left), "right": .number(right)])
    }
}