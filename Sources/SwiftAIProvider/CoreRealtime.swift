import Foundation


/// Audio format configuration shared by realtime V4 model implementations.
public struct AIRealtimeAudioFormat: Equatable, Hashable, Sendable {
    public var type: String
    public var rate: Int?

    public init(type: String, rate: Int? = nil) {
        self.type = type
        self.rate = rate
    }

    public init(_ format: AIStreamingAudioFormat) {
        self.init(type: format.mediaType, rate: format.sampleRate)
    }
}

public enum AIRealtimeOutputModality: String, Equatable, Hashable, Sendable {
    case text
    case audio
}

public struct AIRealtimeAudioTranscriptionConfiguration:
    Equatable,
    Sendable {
    public var model: String?
    public var language: String?
    public var prompt: String?

    public init(
        model: String? = nil,
        language: String? = nil,
        prompt: String? = nil
    ) {
        self.model = model
        self.language = language
        self.prompt = prompt
    }
}

public enum AIRealtimeTurnDetectionType:
    String,
    Equatable,
    Hashable,
    Sendable {
    case serverVAD = "server-vad"
    case semanticVAD = "semantic-vad"
    case disabled
}

public struct AIRealtimeTurnDetectionConfiguration: Equatable, Sendable {
    public var type: AIRealtimeTurnDetectionType
    public var threshold: Double?
    public var silenceDurationMilliseconds: Int?
    public var prefixPaddingMilliseconds: Int?

    public init(
        type: AIRealtimeTurnDetectionType,
        threshold: Double? = nil,
        silenceDurationMilliseconds: Int? = nil,
        prefixPaddingMilliseconds: Int? = nil
    ) {
        self.type = type
        self.threshold = threshold
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.prefixPaddingMilliseconds = prefixPaddingMilliseconds
    }
}

public struct AIRealtimeToolDefinition: Equatable, Sendable {
    public var type: String
    public var name: String
    public var description: String?
    public var parameters: JSONValue

