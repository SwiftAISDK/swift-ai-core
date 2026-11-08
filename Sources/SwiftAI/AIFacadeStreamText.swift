import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension AI {
    static func streamTextParts(
        model: any LanguageModel,
        request: LanguageModelRequest,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        streamRetries: Int? = nil,
        telemetry: Telemetry.Options? = nil,
        logWarnings: Bool,
        onStepError: AIGenerateTextOnStepError? = nil,
        onError: AIGenerationOnError? = nil,
        onAbort: AIStreamTextOnAbort? = nil,
        stepNumber: Int = 0,
        reportsStepErrors: Bool = true
    ) -> AsyncThrowingStream<StreamTextTelemetryPart, Error> {
        let preparedRequest: LanguageModelRequest
        do {
            preparedRequest = try prepareLanguageModelCallOptions(request)
        } catch {
            return streamTextWithTelemetryParts(
                makeStream: { failingPartStream(error) },
                operationID: "ai.streamText",
                providerID: model.providerID,
                modelID: model.modelID,
                input: languageRequestTelemetryInput(request),
                retryPolicy: retryPolicy,
                streamRetries: streamRetries,
                telemetry: telemetry,
                abortSignal: request.abortSignal,
                logWarnings: logWarnings,
                onStepError: nil,
                onError: { error in try? await onError?(AIGenerationErrorEvent(error: error)) },
                onAbort: { error in try? await onAbort?(AIStreamTextAbortEvent(steps: [], reason: request.abortSignal?.reason ?? error.map { String(describing: $0) })) },
                reportsStepErrors: false
            )
        }
        if let timeoutNanoseconds, timeoutNanoseconds <= 0 {
            return streamTextWithTelemetryParts(
                makeStream: {
                    failingPartStream(AIError.invalidArgument(
                        argument: "timeoutNanoseconds",
                        message: "timeoutNanoseconds must be greater than zero."
                    ))
                },
                operationID: "ai.streamText",
                providerID: model.providerID,
                modelID: model.modelID,
                input: languageRequestTelemetryInput(preparedRequest),
                retryPolicy: retryPolicy,
                streamRetries: streamRetries,
                telemetry: telemetry,
                abortSignal: preparedRequest.abortSignal,
                logWarnings: logWarnings,
                onStepError: nil,
                onError: { error in try? await onError?(AIGenerationErrorEvent(error: error)) },
                onAbort: { error in try? await onAbort?(AIStreamTextAbortEvent(steps: [], reason: request.abortSignal?.reason ?? error.map { String(describing: $0) })) },
                reportsStepErrors: false
            )
        }
        if let validationError = validateStreamTimeoutConfiguration(timeout) {
            return streamTextWithTelemetryParts(
                makeStream: { failingPartStream(validationError) },
                operationID: "ai.streamText",
                providerID: model.providerID,
                modelID: model.modelID,
                input: languageRequestTelemetryInput(preparedRequest),
                retryPolicy: retryPolicy,
                streamRetries: streamRetries,
                telemetry: telemetry,
                abortSignal: preparedRequest.abortSignal,
                logWarnings: logWarnings,
                onStepError: nil,
                onError: { error in try? await onError?(AIGenerationErrorEvent(error: error)) },
                onAbort: { error in try? await onAbort?(AIStreamTextAbortEvent(steps: [], reason: request.abortSignal?.reason ?? error.map { String(describing: $0) })) },
                reportsStepErrors: false
            )
        }
        let totalTimeoutNanoseconds = minimumTimeoutNanoseconds(
            timeout?.totalNanoseconds,
            timeoutNanoseconds
        )
        let stepTimeoutNanoseconds = timeout?.stepNanoseconds
        let totalTimeoutController = totalTimeoutNanoseconds.map { _ in AIAbortController() }
        let stepTimeoutController = stepTimeoutNanoseconds.map { _ in AIAbortController() }
        let semanticTimeoutController = timeout?.firstChunkNanoseconds != nil
            || timeout?.chunkNanoseconds != nil
            ? AIAbortController()
            : nil
        var requestWithTimeoutSignals = preparedRequest
        requestWithTimeoutSignals.abortSignal = mergeAbortSignals(
            preparedRequest.abortSignal,
            totalTimeoutController?.signal,
            stepTimeoutController?.signal,
            semanticTimeoutController?.signal
        )
        let operationRequest = requestWithTimeoutSignals

        let retriedStream = streamTextWithTelemetryParts(
            makeStream: {
                let attemptTimeoutController = retryPolicy.timeoutNanoseconds.map { _ in
                    AIAbortController()
                }
                var attemptRequest = operationRequest
                attemptRequest.abortSignal = mergeAbortSignals(
                    operationRequest.abortSignal,
                    attemptTimeoutController?.signal
                )
                let downloadedRequest = try await downloadUnsupportedPromptAssets(
                    in: attemptRequest,
                    supportedURLs: model.supportedURLs
                )
                let stream = streamWithAbortSignal(
                    model.stream(downloadedRequest),
                    abortSignal: downloadedRequest.abortSignal
                )
                let canonicalStream = canonicalLanguageStream(
                    stream,
                    providerID: model.providerID
                )
                let resolvedFileStream = resolvingGeneratedFileStream(
                    canonicalStream,
                    abortSignal: downloadedRequest.abortSignal
                )
                // With `none`, raw tool parts reach timing and validation only.
                // They must not resolve approvals or invoke input callbacks.
                let forwardedStream = prepareToolChoice(downloadedRequest.toolChoice)["type"]?.stringValue == "none"
                    ? resolvedFileStream
                    : forwardedLanguageStream(resolvedFileStream, request: downloadedRequest)
                let outputTimedStream = streamWithSemanticOutputTimeouts(
                    forwardedStream,
                    firstChunkNanoseconds: timeout?.firstChunkNanoseconds,
                    chunkNanoseconds: timeout?.chunkNanoseconds,
                    abortController: semanticTimeoutController
                )
                let toolChoiceValidatedStream = validatedEnforcedToolChoiceStream(
                    outputTimedStream,
                    toolChoice: downloadedRequest.toolChoice,
                    providerID: model.providerID,
                    modelID: model.modelID
                )
                return streamWithTimeout(
                    toolChoiceValidatedStream,
                    timeoutNanoseconds: retryPolicy.timeoutNanoseconds,
                    abortController: attemptTimeoutController,
                    timeoutLabel: "Retry attempt"
                )
            },
            operationID: "ai.streamText",
            providerID: model.providerID,
            modelID: model.modelID,
            input: languageRequestTelemetryInput(operationRequest),
            retryPolicy: retryPolicy,
            streamRetries: streamRetries,
            telemetry: telemetry,
            abortSignal: operationRequest.abortSignal,
            logWarnings: logWarnings,
                onStepError: { error in
                    try? await onStepError?(AIGenerateTextStepErrorEvent(stepNumber: stepNumber, providerID: model.providerID, modelID: model.modelID, request: request, error: error))
                },
                onError: { error in try? await onError?(AIGenerationErrorEvent(error: error)) },
                onAbort: { error in try? await onAbort?(AIStreamTextAbortEvent(steps: [], reason: request.abortSignal?.reason ?? error.map { String(describing: $0) })) },
                reportsStepErrors: reportsStepErrors
        )
        let stepTimedStream = streamWithTimeout(
            retriedStream,
            timeoutNanoseconds: stepTimeoutNanoseconds,
            abortController: stepTimeoutController,
            timeoutLabel: "Step"
        )
        return streamWithTimeout(
            stepTimedStream,
            timeoutNanoseconds: totalTimeoutNanoseconds,
            abortController: totalTimeoutController,
            timeoutLabel: "Total"
        )
    }

    static func streamText(
        model: any LanguageModel,
        request: LanguageModelRequest,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        streamRetries: Int? = nil,
        telemetry: Telemetry.Options? = nil,
        logWarnings: Bool,
        onStepError: AIGenerateTextOnStepError? = nil,
        onError: AIGenerationOnError? = nil,
        onAbort: AIStreamTextOnAbort? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        validatedEnforcedToolChoiceStream(
            publicLanguageStream(
            streamTextParts(
                model: model,
                request: request,
                timeoutNanoseconds: timeoutNanoseconds,
                timeout: timeout,
                retryPolicy: retryPolicy,
                streamRetries: streamRetries,
                telemetry: telemetry,
                logWarnings: logWarnings,
                onStepError: onStepError,
                onError: onError,
                onAbort: onAbort
            )
            ),
            toolChoice: request.toolChoice,
            providerID: model.providerID,
            modelID: model.modelID
        )
    }

    public static func streamText(
        model: any LanguageModel,
        request: LanguageModelRequest,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        streamRetries: Int? = nil,
        telemetry: Telemetry.Options? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil,
        onError: AIGenerationOnError? = nil,
        onAbort: AIStreamTextOnAbort? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        if let experimentalSteering {
            return streamText(model: model, request: request, executableTools: [], maxSteps: 1, timeoutNanoseconds: timeoutNanoseconds, timeout: timeout, retryPolicy: retryPolicy, streamRetries: streamRetries, telemetry: telemetry, experimentalSteering: experimentalSteering, onStepError: onStepError, onError: onError, onAbort: onAbort)
        }
        return streamText(
            model: model,
            request: request,
            timeoutNanoseconds: timeoutNanoseconds,
            timeout: timeout,
            retryPolicy: retryPolicy,
            streamRetries: streamRetries,
            telemetry: telemetry,
            logWarnings: true,
            onStepError: onStepError,
            onError: onError,
            onAbort: onAbort
        )
    }

    public static func streamText(
        model: any LanguageModel,
        request: LanguageModelRequest,
        executableTools: [AITool],
        maxSteps: Int = 5,
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolCallers: AIToolCallerRouting = [:],
        toolApproval: AIToolApproval? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        streamRetries: Int? = nil,
        telemetry: Telemetry.Options? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil,
        onError: AIGenerationOnError? = nil,
        onAbort: AIStreamTextOnAbort? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        guard !executableTools.isEmpty || prepareStep != nil || experimentalSteering != nil else {
            return streamText(
                model: model,
                request: request,
                timeoutNanoseconds: timeoutNanoseconds,
                timeout: timeout,
                retryPolicy: retryPolicy,
                streamRetries: streamRetries,
                telemetry: telemetry,
                onStepError: onStepError,
                onError: onError,
                onAbort: onAbort
            )
        }
        if let validationError = validateStreamTimeoutConfiguration(timeout) {
            return streamTextWithTelemetry(
                makeStream: { failingPartStream(validationError) },
                operationID: "ai.streamText",
                providerID: model.providerID,
                modelID: model.modelID,
                input: languageRequestTelemetryInput(request),
                retryPolicy: .none,
                telemetry: telemetry,
                abortSignal: request.abortSignal,
                logWarnings: false
            )
        }

        let explicitTotalTimeoutNanoseconds = minimumTimeoutNanoseconds(
            timeout?.totalNanoseconds,
            timeoutNanoseconds
        )
        let totalTimeoutNanoseconds = explicitTotalTimeoutNanoseconds
            ?? retryPolicy.timeoutNanoseconds
        let totalTimeoutController = totalTimeoutNanoseconds.map { _ in AIAbortController() }
        var requestWithTimeoutSignals = request
        requestWithTimeoutSignals.abortSignal = mergeAbortSignals(
            request.abortSignal,
            totalTimeoutController?.signal
        )
        let operationRequest = requestWithTimeoutSignals

        let stepResults = AISteeringContext.streamResults ?? AISteeringStepResults()
        let stream = AsyncThrowingStream<LanguageStreamPart, Error> { continuation in
            let task = AISteeringContext.$streamResults.withValue(nil) { Task {
                var steeringEndReason: AISteeringNotDeliveredReason = .error
                var steeringStarted = false
                defer { if steeringStarted { experimentalSteering?.end(operationRequest.abortSignal?.isAborted == true || Task.isCancelled ? .aborted : steeringEndReason) } }
                do {
                    try experimentalSteering?.start()
                    steeringStarted = true
                    if let validationError = validateStreamTimeoutConfiguration(timeout) {
                        throw validationError
                    }
                    guard maxSteps > 0 else {
                        throw AIError.invalidArgument(argument: "maxSteps", message: "maxSteps must be greater than zero.")
                    }

                    let initialRequest = operationRequest
                    var currentRequest = initialRequest
                    var steps: [AIToolStep] = []
                    var responseMessages: [AIMessage] = []
                    var pendingProviderExecutedToolCallIDs: Set<String> = []
                    let partIDReserver = LanguageStreamPartIDReserver()
                    let toolTelemetry = AIToolLoopTelemetryContext(
                        operationID: "ai.streamText",
                        providerID: model.providerID,
                        modelID: model.modelID,
                        telemetry: telemetry
                    )

                    let toolDiscovery = AIToolDiscoveryState()
                    for index in 0..<maxSteps {
                        let stepDeadline = AIStreamTimeoutDeadline(
                            durationNanoseconds: timeout?.stepNanoseconds,
                            label: "Step"
                        )
                        stepDeadline.start()
                        defer { stepDeadline.cancel() }
                        do {
                        var stepCurrentRequest = currentRequest
                        stepCurrentRequest.abortSignal = mergeAbortSignals(
                            currentRequest.abortSignal,
                            stepDeadline.signal
                        )
                        let historicalApprovalExecution = try await executeHistoricalToolApprovals(
                            request: stepCurrentRequest,
                            toolsByName: try toolsByName(from: executableTools),
                            toolApproval: toolApproval,
                            telemetry: toolTelemetry,
                            stepIndex: index
                        )
                        try stepDeadline.throwIfTimedOut()
                        if !historicalApprovalExecution.responseMessages.isEmpty {
                            responseMessages.append(contentsOf: historicalApprovalExecution.responseMessages)
                            stepCurrentRequest.messages.append(contentsOf: historicalApprovalExecution.responseMessages)
                            for approvalResponse in historicalApprovalExecution.approvalResponses {
                                continuation.yield(.toolApprovalResponse(approvalResponse))
                            }
                            for toolResult in historicalApprovalExecution.toolResults {
                                continuation.yield(.toolResult(toolResult))
                            }
                        }

                        let steeringMessages = experimentalSteering?.takeMessages() ?? []
                        stepCurrentRequest.messages.append(contentsOf: steeringMessages)
                        var stepContext = AIPrepareStepContext(
                            model: model,
                            stepNumber: index,
                            steps: steps,
                            request: stepCurrentRequest,
                            initialRequest: initialRequest,
                            responseMessages: responseMessages
                        )
                        stepContext.experimentalSteeringMessages = steeringMessages
                        let prepared = try await prepareStep?(stepContext)
                        try stepDeadline.throwIfTimedOut()
                        let stepModel = prepared?.model ?? model
                        let stepTools = prepared?.executableTools ?? executableTools
                        let preparedTools = try await toolDiscovery.prepare(tools: stepTools, routing: toolCallers)
                        let executionTools = preparedTools.executionTools
                        var modelToolsByName = try toolsByName(from: preparedTools.modelTools)
                        let directExecutionTools = executionTools.filter {
                            modelToolsByName[$0.name] != nil
                        }
                        let executionToolsByName = try toolsByName(from: directExecutionTools)
                        var stepRequest = try prepareLanguageModelCallOptions(
                            prepared?.request ?? stepCurrentRequest
                        )
                        stepRequest.toolCallConcurrency = stepRequest.toolCallConcurrency ?? initialRequest.toolCallConcurrency
                        if stepRequest.abortSignal === operationRequest.abortSignal {
                            stepRequest.abortSignal = mergeAbortSignals(
                                stepRequest.abortSignal,
                                stepDeadline.signal
                            )
                        } else {
                            stepRequest.abortSignal = mergeAbortSignals(
                                stepRequest.abortSignal,
                                operationRequest.abortSignal,
                                stepDeadline.signal
                            )
                        }
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
                        try stepDeadline.throwIfTimedOut()
                        let deliveredSteeringMessages = experimentalSteering?.resolveTakenMessages(stepNumber: index, sentMessages: stepRequest.messages) ?? []
                        for delivered in deliveredSteeringMessages {
                            continuation.yield(.steeringMessage(id: delivered.id, message: delivered.message, stepNumber: index))
                        }
                        let previousSteps = steps
                        let step = try await forwardLanguageStream(
                            streamTextParts(
                                model: stepModel,
                                request: stepRequest,
                                timeout: timeout.map {
                                    AIStreamTimeoutConfiguration(
                                        firstChunkNanoseconds: $0.firstChunkNanoseconds,
                                        chunkNanoseconds: $0.chunkNanoseconds
                                    )
                                },
                                retryPolicy: retryPolicy,
                                streamRetries: streamRetries,
                                telemetry: nil,
                                logWarnings: true,
                                onStepError: { event in
                                    var event = event
                                    event.steps = previousSteps
                                    try? await onStepError?(event)
                                    await toolTelemetry.recordStepError(event)
                                },
                                stepNumber: index,
                                reportsStepErrors: false
                            ),
                            to: continuation,
                            toolsByName: modelToolsByName,
                            executionToolsByName: executionToolsByName,
                            request: stepRequest,
                            repairToolCall: repairToolCall,
                            partIDReserver: partIDReserver
                        )
                        try stepDeadline.throwIfTimedOut()
                        try operationRequest.abortSignal?.throwIfAborted()
                        try Task.checkCancellation()
                        try validateEnforcedToolChoice(
                            stepRequest.toolChoice,
                            step: step,
                            providerID: stepModel.providerID,
                            modelID: stepModel.modelID
                        )
                        let executableCalls = step.toolCalls.filter { !$0.providerExecuted && !schemaOnlyToolNames.contains($0.name) }
                        let unresolvedCalls = step.toolCalls.filter { !$0.providerExecuted && schemaOnlyToolNames.contains($0.name) }
                        let providerExecutedToolCallIDs = Set(step.toolCalls.filter(\.providerExecuted).map(\.id))
                        pendingProviderExecutedToolCallIDs.formUnion(providerExecutedToolCallIDs)
                        let providerExecutedToolResultIDs = Set(step.streamedToolResults.compactMap { result -> String? in
                            if result.providerExecuted
                                || providerExecutedToolCallIDs.contains(result.toolCallID)
                                || pendingProviderExecutedToolCallIDs.contains(result.toolCallID) {
                                return result.toolCallID
                            }
                            return nil
                        })
                        pendingProviderExecutedToolCallIDs.subtract(providerExecutedToolResultIDs)

                        if !isAutomaticToolExecutionAllowed(finishReason: step.finishReason) {
                            var completedStep = step.toolStep(
                                index: index,
                                toolResults: [],
                                approvalRequests: [],
                                approvalResponses: []
                            )
                            completedStep.providerID = stepModel.providerID
                            completedStep.modelID = stepModel.modelID
                            if completedStep.responseMetadata.modelID == nil {
                                completedStep.responseMetadata.modelID = stepModel.modelID
                            }
                            completedStep.experimentalSteeringMessages = deliveredSteeringMessages.map(\.message)
                            steps.append(completedStep)
                            stepResults.append(completedStep)
                            await toolTelemetry.recordStepEnd(completedStep)
                            try stepDeadline.throwIfTimedOut()
                            let isTruncated = step.finishReason == "length" || step.finishReason == "content-filter"
                            let steeringWaiting = experimentalSteering?.hasPendingMessages == true || (!isTruncated && experimentalSteering?.promoteQueuedMessage() == true)
                            let canContinueWithSteering = steeringWaiting
                                && step.finishReason != "interrupted" && step.finishReason != "error"
                                && executableCalls.isEmpty && unresolvedCalls.isEmpty
                            let stopped = canContinueWithSteering ? try await isStopConditionMet(stopWhen, steps: steps) : false
                            if canContinueWithSteering, !stopped, index < maxSteps - 1 {
                                let stepResponseMessages = try await toResponseMessages(content: completedStep.content.compactMap(\.responseMessagePart), toolsByName: executionToolsByName)
                                responseMessages.append(contentsOf: stepResponseMessages)
                                currentRequest = stepRequest
                                currentRequest.abortSignal = operationRequest.abortSignal
                                currentRequest.messages.append(contentsOf: stepResponseMessages)
                                continue
                            }
                            steeringEndReason = steeringCompletionReason(
                                finishReason: step.finishReason,
                                waitingForToolResults: !executableCalls.isEmpty || !unresolvedCalls.isEmpty,
                                stopped: stopped,
                                reachedStepLimit: experimentalSteering?.hasPendingMessages == true
                            )
                            continuation.finish()
                            return
                        }

                        guard !executableCalls.isEmpty else {
                            var completedStep = step.toolStep(
                                index: index,
                                toolResults: [],
                                approvalRequests: [],
                                approvalResponses: []
                            )
                            completedStep.providerID = stepModel.providerID
                            completedStep.modelID = stepModel.modelID
                            if completedStep.responseMetadata.modelID == nil {
                                completedStep.responseMetadata.modelID = stepModel.modelID
                            }
                            completedStep.experimentalSteeringMessages = deliveredSteeringMessages.map(\.message)
                            steps.append(completedStep)
                            stepResults.append(completedStep)
                            await toolTelemetry.recordStepEnd(completedStep)
                            try stepDeadline.throwIfTimedOut()
                            let isTruncated = step.finishReason == "length" || step.finishReason == "content-filter"
                            if pendingProviderExecutedToolCallIDs.isEmpty && unresolvedCalls.isEmpty && experimentalSteering?.hasPendingMessages != true && !isTruncated { _ = experimentalSteering?.promoteQueuedMessage() }
                            let canContinue = !pendingProviderExecutedToolCallIDs.isEmpty || experimentalSteering?.hasPendingMessages == true
                            if canContinue, try await isStopConditionMet(stopWhen, steps: steps) {
                                steeringEndReason = .stopCondition
                                try stepDeadline.throwIfTimedOut()
                                continuation.finish()
                                return
                            }
                            let stepResponseMessages = try await toResponseMessages(
                                content: completedStep.content.compactMap(\.responseMessagePart),
                                toolsByName: executionToolsByName
                            )
                            responseMessages.append(contentsOf: stepResponseMessages)
                            currentRequest = stepRequest
                            currentRequest.abortSignal = operationRequest.abortSignal
                            currentRequest.messages.append(contentsOf: stepResponseMessages)
                            if !unresolvedCalls.isEmpty {
                                steeringEndReason = .waitingForToolResults
                                continuation.finish()
                                return
                            }
                            let steeringPending = experimentalSteering?.hasPendingMessages == true
                            guard (!pendingProviderExecutedToolCallIDs.isEmpty || steeringPending), index < maxSteps - 1 else {
                                steeringEndReason = steeringPending ? .stopCondition : .finished
                                try stepDeadline.throwIfTimedOut()
                                continuation.finish()
                                return
                            }
                            try stepDeadline.throwIfTimedOut()
                            continue
                        }

                        let toolExecution = try await executeToolCalls(
                            executableCalls,
                            toolsByName: executionToolsByName,
                            request: stepRequest,
                            toolApproval: toolApproval,
                            repairToolCall: repairToolCall,
                            telemetry: toolTelemetry,
                            stepIndex: index,
                            convertToolErrorsToResults: true,
                            invokeInputAvailableCallbacks: false
                        )
                        try stepDeadline.throwIfTimedOut()
                        for approvalRequest in toolExecution.approvalRequests {
                            continuation.yield(.toolApprovalRequest(approvalRequest))
                        }
                        for approvalResponse in toolExecution.approvalResponses {
                            continuation.yield(.toolApprovalResponse(approvalResponse))
                        }
                        for toolResult in toolExecution.results {
                            continuation.yield(.toolResult(toolResult))
                        }

                        var completedStep = step.toolStep(
                            index: index,
                            toolResults: toolExecution.results,
                            approvalRequests: toolExecution.approvalRequests,
                            approvalResponses: toolExecution.approvalResponses
                        )
                        completedStep.providerID = stepModel.providerID
                        completedStep.modelID = stepModel.modelID
                        if completedStep.responseMetadata.modelID == nil {
                            completedStep.responseMetadata.modelID = stepModel.modelID
                        }
                        completedStep.experimentalSteeringMessages = deliveredSteeringMessages.map(\.message)
                        steps.append(completedStep)
                        stepResults.append(completedStep)
                        await toolTelemetry.recordStepEnd(completedStep)
                        try stepDeadline.throwIfTimedOut()
                        if toolExecution.needsUserApproval || !unresolvedCalls.isEmpty || toolExecution.results.count < executableCalls.count {
                            steeringEndReason = .waitingForToolResults
                            continuation.finish()
                            return
                        }
                        if try await isStopConditionMet(stopWhen, steps: steps) {
                            steeringEndReason = .stopCondition
                            try stepDeadline.throwIfTimedOut()
                            continuation.finish()
                            return
                        }
                        let stepResponseMessages = try await toResponseMessages(
                            content: completedStep.content.compactMap(\.responseMessagePart),
                            toolsByName: executionToolsByName
                        )
                        responseMessages.append(contentsOf: stepResponseMessages)
                        currentRequest = stepRequest
                        currentRequest.abortSignal = operationRequest.abortSignal
                        currentRequest.messages.append(contentsOf: stepResponseMessages)
                        try stepDeadline.throwIfTimedOut()
                        } catch {
                            if stepDeadline.hasTimedOut,
                               let durationNanoseconds = stepDeadline.durationNanoseconds {
                                throw AIError.timeout(durationNanoseconds: durationNanoseconds)
                            }
                            throw error
                        }
                    }

                    steeringEndReason = experimentalSteering?.hasPendingMessages == true ? .stopCondition : .finished
                    continuation.finish()
                } catch {
                    if isCausedByAbort(error) { steeringEndReason = .aborted }
                    continuation.finish(throwing: error)
                }
            } }

            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
        let telemeteredStream = streamTextWithTelemetry(
            makeStream: { stream },
            operationID: "ai.streamText",
            providerID: model.providerID,
            modelID: model.modelID,
            input: languageRequestTelemetryInput(operationRequest),
            retryPolicy: .none,
            telemetry: telemetry,
            abortSignal: operationRequest.abortSignal,
            logWarnings: false,
            onError: { error in try? await onError?(AIGenerationErrorEvent(error: error)) },
            onAbort: { error in try? await onAbort?(AIStreamTextAbortEvent(steps: stepResults.steps, reason: operationRequest.abortSignal?.reason ?? error.map { String(describing: $0) })) },
            reportsStepErrors: false
        )
        return streamWithTimeout(
            telemeteredStream,
            timeoutNanoseconds: totalTimeoutNanoseconds,
            abortController: totalTimeoutController,
            timeoutLabel: "Total"
        )
    }

    public static func streamText(
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
        toolCallers: AIToolCallerRouting = [:],
        toolApproval: AIToolApproval? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        toolChoice: JSONValue? = nil,
        includeRawChunks: Bool = false,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        streamRetries: Int? = nil,
        telemetry: Telemetry.Options? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil,
        onError: AIGenerationOnError? = nil,
        onAbort: AIStreamTextOnAbort? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
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
            return streamText(
                model: model,
                request: request,
                timeoutNanoseconds: timeoutNanoseconds,
                timeout: timeout,
                retryPolicy: retryPolicy,
                streamRetries: streamRetries,
                telemetry: telemetry,
                onStepError: onStepError,
                onError: onError,
                onAbort: onAbort
            )
        }

        return streamText(
            model: model,
            request: request,
            executableTools: executableTools,
            maxSteps: maxSteps,
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolCallers: toolCallers,
            toolApproval: toolApproval,
            repairToolCall: repairToolCall,
            timeoutNanoseconds: timeoutNanoseconds,
            timeout: timeout,
            retryPolicy: retryPolicy,
            streamRetries: streamRetries,
            telemetry: telemetry,
            experimentalSteering: experimentalSteering,
            onStepError: onStepError,
            onError: onError,
            onAbort: onAbort
        )
    }

    public static func streamText<FinalOutput: Sendable, PartialOutput: Sendable>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        output: AIOutput<FinalOutput, PartialOutput>,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        streamRetries: Int? = nil,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil,
        onError: AIGenerationOnError? = nil,
        onAbort: AIStreamTextOnAbort? = nil
    ) -> AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error> {
        if experimentalSteering != nil || onStepError != nil || onError != nil || onAbort != nil {
            let stepResults = AISteeringStepResults()
            let languageStream = AISteeringContext.$streamResults.withValue(stepResults) {
                streamText(model: model, request: output.requestForOutput(request, jsonInstruction), timeoutNanoseconds: timeoutNanoseconds, timeout: timeout, retryPolicy: retryPolicy, streamRetries: streamRetries, telemetry: telemetry, experimentalSteering: experimentalSteering, onStepError: onStepError, onError: onError, onAbort: onAbort)
            }
            return mapStructuredLanguageStreamToOutputStream(languageStream, output: output, providerID: model.providerID, repairText: repairText, stepResults: stepResults)
        }
        if let timeoutNanoseconds, timeoutNanoseconds == 0 {
            return failingPartStream(AIError.invalidArgument(
                argument: "timeoutNanoseconds",
                message: "timeoutNanoseconds must be greater than zero."
            ))
        }
        if let validationError = validateStreamTimeoutConfiguration(timeout) {
            return failingPartStream(validationError)
        }
        if let streamRetries, streamRetries < 0 {
            return failingPartStream(AIError.invalidArgument(
                argument: "streamRetries",
                message: "streamRetries must be greater than or equal to zero."
            ))
        }

        let totalTimeoutNanoseconds = minimumTimeoutNanoseconds(
            timeout?.totalNanoseconds,
            timeoutNanoseconds
        )
        let stepTimeoutNanoseconds = timeout?.stepNanoseconds
        let totalTimeoutController = totalTimeoutNanoseconds.map { _ in AIAbortController() }
        let stepTimeoutController = stepTimeoutNanoseconds.map { _ in AIAbortController() }
        let semanticTimeoutController = timeout?.firstChunkNanoseconds != nil
            || timeout?.chunkNanoseconds != nil
            ? AIAbortController()
            : nil
        var requestWithTimeoutSignals = request
        requestWithTimeoutSignals.abortSignal = mergeAbortSignals(
            request.abortSignal,
            totalTimeoutController?.signal,
            stepTimeoutController?.signal,
            semanticTimeoutController?.signal
        )
        let operationRequest = requestWithTimeoutSignals
        let outputStream = outputStreamWithRetries(streamRetries: streamRetries) {
            AIDeprecationLogging.$suppressObjectWarnings.withValue(true) {
                output.streamFromRequest(
                    model,
                    operationRequest,
                    nil,
                    retryPolicy,
                    telemetry,
                    jsonInstruction,
                    repairText
                )
            }
        }
        let semanticTimedStream = streamWithSemanticOutputTimeouts(
            outputStream,
            firstChunkNanoseconds: timeout?.firstChunkNanoseconds,
            chunkNanoseconds: timeout?.chunkNanoseconds,
            abortController: semanticTimeoutController
        )
        let stepTimedStream = streamWithTimeout(
            semanticTimedStream,
            timeoutNanoseconds: stepTimeoutNanoseconds,
            abortController: stepTimeoutController,
            timeoutLabel: "Step"
        )
        return streamWithTimeout(
            stepTimedStream,
            timeoutNanoseconds: totalTimeoutNanoseconds,
            abortController: totalTimeoutController,
            timeoutLabel: "Total"
        )
    }

    public static func streamText<FinalOutput: Sendable, PartialOutput: Sendable>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        output: AIOutput<FinalOutput, PartialOutput>,
        executableTools: [AITool],
        maxSteps: Int = 5,
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolCallers: AIToolCallerRouting = [:],
        toolApproval: AIToolApproval? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        streamRetries: Int? = nil,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil,
        onError: AIGenerationOnError? = nil,
        onAbort: AIStreamTextOnAbort? = nil
    ) -> AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error> {
        let outputRequest = output.requestForOutput(request, jsonInstruction)
        let stepResults = AISteeringStepResults()
        let languageStream = AISteeringContext.$streamResults.withValue(stepResults) {
            streamText(
            model: model,
            request: outputRequest,
            executableTools: executableTools,
            maxSteps: maxSteps,
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolCallers: toolCallers,
            toolApproval: toolApproval,
            repairToolCall: repairToolCall,
            timeoutNanoseconds: timeoutNanoseconds,
            timeout: timeout,
            retryPolicy: retryPolicy,
            streamRetries: streamRetries,
            telemetry: telemetry,
            experimentalSteering: experimentalSteering,
            onStepError: onStepError,
            onError: onError,
            onAbort: onAbort
            )
        }
        return mapStructuredLanguageStreamToOutputStream(
            languageStream,
            output: output,
            providerID: model.providerID,
            repairText: repairText,
            stepResults: stepResults
        )
    }

    public static func streamText<FinalOutput: Sendable, PartialOutput: Sendable>(
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
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        streamRetries: Int? = nil,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil,
        experimentalSteering: AISteering? = nil,
        onStepError: AIGenerateTextOnStepError? = nil,
        onError: AIGenerationOnError? = nil,
        onAbort: AIStreamTextOnAbort? = nil
    ) -> AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error> {
        streamText(
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
            timeoutNanoseconds: timeoutNanoseconds,
            timeout: timeout,
            retryPolicy: retryPolicy,
            streamRetries: streamRetries,
            telemetry: telemetry,
            jsonInstruction: jsonInstruction,
            repairText: repairText,
            experimentalSteering: experimentalSteering,
            onStepError: onStepError,
            onError: onError,
            onAbort: onAbort
        )
    }
}


