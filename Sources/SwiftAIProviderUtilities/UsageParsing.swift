import Foundation
import SwiftAIProvider
import SwiftAITransport



public func tokenUsage(from raw: JSONValue) -> TokenUsage? {
    guard let usage = raw["usage"] else { return nil }
    let inputTokens = usage["prompt_tokens"]?.intValue ?? usage["input_tokens"]?.intValue
    let outputTokens = usage["completion_tokens"]?.intValue ?? usage["output_tokens"]?.intValue
    let cachedInputTokens = usage["prompt_tokens_details"]?["cached_tokens"]?.intValue
        ?? usage["input_tokens_details"]?["cached_tokens"]?.intValue
    let cacheWriteTokens = usage["prompt_tokens_details"]?["cache_write_tokens"]?.intValue
        ?? usage["input_tokens_details"]?["cache_write_tokens"]?.intValue
    let reasoningTokens = usage["completion_tokens_details"]?["reasoning_tokens"]?.intValue
        ?? usage["output_tokens_details"]?["reasoning_tokens"]?.intValue
    return TokenUsage(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        totalTokens: usage["total_tokens"]?.intValue,
        inputTokensNoCache: inputTokens.map { $0 - (cachedInputTokens ?? 0) - (cacheWriteTokens ?? 0) },
        inputTokensCacheRead: cachedInputTokens,
        inputTokensCacheWrite: cacheWriteTokens,
        outputTextTokens: outputTokens.map { max(0, $0 - (reasoningTokens ?? 0)) },
        outputReasoningTokens: reasoningTokens,
        rawValue: usage
    )
}
