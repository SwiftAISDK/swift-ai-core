import Foundation
import Testing
@testable import SwiftAIProviderUtilities
import SwiftAIProvider
import SwiftAITransport

@Test func aiCosineSimilarityCalculatesPositiveSimilarityLikeUpstream() throws {
    let result = try cosineSimilarity([1.0, 2.0, 3.0], [4.0, 5.0, 6.0])
    #expect(abs(result - 0.9746318461970762) < 0.000_01)
}

@Test func aiCosineSimilarityCalculatesNegativeSimilarityLikeUpstream() throws {
    let result = try cosineSimilarity([1.0, 0.0], [-1.0, 0.0])
    #expect(abs(result - -1) < 0.000_01)
}

@Test func aiCosineSimilarityThrowsWhenVectorLengthsDifferLikeUpstream() {
    #expect(throws: AIError.self) {
        _ = try cosineSimilarity([1.0, 2.0, 3.0], [4.0, 5.0])
    }
}

@Test func aiCosineSimilarityReturnsZeroForZeroVectorsLikeUpstream() throws {
    let vector1 = [0.0, 1.0, 2.0]
    let vector2 = [0.0, 0.0, 0.0]

    #expect(try cosineSimilarity(vector1, vector2) == 0)
    #expect(try cosineSimilarity(vector2, vector1) == 0)
}

@Test func aiCosineSimilarityHandlesVerySmallMagnitudesLikeUpstream() throws {
    #expect(try cosineSimilarity([1e-10, 0, 0], [2e-10, 0, 0]) == 1)
    #expect(try cosineSimilarity([1e-10, 0, 0], [-1e-10, 0, 0]) == -1)
}

@Test func aiSplitArraySplitsIntoChunksLikeUpstream() throws {
    #expect(try splitArray([1, 2, 3, 4, 5], chunkSize: 2) == [[1, 2], [3, 4], [5]])
}

@Test func aiSplitArrayReturnsEmptyArrayForEmptyInputLikeUpstream() throws {
    #expect(try splitArray([] as [Int], chunkSize: 2) == [])
}

@Test func aiSplitArrayReturnsSingleChunkWhenChunkSizeExceedsLengthLikeUpstream() throws {
    #expect(try splitArray([1, 2, 3], chunkSize: 5) == [[1, 2, 3]])
}

@Test func aiSplitArrayReturnsSingleChunkWhenChunkSizeEqualsLengthLikeUpstream() throws {
    #expect(try splitArray([1, 2, 3], chunkSize: 3) == [[1, 2, 3]])
}

@Test func aiSplitArrayHandlesChunkSizeOneLikeUpstream() throws {
    #expect(try splitArray([1, 2, 3], chunkSize: 1) == [[1], [2], [3]])
}

@Test func aiSplitArrayThrowsForZeroOrNegativeChunkSizeLikeUpstream() {
    for chunkSize in [0, -1] {
        do {
            _ = try splitArray([1, 2, 3], chunkSize: chunkSize)
            Issue.record("Expected chunk size failure.")
        } catch let error as AIError {
            guard case let .invalidArgument(argument, message) = error else {
                Issue.record("Expected invalid argument error.")
                return
            }
            #expect(argument == "chunkSize")
            #expect(message == "chunkSize must be greater than 0")
        } catch {
            Issue.record("Expected invalid argument error, got \(error).")
        }
    }
}

@Test func aiSplitArrayHandlesFlooredNonIntegerChunkSizeLikeUpstreamCaller() throws {
    let chunkSize = Int(floor(2.5))
    #expect(try splitArray([1, 2, 3, 4, 5], chunkSize: chunkSize) == [[1, 2], [3, 4], [5]])
}

@Test func aiSumTokenCountsSumsKnownCountsLikeUpstream() {
    #expect(sumTokenCounts(3, 10) == 13)
}

@Test func aiSumTokenCountsTreatsOneUnknownCountAsZeroLikeUpstream() {
    #expect(sumTokenCounts(nil, 10) == 10)
    #expect(sumTokenCounts(3, nil) == 3)
}

@Test func aiSumTokenCountsReturnsNilWhenBothCountsAreUnknownLikeUpstream() {
    #expect(sumTokenCounts(nil, nil) == nil)
}

@Test func aiCalculateTokensPerSecondCalculatesAverageOutputRateLikeUpstream() {
    #expect(calculateTokensPerSecond(tokens: 10, durationMilliseconds: 500) == 20)
}

@Test func aiCalculateTokensPerSecondReturnsZeroWhenTokensAreUnknownLikeUpstream() {
    #expect(calculateTokensPerSecond(tokens: nil, durationMilliseconds: 500) == 0)
}

@Test func aiCalculateTokensPerSecondReturnsZeroWhenDurationIsZeroLikeUpstream() {
    #expect(calculateTokensPerSecond(tokens: 10, durationMilliseconds: 0) == 0)
    #expect(calculateTokensPerSecond(tokens: nil, durationMilliseconds: 0) == 0)
}

@Test func aiCalculateTokensPerSecondReturnsZeroWhenResultIsNotJSONSerializableLikeUpstream() {
    #expect(calculateTokensPerSecond(tokens: .infinity, durationMilliseconds: 500) == 0)
    #expect(calculateTokensPerSecond(tokens: .nan, durationMilliseconds: 500) == 0)
}

@Test func aiCalculateTokensPerSecondReturnsZeroWhenDurationIsUnknownLikeUpstream() {
    #expect(calculateTokensPerSecond(tokens: 10, durationMilliseconds: nil) == 0)
}
