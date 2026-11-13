import Foundation
import Testing
@testable import SwiftAI
import SwiftAIProvider

private final class ArrayDecodeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Suite("Weekly20261114 incremental structured arrays")
struct Weekly20261114ArrayTests {
    @Test func eachDelimitedElementIsDecodedOnceAcrossOneCharacterChunks() throws {
        let count = ArrayDecodeCount()
        let parser = AIArrayOutputStreamParser<Int>(skipInvalidElements: false) { value in
            count.increment()
            guard let integer = value.intValue else { throw AIError.invalidResponse(provider: "mock", message: "number") }
            return integer
        }
        let text = #"{"elements":[1,2,3,4,5]}"#
        var snapshots: [[Int]] = []
        for char in text {
            switch parser.append(String(char)) {
            case let .snapshot(_, elements): snapshots.append(elements)
            case .unchanged: break
            case .fallback: Issue.record("Canonical envelope unexpectedly fell back")
            }
        }
        #expect(count.value == 5)
        #expect(snapshots == [[], [1], [1, 2], [1, 2, 3], [1, 2, 3, 4], [1, 2, 3, 4, 5]])
    }

    @Test func withholdsLastValueUntilNextStartsOrObjectCloses() {
        let parser = AIArrayOutputStreamParser<JSONValue>(skipInvalidElements: true) { $0 }
        if case let .snapshot(_, values) = parser.append(#"{"elements":[{"text":"quoted ] ,"},"#) { #expect(values.isEmpty) }
        else { Issue.record("Expected empty initial snapshot") }
        if case let .snapshot(_, values) = parser.append(#"{"nested":[1,2]}]"#) { #expect(values == [["text": "quoted ] ,"]]) }
        else { Issue.record("Expected first committed value") }
        if case let .snapshot(_, values) = parser.append("}") { #expect(values.count == 2) }
        else { Issue.record("Expected final committed value") }
    }

    @Test func nonstandardAndInvalidEnvelopesFallBackWithoutPoisoningOtherStreams() {
        let first = AIArrayOutputStreamParser<JSONValue>(skipInvalidElements: false) { $0 }
        let second = AIArrayOutputStreamParser<JSONValue>(skipInvalidElements: false) { $0 }
        if case .fallback = first.append(#"{"extra":true,"elements":[1]}"#) {} else { Issue.record("Expected fallback") }
        if case let .snapshot(_, values) = second.append(#"{"elements":[2]}"#) { #expect(values == [2]) } else { Issue.record("Expected independent parser") }
        if case .fallback = first.append("anything") {} else { Issue.record("Fallback state must remain terminal") }
    }

    @Test func invalidElementsCanBeSkippedOrHandedToLegacyValidation() {
        let decode: @Sendable (JSONValue) throws -> Int = { value in
            guard let number = value.intValue else { throw AIError.invalidResponse(provider: "mock", message: "number") }
            return number
        }
        let skip = AIArrayOutputStreamParser<Int>(skipInvalidElements: true, decode: decode)
        let strict = AIArrayOutputStreamParser<Int>(skipInvalidElements: false, decode: decode)
        let text = #"{"elements":[1,"invalid",2]}"#
        if case let .snapshot(_, values) = skip.append(text) { #expect(values == [1, 2]) } else { Issue.record("Expected skipped invalid element") }
        if case .fallback = strict.append(text) {} else { Issue.record("Expected legacy fallback") }
    }
}

private struct November14ArrayModel: LanguageModel {
    let providerID = "mock", modelID = "array"
    let values: [Int]
    func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult { throw AIError.invalidArgument(argument: "model", message: "stream only") }
    func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.streamStart(warnings: []))
            let text = "{\"elements\":[" + values.map(String.init).joined(separator: ",") + "]}"
            for char in text { continuation.yield(.textDelta(String(char))) }
            continuation.yield(.finish(reason: "stop", usage: nil)); continuation.finish()
        }
    }
}

extension Weekly20261114ArrayTests {
    @Test func reusableOutputArraysKeepEachConcurrentStreamIndependent() async throws {
        let output = Output.array(element: JSONValue.object(["type": "integer"]), as: Int.self)
        @Sendable func collect(_ values: [Int]) async throws -> [[Int]] {
            var snapshots: [[Int]] = []
            for try await part in AI.streamText(model: November14ArrayModel(values: values), request: .init(messages: [.user("array")]), output: output) {
                if case let .partialOutput(value) = part { snapshots.append(value) }
            }
            return snapshots
        }
        async let first = collect([1, 2])
        async let second = collect([8, 9])
        let results = try await (first, second)
        #expect(results.0.last == [1, 2])
        #expect(results.1.last == [8, 9])
        #expect(results.0 == [[], [1], [1, 2]])
        #expect(results.1 == [[], [8], [8, 9]])
    }
}
