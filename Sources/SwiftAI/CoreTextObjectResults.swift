import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public struct ObjectGenerationResult<Object: Sendable>: Sendable {
    public var object: Object
    public var text: String
    public var rawObject: JSONValue
    public var reasoning: String
    public var finishReason: String?
    public var usage: TokenUsage?
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var responseMetadata: AIResponseMetadata
    public var textResult: TextGenerationResult

    public init(
        object: Object,
        text: String,
        rawObject: JSONValue,
        reasoning: String = "",
        finishReason: String? = nil,
        usage: TokenUsage? = nil,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        responseMetadata: AIResponseMetadata = AIResponseMetadata(),
        textResult: TextGenerationResult
    ) {
        self.object = object
        self.text = text
        self.rawObject = rawObject
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.usage = usage
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.responseMetadata = responseMetadata
        self.textResult = textResult
    }
}

public struct AIObjectGenerationCallbacks<Output: Sendable>: Sendable {
    public var onStart: (@Sendable (AIObjectGenerationStartEvent) async -> Void)?
    public var onStepStart: (@Sendable (AIObjectGenerationStepStartEvent) async -> Void)?
    public var onStepFinish: (@Sendable (AIObjectGenerationStepFinishEvent) async -> Void)?
    public var onFinish: (@Sendable (AIObjectGenerationFinishEvent<Output>) async -> Void)?
    public var onError: (@Sendable (AIObjectGenerationErrorEvent) async -> Void)?

    public init(
        onStart: (@Sendable (AIObjectGenerationStartEvent) async -> Void)? = nil,
        onStepStart: (@Sendable (AIObjectGenerationStepStartEvent) async -> Void)? = nil,
        onStepFinish: (@Sendable (AIObjectGenerationStepFinishEvent) async -> Void)? = nil,
        onFinish: (@Sendable (AIObjectGenerationFinishEvent<Output>) async -> Void)? = nil,
        onError: (@Sendable (AIObjectGenerationErrorEvent) async -> Void)? = nil
    ) {
        self.onStart = onStart
        self.onStepStart = onStepStart
        self.onStepFinish = onStepFinish
        self.onFinish = onFinish
        self.onError = onError
    }
}

public struct AIObjectGenerationStartEvent: Sendable {
    public var callID: String
    public var operationID: String
    public var providerID: String
    public var modelID: String?
    public var outputKind: String
    public var request: LanguageModelRequest
    public var schema: JSONValue?
    public var schemaName: String?
    public var schemaDescription: String?
    public var maxRetries: Int

    public init(
        callID: String,
        operationID: String,
        providerID: String,
        modelID: String?,
        outputKind: String,
        request: LanguageModelRequest,
        schema: JSONValue?,
        schemaName: String?,
        schemaDescription: String?,
        maxRetries: Int
    ) {
        self.callID = callID
        self.operationID = operationID
        self.providerID = providerID
        self.modelID = modelID
        self.outputKind = outputKind
        self.request = request
        self.schema = schema
        self.schemaName = schemaName
        self.schemaDescription = schemaDescription
        self.maxRetries = maxRetries
    }
}

public struct AIObjectGenerationStepStartEvent: Sendable {
    public var callID: String
    public var stepNumber: Int
    public var providerID: String
    public var modelID: String?
    public var request: LanguageModelRequest

    public init(callID: String, stepNumber: Int, providerID: String, modelID: String?, request: LanguageModelRequest) {
        self.callID = callID
        self.stepNumber = stepNumber
        self.providerID = providerID
        self.modelID = modelID
        self.request = request
    }
}

public struct AIObjectGenerationStepFinishEvent: Sendable {
    public var callID: String
    public var stepNumber: Int
    public var providerID: String
    public var modelID: String?
    public var text: String
    public var reasoning: String
    public var finishReason: String?
    public var usage: TokenUsage?
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var responseMetadata: AIResponseMetadata

