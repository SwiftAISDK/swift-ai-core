import Foundation
import SwiftAIProvider


public struct AIHTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// Single-use request body consumed incrementally by streaming-capable
    /// transports. It is mutually exclusive with `body`.
    public var bodyStream: AsyncThrowingStream<Data, Error>?
    public var abortSignal: AIAbortSignal?
    public var maxResponseBytes: Int?
    public var followRedirects: Bool
    private let bodyStreamCancellation: @Sendable () async -> Void

    public init(
        method: String = "POST",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        bodyStream: AsyncThrowingStream<Data, Error>? = nil,
        cancelBodyStream: @escaping @Sendable () async -> Void = {},
        abortSignal: AIAbortSignal? = nil,
        maxResponseBytes: Int? = nil,
        followRedirects: Bool = true
    ) {
        precondition(body == nil || bodyStream == nil, "AIHTTPRequest cannot contain both body and bodyStream.")
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.bodyStream = bodyStream
        self.abortSignal = abortSignal
        self.maxResponseBytes = maxResponseBytes
        self.followRedirects = followRedirects
        self.bodyStreamCancellation = cancelBodyStream
    }

    /// Source-compatible initializer retained from before streamed request
    /// bodies were supported.
    public init(
        method: String = "POST",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        abortSignal: AIAbortSignal? = nil,
        maxResponseBytes: Int? = nil,
        followRedirects: Bool = true
    ) {
        self.init(
            method: method,
            url: url,
            headers: headers,
            body: body,
            bodyStream: nil,
            cancelBodyStream: {},
            abortSignal: abortSignal,
            maxResponseBytes: maxResponseBytes,
            followRedirects: followRedirects
        )
    }

    public func cancelRequestBody() async {
        await bodyStreamCancellation()
    }
}

public let AIDefaultMaxDownloadSize = 2 * 1024 * 1024 * 1024

public struct AIDownloadError: Error, Equatable, CustomStringConvertible, Sendable {
    public var url: String
    public var message: String

    public init(url: String, message: String) {
        self.url = url
        self.message = message
    }

    public var description: String {
        "Failed to download \(url): \(message)"
    }
}

public struct AIHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    public var url: URL?

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data(), url: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.url = url
    }

    public func jsonValue() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: body)
    }

    public var bodyText: String {
        String(data: body, encoding: .utf8) ?? ""
    }

    public func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol AITransport: Sendable {
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse
    /// Fetches one untrusted download hop without redirects. Implementations
    /// must connect only to validated DNS results and retain hostname TLS trust.
    func sendValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPResponse
}

public extension AITransport {
    func sendValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        throw AIDownloadError(
            url: request.url.absoluteString,
            message: "This transport does not implement DNS-pinned downloads. Implement sendValidatedDownload for untrusted URLs."
        )
    }
}


public struct AIHTTPStreamResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>
    /// Distinguishes a present zero-byte body from a transport response that
    /// has no body object at all.
    public var bodyAvailable: Bool
    private let bodyCancellation: @Sendable () -> Void

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: AsyncThrowingStream<Data, Error>,
        bodyAvailable: Bool = true,
        cancelBody: @escaping @Sendable () -> Void = {}
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyAvailable = bodyAvailable
        self.bodyCancellation = cancelBody
    }

    /// Source-compatible initializer retained from before transport responses
    /// distinguished an absent body from a present empty body.
    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: AsyncThrowingStream<Data, Error>,
        cancelBody: @escaping @Sendable () -> Void = {}
    ) {
        self.init(
            statusCode: statusCode,
            headers: headers,
            body: body,
            bodyAvailable: true,
            cancelBody: cancelBody
        )
    }

    public func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Cancels production of the response body when a caller intentionally
    /// discards it, for example before following or rejecting a redirect.
    public func cancelBody() {
        bodyCancellation()
    }
}

public func readResponseWithSizeLimit(
    response: AIHTTPStreamResponse,
    url: String,
    maxBytes: Int = AIDefaultMaxDownloadSize
) async throws -> Data {
    // Match the provider-utils reader contract: whether the body is drained,
    // rejected from Content-Length, exceeds the cumulative limit, or throws,
    // release its producer deterministically.
    defer { response.cancelBody() }
    let contentLength = response.headerValue("content-length").flatMap(parseContentLength)
    if let contentLength, contentLength > maxBytes {
        throw AIDownloadError(
            url: url,
            message: downloadSizeLimitExceededMessage(url: url, maxBytes: maxBytes, contentLength: contentLength)
        )
    }

    var data = Data()
    data.reserveCapacity(max(0, min(maxBytes, contentLength ?? 0)))
    var totalBytes = 0

    for try await chunk in response.body {
        totalBytes += chunk.count
        if totalBytes > maxBytes {
            throw AIDownloadError(
                url: url,
                message: downloadSizeLimitExceededMessage(url: url, maxBytes: maxBytes)
            )
        }
        data.append(chunk)
    }

    return data
}

public protocol AIStreamingTransport: AITransport {
    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse
    /// Streaming counterpart of `sendValidatedDownload`; each redirect is a
    /// separate validated hop. The returned body must remain cancellable.
    func streamValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse
}

