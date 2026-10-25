import Foundation


public enum VideoFrameType: String, Sendable {
    case firstFrame = "first_frame"
    case lastFrame = "last_frame"
}

public struct VideoFrameImage: Sendable, Equatable {
    public var image: ImageInputFile
    public var frameType: VideoFrameType

    public init(image: ImageInputFile, frameType: VideoFrameType) {
        self.image = image
        self.frameType = frameType
    }
}

public struct VideoGenerationRequest: Sendable {
    public var prompt: String
    public var aspectRatio: String?
    public var durationSeconds: Double?
    public var image: ImageInputFile?
    public var frameImages: [VideoFrameImage]
    public var inputReferences: [ImageInputFile]
    public var resolution: String?
    public var fps: Double?
    public var generateAudio: Bool?
    public var seed: Int?
    public var count: Int?
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        prompt: String,
        aspectRatio: String? = nil,
        durationSeconds: Double? = nil,
        image: ImageInputFile? = nil,
        frameImages: [VideoFrameImage] = [],
        inputReferences: [ImageInputFile] = [],
        resolution: String? = nil,
        fps: Double? = nil,
        generateAudio: Bool? = nil,
        seed: Int? = nil,
        count: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.durationSeconds = durationSeconds
        self.image = image
        self.frameImages = frameImages
        self.inputReferences = inputReferences
        self.resolution = resolution
        self.fps = fps
        self.generateAudio = generateAudio
        self.seed = seed
        self.count = count
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }
}

public struct VideoGenerationResult: Sendable {
    public var urls: [String]
    public var base64Videos: [String]
    public var operationID: String?
    public var mediaType: String?
    public var rawValue: JSONValue
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        urls: [String],
        base64Videos: [String] = [],
        operationID: String? = nil,
        mediaType: String? = nil,
        rawValue: JSONValue,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.urls = urls
        self.base64Videos = base64Videos
        self.operationID = operationID
        self.mediaType = mediaType
        self.rawValue = rawValue
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct RerankingRequest: Sendable {
    public var query: String
    public var documents: [String]
    public var documentObjects: [[String: JSONValue]]?
    public var topK: Int?
    public var providerOptions: [String: JSONValue]
    public var extraBody: [String: JSONValue]
    public var headers: [String: String]
    public var abortSignal: AIAbortSignal?

    public init(
        query: String,
        documents: [String],
        topK: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.query = query
        self.documents = documents
        self.documentObjects = nil
        self.topK = topK
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }

    public init(
        query: String,
        documents: [[String: JSONValue]],
        topK: Int? = nil,
        providerOptions: [String: JSONValue] = [:],
        extraBody: [String: JSONValue] = [:],
        headers: [String: String] = [:],
        abortSignal: AIAbortSignal? = nil
    ) {
        self.query = query
        self.documents = []
        self.documentObjects = documents
        self.topK = topK
        self.providerOptions = providerOptions
        self.extraBody = extraBody
        self.headers = headers
        self.abortSignal = abortSignal
    }

    public var documentsJSON: [JSONValue] {
        if let documentObjects {
            return documentObjects.map(JSONValue.object)
        }
        return documents.map(JSONValue.string)
    }
}

public struct RerankingResult: Sendable {
    public var results: [RerankedDocument]
    public var rawValue: JSONValue
    public var warnings: [AIWarning]
    public var providerMetadata: [String: JSONValue]
    public var requestMetadata: AIRequestMetadata
    public var responseMetadata: AIResponseMetadata

    public init(
        results: [RerankedDocument],
        rawValue: JSONValue,
        warnings: [AIWarning] = [],
        providerMetadata: [String: JSONValue] = [:],
        requestMetadata: AIRequestMetadata = AIRequestMetadata(),
        responseMetadata: AIResponseMetadata = AIResponseMetadata()
    ) {
        self.results = results
        self.rawValue = rawValue
        self.warnings = warnings
        self.providerMetadata = providerMetadata
        self.requestMetadata = requestMetadata
        self.responseMetadata = responseMetadata
    }
}

public struct RerankedDocument: Equatable, Sendable {
    public var index: Int
    public var score: Double
    public var document: String?

    public init(index: Int, score: Double, document: String? = nil) {
        self.index = index
        self.score = score
        self.document = document
    }
}