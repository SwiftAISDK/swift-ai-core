import Foundation
import Darwin
import Network
import SwiftAIProvider


/// A resolver result, never a hostname that a connector may resolve again.
struct HTTPResolvedAddress: Hashable, Sendable {
    let address: String
    let family: Int

    var numericHost: NWEndpoint.Host? {
        switch family {
        case 4: IPv4Address(address).map(NWEndpoint.Host.ipv4)
        case 6: IPv6Address(address).map(NWEndpoint.Host.ipv6)
        default: nil
        }
    }
}

struct HTTPPinnedEndpoint: Sendable {
    let address: HTTPResolvedAddress
    let hostname: String
    let port: UInt16
    let usesTLS: Bool
}

/// The resolver and connector are separate for deterministic regression tests.
/// Production always passes a numeric endpoint to Network.framework.
struct HTTPDNSPinnedTransport: Sendable {
    typealias Resolver = @Sendable (String) async throws -> [HTTPResolvedAddress]
    typealias Connector = @Sendable (AIHTTPRequest, HTTPPinnedEndpoint) async throws -> AIHTTPStreamResponse
    var resolve: Resolver = systemDownloadAddresses
    var connect: Connector = { request, endpoint in
        try await HTTPPinnedConnection.open(request: request, endpoint: endpoint)
    }

    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        try request.abortSignal?.throwIfAborted()
        try Task.checkCancellation()
        let operation: @Sendable () async throws -> AIHTTPStreamResponse = {
            let url = try validateDownloadURL(request.url.absoluteString)
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let rawHost = url.host,
                  url.user == nil, url.password == nil,
                  let port = UInt16(exactly: url.port ?? (scheme == "https" ? 443 : 80)), port > 0,
                  request.method == "GET", request.body == nil, request.bodyStream == nil,
                  !request.followRedirects,
                  (request.maxResponseBytes ?? AIDefaultMaxDownloadSize) >= 0 else {
                throw AIDownloadError(url: request.url.absoluteString, message: "Pinned downloads require a body-free HTTP(S) GET, a valid port, no URL credentials, and manual redirects.")
            }
            let hostname = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let addresses: [HTTPResolvedAddress]
            if let bytes = ipv4Bytes(hostname) {
                // Canonicalize historical numeric IPv4 forms before connecting.
                addresses = [HTTPResolvedAddress(address: bytes.map(String.init).joined(separator: "."), family: 4)]
            } else if IPv6Address(hostname) != nil {
                addresses = [HTTPResolvedAddress(address: hostname, family: 6)]
            } else {
                addresses = try await resolve(hostname)
            }
            try validateDownloadAddresses(addresses, hostname: hostname, url: url.absoluteString)
            try Task.checkCancellation()
            try request.abortSignal?.throwIfAborted()

            var lastError: (any Error)?
            // Validate every answer above, including those beyond this bounded
            // retry budget. Never perform another DNS lookup on retry.
            var seen = Set<HTTPResolvedAddress>()
            for address in addresses.filter({ seen.insert($0).inserted }).prefix(8) {
                try Task.checkCancellation()
                try request.abortSignal?.throwIfAborted()
                do {
                    return try await connect(request, HTTPPinnedEndpoint(
                        address: address, hostname: hostname, port: port, usesTLS: scheme == "https"
                    ))
                } catch {
                    try Task.checkCancellation()
                    try request.abortSignal?.throwIfAborted()
                    guard error is NWError || (error as? URLError).map({
                        [.cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet].contains($0.code)
                    }) == true else { throw error }
                    lastError = error
                }
            }
            throw lastError ?? AIDownloadError(url: url.absoluteString, message: "No validated address is available.")
        }
        if let signal = request.abortSignal {
            return try await raceAbortSignal(signal, operation: operation)
        }
        return try await operation()
    }
}

