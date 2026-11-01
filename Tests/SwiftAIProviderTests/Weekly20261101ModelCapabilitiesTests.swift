import Foundation
import Testing
import SwiftAIProvider

@Suite("Weekly20261101 provider model metadata")
struct Weekly20261101ModelCapabilitiesTests {
    @Test func supportCodecPreservesFalseUnknownAndConditions() throws {
        let values: [AIModelFeatureSupport] = [.supported, .unsupported, .unknown, .conditional("only for text")]
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(values))
        #expect(encoded == [true, false, "unknown", ["condition": "only for text"]])
        #expect(try JSONDecoder().decode([AIModelFeatureSupport].self, from: JSONEncoder().encode(encoded)) == values)
        for invalid: JSONValue in [.null, 42, "sometimes", ["condition": true]] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(AIModelFeatureSupport.self, from: JSONEncoder().encode(invalid)) }
        }
    }

    @Test func modelEntriesKeepOmittedSectionsDistinctFromUnsupportedFeatures() throws {
        let entry = AIModelEntry<JSONValue>(capabilities: AIModelCapabilities(
            embedding: .init(defaultDimensions: 1024, customDimensions: .unsupported),
            image: .init(sizes: .described("width and height are multiples of 16"), fileInput: .unknown, maskInput: .conditional("with an input image")),
            realtime: .init(conversation: .turnBased, transports: [.websocket, .webrtc], connections: [.clientSecretWebSocket, .serverWebSocket, .webrtc])
        ), providerOptions: [.image: ["quality": .unknown, "seed": .unsupported]], requestConfig: ["path": "/images"])
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(entry))
        #expect(json["capabilities"]?["language"] == nil)
        #expect(json["capabilities"]?["embedding"]?["customDimensions"] == false)
        #expect(json["capabilities"]?["image"]?["fileInput"] == "unknown")
        #expect(json["capabilities"]?["image"]?["maxImagesPerCall"] == nil)
        #expect(json["providerOptions"]?["image"]?["seed"] == false)
        #expect(json["providerOptions"]?["image"]?["unknown-option"] == nil)
        #expect(json["capabilities"]?["realtime"]?["connections"] == ["client-secret-websocket", "server-websocket", "webrtc"])
        #expect(try JSONDecoder().decode(AIModelEntry<JSONValue>.self, from: JSONEncoder().encode(entry)) == entry)
    }

    @Test func providerOptionDefinitionsEncodeSectionKeysAsAnObject() throws {
        let definitions: AIProviderOptionDefinitions = [.language: ["effort": AIProviderOptionDefinition(description: "Model-specific effort")]]
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(definitions))
        #expect(json == ["language": ["effort": ["description": "Model-specific effort"]]])
        #expect(try JSONDecoder().decode(AIProviderOptionDefinitions.self, from: JSONEncoder().encode(json)) == definitions)
    }
}