// Source-compatible overloads preserve the public signatures released in 1.7.0.
extension AI {
    public static func streamText(
        model: any LanguageModel,
        request: LanguageModelRequest,
        executableTools: [AITool],
        maxSteps: Int = 5,
        stopWhen: [AIStopCondition] = [],
        prepareStep: AIPrepareStep? = nil,
        toolApproval: AIToolApproval? = nil,
        repairToolCall: AIToolCallRepair? = nil,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        streamRetries: Int? = nil,
        telemetry: Telemetry.Options? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        streamText(
            model: model,
            request: request,
            executableTools: executableTools,
            maxSteps: maxSteps,
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolCallers: [:],
            toolApproval: toolApproval,
            repairToolCall: repairToolCall,
            timeoutNanoseconds: timeoutNanoseconds,
            timeout: timeout,
            retryPolicy: retryPolicy,
            streamRetries: streamRetries,
            telemetry: telemetry
        )
    }

    public static func streamText(
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
        repairToolCall: AIToolCallRepair? = nil,
        toolChoice: JSONValue? = nil,
        includeRawChunks: Bool = false,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        streamRetries: Int? = nil,
        telemetry: Telemetry.Options? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        streamText(
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
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolCallers: [:],
            toolApproval: toolApproval,
            repairToolCall: repairToolCall,
            toolChoice: toolChoice,
            includeRawChunks: includeRawChunks,
            providerOptions: providerOptions,
            extraBody: extraBody,
            headers: headers,
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds,
            timeout: timeout,
            retryPolicy: retryPolicy,
            streamRetries: streamRetries,
            telemetry: telemetry
        )
    }
}