func validateDownloadAddresses(_ addresses: [HTTPResolvedAddress], hostname: String, url: String) throws {
    guard !addresses.isEmpty else {
        throw AIDownloadError(url: url, message: "Hostname \(hostname) did not resolve to an address.")
    }
    for address in addresses {
        let valid: Bool
        switch address.family {
        case 4:
            valid = IPv4Address(address.address) != nil
                && ipv4Bytes(address.address).map { !isPrivateIPv4($0) } == true
        case 6:
            valid = IPv6Address(address.address) != nil
                && ipv6Bytes(address.address).map { !isPrivateIPv6($0) } == true
        default:
            valid = false
        }
        guard valid else {
            throw AIDownloadError(url: url, message: "Hostname \(hostname) resolved to disallowed IP address \(address.address).")
        }
    }
}

private let downloadDNSQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "SwiftAISDK.download-dns"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 4
    return queue
}()

/// getaddrinfo itself is synchronous. The caller's cancellation/timeout wins
/// immediately; a late resolver result can never proceed to a connection.
func systemDownloadAddresses(_ hostname: String) async throws -> [HTTPResolvedAddress] {
    try await HTTPDownloadPending<[HTTPResolvedAddress]>.run(timeout: 30) { pending in
        downloadDNSQueue.addOperation {
            guard !pending.isFinished else { return }
            pending.finish(Result {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(hostname, nil, &hints, &result)
                guard status == 0 else {
                    throw AIDownloadError(url: hostname, message: "DNS lookup failed: \(String(cString: gai_strerror(status))).")
                }
                defer { if let result { freeaddrinfo(result) } }
                var addresses: [HTTPResolvedAddress] = []
                var cursor = result
                while let node = cursor {
                    let info = node.pointee
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard let address = info.ai_addr,
                          (info.ai_family == AF_INET || info.ai_family == AF_INET6),
                          getnameinfo(address, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                        throw AIDownloadError(url: hostname, message: "DNS returned an unsupported address.")
                    }
                    let text = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    let value = HTTPResolvedAddress(address: text, family: info.ai_family == AF_INET ? 4 : 6)
                    if !addresses.contains(value) { addresses.append(value) }
                    cursor = info.ai_next
                }
                return addresses
            })
        }
    }
}

/// One-shot continuation shared by DNS and Network callbacks. Completion and
/// cancellation are linearized, including cancellation before installation.
final class HTTPDownloadPending<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var completed = false
    private var installed = false

    var isFinished: Bool { lock.withLock { completed } }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let completed = lock.withLock { () -> Result<Value, Error>? in
            precondition(!installed, "A download operation can be awaited only once.")
            installed = true
            if self.completed {
                let delivered = result
                result = nil
                return delivered
            }
            self.continuation = continuation
            return nil as Result<Value, Error>?
        }
        if let completed { continuation.resume(with: completed) }
    }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        let (accepted, waiting) = lock.withLock {
            guard !completed else { return (false, nil as CheckedContinuation<Value, Error>?) }
            completed = true
            let waiting = continuation
            continuation = nil
            // Preserve a result only until the continuation is installed.
            // Network/DNS callbacks may retain this box after completion.
            if waiting == nil { self.result = result }
            return (true, waiting)
        }
        waiting?.resume(with: result)
        return accepted
    }

    static func run(
        timeout: TimeInterval,
        cancel: @escaping @Sendable () -> Void = {},
        start: @escaping @Sendable (HTTPDownloadPending<Value>) -> Void
    ) async throws -> Value {
        let pending = HTTPDownloadPending<Value>()
        return try await pending.value(timeout: timeout, cancel: cancel, start: start)
    }

    func value(
        timeout: TimeInterval,
        cancel: @escaping @Sendable () -> Void = {},
        start: @escaping @Sendable (HTTPDownloadPending<Value>) -> Void = { _ in }
    ) async throws -> Value {
        let pending = self
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler {
            if pending.finish(.failure(URLError(.timedOut))) { cancel() }
        }
        timer.schedule(deadline: .now() + timeout)
        timer.resume()
        // Unlike an asyncAfter work item, a cancelled source drops its event
        // handler immediately instead of retaining each response chunk and
        // socket until a future timeout deadline.
        defer { timer.setEventHandler {}; timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                guard !pending.isFinished else { return }
                start(pending)
            }
        } onCancel: {
            pending.finish(.failure(CancellationError()))
            cancel()
        }
    }
}