    public init(
        callID: String,
        stepNumber: Int,
        providerID: String,
        modelID: String?,
        text: String,
        reasoning: String,
        finishReason: String?,
        usage: TokenUsage?,
        warnings: [AIWarning],
        providerMetadata: [String: JSONValue],
        responseMetadata: AIResponseMetadata
    ) {
        self.callID = callID
        self.stepNumber = stepNumber
        self.providerID = providerID
        self.modelID = modelID
        self.text = text
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.usage = usage
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct AIObjectGenerationFinishEvent<Output: Sendable>: Sendable {
    public var callID: String
    public var object: Output
    public var text: String
    public var rawObject: JSONValue
    public var reasoning: String
    public var finishReason: String?
    public var usage: TokenUsage?
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var responseMetadata: AIResponseMetadata

    public init(
        callID: String,
        object: Output,
        text: String,
        rawObject: JSONValue,
        reasoning: String,
        finishReason: String?,
        usage: TokenUsage?,
        warnings: [AIWarning],
        providerMetadata: [String: JSONValue],
        responseMetadata: AIResponseMetadata
    ) {
        self.callID = callID
        self.object = object
        self.text = text
        self.rawObject = rawObject
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.usage = usage
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct AIObjectGenerationErrorEvent: Sendable {
    public var callID: String
    public var providerID: String
    public var modelID: String?
    public var text: String
    public var errorDescription: String
    public var finishReason: String?
    public var usage: TokenUsage?
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var responseMetadata: AIResponseMetadata

    public init(
        callID: String,
        providerID: String,
        modelID: String?,
        text: String,
        errorDescription: String,
        finishReason: String?,
        usage: TokenUsage?,
        warnings: [AIWarning],
        providerMetadata: [String: JSONValue],
        responseMetadata: AIResponseMetadata
    ) {
        self.callID = callID
        self.providerID = providerID
        self.modelID = modelID
        self.text = text
        self.errorDescription = errorDescription
        self.finishReason = finishReason
        self.usage = usage
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.responseMetadata = responseMetadata
    }
}

public enum ObjectStreamPart<Object: Sendable>: Sendable {
    case textDelta(String)
    case partialObject(JSONValue)
    case partial(Object)
    case object(ObjectGenerationResult<Object>)
    case warning(AIWarning)
    case source(AISource)
    case metadata([String: JSONValue])
    case responseMetadata(AIResponseMetadata)
    case raw(LanguageStreamPart)
    case finish(reason: String?, usage: TokenUsage?)
}

public struct AIObjectRepairContext: Sendable {
    public var text: String
    public var errorMessage: String

    public init(text: String, errorMessage: String) {
        self.text = text
        self.errorMessage = errorMessage
    }
}

public enum AIObjectGenerationFailureKind: String, Equatable, Sendable {
    case noJSON
    case schemaValidation
    case decoding
    case repairFailed
}

public enum AIObjectOutputStrategy: String, Equatable, Sendable {
    case object
    case array
    case enumeration
    case json
}

public struct AIObjectGenerationError: Error, Equatable, CustomStringConvertible, Sendable {
    public var provider: String
    public var strategy: AIObjectOutputStrategy
    public var kind: AIObjectGenerationFailureKind
    public var message: String
    public var path: String?
    public var text: String
    public var repairAttempted: Bool
    public var finishReason: String?
    public var usage: TokenUsage?
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var responseMetadata: AIResponseMetadata

    public init(
        provider: String,
        strategy: AIObjectOutputStrategy,
        kind: AIObjectGenerationFailureKind,
        message: String,
        path: String? = nil,
        text: String,
        repairAttempted: Bool = false,
        finishReason: String? = nil,
        usage: TokenUsage? = nil,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.provider = provider
        self.strategy = strategy
        self.kind = kind
        self.message = message
        self.path = path
        self.text = text
        self.repairAttempted = repairAttempted
        self.finishReason = finishReason
        self.usage = usage
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.responseMetadata = responseMetadata
    }

    public var description: String {
        let pathSuffix = path.map { " at \($0)" } ?? ""
        let repairSuffix = repairAttempted ? " after repair" : ""
        return "\(provider) did not generate a valid \(strategy.rawValue)\(repairSuffix): \(kind.rawValue)\(pathSuffix): \(message)"
    }
}