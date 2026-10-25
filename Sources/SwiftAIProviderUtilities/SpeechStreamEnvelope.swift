import Foundation
import SwiftAIProvider
import SwiftAITransport


/// Version-one speech WebSocket envelope shared by native Gateway clients and
/// compatible servers. Unknown types are ignored; malformed known types reject.
public enum SpeechStreamEnvelope {
    public static let startFrameType = "speech-stream.start"
    public static let textDeltaFrameType = "speech-stream.text-delta"
    public static let textDoneFrameType = "speech-stream.text-done"

    public enum ClientFrame: Equatable, Sendable {
        case start(JSONValue)
        case textDelta(SpeechTextPart)
        case textDone
        case invalid(String)
        case unknown
    }

    public static func parseClientFrame(_ text: String) -> ClientFrame {
        guard let value = try? secureJSONParse(text), let object = value.objectValue else { return .invalid("malformed JSON or non-object frame") }
        guard let type = value["type"]?.stringValue else { return .invalid("frame type must be a string") }
        switch type {
        case startFrameType:
            for key in ["instructions", "language", "voice"] where object[key] != nil {
                guard object[key]?.stringValue != nil else { return .invalid("\(key) must be a string when present") }
            }
            if let speed = object["speed"], speed.doubleValue == nil { return .invalid("speed must be a number when present") }
            if let raw = object["includeRawChunks"], raw.boolValue == nil { return .invalid("includeRawChunks must be a boolean when present") }
            if let format = object["outputFormat"], audioFormat(format) == nil { return .invalid("outputFormat must be an audio format object") }
            if let options = object["providerOptions"], !validOptions(options) { return .invalid("providerOptions must be an object of provider objects") }
            let allowed: Set<String> = ["type", "voice", "outputFormat", "instructions", "speed", "language", "providerOptions", "includeRawChunks"]
            var frame = object.filter { allowed.contains($0.key) }
            if let format = frame["outputFormat"]?.objectValue { frame["outputFormat"] = .object(format.filter { $0.key == "type" || $0.key == "rate" }) }
            return .start(.object(frame))
        case textDeltaFrameType:
            guard let delta = object["delta"]?.stringValue else { return .invalid("text-delta frame must have a string delta") }
            if let voice = object["voice"], voice.stringValue == nil { return .invalid("text-delta voice must be a string") }
            if let options = object["providerOptions"], !validOptions(options) { return .invalid("providerOptions must be an object of provider objects") }
            return .textDelta(SpeechTextPart(text: delta, voice: object["voice"]?.stringValue, providerOptions: object["providerOptions"]?.objectValue ?? [:]))
        case textDoneFrameType: return .textDone
        default: return .unknown
        }
    }

    public static func parsePart(_ text: String) -> StreamingSpeechPart? {
        guard let value = try? secureJSONParse(text), value.objectValue != nil else { return nil }
        func objectIfPresent(_ key: String) -> Bool { value[key] == nil || value[key]?.objectValue != nil }
        switch value["type"]?.stringValue {
        case "stream-start":
            guard let input = value["warnings"]?.arrayValue else { return nil }
            var warnings: [AIWarning] = []
            for item in input {
                guard item.objectValue != nil, let type = item["type"]?.stringValue else { return nil }
                switch type {
                case "unsupported", "compatibility":
                    guard item["feature"]?.stringValue != nil, item["details"] == nil || item["details"]?.stringValue != nil else { return nil }
                case "deprecated": guard item["setting"]?.stringValue != nil, item["message"]?.stringValue != nil else { return nil }
                case "other": guard item["message"]?.stringValue != nil else { return nil }
                default: continue
                }
                warnings.append(AIWarning(type: type, feature: item["feature"]?.stringValue, setting: item["setting"]?.stringValue,
                                          message: item["message"]?.stringValue ?? item["details"]?.stringValue))
            }
            return .streamStart(warnings: warnings)
        case "audio":
            guard let encoded = value["audio"]?.stringValue, let audio = Data(base64Encoded: encoded),
                  let formatValue = value["audioFormat"], let format = audioFormat(formatValue), objectIfPresent("providerMetadata"),
                  value["id"] == nil || value["id"]?.stringValue != nil else { return nil }
            return .audio(id: value["id"]?.stringValue, audio: audio, audioFormat: format, providerMetadata: value["providerMetadata"]?.objectValue ?? [:])
        case "finish":
            guard objectIfPresent("providerMetadata"), objectIfPresent("usage") else { return nil }
            let usage = value["usage"]?.objectValue ?? [:]
            for key in ["inputCharacters", "inputTokens", "outputTokens"] where usage[key] != nil {
                guard usage[key]?.doubleValue != nil else { return nil }
            }
            return .finish(usage: usage, providerMetadata: value["providerMetadata"]?.objectValue ?? [:])
        case "response-metadata":
            guard objectIfPresent("headers"), value["modelId"] == nil || value["modelId"]?.stringValue != nil else { return nil }
            var timestamp: Date?
            if let time = value["timestamp"], time != .null {
                guard let string = time.stringValue else { return nil }
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                timestamp = formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
                guard timestamp != nil else { return nil }
            }
            return .responseMetadata(AIResponseMetadata(timestamp: timestamp, modelID: value["modelId"]?.stringValue,
                                                         headers: value["headers"]?.objectValue?.compactMapValues(\.stringValue) ?? [:], body: value["body"]))
        case "raw": return value["rawValue"].map(StreamingSpeechPart.raw)
        case "error": return value["error"].map { .error(AIStreamingSpeechError(provider: "speech", message: $0["message"]?.stringValue ?? $0.stringValue ?? String(describing: $0), rawValue: $0)) }
        default: return nil
        }
    }