    public init(
        type: String = "function",
        name: String,
        description: String? = nil,
        parameters: JSONValue
    ) {
        self.type = type
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Provider-neutral configuration for a realtime V4 session.
public struct AIRealtimeSessionConfiguration: Equatable, Sendable {
    public var instructions: String?
    public var voice: String?
    public var outputModalities: [AIRealtimeOutputModality]?
    public var inputAudioFormat: AIRealtimeAudioFormat?
    public var inputAudioTranscription:
        AIRealtimeAudioTranscriptionConfiguration?
    public var outputAudioTranscription:
        AIRealtimeAudioTranscriptionConfiguration?
    public var outputAudioFormat: AIRealtimeAudioFormat?
    public var turnDetection: AIRealtimeTurnDetectionConfiguration?
    public var tools: [AIRealtimeToolDefinition]?
    public var providerOptions: [String: JSONValue]?

    public init(
        instructions: String? = nil,
        voice: String? = nil,
        outputModalities: [AIRealtimeOutputModality]? = nil,
        inputAudioFormat: AIRealtimeAudioFormat? = nil,
        inputAudioTranscription:
            AIRealtimeAudioTranscriptionConfiguration? = nil,
        outputAudioTranscription:
            AIRealtimeAudioTranscriptionConfiguration? = nil,
        outputAudioFormat: AIRealtimeAudioFormat? = nil,
        turnDetection: AIRealtimeTurnDetectionConfiguration? = nil,
        tools: [AIRealtimeToolDefinition]? = nil,
        providerOptions: [String: JSONValue]? = nil
    ) {
        self.instructions = instructions
        self.voice = voice
        self.outputModalities = outputModalities
        self.inputAudioFormat = inputAudioFormat
        self.inputAudioTranscription = inputAudioTranscription
        self.outputAudioTranscription = outputAudioTranscription
        self.outputAudioFormat = outputAudioFormat
        self.turnDetection = turnDetection
        self.tools = tools
        self.providerOptions = providerOptions
    }
}

public struct AIRealtimeClientSecretOptions: Equatable, Sendable {
    public var expiresAfterSeconds: Int?
    public var sessionConfig: AIRealtimeSessionConfiguration?
    public var abortSignal: AIAbortSignal?

    public init(
        expiresAfterSeconds: Int? = nil,
        sessionConfig: AIRealtimeSessionConfiguration? = nil,
        abortSignal: AIAbortSignal? = nil
    ) {
        self.expiresAfterSeconds = expiresAfterSeconds
        self.sessionConfig = sessionConfig
        self.abortSignal = abortSignal
    }

    public static func == (
        lhs: AIRealtimeClientSecretOptions,
        rhs: AIRealtimeClientSecretOptions
    ) -> Bool {
        lhs.expiresAfterSeconds == rhs.expiresAfterSeconds
            && lhs.sessionConfig == rhs.sessionConfig
            && lhs.abortSignal === rhs.abortSignal
    }
}

public struct AIRealtimeClientSecretResult: Equatable, Sendable {
    public var token: String
    public var url: String
    public var expiresAt: Int?

    public init(token: String, url: String, expiresAt: Int? = nil) {
        self.token = token
        self.url = url
        self.expiresAt = expiresAt
    }
}

public struct AIRealtimeWebSocketConfiguration: Equatable, Sendable {
    public var url: String
    public var protocols: [String]
    public var headers: [String: String]

    public init(
        url: String,
        protocols: [String] = [],
        headers: [String: String] = [:]
    ) {
        self.url = url
        self.protocols = protocols
        self.headers = headers
    }
}

public enum AIRealtimeConversationMode: String, Equatable, Sendable {
    case continuous
    case turnBased = "turn-based"
}

public enum AIRealtimeTransportKind: String, Equatable, Sendable {
    case webSocket = "websocket"
    case webRTC = "webrtc"
}

public enum AIRealtimeConnectionKind: String, Equatable, Sendable {
    /// Browser provider-owned media transport; descriptive only in the native WebSocket runner.
    case provider
    case clientSecretWebSocket = "client-secret-websocket"
    case serverWebSocket = "server-websocket"
    case webRTC = "webrtc"
}

public enum AIRealtimeStartupMode: String, Equatable, Sendable {
    case sessionStart = "session-start"
    case sessionUpdate = "session-update"
}

public enum AIRealtimeFinalizationMode: String, Equatable, Sendable {
    case sessionClose = "session-close"
    case transportClose = "transport-close"
}

/// Conversation and transport behavior declared by a realtime V4 model.
public struct AIRealtimeModelCapabilities: Equatable, Sendable {
    public var conversation: AIRealtimeConversationMode
    public var transports: [AIRealtimeTransportKind]
    public var connections: [AIRealtimeConnectionKind]?
    public var startup: AIRealtimeStartupMode?
    public var finalization: AIRealtimeFinalizationMode?

    public init(
        conversation: AIRealtimeConversationMode,
        transports: [AIRealtimeTransportKind],
        connections: [AIRealtimeConnectionKind]? = nil,
        startup: AIRealtimeStartupMode? = nil,
        finalization: AIRealtimeFinalizationMode? = nil
    ) {
        self.conversation = conversation
        self.transports = transports
        self.connections = connections
        self.startup = startup
        self.finalization = finalization
    }
}

public enum AIRealtimeDelegationMode: String, Equatable, Sendable {
    case client
    case provider
}

public enum AIRealtimeTranscriptSpeaker: String, Equatable, Sendable {
    case user
    case assistant
}

/// Raw provider token counts; cached counts are subsets of the gross input counts.
/// Session snapshots without a response association must not be summed as increments.
public struct AIRealtimeUsage: Equatable, Sendable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var inputTextTokens: Int?
    public var inputAudioTokens: Int?
    public var outputTextTokens: Int?
    public var outputAudioTokens: Int?
    public var cachedInputTextTokens: Int?
    public var cachedInputAudioTokens: Int?
    public var seconds: Double?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil, inputTextTokens: Int? = nil, inputAudioTokens: Int? = nil, outputTextTokens: Int? = nil, outputAudioTokens: Int? = nil, cachedInputTextTokens: Int? = nil, cachedInputAudioTokens: Int? = nil, seconds: Double? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cachedInputTokens = cachedInputTokens
        self.inputTextTokens = inputTextTokens; self.inputAudioTokens = inputAudioTokens
        self.outputTextTokens = outputTextTokens; self.outputAudioTokens = outputAudioTokens
        self.cachedInputTextTokens = cachedInputTextTokens; self.cachedInputAudioTokens = cachedInputAudioTokens; self.seconds = seconds
    }
}

