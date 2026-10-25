import Foundation
import SwiftAIProvider
import SwiftAITransport


public struct AIWarningLogEvent: Equatable, Sendable {
    public var warnings: [AIWarning]
    public var providerID: String?
    public var modelID: String?

    public init(warnings: [AIWarning], providerID: String? = nil, modelID: String? = nil) {
        self.warnings = warnings
        self.providerID = providerID
        self.modelID = modelID
    }
}

public protocol AIWarningLogger: Sendable {
    func logWarnings(_ event: AIWarningLogEvent) async
}

public struct AIConsoleWarningLogger: AIWarningLogger {
    public init() {}

    public func logWarnings(_ event: AIWarningLogEvent) async {
        for warning in event.warnings {
            let code = warning.type == "deprecated" ? aiDeprecationCode(setting: warning.setting ?? "", provider: event.providerID) : nil
            if let code, !AIWarningLogging.emittedDeprecations.insert(code) { continue }
            let message = (code.map { "[\($0)] " } ?? "") + AIWarningLogging.formattedMessage(for: warning, providerID: event.providerID, modelID: event.modelID) + "\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }
}

public enum AIWarningLogging {
    @TaskLocal private static var scopedState: AIWarningLoggingScopedState?

    private static let registry = AIWarningLoggingRegistry()
    static let emittedDeprecations = AIDeprecationEmissionState()

    public static func useDefaultLogger() {
        registry.useDefaultLogger()
    }

    public static func useLogger(_ logger: any AIWarningLogger) {
        registry.useLogger(logger)
    }

    public static func disable() {
        registry.disable()
    }

    public static func withLogger<Result>(
        _ logger: any AIWarningLogger,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $scopedState.withValue(.custom(logger)) {
            try await operation()
        }
    }

    public static func withLoggingDisabled<Result>(
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $scopedState.withValue(.disabled) {
            try await operation()
        }
    }

    public static func formattedMessage(for warning: AIWarning, providerID: String? = nil, modelID: String? = nil) -> String {
        let scope = providerID.flatMap { provider in
            modelID.map { model in " (\(provider) / \(model))" }
        } ?? ""
        let prefix = "AI SDK Warning\(scope):"

        switch warning.type {
        case "unsupported":
            if let feature = warning.feature {
                return "\(prefix) The feature \"\(feature)\" is not supported.\(warning.message.map { " \($0)" } ?? "")"
            }
            return "\(prefix) The requested feature is not supported.\(warning.message.map { " \($0)" } ?? "")"
        case "compatibility":
            if let feature = warning.feature {
                return "\(prefix) The feature \"\(feature)\" is used in a compatibility mode.\(warning.message.map { " \($0)" } ?? "")"
            }
            return "\(prefix) A feature is used in a compatibility mode.\(warning.message.map { " \($0)" } ?? "")"
        case "deprecated":
            let setting = warning.setting.map { "\"\($0)\"" } ?? "a setting"
            return "\(prefix) Deprecated: \(setting). \(warning.message ?? "")"
        case "other":
            return "\(prefix) \(warning.message ?? "A provider warning was returned.")"
        default:
            return "\(prefix) \(warning.type)\(warning.message.map { ": \($0)" } ?? "")"
        }
    }

    package static func logWarnings(_ warnings: [AIWarning], providerID: String?, modelID: String?) async {
        let event = AIWarningLogEvent(warnings: warnings, providerID: providerID, modelID: modelID)
        switch scopedState {
        case let .custom(logger):
            await logger.logWarnings(event)
        case .disabled:
            return
        case nil:
            await registry.logWarnings(event)
        }
    }

    static func resetForTesting() {
        registry.resetForTesting()
        emittedDeprecations.reset()
    }
}

package enum AIDeprecationLogging {
    @TaskLocal package static var suppressObjectWarnings = false

    package static func objectWarning(_ setting: String) async {
        guard !suppressObjectWarnings else { return }
        await AIWarningLogging.logWarnings([AIWarning(type: "deprecated", setting: setting,
            message: "Use \(setting == "generateObject" ? "generateText" : "streamText") with an output setting instead.")], providerID: nil, modelID: nil)
    }
}

final class AIDeprecationEmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: Set<String> = []
    func insert(_ code: String) -> Bool { lock.withLock { codes.insert(code).inserted } }
    func reset() { lock.withLock { codes.removeAll() } }
}

func aiDeprecationCode(setting: String, provider: String? = nil) -> String {
    func encoded(_ text: String) -> String {
        text.utf16.map { unit in
            if (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) {
                return String(UnicodeScalar(Int(unit))!)
            }
            return "_" + String(format: "%04X", unit)
        }.joined()
    }
    if let provider { return "AISDK_DEP_PROVIDER_\(encoded(provider))__\(encoded(setting))" }
    let fixed: [String: String] = [
        "generateObject": "GENERATE_OBJECT", "streamObject": "STREAM_OBJECT",
        "experimental_generateSpeech": "EXPERIMENTAL_GENERATE_SPEECH", "experimental_transcribe": "EXPERIMENTAL_TRANSCRIBE",
        "\"image\" content part": "IMAGE_CONTENT_PART",
        "rawInput in output-error UI message parts": "UI_MESSAGE_RAW_INPUT"
    ]
    if let code = fixed[setting] { return "AISDK_DEP_\(code)" }
    for kind in ["file-data", "file-url", "file-id", "file-reference", "image-data", "image-url", "image-file-id", "image-file-reference"] {
        if setting == "\"tool-result\" content of type \"\(kind)\"" {
            return "AISDK_DEP_TOOL_RESULT_" + kind.uppercased().replacingOccurrences(of: "-", with: "_")
        }
    }
    return "AISDK_DEP_SETTING_\(encoded(setting))"
}

private enum AIWarningLoggingScopedState: Sendable {
    case custom(any AIWarningLogger)
    case disabled
}

private final class AIWarningLoggingRegistry: @unchecked Sendable {
    private enum State {
        case defaultLogger
        case custom(any AIWarningLogger)
        case disabled
    }

    private let lock = NSLock()
    private var state: State = .defaultLogger

    func useDefaultLogger() {
        lock.lock()
        state = .defaultLogger
        lock.unlock()
    }

    func useLogger(_ logger: any AIWarningLogger) {
        lock.lock()
        state = .custom(logger)
        lock.unlock()
    }

    func disable() {
        lock.lock()
        state = .disabled
        lock.unlock()
    }

    func logWarnings(_ event: AIWarningLogEvent) async {
        switch currentState() {
        case .defaultLogger:
            await AIConsoleWarningLogger().logWarnings(event)
        case let .custom(logger):
            await logger.logWarnings(event)
        case .disabled:
            return
        }
    }

    func resetForTesting() {
        useDefaultLogger()
    }

    private func currentState() -> State {
        lock.lock()
        let current = state
        lock.unlock()
        return current
    }
}