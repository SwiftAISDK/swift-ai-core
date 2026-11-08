import Foundation

/// A declaration of support, independent of runtime request validation.
/// An omitted value, explicit unsupported value and unknown value are distinct.
public enum AIModelFeatureSupport: Equatable, Sendable, Codable {
    case supported
    case unsupported
    case unknown
    case conditional(String)

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        switch value {
        case .bool(true): self = .supported
        case .bool(false): self = .unsupported
        case .string("unknown"): self = .unknown
        case let .object(object):
            guard let condition = object["condition"]?.stringValue else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected a condition description."))
            }
            self = .conditional(condition)
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected a Boolean, unknown, or condition description."))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        let value: JSONValue
        switch self {
        case .supported: value = true
        case .unsupported: value = false
        case .unknown: value = "unknown"
        case let .conditional(condition): value = ["condition": .string(condition)]
        }
        try value.encode(to: encoder)
    }
}

public enum AIModelCapabilitySection: String, Codable, CodingKeyRepresentable, Hashable, Sendable {
    case language, embedding, image, video, reranking, decision, transcription, speechTranslation, speech, realtime
}

public struct AIModelCapabilities: Equatable, Sendable, Codable {
    public struct Language: Equatable, Sendable, Codable {
        public struct Inputs: Equatable, Sendable, Codable {
            public var image: AIModelFeatureSupport
            public var audio: AIModelFeatureSupport
            public init(image: AIModelFeatureSupport, audio: AIModelFeatureSupport) { self.image = image; self.audio = audio }
        }
        public struct Tools: Equatable, Sendable, Codable {
            public var usage: AIModelFeatureSupport
            public var streaming: AIModelFeatureSupport
            public init(usage: AIModelFeatureSupport, streaming: AIModelFeatureSupport) { self.usage = usage; self.streaming = streaming }
        }
        public struct Reasoning: Equatable, Sendable, Codable {
            public var support: AIModelFeatureSupport
            public var efforts: [String]?
            public init(support: AIModelFeatureSupport, efforts: [String]? = nil) { self.support = support; self.efforts = efforts }
        }
        public struct Sampling: Equatable, Sendable, Codable {
            public var temperature: AIModelFeatureSupport
            public var topP: AIModelFeatureSupport
            public var logprobs: AIModelFeatureSupport
            public init(temperature: AIModelFeatureSupport, topP: AIModelFeatureSupport, logprobs: AIModelFeatureSupport) { self.temperature = temperature; self.topP = topP; self.logprobs = logprobs }
        }
        public var inputs: Inputs
        public var objectGeneration: AIModelFeatureSupport
        public var tools: Tools
        public var reasoning: Reasoning
        public var sampling: Sampling
        public init(inputs: Inputs, objectGeneration: AIModelFeatureSupport, tools: Tools, reasoning: Reasoning, sampling: Sampling) { self.inputs = inputs; self.objectGeneration = objectGeneration; self.tools = tools; self.reasoning = reasoning; self.sampling = sampling }
    }
    public struct Embedding: Equatable, Sendable, Codable {
        public var defaultDimensions: Int
        public var customDimensions: AIModelFeatureSupport
        public init(defaultDimensions: Int, customDimensions: AIModelFeatureSupport) { self.defaultDimensions = defaultDimensions; self.customDimensions = customDimensions }
    }
    public struct Image: Equatable, Sendable, Codable {
        public enum Sizes: Equatable, Sendable, Codable {
            case values([String])
            case described(String)
            public init(from decoder: any Decoder) throws {
                let value = try JSONValue(from: decoder)
                if let array = value.arrayValue, array.allSatisfy({ $0.stringValue != nil }) { self = .values(array.compactMap(\.stringValue)) }
                else if let description = value["description"]?.stringValue { self = .described(description) }
                else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected size strings or a description.")) }
            }
            public func encode(to encoder: any Encoder) throws {
                switch self {
                case let .values(values): try JSONValue.array(values.map(JSONValue.string)).encode(to: encoder)
                case let .described(description): try JSONValue.object(["description": .string(description)]).encode(to: encoder)
                }
            }
        }
        public var sizes: Sizes
        public var fileInput: AIModelFeatureSupport
        public var maskInput: AIModelFeatureSupport
        public var maxImagesPerCall: Int?
        public init(sizes: Sizes, fileInput: AIModelFeatureSupport, maskInput: AIModelFeatureSupport, maxImagesPerCall: Int? = nil) { self.sizes = sizes; self.fileInput = fileInput; self.maskInput = maskInput; self.maxImagesPerCall = maxImagesPerCall }
    }
    public struct Video: Equatable, Sendable, Codable {
        public struct Inputs: Equatable, Sendable, Codable {
            public var text: AIModelFeatureSupport
            public var image: AIModelFeatureSupport
            public var firstFrame: AIModelFeatureSupport
            public var lastFrame: AIModelFeatureSupport
            public var referenceImage: AIModelFeatureSupport
            public var referenceVideo: AIModelFeatureSupport
            public init(text: AIModelFeatureSupport, image: AIModelFeatureSupport, firstFrame: AIModelFeatureSupport, lastFrame: AIModelFeatureSupport, referenceImage: AIModelFeatureSupport, referenceVideo: AIModelFeatureSupport) { self.text = text; self.image = image; self.firstFrame = firstFrame; self.lastFrame = lastFrame; self.referenceImage = referenceImage; self.referenceVideo = referenceVideo }
        }
        public var inputs: Inputs
        public var generateAudio: AIModelFeatureSupport
        public var aspectRatio: AIModelFeatureSupport
        public var resolution: AIModelFeatureSupport
        public var duration: AIModelFeatureSupport
        public var fps: AIModelFeatureSupport
        public var seed: AIModelFeatureSupport
        public var maxVideosPerCall: Int?
        public init(inputs: Inputs, generateAudio: AIModelFeatureSupport, aspectRatio: AIModelFeatureSupport, resolution: AIModelFeatureSupport, duration: AIModelFeatureSupport, fps: AIModelFeatureSupport, seed: AIModelFeatureSupport, maxVideosPerCall: Int? = nil) { self.inputs = inputs; self.generateAudio = generateAudio; self.aspectRatio = aspectRatio; self.resolution = resolution; self.duration = duration; self.fps = fps; self.seed = seed; self.maxVideosPerCall = maxVideosPerCall }
    }
    public struct Reranking: Equatable, Sendable, Codable {
        public struct Documents: Equatable, Sendable, Codable {
            public var text: AIModelFeatureSupport
            public var object: AIModelFeatureSupport
            public init(text: AIModelFeatureSupport, object: AIModelFeatureSupport) { self.text = text; self.object = object }
        }
        public var documents: Documents
        public var topN: AIModelFeatureSupport
        public init(documents: Documents, topN: AIModelFeatureSupport) { self.documents = documents; self.topN = topN }
    }
    public struct Decision: Equatable, Sendable, Codable {
        public struct QuestionTypes: Equatable, Sendable, Codable {
            public var boolean: AIModelFeatureSupport
            public var choice: AIModelFeatureSupport
            public var score: AIModelFeatureSupport
            public var box: AIModelFeatureSupport
            public init(boolean: AIModelFeatureSupport, choice: AIModelFeatureSupport, score: AIModelFeatureSupport, box: AIModelFeatureSupport) { self.boolean = boolean; self.choice = choice; self.score = score; self.box = box }
        }
        public struct Inputs: Equatable, Sendable, Codable {
            public var image: AIModelFeatureSupport
            public init(image: AIModelFeatureSupport) { self.image = image }
        }
        public var questionTypes: QuestionTypes
        public var inputs: Inputs
        public var reasoning: AIModelFeatureSupport
        public var maxOutputTokens: AIModelFeatureSupport
        public init(questionTypes: QuestionTypes, inputs: Inputs, reasoning: AIModelFeatureSupport, maxOutputTokens: AIModelFeatureSupport) { self.questionTypes = questionTypes; self.inputs = inputs; self.reasoning = reasoning; self.maxOutputTokens = maxOutputTokens }
    }
    public struct Transcription: Equatable, Sendable, Codable {
        public var transcription: AIModelFeatureSupport
        public var streaming: AIModelFeatureSupport
        public var duration: AIModelFeatureSupport
        public var segments: AIModelFeatureSupport
        public var language: AIModelFeatureSupport
        public var streamingDelay: AIModelFeatureSupport?
        public init(transcription: AIModelFeatureSupport, streaming: AIModelFeatureSupport, duration: AIModelFeatureSupport, segments: AIModelFeatureSupport, language: AIModelFeatureSupport, streamingDelay: AIModelFeatureSupport? = nil) { self.transcription = transcription; self.streaming = streaming; self.duration = duration; self.segments = segments; self.language = language; self.streamingDelay = streamingDelay }
    }
    public struct SpeechTranslation: Equatable, Sendable, Codable {
        public var translatedAudio: AIModelFeatureSupport
        public var translatedText: AIModelFeatureSupport
        public var sourceTranscript: AIModelFeatureSupport
        public init(translatedAudio: AIModelFeatureSupport, translatedText: AIModelFeatureSupport, sourceTranscript: AIModelFeatureSupport) { self.translatedAudio = translatedAudio; self.translatedText = translatedText; self.sourceTranscript = sourceTranscript }
    }
    public struct Speech: Equatable, Sendable, Codable {
        public var instructions: AIModelFeatureSupport
        public init(instructions: AIModelFeatureSupport) { self.instructions = instructions }
    }
    public struct Realtime: Equatable, Sendable, Codable {
        public enum Conversation: String, Codable, Sendable { case continuous; case turnBased = "turn-based" }
        public enum Transport: String, Codable, Sendable { case websocket, webrtc }
        public enum Connection: String, Codable, Sendable { case provider; case clientSecretWebSocket = "client-secret-websocket"; case serverWebSocket = "server-websocket"; case webrtc }
        public var conversation: Conversation
        public var transports: [Transport]
        public var connections: [Connection]
        public init(conversation: Conversation, transports: [Transport], connections: [Connection]) { self.conversation = conversation; self.transports = transports; self.connections = connections }
    }
    public var language: Language?
    public var embedding: Embedding?
    public var video: Video?
    public var reranking: Reranking?
    public var decision: Decision?
    public var image: Image?
    public var transcription: Transcription?
    public var speechTranslation: SpeechTranslation?
    public var speech: Speech?
    public var realtime: Realtime?
    /// Preserves the exact public selector released in core 1.2.0.
    public init(language: Language? = nil, embedding: Embedding? = nil, image: Image? = nil, transcription: Transcription? = nil, speechTranslation: SpeechTranslation? = nil, speech: Speech? = nil, realtime: Realtime? = nil) {
        self.init(language: language, embedding: embedding, image: image, transcription: transcription, speechTranslation: speechTranslation, speech: speech, realtime: realtime, video: nil, reranking: nil, decision: nil)
    }

