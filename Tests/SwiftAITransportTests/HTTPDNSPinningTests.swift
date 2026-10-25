import Foundation
import Network
import Security
import Testing
@testable import SwiftAITransport
import SwiftAIProvider

@Suite struct HTTPDNSPinningTests {
    @Test func validatesEveryDNSAnswerBeforeConnecting() async throws {
        let probe = DNSPinningProbe()
        let transport = HTTPDNSPinnedTransport(resolve: { _ in [
            .init(address: "8.8.8.8", family: 4), .init(address: "169.254.169.254", family: 4)
        ] }, connect: { _, endpoint in await probe.connected(endpoint); return emptyDNSResponse() })
        await #expect(throws: AIDownloadError.self) { try await transport.stream(dnsRequest()) }
        #expect(await probe.endpoints.isEmpty)
    }

    @Test(arguments: [
        HTTPResolvedAddress(address: "::1", family: 6),
        .init(address: "::ffff:127.0.0.1", family: 6),
        .init(address: "fd00::1", family: 6),
        .init(address: "64:ff9b::169.254.169.254", family: 6),
        .init(address: "198.18.0.1", family: 4),
        .init(address: "127.0.0.1", family: 4),
        .init(address: "8.8.8.8", family: 6),
        .init(address: "not-an-address", family: 4)
    ])
    func rejectsPrivateAndMalformedDNSAnswers(_ address: HTTPResolvedAddress) throws {
        #expect(throws: AIDownloadError.self) {
            try validateDownloadAddresses([address], hostname: "files.example", url: "https://files.example")
        }
    }

    @Test func rejectsEmptyDNSAnswers() {
        #expect(throws: AIDownloadError.self) { try validateDownloadAddresses([], hostname: "example.com", url: "https://example.com") }
    }

    @Test func retriesOnlyTheOriginalValidatedAddressesWithoutRebinding() async throws {
        let probe = DNSPinningProbe()
        let addresses: [HTTPResolvedAddress] = [.init(address: "8.8.8.8", family: 4), .init(address: "2606:4700:4700::1111", family: 6)]
        let transport = HTTPDNSPinnedTransport(resolve: { host in
            await probe.resolved(host)
            return await probe.hosts.count == 1 ? addresses : [.init(address: "127.0.0.1", family: 4)]
        }, connect: { _, endpoint in
            await probe.connected(endpoint)
            if endpoint.address.family == 4 { throw URLError(.cannotConnectToHost) }
            return emptyDNSResponse()
        })
        let response = try await transport.stream(dnsRequest())
        response.cancelBody()
        #expect(await probe.hosts == ["files.example"])
        #expect(await probe.endpoints.map(\.address) == addresses)
        #expect(await probe.endpoints.allSatisfy { $0.hostname == "files.example" && $0.usesTLS && $0.port == 443 })
        for endpoint in await probe.endpoints {
            switch endpoint.address.numericHost {
            case .ipv4?, .ipv6?: break
            default: Issue.record("A pinned endpoint must never be a DNS hostname.")
            }
        }
    }

    @Test func literalPublicAddressesDoNotResolveAgain() async throws {
        let transport = HTTPDNSPinnedTransport(resolve: { _ in Issue.record("Unexpected DNS lookup"); return [] }, connect: { _, _ in emptyDNSResponse() })
        for url in ["https://8.8.8.8/file", "https://[2606:4700:4700::1111]/file"] {
            let response = try await transport.stream(dnsRequest(url))
            response.cancelBody()
        }
    }

    @Test func unsupportedTransportsAndCustomSessionsFailBeforeSending() async throws {
        let custom = UnsafeDNSFixtureTransport()
        await #expect(throws: AIDownloadError.self) { try await fetchUntrustedURL("https://files.example/file", transport: custom) }
        await #expect(throws: AIDownloadError.self) { try await streamDownloadURL("https://files.example/file", transport: custom) }
        #expect(await custom.sendCount == 0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionTransport(session: session)
        await #expect(throws: AIDownloadError.self) { try await transport.sendValidatedDownload(dnsRequest()) }
        await #expect(throws: AIDownloadError.self) { try await transport.streamValidatedDownload(dnsRequest()) }
    }

    @Test func trustedOriginUsesConfiguredTransportButRedirectDoesNotInheritTrust() async throws {
        let custom = UnsafeDNSFixtureTransport(redirect: "https://files.example/file")
        await #expect(throws: AIDownloadError.self) {
            try await fetchUntrustedURL("http://localhost/file", transport: custom, trustedOrigin: "http://localhost")
        }
        #expect(await custom.sendCount == 1)
    }

    @Test func everyRedirectResolvesAgainAndRejectsPrivateDestinationBeforeConnect() async throws {
        let probe = DNSPinningProbe()
        let protected = HTTPDNSPinnedTransport(resolve: { host in
            await probe.resolved(host)
            return [.init(address: host == "files.example" ? "8.8.8.8" : "127.0.0.1", family: 4)]
        }, connect: { _, endpoint in
            await probe.connected(endpoint)
            return AIHTTPStreamResponse(statusCode: 302, headers: ["location": "https://redirect.example/private"], body: AsyncThrowingStream { $0.finish() })
        })
        let transport = ProtectedDNSFixtureTransport(protected: protected)
        await #expect(throws: AIDownloadError.self) {
            try await streamDownloadURL("https://files.example/file", transport: transport)
        }
        #expect(await probe.hosts == ["files.example", "redirect.example"])
        #expect(await probe.endpoints.count == 1)
    }

    @Test func cancellationDoesNotWaitForAResolverCallback() async throws {
        let started = HTTPDownloadPending<Void>()
        let operation = Task {
            try await HTTPDownloadPending<[HTTPResolvedAddress]>.run(timeout: 30) { _ in
                // Model an OS DNS call that has not completed and cannot be
                // interrupted. It must not retain the caller's continuation.
                started.finish(.success(()))
            }
        }
        try await started.value(timeout: 5)
        let start = Date()
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test(arguments: [false, true])
    func completedOperationReleasesResultWhilePendingBoxRemainsAlive(finishBeforeInstall: Bool) async throws {
        let pending = HTTPDownloadPending<DNSReleaseSentinel>()
        let probe = try await completedDNSTimerProbe(pending: pending, finishBeforeInstall: finishBeforeInstall)
        // Model a DNS/Network callback retaining the box after delivery. A
        // cached Result must be released even while that callback stays alive.
        withExtendedLifetime(pending) {
            #expect(pending.isFinished)
            #expect(probe.value == nil)
        }
    }

    @Test func abortedDNSCannotStartAConnection() async throws {
        let controller = AIAbortController()
        let probe = DNSPinningProbe()
        let transport = HTTPDNSPinnedTransport(resolve: { _ in
            controller.abort()
            return [.init(address: "8.8.8.8", family: 4)]
        }, connect: { _, endpoint in await probe.connected(endpoint); return emptyDNSResponse() })
        var request = dnsRequest()
        request.abortSignal = controller.signal
        await #expect(throws: AIAbortError.self) { try await transport.stream(request) }
        #expect(await probe.endpoints.isEmpty)
    }

    @Test func requestFramingKeepsHostnameAndRejectsHeaderInjection() throws {
        let endpoint = dnsEndpoint(port: 8443)
        var request = dnsRequest("https://files.example:8443/path%20name?q=a%20b#fragment")
        request.headers = ["Host": "attacker", "Accept-Encoding": "gzip", "Authorization": "Bearer fixture"]
        let text = String(decoding: try HTTPPinnedConnection.makeRequest(request, endpoint: endpoint), as: UTF8.self)
        #expect(text.hasPrefix("GET /path%20name?q=a%20b HTTP/1.1\r\n"))
        #expect(text.contains("Host: files.example:8443\r\n"))
        #expect(text.contains("Accept-Encoding: identity\r\n"))
        #expect(!text.contains("attacker"))
        for headers in [["x-header": "ok\r\nHost: attacker"], ["bad name": "value"], ["x-header": "nul\0value"]] {
            request.headers = headers
            #expect(throws: AIDownloadError.self) { try HTTPPinnedConnection.makeRequest(request, endpoint: endpoint) }
        }
    }

    @Test func parsesInterimChunkedErrorBodyAndTrailers() async throws {
        let bytes = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 429 Too Many Requests\r\nTransfer-Encoding: chunked\r\n\r\n3;part=\"one;two\\\"three\"\r\nerr\r\n2\r\nor\r\n0\r\nX-End: yes\r\n\r\n"
        let source = DNSByteSource(Array(bytes.utf8).map { Data([$0]) })
        let reader = dnsReader(source, maxBytes: 5)
        let head = try await reader.readHead()
        #expect(head.statusCode == 429)
        var body = Data()
        while let chunk = try await reader.next() { body.append(chunk) }
        #expect(String(decoding: body, as: UTF8.self) == "error")
    }

    @Test(arguments: [
        "Content-Length: 2\r\nContent-Length: 3\r\n\r\nab",
        "Content-Length: -1\r\n\r\n",
        "Content-Length: +1\r\n\r\na",
        "Content-Length: 999999999999999999999999\r\n\r\n",
        "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "Transfer-Encoding: gzip, chunked\r\n\r\n",
        "Content-Encoding: gzip\r\n\r\n",
        "Bad Header: value\r\n\r\n",
        "X-Test: value\nInjected: value\r\n\r\n",
        "Transfer-Encoding: chunked\r\n\r\n+1\r\nx\r\n0\r\n\r\n",
        "Transfer-Encoding: chunked\r\n\r\n1\r\nxX\r\n0\r\n\r\n",
        "Transfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 42\r\n\r\n",
        "Transfer-Encoding: chunked\r\n\r\n1;bad name=value\r\nx\r\n0\r\n\r\n",
        "Transfer-Encoding: chunked\r\n\r\n1;bad=\"unterminated\r\nx\r\n0\r\n\r\n",
        "Content-Length: 4\r\n\r\nab"
    ])
    func rejectsMalformedFraming(_ suffix: String) async throws {
        let reader = dnsReader(DNSByteSource([Data(("HTTP/1.1 200 OK\r\n" + suffix).utf8)]))
        await #expect(throws: AIDownloadError.self) {
            _ = try await reader.readHead()
            while try await reader.next() != nil {}
        }
    }

    @Test func acceptsRepeatedEqualContentLengthAndZeroBodyStatuses() async throws {
        for response in ["HTTP/1.1 200 OK\r\nContent-Length: 3, 3\r\n\r\nabc", "HTTP/1.1 204 No Content\r\n\r\n", "HTTP/1.1 304 Not Modified\r\nContent-Length: 1000\r\n\r\n"] {
            let reader = dnsReader(DNSByteSource([Data(response.utf8)]), maxBytes: 3)
            _ = try await reader.readHead()
            while try await reader.next() != nil {}
        }
    }

    @Test func capsHeadersTrailersAndBody() async throws {
        for wire in [
            "HTTP/1.1 200 OK\r\nX-Huge: " + String(repeating: "a", count: 65536) + "\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Huge: " + String(repeating: "a", count: 16384) + "\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n1234",
            "HTTP/1.1 200 OK\r\n\r\n1234",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n1234\r\n0\r\n\r\n"
        ] {
            let reader = dnsReader(DNSByteSource([Data(wire.utf8)]), maxBytes: 3)
            await #expect(throws: AIDownloadError.self) {
                _ = try await reader.readHead()
                while try await reader.next() != nil {}
            }
        }
    }

    @Test func bodyOnlyReadsOnDemand() async throws {
        let source = DNSByteSource([Data("HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\n".utf8), Data("abc".utf8), Data("def".utf8)])
        let reader = dnsReader(source)
        _ = try await reader.readHead()
        #expect(await source.reads == 1)
        #expect(try await reader.next() == Data("abc".utf8))
        #expect(await source.reads == 2)
        #expect(try await reader.next() == Data("def".utf8))
        #expect(try await reader.next() == nil)
    }

    @Test func concurrentBodyReadsFailWithoutRacingTheSocket() async throws {
        let started = HTTPDownloadPending<Void>()
        let pending = HTTPDownloadPending<Data?>()
        let source = DNSByteSource([Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n".utf8)])
        let reader = HTTPPinnedResponseReader(url: "https://files.example", maxBytes: 1, receive: {
            if let head = await source.next() { return head }
            started.finish(.success(()))
            return try await pending.value(timeout: 5)
        }, cancel: {})
        _ = try await reader.readHead()
        let first = Task { try await reader.next() }
        try await started.value(timeout: 5)
        await #expect(throws: AIError.self) { try await reader.next() }
        pending.finish(.success(Data("x".utf8)))
        #expect(try await first.value == Data("x".utf8))
    }

    @Test func realNumericConnectionNeverResolvesTheOriginalHostname() async throws {
        let server = try await DNSLoopbackServer.start(response: "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\npinned")
        defer { server.stop() }
        let request = dnsRequest("http://this-host-must-not-resolve.invalid:\(server.port)/asset")
        let endpoint = HTTPPinnedEndpoint(address: .init(address: "127.0.0.1", family: 4), hostname: "this-host-must-not-resolve.invalid", port: server.port, usesTLS: false)
        // Exercise the production connector directly; the independent DNS
        // tests above verify that loopback is never admitted by its guard.
        let response = try await HTTPPinnedConnection.open(request: request, endpoint: endpoint)
        let body = try await readResponseWithSizeLimit(response: response, url: request.url.absoluteString)
        #expect(body == Data("pinned".utf8))
        let received = try await server.receivedRequest()
        #expect(received.contains("Host: this-host-must-not-resolve.invalid:\(server.port)\r\n"))
    }

    @Test func realSocketBodyCancellationInterruptsPendingRead() async throws {
        let server = try await DNSLoopbackServer.start(response: "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\n", keepOpen: true)
        defer { server.stop() }
        let response = try await HTTPPinnedConnection.open(request: dnsRequest("http://files.example/"), endpoint: dnsEndpoint(port: server.port, tls: false))
        let reading = Task { var iterator = response.body.makeAsyncIterator(); return try await iterator.next() }
        try await Task.sleep(nanoseconds: 10_000_000)
        response.cancelBody()
        await #expect(throws: Error.self) { try await reading.value }
    }

    @Test func TLSClientHelloUsesOriginalHostname() async throws {
        let server = try await DNSLoopbackServer.start(response: "")
        defer { server.stop() }
        let operation = Task {
            try await HTTPPinnedConnection.open(request: dnsRequest(), endpoint: dnsEndpoint(port: server.port))
        }
        let hello = try await server.receivedBytes()
        _ = await operation.result
        // RFC 6066 server_name: extension type/length, list length, name type,
        // name length, and the original hostname. The TCP endpoint is 127.0.0.1.
        let hostname = Array("files.example".utf8)
        let expected = Data([0, 0, 0, UInt8(hostname.count + 5), 0, UInt8(hostname.count + 3), 0, 0, UInt8(hostname.count)] + hostname)
        #expect(hello.range(of: expected) != nil)
    }

    @Test @available(macOS 15, iOS 18, *)
    func TLSRetainsSystemTrustAndOriginalHostnamePolicy() async throws {
        let (identity, certificate) = try dnsTLSIdentity()
        func serverParameters() -> NWParameters {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
            return NWParameters(tls: tls, tcp: .init())
        }
        let untrusted = try await DNSLoopbackServer.start(response: "", parameters: serverParameters())
        await #expect(throws: Error.self) {
            try await HTTPPinnedConnection.open(request: dnsRequest(), endpoint: dnsEndpoint(port: untrusted.port))
        }
        untrusted.stop()

        for hostname in ["files.example", "wrong.example"] {
            let server = try await DNSLoopbackServer.start(response: "", parameters: serverParameters())
            defer { server.stop() }
            let endpoint = HTTPPinnedEndpoint(address: .init(address: "127.0.0.1", family: 4), hostname: hostname, port: server.port, usesTLS: true)
            let parameters = HTTPPinnedConnection.parameters(endpoint: endpoint)
            let tls = try #require(parameters.defaultProtocolStack.applicationProtocols.compactMap { $0 as? NWProtocolTLS.Options }.first)
            let verification = DNSVerificationProbe()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let value = sec_trust_copy_ref(trust).takeRetainedValue()
                // Only the test CA anchor changes. Preserve Network's SSL
                // policy created by the production TLS server-name setting.
                SecTrustSetAnchorCertificates(value, [certificate] as CFArray)
                SecTrustSetAnchorCertificatesOnly(value, true)
                SecTrustSetNetworkFetchAllowed(value, false)
                SecTrustSetVerifyDate(value, Date(timeIntervalSince1970: 1792756800) as CFDate)
                let accepted = SecTrustEvaluateWithError(value, nil)
                verification.record(accepted)
                complete(accepted)
            }, DispatchQueue(label: "SwiftAISDKTests.DNSPinning.verify"))
            let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: server.port)!, using: parameters)
            defer { connection.cancel() }
            if hostname == "files.example" {
                do { try await readyDNSConnection(connection) }
                catch {
                    Issue.record("TLS positive control failed; verification=\(String(describing: verification.accepted)); error=\(error)")
                    throw error
                }
            }
            else { await #expect(throws: Error.self) { try await readyDNSConnection(connection) } }
            #expect(verification.accepted == (hostname == "files.example"))
        }
    }
}

