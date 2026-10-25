import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func isAutomaticToolExecutionAllowed(finishReason: String?) -> Bool {
    finishReason == "stop" || finishReason == "tool-calls"
}

func toolsDictionary(from tools: [AITool]) -> [String: JSONValue] {
    Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.schema) })
}

func toolsByName(from tools: [AITool]) throws -> [String: AITool] {
    var output: [String: AITool] = [:]
    for tool in tools {
        guard output[tool.name] == nil else {
            throw AIError.invalidArgument(argument: "executableTools", message: "Duplicate tool name '\(tool.name)'.")
        }
        output[tool.name] = tool
    }
    return output
}

struct AIToolExecutionBatch: Sendable {
    var results: [AIToolResult] = []
    var approvalRequests: [AIToolApprovalRequest] = []
    var approvalResponses: [AIToolApprovalResponse] = []
    var needsUserApproval = false
}

struct AIParsedToolCall: Equatable, Sendable {
    var toolCall: AIToolCall
    var input: JSONValue
    var inputSchemaInput: JSONValue?
}

func toolResponseMessages(
    approvalResponses: [AIToolApprovalResponse],
    toolResults: [AIToolResult]
) -> [AIMessage] {
    guard !approvalResponses.isEmpty || !toolResults.isEmpty else { return [] }
    return [AIMessage.toolResponses(approvalResponses: approvalResponses, toolResults: toolResults)]
}

func annotateToolCalls(_ calls: [AIToolCall], toolsByName: [String: AITool]) -> [AIToolCall] {
    calls.map { call in
        guard toolsByName[call.name]?.dynamic == true, !call.dynamic else { return call }
        var annotated = call
        annotated.dynamic = true
        return annotated
    }
}

func annotateToolResult(_ result: AIToolResult, toolsByName: [String: AITool]) -> AIToolResult {
    guard toolsByName[result.toolName]?.dynamic == true, !result.dynamic else { return result }
    var annotated = result
    annotated.dynamic = true
    return annotated
}

func annotateStreamPart(_ part: LanguageStreamPart, toolsByName: [String: AITool]) -> LanguageStreamPart {
    switch part {
    case let .toolInputStart(id, name, providerExecuted, dynamic, title, providerMetadata),
         let .toolInputStartText(id, name, providerExecuted, dynamic, title, providerMetadata):
        guard toolsByName[name]?.dynamic == true, !dynamic else { return part }
        return .toolInputStart(
            id: id,
            name: name,
            inputEncoding: part.inputEncoding ?? .json,
            providerExecuted: providerExecuted,
            dynamic: true,
            title: title,
            providerMetadata: providerMetadata
        )
    case let .toolCall(call):
        return .toolCall(annotateToolCalls([call], toolsByName: toolsByName)[0])
    case let .toolResult(result):
        return .toolResult(annotateToolResult(result, toolsByName: toolsByName))
    default:
        return part
    }
}

func parseToolCall(
    _ call: AIToolCall,
    toolsByName: [String: AITool]?,
    repairToolCall: AIToolCallRepair? = nil,
    request: LanguageModelRequest? = nil
) async throws -> AIParsedToolCall {
    guard let toolsByName else {
        if call.providerExecuted {
            return AIParsedToolCall(
                toolCall: call,
                input: try toolArguments(from: call),
                inputSchemaInput: nil
            )
        }
        throw AINoSuchToolError(toolName: call.name)
    }

    do {
        return try await parseToolCallWithoutRepair(call, toolsByName: toolsByName)
    } catch {
        guard let repairToolCall, isRepairableToolCallError(error) else {
            throw error
        }
        let repairedCall: AIToolCall?
        do {
            repairedCall = try await repairToolCall(AIToolCallRepairContext(
                toolCall: call,
                toolsByName: toolsByName,
                request: request,
                error: error
            ))
        } catch {
            throw AIToolCallRepairError(
                toolName: call.name,
                toolCallID: call.id,
                originalError: String(describing: error)
            )
        }
        guard let repairedCall else {
            throw error
        }
        return try await parseToolCallWithoutRepair(repairedCall, toolsByName: toolsByName)
    }
}

