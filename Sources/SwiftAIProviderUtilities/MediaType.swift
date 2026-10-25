import Foundation
import SwiftAIProvider
import SwiftAITransport


private struct MediaTypeSignature: Sendable {
    var mediaType: String
    var bytesPrefix: [UInt8?]
}

private let imageMediaTypeSignatures: [MediaTypeSignature] = [
    MediaTypeSignature(mediaType: "image/gif", bytesPrefix: [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]),
    MediaTypeSignature(mediaType: "image/gif", bytesPrefix: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
    MediaTypeSignature(mediaType: "image/png", bytesPrefix: [0x89, 0x50, 0x4E, 0x47]),
    MediaTypeSignature(mediaType: "image/jpeg", bytesPrefix: [0xFF, 0xD8]),
    MediaTypeSignature(mediaType: "image/webp", bytesPrefix: [0x52, 0x49, 0x46, 0x46, nil, nil, nil, nil, 0x57, 0x45, 0x42, 0x50]),
    MediaTypeSignature(mediaType: "image/bmp", bytesPrefix: [0x42, 0x4D, nil, nil, nil, nil, 0x00, 0x00, 0x00, 0x00]),
    MediaTypeSignature(mediaType: "image/tiff", bytesPrefix: [0x49, 0x49, 0x2A, 0x00]),
    MediaTypeSignature(mediaType: "image/tiff", bytesPrefix: [0x4D, 0x4D, 0x00, 0x2A]),
    MediaTypeSignature(mediaType: "image/avif", bytesPrefix: [0x00, 0x00, 0x00, nil, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66]),
    MediaTypeSignature(mediaType: "image/heic", bytesPrefix: [0x00, 0x00, 0x00, nil, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
]

private let documentMediaTypeSignatures: [MediaTypeSignature] = [
    MediaTypeSignature(mediaType: "application/pdf", bytesPrefix: [0x25, 0x50, 0x44, 0x46])
]

private let audioMediaTypeSignaturesWithoutMP4: [MediaTypeSignature] = [
    MediaTypeSignature(mediaType: "audio/aac", bytesPrefix: [0xFF, 0xF0]),
    MediaTypeSignature(mediaType: "audio/aac", bytesPrefix: [0xFF, 0xF1]),
    MediaTypeSignature(mediaType: "audio/aac", bytesPrefix: [0xFF, 0xF8]),
    MediaTypeSignature(mediaType: "audio/aac", bytesPrefix: [0xFF, 0xF9]),
    MediaTypeSignature(mediaType: "audio/mpeg", bytesPrefix: [0xFF, 0xFB]),
    MediaTypeSignature(mediaType: "audio/mpeg", bytesPrefix: [0xFF, 0xFA]),
    MediaTypeSignature(mediaType: "audio/mpeg", bytesPrefix: [0xFF, 0xF3]),
    MediaTypeSignature(mediaType: "audio/mpeg", bytesPrefix: [0xFF, 0xF2]),
    MediaTypeSignature(mediaType: "audio/mpeg", bytesPrefix: [0xFF, 0xE3]),
    MediaTypeSignature(mediaType: "audio/mpeg", bytesPrefix: [0xFF, 0xE2]),
    MediaTypeSignature(mediaType: "audio/wav", bytesPrefix: [0x52, 0x49, 0x46, 0x46, nil, nil, nil, nil, 0x57, 0x41, 0x56, 0x45]),
    MediaTypeSignature(mediaType: "audio/ogg", bytesPrefix: [0x4F, 0x67, 0x67, 0x53]),
    MediaTypeSignature(mediaType: "audio/flac", bytesPrefix: [0x66, 0x4C, 0x61, 0x43]),
    MediaTypeSignature(mediaType: "audio/aac", bytesPrefix: [0x40, 0x15, 0x00, 0x00]),
    MediaTypeSignature(mediaType: "audio/webm", bytesPrefix: [0x1A, 0x45, 0xDF, 0xA3])
]

private let audioMediaTypeSignatures = audioMediaTypeSignaturesWithoutMP4 + [
    MediaTypeSignature(
        mediaType: "audio/mp4",
        bytesPrefix: [0x00, 0x00, 0x00, nil, 0x66, 0x74, 0x79, 0x70]
    )
]

private let videoMediaTypeSignatures: [MediaTypeSignature] = [
    MediaTypeSignature(mediaType: "video/mp4", bytesPrefix: [0x00, 0x00, 0x00, nil, 0x66, 0x74, 0x79, 0x70]),
    MediaTypeSignature(mediaType: "video/webm", bytesPrefix: [0x1A, 0x45, 0xDF, 0xA3]),
    MediaTypeSignature(mediaType: "video/quicktime", bytesPrefix: [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74]),
    MediaTypeSignature(mediaType: "video/x-msvideo", bytesPrefix: [0x52, 0x49, 0x46, 0x46])
]

private let defaultMediaTypeSniffBytes = 18
private let maximumMediaTypeSignatureBytes = 12
private let maximumID3TagBytes = 128 * 1024
private let id3MediaTypeScanBytes = maximumID3TagBytes + maximumMediaTypeSignatureBytes

public func detectMediaType(data: Data, topLevelType: String? = nil) -> String? {
    detectMediaType(bytes: mediaTypeSniffingBytes(data), topLevelType: topLevelType)
}

public func detectMediaType(base64: String, topLevelType: String? = nil) -> String? {
    detectMediaType(bytes: mediaTypeSniffingBytes(base64), topLevelType: topLevelType)
}

public func topLevelMediaType(_ mediaType: String) -> String {
    guard let slashIndex = mediaType.firstIndex(of: "/") else {
        return mediaType
    }
    return String(mediaType[..<slashIndex])
}

public func isFullMediaType(_ mediaType: String) -> Bool {
    guard let slashIndex = mediaType.firstIndex(of: "/") else {
        return false
    }
    let subtype = mediaType[mediaType.index(after: slashIndex)...]
    return !subtype.isEmpty && subtype != "*"
}

public func mediaTypeToExtension(_ mediaType: String) -> String {
    let subtype = mediaType.lowercased().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
    switch subtype {
    case "mpeg": return "mp3"
    case "x-wav": return "wav"
    case "opus": return "ogg"
    case "mp4", "x-m4a": return "m4a"
    default: return subtype
    }
}

public func resolveFullMediaType(mediaType: String, data: Data) throws -> String {
    if isFullMediaType(mediaType) {
        return mediaType
    }
    if let detected = detectMediaType(data: data, topLevelType: topLevelMediaType(mediaType)) {
        return detected
    }
    throw AIError.invalidArgument(
        argument: "mediaType",
        message: "File of media type \"\(mediaType)\" must specify subtype since it could not be auto-detected."
    )
}

private func detectMediaType(bytes: [UInt8], topLevelType: String?) -> String? {
    let signatures: [MediaTypeSignature]
    switch topLevelType {
    case nil:
        signatures = imageMediaTypeSignatures
            + documentMediaTypeSignatures
            + audioMediaTypeSignaturesWithoutMP4
            + videoMediaTypeSignatures
    case "image":
        signatures = imageMediaTypeSignatures
    case "audio":
        signatures = audioMediaTypeSignatures
    case "video":
        signatures = videoMediaTypeSignatures
    case "application":
        signatures = documentMediaTypeSignatures
    default:
        signatures = []
    }

    return signatures.first { signature in
        bytes.count >= signature.bytesPrefix.count
            && signature.bytesPrefix.enumerated().allSatisfy { index, byte in
                byte == nil || bytes[index] == byte
            }
    }?.mediaType
}

private func mediaTypeSniffingBytes(_ data: Data) -> [UInt8] {
    let prefix = Array(data.prefix(defaultMediaTypeSniffBytes))
    guard hasID3Tag(prefix) else {
        return prefix
    }
    return bytesAfterID3Tag(Array(data.prefix(id3MediaTypeScanBytes)))
}

private func mediaTypeSniffingBytes(_ base64: String) -> [UInt8] {
    guard let prefix = decodeBase64Prefix(base64, maximumBytes: defaultMediaTypeSniffBytes) else {
        return []
    }
    guard hasID3Tag(prefix) else {
        return prefix
    }
    guard let id3Prefix = decodeBase64Prefix(base64, maximumBytes: id3MediaTypeScanBytes) else {
        return []
    }
    return bytesAfterID3Tag(id3Prefix)
}

private func decodeBase64Prefix(_ base64: String, maximumBytes: Int) -> [UInt8]? {
    let maximumCharacters = ((maximumBytes + 2) / 3) * 4
    // Upstream accepts both standard base64 and the URL-safe, optionally
    // unpadded representation used by provider references and signatures.
    var encodedPrefix = String(base64.prefix(maximumCharacters))
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - encodedPrefix.count % 4) % 4
    encodedPrefix.append(String(repeating: "=", count: padding))
    guard let data = Data(base64Encoded: encodedPrefix) else {
        return nil
    }
    return Array(data.prefix(maximumBytes))
}

private func hasID3Tag(_ bytes: [UInt8]) -> Bool {
    bytes.count > 10
        && bytes[0] == 0x49
        && bytes[1] == 0x44
        && bytes[2] == 0x33
}

private func bytesAfterID3Tag(_ bytes: [UInt8]) -> [UInt8] {
    let id3Size = (Int(bytes[6] & 0x7F) << 21)
        | (Int(bytes[7] & 0x7F) << 14)
        | (Int(bytes[8] & 0x7F) << 7)
        | Int(bytes[9] & 0x7F)
    return Array(bytes.dropFirst(id3Size + 10).prefix(maximumMediaTypeSignatureBytes))
}
public func isVideoInputFile(_ file: ImageInputFile) -> Bool {
    if let mediaType = file.mediaType, topLevelMediaType(mediaType.lowercased()) == "video" {
        return true
    }
    if let data = file.data, detectMediaType(data: data, topLevelType: "video") != nil {
        return true
    }
    return false
}