    public static func serializePart(_ part: StreamingSpeechPart) -> String? {
        let value: JSONValue
        switch part {
        case let .streamStart(warnings):
            value = .object(["type": "stream-start", "warnings": .array(warnings.map { .object([
                "type": .string($0.type), "feature": $0.feature.map(JSONValue.string), "setting": $0.setting.map(JSONValue.string),
                $0.type == "unsupported" || $0.type == "compatibility" ? "details" : "message": $0.message.map(JSONValue.string)
            ]) })])
        case let .audio(id, audio, format, metadata):
            value = .object(["type": "audio", "id": id.map(JSONValue.string), "audio": .string(audio.base64EncodedString()),
                             "audioFormat": formatJSON(format), "providerMetadata": metadata.isEmpty ? nil : .object(metadata)])
        case let .finish(usage, metadata): value = .object(["type": "finish", "usage": .object(usage), "providerMetadata": .object(metadata)])
        case let .raw(raw): value = .object(["type": "raw", "rawValue": raw])
        case let .error(error):
            let payload = (error as? AIStreamingSpeechError)?.rawValue ?? .object(["name": .string(String(describing: type(of: error))), "message": .string(String(describing: error))])
            value = .object(["type": "error", "error": payload])
        case let .responseMetadata(metadata):
            value = .object(["type": "response-metadata", "modelId": metadata.modelID.map(JSONValue.string),
                             "timestamp": metadata.timestamp.map { .string(ISO8601DateFormatter().string(from: $0)) },
                             "headers": .object(metadata.headers.mapValues(JSONValue.string)), "body": metadata.body])
        }
        guard let bytes = try? encodeJSONBody(value) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    public static func startFrame(_ request: StreamingSpeechRequest) -> JSONValue {
        .object(["type": .string(startFrameType), "voice": request.voice.map(JSONValue.string),
                 "outputFormat": request.outputFormat.map(formatJSON), "instructions": request.instructions.map(JSONValue.string),
                 "speed": request.speed.map(JSONValue.number), "language": request.language.map(JSONValue.string),
                 "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
                 "includeRawChunks": request.includeRawChunks ? .bool(true) : nil])
    }

    static func formatJSON(_ format: AIStreamingAudioFormat) -> JSONValue {
        .object(["type": .string(format.mediaType), "rate": format.sampleRate.map { .number(Double($0)) }])
    }
    static func audioFormat(_ value: JSONValue) -> AIStreamingAudioFormat? {
        guard let type = value["type"]?.stringValue, !type.isEmpty else { return nil }
        if let rate = value["rate"] { guard let number = rate.doubleValue, number.isFinite, number > 0, rate.intValue != nil else { return nil } }
        return AIStreamingAudioFormat(mediaType: type, sampleRate: value["rate"]?.intValue)
    }
    private static func validOptions(_ value: JSONValue) -> Bool { value.objectValue?.values.allSatisfy { $0.objectValue != nil } == true }
}