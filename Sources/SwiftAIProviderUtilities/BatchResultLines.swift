import Foundation
import SwiftAIProvider
import SwiftAITransport


public func aiBatchResultLineLimit(_ maxLineBytes: Int?) throws -> Int {
    let limit = maxLineBytes ?? 64 * 1024 * 1024
    guard limit > 0, limit <= 9_007_199_254_740_991 else {
        throw AIError.invalidArgument(argument: "maxLineBytes", message: "maxLineBytes must be a positive safe integer.")
    }
    return limit
}

/// Counts raw UTF-8 bytes before buffering, including CR and excluding LF.
/// The limit is per row, so a chunk containing many short rows remains valid.
public func aiForEachBatchResultLine(
    _ body: AsyncThrowingStream<Data, Error>,
    url: String,
    maxLineBytes: Int,
    abortSignal: AIAbortSignal?,
    cancelBody: @Sendable () -> Void = {},
    consume: (Data) throws -> Void
) async throws {
    defer { cancelBody() }
    var buffer = Data()
    var isFirstLine = true
    func emit(_ data: Data) throws {
        var line = data
        if isFirstLine {
            isFirstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        if line.last == 0x0D { line.removeLast() }
        try consume(line)
    }
    for try await chunk in body {
        try Task.checkCancellation()
        try abortSignal?.throwIfAborted()
        var offset = chunk.startIndex
        while offset < chunk.endIndex {
            let newline = chunk[offset...].firstIndex(of: 0x0A)
            let segmentEnd = newline ?? chunk.endIndex
            let segmentCount = chunk.distance(from: offset, to: segmentEnd)
            guard segmentCount <= maxLineBytes - buffer.count else {
                throw AIDownloadError(url: url, message: "JSON Lines response exceeded maximum line size of \(maxLineBytes) bytes.")
            }
            buffer.append(contentsOf: chunk[offset..<segmentEnd])
            guard let newline else { break }
            try emit(buffer)
            buffer.removeAll(keepingCapacity: true)
            offset = chunk.index(after: newline)
        }
    }
    try Task.checkCancellation()
    try abortSignal?.throwIfAborted()
    if !buffer.isEmpty { try emit(buffer) }
}