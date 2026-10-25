import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public enum Telemetry {
    public struct Event: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case start
            case retry
            case end
            case abort
            case error
            case modelCallStart
            case modelCallEnd
            case stepStart
            case stepEnd
            case toolStart
            case toolEnd
            case toolError
        }

        public var kind: Kind
        public var callID: String
        public var operationID: String
        public var providerID: String
        public var modelID: String?
        public var functionID: String?
        public var attempt: Int?
        public var maxRetries: Int?
        public var delayNanoseconds: UInt64?
        public var durationNanoseconds: UInt64?
        public var input: JSONValue?
        public var output: JSONValue?
        public var usage: TokenUsage?
        /// Native audio usage, such as characters, seconds, or provider counters.
        public var providerUsage: [String: JSONValue]? = nil
        public var warnings: [AIWarning]
        public var providerMetadata: [String: JSONValue]
        public var responseMetadata: AIResponseMetadata
        public var errorDescription: String?
        public var metadata: [String: JSONValue]
        public var runtimeContext: [String: JSONValue]
        public var includesInput: Bool
        public var includesOutput: Bool

        public init(
            kind: Kind,
            callID: String,
            operationID: String,
            providerID: String,
            modelID: String? = nil,
            functionID: String? = nil,
            attempt: Int? = nil,
            maxRetries: Int? = nil,
            delayNanoseconds: UInt64? = nil,
            durationNanoseconds: UInt64? = nil,
            input: JSONValue? = nil,
            output: JSONValue? = nil,
            usage: TokenUsage? = nil,
            warnings: [AIWarning] = [],
            providerMetadata: [String: JSONValue] = [:],
            responseMetadata: AIResponseMetadata = AIResponseMetadata(),
            errorDescription: String? = nil,
            metadata: [String: JSONValue] = [:],
            runtimeContext: [String: JSONValue] = [:],
            includesInput: Bool = true,
            includesOutput: Bool = true
        ) {
            self.kind = kind
            self.callID = callID
            self.operationID = operationID
            self.providerID = providerID
            self.modelID = modelID
            self.functionID = functionID
            self.attempt = attempt
            self.maxRetries = maxRetries
            self.delayNanoseconds = delayNanoseconds
            self.durationNanoseconds = durationNanoseconds
            self.input = input
            self.output = output
            self.usage = usage
            self.warnings = warnings
            self.providerMetadata = providerMetadata
            self.responseMetadata = responseMetadata
            self.errorDescription = errorDescription
            self.metadata = metadata
            self.runtimeContext = runtimeContext
            self.includesInput = includesInput
            self.includesOutput = includesOutput
        }

        /// Source-compatible initializer retained from SwiftAISDK 1.9.0,
        /// before events could carry a filtered runtime context.
        public init(
            kind: Kind,
            callID: String,
            operationID: String,
            providerID: String,
            modelID: String? = nil,
            functionID: String? = nil,
            attempt: Int? = nil,
            maxRetries: Int? = nil,
            delayNanoseconds: UInt64? = nil,
            durationNanoseconds: UInt64? = nil,
            input: JSONValue? = nil,
            output: JSONValue? = nil,
            usage: TokenUsage? = nil,
            warnings: [AIWarning] = [],
            providerMetadata: [String: JSONValue] = [:],
            responseMetadata: AIResponseMetadata = AIResponseMetadata(),
            errorDescription: String? = nil,
            metadata: [String: JSONValue] = [:],
            includesInput: Bool = true,
            includesOutput: Bool = true
        ) {
            self.init(
                kind: kind,
                callID: callID,
                operationID: operationID,
                providerID: providerID,
                modelID: modelID,
                functionID: functionID,
                attempt: attempt,
                maxRetries: maxRetries,
                delayNanoseconds: delayNanoseconds,
                durationNanoseconds: durationNanoseconds,
                input: input,
                output: output,
                usage: usage,
                warnings: warnings,
                providerMetadata: providerMetadata,
                responseMetadata: responseMetadata,
                errorDescription: errorDescription,
                metadata: metadata,
                runtimeContext: [:],
                includesInput: includesInput,
                includesOutput: includesOutput
            )
        }
    }

    public protocol Integration: Sendable {
        func record(_ event: Event) async
        func executeLanguageModelCall<Output: Sendable>(_ context: LanguageModelCallContext<Output>) async throws -> Output
        func executeTool<Output: Sendable>(_ context: ToolExecutionContext<Output>) async throws -> Output
    }

    public struct LanguageModelCallContext<Output: Sendable>: Sendable {
        public var callID: String
        public var operationID: String
        public var providerID: String
        public var modelID: String?
        public var execute: @Sendable () async throws -> Output

        public init(
            callID: String,
            operationID: String,
            providerID: String,
            modelID: String? = nil,
            execute: @escaping @Sendable () async throws -> Output
        ) {
            self.callID = callID
            self.operationID = operationID
            self.providerID = providerID
            self.modelID = modelID
            self.execute = execute
        }
    }

    public struct ToolExecutionContext<Output: Sendable>: Sendable {
        public var callID: String
        public var toolCallID: String
        public var toolName: String
        public var execute: @Sendable () async throws -> Output

        public init(
            callID: String,
            toolCallID: String,
            toolName: String,
            execute: @escaping @Sendable () async throws -> Output
        ) {
            self.callID = callID
            self.toolCallID = toolCallID
            self.toolName = toolName
            self.execute = execute
        }
    }

    public struct Options: Sendable {
        public var isEnabled: Bool
        public var includesInput: Bool
        public var includesOutput: Bool
        public var functionID: String?
        public var metadata: [String: JSONValue]
        public var includeRuntimeContext: [String: Bool]?
        public var integrations: [any Integration]?

        public init(
            isEnabled: Bool = true,
            includesInput: Bool = true,
            includesOutput: Bool = true,
            functionID: String? = nil,
            metadata: [String: JSONValue] = [:],
            includeRuntimeContext: [String: Bool]? = nil,
            integrations: [any Integration]? = nil
        ) {
            self.isEnabled = isEnabled
            self.includesInput = includesInput
            self.includesOutput = includesOutput
            self.functionID = functionID
            self.metadata = metadata
            self.includeRuntimeContext = includeRuntimeContext
            self.integrations = integrations
        }

        /// Source-compatible initializer retained from SwiftAISDK 1.9.0,
        /// before telemetry options selected runtime-context fields.
        public init(
            isEnabled: Bool = true,
            includesInput: Bool = true,
            includesOutput: Bool = true,
            functionID: String? = nil,
            metadata: [String: JSONValue] = [:],
            integrations: [any Integration]? = nil
        ) {
            self.init(
                isEnabled: isEnabled,
                includesInput: includesInput,
                includesOutput: includesOutput,
                functionID: functionID,
                metadata: metadata,
                includeRuntimeContext: nil,
                integrations: integrations
            )
        }

        public static let disabled = Options(isEnabled: false)
    }

    private static let registry = Registry()

    public static func register(_ integrations: any Integration...) {
        registry.register(integrations)
    }

    public static func register(_ integrations: [any Integration]) {
        registry.register(integrations)
    }

    public static func registeredIntegrations() -> [any Integration] {
        registry.integrations()
    }

    static func removeAllIntegrations() {
        registry.removeAll()
    }
}

public extension Telemetry.Integration {
    func executeLanguageModelCall<Output: Sendable>(_ context: Telemetry.LanguageModelCallContext<Output>) async throws -> Output {
        try await context.execute()
    }

    func executeTool<Output: Sendable>(_ context: Telemetry.ToolExecutionContext<Output>) async throws -> Output {
        try await context.execute()
    }
}


private final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [any Telemetry.Integration] = []

    func register(_ integrations: [any Telemetry.Integration]) {
        lock.lock()
        values.append(contentsOf: integrations)
        lock.unlock()
    }

    func integrations() -> [any Telemetry.Integration] {
        lock.lock()
        let result = values
        lock.unlock()
        return result
    }

    func removeAll() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}