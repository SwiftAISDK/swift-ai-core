import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


private let aiBatchUserAgent = "ai/7.0.153"

extension AI {
    /// Starts a provider-owned Batch V4 operation. Unlike the legacy text-only
    /// overload, every request carries its own model identifier and modality.
    public static func startBatch(
        provider: any AIBatchProvider,
        requests: [AIBatchRequest],
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        idempotencyKey: String? = nil,
        webhookURL: String? = nil,
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> StartBatchResult {
        try validateBatchRequests(requests)
        let operationAbortSignal = try batchOperationAbortSignal(
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds
        )
        try operationAbortSignal?.throwIfAborted()

        var normalized: [AIBatchRequest] = []
        normalized.reserveCapacity(requests.count)
        var toolsByName: [String: JSONValue] = [:]
        for request in requests {
            switch request {
            case var .text(text):
                guard let modelID = text.modelID, !modelID.isEmpty else {
                    throw AIError.invalidArgument(
                        argument: "requests",
                        message: "text batch request \"\(text.id)\" must specify a modelID"
                    )
                }
                text.modelID = modelID
                text.request = try prepareLanguageModelCallOptions(text.request)
                for (toolName, definition) in text.request.tools {
                    if let previous = toolsByName[toolName], previous != definition {
                        throw AIError.invalidArgument(
                            argument: "requests",
                            message: "tool \"\(toolName)\" must have the same definition in every batch request"
                        )
                    }
                    toolsByName[toolName] = definition
                }
                normalized.append(.text(text))
            case let .image(image):
                guard !image.modelID.isEmpty else {
                    throw AIError.invalidArgument(
                        argument: "requests",
                        message: "image batch request \"\(image.id)\" must specify a modelID"
                    )
                }
                normalized.append(.image(image))
            }
            try operationAbortSignal?.throwIfAborted()
        }

        let result = try await provider.startBatch(AIBatchStartOptions(
            requests: normalized,
            providerOptions: providerOptions,
            abortSignal: operationAbortSignal,
            headers: batchOperationHeaders(headers, idempotencyKey: idempotencyKey),
            idempotencyKey: idempotencyKey,
            webhookURL: webhookURL
        ))
        let models = Dictionary(uniqueKeysWithValues: normalized.compactMap { request in
            request.modelID.map { (request.id, $0) }
        })
        for warning in result.warnings {
            await AIWarningLogging.logWarnings(
                [warning.warning],
                providerID: provider.providerID,
                modelID: warning.requestID.flatMap { models[$0] }
            )
        }
        return StartBatchResult(
            batch: AIBatch(
                reference: AIBatchReference(id: result.batchID, providerID: provider.providerID),
                status: result.status
            ),
            warnings: result.warnings,
            providerMetadata: result.providerMetadata
        )
    }

    public static func cancelBatch(
        provider: any AIBatchProvider,
        batch: AIBatchReference,
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> AIBatchCancelResult {
        try validateBatchReference(batch, provider: provider)
        let signal = try batchOperationAbortSignal(
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds
        )
        return try await provider.cancelBatch(AIBatchOperationOptions(
            batchID: batch.id,
            providerOptions: providerOptions,
            abortSignal: signal,
            headers: batchOperationHeaders(headers, idempotencyKey: nil)
        ))
    }

    public static func listBatches(
        provider: any AIBatchProvider,
        providerOptions: [String: JSONValue] = [:],
        limit: Int? = nil,
        cursor: String? = nil,
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default
    ) async throws -> (batches: [AIBatch], nextCursor: String?, providerMetadata: [String: JSONValue]) {
        if let limit, limit <= 0 {
            throw AIError.invalidArgument(argument: "limit", message: "limit must be greater than zero")
        }
        let signal = try batchOperationAbortSignal(
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds
        )
        let result = try await withRetry(policy: retryPolicy, abortSignal: signal) {
            try await provider.listBatches(AIBatchListOptions(
                providerOptions: providerOptions,
                limit: limit,
                cursor: cursor,
                abortSignal: signal,
                headers: batchOperationHeaders(headers, idempotencyKey: nil)
            ))
        }
        return (
            batches: result.batches.map {
                AIBatch(
                    reference: AIBatchReference(id: $0.batchID, providerID: provider.providerID),
                    status: $0.status
                )
            },
            nextCursor: result.nextCursor,
            providerMetadata: result.providerMetadata
        )
    }

    public static func getBatchStatus(
        provider: any AIBatchProvider,
        batch: AIBatchReference,
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default
    ) async throws -> AIBatchStatus {
        try validateBatchReference(batch, provider: provider)
        let signal = try batchOperationAbortSignal(
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds
        )
        return try await withRetry(policy: retryPolicy, abortSignal: signal) {
            try await provider.getBatchStatus(AIBatchOperationOptions(
                batchID: batch.id,
                providerOptions: providerOptions,
                abortSignal: signal,
                headers: batchOperationHeaders(headers, idempotencyKey: nil)
            ))
        }
    }

    public static func getBatchResults(
        provider: any AIBatchProvider,
        batch: AIBatchReference,
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default
    ) throws -> AsyncThrowingStream<BatchItemResult, Error> {
        try validateBatchReference(batch, provider: provider)
        let streamAbortController = AIAbortController()
        let signal = try batchOperationAbortSignal(
            abortSignal: mergeAbortSignals(abortSignal, streamAbortController.signal),
            timeoutNanoseconds: timeoutNanoseconds
        )
        let operationHeaders = batchOperationHeaders(headers, idempotencyKey: nil)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = try await withRetry(policy: retryPolicy, abortSignal: signal) {
                        try await provider.getBatchResults(AIBatchOperationOptions(
                            batchID: batch.id,
                            providerOptions: providerOptions,
                            abortSignal: signal,
                            headers: operationHeaders
                        ))
                    }
                    for try await item in stream {
                        try Task.checkCancellation()
                        try signal?.throwIfAborted()
                        continuation.yield(try await convertBatchItemResult(
                            item,
                            providerID: provider.providerID,
                            abortSignal: signal
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                streamAbortController.abort(reason: "Batch results stream was cancelled.")
                task.cancel()
            }
        }
    }

    /// Source-compatible Batch V4 entry point retained from 1.5.x.
    public static func startTextBatch(
        model: any LanguageModel,
        requests: [TextBatchRequest],
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        idempotencyKey: String? = nil,
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> StartTextBatchResult {
        try await startTextBatch(
            model: model,
            requests: requests,
            tools: [:],
            toolChoice: nil,
            providerOptions: providerOptions,
            headers: headers,
            idempotencyKey: idempotencyKey,
            webhookURL: nil,
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    /// Source-compatible overload retained from Batch V4 before completion
    /// webhooks were added.
    public static func startTextBatch(
        model: any LanguageModel,
        requests: [TextBatchRequest],
        tools: [String: JSONValue] = [:],
        toolChoice: JSONValue? = nil,
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        idempotencyKey: String? = nil,
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> StartTextBatchResult {
        try await startTextBatch(
            model: model,
            requests: requests,
            tools: tools,
            toolChoice: toolChoice,
            providerOptions: providerOptions,
            headers: headers,
            idempotencyKey: idempotencyKey,
            webhookURL: nil,
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    /// Starts a durable text-generation batch. Starting is intentionally not retried because it is billable.
    public static func startTextBatch(
        model: any LanguageModel,
        requests: [TextBatchRequest],
        tools: [String: JSONValue] = [:],
        toolChoice: JSONValue? = nil,
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        idempotencyKey: String? = nil,
        webhookURL: String? = nil,
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> StartTextBatchResult {
        try validateTextBatchRequests(requests)
        let model = try resolveBatchLanguageModel(model)
        let operationAbortSignal = try batchOperationAbortSignal(
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds
        )
        try operationAbortSignal?.throwIfAborted()

        var normalizedRequests: [AILanguageModelBatchRequest] = []
        normalizedRequests.reserveCapacity(requests.count)
        for request in requests {
            var preparedRequest = try prepareLanguageModelCallOptions(request.request)
            if !tools.isEmpty {
                preparedRequest.tools = tools
            }
            if let toolChoice {
                preparedRequest.toolChoice = toolChoice
            }
            normalizedRequests.append(AILanguageModelBatchRequest(
                id: request.id,
                request: preparedRequest
            ))
            try operationAbortSignal?.throwIfAborted()
        }

        let operationHeaders = batchOperationHeaders(headers, idempotencyKey: idempotencyKey)
        let result = try await model.startBatch(AIBatchStartOptions(
            requests: normalizedRequests,
            providerOptions: providerOptions,
            abortSignal: operationAbortSignal,
            headers: operationHeaders,
            idempotencyKey: idempotencyKey,
            webhookURL: webhookURL
        ))
        await AIWarningLogging.logWarnings(
            result.warnings.map(\.warning),
            providerID: model.providerID,
            modelID: model.modelID
        )
        return StartTextBatchResult(
            batch: TextBatch(
                reference: TextBatchReference(
                    id: result.batchID,
                    providerID: model.providerID,
                    modelID: model.modelID
                ),
                status: result.status
            ),
            warnings: result.warnings,
            providerMetadata: result.providerMetadata
        )
    }

    /// Source-compatible webhook entry point retained from 1.5.x.
    public static func startTextBatch(
        model: any LanguageModel,
        requests: [TextBatchRequest],
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        idempotencyKey: String? = nil,
        webhookURL: String? = nil,
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> StartTextBatchResult {
        try await startTextBatch(
            model: model,
            requests: requests,
            tools: [:],
            toolChoice: nil,
            providerOptions: providerOptions,
            headers: headers,
            idempotencyKey: idempotencyKey,
            webhookURL: webhookURL,
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    public static func getBatchStatus(
        model: any LanguageModel,
        batch: TextBatchReference,
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default
    ) async throws -> AIBatchStatus {
        let model = try resolveBatchLanguageModel(model)
        try validateBatchReference(batch, model: model)
        let operationAbortSignal = try batchOperationAbortSignal(
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds
        )
        let operationHeaders = batchOperationHeaders(headers, idempotencyKey: nil)

        return try await withRetry(policy: retryPolicy, abortSignal: operationAbortSignal) {
            try await model.getBatchStatus(AIBatchOperationOptions(
                batchID: batch.id,
                providerOptions: providerOptions,
                abortSignal: operationAbortSignal,
                headers: operationHeaders
            ))
        }
    }

    public static func getBatchStatus(
        model: any LanguageModel,
        batch: TextBatch,
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default
    ) async throws -> AIBatchStatus {
        try await getBatchStatus(
            model: model,
            batch: batch.reference,
            providerOptions: providerOptions,
            headers: headers,
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: retryPolicy
        )
    }

    /// Opens the provider result stream in a task. Connection failures are delivered through the stream.
    public static func getBatchResults(
        model: any LanguageModel,
        batch: TextBatchReference,
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default
    ) throws -> AsyncThrowingStream<TextBatchItemResult, Error> {
        let model = try resolveBatchLanguageModel(model)
        try validateBatchReference(batch, model: model)
        let streamAbortController = AIAbortController()
        let operationAbortSignal = try batchOperationAbortSignal(
            abortSignal: mergeAbortSignals(abortSignal, streamAbortController.signal),
            timeoutNanoseconds: timeoutNanoseconds
        )
        let operationHeaders = batchOperationHeaders(headers, idempotencyKey: nil)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let stream = try await withRetry(policy: retryPolicy, abortSignal: operationAbortSignal) {
                        try await model.getBatchResults(AIBatchOperationOptions(
                            batchID: batch.id,
                            providerOptions: providerOptions,
                            abortSignal: operationAbortSignal,
                            headers: operationHeaders
                        ))
                    }
                    for try await item in stream {
                        try Task.checkCancellation()
                        try operationAbortSignal?.throwIfAborted()
                        continuation.yield(try await convertTextBatchItemResult(
                            item,
                            providerID: model.providerID,
                            abortSignal: operationAbortSignal
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                streamAbortController.abort(reason: "Batch results stream was cancelled.")
                task.cancel()
            }
        }
    }

    public static func getBatchResults(
        model: any LanguageModel,
        batch: TextBatch,
        providerOptions: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil,
        timeoutNanoseconds: UInt64? = nil,
        retryPolicy: AIRetryPolicy = .default
    ) throws -> AsyncThrowingStream<TextBatchItemResult, Error> {
        try getBatchResults(
            model: model,
            batch: batch.reference,
            providerOptions: providerOptions,
            headers: headers,
            abortSignal: abortSignal,
            timeoutNanoseconds: timeoutNanoseconds,
            retryPolicy: retryPolicy
        )
    }
}


private func validateBatchRequests(_ requests: [AIBatchRequest]) throws {
    guard !requests.isEmpty else {
        throw AIError.invalidArgument(argument: "requests", message: "requests must not be empty")
    }
    var ids = Set<String>()
    for request in requests {
        guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidArgument(argument: "requests", message: "request IDs must not be empty")
        }
        guard ids.insert(request.id).inserted else {
            throw AIError.invalidArgument(
                argument: "requests",
                message: "request IDs must be unique; duplicate ID \"\(request.id)\""
            )
        }
    }
}

private func validateBatchReference(_ batch: AIBatchReference, provider: any AIBatchProvider) throws {
    guard batch.version == 2 else {
        throw AIError.invalidArgument(argument: "batch", message: "batch must be a supported batch reference")
    }
    guard batch.providerID == provider.providerID else {
        throw AIError.invalidArgument(
            argument: "provider",
            message: "provider \(provider.providerID) is not compatible with batch provider \(batch.providerID)"
        )
    }
}

private func convertBatchItemResult(
    _ item: AIBatchV4ItemResult,
    providerID: String,
    abortSignal: AIAbortSignal?
) async throws -> BatchItemResult {
    switch item {
    case let .text(result):
        return .text(try await convertTextBatchItemResult(
            result,
            providerID: providerID,
            abortSignal: abortSignal
        ))
    case let .image(result):
        switch result {
        case let .succeeded(id, value):
            return .image(.succeeded(
                id: id,
                result: ImageBatchGenerationResult(
                    urls: value.urls,
                    base64Images: value.base64Images,
                    warnings: value.warnings,
                    usage: value.usage,
                    response: value.responseMetadata,
                    providerMetadata: value.providerMetadata
                )
            ))
        case let .failed(id, error, metadata):
            return .image(.failed(id: id, error: error, providerMetadata: metadata))
        case let .cancelled(id, error, metadata):
            return .image(.cancelled(id: id, error: error, providerMetadata: metadata))
        case let .expired(id, error, metadata):
            return .image(.expired(id: id, error: error, providerMetadata: metadata))
        }
    }
}

private func resolveBatchLanguageModel(_ model: any LanguageModel) throws -> any BatchLanguageModel {
    guard let batchModel = model as? any BatchLanguageModel else {
        throw AIError.invalidArgument(
            argument: "model",
            message: "The \(model.providerID) model \"\(model.modelID)\" does not support batch processing."
        )
    }
    return batchModel
}

private func validateTextBatchRequests(_ requests: [TextBatchRequest]) throws {
    guard !requests.isEmpty else {
        throw AIError.invalidArgument(argument: "requests", message: "requests must not be empty")
    }
    var ids = Set<String>()
    for request in requests {
        guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidArgument(argument: "requests", message: "request IDs must not be empty")
        }
        guard ids.insert(request.id).inserted else {
            throw AIError.invalidArgument(
                argument: "requests",
                message: "request IDs must be unique; duplicate ID \"\(request.id)\""
            )
        }
    }
}

private func validateBatchReference(_ batch: TextBatchReference, model: any BatchLanguageModel) throws {
    guard batch.version == 1, batch.type == .text else {
        throw AIError.invalidArgument(argument: "batch", message: "batch must be a supported text batch reference")
    }
    guard batch.providerID == model.providerID, batch.modelID == model.modelID else {
        throw AIError.invalidArgument(
            argument: "model",
            message: "model \(model.providerID):\(model.modelID) is not compatible with batch \(batch.providerID):\(batch.modelID)"
        )
    }
}

private func batchOperationHeaders(_ headers: [String: String], idempotencyKey: String?) -> [String: String] {
    var output = withUserAgentSuffix(headers, aiBatchUserAgent)
    if let idempotencyKey, output["idempotency-key"] == nil {
        output["idempotency-key"] = idempotencyKey
    }
    return output
}

private func batchOperationAbortSignal(
    abortSignal: AIAbortSignal?,
    timeoutNanoseconds: UInt64?
) throws -> AIAbortSignal? {
    guard let timeoutNanoseconds else { return abortSignal }
    guard timeoutNanoseconds > 0 else {
        throw AIError.invalidArgument(
            argument: "timeoutNanoseconds",
            message: "timeoutNanoseconds must be greater than zero."
        )
    }
    let roundedMilliseconds = timeoutNanoseconds / 1_000_000
        + (timeoutNanoseconds % 1_000_000 == 0 ? 0 : 1)
    let milliseconds = Int(min(roundedMilliseconds, UInt64(Int.max)))
    return mergeAbortSignals(sources: [
        abortSignal.map(AIAbortSource.signal),
        .timeoutMilliseconds(milliseconds)
    ])
}

private func convertTextBatchItemResult(
    _ item: AIBatchItemResult<TextGenerationResult>,
    providerID: String,
    abortSignal: AIAbortSignal?
) async throws -> TextBatchItemResult {
    switch item {
    case let .succeeded(id, providerResult):
        let result = try await materializeGeneratedFiles(
            in: providerResult,
            abortSignal: abortSignal
        )
        let response = result.responseMetadata == AIResponseMetadata() ? nil : result.responseMetadata
        var usage = result.usage ?? TokenUsage()
        if usage.totalTokens == nil,
           let inputTokens = usage.inputTokens,
           let outputTokens = usage.outputTokens {
            usage.totalTokens = inputTokens + outputTokens
        }
        return .succeeded(id: id, result: TextBatchGenerationResult(
            text: result.content.compactMap { part in
                guard let text = part.textValue else { return nil }
                return text
            }.joined(),
            content: result.content,
            finishReason: result.finishReason,
            rawFinishReason: textBatchRawFinishReason(
                from: result.rawValue,
                providerID: providerID
            ),
            usage: usage,
            response: response,
            providerMetadata: result.providerMetadata
        ))
    case let .failed(id, error, providerMetadata):
        return .failed(id: id, error: error, providerMetadata: providerMetadata)
    case let .cancelled(id, error, providerMetadata):
        return .cancelled(id: id, error: error, providerMetadata: providerMetadata)
    case let .expired(id, error, providerMetadata):
        return .expired(id: id, error: error, providerMetadata: providerMetadata)
    }
}

private func textBatchRawFinishReason(
    from rawValue: JSONValue,
    providerID: String
) -> String? {
    if let stopReason = rawValue["stop_reason"]?.stringValue {
        return stopReason
    }
    guard providerID.split(separator: ".", maxSplits: 1).first == "xai",
          let choices = rawValue["choices"]?.arrayValue else {
        return nil
    }
    return choices.reversed().first { choice in
        choice["message"]?["role"]?.stringValue == "assistant"
    }?["finish_reason"]?.stringValue
}