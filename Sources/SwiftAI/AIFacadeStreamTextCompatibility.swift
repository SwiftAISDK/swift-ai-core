import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


// Exact 1.5.x entry points retained alongside the additive `streamRetries`
// overloads. Keeping these declarations prevents a defaulted parameter added
// near the end of a Swift function from changing its public symbol.
extension AI {
    public static func streamText(
        model: any LanguageModel,
        request: LanguageModelRequest,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        streamText(
            model: model,
            request: request,
            timeoutNanoseconds: timeoutNanoseconds,
            timeout: timeout,
            retryPolicy: retryPolicy,
            streamRetries: nil,
            telemetry: telemetry
        )
    }

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
        telemetry: Telemetry.Options? = nil
    ) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        streamText(
            model: model,
            request: request,
            executableTools: executableTools,
            maxSteps: maxSteps,
            stopWhen: stopWhen,
            prepareStep: prepareStep,
            toolApproval: toolApproval,
            repairToolCall: repairToolCall,
            timeoutNanoseconds: timeoutNanoseconds,
            timeout: timeout,
            retryPolicy: retryPolicy,
            streamRetries: nil,
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
            streamRetries: nil,
            telemetry: telemetry
        )
    }

    public static func streamText<FinalOutput: Sendable, PartialOutput: Sendable>(
        model: any LanguageModel,
        request: LanguageModelRequest,
        output: AIOutput<FinalOutput, PartialOutput>,
        timeoutNanoseconds: UInt64? = nil,
        timeout: AIStreamTimeoutConfiguration? = nil,
        retryPolicy: AIRetryPolicy = .default,
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error> {
        streamText(
            model: model,
            request: request,
            output: output,
            timeoutNanoseconds: timeoutNanoseconds,
            timeout: timeout,
            retryPolicy: retryPolicy,
            streamRetries: nil,
            telemetry: telemetry,
            jsonInstruction: jsonInstruction,
            repairText: repairText
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
        telemetry: Telemetry.Options? = nil,
        jsonInstruction: AIJSONInstruction? = nil,
        repairText: (@Sendable (AIObjectRepairContext) async throws -> String?)? = nil
    ) -> AsyncThrowingStream<AIOutputStreamPart<FinalOutput, PartialOutput>, Error> {
        streamText(
            model: model,
            prompt: prompt,
            output: output,
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
            timeoutNanoseconds: timeoutNanoseconds,
            timeout: timeout,
            retryPolicy: retryPolicy,
            streamRetries: nil,
            telemetry: telemetry,
            jsonInstruction: jsonInstruction,
            repairText: repairText
        )
    }
}
