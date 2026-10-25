import Foundation
import SwiftAIProvider
import SwiftAITransport


public func rerankingResults(from value: JSONValue?) -> [RerankedDocument] {
    value?.arrayValue?.compactMap { item in
        guard let index = item["index"]?.intValue ?? item["document_index"]?.intValue,
              let score = item["relevance_score"]?.doubleValue ?? item["score"]?.doubleValue else {
            return nil
        }
        return RerankedDocument(index: index, score: score, document: item["document"]?.stringValue)
    } ?? []
}