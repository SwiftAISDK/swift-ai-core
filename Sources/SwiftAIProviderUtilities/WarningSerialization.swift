import Foundation
import SwiftAIProvider
import SwiftAITransport



public func aiWarningJSON(_ warning: AIWarning) -> JSONValue {
    .object([
        "type": .string(warning.type),
        "feature": warning.feature.map(JSONValue.string),
        "setting": warning.setting.map(JSONValue.string),
        "message": warning.message.map(JSONValue.string)
    ])
}
