import Foundation

public struct AIDownloadRequest: Sendable {
    public var url: URL
    public var isURLSupportedByModel: Bool
    public var abortSignal: AIAbortSignal?
    public init(url: URL, isURLSupportedByModel: Bool = false, abortSignal: AIAbortSignal? = nil) { self.url = url; self.isURLSupportedByModel = isURLSupportedByModel; self.abortSignal = abortSignal }
}
public struct AIDownloadResult: Equatable, Sendable {
    public var data: Data
    public var mediaType: String?
    public init(data: Data, mediaType: String? = nil) { self.data = data; self.mediaType = mediaType }
}
/// One result per request, in order. Nil keeps supported prompt URLs in their
/// native representation; generated file URLs require a non-nil result.
public typealias AIDownloadFunction = @Sendable ([AIDownloadRequest]) async throws -> [AIDownloadResult?]