public enum AIRealtimeSessionIntent: String, Codable, Sendable {
    case conversation
    case transcription
}

public struct AIRealtimeSessionUsage: Equatable, Sendable {
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }
}

public enum AIRealtimeConversationItem: Equatable, Sendable {
    case textMessage(text: String)
    case audioMessage(audio: String)
    case functionCallOutput(callID: String, name: String?, output: String)
}

public struct AIRealtimeResponseOptions: Equatable, Sendable {
    public var modalities: [String]?
    public var instructions: String?
    public var metadata: [String: JSONValue]?

    public init(
        modalities: [String]? = nil,
        instructions: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.modalities = modalities
        self.instructions = instructions
        self.metadata = metadata
    }
}

/// Provider-neutral events sent from a realtime client to a V4 model.
public enum AIRealtimeClientEvent: Equatable, Sendable {
    case sessionUpdate(AIRealtimeSessionConfiguration)
    case sessionUpdateWithEventID(
        AIRealtimeSessionConfiguration,
        eventID: String
    )
    case sessionStart(
        AIRealtimeSessionConfiguration,
        eventID: String? = nil
    )
    case sessionClose(eventID: String? = nil)
    case inputAudioMute(eventID: String? = nil)
    case inputAudioUnmute(eventID: String? = nil)
    case contextAppend(
        content: String,
        delegationID: String?,
        eventID: String? = nil,
        providerOptions: [String: JSONValue]? = nil
    )
    case inputAudioAppend(audio: String)
    case inputAudioAppendWithEventID(audio: String, eventID: String)
    case inputAudioCommit
    case inputAudioClear
    case conversationItemCreate(AIRealtimeConversationItem)
    case conversationItemTruncate(
        itemID: String,
        contentIndex: Int,
        audioEndMilliseconds: Int
    )
    case responseCreate(options: AIRealtimeResponseOptions? = nil)
    case responseCancel
}

/// A serialized provider message ready for a duplex WebSocket connection.
public enum AIRealtimeWireMessage: Equatable, Sendable {
    case json(JSONValue)
    case text(String)
    case binary(Data)
}

/// Normalized events emitted by a realtime V4 model.
public enum AIRealtimeServerEvent: Equatable, Sendable {
    case sessionStarted(
        sessionID: String,
        delegationMode: AIRealtimeDelegationMode?,
        raw: JSONValue
    )
    case sessionClosed(
        sessionID: String?,
        usage: AIRealtimeSessionUsage,
        reason: String,
        raw: JSONValue
    )
    case sessionUsage(
        usage: AIRealtimeSessionUsage,
        contextWindowUsageRatio: Double?,
        raw: JSONValue
    )
    case audioChunk(delta: String, raw: JSONValue)
    case transcriptFragment(
        speaker: AIRealtimeTranscriptSpeaker,
        delta: String,
        startMilliseconds: Double,
        endMilliseconds: Double,
        raw: JSONValue
    )
    case delegationCreated(
        delegationID: String,
        target: AIRealtimeDelegationMode?,
        offsetMilliseconds: Double?,
        responseID: String?,
        raw: JSONValue
    )
    case commandAcknowledged(
        command: String,
        clientEventID: String?,
        raw: JSONValue
    )
    case sessionCreated(sessionID: String?, raw: JSONValue)
    case sessionUpdated(raw: JSONValue)
    case speechStarted(itemID: String?, raw: JSONValue)
    case speechStopped(itemID: String?, raw: JSONValue)
    case audioCommitted(
        itemID: String?,
        previousItemID: String?,
        raw: JSONValue
    )
    case conversationItemAdded(
        itemID: String,
        item: JSONValue,
        raw: JSONValue
    )
    case inputTranscriptionCompleted(
        itemID: String,
        transcript: String,
        raw: JSONValue
    )
    case responseCreated(responseID: String, raw: JSONValue)
    case responseDone(responseID: String, status: String, raw: JSONValue)
    case outputItemAdded(
        responseID: String,
        itemID: String,
        raw: JSONValue
    )
    case outputItemDone(
        responseID: String,
        itemID: String,
        raw: JSONValue
    )
    case contentPartAdded(
        responseID: String,
        itemID: String,
        raw: JSONValue
    )
    case contentPartDone(
        responseID: String,
        itemID: String,
        raw: JSONValue
    )
    case audioDelta(
        responseID: String,
        itemID: String,
        delta: String,
        raw: JSONValue
    )
    case audioDone(responseID: String, itemID: String, raw: JSONValue)
    case audioTranscriptDelta(
        responseID: String,
        itemID: String,
        delta: String,
        raw: JSONValue
    )
    case audioTranscriptDone(
        responseID: String,
        itemID: String,
        transcript: String?,
        raw: JSONValue
    )
    case textDelta(
        responseID: String,
        itemID: String,
        delta: String,
        raw: JSONValue
    )
    case textDone(
        responseID: String,
        itemID: String,
        text: String?,
        raw: JSONValue
    )
    case functionCallArgumentsDelta(
        responseID: String,
        itemID: String,
        callID: String,
        delta: String,
        raw: JSONValue
    )
    case functionCallArgumentsDone(
        responseID: String,
        itemID: String,
        callID: String,
        name: String,
        arguments: String,
        raw: JSONValue
    )
    case error(message: String, code: String?, raw: JSONValue)
    case correlatedError(
        message: String,
        code: String?,
        clientEventID: String,
        raw: JSONValue
    )
    case custom(rawType: String, raw: JSONValue)
}

