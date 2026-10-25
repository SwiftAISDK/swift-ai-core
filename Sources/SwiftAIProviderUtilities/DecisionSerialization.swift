import Foundation
import SwiftAIProvider
import SwiftAITransport



public func decisionStatePartJSON(_ part: AIDecisionStatePart) -> JSONValue {
    switch part {
    case let .text(text): return .object(["type": .string("text"), "text": .string(text)])
    case let .json(value): return .object(["type": .string("json"), "value": value])
    case let .file(mediaType, data, filename, providerOptions):
        let encodedData: JSONValue
        switch data {
        case let .data(bytes): encodedData = .object(["type": .string("data"), "data": .string(bytes.base64EncodedString())])
        case let .base64(value): encodedData = .object(["type": .string("data"), "data": .string(value)])
        case let .url(url): encodedData = .object(["type": .string("url"), "url": .string(url.absoluteString)])
        case let .reference(reference): encodedData = .object(["type": .string("reference"), "reference": .string(reference)])
        }
        return .object([
            "type": .string("file"),
            "mediaType": .string(mediaType),
            "data": encodedData,
            "filename": filename.map(JSONValue.string),
            "providerOptions": providerOptions.isEmpty ? nil : .object(providerOptions)
        ])
    }
}
