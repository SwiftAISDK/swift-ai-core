import Foundation
import SwiftAIProvider
import SwiftAITransport


public func asArray<Value>(_ value: Value?) -> [Value] {
    guard let value else { return [] }
    return [value]
}

public func asArray<Value>(_ value: [Value]?) -> [Value] {
    value ?? []
}

public func filterNullable<Value>(_ values: Value?...) -> [Value] {
    values.compactMap { $0 }
}

public func mergeCallbacks<Event: Sendable>(_ callbacks: [AICallback<Event>?]) -> AICallback<Event> {
    let callbacks = callbacks.compactMap { $0 }
    return { event in
        let tasks = callbacks.map { callback in
            Task {
                try await callback(event)
            }
        }
        for task in tasks {
            do {
                try await task.value
            } catch {}
        }
    }
}

public func mergeCallbacks<Event: Sendable>(_ callbacks: AICallback<Event>?...) -> AICallback<Event> {
    mergeCallbacks(callbacks)
}

public func notify<Event: Sendable>(
    event: Event,
    callbacks: [AICallback<Event>?]
) async {
    do {
        try await mergeCallbacks(callbacks)(event)
    } catch {}
}

public func notify<Event: Sendable>(
    event: Event,
    callback: AICallback<Event>?
) async {
    await notify(event: event, callbacks: [callback])
}

public func notify<Event: Sendable>(event: Event) async {
    await notify(event: event, callbacks: [])
}

public func removeNilEntries<Value>(_ input: [String: Value?]) -> [String: Value] {
    input.reduce(into: [String: Value]()) { output, entry in
        if let value = entry.value {
            output[entry.key] = value
        }
    }
}

public func stripFileExtension(_ filename: String) -> String {
    guard let firstDotIndex = filename.firstIndex(of: ".") else {
        return filename
    }
    return String(filename[..<firstDotIndex])
}

public func extractLines(text: String, startLine: Int? = nil, endLine: Int? = nil) -> String {
    guard startLine != nil || endLine != nil else {
        return text
    }

    let lineEnding: String
    if text.contains("\r\n") {
        lineEnding = "\r\n"
    } else if text.contains("\n") {
        lineEnding = "\n"
    } else if text.contains("\r") {
        lineEnding = "\r"
    } else {
        lineEnding = "\n"
    }

    let lines = text.components(separatedBy: lineEnding)
    let start = max(1, startLine ?? 1) - 1
    let end = min(lines.count, endLine ?? lines.count)
    guard start < end else {
        return ""
    }
    return lines[start..<end].joined(separator: lineEnding)
}

public struct AIToolNameMapping: Sendable {
    private var customToolNameToProviderToolName: [String: String]
    private var providerToolNameToCustomToolName: [String: String]

    public init(customToolNameToProviderToolName: [String: String] = [:]) {
        self.customToolNameToProviderToolName = customToolNameToProviderToolName
        self.providerToolNameToCustomToolName = Dictionary(
            uniqueKeysWithValues: customToolNameToProviderToolName.map { customName, providerName in
                (providerName, customName)
            }
        )
    }

    public func toProviderToolName(_ customToolName: String) -> String {
        customToolNameToProviderToolName[customToolName] ?? customToolName
    }

    public func toCustomToolName(_ providerToolName: String) -> String {
        providerToolNameToCustomToolName[providerToolName] ?? providerToolName
    }
}

public func createToolNameMapping(
    tools: [String: JSONValue]? = nil,
    providerToolNames: [String: String]
) -> AIToolNameMapping {
    var customToolNameToProviderToolName: [String: String] = [:]
    for (customName, tool) in tools ?? [:] {
        guard tool["type"]?.stringValue == "provider",
              let providerToolID = tool["id"]?.stringValue,
              let providerToolName = providerToolNames[providerToolID] else {
            continue
        }
        customToolNameToProviderToolName[customName] = providerToolName
    }
    return AIToolNameMapping(customToolNameToProviderToolName: customToolNameToProviderToolName)
}

