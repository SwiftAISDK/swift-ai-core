import Foundation
import SwiftAIProvider
import SwiftAITransport

/// Captures the caller's transport. Untrusted URLs retain the transport's
/// connection-time DNS validation and redirect protections.
public func createDownload(transport: any AITransport = URLSessionTransport.shared, maxBytes: Int = AIDefaultMaxDownloadSize) -> AIDownloadFunction {
    { requests in
        var results: [AIDownloadResult?] = []
        for request in requests {
            try request.abortSignal?.throwIfAborted()
            if request.isURLSupportedByModel { results.append(nil); continue }
            let response = try await downloadURL(request.url.absoluteString, transport: transport, abortSignal: request.abortSignal, maxBytes: maxBytes)
            guard (200..<300).contains(response.statusCode) else { throw AIDownloadError(url: request.url.absoluteString, message: "Download failed with HTTP status \(response.statusCode).") }
            results.append(.init(data: response.body, mediaType: response.headerValue("content-type")?.split(separator: ";", maxSplits: 1).first.map(String.init)))
        }
        return results
    }
}
