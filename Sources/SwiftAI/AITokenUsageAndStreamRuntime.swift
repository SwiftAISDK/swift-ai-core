import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func sumTokenUsage(_ lhs: TokenUsage?, _ rhs: TokenUsage?) -> TokenUsage? {
    guard lhs != nil || rhs != nil else { return nil }
    return TokenUsage(
        inputTokens: optionalSum(lhs?.inputTokens, rhs?.inputTokens),
        outputTokens: optionalSum(lhs?.outputTokens, rhs?.outputTokens),
        totalTokens: optionalSum(lhs?.totalTokens, rhs?.totalTokens),
        inputTokensNoCache: optionalSum(lhs?.inputTokensNoCache, rhs?.inputTokensNoCache),
        inputTokensCacheRead: optionalSum(lhs?.inputTokensCacheRead, rhs?.inputTokensCacheRead),
        inputTokensCacheWrite: optionalSum(lhs?.inputTokensCacheWrite, rhs?.inputTokensCacheWrite),
        outputTextTokens: optionalSum(lhs?.outputTextTokens, rhs?.outputTextTokens),
        outputReasoningTokens: optionalSum(lhs?.outputReasoningTokens, rhs?.outputReasoningTokens),
        rawValue: isEmptyTokenUsage(lhs) ? rhs?.rawValue : isEmptyTokenUsage(rhs) ? lhs?.rawValue : nil
    )
}

private func isEmptyTokenUsage(_ usage: TokenUsage?) -> Bool {
    guard let usage else { return true }
    return usage.inputTokens == nil && usage.outputTokens == nil && usage.totalTokens == nil
        && usage.inputTokensNoCache == nil && usage.inputTokensCacheRead == nil
        && usage.inputTokensCacheWrite == nil && usage.outputTextTokens == nil
        && usage.outputReasoningTokens == nil && usage.rawValue == nil
}

func optionalSum(_ lhs: Int?, _ rhs: Int?) -> Int? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        return lhs + rhs
    case let (lhs?, nil):
        return lhs
    case let (nil, rhs?):
        return rhs
    case (nil, nil):
        return nil
    }
}

func isCancellationTelemetryError(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }
    if error is AIAbortError {
        return true
    }
    if let retryError = error as? AIRetryError, retryError.reason == .cancelled {
        return true
    }
    return false
}

struct LanguageStreamToolStep {
    var text = ""
    var reasoning = ""
    var finishReason: String?
    var usage: TokenUsage?
    var files: [AIStreamFile] = []
    var toolCalls: [AIToolCall] = []
    var streamedToolResults: [AIToolResult] = []
    var approvalRequests: [AIToolApprovalRequest] = []
    var approvalResponses: [AIToolApprovalResponse] = []
    var sources: [AISource] = []
    var warnings: [AIWarning] = []
    var providerMetadata: [String: JSONValue] = [:]
    var responseMetadata = AIResponseMetadata()
    var orderedContent: [AIResultContentPart] = []
    var contentIndicesByStreamKey: [String: Int] = [:]
    var hasUnterminatedInBandError = false