private func parseToolCallWithoutRepair(
    _ call: AIToolCall,
    toolsByName: [String: AITool]
) async throws -> AIParsedToolCall {
    guard let tool = toolsByName[call.name] else {
        if call.providerExecuted {
            return AIParsedToolCall(
                toolCall: call,
                input: try toolArguments(from: call),
                inputSchemaInput: nil
            )
        }
        throw AINoSuchToolError(toolName: call.name, availableToolNames: Array(toolsByName.keys))
    }
    let arguments = try toolArguments(from: call)
    let refinedArguments: JSONValue
    do {
        refinedArguments = try await tool.refineArguments?(arguments) ?? arguments
    } catch {
        throw AIToolCallRepairError(
            toolName: call.name,
            toolCallID: call.id,
            originalError: String(describing: error)
        )
    }
    try validateToolArguments(refinedArguments, schema: tool.parameters, call: call)

    var parsedCall = call
    if arguments != refinedArguments {
        parsedCall.arguments = canonicalJSONText(refinedArguments) ?? parsedCall.arguments
    }
    if tool.dynamic {
        parsedCall.dynamic = true
    }
    let inputSchemaInput: JSONValue? = arguments == refinedArguments ? .none : arguments
    return AIParsedToolCall(
        toolCall: parsedCall,
        input: refinedArguments,
        inputSchemaInput: inputSchemaInput
    )
}

private func isRepairableToolCallError(_ error: any Error) -> Bool {
    error is AINoSuchToolError || error is AIInvalidToolInputError
}

func resolveToolApproval(
    toolsByName: [String: AITool],
    toolCall: AIToolCall,
    arguments: JSONValue,
    request: LanguageModelRequest,
    toolApproval: AIToolApproval?
) async throws -> AIToolApprovalStatus {
    try await resolveToolApprovalDecision(
        toolsByName: toolsByName,
        toolCall: toolCall,
        arguments: arguments,
        request: request,
        toolApproval: toolApproval
    ).status
}

private struct AIResolvedToolApproval {
    var status: AIToolApprovalStatus
    var userApprovalReason: String?
}

private func resolveToolApprovalDecision(
    toolsByName: [String: AITool],
    toolCall: AIToolCall,
    arguments: JSONValue,
    request: LanguageModelRequest,
    toolApproval: AIToolApproval?
) async throws -> AIResolvedToolApproval {
    guard let tool = toolsByName[toolCall.name] else {
        throw AINoSuchToolError(toolName: toolCall.name, availableToolNames: Array(toolsByName.keys))
    }

    if let toolApproval {
        let reasonCapture = AIToolApprovalReasonCapture()
        let status = try await toolApproval(AIToolApprovalContext(
            toolCall: toolCall,
            arguments: arguments,
            tool: tool,
            request: request,
            toolContext: rawToolContext(for: tool, toolCall: toolCall, request: request),
            approvalReasonCapture: reasonCapture
        )) ?? .notApplicable
        return AIResolvedToolApproval(
            status: status,
            userApprovalReason: status == .userApproval ? reasonCapture.get() : nil
        )
    }

    guard let needsApproval = tool.needsApproval else {
        return AIResolvedToolApproval(status: .notApplicable, userApprovalReason: nil)
    }

    let toolContext = try validatedToolContext(for: tool, toolCall: toolCall, request: request)
    let needsUserApproval = try await needsApproval(arguments, AIToolNeedsApprovalContext(
        toolCallID: toolCall.id,
        messages: request.messages,
        context: toolContext
    ))
    return AIResolvedToolApproval(
        status: needsUserApproval ? .userApproval : .notApplicable,
        userApprovalReason: nil
    )
}

private func rawToolContext(for tool: AITool, toolCall: AIToolCall, request: LanguageModelRequest) -> JSONValue? {
    request.toolContexts[tool.name] ?? toolCall.providerMetadata["context"]
}

private func validatedToolContext(for tool: AITool, toolCall: AIToolCall, request: LanguageModelRequest) throws -> JSONValue? {
    guard let rawContext = rawToolContext(for: tool, toolCall: toolCall, request: request) else { return nil }
    return try validateToolContext(
        toolName: tool.name,
        context: rawContext,
        contextSchema: tool.contextSchema
    )
}

