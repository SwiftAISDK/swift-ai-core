import Foundation
import Network
import Security
import SwiftAIProvider


/// One HTTP/1.1 GET over a numeric Network.framework endpoint. TLS keeps the
/// original hostname for SNI and system certificate/hostname verification.
final class HTTPPinnedConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let request: AIHTTPRequest
    private let lock = NSLock()
    private var closed = false
    private var abortRegistration: AIAbortHandlerRegistration?
    private static let queue = DispatchQueue(label: "SwiftAISDK.pinned-download", qos: .utility)

    init(request: AIHTTPRequest, endpoint: HTTPPinnedEndpoint) throws {
        guard let host = endpoint.address.numericHost,
              let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw AIDownloadError(url: request.url.absoluteString, message: "The pinned endpoint is not a numeric IP address.")
        }
        connection = NWConnection(host: host, port: port, using: Self.parameters(endpoint: endpoint))
        self.request = request
    }

    static func parameters(endpoint: HTTPPinnedEndpoint) -> NWParameters {
        let tls: NWProtocolTLS.Options?
        if endpoint.usesTLS {
            let options = NWProtocolTLS.Options()
            // This API overrides the numeric endpoint's name for certificate
            // verification as well as TLS SNI. Never replace system trust with
            // an accepting verification callback.
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, endpoint.hostname)
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, true)
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
            tls = options
        } else {
            tls = nil
        }
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    deinit { connection.cancel(); abortRegistration?.cancel() }

    static func open(request: AIHTTPRequest, endpoint: HTTPPinnedEndpoint) async throws -> AIHTTPStreamResponse {
        let wireRequest = try makeRequest(request, endpoint: endpoint)
        let socket = try HTTPPinnedConnection(request: request, endpoint: endpoint)
        socket.installAbortHandler()
        do {
            try await socket.start()
            try await socket.send(wireRequest)
            let reader = HTTPPinnedResponseReader(
                url: request.url.absoluteString,
                maxBytes: request.maxResponseBytes ?? AIDefaultMaxDownloadSize,
                receive: { try await socket.receive() },
                cancel: { socket.cancel() }
            )
            let head = try await reader.readHead()
            let body = AsyncThrowingStream<Data, Error>(unfolding: {
                do {
                    try socket.checkCancellation()
                    return try await reader.next()
                }
                catch {
                    socket.cancel()
                    try request.abortSignal?.throwIfAborted()
                    throw error
                }
            })
            return AIHTTPStreamResponse(
                statusCode: head.statusCode, headers: head.headers, body: body,
                cancelBody: { socket.cancel() }
            )
        } catch {
            socket.cancel()
            try request.abortSignal?.throwIfAborted()
            throw error
        }
    }

    private func installAbortHandler() {
        let registration = request.abortSignal?.addAbortHandler { [weak self] _ in self?.cancel() }
        let wasClosed = lock.withLock {
            if closed { return true }
            abortRegistration = registration
            return false
        }
        if wasClosed { registration?.cancel() }
    }

    func cancel() {
        let registration = lock.withLock {
            closed = true
            let registration = abortRegistration
            abortRegistration = nil
            return registration
        }
        registration?.cancel()
        connection.cancel()
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        try request.abortSignal?.throwIfAborted()
        if lock.withLock({ closed }) { throw CancellationError() }
    }

    private func start() async throws {
        try checkCancellation()
        try await HTTPDownloadPending<Void>.run(timeout: 15, cancel: { self.cancel() }) { pending in
            self.connection.stateUpdateHandler = { state in
                switch state {
                case .ready: pending.finish(.success(()))
                case .failed(let error), .waiting(let error): pending.finish(.failure(error))
                case .cancelled: pending.finish(.failure(CancellationError()))
                default: break
                }
            }
            self.connection.start(queue: Self.queue)
        }
        connection.stateUpdateHandler = nil
    }

    private func send(_ data: Data) async throws {
        try checkCancellation()
        try await HTTPDownloadPending<Void>.run(timeout: 30, cancel: { self.cancel() }) { pending in
            self.connection.send(content: data, completion: .contentProcessed { error in
                if let error { pending.finish(.failure(error)) }
                else { pending.finish(.success(())) }
            })
        }
    }

    private func receive() async throws -> Data? {
        try checkCancellation()
        return try await HTTPDownloadPending<Data?>.run(timeout: 30, cancel: { self.cancel() }) { pending in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, complete, error in
                if let error { pending.finish(.failure(error)) }
                else if let data, !data.isEmpty { pending.finish(.success(data)) }
                else if complete { pending.finish(.success(nil)) }
                else { pending.finish(.failure(URLError(.badServerResponse))) }
            }
        }
    }

    static func makeRequest(_ request: AIHTTPRequest, endpoint: HTTPPinnedEndpoint) throws -> Data {
        guard request.method == "GET", request.body == nil, request.bodyStream == nil,
              let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else {
            throw AIDownloadError(url: request.url.absoluteString, message: "Pinned downloads support body-free GET requests only.")
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard target.hasPrefix("/"), target.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw AIDownloadError(url: request.url.absoluteString, message: "Invalid HTTP request target.")
        }
        let hostname = endpoint.hostname.contains(":") ? "[\(endpoint.hostname)]" : endpoint.hostname
        guard hostname.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw AIDownloadError(url: request.url.absoluteString, message: "Invalid HTTP hostname.")
        }
        var text = "GET \(target) HTTP/1.1\r\nHost: \(hostname):\(endpoint.port)\r\nConnection: close\r\nAccept-Encoding: identity\r\n"
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            guard !name.isEmpty, name.utf8.allSatisfy(httpTokenByte),
                  value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else {
                throw AIDownloadError(url: request.url.absoluteString, message: "Invalid HTTP request header.")
            }
            // Framing is owned by this connector, not a caller-supplied header.
            guard !["host", "connection", "accept-encoding", "content-length", "transfer-encoding", "expect", "upgrade", "te", "trailer"].contains(name.lowercased()) else { continue }
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        guard text.utf8.count <= 64 * 1024 else {
            throw AIDownloadError(url: request.url.absoluteString, message: "HTTP request headers exceed 65536 bytes.")
        }
        return Data(text.utf8)
    }
}

