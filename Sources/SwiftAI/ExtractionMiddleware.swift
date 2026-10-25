import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public func extractJsonMiddleware(
    transform: (@Sendable (_ text: String) -> String)? = nil
) -> AILanguageModelMiddleware {
    let transformText = transform ?? defaultExtractJSONTransform
    return AILanguageModelMiddleware(
        wrapGenerate: { context in
            var result = try await context.doGenerate()
            result.content = result.content.map { part in
                switch part {
                case let .text(text, metadata):
                    return .text(transformText(text), providerMetadata: metadata)
                case let .citedText(text, citations, metadata):
                    return .citedText(transformText(text), citations: citations, providerMetadata: metadata)
                default: return part
                }
            }
            result.structuredOutputText = result.structuredOutputText.map(transformText)
            result.text = result.content.compactMap { part -> String? in
                switch part {
                case let .text(text, _), let .citedText(text, _, _): return text
                default: return nil
                }
            }.joined()
            result.refreshDerivedContent()
            return result
        },
        wrapStream: { context in
            transformTextStream(context.doStream(), transform: transformText)
        }
    )
}

public func extractJSONMiddleware(
    transform: (@Sendable (_ text: String) -> String)? = nil
) -> AILanguageModelMiddleware {
    extractJsonMiddleware(transform: transform)
}

public func extractReasoningMiddleware(
    tagName: String,
    separator: String = "\n",
    startWithReasoning: Bool = false
) -> AILanguageModelMiddleware {
    makeExtractReasoningMiddleware(opening: "<\(tagName)>", closing: "</\(tagName)>", separator: separator, startWithReasoning: startWithReasoning)
}

public struct AIReasoningDelimiters: Equatable, Sendable {
    public var opening: String
    public var closing: String
    public init(opening: String, closing: String) { self.opening = opening; self.closing = closing }
}

public func extractReasoningMiddleware(
    delimiters: AIReasoningDelimiters,
    separator: String = "\n",
    startWithReasoning: Bool = false
) throws -> AILanguageModelMiddleware {
    guard !delimiters.opening.isEmpty, !delimiters.closing.isEmpty else {
        throw AIError.invalidArgument(argument: "tagName", message: "Reasoning delimiters must not be empty.")
    }
    return makeExtractReasoningMiddleware(opening: delimiters.opening, closing: delimiters.closing, separator: separator, startWithReasoning: startWithReasoning)
}

private func makeExtractReasoningMiddleware(opening: String, closing: String, separator: String, startWithReasoning: Bool) -> AILanguageModelMiddleware {
    AILanguageModelMiddleware(
        wrapGenerate: { context in
            var result = try await context.doGenerate()
            func extract(_ text: String) -> (reasoning: String, text: String)? {
                let input = startWithReasoning ? opening + text : text
                return extractDelimitedSections(text: input, opening: opening, closing: closing, separator: separator)
            }
            result.content = result.content.flatMap { part -> [AIResultContentPart] in
                let text: String
                let metadata: [String: JSONValue]
                switch part {
                case let .text(value, providerMetadata), let .citedText(value, _, providerMetadata):
                    text = value; metadata = providerMetadata
                default: return [part]
                }
                guard let extracted = extract(text) else { return [part] }
                let remainingText: AIResultContentPart = part.citations.isEmpty
                    ? .text(extracted.text, providerMetadata: metadata)
                    : .citedText(extracted.text, citations: part.citations, providerMetadata: metadata)
                return [.reasoning(extracted.reasoning), remainingText]
            }
            if let selected = result.structuredOutputText {
                result.structuredOutputText = extract(selected)?.text ?? selected
            }
            result.text = result.content.compactMap { part -> String? in
                switch part {
                case let .text(text, _), let .citedText(text, _, _): return text
                default: return nil
                }
            }.joined()
            result.reasoning = result.content.compactMap { part -> String? in
                if case let .reasoning(reasoning, _) = part { return reasoning }
                return nil
            }.joined(separator: separator)
            result.refreshDerivedContent()
            return result
        },
        wrapStream: { context in
            extractReasoningStream(
                context.doStream(),
                opening: opening,
                closing: closing,
                separator: separator,
                startWithReasoning: startWithReasoning
            )
        }
    )
}

