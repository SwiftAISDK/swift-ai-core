import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


private let aiEvaluationUserAgent = "ai/7.0.153"

extension AI {
    /// Source-compatible direct-model entry point retained from SwiftAISDK 1.9.0.
    public static func experimentalEvaluate(
        model: any AIEvaluationModelV4,
        state: JSONValue,
        questions: [String: AIEvaluationQuestion],
        maxRetries: Int? = nil,
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        providerOptions: [String: JSONValue] = [:]
    ) async throws -> AIEvaluationResult {
        try await experimentalEvaluate(
            model: model,
            state: state,
            questions: questions,
            maxRetries: maxRetries,
            abortSignal: abortSignal,
            headers: headers,
            providerOptions: providerOptions,
            telemetry: nil,
            runtimeContext: [:],
            onStart: nil,
            onEnd: nil
        )
    }

    /// Evaluates a map of typed questions against one shared state.
    public static func experimentalEvaluate(
        model: any AIEvaluationModelV4,
        state: JSONValue,
        questions: [String: AIEvaluationQuestion],
        maxRetries: Int? = nil,
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        providerOptions: [String: JSONValue] = [:],
        telemetry: Telemetry.Options? = nil,
        runtimeContext: [String: JSONValue] = [:],
        onStart: AICallback<AIEvaluationStartEvent>? = nil,
        onEnd: AICallback<AIEvaluationEndEvent>? = nil
    ) async throws -> AIEvaluationResult {
        try await experimentalEvaluate(
            model: .model(model),
            state: state,
            questions: questions,
            maxRetries: maxRetries,
            abortSignal: abortSignal,
            headers: headers,
            providerOptions: providerOptions,
            telemetry: telemetry,
            runtimeContext: runtimeContext,
            onStart: onStart,
            onEnd: onEnd
        )
    }

    /// Source-compatible model-reference entry point retained from SwiftAISDK 1.9.0.
    public static func experimentalEvaluate(
        model reference: AIEvaluationModelReference,
        state: JSONValue,
        questions: [String: AIEvaluationQuestion],
        maxRetries: Int? = nil,
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        providerOptions: [String: JSONValue] = [:]
    ) async throws -> AIEvaluationResult {
        try await experimentalEvaluate(
            model: reference,
            state: state,
            questions: questions,
            maxRetries: maxRetries,
            abortSignal: abortSignal,
            headers: headers,
            providerOptions: providerOptions,
            telemetry: nil,
            runtimeContext: [:],
            onStart: nil,
            onEnd: nil
        )
    }