    mutating func record(_ part: LanguageStreamPart) {
        switch part {
        case let .streamStart(partWarnings):
            warnings.append(contentsOf: partWarnings)
        case let .textDelta(delta):
            text += delta
            appendTextContent(id: "__default", delta: delta)
        case let .textStart(id, metadata):
            ensureTextContent(id: id, providerMetadata: metadata)
        case let .textDeltaPart(id, delta, metadata):
            text += delta
            appendTextContent(id: id, delta: delta, providerMetadata: metadata)
        case let .textEnd(id, metadata):
            mergeTextContentMetadata(id: id, providerMetadata: metadata)
        case let .textEndWithCitations(id, citations, metadata):
            mergeTextContentMetadata(id: id, providerMetadata: metadata, citations: citations)
        case let .reasoningDelta(delta):
            reasoning += delta
            appendReasoningContent(id: "__default", delta: delta)
        case let .reasoningStart(id, metadata):
            ensureReasoningContent(id: id, providerMetadata: metadata)
        case let .reasoningDeltaPart(id, delta, metadata):
            reasoning += delta
            appendReasoningContent(id: id, delta: delta, providerMetadata: metadata)
        case let .reasoningEnd(id, metadata):
            mergeReasoningContentMetadata(id: id, providerMetadata: metadata)
        case let .toolCall(toolCall):
            toolCalls.append(toolCall)
            orderedContent.append(.toolCall(toolCall))
        case let .toolResult(toolResult):
            streamedToolResults.append(toolResult)
            orderedContent.append(.toolResult(toolResult))
        case let .toolApprovalRequest(approvalRequest):
            approvalRequests.append(approvalRequest)
            orderedContent.append(.toolApprovalRequest(approvalRequest))
        case let .toolApprovalResponse(approvalResponse):
            approvalResponses.append(approvalResponse)
            orderedContent.append(.toolApprovalResponse(approvalResponse))
        case let .file(file):
            files.append(file)
            orderedContent.append(.file(file))
        case let .reasoningFile(file):
            orderedContent.append(.reasoningFile(file))
        case let .custom(value, metadata):
            orderedContent.append(.custom(value, providerMetadata: metadata))
        case let .source(source):
            sources.append(source)
            orderedContent.append(.source(source))
        case let .metadata(metadata):
            providerMetadata.merge(metadata) { _, new in new }
        case let .responseMetadata(metadata):
            responseMetadata = metadata
        case .error:
            finishReason = "error"
            hasUnterminatedInBandError = true
        case let .finish(reason, partUsage):
            finishReason = reason ?? (hasUnterminatedInBandError ? "error" : nil)
            usage = partUsage
            hasUnterminatedInBandError = false
        case let .finishMetadata(reason, partUsage, metadata):
            finishReason = reason ?? (hasUnterminatedInBandError ? "error" : nil)
            usage = partUsage
            providerMetadata.merge(metadata) { _, new in new }
            hasUnterminatedInBandError = false
        default:
            break
        }
    }

    mutating func ensureTextContent(id: String, providerMetadata: [String: JSONValue] = [:]) {
        ensureContent(key: "text:\(id)", part: .text("", providerMetadata: providerMetadata))
    }

    mutating func appendTextContent(
        id: String,
        delta: String,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        let key = "text:\(id)"
        ensureTextContent(id: id, providerMetadata: providerMetadata)
        guard let index = contentIndicesByStreamKey[key],
              case let .text(existing, existingMetadata) = orderedContent[index] else {
            return
        }
        orderedContent[index] = .text(
            existing + delta,
            providerMetadata: mergeProviderMetadata(existingMetadata, providerMetadata)
        )
    }

    mutating func mergeTextContentMetadata(id: String, providerMetadata: [String: JSONValue], citations: [AICitation] = []) {
        let key = "text:\(id)"
        guard let index = contentIndicesByStreamKey[key],
              case let .text(existing, existingMetadata) = orderedContent[index] else {
            return
        }
        orderedContent[index] = .text(
            existing,
            citations: citations,
            providerMetadata: mergeProviderMetadata(existingMetadata, providerMetadata)
        )
    }

    mutating func ensureReasoningContent(id: String, providerMetadata: [String: JSONValue] = [:]) {
        ensureContent(key: "reasoning:\(id)", part: .reasoning("", providerMetadata: providerMetadata))
    }

    mutating func appendReasoningContent(
        id: String,
        delta: String,
        providerMetadata: [String: JSONValue] = [:]
    ) {
        let key = "reasoning:\(id)"
        ensureReasoningContent(id: id, providerMetadata: providerMetadata)
        guard let index = contentIndicesByStreamKey[key],
              case let .reasoning(existing, existingMetadata) = orderedContent[index] else {
            return
        }
        orderedContent[index] = .reasoning(
            existing + delta,
            providerMetadata: mergeProviderMetadata(existingMetadata, providerMetadata)
        )
    }

    mutating func mergeReasoningContentMetadata(id: String, providerMetadata: [String: JSONValue]) {
        let key = "reasoning:\(id)"
        guard let index = contentIndicesByStreamKey[key],
              case let .reasoning(existing, existingMetadata) = orderedContent[index] else {
            return
        }
        orderedContent[index] = .reasoning(
            existing,
            providerMetadata: mergeProviderMetadata(existingMetadata, providerMetadata)
        )
    }