public extension AIStreamingTransport {
    func streamValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        throw AIDownloadError(
            url: request.url.absoluteString,
            message: "This transport does not implement DNS-pinned downloads. Implement streamValidatedDownload for untrusted URLs."
        )
    }
}


public func requireStreamingTransport(
    _ transport: any AITransport,
    providerID: String
) throws -> any AIStreamingTransport {
    guard let streamingTransport = transport as? any AIStreamingTransport else {
        throw AIError.invalidArgument(
            argument: "transport",
            message: "\(providerID) streaming requires a transport conforming to AIStreamingTransport."
        )
    }
    return streamingTransport
}

public func getFromAPI(
    url: URL,
    transport: any AITransport,
    headers: [String: String] = [:],
    abortSignal: AIAbortSignal? = nil
) async throws -> (request: AIHTTPRequest, response: AIHTTPResponse) {
    let request = AIHTTPRequest(
        method: "GET",
        url: url,
        headers: headers,
        abortSignal: abortSignal,
        followRedirects: false
    )
    return (request, try await transport.send(request))
}

public func deleteFromAPI(
    url: URL,
    transport: any AITransport,
    headers: [String: String] = [:],
    abortSignal: AIAbortSignal? = nil
) async throws -> (request: AIHTTPRequest, response: AIHTTPResponse) {
    let request = AIHTTPRequest(
        method: "DELETE",
        url: url,
        headers: headers,
        abortSignal: abortSignal,
        followRedirects: false
    )
    return (request, try await transport.send(request))
}

public func getBinaryStreamFromAPI(
    url: URL,
    transport: any AITransport,
    providerID: String,
    headers: [String: String] = [:],
    abortSignal: AIAbortSignal? = nil,
    trustedOrigin: String? = nil,
    credentialedOrigin: String? = nil
) async throws -> (request: AIHTTPRequest, response: AIHTTPStreamResponse) {
    let streamingTransport = try requireStreamingTransport(transport, providerID: providerID)
    let (response, request) = try await streamDownloadURL(
        url.absoluteString,
        transport: streamingTransport,
        headers: headers,
        credentialedOrigin: credentialedOrigin,
        trustedOrigin: trustedOrigin,
        abortSignal: abortSignal,
        maxBytes: AIDefaultMaxDownloadSize
    )
    guard response.bodyAvailable else {
        response.cancelBody()
        throw AIError.invalidResponse(provider: providerID, message: "File download response body is missing.")
    }
    guard (200..<300).contains(response.statusCode) else {
        let body = try await readResponseWithSizeLimit(
            response: response,
            url: url.absoluteString
        )
        throw apiCallError(
            provider: providerID,
            statusCode: response.statusCode,
            body: String(decoding: body, as: UTF8.self),
            headers: response.headers
        )
    }
    return (request, response)
}

public final class URLSessionTransport: AIStreamingTransport, @unchecked Sendable {
    public static let shared = URLSessionTransport()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func sendValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        let response = try await streamValidatedDownload(request)
        let body = try await readResponseWithSizeLimit(
            response: response,
            url: request.url.absoluteString,
            maxBytes: request.maxResponseBytes ?? AIDefaultMaxDownloadSize
        )
        return AIHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: body, url: request.url)
    }

    public func streamValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        guard session === URLSession.shared else {
            throw AIDownloadError(
                url: request.url.absoluteString,
                message: "A custom URLSession cannot guarantee DNS-pinned downloads. Use the default transport or implement the validated-download transport hooks."
            )
        }
        return try await HTTPDNSPinnedTransport().stream(request)
    }

    public func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        try request.abortSignal?.throwIfAborted()
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        let requestInputStream = request.bodyStream.map(AsyncSequenceInputStream.init)
        if let requestInputStream {
            urlRequest.httpBodyStream = requestInputStream
        } else {
            urlRequest.httpBody = request.body
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let preparedRequest = urlRequest

        let delegate = urlSessionTaskDelegate(followRedirects: request.followRedirects)

        let maxResponseBytes = request.maxResponseBytes ?? AIDefaultMaxDownloadSize
        let operation: @Sendable () async throws -> AIHTTPResponse = {
            do {
                requestInputStream?.open()
                let (bytes, response) = try await self.session.bytes(for: preparedRequest, delegate: delegate)
                let result = try await limitedHTTPResponse(
                    bytes: bytes,
                    response: response,
                    request: request,
                    maxResponseBytes: maxResponseBytes
                )
                requestInputStream?.close()
                return result
            } catch {
                requestInputStream?.close()
                await request.cancelRequestBody()
                if let abortSignal = request.abortSignal, abortSignal.isAborted {
                    throw AIAbortError(reason: abortSignal.reason, reasonName: abortSignal.reasonName)
                }
                throw error
            }
        }

        if let abortSignal = request.abortSignal {
            return try await raceAbortSignal(abortSignal, operation: operation)
        }
        return try await operation()
    }

    public func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        guard request.bodyStream == nil else {
            await request.cancelRequestBody()
            throw AIError.invalidArgument(
                argument: "request.bodyStream",
                message: "Streaming response requests cannot also contain a streaming upload body."
            )
        }
        try request.abortSignal?.throwIfAborted()
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let preparedRequest = urlRequest

        let delegate = urlSessionTaskDelegate(followRedirects: request.followRedirects)
        let responseOperation: @Sendable () async throws -> (URLSession.AsyncBytes, URLResponse) = {
            do {
                return try await self.session.bytes(for: preparedRequest, delegate: delegate)
            } catch {
                if let abortSignal = request.abortSignal, abortSignal.isAborted {
                    throw AIAbortError(reason: abortSignal.reason, reasonName: abortSignal.reasonName)
                }
                throw error
            }
        }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        if let abortSignal = request.abortSignal {
            (bytes, response) = try await raceAbortSignal(abortSignal, operation: responseOperation)
        } else {
            (bytes, response) = try await responseOperation()
        }
        let httpResponse = response as? HTTPURLResponse
        let headers = httpHeaders(from: httpResponse)
        let maxResponseBytes = request.maxResponseBytes ?? AIDefaultMaxDownloadSize
        let urlText = request.url.absoluteString
        if let contentLength = httpResponse?.value(forHTTPHeaderField: "content-length").flatMap(parseContentLength),
           contentLength > maxResponseBytes {
            bytes.task.cancel()
            throw AIDownloadError(
                url: urlText,
                message: downloadSizeLimitExceededMessage(
                    url: urlText,
                    maxBytes: maxResponseBytes,
                    contentLength: contentLength
                )
            )
        }
        let body = makeDemandDrivenHTTPBody(
            bytes: bytes,
            url: urlText,
            maxBytes: maxResponseBytes,
            abortSignal: request.abortSignal,
            cancel: { bytes.task.cancel() }
        )
        return AIHTTPStreamResponse(
            statusCode: httpResponse?.statusCode ?? 0,
            headers: headers,
            body: body.body,
            cancelBody: body.cancel
        )
    }
}

