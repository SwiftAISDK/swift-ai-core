import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension AI {
    public static func generateText(
        model: any LanguageModel,
        request: LanguageModelRequest,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        includeResponseBody: Bool = false,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil
    ) async throws -> TextGenerationResult {
        if let experimentalSteering {
            return try await generateText(model: model, request: request, executableTools: [], maxSteps: 1, toolCallers: [:], retryPolicy: retryPolicy, telemetry: telemetry, includeResponseBody: includeResponseBody, experimentalSteering: experimentalSteering, onStepError: onStepError)
        }
        let request = try await downloadUnsupportedPromptAssets(
            in: prepareLanguageModelCallOptions(request),
            supportedURLs: model.supportedURLs
        )
        let result = try await withTelemetry(
            operationID: "ai.generateText",
            providerID: model.providerID,
            modelID: model.modelID,
            input: languageRequestTelemetryInput(request),
            telemetry: telemetry,
            retryPolicy: retryPolicy,
            abortSignal: request.abortSignal,
            output: textGenerationTelemetryOutput,
            usage: { $0.usage },
            warnings: { $0.warnings },
            providerMetadata: { $0.providerMetadata },
            responseMetadata: { $0.responseMetadata },
            wrapLanguageModelCall: true,
            stepError: { error in
                try? await onStepError?(AIGenerateTextStepErrorEvent(stepNumber: 0, providerID: model.providerID, modelID: model.modelID, request: request, error: error))
            }
        ) {
            var result = try await model.generate(request)
            result.requestMetadata = sanitizedRequestMetadata(result.requestMetadata)
            result = try await materializeGeneratedFiles(
                in: result,
                abortSignal: request.abortSignal
            )
            if result.responseMetadata.modelID == nil {
                result.responseMetadata.modelID = model.modelID
            }
            result.responseMetadata = result.responseMetadata.includingBody(includeResponseBody)
            if result.requestMetadata == AIRequestMetadata() {
                result.requestMetadata = AIRequestMetadata(body: languageRequestMetadataBody(request), headers: request.headers)
            }
            try await result.ensureResponseMessages()
            if result.steps.isEmpty {
                result.steps = [
                    AIToolStep(
                        index: 0,
                        providerID: model.providerID,
                        modelID: model.modelID,
                        content: result.content,
                        text: result.text,
                        reasoning: result.reasoning,
                        finishReason: result.finishReason,
                        usage: result.usage,
                        files: result.files,
                        toolCalls: result.toolCalls,
                        toolResults: result.toolResults,
                        toolApprovalRequests: result.toolApprovalRequests,
                        toolApprovalResponses: result.toolApprovalResponses,
                        sources: result.sources,
                        warnings: result.warnings,
                        providerMetadata: result.providerMetadata,
                        responseMetadata: result.responseMetadata.includingBody(includeResponseBody)
                    )
                ]
            }
            return result
        }
        try validateEnforcedToolChoice(
            request.toolChoice,
            result: result,
            providerID: model.providerID,
            modelID: model.modelID
        )
        return result
    }

    public static func generateText(
        model: any LanguageModel,
        request: LanguageModelRequest,
        executableTools: [AITool],
        maxSteps: Int = 5,
        toolCallers: AIToolCallerRouting = [:],
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        toolApprovalSecret: String? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        includeResponseBody: Bool = false,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil
    ) async throws -> TextGenerationResult {
        guard !executableTools.isEmpty || prepareStep != nil || experimentalSteering != nil else {
            return try await generateText(
                model: model,
                request: request,
                retryPolicy: retryPolicy,
                telemetry: telemetry,
                includeResponseBody: includeResponseBody,
                onStepError: onStepError
            )
        }
        try experimentalSteering?.start()
        var steeringEndReason: AISteeringNotDeliveredReason = .error
        defer { experimentalSteering?.end(request.abortSignal?.isAborted == true || Task.isCancelled ? .aborted : steeringEndReason) }
        do {
        guard maxSteps > 0 else {
            throw AIError.invalidArgument(argument: "maxSteps", message: "maxSteps must be greater than zero.")
        }

        let initialRequest = request
        var currentRequest = initialRequest

        var steps: [AIToolStep] = []
        var allToolResults: [AIToolResult] = []
        var allApprovalRequests: [AIToolApprovalRequest] = []
        var allApprovalResponses: [AIToolApprovalResponse] = []
        var allContent: [AIResultContentPart] = []
        var allWarnings: [AIWarning] = []
        var totalUsage: TokenUsage?
        var responseMessages: [AIMessage] = []
        var lastResult: TextGenerationResult?
        let toolTelemetry = AIToolLoopTelemetryContext(
            operationID: "ai.generateText",
            providerID: model.providerID,
            modelID: model.modelID,
            telemetry: telemetry
        )

        let toolDiscovery = AIToolDiscoveryState()
        for index in 0..<maxSteps {
            if index > 0 {
                try initialRequest.abortSignal?.throwIfAborted()
            }
            let historicalApprovalExecution = try await executeHistoricalToolApprovals(
                request: currentRequest,
                toolsByName: try toolsByName(from: executableTools),
                toolApproval: toolApproval,
                toolApprovalSecret: toolApprovalSecret,
                telemetry: toolTelemetry,
                stepIndex: index
            )
            if !historicalApprovalExecution.responseMessages.isEmpty {
                responseMessages.append(contentsOf: historicalApprovalExecution.responseMessages)
                currentRequest.messages.append(contentsOf: historicalApprovalExecution.responseMessages)
                allToolResults.append(contentsOf: historicalApprovalExecution.toolResults)
                allApprovalResponses.append(contentsOf: historicalApprovalExecution.approvalResponses)
            }

            let steeringMessages = experimentalSteering?.takeMessages() ?? []
            currentRequest.messages.append(contentsOf: steeringMessages)
            var stepContext = AIPrepareStepContext(
                model: model,
                stepNumber: index,
                steps: steps,
                request: currentRequest,
                initialRequest: initialRequest,
                responseMessages: responseMessages
            )
            stepContext.experimentalSteeringMessages = steeringMessages
            let prepared = try await prepareStep?(stepContext)
            let stepModel = prepared?.model ?? model
            let stepTools = prepared?.executableTools ?? executableTools
            let preparedTools = try await toolDiscovery.prepare(tools: stepTools, routing: toolCallers)
            let executionTools = preparedTools.executionTools
            var modelToolsByName = try toolsByName(from: preparedTools.modelTools)
            let directExecutionTools = executionTools.filter {
                modelToolsByName[$0.name] != nil
            }
            let executionToolsByName = try toolsByName(from: directExecutionTools)
            var stepRequest = prepared?.request ?? currentRequest
            if stepRequest.abortSignal !== initialRequest.abortSignal {
                stepRequest.abortSignal = mergeAbortSignals(stepRequest.abortSignal, initialRequest.abortSignal)
            }
            stepRequest.toolCallConcurrency = stepRequest.toolCallConcurrency ?? initialRequest.toolCallConcurrency
            stepRequest.messages = appendToolCallerMessages(
                stepRequest.messages,
                additions: preparedTools.callerMessages
            )
            if prepared?.executableTools != nil {
                stepRequest.tools = toolsDictionary(from: preparedTools.modelTools)
            } else {
                stepRequest.tools.merge(toolsDictionary(from: preparedTools.modelTools)) { _, typed in typed }
            }

            let schemaOnlyToolNames: Set<String> = experimentalSteering == nil ? [] : Set(stepRequest.tools.keys).subtracting(executionToolsByName.keys)
            if experimentalSteering != nil {
                modelToolsByName = modelValidationTools(stepRequest.tools, explicit: modelToolsByName)
            }
            await toolTelemetry.recordStepStart(
                index: index,
                maxSteps: maxSteps,
                model: stepModel,
                request: stepRequest,
                tools: executionTools
            )
            let deliveredSteeringMessages = experimentalSteering?.resolveTakenMessages(stepNumber: index, sentMessages: stepRequest.messages) ?? []
            let previousSteps = steps
            var result = try await AITelemetryStepContext.$stepNumber.withValue(index) {
                try await generateText(
                model: stepModel,
                request: stepRequest,
                retryPolicy: retryPolicy,
                telemetry: telemetry,
                includeResponseBody: includeResponseBody,
                onStepError: { event in
                    var event = event
                    event.stepNumber = index
                    event.steps = previousSteps
                    try? await onStepError?(event)
                }
                )
            }
            allWarnings.append(contentsOf: result.warnings)
            totalUsage = sumTokenUsage(totalUsage, result.usage)
            var forwardedCalls: [AIToolCall] = []
            var preExecutionToolResults: [AIToolResult] = []
            var preExecutionToolResultIDs = Set<String>()
            for call in result.toolCalls {
                do {
                    let forwarded = try await forwardedToolCall(
                        call,
                        toolsByName: modelToolsByName,
                        repairToolCall: repairToolCall,
                        request: stepRequest
                    )
                    forwardedCalls.append(forwarded.call)
                } catch {
                    guard isToolCallResultError(error) else { throw error }
                    let annotatedCall = annotateToolCalls([call], toolsByName: executionToolsByName)[0]
                    forwardedCalls.append(annotatedCall)
                    if !annotatedCall.providerExecuted {
                        await toolTelemetry.recordToolError(stepIndex: index, call: call, error: error)
                        preExecutionToolResults.append(toolCallErrorResult(
                            error,
                            toolCall: annotatedCall,
                            dynamic: annotatedCall.dynamic || (executionToolsByName[annotatedCall.name]?.dynamic == true)
                        ))
                        preExecutionToolResultIDs.insert(annotatedCall.id)
                    }
                }
            }
            result.toolCalls = forwardedCalls
            result.replaceToolCallContent(with: forwardedCalls)
            let executableCalls = result.toolCalls.filter { !$0.providerExecuted && !preExecutionToolResultIDs.contains($0.id) && !schemaOnlyToolNames.contains($0.name) }
            let unresolvedCalls = result.toolCalls.filter { !$0.providerExecuted && !preExecutionToolResultIDs.contains($0.id) && schemaOnlyToolNames.contains($0.name) }
            if !preExecutionToolResults.isEmpty {
                allToolResults.append(contentsOf: preExecutionToolResults)
                result.appendGeneratedToolContent(
                    approvalRequests: [],
                    approvalResponses: [],
                    toolResults: preExecutionToolResults
                )
            }

            if executableCalls.isEmpty || !isAutomaticToolExecutionAllowed(finishReason: result.finishReason) {
                let finalContent = allContent + result.content
                let finalResponseMessages = responseMessages + (try await makeResponseMessages(from: result.content))
                var finalStep = AIToolStep(
                    index: index,
                    providerID: stepModel.providerID,
                    modelID: stepModel.modelID,
                    content: result.content,
                    text: result.text,
                    reasoning: result.reasoning,
                    finishReason: result.finishReason,
                    usage: result.usage,
                    files: result.files,
                    toolCalls: result.toolCalls,
                    toolResults: result.toolResults,
                    toolApprovalRequests: result.toolApprovalRequests,
                    toolApprovalResponses: result.toolApprovalResponses,
                    sources: result.sources,
                    warnings: result.warnings,
                    providerMetadata: result.providerMetadata,
                    responseMetadata: result.responseMetadata.includingBody(includeResponseBody)
                )
                finalStep.requestMetadata = result.requestMetadata
                finalStep.experimentalSteeringMessages = deliveredSteeringMessages.map(\.message)
                let finalText = result.text
                result.toolResults = allToolResults
                result.toolApprovalRequests = allApprovalRequests
                result.toolApprovalResponses = allApprovalResponses
                result.content = finalContent
                result.refreshDerivedContent()
                if experimentalSteering != nil { result.text = finalText }
                result.usage = totalUsage
                result.warnings = allWarnings
                result.responseMessages = finalResponseMessages
                result.steps = steps + [finalStep]
                await toolTelemetry.recordStepEnd(finalStep)
                let isTruncated = result.finishReason == "length" || result.finishReason == "content-filter"
                let steeringWaiting = experimentalSteering?.hasPendingMessages == true || (!isTruncated && experimentalSteering?.promoteQueuedMessage() == true)
                let canContinueWithSteering = steeringWaiting
                    && unresolvedCalls.isEmpty && executableCalls.isEmpty
                    && result.finishReason != "interrupted" && result.finishReason != "error"
                let stopped = canContinueWithSteering ? try await isStopConditionMet(stopWhen, steps: result.steps) : false
                if canContinueWithSteering, !stopped, index < maxSteps - 1 {
                    steps.append(finalStep)
                    allContent = finalContent
                    responseMessages = finalResponseMessages
                    currentRequest = stepRequest
                    currentRequest.messages.append(contentsOf: try await makeResponseMessages(from: finalStep.content))
                    lastResult = result
                    continue
                }
                steeringEndReason = steeringCompletionReason(
                    finishReason: result.finishReason,
                    waitingForToolResults: !unresolvedCalls.isEmpty || !executableCalls.isEmpty,
                    stopped: stopped,
                    reachedStepLimit: experimentalSteering?.hasUndeliveredMessages == true && index == maxSteps - 1
                )
                return result
            }

            let toolExecution = try await executeToolCalls(
                executableCalls,
                toolsByName: executionToolsByName,
                request: stepRequest,
                toolApproval: toolApproval,
                repairToolCall: repairToolCall,
                telemetry: toolTelemetry,
                stepIndex: index,
                convertToolErrorsToResults: true
            )
            allApprovalRequests.append(contentsOf: toolExecution.approvalRequests)
            allApprovalResponses.append(contentsOf: toolExecution.approvalResponses)
            allToolResults.append(contentsOf: toolExecution.results)
            let stepToolResults = preExecutionToolResults + toolExecution.results
            result.appendGeneratedToolContent(
                approvalRequests: toolExecution.approvalRequests,
                approvalResponses: toolExecution.approvalResponses,
                toolResults: toolExecution.results
            )
            let stepResponseMessages = try await makeResponseMessages(from: result.content)
            allContent.append(contentsOf: result.content)
            var step = AIToolStep(
                index: index,
                providerID: stepModel.providerID,
                modelID: stepModel.modelID,
                content: result.content,
                text: result.text,
                reasoning: result.reasoning,
                finishReason: result.finishReason,
                usage: result.usage,
                files: result.files,
                toolCalls: result.toolCalls,
                toolResults: stepToolResults,
                toolApprovalRequests: toolExecution.approvalRequests,
                toolApprovalResponses: toolExecution.approvalResponses,
                sources: result.sources,
                warnings: result.warnings,
                providerMetadata: result.providerMetadata,
                responseMetadata: result.responseMetadata.includingBody(includeResponseBody)
            )
            step.requestMetadata = result.requestMetadata
            step.experimentalSteeringMessages = deliveredSteeringMessages.map(\.message)
            steps.append(step)
            await toolTelemetry.recordStepEnd(step)

            result.toolResults = allToolResults
            result.toolApprovalRequests = allApprovalRequests
            result.toolApprovalResponses = allApprovalResponses
            let finalText = result.text
            result.content = allContent
            result.refreshDerivedContent()
            if experimentalSteering != nil { result.text = finalText }
            result.usage = totalUsage
            result.warnings = allWarnings
            result.responseMessages = responseMessages + stepResponseMessages
            result.steps = steps
            lastResult = result
            if toolExecution.needsUserApproval || !unresolvedCalls.isEmpty || toolExecution.results.count < executableCalls.count {
                steeringEndReason = .waitingForToolResults
                return result
            }
            if try await isStopConditionMet(stopWhen, steps: steps) {
                steeringEndReason = .stopCondition
                return result
            }
            responseMessages.append(contentsOf: stepResponseMessages)
            currentRequest = stepRequest
            currentRequest.messages.append(contentsOf: stepResponseMessages)
        }

        steeringEndReason = experimentalSteering?.hasPendingMessages == true ? .stopCondition : .finished
        guard var result = lastResult else {
            return try await generateText(model: model, request: currentRequest, retryPolicy: retryPolicy, telemetry: telemetry)
        }
        result.toolResults = allToolResults
        result.toolApprovalRequests = allApprovalRequests
        result.toolApprovalResponses = allApprovalResponses
        let finalText = result.text
        result.content = allContent
        result.refreshDerivedContent()
        if experimentalSteering != nil { result.text = finalText }
        result.usage = totalUsage
        result.warnings = allWarnings
        result.responseMessages = responseMessages
        result.steps = steps
        return result
        } catch {
            if isCausedByAbort(error) { experimentalSteering?.end(.aborted) }
            throw error
        }
    }

    public static func generateText(
        model: any LanguageModel,
        prompt: String,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        responseFormat: AIResponseFormat? = nil,
        reasoning: String? = nil,
        tools: [String: JSONValue] = [:],
        executableTools: [AITool] = [],
        maxSteps: Int = 5,
        toolCallers: AIToolCallerRouting = [:],
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        toolApprovalSecret: String? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        retryPolicy: AIRetryPolicy = .default,
        toolChoice: JSONValue? = nil,
        includeRawChunks: Bool = false,
        includeResponseBody: Bool = false,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        telemetry: Telemetry.Options? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil
    ) async throws -> TextGenerationResult {
        let request = LanguageModelRequest(
            messages: [.user(prompt)],
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed,
            maxOutputTokens: maxOutputTokens,
            stopSequences: stopSequences,
            responseFormat: responseFormat,
            reasoning: reasoning,
            tools: tools,
            toolChoice: toolChoice,
            includeRawChunks: includeRawChunks,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal
        )

        if executableTools.isEmpty && prepareStep == nil && experimentalSteering == nil {
            return try await generateText(
                model: model,
                request: request,
                retryPolicy: retryPolicy,
                telemetry: telemetry,
                includeResponseBody: includeResponseBody,
                onStepError: onStepError
            )
        }

        return try await generateText(
            model: model,
            request: request,
            executableTools: executableTools,
            maxSteps: maxSteps,
            toolCallers: toolCallers,
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            toolApprovalSecret: toolApprovalSecret,
            repairToolCall: repairToolCall,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            includeResponseBody: includeResponseBody,
            experimentalSteering: experimentalSteering,
            onStepError: onStepError
        )
    }

    public static func generateText<FinalOutput: Sendable, PartialOutput: Sendable>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        output: AIOutput<FinalOutput, PartialOutput>,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil
    ) async throws -> AIOutputGenerationResult<FinalOutput> {
        if experimentalSteering != nil || onStepError != nil {
            let text = try await generateText(model: model, request: output.requestForOutput(request, jsonInstruction), retryPolicy: retryPolicy, telemetry: telemetry, experimentalSteering: experimentalSteering, onStepError: onStepError)
            let result = try await output.optionalResultFromTextResult(text, model.providerID, repairText)
            guard let value = result.output else {
                throw AIError.invalidResponse(provider: model.providerID, message: "No output generated.")
            }
            return AIOutputGenerationResult(output: value, text: result.text, rawOutput: result.rawOutput, reasoning: result.reasoning, finishReason: result.finishReason, usage: result.usage, warnings: result.warnings, providerMetadata: result.providerMetadata, responseMetadata: result.responseMetadata, textResult: result.textResult)
        }
        return try await AIDeprecationLogging.$suppressObjectWarnings.withValue(true) {
            try await output.generateFromRequest(
                model,
                request,
                retryPolicy,
                telemetry,
                jsonInstruction,
                repairText
            )
        }
    }

    public static func generateText<FinalOutput: Sendable, PartialOutput: Sendable>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        output: AIOutput<FinalOutput, PartialOutput>,
        executableTools: [AITool],
        maxSteps: Int = 5,
        toolCallers: AIToolCallerRouting = [:],
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        toolApprovalSecret: String? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil
    ) async throws -> AIOutputGenerationResult<FinalOutput?> {
        let outputRequest = output.requestForOutput(request, jsonInstruction)
        let textResult = try await generateText(
            model: model,
            request: outputRequest,
            executableTools: executableTools,
            maxSteps: maxSteps,
            toolCallers: toolCallers,
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            toolApprovalSecret: toolApprovalSecret,
            repairToolCall: repairToolCall,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            experimentalSteering: experimentalSteering,
            onStepError: onStepError
        )
        let finalStepResult = structuredOutputTextResult(textResult)
        return try await output.optionalResultFromTextResult(
            finalStepResult,
            textResult.finalStep?.providerID ?? model.providerID,
            repairText
        )
    }

    public static func generateText<FinalOutput: Sendable, PartialOutput: Sendable>(
        model: any LanguageModel,
        prompt: String,
        output: AIOutput<FinalOutput, PartialOutput>,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        reasoning: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil
    ) async throws -> AIOutputGenerationResult<FinalOutput> {
        try await generateText(
            model: model,
            request: LanguageModelRequest(
                messages: [.user(prompt)],
                temperature: temperature,
                topP: topP,
                topK: topK,
                presencePenalty: presencePenalty,
                frequencyPenalty: frequencyPenalty,
                seed: seed,
                maxOutputTokens: maxOutputTokens,
                stopSequences: stopSequences,
                reasoning: reasoning,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers,
                abortSignal: abortSignal
            ),
            output: output,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            jsonInstruction: jsonInstruction,
            repairText: repairText,
            experimentalSteering: experimentalSteering,
            onStepError: onStepError
        )
    }

    public static func generateText<FinalOutput: Sendable, PartialOutput: Sendable>(
        model: any LanguageModel,
        prompt: String,
        output: AIOutput<FinalOutput, PartialOutput>,
        executableTools: [AITool],
        maxSteps: Int = 5,
        toolCallers: AIToolCallerRouting = [:],
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        toolApprovalSecret: String? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        reasoning: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil
    ) async throws -> AIOutputGenerationResult<FinalOutput?> {
        try await generateText(
            model: model,
            request: LanguageModelRequest(
                messages: [.user(prompt)],
                temperature: temperature,
                topP: topP,
                topK: topK,
                presencePenalty: presencePenalty,
                frequencyPenalty: frequencyPenalty,
                seed: seed,
                maxOutputTokens: maxOutputTokens,
                stopSequences: stopSequences,
                reasoning: reasoning,
                providerOptions: providerOptions,
                extraBody: extraBody,
                headers: headers,
                abortSignal: abortSignal
            ),
            output: output,
            executableTools: executableTools,
            maxSteps: maxSteps,
            toolCallers: toolCallers,
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            toolApprovalSecret: toolApprovalSecret,
            repairToolCall: repairToolCall,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            jsonInstruction: jsonInstruction,
            repairText: repairText,
            experimentalSteering: experimentalSteering,
            onStepError: onStepError
        )
    }
}