func executeToolCalls(
    _ calls: [AIToolCall], toolsByName: [String: AITool], request: LanguageModelRequest,
    toolApproval: AIToolApproval?, repairToolCall: AIToolCallRepair? = nil,
    telemetry: AIToolLoopTelemetryContext? = nil, stepIndex: Int = 0,
    convertToolErrorsToResults: Bool = false, invokeInputAvailableCallbacks: Bool = true
) async throws -> AIToolExecutionBatch {
    let batches = try await mapToolCallsWithConcurrency(calls, concurrency: request.toolCallConcurrency, abortSignal: request.abortSignal) { call in
        try await executeToolCallsSequentially(
            [call], toolsByName: toolsByName, request: request, toolApproval: toolApproval,
            repairToolCall: repairToolCall, telemetry: telemetry, stepIndex: stepIndex,
            convertToolErrorsToResults: convertToolErrorsToResults,
            invokeInputAvailableCallbacks: invokeInputAvailableCallbacks
        )
    }
    var batch = AIToolExecutionBatch()
    for item in batches {
        batch.results += item.results
        batch.approvalRequests += item.approvalRequests
        batch.approvalResponses += item.approvalResponses
        batch.needsUserApproval = batch.needsUserApproval || item.needsUserApproval
    }
    return batch
}