/// Blocking InputStream bridge used by URLSession to pull an async request body
/// one chunk at a time. At most one source chunk is retained, so large file
/// uploads are not accumulated in memory.
private final class AsyncSequenceInputStream: InputStream, @unchecked Sendable {
    private let source: AsyncThrowingStream<Data, Error>
    private let condition = NSCondition()
    private var iteratorBox: AsyncStreamIteratorBox?
    private var pendingRead: Task<Void, Never>?
    private var chunk = Data()
    private var offset = 0
    private var finished = false
    private var closed = false
    private var failure: Error?
    private var status: Stream.Status = .notOpen

    init(_ source: AsyncThrowingStream<Data, Error>) {
        self.source = source
        super.init(data: Data())
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func open() {
        condition.lock()
        if status == .notOpen { status = .open }
        condition.broadcast()
        condition.unlock()
    }

    override func close() {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        status = .closed
        let pendingRead = pendingRead
        self.pendingRead = nil
        condition.broadcast()
        condition.unlock()
        pendingRead?.cancel()
    }

    override var streamStatus: Stream.Status {
        condition.withLock { status }
    }

    override var streamError: Error? {
        condition.withLock { failure }
    }

    override var hasBytesAvailable: Bool {
        condition.withLock { !closed && (!chunk.isEmpty || !finished) }
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0 else { return 0 }
        condition.lock()
        defer { condition.unlock() }

        while true {
            if offset < chunk.count {
                let count = min(len, chunk.count - offset)
                chunk.copyBytes(to: buffer, from: offset..<(offset + count))
                offset += count
                if offset == chunk.count {
                    chunk = Data()
                    offset = 0
                }
                return count
            }
            if failure != nil {
                status = .error
                return -1
            }
            if finished || closed {
                if !closed { status = .atEnd }
                return 0
            }
            startPendingReadLocked()
            condition.wait()
        }
    }

    private func startPendingReadLocked() {
        guard pendingRead == nil, !finished, !closed else { return }
        if iteratorBox == nil { iteratorBox = AsyncStreamIteratorBox(source) }
        guard let iteratorBox else { return }
        let completion = AsyncStreamReadCompletion(owner: self)
        pendingRead = Task.detached { [iteratorBox, completion] in
            do {
                completion.finish(value: try await iteratorBox.next(), error: nil)
            } catch {
                completion.finish(value: nil, error: error)
            }
        }
    }

    fileprivate func completeRead(
        value: Data?,
        error: Error?
    ) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        guard !closed else { return }
        pendingRead = nil
        if let error {
            failure = error
            return
        }
        guard let value else {
            finished = true
            return
        }
        chunk = value
        offset = 0
    }
}

private final class AsyncStreamReadCompletion: @unchecked Sendable {
    private weak var owner: AsyncSequenceInputStream?

    init(owner: AsyncSequenceInputStream) {
        self.owner = owner
    }

    func finish(value: Data?, error: Error?) {
        owner?.completeRead(value: value, error: error)
    }
}

private final class AsyncStreamIteratorBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator

    init(_ source: AsyncThrowingStream<Data, Error>) {
        iterator = source.makeAsyncIterator()
    }

    func next() async throws -> Data? {
        try await iterator.next()
    }
}

func urlSessionTaskDelegate(followRedirects: Bool) -> URLSessionTaskDelegate? {
    followRedirects ? nil : NoRedirectURLSessionDelegate()
}

