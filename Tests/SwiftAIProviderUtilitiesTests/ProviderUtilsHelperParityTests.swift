import Foundation
import Testing
@testable import SwiftAIProviderUtilities
import SwiftAIProvider
import SwiftAITransport

// Translations of @ai-sdk/provider-utils@5.0.81 helper tests:
// media-type-to-extension, strip-file-extension, extract-lines,
// parse-json (isParsableJson), speech-stream-envelope client frames and the
// streaming-tool-call tracker's id and code-point scanning behavior.

@Test func mediaTypeToExtensionMatchesUpstreamCases() {
    let cases: [(String, String)] = [
        ("audio/mpeg", "mp3"), ("audio/mp3", "mp3"), ("audio/wav", "wav"), ("audio/x-wav", "wav"),
        ("audio/webm", "webm"), ("audio/ogg", "ogg"), ("audio/opus", "ogg"), ("audio/mp4", "m4a"),
        ("audio/x-m4a", "m4a"), ("audio/flac", "flac"), ("audio/aac", "aac"),
        ("AUDIO/MPEG", "mp3"), ("AUDIO/MP3", "mp3"), ("nope", "")
    ]
    for (mediaType, expected) in cases {
        #expect(mediaTypeToExtension(mediaType) == expected, "\(mediaType)")
    }
    // `split('/')` keeps only the second segment as the subtype.
    #expect(mediaTypeToExtension("audio/mpeg/extra") == "mp3")
}

@Test func stripFileExtensionMatchesUpstreamCases() {
    #expect(stripFileExtension("report.pdf") == "report")
    #expect(stripFileExtension("report") == "report")
    #expect(stripFileExtension("archive.tar.gz") == "archive")
    #expect(stripFileExtension("report.") == "report")
}

@Test func extractLinesMatchesUpstreamCases() {
    #expect(extractLines(text: "a\nb\nc") == "a\nb\nc")
    #expect(extractLines(text: "a\nb\nc\nd", startLine: 2, endLine: 3) == "b\nc")
    #expect(extractLines(text: "a\r\nb\r\nc\r\nd", startLine: 2, endLine: 3) == "b\r\nc")
    #expect(extractLines(text: "a\rb\rc\rd", startLine: 2, endLine: 3) == "b\rc")
    #expect(extractLines(text: "a\nb\nc", startLine: 2, endLine: 99) == "b\nc")
    #expect(extractLines(text: "a\nb\nc", endLine: 2) == "a\nb")
    #expect(extractLines(text: "a\nb\nc", startLine: 2) == "b\nc")
    #expect(extractLines(text: "one-liner", startLine: 1, endLine: 1) == "one-liner")
}

@Test func isParsableJSONMatchesUpstreamCases() {
    #expect(isParsableJSON(#"{"foo": "bar"}"#))
    #expect(isParsableJSON("[1, 2, 3]"))
    #expect(isParsableJSON(#""hello""#))
    #expect(!isParsableJSON("invalid"))
    #expect(!isParsableJSON("{foo: \"bar\"}"))
    #expect(!isParsableJSON(#"{"foo": }"#))
    // JSON.parse grammar: trailing commas are not parsable.
    #expect(!isParsableJSON(#"{"foo": "bar",}"#))
}

@Test func speechStreamClientFrameMessagesMatchUpstream() {
    func frame(_ fields: String, type: String = "speech-stream.start") -> SpeechStreamEnvelope.ClientFrame {
        SpeechStreamEnvelope.parseClientFrame(#"{"type":"\#(type)""# + (fields.isEmpty ? "" : ",\(fields)") + "}")
    }

    let startCases: [(String, String)] = [
        (#""voice":1"#, "voice must be a string when present"),
        (#""speed":"1""#, "speed must be a number when present"),
        (#""includeRawChunks":"yes""#, "includeRawChunks must be a boolean when present"),
        (#""providerOptions":[]"#, "providerOptions must be an object of provider objects when present"),
        (#""providerOptions":{"openai":null}"#, "providerOptions must be an object of provider objects when present"),
        (#""providerOptions":{"openai":"x"}"#, "providerOptions must be an object of provider objects when present"),
        (#""outputFormat":{"type":""}"#, "outputFormat must be an audio format object ({ type, rate? }) when present"),
        (#""outputFormat":{"type":"audio/pcm","rate":-1}"#, "outputFormat must be an audio format object ({ type, rate? }) when present"),
        (#""outputFormat":"pcm_24000""#, "outputFormat must be an audio format object ({ type, rate? }) when present"),
        // Upstream checks speed before voice.
        (#""voice":1,"speed":"1""#, "speed must be a number when present")
    ]
    for (fields, message) in startCases {
        #expect(frame(fields) == .invalid(message), "\(fields)")
    }

    let deltaCases: [(String, String)] = [
        (#""voice":2"#, "text-delta voice must be a string when present"),
        (#""providerOptions":"x""#, "text-delta providerOptions must be an object of provider objects when present"),
        (#""providerOptions":{"elevenlabs":[]}"#, "text-delta providerOptions must be an object of provider objects when present")
    ]
    for (fields, message) in deltaCases {
        #expect(frame(#""delta":"Hi","# + fields, type: "speech-stream.text-delta") == .invalid(message), "\(fields)")
    }
    #expect(frame(#""delta":3"#, type: "speech-stream.text-delta") == .invalid("text-delta frame must have a string delta"))

    #expect(SpeechStreamEnvelope.parseClientFrame("{") == .invalid("malformed JSON"))
    #expect(SpeechStreamEnvelope.parseClientFrame("[]") == .invalid("frame must be a JSON object"))
    #expect(SpeechStreamEnvelope.parseClientFrame(#"{"type":1}"#) == .invalid("frame type must be a string"))
    #expect(SpeechStreamEnvelope.parseClientFrame(#"{"type":"speech-stream.x"}"#) == .unknown)
    #expect(SpeechStreamEnvelope.parseClientFrame(#"{"type":"speech-stream.start","__proto__":{"polluted":true}}"#) == .invalid("malformed JSON"))
}

@Test func streamingToolCallTrackerGeneratesUpstreamStyleIDsByDefault() throws {
    var tracker = AIStreamingToolCallTracker()
    let parts = try tracker.processDelta(AIStreamingToolCallDelta(index: 0, functionName: "lookup", arguments: "{}"))
    guard case let .toolInputStart(id, name, _, _, _, _)? = parts.first else {
        Issue.record("expected tool-input-start")
        return
    }
    #expect(name == "lookup")
    // provider-utils generateId: 16 characters from the alphanumeric alphabet.
    #expect(id.count == 16)
    #expect(id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
}

@Test func streamingToolCallTrackerScansArgumentCodePointsLikeUpstream() throws {
    var tracker = AIStreamingToolCallTracker()
    // A combining mark directly after a quote must not hide the quote, so the
    // first payload is a complete object and the next structured start with
    // the same name at the same index begins a second call.
    _ = try tracker.processDelta(AIStreamingToolCallDelta(index: 0, functionName: "f", arguments: "{\"a\":\"\u{0301}x\"}"))
    _ = try tracker.processDelta(AIStreamingToolCallDelta(index: 0, functionName: "f", arguments: #"{"b":1}"#))
    let calls = tracker.flush().compactMap { part -> AIToolCall? in
        if case let .toolCall(call) = part { return call }
        return nil
    }
    #expect(calls.map(\.arguments) == ["{\"a\":\"\u{0301}x\"}", #"{"b":1}"#])
}
