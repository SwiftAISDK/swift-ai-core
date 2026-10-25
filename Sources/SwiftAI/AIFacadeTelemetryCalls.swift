import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func withTelemetry<Output: Sendable>(
    operationID: String,
    providerID: String,
    modelID: String?,
    input: JSONValue?,
    telemetry: Telemetry.Options?,
    retryPolicy: AIRetryPolicy,
    abortSignal: AIAbortSignal? = nil,
    callID providedCallID: String? = nil,
    output: @escaping @Sendable (Output) -> JSONValue?,
    usage: @escaping @Sendable (Output) -> TokenUsage?,
    warnings: @escaping @Sendable (Output) -> [AIWarning],
    providerMetadata: @escaping @Sendable (Output) -> [String: JSONValue],
    responseMetadata: @escaping @Sendable (Output) -> AIResponseMetadata,
    providerUsage: (@Sendable (Output) -> [String: JSONValue]?)? = nil,
    wrapLanguageModelCall: Bool = false,
    logEmptyWarnings: Bool = true,
    operation: @escaping @Sendable () async throws -> Output
) async throws -> Output {
    let dispatcher = TelemetryDispatcher(options: telemetry)
    guard dispatcher.isEnabled else {
        let result = try await withRetry(policy: retryPolicy, abortSignal: abortSignal, operation: operation)
        let resultWarnings = warnings(result)
        if logEmptyWarnings || !resultWarnings.isEmpty {
            await AIWarningLogging.logWarnings(resultWarnings, providerID: providerID, modelID: modelID)
        }
        return result
    }

    let callID = providedCallID ?? UUID().uuidString
    let started = DispatchTime.now().uptimeNanoseconds
    await dispatcher.record(telemetryEvent(
        kind: .start,
        callID: callID,
        operationID: operationID,
        providerID: providerID,
        modelID: modelID,
        options: telemetry,
        maxRetries: retryPolicy.maxRetries,
        input: input
    ))

    do {
        let wrappedOperation: @Sendable () async throws -> Output = {
            if wrapLanguageModelCall {
                return try await dispatcher.executeLanguageModelCall(
                    callID: callID,
                    operationID: operationID,
                    providerID: providerID,
                    modelID: modelID,
                    operation: operation
                )
            }
            return try await operation()
        }
        let result = try await withRetry(policy: retryPolicy, abortSignal: abortSignal, onRetry: { retry in
            await dispatcher.record(telemetryEvent(
                kind: .retry,
                callID: callID,
                operationID: operationID,
                providerID: providerID,
                modelID: modelID,
                options: telemetry,
                attempt: retry.attempt,
                maxRetries: retry.maxRetries,
                delayNanoseconds: retry.delayNanoseconds,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
                errorDescription: retry.errorDescription
            ))
        }, operation: wrappedOperation)
        var endEvent = telemetryEvent(
            kind: .end,
            callID: callID,
            operationID: operationID,
            providerID: providerID,
            modelID: modelID,
            options: telemetry,
            maxRetries: retryPolicy.maxRetries,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
            output: output(result),
            usage: usage(result),
            warnings: warnings(result),
            providerMetadata: providerMetadata(result),
            responseMetadata: responseMetadata(result),
            useResponseModelID: wrapLanguageModelCall
        )
        endEvent.providerUsage = providerUsage?(result)
        await dispatcher.record(endEvent)
        let resultWarnings = warnings(result)
        if logEmptyWarnings || !resultWarnings.isEmpty {
            await AIWarningLogging.logWarnings(resultWarnings, providerID: providerID, modelID: modelID)
        }
        return result
    } catch {
        let eventKind: Telemetry.Event.Kind = isCancellationTelemetryError(error) ? .abort : .error
        await dispatcher.record(telemetryEvent(
            kind: eventKind,
            callID: callID,
            operationID: operationID,
            providerID: providerID,
            modelID: modelID,
            options: telemetry,
            maxRetries: retryPolicy.maxRetries,
            durationNanoseconds: DispatchTime.now().uptimeNanoseconds - started,
            errorDescription: String(describing: error)
        ))
        throw error
    }
}