final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private func limitedHTTPResponse(
    bytes: URLSession.AsyncBytes,
    response: URLResponse,
    request: AIHTTPRequest,
    maxResponseBytes: Int
) async throws -> AIHTTPResponse {
    try await withTaskCancellationHandler {
        let httpResponse = response as? HTTPURLResponse
        let headers = httpHeaders(from: httpResponse)
        let urlText = request.url.absoluteString
        if let contentLength = httpResponse?.value(forHTTPHeaderField: "content-length"),
           let length = parseContentLength(contentLength),
           length > maxResponseBytes {
            bytes.task.cancel()
            throw AIDownloadError(
                url: urlText,
                message: downloadSizeLimitExceededMessage(url: urlText, maxBytes: maxResponseBytes, contentLength: length)
            )
        }

        var data = Data()
        let expectedLength = response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 0
        data.reserveCapacity(min(maxResponseBytes, expectedLength))
        var totalBytes = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            totalBytes += 1
            if totalBytes > maxResponseBytes {
                bytes.task.cancel()
                throw AIDownloadError(
                    url: urlText,
                    message: downloadSizeLimitExceededMessage(url: urlText, maxBytes: maxResponseBytes)
                )
            }
            data.append(byte)
        }

        return AIHTTPResponse(statusCode: httpResponse?.statusCode ?? 0, headers: headers, body: data, url: response.url)
    } onCancel: {
        bytes.task.cancel()
    }
}

private func httpHeaders(from response: HTTPURLResponse?) -> [String: String] {
    response?.allHeaderFields.reduce(into: [String: String]()) { partial, element in
        guard let key = element.key as? String else { return }
        partial[key] = String(describing: element.value)
    } ?? [:]
}

public func raceAbortSignal<Output: Sendable>(
    _ abortSignal: AIAbortSignal,
    operation: @escaping @Sendable () async throws -> Output
) async throws -> Output {
    try abortSignal.throwIfAborted()
    let state = HTTPAbortRaceState<Output>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            state.setContinuation(continuation)

            let registration = abortSignal.addAbortHandler { reason in
                state.complete(
                    .failure(AIAbortError(reason: reason, reasonName: abortSignal.reasonName)),
                    cancelOperation: true
                )
            }
            state.setRegistration(registration)

            let operationTask = Task {
                do {
                    state.complete(.success(try await operation()), cancelOperation: false)
                } catch {
                    if abortSignal.isAborted {
                        state.complete(
                            .failure(AIAbortError(
                                reason: abortSignal.reason,
                                reasonName: abortSignal.reasonName
                            )),
                            cancelOperation: false
                        )
                    } else {
                        state.complete(.failure(error), cancelOperation: false)
                    }
                }
            }
            state.setOperationTask(operationTask)
        }
    } onCancel: {
        state.complete(.failure(CancellationError()), cancelOperation: true)
    }
}

private final class HTTPAbortRaceState<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var pendingResult: Result<Output, Error>?
    private var operationTask: Task<Void, Never>?
    private var registration: AIAbortHandlerRegistration?
    private var completed = false

    func setContinuation(_ continuation: CheckedContinuation<Output, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setOperationTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            task.cancel()
            return
        }
        operationTask = task
        lock.unlock()
    }

    func setRegistration(_ registration: AIAbortHandlerRegistration) {
        lock.lock()
        if completed {
            lock.unlock()
            registration.cancel()
            return
        }
        self.registration = registration
        lock.unlock()
    }

    func complete(_ result: Result<Output, Error>, cancelOperation: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let operationTask = self.operationTask
        self.operationTask = nil
        let registration = self.registration
        self.registration = nil
        lock.unlock()

        registration?.cancel()
        if cancelOperation {
            operationTask?.cancel()
        }
        continuation?.resume(with: result)
    }
}

extension Dictionary where Key == String, Value == String {
    public func mergingHeaders(_ other: [String: String]) -> [String: String] {
        combineHeaders(self, other)
    }
}


public func normalizeHeaders(_ headers: [String: String?]?) -> [String: String] {
    guard let headers else { return [:] }
    return headers.reduce(into: [String: String]()) { normalized, element in
        guard let value = element.value else { return }
        normalized[element.key.lowercased()] = value
    }
}

public func normalizeHeaders(_ headers: [String: String]) -> [String: String] {
    headers.reduce(into: [String: String]()) { normalized, element in
        normalized[element.key.lowercased()] = element.value
    }
}

public func normalizeHeaderEntries(_ entries: [(String, String?)]) -> [String: String] {
    entries.reduce(into: [String: String]()) { normalized, element in
        guard let value = element.1 else { return }
        normalized[element.0.lowercased()] = value
    }
}

public func combineHeaders(_ headers: [String: String]...) -> [String: String] {
    headers.reduce(into: [String: String]()) { combined, current in
        combined.merge(current) { _, new in new }
    }
}

public func prepareHeaders(_ headers: [String: String?]?, defaultHeaders: [String: String]) -> [String: String] {
    var preparedHeaders = normalizeHeaders(headers)
    for (key, value) in normalizeHeaders(defaultHeaders) where preparedHeaders[key] == nil {
        preparedHeaders[key] = value
    }
    return preparedHeaders
}

public func prepareHeaders(_ headers: [String: String], defaultHeaders: [String: String]) -> [String: String] {
    prepareHeaders(headers.mapValues(Optional.some), defaultHeaders: defaultHeaders)
}