    /// Evaluates with either a direct model or a default-provider model ID.
    public static func experimentalEvaluate(
        model reference: AIEvaluationModelReference,
        state: JSONValue,
        questions: [String: AIEvaluationQuestion],
        maxRetries: Int? = nil,
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        providerOptions: [String: JSONValue] = [:],
        telemetry: Telemetry.Options? = nil,
        runtimeContext: [String: JSONValue] = [:],
        onStart: AICallback<AIEvaluationStartEvent>? = nil,
        onEnd: AICallback<AIEvaluationEndEvent>? = nil
    ) async throws -> AIEvaluationResult {
        let model = try resolveEvaluationModel(reference)
        try validateEvaluationInput(state: state, questions: questions)

        for questionID in questions.keys.sorted() {
            guard let question = questions[questionID] else { continue }
            guard model.supportedQuestionTypes.contains(question.type) else {
                throw AIEvaluationUnsupportedQuestionTypeError(
                    questionID: questionID,
                    questionType: question.type,
                    providerID: model.providerID,
                    modelID: model.modelID
                )
            }
        }

        let retryPolicy = try prepareRetries(maxRetries: maxRetries)
        let dispatcher = TelemetryDispatcher(options: telemetry)
        let callID = UUID().uuidString
        let started = DispatchTime.now().uptimeNanoseconds
        let filteredRuntimeContext = filterEvaluationRuntimeContext(
            runtimeContext,
            include: telemetry?.includeRuntimeContext
        )
        let startEvent = AIEvaluationStartEvent(
            runtimeContext: runtimeContext,
            callID: callID,
            providerID: model.providerID,
            modelID: model.modelID,
            state: state,
            questions: questions,
            maxRetries: retryPolicy.maxRetries,
            headers: headers,
            providerOptions: providerOptions
        )
        await dispatcher.record(telemetryEvent(
            kind: .start,
            callID: callID,
            operationID: startEvent.operationID,
            providerID: model.providerID,
            modelID: model.modelID,
            options: telemetry,
            maxRetries: retryPolicy.maxRetries,
            input: evaluationTelemetryInput(
                state: state,
                questions: questions,
                headers: headers,
                providerOptions: providerOptions
            ),
            runtimeContext: filteredRuntimeContext
        ))
        await notify(event: startEvent, callback: onStart)

        let callOptions = AIEvaluationModelV4CallOptions(
            state: state,
            questions: questions,
            abortSignal: abortSignal,
            headers: withUserAgentSuffix(headers, aiEvaluationUserAgent),
            providerOptions: providerOptions
        )

        do {
            let modelCallStarted = DispatchTime.now().uptimeNanoseconds
            await dispatcher.record(telemetryEvent(
                kind: .modelCallStart,
                callID: callID,
                operationID: "ai.evaluate.doEvaluate",
                providerID: model.providerID,
                modelID: model.modelID,
                options: telemetry,
                input: evaluationTelemetryInput(state: state, questions: questions)
            ))
            let result = try await withRetry(policy: retryPolicy, abortSignal: abortSignal) {
                try abortSignal?.throwIfAborted()
                return try await model.doEvaluate(callOptions)
            }

            try abortSignal?.throwIfAborted()
            try validateEvaluationAnswers(
                questions: questions,
                answers: result.answers,
                rounding: result.rounding,
                providerID: model.providerID
            )
            await dispatcher.record(telemetryEvent(
                kind: .modelCallEnd,
                callID: callID,
                operationID: "ai.evaluate.doEvaluate",
                providerID: model.providerID,
                modelID: model.modelID,
                options: telemetry,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - modelCallStarted,
                output: evaluationModelTelemetryOutput(result),
                usage: evaluationTokenUsage(result.usage),
                warnings: result.warnings,
                providerMetadata: result.providerMetadata,
                responseMetadata: result.response ?? AIResponseMetadata()
            ))
            await AIWarningLogging.logWarnings(
                result.warnings,
                providerID: model.providerID,
                modelID: model.modelID
            )

            let inputTokens = result.usage?.inputTokens
            let outputTokens = result.usage?.outputTokens
            let totalTokens: Int?
            if let inputTokens, let outputTokens {
                let total = inputTokens.addingReportingOverflow(outputTokens)
                totalTokens = total.overflow ? nil : total.partialValue
            } else {
                totalTokens = nil
            }

            let response = result.response ?? AIResponseMetadata()
            let evaluationResult = AIEvaluationResult(
                answers: result.answers,
                usage: AIEvaluationUsage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    totalTokens: totalTokens
                ),
                warnings: result.warnings,
                rounding: result.rounding,
                providerMetadata: result.providerMetadata,
                response: AIEvaluationResponseMetadata(
                    id: response.id,
                    timestamp: response.timestamp ?? Date(),
                    modelID: response.modelID ?? model.modelID,
                    headers: response.headers,
                    body: response.body
                )
            )
            await notify(event: AIEvaluationEndEvent(
                runtimeContext: runtimeContext,
                callID: callID,
                providerID: model.providerID,
                modelID: model.modelID,
                state: state,
                questions: questions,
                maxRetries: retryPolicy.maxRetries,
                headers: headers,
                providerOptions: providerOptions,
                answers: evaluationResult.answers,
                usage: evaluationResult.usage,
                warnings: evaluationResult.warnings,
                rounding: evaluationResult.rounding,
                providerMetadata: evaluationResult.providerMetadata,
                response: evaluationResult.response
            ), callback: onEnd)
            await dispatcher.record(telemetryEvent(
                kind: .end,
                callID: callID,
                operationID: "ai.evaluate",
                providerID: model.providerID,
                modelID: model.modelID,
                options: telemetry,
                maxRetries: retryPolicy.maxRetries,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                output: evaluationResultTelemetryOutput(evaluationResult),
                usage: evaluationTokenUsage(evaluationResult.usage),
                warnings: evaluationResult.warnings,
                providerMetadata: evaluationResult.providerMetadata,
                responseMetadata: evaluationResponseMetadata(evaluationResult.response),
                runtimeContext: filteredRuntimeContext
            ))
            return evaluationResult
        } catch {
            await dispatcher.record(telemetryEvent(
                kind: .error,
                callID: callID,
                operationID: "ai.evaluate",
                providerID: model.providerID,
                modelID: model.modelID,
                options: telemetry,
                maxRetries: retryPolicy.maxRetries,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                errorDescription: String(describing: error),
                runtimeContext: filteredRuntimeContext
            ))
            throw error
        }
    }
}



