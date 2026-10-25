import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


struct AIRetryAttemptTelemetry: Sendable {
    var attempt: Int
    var maxRetries: Int
    var errorDescription: String
    var delayNanoseconds: UInt64
}

struct TelemetryDispatcher: Sendable {
    var options: Telemetry.Options?
    var integrations: [any Telemetry.Integration]

    init(options: Telemetry.Options?) {
        self.options = options
        guard let options, options.isEnabled else {
            integrations = []
            return
        }
        integrations = options.integrations ?? Telemetry.registeredIntegrations()
    }

    var isEnabled: Bool {
        !integrations.isEmpty
    }

    func record(_ event: Telemetry.Event) async {
        guard isEnabled else { return }
        for integration in integrations {
            await integration.record(event)
        }
    }

    func executeLanguageModelCall<Output: Sendable>(
        callID: String,
        operationID: String,
        providerID: String,
        modelID: String?,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        guard isEnabled else {
            return try await operation()
        }

        var execute = operation
        for integration in integrations {
            let innerExecute = execute
            execute = {
                try await integration.executeLanguageModelCall(Telemetry.LanguageModelCallContext(
                    callID: callID,
                    operationID: operationID,
                    providerID: providerID,
                    modelID: modelID,
                    execute: innerExecute
                ))
            }
        }
        return try await execute()
    }

    func executeTool<Output: Sendable>(
        callID: String,
        toolCallID: String,
        toolName: String,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        guard isEnabled else {
            return try await operation()
        }

        var execute = operation
        for integration in integrations {
            let innerExecute = execute
            execute = {
                try await integration.executeTool(Telemetry.ToolExecutionContext(
                    callID: callID,
                    toolCallID: toolCallID,
                    toolName: toolName,
                    execute: innerExecute
                ))
            }
        }
        return try await execute()
    }
}

actor AIStreamTerminalState {
    private var didRecordTerminalEvent = false

    func claimTerminalEvent() -> Bool {
        guard !didRecordTerminalEvent else { return false }
        didRecordTerminalEvent = true
        return true
    }
}

struct AIToolLoopTelemetryContext: Sendable {
    var dispatcher: TelemetryDispatcher
    var callID: String
    var operationID: String
    var providerID: String
    var modelID: String?
    var telemetry: Telemetry.Options?
    var started: UInt64

    init(
        operationID: String,
        providerID: String,
        modelID: String?,
        telemetry: Telemetry.Options?
    ) {
        self.dispatcher = TelemetryDispatcher(options: telemetry)
        self.callID = UUID().uuidString
        self.operationID = operationID
        self.providerID = providerID
        self.modelID = modelID
        self.telemetry = telemetry
        self.started = DispatchTime.now().uptimeNanoseconds
    }

    func recordStepStart(
        index: Int,
        maxSteps: Int,
        model: any LanguageModel,
        request: LanguageModelRequest,
        tools: [AITool]
    ) async {
        await dispatcher.record(telemetryEvent(
            kind: .stepStart,
            callID: callID,
            operationID: "\(operationID).step",
            providerID: model.providerID,
            modelID: model.modelID,
            options: telemetry,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
            input: stepTelemetryInput(index: index, maxSteps: maxSteps, request: request, tools: tools)
        ))
    }

    func recordStepEnd(_ step: AIToolStep) async {
        await dispatcher.record(telemetryEvent(
            kind: .stepEnd,
            callID: callID,
            operationID: "\(operationID).step",
            providerID: step.providerID ?? providerID,
            modelID: step.modelID ?? modelID,
            options: telemetry,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
            output: toolStepTelemetryOutput(step),
            usage: step.usage,
            providerMetadata: step.providerMetadata,
            responseMetadata: step.responseMetadata
        ))
    }

    func recordToolStart(
        stepIndex: Int,
        call: AIToolCall,
        tool: AITool
    ) async {
        await dispatcher.record(telemetryEvent(
            kind: .toolStart,
            callID: callID,
            operationID: "\(operationID).tool",
            providerID: providerID,
            modelID: modelID,
            options: telemetry,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
            input: toolExecutionTelemetryInput(stepIndex: stepIndex, call: call, tool: tool)
        ))
    }

    func recordToolEnd(
        stepIndex: Int,
        call: AIToolCall,
        status: String,
        arguments: JSONValue?,
        result: AIToolResult? = nil,
        approvalRequest: AIToolApprovalRequest? = nil,
        approvalResponse: AIToolApprovalResponse? = nil
    ) async {
        await dispatcher.record(telemetryEvent(
            kind: .toolEnd,
            callID: callID,
            operationID: "\(operationID).tool",
            providerID: providerID,
            modelID: modelID,
            options: telemetry,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
            output: toolExecutionTelemetryOutput(
                stepIndex: stepIndex,
                call: call,
                status: status,
                arguments: arguments,
                result: result,
                approvalRequest: approvalRequest,
                approvalResponse: approvalResponse
            ),
            providerMetadata: result?.providerMetadata ?? call.providerMetadata
        ))
    }

    func recordToolError(
        stepIndex: Int,
        call: AIToolCall,
        error: Error
    ) async {
        await dispatcher.record(telemetryEvent(
            kind: .toolError,
            callID: callID,
            operationID: "\(operationID).tool",
            providerID: providerID,
            modelID: modelID,
            options: telemetry,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
            input: .object([
                "stepNumber": .number(Double(stepIndex)),
                "toolCall": toolCallTelemetryJSON(call)
            ]),
            errorDescription: String(describing: error)
        ))
    }

    func executeTool<Output: Sendable>(
        call: AIToolCall,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await dispatcher.executeTool(
            callID: callID,
            toolCallID: call.id,
            toolName: call.name,
            operation: operation
        )
    }
}