public func withUserAgentSuffix(_ headers: [String: String?]? = nil, _ userAgentSuffixParts: String...) -> [String: String] {
    headersWithUserAgentSuffix(normalizeHeaders(headers), userAgentSuffixParts)
}

public func withUserAgentSuffix(_ headers: [String: String], _ userAgentSuffixParts: String...) -> [String: String] {
    headersWithUserAgentSuffix(normalizeHeaders(headers), userAgentSuffixParts)
}

private func headersWithUserAgentSuffix(_ headers: [String: String], _ userAgentSuffixParts: [String]) -> [String: String] {
    var output = headers
    let currentUserAgent = output["user-agent"] ?? ""
    output["user-agent"] = ([currentUserAgent] + userAgentSuffixParts)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return output
}

public func encodeJSONBody(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

public func decodeJSONBody(_ data: Data) throws -> JSONValue {
    guard let text = String(data: data, encoding: .utf8) else {
        throw AIJSONParseError(text: "", message: "JSON body is not valid UTF-8.")
    }
    return try secureJSONParse(text)
}

public func requireURL(_ string: String) throws -> URL {
    guard let url = URL(string: string) else { throw AIError.invalidURL(string) }
    return url
}

public func isSameOrigin(_ lhs: String, _ rhs: String) -> Bool {
    guard let left = URLComponents(string: lhs),
          let right = URLComponents(string: rhs),
          let leftScheme = left.scheme?.lowercased(),
          let rightScheme = right.scheme?.lowercased(),
          let leftHost = left.host?.lowercased(),
          let rightHost = right.host?.lowercased(),
          leftScheme == rightScheme,
          leftHost == rightHost else {
        return false
    }
    return (left.port ?? defaultPort(for: leftScheme)) == (right.port ?? defaultPort(for: rightScheme))
}

private func defaultPort(for scheme: String) -> Int? {
    switch scheme {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
}

/// Mirrors upstream provider-utils download URL validation before fetching
/// provider-returned or user-provided remote assets.
public func validateDownloadURL(_ string: String) throws -> URL {
    guard let url = URL(string: string),
          let scheme = url.scheme?.lowercased(),
          !scheme.isEmpty else {
        throw AIError.invalidURL(string)
    }

    if scheme == "data" {
        return url
    }

    guard scheme == "http" || scheme == "https" else {
        throw AIError.invalidArgument(argument: "url", message: "URL scheme must be http, https, or data, got \(scheme):")
    }

    guard let rawHost = url.host, !rawHost.isEmpty else {
        throw AIError.invalidArgument(argument: "url", message: "URL must have a hostname.")
    }

    let host = rawHost.lowercased().strippingTrailingDots()
        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal") {
        throw AIError.invalidArgument(argument: "url", message: "URL with hostname \(host) is not allowed.")
    }

    if let ipv4 = ipv4Bytes(host) {
        if isPrivateIPv4(ipv4) {
            throw AIError.invalidArgument(argument: "url", message: "URL with IP address \(host) is not allowed.")
        }
        return url
    }

    if host.contains(":") {
        guard let ipv6 = ipv6Bytes(host), !isPrivateIPv6(ipv6) else {
            throw AIError.invalidArgument(argument: "url", message: "URL with IPv6 address \(host) is not allowed.")
        }
    }

    return url
}

public func fetchUntrustedURL(
    _ string: String,
    transport: any AITransport,
    headers: [String: String] = [:],
    abortSignal: AIAbortSignal? = nil,
    maxBytes: Int = AIDefaultMaxDownloadSize,
    trustedOrigin: String? = nil,
    credentialedOrigin: String? = nil,
    untrustedFirstHopHeaders: [String] = []
) async throws -> AIHTTPResponse {
    let sanitizedHeaders = sanitizedDownloadRequestHeaders(headers)
    let resolvedCredentialedOrigin = credentialedOrigin ?? trustedOrigin
    let firstHopHeaders: [String: String]
    if let resolvedCredentialedOrigin, isSameOrigin(string, resolvedCredentialedOrigin) {
        firstHopHeaders = sanitizedHeaders
    } else {
        let allowedHeaders = safeUntrustedFirstHopHeaders.union(
            untrustedFirstHopHeaders.map { $0.lowercased() }
        )
        firstHopHeaders = sanitizedHeaders.filter {
            allowedHeaders.contains($0.key.lowercased())
        }
    }
    return try await downloadURL(
        string,
        transport: transport,
        headers: firstHopHeaders,
        abortSignal: abortSignal,
        maxBytes: maxBytes,
        trustedOrigin: trustedOrigin
    )
}

public func downloadURL(
    _ string: String,
    transport: AITransport,
    headers: [String: String] = [:],
    abortSignal: AIAbortSignal? = nil,
    maxBytes: Int = AIDefaultMaxDownloadSize,
    trustedOrigin: String? = nil,
    credentialedOrigin: String? = nil
) async throws -> AIHTTPResponse {
    let initialURL = try validatedRemoteURL(string, trustedOrigin: trustedOrigin)
    if initialURL.scheme?.lowercased() == "data" {
        return try downloadDataURL(initialURL)
    }

    var current = string
    let sanitizedHeaders = sanitizedDownloadRequestHeaders(headers)
    var currentHeaders = if let credentialedOrigin, !isSameOrigin(string, credentialedOrigin) {
        userAgentOnlyHeaders(sanitizedHeaders)
    } else {
        sanitizedHeaders
    }
    let maxRedirects = 10
    for _ in 0...maxRedirects {
        let url = try validatedRemoteURL(current, trustedOrigin: trustedOrigin)
        let request = AIHTTPRequest(
            method: "GET",
            url: url,
            headers: currentHeaders,
            abortSignal: abortSignal,
            maxResponseBytes: maxBytes,
            followRedirects: false
        )
        let response: AIHTTPResponse
        if let trustedOrigin, isSameOrigin(url.absoluteString, trustedOrigin) {
            response = try await transport.send(request)
        } else {
            response = try await transport.sendValidatedDownload(request)
        }
        if httpRedirectStatusCodes.contains(response.statusCode),
           let location = response.headerValue("location"),
           let nextURL = URL(string: location, relativeTo: url)?.absoluteURL {
            _ = try validatedRemoteURL(nextURL.absoluteString, trustedOrigin: trustedOrigin)
            currentHeaders = redirectedRequestHeaders(currentHeaders, from: url, to: nextURL)
            current = nextURL.absoluteString
            continue
        }
        if let finalURL = response.url, finalURL != url {
            _ = try validatedRemoteURL(finalURL.absoluteString, trustedOrigin: trustedOrigin)
        }
        if response.body.count > maxBytes {
            throw AIDownloadError(
                url: string,
                message: downloadSizeLimitExceededMessage(url: string, maxBytes: maxBytes)
            )
        }
        return response
    }
    throw AIDownloadError(url: string, message: "Too many redirects (max \(maxRedirects)).")
}

/// Streams a response-supplied URL with the same URL and redirect protections as
/// `downloadURL`. Callers can identify the only origin allowed to receive their
/// credentials and separately exempt a developer-configured origin from the
/// private-address guard (for example, a local test or self-hosted endpoint).
public func streamDownloadURL(
    _ string: String,
    transport: any AIStreamingTransport,
    headers: [String: String] = [:],
    credentialedOrigin: String? = nil,
    trustedOrigin: String? = nil,
    abortSignal: AIAbortSignal? = nil,
    maxBytes: Int = AIDefaultMaxDownloadSize
) async throws -> (response: AIHTTPStreamResponse, request: AIHTTPRequest) {
    var current = string
    let sanitizedHeaders = sanitizedDownloadRequestHeaders(headers)
    var currentHeaders: [String: String]
    if let credentialedOrigin, !isSameOrigin(string, credentialedOrigin) {
        currentHeaders = userAgentOnlyHeaders(sanitizedHeaders)
    } else {
        currentHeaders = sanitizedHeaders
    }

    let maxRedirects = 10
    for _ in 0...maxRedirects {
        let url = try validatedRemoteURL(current, trustedOrigin: trustedOrigin)
        let request = AIHTTPRequest(
            method: "GET",
            url: url,
            headers: currentHeaders,
            abortSignal: abortSignal,
            maxResponseBytes: maxBytes,
            followRedirects: false
        )
        let response: AIHTTPStreamResponse
        if let trustedOrigin, isSameOrigin(url.absoluteString, trustedOrigin) {
            response = try await transport.stream(request)
        } else {
            response = try await transport.streamValidatedDownload(request)
        }
        if httpRedirectStatusCodes.contains(response.statusCode),
           let location = response.headerValue("location"),
           let nextURL = URL(string: location, relativeTo: url)?.absoluteURL {
            response.cancelBody()
            _ = try validatedRemoteURL(nextURL.absoluteString, trustedOrigin: trustedOrigin)
            currentHeaders = redirectedRequestHeaders(currentHeaders, from: url, to: nextURL)
            current = nextURL.absoluteString
            continue
        }
        return (response, request)
    }
    throw AIDownloadError(url: string, message: "Too many redirects (max \(maxRedirects)).")
}

private let httpRedirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

private let safeUntrustedFirstHopHeaders: Set<String> = [
    "accept", "accept-language", "baggage", "cache-control", "idempotency-key",
    "if-match", "if-modified-since", "if-none-match", "if-range",
    "if-unmodified-since", "pragma", "range", "traceparent", "tracestate",
    "user-agent", "x-correlation-id", "x-request-id"
]

private let blockedDownloadRequestHeaders: Set<String> = [
    "connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade",
    "host",
    "forwarded", "proxy-authorization", "via", "x-forwarded-for", "x-forwarded-host",
    "x-forwarded-proto", "x-real-ip",
    "metadata", "metadata-flavor", "x-aws-ec2-metadata-token", "x-metadata-token",
    "cookie", "set-cookie"
]

private func sanitizedDownloadRequestHeaders(_ headers: [String: String]) -> [String: String] {
    headers.filter { !blockedDownloadRequestHeaders.contains($0.key.lowercased()) }
}

private func validatedRemoteURL(_ string: String, trustedOrigin: String?) throws -> URL {
    if let trustedOrigin, isSameOrigin(string, trustedOrigin) {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            throw AIError.invalidURL(string)
        }
        return url
    }
    return try validateDownloadURL(string)
}