public func isCustomReasoning(_ reasoning: String?) -> Bool {
    reasoning != nil && reasoning != "provider-default"
}

public func mapReasoningToProviderEffort(
    reasoning: String,
    effortMap: [String: String],
    warnings: inout [AIWarning]
) -> String? {
    guard let mapped = effortMap[reasoning] else {
        warnings.append(AIWarning(
            type: "unsupported",
            feature: "reasoning",
            message: #"reasoning "\#(reasoning)" is not supported by this model."#
        ))
        return nil
    }
    if mapped != reasoning {
        warnings.append(AIWarning(
            type: "compatibility",
            feature: "reasoning",
            message: #"reasoning "\#(reasoning)" is not directly supported by this model. mapped to effort "\#(mapped)"."#
        ))
    }
    return mapped
}

public func mapReasoningToProviderBudget(
    reasoning: String,
    maxOutputTokens: Int,
    maxReasoningBudget: Int,
    minReasoningBudget: Int = 1024,
    budgetPercentages: [String: Double] = [
        "minimal": 0.02,
        "low": 0.1,
        "medium": 0.3,
        "high": 0.6,
        "xhigh": 0.9,
        "max": 0.95
    ],
    warnings: inout [AIWarning]
) -> Int? {
    guard let percentage = budgetPercentages[reasoning] else {
        warnings.append(AIWarning(
            type: "unsupported",
            feature: "reasoning",
            message: #"reasoning "\#(reasoning)" is not supported by this model."#
        ))
        return nil
    }
    let budget = Int((Double(maxOutputTokens) * percentage).rounded())
    return min(maxReasoningBudget, max(minReasoningBudget, budget))
}

public func cosineSimilarity(_ vector1: [Double], _ vector2: [Double]) throws -> Double {
    guard vector1.count == vector2.count else {
        throw AIError.invalidArgument(
            argument: "vector1,vector2",
            message: "Vectors must have the same length."
        )
    }

    guard !vector1.isEmpty else {
        return 0
    }

    var magnitudeSquared1 = 0.0
    var magnitudeSquared2 = 0.0
    var dotProduct = 0.0

    for index in vector1.indices {
        let value1 = vector1[index]
        let value2 = vector2[index]
        magnitudeSquared1 += value1 * value1
        magnitudeSquared2 += value2 * value2
        dotProduct += value1 * value2
    }

    guard magnitudeSquared1 != 0, magnitudeSquared2 != 0 else {
        return 0
    }

    return dotProduct / (sqrt(magnitudeSquared1) * sqrt(magnitudeSquared2))
}

public func cosineSimilarity(_ vector1: [Float], _ vector2: [Float]) throws -> Double {
    try cosineSimilarity(vector1.map(Double.init), vector2.map(Double.init))
}

public func splitArray<Element>(_ array: [Element], chunkSize: Int) throws -> [[Element]] {
    guard chunkSize > 0 else {
        throw AIError.invalidArgument(argument: "chunkSize", message: "chunkSize must be greater than 0")
    }
    guard !array.isEmpty else { return [] }

    var chunks: [[Element]] = []
    chunks.reserveCapacity((array.count + chunkSize - 1) / chunkSize)
    var start = 0
    while start < array.count {
        let end = min(start + chunkSize, array.count)
        chunks.append(Array(array[start..<end]))
        start = end
    }
    return chunks
}

public func sumTokenCounts(_ lhs: Int?, _ rhs: Int?) -> Int? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        return lhs + rhs
    case let (lhs?, nil):
        return lhs
    case let (nil, rhs?):
        return rhs
    case (nil, nil):
        return nil
    }
}

public func calculateTokensPerSecond(tokens: Double?, durationMilliseconds: Double?) -> Double {
    guard let tokens,
          let durationMilliseconds,
          durationMilliseconds > 0 else {
        return 0
    }
    let tokensPerSecond = tokens / durationMilliseconds * 1000
    guard tokensPerSecond.isFinite else { return 0 }
    return tokensPerSecond
}

