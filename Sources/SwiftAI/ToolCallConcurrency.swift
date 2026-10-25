import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


/// Schedules work in input order and retains result order, stopping queued work on failure or abort.
func mapToolCallsWithConcurrency<Input: Sendable, Output: Sendable>(
    _ items: [Input], concurrency: Int?, abortSignal: AIAbortSignal?,
    execute: @escaping @Sendable (Input) async throws -> Output
) async throws -> [Output] {
    if let concurrency, concurrency < 1 {
        throw AIError.invalidArgument(argument: "toolCallConcurrency", message: "toolCallConcurrency must be >= 1")
    }
    try abortSignal?.throwIfAborted()
    guard !items.isEmpty else { return [] }
    let workers = min(concurrency ?? items.count, items.count)
    return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var next = 0
        var results: [Int: Output] = [:]
        func enqueue(_ index: Int) {
            group.addTask {
                try Task.checkCancellation()
                try abortSignal?.throwIfAborted()
                return (index, try await execute(items[index]))
            }
        }
        for index in 0..<workers { enqueue(index); next += 1 }
        do {
            while let (index, result) = try await group.next() {
                results[index] = result
                try abortSignal?.throwIfAborted()
                if next < items.count { enqueue(next); next += 1 }
            }
        } catch {
            group.cancelAll()
            throw error
        }
        return items.indices.compactMap { results[$0] }
    }
}