import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


func mapObjectStream<Input: Sendable, Output: Sendable>(
    _ stream: AsyncThrowingStream<ObjectStreamPart<Input>, Error>,
    transform: @escaping @Sendable (ObjectStreamPart<Input>) -> ObjectStreamPart<Output>
) -> AsyncThrowingStream<ObjectStreamPart<Output>, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await part in stream {
                    try Task.checkCancellation()
                    continuation.yield(transform(part))
                }
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

func arrayEnvelopeCallbacks<Element: Decodable & Sendable>(
    _ callbacks: AIObjectGenerationCallbacks<[Element]>?
) -> AIObjectGenerationCallbacks<AIObjectArrayEnvelope<Element>>? {
    guard let callbacks else { return nil }
    return AIObjectGenerationCallbacks<AIObjectArrayEnvelope<Element>>(
        onStart: { event in
            await callbacks.onStart?(AIObjectGenerationStartEvent(
                callID: event.callID,
                operationID: event.operationID,
                providerID: event.providerID,
                modelID: event.modelID,
                outputKind: "array",
                request: event.request,
                schema: event.schema,
                schemaName: event.schemaName,
                schemaDescription: event.schemaDescription,
                maxRetries: event.maxRetries
            ))
        },
        onStepStart: callbacks.onStepStart,
        onStepFinish: callbacks.onStepFinish,
        onFinish: { event in
            await callbacks.onFinish?(AIObjectGenerationFinishEvent<[Element]>(
                callID: event.callID,
                object: event.object.elements,
                text: event.text,
                rawObject: event.rawObject,
                reasoning: event.reasoning,
                finishReason: event.finishReason,
                usage: event.usage,
                warnings: event.warnings,
                providerMetadata: event.providerMetadata,
                responseMetadata: event.responseMetadata
            ))
        },
        onError: callbacks.onError
    )
}

func enumEnvelopeCallbacks(
    _ callbacks: AIObjectGenerationCallbacks<String>?
) -> AIObjectGenerationCallbacks<AIEnumEnvelope>? {
    guard let callbacks else { return nil }
    return AIObjectGenerationCallbacks<AIEnumEnvelope>(
        onStart: { event in
            await callbacks.onStart?(AIObjectGenerationStartEvent(
                callID: event.callID,
                operationID: event.operationID,
                providerID: event.providerID,
                modelID: event.modelID,
                outputKind: "enum",
                request: event.request,
                schema: event.schema,
                schemaName: event.schemaName,
                schemaDescription: event.schemaDescription,
                maxRetries: event.maxRetries
            ))
        },
        onStepStart: callbacks.onStepStart,
        onStepFinish: callbacks.onStepFinish,
        onFinish: { event in
            await callbacks.onFinish?(AIObjectGenerationFinishEvent<String>(
                callID: event.callID,
                object: event.object.result,
                text: event.text,
                rawObject: event.rawObject,
                reasoning: event.reasoning,
                finishReason: event.finishReason,
                usage: event.usage,
                warnings: event.warnings,
                providerMetadata: event.providerMetadata,
                responseMetadata: event.responseMetadata
            ))
        },
        onError: callbacks.onError
    )
}