public func getPotentialStartIndex(_ text: String, _ searchedText: String) -> Int? {
    guard !searchedText.isEmpty else { return nil }
    if let range = text.range(of: searchedText) {
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }
    var index = text.startIndex
    while index < text.endIndex {
        if searchedText.hasPrefix(text[index...]) {
            return text.distance(from: text.startIndex, to: index)
        }
        index = text.index(after: index)
    }
    return nil
}

public func mergeObjects(_ target: [String: JSONValue]?, _ source: [String: JSONValue]?) -> [String: JSONValue]? {
    guard target != nil || source != nil else { return nil }
    var result = target ?? [:]
    for (key, sourceValue) in source ?? [:] where !isDangerousObjectKey(key) {
        if case let .object(targetObject) = result[key],
           case let .object(sourceObject) = sourceValue {
            result[key] = .object(mergeObjects(targetObject, sourceObject) ?? [:])
        } else {
            result[key] = sourceValue
        }
    }
    return result
}

public func isDeepEqualData(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
    lhs == rhs
}

func isDangerousObjectKey(_ key: String) -> Bool {
    key == "__proto__" || key == "constructor" || key == "prototype"
}

public func generateId() -> String {
    createIdGenerator()()
}

public func resolvedToolCallID(_ value: String?, whenMissing fallback: @autoclosure () -> String) -> String {
    guard let value else { return fallback() }
    return value.isEmpty ? generateId() : value
}

public func createIdGenerator(
    prefix: String? = nil,
    separator: String = "-",
    size: Int = 16,
    alphabet: String = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
) -> AIIdGenerator {
    precondition(size >= 0, "size must be greater than or equal to zero.")
    precondition(!alphabet.isEmpty, "alphabet must not be empty.")
    if prefix != nil, alphabet.contains(separator) {
        preconditionFailure("separator must not be part of alphabet.")
    }
    let characters = Array(alphabet)

    return {
        var id = ""
        id.reserveCapacity(size)
        for _ in 0..<size {
            id.append(characters[Int.random(in: 0..<characters.count)])
        }
        if let prefix {
            return "\(prefix)\(separator)\(id)"
        }
        return id
    }
}

public func simulateReadableStream<Element: Sendable>(
    chunks: [Element],
    initialDelayNanoseconds: UInt64? = 0,
    chunkDelayNanoseconds: UInt64? = 0,
    delay: (@Sendable (UInt64?) async throws -> Void)? = nil
) -> AsyncThrowingStream<Element, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for (index, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    let delayNanoseconds = index == 0 ? initialDelayNanoseconds : chunkDelayNanoseconds
                    try await (delay ?? defaultSimulatedReadableStreamDelay)(delayNanoseconds)
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
    }
}