private func redirectedRequestHeaders(
    _ headers: [String: String],
    from currentURL: URL,
    to nextURL: URL
) -> [String: String] {
    isSameOrigin(currentURL.absoluteString, nextURL.absoluteString)
        ? headers
        : userAgentOnlyHeaders(headers)
}

private func userAgentOnlyHeaders(_ headers: [String: String]) -> [String: String] {
    let normalized = normalizeHeaders(headers)
    return normalized["user-agent"].map { ["user-agent": $0] } ?? [:]
}

private func downloadDataURL(_ url: URL) throws -> AIHTTPResponse {
    let absoluteString = url.absoluteString
    guard absoluteString.lowercased().hasPrefix("data:"),
          let commaIndex = absoluteString.firstIndex(of: ",") else {
        throw AIDownloadError(url: absoluteString, message: "Invalid data URL.")
    }

    let metadata = String(absoluteString[absoluteString.index(absoluteString.startIndex, offsetBy: 5)..<commaIndex])
    let payload = String(absoluteString[absoluteString.index(after: commaIndex)...])
    let metadataParts = metadata.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    let isBase64 = metadataParts.dropFirst().contains { $0.caseInsensitiveCompare("base64") == .orderedSame }
    let mediaType: String
    if metadata.isEmpty {
        mediaType = "text/plain;charset=US-ASCII"
    } else {
        let contentTypeParts = metadataParts.filter {
            $0.caseInsensitiveCompare("base64") != .orderedSame
        }
        mediaType = contentTypeParts.joined(separator: ";")
    }

    let data: Data?
    if isBase64 {
        data = Data(base64Encoded: payload.removingPercentEncoding ?? payload)
    } else if let decoded = payload.removingPercentEncoding {
        data = Data(decoded.utf8)
    } else {
        data = Data(payload.utf8)
    }

    guard let data else {
        throw AIDownloadError(url: absoluteString, message: "Invalid data URL payload.")
    }

    return AIHTTPResponse(
        statusCode: 200,
        headers: ["content-type": mediaType],
        body: data,
        url: url
    )
}