private func dnsRequest(_ url: String = "https://files.example/file") -> AIHTTPRequest {
    AIHTTPRequest(method: "GET", url: URL(string: url)!, followRedirects: false)
}
private func dnsEndpoint(port: UInt16, tls: Bool = true) -> HTTPPinnedEndpoint {
    HTTPPinnedEndpoint(address: .init(address: "127.0.0.1", family: 4), hostname: "files.example", port: port, usesTLS: tls)
}
private func emptyDNSResponse() -> AIHTTPStreamResponse {
    AIHTTPStreamResponse(statusCode: 200, body: AsyncThrowingStream { $0.finish() })
}
private actor DNSPinningProbe {
    var endpoints: [HTTPPinnedEndpoint] = []
    var hosts: [String] = []
    func connected(_ endpoint: HTTPPinnedEndpoint) { endpoints.append(endpoint) }
    func resolved(_ host: String) { hosts.append(host) }
}
private actor UnsafeDNSFixtureTransport: AIStreamingTransport {
    var sendCount = 0
    let redirect: String?
    init(redirect: String? = nil) { self.redirect = redirect }
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        sendCount += 1
        return AIHTTPResponse(statusCode: redirect == nil ? 200 : 302, headers: redirect.map { ["location": $0] } ?? [:])
    }
    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse { sendCount += 1; return emptyDNSResponse() }
}
private struct ProtectedDNSFixtureTransport: AIStreamingTransport {
    let protected: HTTPDNSPinnedTransport
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse { throw URLError(.unsupportedURL) }
    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse { throw URLError(.unsupportedURL) }
    func streamValidatedDownload(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse { try await protected.stream(request) }
}
private actor DNSByteSource {
    var chunks: [Data]
    var reads = 0
    init(_ chunks: [Data]) { self.chunks = chunks }
    func next() -> Data? { reads += 1; return chunks.isEmpty ? nil : chunks.removeFirst() }
}
private func dnsReader(_ source: DNSByteSource, maxBytes: Int = 100) -> HTTPPinnedResponseReader {
    HTTPPinnedResponseReader(url: "https://files.example/file", maxBytes: maxBytes, receive: { await source.next() }, cancel: {})
}

private final class DNSReleaseSentinel: Sendable {}
private final class DNSWeakSentinel: @unchecked Sendable {
    weak var value: DNSReleaseSentinel?
    init(_ value: DNSReleaseSentinel) { self.value = value }
}
private func completedDNSTimerProbe(
    pending: HTTPDownloadPending<DNSReleaseSentinel>,
    finishBeforeInstall: Bool
) async throws -> DNSWeakSentinel {
    if finishBeforeInstall { pending.finish(.success(DNSReleaseSentinel())) }
    let value = try await pending.value(timeout: 5, start: { $0.finish(.success(DNSReleaseSentinel())) })
    return DNSWeakSentinel(value)
}

private final class DNSVerificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    var accepted: Bool? { lock.withLock { result } }
    func record(_ value: Bool) { lock.withLock { result = value } }
}
private func readyDNSConnection(_ connection: NWConnection) async throws {
    try await HTTPDownloadPending<Void>.run(timeout: 5, cancel: { connection.cancel() }) { pending in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: pending.finish(.success(()))
            case .failed(let error), .waiting(let error): pending.finish(.failure(error))
            case .cancelled: pending.finish(.failure(CancellationError()))
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "SwiftAISDKTests.DNSPinning.tls"))
    }
}