public func simulateStreamingMiddleware() -> AILanguageModelMiddleware {
    AILanguageModelMiddleware(wrapStream: { context in
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await context.doGenerate()
                    var id = 0

                    continuation.yield(.streamStart(warnings: result.warnings))
                    if result.responseMetadata != AIResponseMetadata() {
                        continuation.yield(.responseMetadata(result.responseMetadata))
                    }

                    if !result.reasoning.isEmpty {
                        let partID = String(id)
                        continuation.yield(.reasoningStart(id: partID))
                        continuation.yield(.reasoningDeltaPart(id: partID, delta: result.reasoning))
                        continuation.yield(.reasoningEnd(id: partID))
                        id += 1
                    }

                    for part in result.content {
                        let text: String
                        let metadata: [String: JSONValue]
                        switch part {
                        case let .text(value, providerMetadata), let .citedText(value, _, providerMetadata):
                            text = value; metadata = providerMetadata
                        default: continue
                        }
                        guard !text.isEmpty || !part.citations.isEmpty else { continue }
                        let partID = String(id)
                        continuation.yield(.textStart(id: partID, providerMetadata: metadata))
                        continuation.yield(.textDeltaPart(id: partID, delta: text))
                        continuation.yield(.textEnd(id: partID, citations: part.citations))
                        id += 1
                    }

                    for source in result.sources {
                        continuation.yield(.source(source))
                    }
                    for toolCall in result.toolCalls {
                        continuation.yield(.toolCall(toolCall))
                    }
                    for approvalRequest in result.toolApprovalRequests {
                        continuation.yield(.toolApprovalRequest(approvalRequest))
                    }
                    for approvalResponse in result.toolApprovalResponses {
                        continuation.yield(.toolApprovalResponse(approvalResponse))
                    }
                    for toolResult in result.toolResults {
                        continuation.yield(.toolResult(toolResult))
                    }

                    continuation.yield(.finishMetadata(
                        reason: result.finishReason,
                        usage: result.usage,
                        providerMetadata: result.providerMetadata
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    })
}

func defaultExtractJSONTransform(_ text: String) -> String {
    text
        .replacingOccurrences(of: #"^```(?:json)?\s*\n?"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\n?```\s*$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func transformTextStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    transform: @escaping @Sendable (String) -> String
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                var blockBuffers: [String: String] = [:]
                var blockStarts: [String: LanguageStreamPart] = [:]
                var blockDeltaMetadata: [String: [String: JSONValue]] = [:]

                func sortedBlockIDs() -> [String] {
                    blockBuffers.keys.sorted { lhs, rhs in
                        let leftNumber = Int(lhs)
                        let rightNumber = Int(rhs)
                        if let leftNumber, let rightNumber, leftNumber != rightNumber {
                            return leftNumber < rightNumber
                        }
                        return lhs < rhs
                    }
                }

                func flushBlocks() {
                    for id in sortedBlockIDs() {
                        let transformed = transform(blockBuffers[id] ?? "")
                        let deltaMetadata = blockDeltaMetadata[id] ?? [:]
                        continuation.yield(blockStarts[id] ?? .textStart(id: id))
                        if !transformed.isEmpty || !deltaMetadata.isEmpty {
                            continuation.yield(.textDeltaPart(
                                id: id,
                                delta: transformed,
                                providerMetadata: deltaMetadata
                            ))
                        }
                        continuation.yield(.textEnd(id: id))
                    }
                    blockBuffers.removeAll()
                    blockStarts.removeAll()
                    blockDeltaMetadata.removeAll()
                }

                for try await part in canonicalLanguageStream(stream, providerID: "extract-json-middleware") {
                    switch part {
                    case let .textStart(id, providerMetadata):
                        blockStarts[id] = .textStart(id: id, providerMetadata: providerMetadata)
                        blockBuffers[id, default: ""] += ""
                    case let .textDeltaPart(id, delta, providerMetadata):
                        blockBuffers[id, default: ""] += delta
                        blockDeltaMetadata[id, default: [:]].merge(providerMetadata) { _, new in new }
                    case let .textEnd(id, providerMetadata), let .textEndWithCitations(id, _, providerMetadata):
                        let transformed = transform(blockBuffers[id] ?? "")
                        let deltaMetadata = blockDeltaMetadata[id] ?? [:]
                        continuation.yield(blockStarts[id] ?? .textStart(id: id))
                        if !transformed.isEmpty || !deltaMetadata.isEmpty {
                            continuation.yield(.textDeltaPart(
                                id: id,
                                delta: transformed,
                                providerMetadata: deltaMetadata
                            ))
                        }
                        continuation.yield(.textEnd(id: id, citations: part.citations, providerMetadata: providerMetadata))
                        blockBuffers[id] = nil
                        blockStarts[id] = nil
                        blockDeltaMetadata[id] = nil
                    case .finishMetadata:
                        flushBlocks()
                        continuation.yield(part)
                    default:
                        continuation.yield(part)
                    }
                }
                flushBlocks()
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

func extractTaggedSections(
    text: String,
    tagName: String,
    separator: String
) -> (reasoning: String, text: String)? {
    extractDelimitedSections(text: text, opening: "<\(tagName)>", closing: "</\(tagName)>", separator: separator)
}

private func extractDelimitedSections(text: String, opening: String, closing: String, separator: String) -> (reasoning: String, text: String)? {
    guard let segments = extractDelimitedSegments(text: text, openingTag: opening, closingTag: closing) else {
        return nil
    }

    let reasoning = segments.compactMap { segment -> String? in
        if case let .reasoning(value) = segment { return value }
        return nil
    }.joined(separator: separator)
    let textWithoutReasoning = segments.compactMap { segment -> String? in
        if case let .text(value) = segment { return value }
        return nil
    }.joined(separator: separator)

    return (reasoning: reasoning, text: textWithoutReasoning)
}

private enum ExtractedTaggedSegment {
    case reasoning(String)
    case text(String)
}

private func extractDelimitedSegments(text: String, openingTag: String, closingTag: String) -> [ExtractedTaggedSegment]? {
    let pattern = NSRegularExpression.escapedPattern(for: openingTag)
        + "(.*?)"
        + NSRegularExpression.escapedPattern(for: closingTag)
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return nil
    }

    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, range: fullRange)
    guard !matches.isEmpty else {
        return nil
    }

    var segments: [ExtractedTaggedSegment] = []
    var cursor = text.startIndex

    for match in matches {
        guard let matchRange = Range(match.range, in: text),
              let reasoningRange = Range(match.range(at: 1), in: text) else {
            continue
        }

        if cursor < matchRange.lowerBound {
            let textSegment = String(text[cursor..<matchRange.lowerBound])
            if !textSegment.isEmpty {
                segments.append(.text(textSegment))
            }
        }

        segments.append(.reasoning(String(text[reasoningRange])))
        cursor = matchRange.upperBound
    }

    if cursor < text.endIndex {
        let textSegment = String(text[cursor..<text.endIndex])
        if !textSegment.isEmpty {
            segments.append(.text(textSegment))
        }
    }

    return segments
}

func appendSeparated(_ existing: String, _ next: String, separator: String) -> String {
    guard !existing.isEmpty else { return next }
    guard !next.isEmpty else { return existing }
    return existing + separator + next
}

func extractReasoningStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    tagName: String,
    separator: String,
    startWithReasoning: Bool
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    extractReasoningStream(stream, opening: "<\(tagName)>", closing: "</\(tagName)>", separator: separator, startWithReasoning: startWithReasoning)
}

func extractReasoningStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    opening: String,
    closing: String,
    separator: String,
    startWithReasoning: Bool
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                var textBuffers: [String: String] = [:]
                var textStartMetadata: [String: [String: JSONValue]] = [:]
                var textDeltaMetadata: [String: [String: JSONValue]] = [:]
                var textEndMetadata: [String: [String: JSONValue]] = [:]
                var textCitations: [String: [AICitation]] = [:]
                var activeTextIDs = Set<String>()
                var textIDOrder: [String] = []
                var reasoningIDCounter = 0

                func markTextID(_ id: String) {
                    if activeTextIDs.insert(id).inserted {
                        textIDOrder.append(id)
                    }
                }

                func flushExtractedText(id textID: String) {
                    guard activeTextIDs.contains(textID) else { return }
                    let textBuffer = textBuffers[textID] ?? ""
                    let startMetadata = textStartMetadata[textID] ?? [:]
                    let endMetadata = textEndMetadata[textID] ?? [:]
                    let citations = textCitations[textID] ?? []
                    let input = startWithReasoning ? opening + textBuffer : textBuffer
                    var pendingDeltaMetadata = textDeltaMetadata[textID] ?? [:]
                    func takeDeltaMetadata() -> [String: JSONValue] {
                        defer { pendingDeltaMetadata = [:] }
                        return pendingDeltaMetadata
                    }
                    if let segments = extractDelimitedSegments(text: input, openingTag: opening, closingTag: closing) {
                        var reasoningSegmentCount = 0
                        var textSegmentCount = 0
                        var emittedTextStart = false

                        for segment in segments {
                            switch segment {
                            case let .reasoning(reasoning):
                                let reasoningID = "reasoning-\(reasoningIDCounter)"
                                reasoningIDCounter += 1
                                continuation.yield(.reasoningStart(id: reasoningID))
                                let delta = (reasoningSegmentCount > 0 ? separator : "") + reasoning
                                let providerMetadata = takeDeltaMetadata()
                                if !delta.isEmpty || !providerMetadata.isEmpty {
                                    continuation.yield(.reasoningDeltaPart(
                                        id: reasoningID,
                                        delta: delta,
                                        providerMetadata: providerMetadata
                                    ))
                                }
                                continuation.yield(.reasoningEnd(id: reasoningID))
                                reasoningSegmentCount += 1
                            case let .text(text):
                                if !emittedTextStart {
                                    continuation.yield(.textStart(id: textID, providerMetadata: startMetadata))
                                    emittedTextStart = true
                                }
                                let delta = (textSegmentCount > 0 ? separator : "") + text
                                let providerMetadata = takeDeltaMetadata()
                                if !delta.isEmpty || !providerMetadata.isEmpty {
                                    continuation.yield(.textDeltaPart(
                                        id: textID,
                                        delta: delta,
                                        providerMetadata: providerMetadata
                                    ))
                                }
                                textSegmentCount += 1
                            }
                        }

                        if !emittedTextStart {
                            continuation.yield(.textStart(id: textID, providerMetadata: startMetadata))
                        }
                        if !pendingDeltaMetadata.isEmpty {
                            continuation.yield(.textDeltaPart(
                                id: textID,
                                delta: "",
                                providerMetadata: takeDeltaMetadata()
                            ))
                        }
                        continuation.yield(.textEnd(id: textID, citations: citations, providerMetadata: endMetadata))
                    } else if !textBuffer.isEmpty {
                        continuation.yield(.textStart(id: textID, providerMetadata: startMetadata))
                        continuation.yield(.textDeltaPart(
                            id: textID,
                            delta: textBuffer,
                            providerMetadata: takeDeltaMetadata()
                        ))
                        continuation.yield(.textEnd(id: textID, citations: citations, providerMetadata: endMetadata))
                    } else {
                        continuation.yield(.textStart(id: textID, providerMetadata: startMetadata))
                        if !pendingDeltaMetadata.isEmpty {
                            continuation.yield(.textDeltaPart(
                                id: textID,
                                delta: "",
                                providerMetadata: takeDeltaMetadata()
                            ))
                        }
                        continuation.yield(.textEnd(id: textID, citations: citations, providerMetadata: endMetadata))
                    }
                    textBuffers[textID] = nil
                    textStartMetadata[textID] = nil
                    textDeltaMetadata[textID] = nil
                    textEndMetadata[textID] = nil
                    textCitations[textID] = nil
                    activeTextIDs.remove(textID)
                }

                func flushAllExtractedText() {
                    for id in textIDOrder where activeTextIDs.contains(id) {
                        flushExtractedText(id: id)
                    }
                    textIDOrder.removeAll()
                }

                for try await part in canonicalLanguageStream(stream, providerID: "extract-reasoning-middleware") {
                    switch part {
                    case let .textStart(id, providerMetadata):
                        markTextID(id)
                        textStartMetadata[id] = providerMetadata
                    case let .textDeltaPart(id, delta, providerMetadata):
                        markTextID(id)
                        textBuffers[id, default: ""] += delta
                        textDeltaMetadata[id, default: [:]].merge(providerMetadata) { _, new in new }
                    case let .textEnd(id, providerMetadata), let .textEndWithCitations(id, _, providerMetadata):
                        markTextID(id)
                        textEndMetadata[id] = providerMetadata
                        textCitations[id] = part.citations
                        flushExtractedText(id: id)
                    case .finishMetadata:
                        flushAllExtractedText()
                        continuation.yield(part)
                    default:
                        continuation.yield(part)
                    }
                }
                flushAllExtractedText()
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}