/// Decodes text from a data URL while honoring an explicit charset for both
/// base64 and percent-encoded payloads. Without a charset, bytes are mapped
/// one-to-one like the byte string returned by JavaScript's `atob`.
public func getTextFromDataURL(_ string: String) throws -> String {
    guard let url = URL(string: string), url.scheme?.lowercased() == "data" else {
        throw AIError.invalidArgument(argument: "url", message: "Expected a valid data URL.")
    }
    let response = try downloadDataURL(url)
    let contentType = response.headerValue("content-type") ?? ""
    let charset = contentType
        .split(separator: ";")
        .dropFirst()
        .compactMap { component -> String? in
            let parts = component.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, parts[0].lowercased() == "charset" else { return nil }
            return parts[1]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
        }
        .first

    let encoding: String.Encoding
    switch charset {
    case "utf-8", "utf8":
        encoding = .utf8
    case "us-ascii", "ascii":
        encoding = .ascii
    case "iso-8859-1", "latin1", "latin-1":
        encoding = .isoLatin1
    case "utf-16", "utf16":
        encoding = .utf16
    case "utf-16le", "utf16le":
        encoding = .utf16LittleEndian
    case "utf-16be", "utf16be":
        encoding = .utf16BigEndian
    case nil:
        encoding = .isoLatin1
    default:
        throw AIError.invalidArgument(argument: "url", message: "Unsupported data URL charset '\(charset!)'.")
    }

    guard let text = String(data: response.body, encoding: encoding) else {
        throw AIError.invalidArgument(
            argument: "url",
            message: "Data URL payload is not valid for charset '\(charset ?? "byte-string")'."
        )
    }
    return text
}

public func getTextFromDataUrl(_ string: String) throws -> String {
    try getTextFromDataURL(string)
}

private func parseContentLength(_ value: String) -> Int? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    var result = 0
    var hasDigit = false

    for scalar in trimmed.unicodeScalars {
        guard scalar.value >= 48 && scalar.value <= 57 else { break }
        hasDigit = true
        let digit = Int(scalar.value - 48)
        if result > (Int.max - digit) / 10 {
            return Int.max
        }
        result = result * 10 + digit
    }

    return hasDigit ? result : nil
}

private func downloadSizeLimitExceededMessage(url: String, maxBytes: Int, contentLength: Int? = nil) -> String {
    if let contentLength {
        return "Download of \(url) exceeded maximum size of \(maxBytes) bytes (Content-Length: \(contentLength))."
    }
    return "Download of \(url) exceeded maximum size of \(maxBytes) bytes."
}

func ipv4Bytes(_ host: String) -> [UInt8]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(parts.count),
          parts.allSatisfy({ !$0.isEmpty }) else {
        return nil
    }

    var numbers: [UInt32] = []
    numbers.reserveCapacity(parts.count)
    for part in parts {
        guard let value = ipv4PartValue(String(part)) else { return nil }
        numbers.append(value)
    }

    for number in numbers.dropLast() where number > 255 {
        return nil
    }

    let lastPartMax = (UInt64(1) << UInt64(8 * (5 - numbers.count))) - 1
    guard let last = numbers.last, UInt64(last) <= lastPartMax else {
        return nil
    }

    var value: UInt32 = 0
    for number in numbers.dropLast() {
        value = (value << 8) | number
    }
    value = (value << UInt32(8 * (5 - numbers.count))) | last

    return [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
}