    mutating func ensureContent(key: String, part: AIResultContentPart) {
        guard contentIndicesByStreamKey[key] == nil else { return }
        contentIndicesByStreamKey[key] = orderedContent.count
        orderedContent.append(part)
    }

    func toolStep(
        index: Int,
        toolResults: [AIToolResult],
        approvalRequests: [AIToolApprovalRequest],
        approvalResponses: [AIToolApprovalResponse]
    ) -> AIToolStep {
        let stepApprovalRequests = self.approvalRequests + approvalRequests
        let stepApprovalResponses = self.approvalResponses + approvalResponses
        let stepToolResults = streamedToolResults + toolResults
        let content = orderedContent.isEmpty
            ? synthesizeResultContent(
                text: text,
                reasoning: reasoning,
                files: files,
                toolCalls: toolCalls,
                toolResults: stepToolResults,
                toolApprovalRequests: stepApprovalRequests,
                toolApprovalResponses: stepApprovalResponses,
                sources: sources
            )
            : synthesizedOrderedContent(
                orderedContent: orderedContent,
                generatedApprovalRequests: approvalRequests,
                generatedApprovalResponses: approvalResponses,
                generatedToolResults: toolResults
            )
        return AIToolStep(
            index: index,
            content: content,
            text: text,
            reasoning: reasoning,
            finishReason: finishReason,
            usage: usage,
            files: files,
            toolCalls: toolCalls,
            toolResults: stepToolResults,
            toolApprovalRequests: stepApprovalRequests,
            toolApprovalResponses: stepApprovalResponses,
            sources: sources,
            warnings: warnings,
            providerMetadata: providerMetadata,
            responseMetadata: responseMetadata
        )
    }
}

func validateEnforcedToolChoice(
    _ toolChoice: JSONValue?,
    step: LanguageStreamToolStep,
    providerID: String,
    modelID: String
) throws {
    let content = step.toolStep(
        index: 0,
        toolResults: [],
        approvalRequests: [],
        approvalResponses: []
    ).content
    try validateEnforcedToolChoice(
        toolChoice,
        result: TextGenerationResult(
            text: step.text,
            content: content,
            reasoning: step.reasoning,
            finishReason: step.finishReason,
            usage: step.usage,
            files: step.files,
            toolCalls: step.toolCalls,
            toolResults: step.streamedToolResults,
            sources: step.sources,
            providerMetadata: step.providerMetadata,
            rawValue: .null,
            warnings: step.warnings,
            responseMetadata: step.responseMetadata
        ),
        providerID: providerID,
        modelID: modelID
    )
}

