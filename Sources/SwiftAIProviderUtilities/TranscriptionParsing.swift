import Foundation
import SwiftAIProvider
import SwiftAITransport


public func transcriptionSegments(from items: JSONValue?, textKey: String = "text", startKey: String = "start", endKey: String = "end") -> [TranscriptionSegment] {
    items?.arrayValue?.compactMap { item in
        guard let text = item[textKey]?.stringValue, !text.isEmpty else { return nil }
        let start = item[startKey]?.doubleValue ?? 0
        let end = item[endKey]?.doubleValue ?? start
        return TranscriptionSegment(text: text, startSecond: start, endSecond: end)
    } ?? []
}

public func transcriptionDuration(from segments: [TranscriptionSegment]) -> Double? {
    segments.map(\.endSecond).max()
}

public func standardTranscriptionSegments(from raw: JSONValue) -> [TranscriptionSegment] {
    transcriptionSegments(from: raw["segments"])
}