public extension AIRealtimeServerEvent {
    /// Provider-reported usage for this event. Unassociated snapshots are not increments.
    /// The original event and its associated-value shape remain unchanged.
    var usage: AIRealtimeUsage? {
        switch self {
        case let .inputTranscriptionCompleted(_, _, raw): return realtimeUsageFromRaw(raw["usage"], transcription: true)
        case let .responseDone(_, _, raw):
            return realtimeUsageFromRaw(raw["usage"] ?? raw["response"]?["usage"])
                ?? googleRealtimeUsage(raw["usageMetadata"])
        case let .custom(rawType, raw):
            return realtimeUsageFromRaw(raw["usage"])
                ?? (rawType == "usageMetadata" ? googleRealtimeUsage(raw["usageMetadata"]) : nil)
        case let .sessionClosed(_, usage, _, _), let .sessionUsage(usage, _, _): return .init(seconds: usage.seconds)
        default: return nil
        }
    }
}

private func googleRealtimeUsage(_ raw: JSONValue?) -> AIRealtimeUsage? {
    guard let raw, raw.objectValue != nil else { return nil }
    func total(_ base: String, adding extra: String) -> Int? {
        guard let count = raw[base]?.intValue else { return nil }
        let (sum, overflow) = count.addingReportingOverflow(raw[extra]?.intValue ?? 0)
        return overflow ? nil : sum
    }
    func modality(_ field: String, _ name: String) -> Int? {
        var sum: Int?
        for detail in raw[field]?.arrayValue ?? [] {
            guard detail["modality"]?.stringValue?.uppercased() == name,
                  let count = detail["tokenCount"]?.intValue else { continue }
            let (next, overflow) = (sum ?? 0).addingReportingOverflow(count)
            guard !overflow else { return nil }
            sum = next
        }
        return sum
    }
    let result = AIRealtimeUsage(
        inputTokens: total("promptTokenCount", adding: "toolUsePromptTokenCount"),
        outputTokens: total("responseTokenCount", adding: "thoughtsTokenCount"),
        cachedInputTokens: raw["cachedContentTokenCount"]?.intValue,
        inputTextTokens: modality("promptTokensDetails", "TEXT"),
        inputAudioTokens: modality("promptTokensDetails", "AUDIO"),
        outputTextTokens: modality("responseTokensDetails", "TEXT"),
        outputAudioTokens: modality("responseTokensDetails", "AUDIO")
    )
    return result == AIRealtimeUsage() ? nil : result
}