/// Validates semantic tool-choice requirements after the provider stream has
/// completed. A violation is a non-retryable semantic error, and validation
/// precedes the terminal part so consumers cannot mistake it for success.
func validatedEnforcedToolChoiceStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    toolChoice: JSONValue?,
    providerID: String,
    modelID: String
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    let prepared = prepareToolChoice(toolChoice)
    guard prepared["type"]?.stringValue == "required"
        || prepared["type"]?.stringValue == "tool"
        || prepared["type"]?.stringValue == "none" else {
        return stream
    }
    return AsyncThrowingStream { continuation in
        let task = Task {
            do {
                var step = LanguageStreamToolStep()
                var validatedAtTerminalPart = false
                for try await part in stream {
                    step.record(part)
                    switch part {
                    case .finish, .finishMetadata:
                        // Validate before publishing the terminal part. Some
                        // consumers treat that part as the semantic end of the
                        // stream and do not request another iterator element.
                        try validateEnforcedToolChoice(
                            prepared,
                            step: step,
                            providerID: providerID,
                            modelID: modelID
                        )
                        validatedAtTerminalPart = true
                    default:
                        break
                    }
                    if prepared["type"]?.stringValue == "none" {
                        switch part {
                        case .toolInputStart, .toolInputStartText, .toolInputDelta, .toolInputEnd,
                             .toolCall, .toolResult, .toolApprovalRequest, .toolApprovalResponse:
                            continue
                        default:
                            break
                        }
                    }
                    continuation.yield(part)
                }
                if !validatedAtTerminalPart {
                    try validateEnforcedToolChoice(
                        prepared,
                        step: step,
                        providerID: providerID,
                        modelID: modelID
                    )
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
    }
}

private func synthesizedOrderedContent(
    orderedContent: [AIResultContentPart],
    generatedApprovalRequests: [AIToolApprovalRequest],
    generatedApprovalResponses: [AIToolApprovalResponse],
    generatedToolResults: [AIToolResult]
) -> [AIResultContentPart] {
    var content = orderedContent.filter { part in
        switch part {
        case let .text(text, _), let .reasoning(text, _):
            return !text.isEmpty
        default:
            return true
        }
    }
    content.append(contentsOf: generatedApprovalRequests.map(AIResultContentPart.toolApprovalRequest))
    content.append(contentsOf: generatedApprovalResponses.map(AIResultContentPart.toolApprovalResponse))
    content.append(contentsOf: generatedToolResults.map(AIResultContentPart.toolResult))
    return content
}

private func mergeProviderMetadata(
    _ lhs: [String: JSONValue],
    _ rhs: [String: JSONValue]
) -> [String: JSONValue] {
    guard !rhs.isEmpty else { return lhs }
    var merged = lhs
    merged.merge(rhs) { _, new in new }
    return merged
}

final class LanguageStreamPartIDReserver: @unchecked Sendable {
    private var usedTextIDs: Set<String> = []
    private var usedReasoningIDs: Set<String> = []

    func reserveTextID(_ id: String) -> String {
        reserve(id, usedIDs: &usedTextIDs)
    }

    func reserveReasoningID(_ id: String) -> String {
        reserve(id, usedIDs: &usedReasoningIDs)
    }

    private func reserve(_ id: String, usedIDs: inout Set<String>) -> String {
        guard !usedIDs.contains(id) else {
            var candidate: String
            repeat {
                candidate = "part-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
            } while usedIDs.contains(candidate)
            usedIDs.insert(candidate)
            return candidate
        }
        usedIDs.insert(id)
        return id
    }
}

func forwardLanguageStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    to continuation: AsyncThrowingStream<LanguageStreamPart, Error>.Continuation,
    toolsByName: [String: AITool] = [:],
    executionToolsByName: [String: AITool]? = nil,
    request: LanguageModelRequest? = nil,
    repairToolCall: AIToolCallRepair? = nil,
    partIDReserver: LanguageStreamPartIDReserver? = nil
) async throws -> LanguageStreamToolStep {
    try await forwardLanguageStream(
        internalLanguageStream(stream),
        to: continuation,
        toolsByName: toolsByName,
        executionToolsByName: executionToolsByName,
        request: request,
        repairToolCall: repairToolCall,
        partIDReserver: partIDReserver
    )
}

func forwardLanguageStream(
    _ stream: AsyncThrowingStream<StreamTextTelemetryPart, Error>,
    to continuation: AsyncThrowingStream<LanguageStreamPart, Error>.Continuation,
    toolsByName: [String: AITool] = [:],
    executionToolsByName: [String: AITool]? = nil,
    request: LanguageModelRequest? = nil,
    repairToolCall: AIToolCallRepair? = nil,
    partIDReserver: LanguageStreamPartIDReserver? = nil
) async throws -> LanguageStreamToolStep {
    let callbackToolsByName = executionToolsByName ?? toolsByName
    var step = LanguageStreamToolStep()
    var inputToolNamesByID: [String: String] = [:]
    var validatedToolContextIDs: Set<String> = []
    var validatedToolContextsByID: [String: JSONValue] = [:]
    var toolCallsByID: [String: AIToolCall] = [:]
    var textPartIDs: [String: String] = [:]
    var reasoningPartIDs: [String: String] = [:]
    for try await event in stream {
        try Task.checkCancellation()
        guard case let .part(part) = event else {
            step = LanguageStreamToolStep()
            inputToolNamesByID.removeAll()
            validatedToolContextIDs.removeAll()
            validatedToolContextsByID.removeAll()
            toolCallsByID.removeAll()
            textPartIDs.removeAll()
            reasoningPartIDs.removeAll()
            continue
        }
        let forwardedPart: LanguageStreamPart
        let toolInput: JSONValue?
        let shouldInvokeInputAvailable: Bool
        if case let .toolCall(call) = part {
            let forwarded = try await forwardedToolCall(
                call,
                toolsByName: toolsByName,
                repairToolCall: repairToolCall,
                request: request
            )
            forwardedPart = .toolCall(forwarded.call)
            toolInput = forwarded.input
            shouldInvokeInputAvailable = forwarded.shouldInvokeInputAvailable
        } else if case let .toolApprovalRequest(request) = part {
            forwardedPart = try forwardedToolApprovalRequest(request, toolCallsByID: toolCallsByID)
            toolInput = nil
            shouldInvokeInputAvailable = false
        } else {
            forwardedPart = remapLanguageStreamPartID(
                annotateStreamPart(part, toolsByName: toolsByName),
                reserver: partIDReserver,
                textPartIDs: &textPartIDs,
                reasoningPartIDs: &reasoningPartIDs
            )
            toolInput = nil
            shouldInvokeInputAvailable = false
        }

        step.record(forwardedPart)
        continuation.yield(forwardedPart)
        switch forwardedPart {
        case let .toolInputStart(id, name, _, _, _, _), let .toolInputStartText(id, name, _, _, _, _):
            inputToolNamesByID[id] = name
            guard let tool = callbackToolsByName[name], let callback = tool.onInputStart else { break }
            let toolContext = try validatedStreamingToolContext(
                toolCallID: id,
                toolName: name,
                tool: tool,
                request: request,
                validatedIDs: &validatedToolContextIDs,
                cachedContexts: &validatedToolContextsByID
            )
            await callback(AIToolInputStartContext(
                toolCallID: id,
                messages: request?.messages ?? [],
                abortSignal: request?.abortSignal,
                toolContext: toolContext
            ))
        case let .toolInputDelta(id, delta, _):
            guard let name = inputToolNamesByID[id],
                  let tool = callbackToolsByName[name],
                  let callback = tool.onInputDelta else { break }
            let toolContext = try validatedStreamingToolContext(
                toolCallID: id,
                toolName: name,
                tool: tool,
                request: request,
                validatedIDs: &validatedToolContextIDs,
                cachedContexts: &validatedToolContextsByID
            )
            await callback(AIToolInputDeltaContext(
                toolCallID: id,
                inputTextDelta: delta,
                messages: request?.messages ?? [],
                abortSignal: request?.abortSignal,
                toolContext: toolContext
            ))
        case let .toolCall(call):
            toolCallsByID[call.id] = call
            let name = inputToolNamesByID[call.id] ?? call.name
            defer {
                inputToolNamesByID[call.id] = nil
                validatedToolContextIDs.remove(call.id)
                validatedToolContextsByID[call.id] = nil
            }
            guard shouldInvokeInputAvailable,
                  let tool = callbackToolsByName[name],
                  let callback = tool.onInputAvailable else { break }
            let toolContext = try validatedStreamingToolContext(
                toolCallID: call.id,
                toolName: name,
                tool: tool,
                request: request,
                validatedIDs: &validatedToolContextIDs,
                cachedContexts: &validatedToolContextsByID
            )
            await callback(AIToolInputAvailableContext(
                toolCallID: call.id,
                input: try toolInput ?? toolArguments(from: call),
                messages: request?.messages ?? [],
                abortSignal: request?.abortSignal,
                toolContext: toolContext
            ))
        default:
            break
        }
    }
    return step
}

private func validatedStreamingToolContext(
    toolCallID: String,
    toolName: String,
    tool: AITool,
    request: LanguageModelRequest?,
    validatedIDs: inout Set<String>,
    cachedContexts: inout [String: JSONValue]
) throws -> JSONValue? {
    if validatedIDs.contains(toolCallID) {
        return cachedContexts[toolCallID]
    }

    let context: JSONValue?
    if let rawContext = request?.toolContexts[toolName] {
        context = try validateToolContext(
            toolName: toolName,
            context: rawContext,
            contextSchema: tool.contextSchema
        )
    } else {
        context = nil
    }
    validatedIDs.insert(toolCallID)
    cachedContexts[toolCallID] = context
    return context
}

private func remapLanguageStreamPartID(
    _ part: LanguageStreamPart,
    reserver: LanguageStreamPartIDReserver?,
    textPartIDs: inout [String: String],
    reasoningPartIDs: inout [String: String]
) -> LanguageStreamPart {
    guard let reserver else { return part }
    switch part {
    case let .textStart(id, providerMetadata):
        let reservedID = reserver.reserveTextID(id)
        textPartIDs[id] = reservedID
        return .textStart(id: reservedID, providerMetadata: providerMetadata)
    case let .textDeltaPart(id, delta, providerMetadata):
        return .textDeltaPart(
            id: textPartIDs[id] ?? id,
            delta: delta,
            providerMetadata: providerMetadata
        )
    case let .textEnd(id, providerMetadata):
        let reservedID = textPartIDs.removeValue(forKey: id) ?? id
        return .textEnd(id: reservedID, providerMetadata: providerMetadata)
    case let .textEndWithCitations(id, citations, providerMetadata):
        let reservedID = textPartIDs.removeValue(forKey: id) ?? id
        return .textEnd(id: reservedID, citations: citations, providerMetadata: providerMetadata)
    case let .reasoningStart(id, providerMetadata):
        let reservedID = reserver.reserveReasoningID(id)
        reasoningPartIDs[id] = reservedID
        return .reasoningStart(id: reservedID, providerMetadata: providerMetadata)
    case let .reasoningDeltaPart(id, delta, providerMetadata):
        return .reasoningDeltaPart(
            id: reasoningPartIDs[id] ?? id,
            delta: delta,
            providerMetadata: providerMetadata
        )
    case let .reasoningEnd(id, providerMetadata):
        let reservedID = reasoningPartIDs.removeValue(forKey: id) ?? id
        return .reasoningEnd(id: reservedID, providerMetadata: providerMetadata)
    default:
        return part
    }
}

func forwardedLanguageStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    toolsByName: [String: AITool] = [:],
    request: LanguageModelRequest? = nil,
    repairToolCall: AIToolCallRepair? = nil
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                _ = try await forwardLanguageStream(
                    stream,
                    to: continuation,
                    toolsByName: toolsByName,
                    request: request,
                    repairToolCall: repairToolCall
                )
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

func forwardedToolCall(
    _ call: AIToolCall,
    toolsByName: [String: AITool],
    repairToolCall: AIToolCallRepair?,
    request: LanguageModelRequest?
) async throws -> (call: AIToolCall, input: JSONValue?, shouldInvokeInputAvailable: Bool) {
    let annotatedCall = annotateToolCalls([call], toolsByName: toolsByName)[0]
    guard !toolsByName.isEmpty else {
        return (annotatedCall, nil, false)
    }

    let parsed: AIParsedToolCall
    do {
        parsed = try await parseToolCall(
            annotatedCall,
            toolsByName: toolsByName,
            repairToolCall: repairToolCall,
            request: request
        )
    } catch {
        guard isToolCallResultError(error) else { throw error }
        return (annotatedCall, nil, false)
    }
    var forwardedCall = parsed.toolCall
    let originalInput = try? toolArguments(from: annotatedCall)
    if originalInput.map({ $0 != parsed.input }) ?? true {
        forwardedCall.arguments = canonicalJSONText(parsed.input) ?? forwardedCall.arguments
    }
    return (forwardedCall, parsed.input, true)
}

private func forwardedToolApprovalRequest(
    _ request: AIToolApprovalRequest,
    toolCallsByID: [String: AIToolCall]
) throws -> LanguageStreamPart {
    guard let toolCallID = request.toolCallID else {
        return .toolApprovalRequest(request)
    }
    guard let toolCall = toolCallsByID[toolCallID] else {
        throw AIToolCallNotFoundForApprovalError(toolCallID: toolCallID, approvalID: request.id)
    }

    var forwardedRequest = request
    forwardedRequest.toolName = toolCall.name
    forwardedRequest.arguments = toolCall.arguments
    return .toolApprovalRequest(forwardedRequest)
}

func isStopConditionMet(_ stopConditions: [AIStopCondition], steps: [AIToolStep]) async throws -> Bool {
    let context = AIStopConditionContext(steps: steps)
    for condition in stopConditions {
        if try await condition.evaluate(context) {
            return true
        }
    }
    return false
}