extension AI {
    /// Ordered evidence overload for the retained Evaluation API. Lifecycle telemetry
    /// follows the renamed `ai.decide` operation; callback signatures remain native Evaluation.
    public static func experimentalEvaluate(
        model: any AIEvaluationModelV4,
        stateParts: [AIDecisionStatePart],
        questions: [String: AIEvaluationQuestion],
        maxRetries: Int? = nil,
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        providerOptions: [String: JSONValue] = [:],
        telemetry: Telemetry.Options? = nil,
        runtimeContext: [String: JSONValue] = [:],
        onStart: AICallback<AIEvaluationStartEvent>? = nil,
        onEnd: AICallback<AIEvaluationEndEvent>? = nil
    ) async throws -> AIEvaluationResult {
        try await experimentalEvaluate(model: .model(model), stateParts: stateParts, questions: questions, maxRetries: maxRetries, abortSignal: abortSignal, headers: headers, providerOptions: providerOptions, telemetry: telemetry, runtimeContext: runtimeContext, onStart: onStart, onEnd: onEnd)
    }

    public static func experimentalEvaluate(
        model reference: AIEvaluationModelReference,
        stateParts: [AIDecisionStatePart],
        questions: [String: AIEvaluationQuestion],
        maxRetries: Int? = nil,
        abortSignal: AIAbortSignal? = nil,
        headers: [String: String] = [:],
        providerOptions: [String: JSONValue] = [:],
        telemetry: Telemetry.Options? = nil,
        runtimeContext: [String: JSONValue] = [:],
        onStart: AICallback<AIEvaluationStartEvent>? = nil,
        onEnd: AICallback<AIEvaluationEndEvent>? = nil
    ) async throws -> AIEvaluationResult {
        let model = try resolveEvaluationModel(reference)
        let callbackState = JSONValue.array(stateParts.map(decisionStatePartJSON))
        let result = try await experimentalDecide(
            model: EvaluationDecisionBridge(model: model),
            state: .parts(stateParts),
            questions: questions,
            maxRetries: maxRetries,
            abortSignal: abortSignal,
            headers: headers,
            providerOptions: providerOptions,
            telemetry: telemetry,
            runtimeContext: runtimeContext,
            onStart: { event in
                await notify(event: AIEvaluationStartEvent(runtimeContext: event.runtimeContext, callID: event.callID, operationID: event.operationID, providerID: event.providerID, modelID: event.modelID, state: callbackState, questions: event.questions, maxRetries: event.maxRetries, headers: event.headers, providerOptions: event.providerOptions), callback: onStart)
            },
            onEnd: { event in
                let answers = try evaluationAnswers(from: event.answers, providerID: event.providerID, modelID: event.modelID)
                await notify(event: AIEvaluationEndEvent(runtimeContext: event.runtimeContext, callID: event.callID, operationID: event.operationID, providerID: event.providerID, modelID: event.modelID, state: callbackState, questions: event.questions, maxRetries: event.maxRetries, headers: event.headers, providerOptions: event.providerOptions, answers: answers, usage: event.usage, warnings: event.warnings, rounding: event.rounding, providerMetadata: event.providerMetadata, response: event.response), callback: onEnd)
            }
        )
        return AIEvaluationResult(
            answers: try evaluationAnswers(from: result.answers, providerID: model.providerID, modelID: model.modelID),
            usage: result.usage,
            warnings: result.warnings,
            rounding: result.rounding,
            providerMetadata: result.providerMetadata,
            response: result.response
        )
    }
}


private struct EvaluationDecisionBridge: AIDecisionModelV4 {
    let model: any AIEvaluationModelV4
    var providerID: String { model.providerID }
    var modelID: String { model.modelID }
    var supportedQuestionTypes: [AIDecisionQuestionType] { model.supportedQuestionTypes }

    func doDecide(_ options: AIDecisionModelV4CallOptions) async throws -> AIDecisionModelV4Result {
        let result = try await model.doEvaluate(AIEvaluationModelV4CallOptions(stateParts: options.state, questions: options.questions, abortSignal: options.abortSignal, headers: options.headers, providerOptions: options.providerOptions))
        return AIDecisionModelV4Result(
            answers: result.answers.mapValues { answer in
                switch answer {
                case let .choice(choice, probabilities): .choice(choice: choice, probabilities: probabilities)
                case let .score(score, probabilities): .score(score: score, probabilities: probabilities)
                case let .boolean(probability): .boolean(probability: probability)
                case let .box(box): .box(box: box)
                }
            },
            rounding: result.rounding,
            usage: result.usage,
            warnings: result.warnings,
            providerMetadata: result.providerMetadata,
            response: result.response
        )
    }
}