private func realtimeUsageFromRaw(_ raw: JSONValue?, transcription: Bool = false) -> AIRealtimeUsage? {
    guard let raw, raw.objectValue != nil else { return nil }
    if transcription && raw["type"]?.stringValue == "duration" { return raw["seconds"]?.doubleValue.map { .init(seconds: $0) } }
    let normalized = AIRealtimeUsage(inputTokens: raw["inputTokens"]?.intValue, outputTokens: raw["outputTokens"]?.intValue, cachedInputTokens: raw["cachedInputTokens"]?.intValue, inputTextTokens: raw["inputTextTokens"]?.intValue, inputAudioTokens: raw["inputAudioTokens"]?.intValue, outputTextTokens: raw["outputTextTokens"]?.intValue, outputAudioTokens: raw["outputAudioTokens"]?.intValue, cachedInputTextTokens: raw["cachedInputTextTokens"]?.intValue, cachedInputAudioTokens: raw["cachedInputAudioTokens"]?.intValue, seconds: raw["seconds"]?.doubleValue)
    if normalized != AIRealtimeUsage() { return normalized }
    let input = raw["input_token_details"]
    let output = raw["output_token_details"]
    let cached = input?["cached_tokens_details"]
    let result = AIRealtimeUsage(inputTokens: raw["input_tokens"]?.intValue, outputTokens: raw["output_tokens"]?.intValue,
        cachedInputTokens: transcription ? nil : input?["cached_tokens"]?.intValue,
        inputTextTokens: input?["text_tokens"]?.intValue, inputAudioTokens: input?["audio_tokens"]?.intValue,
        outputTextTokens: transcription ? raw["output_tokens"]?.intValue : output?["text_tokens"]?.intValue,
        outputAudioTokens: transcription ? nil : output?["audio_tokens"]?.intValue,
        cachedInputTextTokens: transcription ? nil : cached?["text_tokens"]?.intValue,
        cachedInputAudioTokens: transcription ? nil : cached?["audio_tokens"]?.intValue)
    return result == AIRealtimeUsage() ? nil : result
}

/// Optional throwing validation hooks for models whose configuration cannot be
/// represented safely by the released nonthrowing V4 requirements.
public protocol AIRealtimeModelV4ValidationHooks: Sendable {
    func getValidatedWebSocketConfig(token: String, url: String) throws
        -> AIRealtimeWebSocketConfiguration
    func buildValidatedSessionConfig(
        _ config: AIRealtimeSessionConfiguration
    ) throws -> JSONValue
}

public typealias AIRealtimeServerEventParser =
    @Sendable (JSONValue) -> [AIRealtimeServerEvent]

/// Provider V4 contract for bidirectional audio/text realtime models.
public protocol AIRealtimeModelV4: Sendable {
    var specificationVersion: String { get }
    var providerID: String { get }
    var modelID: String { get }
    var capabilities: AIRealtimeModelCapabilities? { get }

    func getServerWebSocketConfig() throws
        -> AIRealtimeWebSocketConfiguration

    func getResolvedServerWebSocketConfig() async throws
        -> AIRealtimeWebSocketConfiguration

    func getServerWebSocketConfig(intent: AIRealtimeSessionIntent) throws -> AIRealtimeWebSocketConfiguration
    func getResolvedServerWebSocketConfig(intent: AIRealtimeSessionIntent) async throws -> AIRealtimeWebSocketConfiguration
    func serializeClientEvent(_ event: AIRealtimeClientEvent, intent: AIRealtimeSessionIntent) async throws -> AIRealtimeWireMessage?
    func buildSessionConfig(_ config: AIRealtimeSessionConfiguration, intent: AIRealtimeSessionIntent) throws -> JSONValue

    func doCreateClientSecret(
        _ options: AIRealtimeClientSecretOptions
    ) async throws -> AIRealtimeClientSecretResult

    func getWebSocketConfig(
        token: String,
        url: String
    ) -> AIRealtimeWebSocketConfiguration

    func parseServerEvent(_ raw: JSONValue) -> [AIRealtimeServerEvent]

    func createServerEventParser() -> AIRealtimeServerEventParser

    func serializeClientEvent(
        _ event: AIRealtimeClientEvent
    ) async throws -> AIRealtimeWireMessage?

    func buildSessionConfig(
        _ config: AIRealtimeSessionConfiguration
    ) -> JSONValue

    func getHealthCheckResponse(
        _ raw: JSONValue
    ) async throws -> AIRealtimeWireMessage?
}

public extension AIRealtimeModelV4 {
    var specificationVersion: String { "v4" }
    var provider: String { providerID }
    var capabilities: AIRealtimeModelCapabilities? { nil }