public func createAsyncIterableStream<Element: Sendable>(
    _ source: AsyncThrowingStream<Element, Error>
) -> AsyncThrowingStream<Element, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await chunk in source {
                    try Task.checkCancellation()
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

public struct AIStitchableStream<Element: Sendable>: Sendable {
    public let stream: AsyncThrowingStream<Element, Error>
    private let state: AIStitchableStreamState<Element>

    fileprivate init(stream: AsyncThrowingStream<Element, Error>, state: AIStitchableStreamState<Element>) {
        self.stream = stream
        self.state = state
    }

    public func addStream(_ innerStream: AsyncThrowingStream<Element, Error>) throws {
        try state.addStream(innerStream)
    }

    public func close() {
        state.close()
    }

    public func terminate() {
        state.terminate()
    }
}

private enum AIStitchableStreamNext<Element: Sendable> {
    case stream(AsyncThrowingStream<Element, Error>)
    case wait
    case done
}

private final class AIStitchableStreamState<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var innerStreams: [AsyncThrowingStream<Element, Error>] = []
    private var waiter: CheckedContinuation<AsyncThrowingStream<Element, Error>?, Never>?
    private var isClosed = false
    private var isTerminated = false

    func addStream(_ innerStream: AsyncThrowingStream<Element, Error>) throws {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw AIError.invalidArgument(
                argument: "innerStream",
                message: "Cannot add inner stream: outer stream is closed"
            )
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: innerStream)
        } else {
            innerStreams.append(innerStream)
            lock.unlock()
        }
    }

    func close() {
        finish(clearStreams: false)
    }

    func terminate() {
        finish(clearStreams: true)
    }

    func nextStream() async -> AsyncThrowingStream<Element, Error>? {
        switch takeNextOrWait() {
        case let .stream(stream):
            return stream
        case .done:
            return nil
        case .wait:
            return await withCheckedContinuation { continuation in
                setWaiterOrResume(continuation)
            }
        }
    }

    private func takeNextOrWait() -> AIStitchableStreamNext<Element> {
        lock.lock()
        defer { lock.unlock() }
        if isTerminated {
            return .done
        }
        if !innerStreams.isEmpty {
            return .stream(innerStreams.removeFirst())
        }
        return isClosed ? .done : .wait
    }

    private func setWaiterOrResume(_ continuation: CheckedContinuation<AsyncThrowingStream<Element, Error>?, Never>) {
        lock.lock()
        if isTerminated {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        if !innerStreams.isEmpty {
            let stream = innerStreams.removeFirst()
            lock.unlock()
            continuation.resume(returning: stream)
            return
        }
        if isClosed {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        waiter = continuation
        lock.unlock()
    }

    private func finish(clearStreams: Bool) {
        lock.lock()
        isClosed = true
        if clearStreams {
            isTerminated = true
            innerStreams.removeAll()
        }
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    func shouldTerminate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isTerminated
    }
}

public func createStitchableStream<Element: Sendable>() -> AIStitchableStream<Element> {
    let state = AIStitchableStreamState<Element>()
    let stream = AsyncThrowingStream<Element, Error> { continuation in
        let task = Task {
            while let innerStream = await state.nextStream() {
                do {
                    for try await chunk in innerStream {
                        try Task.checkCancellation()
                        if state.shouldTerminate() {
                            continuation.finish()
                            return
                        }
                        continuation.yield(chunk)
                    }
                } catch is CancellationError {
                    continuation.finish()
                    return
                } catch {
                    state.terminate()
                    continuation.finish(throwing: error)
                    return
                }
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
            state.terminate()
        }
    }

    return AIStitchableStream(stream: stream, state: state)
}

private func defaultSimulatedReadableStreamDelay(_ delayNanoseconds: UInt64?) async throws {
    if let delayNanoseconds {
        try await Task.sleep(nanoseconds: delayNanoseconds)
    }
}

public enum AISmoothStreamChunking: Sendable {
    case word
    case line
}

public typealias AISmoothStreamChunkDetector = @Sendable (_ buffer: String) throws -> String?

public func smoothStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    delayNanoseconds: UInt64? = 10_000_000,
    chunking: AISmoothStreamChunking = .word
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    smoothStream(
        stream,
        delayNanoseconds: delayNanoseconds,
        detectChunk: detector(for: chunking)
    )
}

public func smoothStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>,
    delayNanoseconds: UInt64? = 10_000_000,
    detectChunk: @escaping AISmoothStreamChunkDetector
) -> AsyncThrowingStream<LanguageStreamPart, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var buffer = ""
            var activeKind: SmoothStreamPartKind?
            var activeID: String?
            var activeProviderMetadata: [String: JSONValue] = [:]

            do {
                func flushBuffer() {
                    guard !buffer.isEmpty, let activeKind, let activeID else { return }
                    continuation.yield(activeKind.part(
                        text: buffer,
                        id: activeID,
                        providerMetadata: activeProviderMetadata
                    ))
                    buffer = ""
                    activeProviderMetadata = [:]
                }

                for try await part in canonicalLanguageStream(stream, providerID: "smooth-stream") {
                    try Task.checkCancellation()
                    guard let smoothable = SmoothableStreamPart(part) else {
                        flushBuffer()
                        continuation.yield(part)
                        continue
                    }

                    if (activeKind != smoothable.kind || activeID != smoothable.id || activeProviderMetadata != smoothable.providerMetadata) && !buffer.isEmpty {
                        flushBuffer()
                    }

                    activeKind = smoothable.kind
                    activeID = smoothable.id
                    buffer += smoothable.text
                    activeProviderMetadata = smoothable.providerMetadata

                    if smoothable.text.isEmpty, !activeProviderMetadata.isEmpty {
                        flushBuffer()
                        activeProviderMetadata = smoothable.providerMetadata
                        continuation.yield(smoothable.kind.part(
                            text: "",
                            id: smoothable.id,
                            providerMetadata: activeProviderMetadata
                        ))
                        activeProviderMetadata = [:]
                        continue
                    }

                    while let match = try detectChunk(buffer) {
                        guard !match.isEmpty else {
                            throw AIError.invalidArgument(
                                argument: "detectChunk",
                                message: "Chunk detector must return a non-empty string."
                            )
                        }
                        guard buffer.hasPrefix(match) else {
                            throw AIError.invalidArgument(
                                argument: "detectChunk",
                                message: "Chunk detector must return a prefix of the current buffer."
                            )
                        }
                        continuation.yield(smoothable.kind.part(
                            text: match,
                            id: smoothable.id,
                            providerMetadata: activeProviderMetadata
                        ))
                        buffer.removeFirst(match.count)
                        if let delayNanoseconds {
                            try await Task.sleep(nanoseconds: delayNanoseconds)
                        }
                    }
                }
                flushBuffer()
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
    }
}