private func executeToolCallsSequentially(
    _ calls: [AIToolCall],
    toolsByName: [String: AITool],
    request: LanguageModelRequest,
    toolApproval: AIToolApproval?,
    repairToolCall: AIToolCallRepair? = nil,
    telemetry: AIToolLoopTelemetryContext? = nil,
    stepIndex: Int = 0,
    convertToolErrorsToResults: Bool = false,
    invokeInputAvailableCallbacks: Bool = true
) async throws -> AIToolExecutionBatch {
    var batch = AIToolExecutionBatch()
    for call in calls {
        do {
            let parsedToolCall = try await parseToolCall(
                call,
                toolsByName: toolsByName,
                repairToolCall: repairToolCall,
                request: request
            )
            let parsedCall = parsedToolCall.toolCall
            let refinedArguments = parsedToolCall.input
            let inputSchemaInput = parsedToolCall.inputSchemaInput
            guard let tool = toolsByName[parsedCall.name] else {
                throw AINoSuchToolError(toolName: parsedCall.name, availableToolNames: Array(toolsByName.keys))
            }
            let toolContext = try validatedToolContext(for: tool, toolCall: parsedCall, request: request)
            if invokeInputAvailableCallbacks {
                await tool.onInputAvailable?(AIToolInputAvailableContext(
                    toolCallID: parsedCall.id,
                    input: refinedArguments,
                    messages: request.messages,
                    abortSignal: request.abortSignal,
                    toolContext: toolContext
                ))
            }
            await telemetry?.recordToolStart(stepIndex: stepIndex, call: parsedCall, tool: tool)
            let approvalDecision = try await resolveToolApprovalDecision(
                toolsByName: toolsByName,
                toolCall: parsedCall,
                arguments: refinedArguments,
                request: request,
                toolApproval: toolApproval
            )
            let approvalStatus = approvalDecision.status
            let approvalID = "approval-\(parsedCall.id)"
            var approvalRequest: AIToolApprovalRequest?
            var approvalResponse: AIToolApprovalResponse?
            switch approvalStatus {
            case .notApplicable:
                break
            case let .approved(reason):
                approvalRequest = AIToolApprovalRequest(
                    id: approvalID,
                    toolName: parsedCall.name,
                    arguments: parsedCall.arguments,
                    toolCallID: parsedCall.id,
                    inputSchemaInput: inputSchemaInput,
                    isAutomatic: true,
                    providerMetadata: parsedCall.providerMetadata
                )
                approvalResponse = AIToolApprovalResponse(
                    id: approvalID,
                    approved: true,
                    reason: reason,
                    providerExecuted: parsedCall.providerExecuted,
                    providerMetadata: parsedCall.providerMetadata
                )
                batch.approvalRequests.append(approvalRequest!)
                batch.approvalResponses.append(approvalResponse!)
            case let .denied(reason):
                approvalRequest = AIToolApprovalRequest(
                    id: approvalID,
                    toolName: parsedCall.name,
                    arguments: parsedCall.arguments,
                    toolCallID: parsedCall.id,
                    inputSchemaInput: inputSchemaInput,
                    isAutomatic: true,
                    providerMetadata: parsedCall.providerMetadata
                )
                approvalResponse = AIToolApprovalResponse(
                    id: approvalID,
                    approved: false,
                    reason: reason,
                    providerExecuted: parsedCall.providerExecuted,
                    providerMetadata: parsedCall.providerMetadata
                )
                batch.approvalRequests.append(approvalRequest!)
                batch.approvalResponses.append(approvalResponse!)
                let dynamic = parsedCall.dynamic || tool.dynamic
                let result = AIToolResult(
                    toolCallID: parsedCall.id,
                    toolName: parsedCall.name,
                    result: executionDeniedResult(reason: reason),
                    dynamic: dynamic,
                    providerMetadata: parsedCall.providerMetadata
                )
                batch.results.append(result)
                await telemetry?.recordToolEnd(
                    stepIndex: stepIndex,
                    call: parsedCall,
                    status: "denied",
                    arguments: refinedArguments,
                    result: result,
                    approvalRequest: approvalRequest,
                    approvalResponse: approvalResponse
                )
                continue
            case .userApproval:
                approvalRequest = AIToolApprovalRequest(
                    id: approvalID,
                    toolName: parsedCall.name,
                    arguments: parsedCall.arguments,
                    toolCallID: parsedCall.id,
                    inputSchemaInput: inputSchemaInput,
                    reason: approvalDecision.userApprovalReason,
                    providerMetadata: parsedCall.providerMetadata
                )
                batch.approvalRequests.append(approvalRequest!)
                batch.needsUserApproval = true
                await telemetry?.recordToolEnd(
                    stepIndex: stepIndex,
                    call: parsedCall,
                    status: "userApproval",
                    arguments: refinedArguments,
                    approvalRequest: approvalRequest
                )
                continue
            }
            let resultValue: JSONValue
            let executionContext = AIToolExecutionContext(
                toolCallID: parsedCall.id,
                messages: request.messages,
                abortSignal: request.abortSignal,
                metadata: parsedCall.providerMetadata,
                toolContext: toolContext
            )
            do {
                if let telemetry {
                    resultValue = try await telemetry.executeTool(call: parsedCall) {
                        try await tool.executeWithContext(refinedArguments, executionContext)
                    }
                } else {
                    resultValue = try await tool.executeWithContext(refinedArguments, executionContext)
                }
            } catch {
                guard convertToolErrorsToResults else { throw error }
                await telemetry?.recordToolError(stepIndex: stepIndex, call: parsedCall, error: error)
                let dynamic = parsedCall.dynamic || tool.dynamic
                batch.results.append(toolExecutionErrorResult(
                    error,
                    toolCall: parsedCall,
                    dynamic: dynamic
                ))
                continue
            }
            let modelOutput = try await tool.toModelOutput?(AIToolModelOutputContext(
                toolCallID: parsedCall.id,
                input: refinedArguments,
                output: resultValue
            ))
            let dynamic = parsedCall.dynamic || tool.dynamic
            let result = AIToolResult(
                toolCallID: parsedCall.id,
                toolName: parsedCall.name,
                result: resultValue,
                modelOutput: modelOutput,
                dynamic: dynamic,
                providerMetadata: parsedCall.providerMetadata
            )
            batch.results.append(result)
            await telemetry?.recordToolEnd(
                stepIndex: stepIndex,
                call: parsedCall,
                status: "executed",
                arguments: refinedArguments,
                result: result,
                approvalRequest: approvalRequest,
                approvalResponse: approvalResponse
            )
        } catch {
            await telemetry?.recordToolError(stepIndex: stepIndex, call: call, error: error)
            if convertToolErrorsToResults, isToolCallResultError(error) {
                batch.results.append(toolCallErrorResult(
                    error,
                    toolCall: call,
                    dynamic: call.dynamic || (toolsByName[call.name]?.dynamic == true)
                ))
                continue
            }
            throw error
        }
    }
    return batch
}

struct AIHistoricalToolApprovalExecution: Sendable {
    var responseMessages: [AIMessage] = []
    var toolResults: [AIToolResult] = []
    var approvalResponses: [AIToolApprovalResponse] = []
}