private func ipv4PartValue(_ part: String) -> UInt32? {
    let lowercased = part.lowercased()
    if lowercased.hasPrefix("0x") {
        let digits = lowercased.dropFirst(2)
        guard !digits.isEmpty else { return nil }
        return UInt32(digits, radix: 16)
    }
    if lowercased.count > 1 && lowercased.hasPrefix("0") {
        return UInt32(lowercased.dropFirst(), radix: 8)
    }
    return UInt32(lowercased, radix: 10)
}

func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 4 else { return false }
    let first = bytes[0]
    let second = bytes[1]
    let third = bytes[2]
    if first == 0 { return true }
    if first == 10 { return true }
    if first == 100 && (64...127).contains(second) { return true }
    if first == 127 { return true }
    if first == 169 && second == 254 { return true }
    if first == 172 && (16...31).contains(second) { return true }
    if first == 192 && second == 0 && third == 0 { return true }
    if first == 192 && second == 0 && third == 2 { return true }
    if first == 192 && second == 168 { return true }
    if first == 198 && (second == 18 || second == 19) { return true }
    if first == 198 && second == 51 && third == 100 { return true }
    if first == 203 && second == 0 && third == 113 { return true }
    if first >= 224 { return true }
    return false
}

func ipv6Bytes(_ host: String) -> [UInt8]? {
    let normalized = host.lowercased()
    guard normalized.contains(":") else { return nil }
    let sides = normalized.components(separatedBy: "::")
    guard sides.count <= 2 else { return nil }

    let left = parseIPv6Hextets(sides[0])
    guard let left else { return nil }
    let right = sides.count == 2 ? parseIPv6Hextets(sides[1]) : []
    guard let right else { return nil }

    let hextetCount = left.count + right.count
    let missingCount: Int
    if sides.count == 2 {
        guard hextetCount < 8 else { return nil }
        missingCount = 8 - hextetCount
    } else {
        guard hextetCount == 8 else { return nil }
        missingCount = 0
    }

    let hextets = left + Array(repeating: UInt16(0), count: missingCount) + right
    guard hextets.count == 8 else { return nil }
    return hextets.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
}

private func parseIPv6Hextets(_ value: String) -> [UInt16]? {
    guard !value.isEmpty else { return [] }
    var parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    if let last = parts.last, last.contains(".") {
        guard let ipv4 = ipv4Bytes(last) else { return nil }
        parts.removeLast()
        parts.append(String(format: "%02x%02x", ipv4[0], ipv4[1]))
        parts.append(String(format: "%02x%02x", ipv4[2], ipv4[3]))
    }

    var hextets: [UInt16] = []
    hextets.reserveCapacity(parts.count)
    for part in parts {
        guard !part.isEmpty,
              part.count <= 4,
              let value = UInt16(part, radix: 16) else {
            return nil
        }
        hextets.append(value)
    }
    return hextets
}

func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 16 else { return false }
    if bytes.allSatisfy({ $0 == 0 }) { return true }
    if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
    if (bytes[0] & 0xfe) == 0xfc { return true }
    if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
    if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0 { return true }
    if bytes[0] == 0xff { return true }
    if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return true }
    if bytes[0] == 0x3f && bytes[1] == 0xff && (bytes[2] & 0xf0) == 0x00 { return true }

    let embedsIPv4 = bytes.prefix(12).allSatisfy { $0 == 0 }
        || (bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff)
        || (bytes.prefix(8).allSatisfy { $0 == 0 } && bytes[8] == 0xff && bytes[9] == 0xff && bytes[10] == 0 && bytes[11] == 0)
        || (bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b && bytes[4...11].allSatisfy { $0 == 0 })
        || (bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b && bytes[4] == 0 && bytes[5] == 1)
    if embedsIPv4 {
        return isPrivateIPv4(Array(bytes[12...15]))
    }
    return false
}

public func apiCallError(provider: String, response: AIHTTPResponse) -> AIError {
    apiCallError(
        provider: provider,
        statusCode: response.statusCode,
        body: response.bodyText,
        headers: response.headers
    )
}

public func apiCallError(
    provider: String,
    statusCode: Int,
    body: String,
    headers: [String: String] = [:]
) -> AIError {
    guard !headers.isEmpty else {
        return .apiCall(provider: provider, statusCode: statusCode, body: body)
    }
    return .apiCall(
        provider: provider,
        statusCode: statusCode,
        body: body,
        headers: headers
    )
}

public func withoutTrailingSlash(_ value: String) -> String {
    var result = value
    while result.hasSuffix("/") {
        result.removeLast()
    }
    return result
}

private extension String {
    func strippingTrailingDots() -> String {
        var result = self
        while result.hasSuffix(".") {
            result.removeLast()
        }
        return result
    }
}


public func environmentValue(_ names: [String]) -> String? {
    let environment = ProcessInfo.processInfo.environment
    return names.lazy.compactMap { environment[$0] }.first
}

public func userAgent(_ providerID: String) -> String {
    "SwiftAISDK/\(providerID)"
}

/// Encodes a raw resource identifier as one path segment, including standalone dots.
public func encodePathSegment(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    if encoded == "." { return "%252E" }
    if encoded == ".." { return "%252E%252E" }
    return encoded
}