public func toTextStream(
    _ stream: AsyncThrowingStream<LanguageStreamPart, Error>
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await part in canonicalLanguageStream(stream, providerID: "text-stream") {
                    try Task.checkCancellation()
                    switch part {
                    case let .textDeltaPart(_, delta, _):
                        continuation.yield(delta)
                    default:
                        break
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
    }
}

private enum SmoothStreamPartKind: Equatable {
    case text
    case reasoning

    init?(_ part: LanguageStreamPart) {
        switch part {
        case .textDeltaPart:
            self = .text
        case .reasoningDeltaPart:
            self = .reasoning
        default:
            return nil
        }
    }

    func part(text: String, id: String, providerMetadata: [String: JSONValue]) -> LanguageStreamPart {
        switch self {
        case .text:
            return .textDeltaPart(id: id, delta: text, providerMetadata: providerMetadata)
        case .reasoning:
            return .reasoningDeltaPart(id: id, delta: text, providerMetadata: providerMetadata)
        }
    }
}

private struct SmoothableStreamPart {
    var kind: SmoothStreamPartKind
    var id: String
    var text: String
    var providerMetadata: [String: JSONValue]
}

private extension SmoothableStreamPart {
    init?(_ part: LanguageStreamPart) {
        switch part {
        case let .textDeltaPart(id, delta, providerMetadata):
            self.init(kind: .text, id: id, text: delta, providerMetadata: providerMetadata)
        case let .reasoningDeltaPart(id, delta, providerMetadata):
            self.init(kind: .reasoning, id: id, text: delta, providerMetadata: providerMetadata)
        default:
            return nil
        }
    }
}


private func detector(for chunking: AISmoothStreamChunking) -> AISmoothStreamChunkDetector {
    switch chunking {
    case .word:
        return regexDetector(#"\S+\s+"#)
    case .line:
        return regexDetector(#"\n+"#)
    }
}

private func regexDetector(_ pattern: String) -> AISmoothStreamChunkDetector {
    let regex = try? NSRegularExpression(pattern: pattern)
    return { buffer in
        guard !buffer.isEmpty, let regex else { return nil }
        let range = NSRange(buffer.startIndex..<buffer.endIndex, in: buffer)
        guard let match = regex.firstMatch(in: buffer, range: range) else {
            return nil
        }
        guard let matchRange = Range(match.range, in: buffer) else {
            return nil
        }
        return String(buffer[..<matchRange.lowerBound]) + String(buffer[matchRange])
    }
}