func executeHistoricalToolApprovals(
    request: LanguageModelRequest,
    toolsByName: [String: AITool],
    toolApproval: AIToolApproval?,
    toolApprovalSecret: String? = nil,
    telemetry: AIToolLoopTelemetryContext? = nil,
    stepIndex: Int = 0
) async throws -> AIHistoricalToolApprovalExecution {
    let collected = try collectToolApprovals(messages: request.messages)
    guard !collected.approvedToolApprovals.isEmpty || !collected.deniedToolApprovals.isEmpty else {
        return AIHistoricalToolApprovalExecution()
    }

    let localApprovedApprovals = collected.approvedToolApprovals.filter {
        !$0.toolCall.providerExecuted && !$0.approvalResponse.providerExecuted
    }
    let localDeniedApprovals = collected.deniedToolApprovals.filter {
        !$0.toolCall.providerExecuted && !$0.approvalResponse.providerExecuted
    }
    let providerExecutedDeniedApprovals = collected.deniedToolApprovals.filter {
        $0.toolCall.providerExecuted || $0.approvalResponse.providerExecuted
    }

    let validated = try await validateApprovedToolApprovals(
        approvedToolApprovals: localApprovedApprovals,
        toolsByName: toolsByName,
        request: request,
        toolApproval: toolApproval,
        toolApprovalSecret: toolApprovalSecret
    )
    let approvedBatch = try await executeToolCalls(
        validated.approvedToolApprovals.map(\.toolCall),
        toolsByName: toolsByName,
        request: request,
        toolApproval: { _ in .notApplicable },
        telemetry: telemetry,
        stepIndex: stepIndex,
        convertToolErrorsToResults: true
    )

    let deniedApprovals = localDeniedApprovals + providerExecutedDeniedApprovals + validated.deniedToolApprovals
    let deniedResults = deniedApprovals.map { approval in
        let toolCall = approval.toolCall
        let providerExecuted = toolCall.providerExecuted || approval.approvalResponse.providerExecuted
        let providerMetadata = toolCall.providerMetadata
            .merging(approval.approvalResponse.providerMetadata) { current, _ in current }
        return AIToolResult(
            toolCallID: toolCall.id,
            toolName: toolCall.name,
            result: executionDeniedResult(reason: approval.approvalResponse.reason),
            dynamic: toolCall.dynamic || (toolsByName[toolCall.name]?.dynamic == true),
            providerExecuted: providerExecuted,
            providerMetadata: providerMetadata
        )
    }
    let invalidResults = validated.invalidToolApprovals.map { invalid in
        let toolCall = invalid.approval.toolCall
        return toolCallErrorResult(
            invalid.error,
            toolCall: toolCall,
            dynamic: toolCall.dynamic || (toolsByName[toolCall.name]?.dynamic == true)
        )
    }
    let toolResults = approvedBatch.results + invalidResults + deniedResults

    return AIHistoricalToolApprovalExecution(
        responseMessages: toolResponseMessages(
            approvalResponses: [],
            toolResults: toolResults
        ),
        toolResults: toolResults,
        approvalResponses: []
    )
}

public func executionDeniedResult(reason: String?) -> JSONValue {
    .object([
        "type": .string("execution-denied"),
        "reason": reason.map(JSONValue.string)
    ].compactMapValues { $0 })
}

func toolExecutionErrorResult(_ error: Error, toolCall: AIToolCall, dynamic: Bool) -> AIToolResult {
    AIToolResult(
        toolCallID: toolCall.id,
        toolName: toolCall.name,
        result: [
            "type": .string("error-text"),
            "value": .string("Error: \(String(describing: error))")
        ],
        isError: true,
        dynamic: dynamic,
        providerMetadata: toolCall.providerMetadata
    )
}

func toolCallErrorResult(_ error: Error, toolCall: AIToolCall, dynamic: Bool) -> AIToolResult {
    AIToolResult(
        toolCallID: toolCall.id,
        toolName: toolCall.name,
        result: [
            "type": .string("error-text"),
            "value": .string(String(describing: error))
        ],
        isError: true,
        dynamic: dynamic,
        providerMetadata: toolCall.providerMetadata
    )
}

func isToolCallResultError(_ error: Error) -> Bool {
    error is AIInvalidToolInputError || error is AINoSuchToolError || error is AIToolCallRepairError
}