private func outputStreamWithRetries<FinalOutput: Sendable, PartialOutput: Sendable>(
    streamRetries: Int?,
    makeStream: @escaping @Sendable () -> AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error>
) -> AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error> {
    guard let streamRetries, streamRetries > 0 else {
        return makeStream()
    }

    return AsyncThrowingStream { continuation in
        let task = Task {
            var retryCount = 0

            do {
                while true {
                    var receivedPart = false
                    var bufferedFailureTail: [AIOutputStreamPart<FinalOutput, PartialOutput>] = []
                    var isBufferingFailureTail = false

                    do {
                        for try await part in makeStream() {
                            try Task.checkCancellation()
                            receivedPart = true
                            if retryCount < streamRetries,
                               isBufferingFailureTail || part.isRetryableProviderStreamError {
                                isBufferingFailureTail = true
                                bufferedFailureTail.append(part)
                            } else {
                                continuation.yield(part)
                            }
                        }

                        for part in bufferedFailureTail {
                            continuation.yield(part)
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard receivedPart,
                              !bufferedFailureTail.isEmpty,
                              retryCount < streamRetries else {
                            for part in bufferedFailureTail {
                                continuation.yield(part)
                            }
                            throw error
                        }
                        retryCount += 1
                    }
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
    }
}

private extension AIOutputStreamPart {
    var isRetryableProviderStreamError: Bool {
        guard case let .raw(part) = self else { return false }
        return part.streamProviderError?.isRetryable == true
    }
}