// Source-compatible overloads preserve the public signatures released in 1.7.0.
extension AI {
    public static func generateText(
        model: any LanguageModel,
        request: LanguageModelRequest,
        executableTools: [AITool],
        maxSteps: Int = 5,
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        toolApprovalSecret: String? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        includeResponseBody: Bool = false
    ) async throws -> TextGenerationResult {
        try await generateText(
            model: model,
            request: request,
            executableTools: executableTools,
            maxSteps: maxSteps,
            toolCallers: [:],
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            toolApprovalSecret: toolApprovalSecret,
            repairToolCall: repairToolCall,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            includeResponseBody: includeResponseBody
        )
    }

    public static func generateText(
        model: any LanguageModel,
        prompt: String,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        responseFormat: AIResponseFormat? = nil,
        reasoning: String? = nil,
        tools: [String: JSONValue] = [:],
        executableTools: [AITool] = [],
        maxSteps: Int = 5,
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        toolApprovalSecret: String? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        retryPolicy: AIRetryPolicy = .default,
        toolChoice: JSONValue? = nil,
        includeRawChunks: Bool = false,
        includeResponseBody: Bool = false,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        telemetry: Telemetry.Options? = nil
    ) async throws -> TextGenerationResult {
        try await generateText(
            model: model,
            prompt: prompt,
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed,
            maxOutputTokens: maxOutputTokens,
            stopSequences: stopSequences,
            responseFormat: responseFormat,
            reasoning: reasoning,
            tools: tools,
            executableTools: executableTools,
            maxSteps: maxSteps,
            toolCallers: [:],
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            toolApprovalSecret: toolApprovalSecret,
            repairToolCall: repairToolCall,
            retryPolicy: retryPolicy,
            toolChoice: toolChoice,
            includeRawChunks: includeRawChunks,
            includeResponseBody: includeResponseBody,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            telemetry: telemetry
        )
    }

