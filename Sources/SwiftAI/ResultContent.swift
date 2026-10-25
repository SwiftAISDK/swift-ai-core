import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension TextGenerationResult {

    mutating func ensureResponseMessages(toolsByName: [String: AITool] = [:]) async throws {
        guard responseMessages.isEmpty else { return }
        responseMessages = try await toResponseMessages(
            content: responseMessageContentParts,
            toolsByName: toolsByName
        )
    }
}


func makeResponseMessages(from content: [AIResultContentPart]) async throws -> [AIMessage] {
    try await toResponseMessages(content: content.compactMap(\.responseMessagePart))
}