    func getServerWebSocketConfig(intent: AIRealtimeSessionIntent) throws -> AIRealtimeWebSocketConfiguration {
        try validateRealtimeIntent(intent)
        return try getServerWebSocketConfig()
    }
    func getResolvedServerWebSocketConfig(intent: AIRealtimeSessionIntent) async throws -> AIRealtimeWebSocketConfiguration {
        if intent == .conversation { return try await getResolvedServerWebSocketConfig() }
        return try getServerWebSocketConfig(intent: intent)
    }
    func serializeClientEvent(_ event: AIRealtimeClientEvent, intent: AIRealtimeSessionIntent) async throws -> AIRealtimeWireMessage? {
        try validateRealtimeIntent(intent)
        return try await serializeClientEvent(event)
    }
    func buildSessionConfig(_ config: AIRealtimeSessionConfiguration, intent: AIRealtimeSessionIntent) throws -> JSONValue {
        try validateRealtimeIntent(intent)
        return buildSessionConfig(config)
    }
    private func validateRealtimeIntent(_ intent: AIRealtimeSessionIntent) throws {
        guard intent == .conversation else { throw AIError.invalidArgument(argument: "intent", message: "The realtime model does not support transcription intent.") }
    }

    /// The asynchronous connection hook permits per-connection credentials while
    /// retaining the synchronous hook for existing static-credential models.
    func getResolvedServerWebSocketConfig() async throws
        -> AIRealtimeWebSocketConfiguration {
        try getServerWebSocketConfig()
    }

    func getServerWebSocketConfig() throws
        -> AIRealtimeWebSocketConfiguration {
        throw AIError.invalidArgument(
            argument: "model",
            message: "The realtime model does not support server WebSocket connections."
        )
    }

    func doCreateClientSecret(
        _ options: AIRealtimeClientSecretOptions
    ) async throws -> AIRealtimeClientSecretResult {
        throw AIError.invalidArgument(
            argument: "model",
            message: "The realtime model does not support client-secret WebSocket connections."
        )
    }

    func createClientSecret(
        _ options: AIRealtimeClientSecretOptions = .init()
    ) async throws -> AIRealtimeClientSecretResult {
        try await doCreateClientSecret(options)
    }

    func parseServerEvent(_ raw: JSONValue) -> [AIRealtimeServerEvent] {
        [.custom(rawType: raw["type"]?.stringValue ?? "", raw: raw)]
    }

    func createServerEventParser() -> AIRealtimeServerEventParser {
        { [self] raw in parseServerEvent(raw) }
    }

    func getValidatedWebSocketConfig(
        token: String,
        url: String
    ) throws -> AIRealtimeWebSocketConfiguration {
        if let hooks = self as? any AIRealtimeModelV4ValidationHooks {
            return try hooks.getValidatedWebSocketConfig(
                token: token,
                url: url
            )
        }
        return getWebSocketConfig(token: token, url: url)
    }

    func buildValidatedSessionConfig(
        _ config: AIRealtimeSessionConfiguration
    ) throws -> JSONValue {
        if let hooks = self as? any AIRealtimeModelV4ValidationHooks {
            return try hooks.buildValidatedSessionConfig(config)
        }
        return buildSessionConfig(config)
    }

    func getHealthCheckResponse(
        _ raw: JSONValue
    ) async throws -> AIRealtimeWireMessage? {
        nil
    }
}


/// Mirrors the experimental naming of `@ai-sdk/provider` V4.
public typealias Experimental_RealtimeModelV4 = AIRealtimeModelV4
public typealias Experimental_RealtimeModelV4ClientEvent =
    AIRealtimeClientEvent
public typealias Experimental_RealtimeModelV4ServerEvent =
    AIRealtimeServerEvent
public typealias Experimental_RealtimeModelV4SessionConfig =
    AIRealtimeSessionConfiguration
public typealias Experimental_RealtimeModelV4ClientSecretOptions =
    AIRealtimeClientSecretOptions
public typealias Experimental_RealtimeModelV4ClientSecretResult =
    AIRealtimeClientSecretResult

public typealias Experimental_RealtimeModelV4Usage = AIRealtimeUsage
public typealias Experimental_RealtimeModelV4ServerConnection = AIRealtimeWebSocketConfiguration
public typealias Experimental_RealtimeModelV4SessionIntent = AIRealtimeSessionIntent