@available(macOS 15, iOS 18, *)
private func dnsTLSIdentity() throws -> (SecIdentity, SecCertificate) {
    var imported: CFArray?
    let options: [String: Any] = [kSecImportExportPassphrase as String: "fixture", kSecImportToMemoryOnly as String: true]
    let status = SecPKCS12Import(Data(base64Encoded: dnsTLSFixturePKCS12)! as CFData, options as CFDictionary, &imported)
    #expect(status == errSecSuccess)
    let item = try #require((imported as? [[String: Any]])?.first)
    let identity = try #require(item[kSecImportItemIdentity as String]) as! SecIdentity
    let certificate = SecCertificateCreateWithData(nil, Data(base64Encoded: dnsTLSFixtureRoot)! as CFData)
    return (identity, try #require(certificate))
}

private final class DNSLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SwiftAISDKTests.DNSPinning")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private let received = HTTPDownloadPending<Data>()
    private let response: Data
    private let keepOpen: Bool
    var port: UInt16 { listener.port!.rawValue }

    private init(listener: NWListener, response: String, keepOpen: Bool) {
        self.listener = listener; self.response = Data(response.utf8); self.keepOpen = keepOpen
    }
    static func start(response: String, keepOpen: Bool = false, parameters: NWParameters = .tcp) async throws -> DNSLoopbackServer {
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let server = DNSLoopbackServer(listener: try NWListener(using: parameters), response: response, keepOpen: keepOpen)
        try await HTTPDownloadPending<Void>.run(timeout: 5, cancel: { server.stop() }) { pending in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: pending.finish(.success(()))
                case .failed(let error): pending.finish(.failure(error))
                default: break
                }
            }
            server.listener.newConnectionHandler = { connection in server.accept(connection) }
            server.listener.start(queue: server.queue)
        }
        return server
    }
    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, error in
            if let error { received.finish(.failure(error)); return }
            guard let data else { received.finish(.failure(URLError(.badServerResponse))); return }
            received.finish(.success(data))
            connection.send(content: response, completion: .contentProcessed { [self] _ in
                if !keepOpen { connection.cancel() }
            })
        }
    }
    func receivedBytes() async throws -> Data { try await received.value(timeout: 5) }
    func receivedRequest() async throws -> String { String(decoding: try await receivedBytes(), as: UTF8.self) }
    func stop() {
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        received.finish(.failure(CancellationError()))
        lock.withLock { connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}

// Public test-only key, CA and files.example leaf. Test trust uses a fixed date.
// Imported into process memory only; never installed in a user trust store.
private let dnsTLSFixturePKCS12 = "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"
private let dnsTLSFixtureRoot = "MIIDKDCCAhCgAwIBAgIJAN7lEL66uaISMA0GCSqGSIb3DQEBCwUAMCExHzAdBgNVBAMMFlN3aWZ0QUlTREsgRE5TIFRlc3QgQ0EwHhcNMjYxMDIyMTkyNTMyWhcNMzYxMDE5MTkyNTMyWjAhMR8wHQYDVQQDDBZTd2lmdEFJU0RLIEROUyBUZXN0IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxKqqmUtJZbxK2S2mx4vWgEGhf9QfaHbbyFFMf5vMNz8c0uWVQmWlvocuN/2p4dbZwE1Qq86tWiF1e1z+/2F9MdObTe+xGhPSjtPOm+FEzktOadvvQzhKIskzVPHYCpgyRknfuqjUMHHfYnpDy959kogj4plUOE3z8rN9++e26/Yj3dsbCSuPyoYBLWRYvmgxNEqG7tk3dSaKbcoQmv1e+AyLNqpoxWJzNOoY3EtLlcABCS4yH34K/vfbmaGaQBHeCwO5knqnYYU/q8p5pK6pMlG4LTrkMRgkasm5arVo5Z6zYFxOGFG1RFiN674XMe2omPQ5eHCmw8idAxdcoXlgSwIDAQABo2MwYTAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAdBgNVHQ4EFgQUB83iWjCjeJe7zqlsI3irC2ynMEMwHwYDVR0jBBgwFoAUB83iWjCjeJe7zqlsI3irC2ynMEMwDQYJKoZIhvcNAQELBQADggEBAHeiefB0jFq5Io2vEGuxSFWiUvsCDqI19gsk2qHqueZZ1rJ1URSk/xHVS6Y0s2HHIZAR7cATKzHnVQmqlw6AcqfWiGkVClr/Mlm86nQ3ryXAa9XVjBpMHI4fGrAonmYBPVPkHpke+U1SyLgi8zuz/nXtNm+tTtJGDSjD5stw8mlliTcszeFvJifRjIBX8LebQZYHcv7VTSsHOJ6V21k5f+aCzO7WkBlsTUEGEvw8WhEAnST1y2iSjwGNCo3G3ENs8ZjEIHioiQ0PAmSfrISTo3G5Ngz0omhW+exZk+ILxMmaZFyIuZN4DbL7H1LMhZfdXTpmCszFmd7yLAt6kOPPoPM="