struct HTTPPinnedResponseHead: Sendable {
    let statusCode: Int
    let headers: [String: String]
}

/// A demand-driven HTTP/1.1 decoder. Its only input is the already pinned
/// connection. It never interprets redirects or opens another connection.
actor HTTPPinnedResponseReader {
    private enum Framing { case none, length(Int), chunked, untilEOF }
    private let url: String
    private let maxBytes: Int
    private let receive: @Sendable () async throws -> Data?
    private let cancel: @Sendable () -> Void
    private var buffer = Data()
    private var framing: Framing = .none
    private var totalBytes = 0
    private var chunkRemaining = 0
    private var chunkNeedsTerminator = false
    private var finished = false
    private var headRead = false
    private var metadataBytes = 0
    private var operationInProgress = false

    init(url: String, maxBytes: Int, receive: @escaping @Sendable () async throws -> Data?, cancel: @escaping @Sendable () -> Void) {
        self.url = url; self.maxBytes = maxBytes; self.receive = receive; self.cancel = cancel
    }

    deinit { cancel() }

    func readHead() async throws -> HTTPPinnedResponseHead {
        try beginRead()
        defer { operationInProgress = false }
        do {
            guard !headRead, maxBytes >= 0 else { throw failure("Invalid HTTP response reader state.") }
            for _ in 0..<16 {
                let statusLine = try await line(limit: 8 * 1024)
                let parts = statusLine.split(separator: " ", omittingEmptySubsequences: false)
                guard parts.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(String(parts[0])),
                      parts[1].count == 3, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
                      let status = Int(parts[1]), (100...599).contains(status) else {
                    throw failure("Malformed HTTP status line.")
                }
                var headers: [String: String] = [:]
                while true {
                    let value = try await line(limit: 64 * 1024)
                    if value.isEmpty { break }
                    let (name, content) = try header(value)
                    if let old = headers[name] { headers[name] = old + ", " + content }
                    else { headers[name] = content }
                }
                let length = try contentLength(headers["content-length"])
                let transfer = headers["transfer-encoding"]?.lowercased()
                guard transfer == nil || (transfer == "chunked" && length == nil) else {
                    throw failure("Ambiguous or unsupported HTTP response framing.")
                }
                if status < 200 {
                    guard status != 101, transfer == nil, length == nil else {
                        throw failure("Unsupported HTTP informational response.")
                    }
                    continue
                }
                let encoding = headers["content-encoding"]?.lowercased()
                guard encoding == nil || encoding == "identity" else {
                    throw failure("Pinned downloads require identity Content-Encoding.")
                }
                if status == 204 || status == 304 {
                    guard transfer == nil, status != 204 || length == nil || length == 0 else {
                        throw failure("Unexpected framing on an empty HTTP response.")
                    }
                    framing = .none
                } else if let length {
                    guard length <= maxBytes else { throw sizeFailure(contentLength: length) }
                    framing = .length(length)
                } else {
                    framing = transfer == "chunked" ? .chunked : .untilEOF
                }
                headRead = true
                return HTTPPinnedResponseHead(statusCode: status, headers: headers)
            }
            throw failure("Too many informational HTTP responses.")
        } catch { cancel(); throw error }
    }

    func next() async throws -> Data? {
        try beginRead()
        defer { operationInProgress = false }
        do {
            try Task.checkCancellation()
            guard headRead else { throw failure("HTTP headers have not been read.") }
            if finished { return nil }
            let chunk: Data
            switch framing {
            case .none: return complete()
            case .length(let remaining):
                if remaining == 0 { return complete() }
                guard try await fill() else { throw failure("HTTP response ended before Content-Length bytes arrived.") }
                chunk = take(min(remaining, buffer.count))
                framing = .length(remaining - chunk.count)
            case .untilEOF:
                guard try await fill() else { return complete() }
                chunk = take(buffer.count)
            case .chunked:
                if chunkRemaining == 0 {
                    if chunkNeedsTerminator {
                        guard try await line(limit: 0, countMetadata: false).isEmpty else {
                            throw failure("Malformed HTTP chunk terminator.")
                        }
                    }
                    chunkRemaining = try chunkSize(try await line(limit: 8 * 1024, countMetadata: false))
                    if chunkRemaining == 0 {
                        metadataBytes = 0
                        while true {
                            let trailer = try await line(limit: 16 * 1024)
                            guard metadataBytes <= 16 * 1024 else { throw failure("HTTP trailers exceed 16384 bytes.") }
                            if trailer.isEmpty { break }
                            let (name, _) = try header(trailer)
                            guard !["content-length", "transfer-encoding", "host", "content-encoding", "location", "connection", "trailer"].contains(name) else {
                                throw failure("Forbidden HTTP trailer field.")
                            }
                        }
                        return complete()
                    }
                    guard chunkRemaining <= maxBytes - totalBytes else { throw sizeFailure() }
                    chunkNeedsTerminator = true
                }
                guard try await fill() else { throw failure("HTTP response ended inside a chunk.") }
                chunk = take(min(chunkRemaining, buffer.count))
                chunkRemaining -= chunk.count
            }
            guard chunk.count <= maxBytes - totalBytes else { throw sizeFailure() }
            totalBytes += chunk.count
            return chunk
        } catch { cancel(); throw error }
    }

    private func complete() -> Data? { finished = true; buffer.removeAll(); cancel(); return nil }
    private func beginRead() throws {
        guard !operationInProgress else {
            throw AIError.invalidArgument(argument: "response.body", message: "An HTTP response supports only one active read.")
        }
        operationInProgress = true
    }
    private func failure(_ message: String) -> AIDownloadError { AIDownloadError(url: url, message: message) }
    private func sizeFailure(contentLength: Int? = nil) -> AIDownloadError {
        failure("Download of \(url) exceeded maximum size of \(maxBytes) bytes." + (contentLength.map { " Content-Length: \($0)." } ?? ""))
    }
    private func take(_ count: Int) -> Data {
        let result = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return result
    }
    private func fill() async throws -> Bool {
        if !buffer.isEmpty { return true }
        guard let next = try await receive(), !next.isEmpty else { return false }
        buffer = next
        return true
    }
    private func line(limit: Int, countMetadata: Bool = true) async throws -> String {
        while true {
            if let end = buffer.range(of: Data([13, 10])) {
                let count = buffer.distance(from: buffer.startIndex, to: end.lowerBound)
                guard count <= limit else { throw failure("HTTP metadata line exceeds its limit.") }
                let bytes = take(count + 2).dropLast(2)
                guard bytes.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }),
                      let text = String(data: bytes, encoding: .isoLatin1) else {
                    throw failure("Malformed HTTP metadata line.")
                }
                if countMetadata {
                    metadataBytes += count + 2
                    guard metadataBytes <= 64 * 1024 else { throw failure("HTTP headers exceed 65536 bytes.") }
                }
                return text
            }
            guard buffer.count <= limit + 1, !buffer.contains(10) else { throw failure("Malformed or oversized HTTP metadata.") }
            guard let data = try await receive(), !data.isEmpty else { throw failure("HTTP response ended inside metadata.") }
            buffer.append(data)
        }
    }
    private func header(_ line: String) throws -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { throw failure("Malformed HTTP header.") }
        let name = String(line[..<colon])
        guard !name.isEmpty, name.utf8.allSatisfy(httpTokenByte) else { throw failure("Malformed HTTP header name.") }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return (name.lowercased(), value)
    }
    private func contentLength(_ value: String?) throws -> Int? {
        guard let value else { return nil }
        let values = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
        let parsed = values.compactMap { text -> Int? in
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(text)
        }
        guard parsed.count == values.count, let first = parsed.first, parsed.allSatisfy({ $0 == first }) else {
            throw failure("Invalid or conflicting Content-Length.")
        }
        return first
    }
    private func chunkSize(_ line: String) throws -> Int {
        let bytes = Array(line.utf8)
        var cursor = 0
        while cursor < bytes.count, (48...57).contains(bytes[cursor]) || (65...70).contains(bytes[cursor]) || (97...102).contains(bytes[cursor]) { cursor += 1 }
        guard cursor > 0, let size = Int(String(decoding: bytes[..<cursor], as: UTF8.self), radix: 16) else {
            throw failure("Malformed HTTP chunk size.")
        }
        func skipWhitespace() { while cursor < bytes.count, bytes[cursor] == 32 || bytes[cursor] == 9 { cursor += 1 } }
        while cursor < bytes.count {
            skipWhitespace()
            guard cursor < bytes.count, bytes[cursor] == 59 else { throw failure("Malformed HTTP chunk extension.") }
            cursor += 1
            skipWhitespace()
            let nameStart = cursor
            while cursor < bytes.count, httpTokenByte(bytes[cursor]) { cursor += 1 }
            guard cursor > nameStart else { throw failure("Malformed HTTP chunk extension.") }
            skipWhitespace()
            if cursor < bytes.count, bytes[cursor] == 61 {
                cursor += 1
                skipWhitespace()
                if cursor < bytes.count, bytes[cursor] == 34 {
                    cursor += 1
                    var closedQuote = false
                    while cursor < bytes.count {
                        let byte = bytes[cursor]
                        cursor += 1
                        if byte == 34 { closedQuote = true; break }
                        if byte == 92 {
                            guard cursor < bytes.count else { throw failure("Malformed quoted chunk extension.") }
                            cursor += 1
                        }
                    }
                    guard closedQuote else { throw failure("Malformed quoted chunk extension.") }
                } else {
                    let valueStart = cursor
                    while cursor < bytes.count, httpTokenByte(bytes[cursor]) { cursor += 1 }
                    guard cursor > valueStart else { throw failure("Malformed HTTP chunk extension value.") }
                }
            }
        }
        return size
    }
}

private func httpTokenByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || "!#$%&'*+-.^_`|~".utf8.contains(byte)
}