    public static func generateText<FinalOutput: Sendable, PartialOutput: Sendable>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        output: AIOutput<FinalOutput, PartialOutput>,
        executableTools: [AITool],
        maxSteps: Int = 5,
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        toolApprovalSecret: String? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> AIOutputGenerationResult<FinalOutput?> {
        try await generateText(
            model: model,
            request: request,
            output: output,
            executableTools: executableTools,
            maxSteps: maxSteps,
            toolCallers: [:],
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            toolApprovalSecret: toolApprovalSecret,
            repairToolCall: repairToolCall,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }

    public static func generateText<FinalOutput: Sendable, PartialOutput: Sendable>(
        model: any LanguageModel,
        prompt: String,
        output: AIOutput<FinalOutput, PartialOutput>,
        executableTools: [AITool],
        maxSteps: Int = 5,
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        toolApprovalSecret: String? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        seed: Int? = nil,
        maxOutputTokens: Int? = nil,
        stopSequences: [String] = [],
        reasoning: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) async throws -> AIOutputGenerationResult<FinalOutput?> {
        try await generateText(
            model: model,
            prompt: prompt,
            output: output,
            executableTools: executableTools,
            maxSteps: maxSteps,
            toolCallers: [:],
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            toolApprovalSecret: toolApprovalSecret,
            repairToolCall: repairToolCall,
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed,
            maxOutputTokens: maxOutputTokens,
            stopSequences: stopSequences,
            reasoning: reasoning,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            retryPolicy: retryPolicy,
            telemetry: telemetry,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }
}


private extension AIResponseMetadata {
    func includingBody(_ includeBody: Bool) -> AIResponseMetadata {
        guard !includeBody else { return self }
        var metadata = self
        metadata.body = nil
        return metadata
    }
}
