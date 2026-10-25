import Foundation


public struct AudioTranscriptionRequest: Sendable {
    public var audio: Data
    public var fileName: String
    public var mimeType: String
    public var language: String?
    public var prompt: String?
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        audio: Data,
        fileName: String = "audio.wav",
        mimeType: String = "audio/wav",
        language: String? = nil,
        prompt: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.audio = audio
        self.fileName = fileName
        self.mimeType = mimeType
        self.language = language
        self.prompt = prompt
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct TranscriptionResult: Sendable {
    public var usage: [String: JSONValue]? = nil
    public var text: String
    public var rawValue: JSONValue
    public var segments: [TranscriptionSegment]
    public var language: String?
    public var durationInSeconds: Double?
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        text: String,
        rawValue: JSONValue,
        segments: [TranscriptionSegment] = [],
        language: String? = nil,
        durationInSeconds: Double? = nil,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.text = text
        self.rawValue = rawValue
        self.segments = segments
        self.language = language
        self.durationInSeconds = durationInSeconds
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }

    public init(
        text: String,
        rawValue: JSONValue,
        segments: [TranscriptionSegment] = [],
        language: String? = nil,
        durationInSeconds: Double? = nil,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata(),
        usage: [String: JSONValue]?
    ) {
        self.init(text: text, rawValue: rawValue, segments: segments, language: language, durationInSeconds: durationInSeconds, warnings: warnings, providerMetadata: providerMetadata, requestMetadata: requestMetadata, responseMetadata: responseMetadata)
        self.usage = usage
    }
}

public struct TranscriptionSegment: Equatable, Sendable {
    public var text: String
    public var startSecond: Double
    public var endSecond: Double

    public init(text: String, startSecond: Double, endSecond: Double) {
        self.text = text
        self.startSecond = startSecond
        self.endSecond = endSecond
    }
}

public struct SpeechRequest: Sendable {
    public var text: String
    public var voice: String?
    public var format: String?
    public var speed: Double?
    public var language: String?
    public var instructions: String?
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        text: String,
        voice: String? = nil,
        format: String? = nil,
        speed: Double? = nil,
        language: String? = nil,
        instructions: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.text = text
        self.voice = voice
        self.format = format
        self.speed = speed
        self.language = language
        self.instructions = instructions
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct SpeechResult: Sendable {
    public var usage: [String: JSONValue]? = nil
    public var audio: Data
    public var contentType: String?
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        audio: Data,
        contentType: String? = nil,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.audio = audio
        self.contentType = contentType
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }

    public init(
        audio: Data,
        contentType: String? = nil,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata(),
        usage: [String: JSONValue]?
    ) {
        self.init(audio: audio, contentType: contentType, warnings: warnings, providerMetadata: providerMetadata, requestMetadata: requestMetadata, responseMetadata: responseMetadata)
        self.usage = usage
    }
}

public struct AudioGenerationRequest: Sendable {
    public var prompt: String
    public var durationSeconds: Double?
    public var format: String?
    public var seed: Int?
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        prompt: String,
        durationSeconds: Double? = nil,
        format: String? = nil,
        seed: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.prompt = prompt
        self.durationSeconds = durationSeconds
        self.format = format
        self.seed = seed
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct AudioGenerationResult: Sendable {
    public var audio: Data
    public var contentType: String?
    public var rawValue: JSONValue
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        audio: Data,
        contentType: String? = nil,
        rawValue: JSONValue = .null,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.audio = audio
        self.contentType = contentType
        self.rawValue = rawValue
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct AudioTransformationRequest: Sendable {
    public var audio: Data
    public var fileName: String
    public var mimeType: String
    public var voice: String?
    public var format: String?
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        audio: Data,
        fileName: String = "audio.wav",
        mimeType: String = "audio/wav",
        voice: String? = nil,
        format: String? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.audio = audio
        self.fileName = fileName
        self.mimeType = mimeType
        self.voice = voice
        self.format = format
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct AudioTransformationResult: Sendable {
    public var audio: Data
    public var contentType: String?
    public var rawValue: JSONValue
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        audio: Data,
        contentType: String? = nil,
        rawValue: JSONValue = .null,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.audio = audio
        self.contentType = contentType
        self.rawValue = rawValue
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct DubbingCreateRequest: Sendable {
    public var file: Data?
    public var fileName: String
    public var mimeType: String
    public var sourceURL: String?
    public var name: String?
    public var sourceLanguage: String?
    public var targetLanguage: String
    public var numSpeakers: Int?
    public var watermark: Bool?
    public var startTime: Int?
    public var endTime: Int?
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        file: Data? = nil,
        fileName: String = "media.mp3",
        mimeType: String = "audio/mpeg",
        sourceURL: String? = nil,
        name: String? = nil,
        sourceLanguage: String? = nil,
        targetLanguage: String,
        numSpeakers: Int? = nil,
        watermark: Bool? = nil,
        startTime: Int? = nil,
        endTime: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.file = file
        self.fileName = fileName
        self.mimeType = mimeType
        self.sourceURL = sourceURL
        self.name = name
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.numSpeakers = numSpeakers
        self.watermark = watermark
        self.startTime = startTime
        self.endTime = endTime
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct DubbingCreateResult: Sendable {
    public var dubbingID: String
    public var expectedDurationSeconds: Double?
    public var rawValue: JSONValue
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(dubbingID: String, expectedDurationSeconds: Double? = nil, rawValue: JSONValue, requestMetadata: AIRequestMetadata = AIRequestMetadata(), responseMetadata: AIResponseMetadata = AIResponseMetadata()) {
        self.dubbingID = dubbingID
        self.expectedDurationSeconds = expectedDurationSeconds
        self.rawValue = rawValue
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct DubbingStatusResult: Sendable {
    public var dubbingID: String
    public var name: String?
    public var status: String
    public var sourceLanguage: String?
    public var targetLanguages: [String]
    public var error: String?
    public var rawValue: JSONValue
    public var responseMetadata: AIResponseMetadata

    public init(dubbingID: String, name: String? = nil, status: String, sourceLanguage: String? = nil, targetLanguages: [String] = [], error: String? = nil, rawValue: JSONValue, responseMetadata: AIResponseMetadata = AIResponseMetadata()) {
        self.dubbingID = dubbingID
        self.name = name
        self.status = status
        self.sourceLanguage = sourceLanguage
        self.targetLanguages = targetLanguages
        self.error = error
        self.rawValue = rawValue
        self.responseMetadata = responseMetadata
    }
}

public struct DubbingAudioResult: Sendable {
    public var audio: Data
    public var contentType: String?
    public var responseMetadata: AIResponseMetadata

    public init(audio: Data, contentType: String? = nil, responseMetadata: AIResponseMetadata = AIResponseMetadata()) {
        self.audio = audio
        self.contentType = contentType
        self.responseMetadata = responseMetadata
    }
}