func toolArguments(from call: AIToolCall) throws -> JSONValue {
    let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .object([:]) }
    do {
        return try decodeJSONBody(Data(trimmed.utf8))
    } catch {
        throw AIInvalidToolInputError(
            toolName: call.name,
            toolCallID: call.id,
            message: "Tool call arguments must be valid JSON."
        )
    }
}

func validateToolArguments(_ arguments: JSONValue, schema: JSONValue, call: AIToolCall) throws {
    do {
        try AIJSONSchemaValidator.validate(arguments, schema: schema)
    } catch let issue as AIJSONSchemaValidationIssue {
        throw AIInvalidToolInputError(
            toolName: call.name,
            toolCallID: call.id,
            input: arguments,
            message: "Tool call arguments do not match tool schema: \(issue.description)",
            validationError: issue
        )
    }
}

struct AIPreparedToolSet: Sendable {
    var executionTools: [AITool]
    var modelTools: [AITool]
    var callerMessages: [AIMessage]
}

actor AIToolDiscoveryState {
    private var discovered: Set<String> = []

    func prepare(
        tools: [AITool],
        routing: AIToolCallerRouting
    ) throws -> AIPreparedToolSet {
        let allTools = try toolsByName(from: tools)
        try validateRouting(routing, tools: allTools)
        try validateDeferredTools(tools, routing: routing, allTools: allTools)

        var activeTools = tools.filter { !$0.deferLoading || discovered.contains($0.name) }
        for index in activeTools.indices where activeTools[index].toolSearchMarker {
            let searchName = activeTools[index].name
            let searchFunction = activeTools[index].toolSearchFunction
            let maxResults = activeTools[index].toolSearchMaxResults
            let search: @Sendable (JSONValue) async throws -> JSONValue = { [self] input in
                try await self.search(
                    input: input,
                    searchName: searchName,
                    customSearch: searchFunction,
                    maxResults: maxResults,
                    tools: tools,
                    routing: routing
                )
            }
            activeTools[index].execute = search
            activeTools[index].executeWithContext = { input, _ in try await search(input) }
        }

        var execution = try toolsByName(from: activeTools)
        var model = execution
        var localToolsByCaller: [String: [String: AITool]] = [:]
        var callerMessages: [AIMessage] = []

        for (toolName, callerNames) in routing {
            guard var tool = execution[toolName] else { continue }
            var availableDirectly = false
            var availableToProvider = false

            for callerName in callerNames {
                if callerName == AIDirectToolCallerName {
                    availableDirectly = true
                    continue
                }
                guard let caller = execution[callerName]?.toolCaller else { continue }
                switch caller {
                case .provider(let prepareProviderOptions):
                    availableToProvider = true
                    tool.providerOptions = prepareProviderOptions(tool.providerOptions)
                case .local:
                    localToolsByCaller[callerName, default: [:]][toolName] = tool
                }
            }

            execution[toolName] = tool
            if availableDirectly || availableToProvider {
                model[toolName] = tool
            } else {
                model[toolName] = nil
            }
        }

        for callerTool in activeTools {
            guard case let .local(bind, prepareModelMessage)? = callerTool.toolCaller else {
                continue
            }
            let callerTools = localToolsByCaller[callerTool.name] ?? [:]
            let boundCaller = bind(callerTools)
            execution[callerTool.name] = boundCaller
            guard model[callerTool.name] != nil else { continue }
            if let prepareModelMessage {
                if let content = prepareModelMessage(callerTools) {
                    callerMessages.append(.user(content))
                }
            } else {
                model[callerTool.name] = boundCaller
            }
        }

        return AIPreparedToolSet(
            executionTools: activeTools.compactMap { execution[$0.name] },
            modelTools: activeTools.compactMap { model[$0.name] },
            callerMessages: callerMessages
        )
    }

    private func search(
        input: JSONValue,
        searchName: String,
        customSearch: AIToolSearchFunction?,
        maxResults: Int,
        tools: [AITool],
        routing: AIToolCallerRouting
    ) async throws -> JSONValue {
        guard let query = input["query"]?.stringValue else {
            throw AIInvalidToolInputError(
                toolName: searchName,
                message: "Tool search query must be a non-empty string."
            )
        }

        let searchCallers = callers(for: searchName, routing: routing)
        let candidates = tools.filter { candidate in
            candidate.deferLoading && !candidate.toolSearchMarker &&
                !Set(callers(for: candidate.name, routing: routing)).isDisjoint(with: searchCallers)
        }
        let available = candidates.map { AIToolSearchCandidate(name: $0.name, description: $0.description) }
        let rankedNames: [String]
        if let customSearch {
            rankedNames = try await customSearch(query, available)
        } else {
            let terms = Set(toolSearchTokens(query))
            rankedNames = candidates.enumerated().compactMap { index, candidate -> (name: String, score: Int, index: Int)? in
                let nameTerms = Set(toolSearchTokens(candidate.name))
                let descriptionTerms = Set(toolSearchTokens(candidate.description ?? ""))
                let score = terms.reduce(0) { $0 + (nameTerms.contains($1) ? 2 : 0) + (descriptionTerms.contains($1) ? 1 : 0) }
                return score > 0 ? (candidate.name, score, index) : nil
            }.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }.map(\.name)
        }
        let registry = Dictionary(uniqueKeysWithValues: available.map { ($0.name, $0) })
        var seen: Set<String> = []
        let matches = rankedNames.compactMap { name -> AIToolSearchCandidate? in
            guard seen.insert(name).inserted else { return nil }
            return registry[name]
        }.prefix(maxResults)
        for match in matches { discovered.insert(match.name) }
        return .object(["tools": .array(matches.map { match in
            .object(["name": .string(match.name), "description": match.description.map(JSONValue.string)].compactMapValues { $0 })
        })])
    }

    private func validateRouting(
        _ routing: AIToolCallerRouting,
        tools: [String: AITool]
    ) throws {
        for (toolName, callers) in routing {
            guard tools[toolName] != nil else {
                throw AIError.invalidArgument(
                    argument: "toolCallers",
                    message: "Unknown tool '\(toolName)'."
                )
            }
            for caller in callers where caller != AIDirectToolCallerName {
                guard tools[caller]?.toolCaller != nil else {
                    throw AIError.invalidArgument(
                        argument: "toolCallers",
                        message: "Tool '\(toolName)' contains invalid caller '\(caller)'."
                    )
                }
            }
        }
    }

    private func validateDeferredTools(
        _ tools: [AITool],
        routing: AIToolCallerRouting,
        allTools: [String: AITool]
    ) throws {
        for tool in tools where tool.deferLoading || tool.toolSearchMarker {
            let toolCallers = callers(for: tool.name, routing: routing)
            let invalidCaller = toolCallers.contains { callerName in
                guard callerName != AIDirectToolCallerName else { return false }
                guard let definition = allTools[callerName]?.toolCaller else { return true }
                guard case let .local(_, prepareModelMessage) = definition else { return true }
                return prepareModelMessage == nil
            }
            if invalidCaller || (tool.toolSearchMarker && tool.deferLoading) {
                throw AIError.invalidArgument(
                    argument: "executableTools",
                    message: "Tool '\(tool.name)' must be callable directly or through a local caller with a model message; the search tool itself must not defer loading."
                )
            }
        }
    }

    private func callers(
        for toolName: String,
        routing: AIToolCallerRouting
    ) -> Set<String> {
        Set(routing[toolName] ?? [AIDirectToolCallerName])
    }
}

func appendToolCallerMessages(
    _ messages: [AIMessage],
    additions: [AIMessage]
) -> [AIMessage] {
    guard !additions.isEmpty else { return messages }

    let latestUserText = messages.reversed().first(where: { message in
        message.role == .user
            && message.content.count == 1
            && message.content[0].text != nil
    })?.content[0].text
    var existingUserText = Set(latestUserText.map { [$0] } ?? [])
    var appended: [AIMessage] = []

    for addition in additions {
        guard addition.role == .user,
              addition.content.count == 1,
              let content = addition.content[0].text,
              !existingUserText.contains(content) else {
            continue
        }
        existingUserText.insert(content)
        appended.append(addition)
    }

    return appended.isEmpty ? messages : messages + appended
}

private func toolSearchTokens(_ value: String) -> [String] {
    let separated = value.replacingOccurrences(
        of: #"([\p{Ll}\d])([\p{Lu}])"#,
        with: "$1 $2",
        options: .regularExpression
    )
    return separated.lowercased().components(
        separatedBy: CharacterSet.alphanumerics.inverted
    ).filter { !$0.isEmpty }
}