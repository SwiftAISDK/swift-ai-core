import Foundation
import CryptoKit
import SwiftAIProvider

/// Credentials for service-neutral AWS Signature Version 4 requests.
public struct AWSSigningCredentials: Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID; self.secretAccessKey = secretAccessKey; self.sessionToken = sessionToken
    }
}

public enum AWSSigV4 {
    public static func sign(request: AIHTTPRequest, body: Data, credentials: AWSSigningCredentials, region: String, service: String, date: Date) throws -> AIHTTPRequest {
        guard let host = request.url.host else { throw AIError.invalidURL(request.url.absoluteString) }
        let amzDate = timestampFormatter.string(from: date)
        let shortDate = dateFormatter.string(from: date)
        let payloadHash = sha256Hex(body)

        var headers = request.headers.reduce(into: [String: String]()) { partial, element in
            partial[element.key.lowercased()] = element.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let unsignedHeaders = headers.filter { !$0.value.unicodeScalars.allSatisfy { $0.value < 128 } }
        headers = headers.filter { $0.value.unicodeScalars.allSatisfy { $0.value < 128 } }
        headers["host"] = host
        headers["x-amz-date"] = amzDate
        headers["x-amz-content-sha256"] = payloadHash
        if let sessionToken = credentials.sessionToken {
            headers["x-amz-security-token"] = sessionToken
        }

        let canonicalHeaders = headers.keys.sorted().map { key in
            "\(key):\(collapseSpaces(headers[key] ?? ""))\n"
        }.joined()
        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let canonicalRequest = [
            request.method.uppercased(),
            canonicalURI(for: request.url),
            canonicalQuery(for: request.url),
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
        let credentialScope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
        let signature = hmacHex(key: signingKey(secret: credentials.secretAccessKey, date: shortDate, region: region, service: service), data: Data(stringToSign.utf8))

        headers["authorization"] = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        headers.merge(unsignedHeaders) { signed, _ in signed }
        return AIHTTPRequest(method: request.method, url: request.url, headers: headers, body: request.body, abortSignal: request.abortSignal)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static func signingKey(secret: String, date: String, region: String, service: String) -> SymmetricKey {
        let kDate = hmacData(key: SymmetricKey(data: Data("AWS4\(secret)".utf8)), data: Data(date.utf8))
        let kRegion = hmacData(key: SymmetricKey(data: kDate), data: Data(region.utf8))
        let kService = hmacData(key: SymmetricKey(data: kRegion), data: Data(service.utf8))
        let kSigning = hmacData(key: SymmetricKey(data: kService), data: Data("aws4_request".utf8))
        return SymmetricKey(data: kSigning)
    }

    private static func hmacData(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func hmacHex(key: SymmetricKey, data: Data) -> String {
        hex(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalURI(for url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return path.isEmpty ? "/" : path
    }

    private static func canonicalQuery(for url: URL) -> String {
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems, !queryItems.isEmpty else {
            return ""
        }
        let encodedItems: [(String, String)] = queryItems.map { item in
            (percentEncode(item.name), percentEncode(item.value ?? ""))
        }
        let sortedItems = encodedItems.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        return sortedItems.map { name, value in
            "\(name)=\(value)"
        }.joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "=&+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func collapseSpaces(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}