    public init(language: Language? = nil, embedding: Embedding? = nil, image: Image? = nil, transcription: Transcription? = nil, speechTranslation: SpeechTranslation? = nil, speech: Speech? = nil, realtime: Realtime? = nil, video: Video? = nil, reranking: Reranking? = nil, decision: Decision? = nil) { self.video = video; self.reranking = reranking; self.decision = decision; self.language = language; self.embedding = embedding; self.image = image; self.transcription = transcription; self.speechTranslation = speechTranslation; self.speech = speech; self.realtime = realtime }
}

public struct AIProviderOptionDefinition: Equatable, Sendable, Codable {
    public var description: String
    public init(description: String) { self.description = description }
}
public typealias AIProviderOptionDefinitions = [AIModelCapabilitySection: [String: AIProviderOptionDefinition]]
public typealias AIModelProviderOptions = [AIModelCapabilitySection: [String: AIModelFeatureSupport]]

/// Provider-owned descriptive capabilities and optional request defaults.
/// Metadata does not validate or alter model calls.
public struct AIModelEntry<RequestConfiguration: Sendable>: Sendable {
    public var capabilities: AIModelCapabilities
    public var providerOptions: AIModelProviderOptions?
    public var requestConfig: RequestConfiguration?
    public init(capabilities: AIModelCapabilities, providerOptions: AIModelProviderOptions? = nil, requestConfig: RequestConfiguration? = nil) { self.capabilities = capabilities; self.providerOptions = providerOptions; self.requestConfig = requestConfig }
}
extension AIModelEntry: Equatable where RequestConfiguration: Equatable {}
extension AIModelEntry: Codable where RequestConfiguration: Codable {}
