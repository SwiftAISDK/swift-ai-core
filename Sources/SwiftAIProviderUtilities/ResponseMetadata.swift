import Foundation
import SwiftAIProvider
import SwiftAITransport


public func aiResponseMetadata(from raw: JSONValue? = nil, response: AIHTTPResponse, modelID: String? = nil) -> AIResponseMetadata {
    AIResponseMetadata(
        id: raw?["id"]?.stringValue ?? raw?["name"]?.stringValue ?? raw?["transcription_id"]?.stringValue,
        timestamp: raw?["created"]?.doubleValue.map { Date(timeIntervalSince1970: $0) } ?? Date(),
        modelID: raw?["model"]?.stringValue ?? modelID,
        headers: response.headers,
        body: raw
    )
}

public func aiRequestMetadata(body: JSONValue?, headers: [String: String]) -> AIRequestMetadata {
    AIRequestMetadata(body: body.map { safeRequestMetadataBody($0) }, headers: headers)
}

public func imageGenerationRequestMetadata(_ request: ImageGenerationRequest, body: JSONValue? = nil) -> AIRequestMetadata {
    aiRequestMetadata(
        body: body ?? .object([
            "prompt": .string(request.prompt),
            "size": request.size.map(JSONValue.string),
            "aspectRatio": request.aspectRatio.map(JSONValue.string),
            "seed": request.seed.map { .number(Double($0)) },
            "count": request.count.map { .number(Double($0)) },
            "files": request.files.isEmpty ? nil : .array(request.files.map(imageInputFileRequestMetadata)),
            "mask": request.mask.map(imageInputFileRequestMetadata),
            "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
            "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
        ]),
        headers: request.headers
    )
}

public func videoGenerationRequestMetadata(_ request: VideoGenerationRequest, body: JSONValue? = nil) -> AIRequestMetadata {
    aiRequestMetadata(
        body: body ?? .object([
            "prompt": .string(request.prompt),
            "aspectRatio": request.aspectRatio.map(JSONValue.string),
            "durationSeconds": request.durationSeconds.map(JSONValue.number),
            "image": request.image.map(imageInputFileRequestMetadata),
            "frameImages": request.frameImages.isEmpty ? nil : .array(request.frameImages.map(videoFrameImageRequestMetadata)),
            "inputReferences": request.inputReferences.isEmpty ? nil : .array(request.inputReferences.map(imageInputFileRequestMetadata)),
            "resolution": request.resolution.map(JSONValue.string),
            "fps": request.fps.map(JSONValue.number),
            "generateAudio": request.generateAudio.map(JSONValue.bool),
            "seed": request.seed.map { .number(Double($0)) },
            "count": request.count.map { .number(Double($0)) },
            "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
            "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
        ]),
        headers: request.headers
    )
}

package func imageInputFileRequestMetadata(_ file: ImageInputFile) -> JSONValue {
    .object([
        "type": .string(file.url == nil ? "data" : "url"),
        "url": file.url.map(JSONValue.string),
        "mediaType": file.mediaType.map(JSONValue.string),
        "fileName": file.fileName.map(JSONValue.string),
        "byteLength": file.data.map { .number(Double($0.count)) }
    ])
}

private func safeRequestMetadataBody(_ value: JSONValue, key: String? = nil) -> JSONValue {
    switch value {
    case let .object(object):
        return .object(object.mapValuesWithKeys { childKey, childValue in
            safeRequestMetadataBody(childValue, key: childKey)
        })
    case let .array(array):
        return .array(array.map { safeRequestMetadataBody($0, key: key) })
    case let .string(string):
        if shouldOmitRequestMetadataString(string, key: key) {
            return .object([
                "type": .string("omitted-media"),
                "encodedByteLength": .number(Double(string.utf8.count))
            ])
        }
        return .string(string)
    case .number, .bool, .null:
        return value
    }
}

private func shouldOmitRequestMetadataString(_ string: String, key: String?) -> Bool {
    let lowerKey = key?.lowercased().replacingOccurrences(of: "-", with: "_")
    if let lowerKey,
       mediaPayloadKeys.contains(lowerKey),
       !isRemoteURLString(string) {
        return true
    }
    if string.hasPrefix("data:") {
        return true
    }
    return string.utf8.count > 128 && string.range(of: #"^[A-Za-z0-9+/_=-]+$"#, options: .regularExpression) != nil
}

private let mediaPayloadKeys: Set<String> = [
    "b64_json",
    "base64",
    "data",
    "image",
    "image_base64",
    "image_data",
    "input_image",
    "input_image_base64",
    "init_image",
    "mask",
    "mask_image",
    "reference_image",
    "reference_image_base64",
    "first_frame_image",
    "last_frame_image",
    "bytesbase64encoded"
]

private func isRemoteURLString(_ string: String) -> Bool {
    string.hasPrefix("http://") || string.hasPrefix("https://")
}

private extension Dictionary where Key == String, Value == JSONValue {
    func mapValuesWithKeys(_ transform: (String, JSONValue) -> JSONValue) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: map { key, value in
            (key, transform(key, value))
        })
    }
}



package func videoFrameImageRequestMetadata(_ frameImage: VideoFrameImage) -> JSONValue {
    .object([
        "image": imageInputFileRequestMetadata(frameImage.image),
        "frameType": .string(frameImage.frameType.rawValue)
    ])
}