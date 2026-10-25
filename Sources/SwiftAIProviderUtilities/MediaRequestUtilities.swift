import Foundation
import SwiftAIProvider
import SwiftAITransport


public func splitVersionedModelID(_ modelID: String) -> (model: String, version: String?) {
    let parts = modelID.split(separator: ":", maxSplits: 1).map(String.init)
    return (parts[0], parts.count > 1 ? parts[1] : nil)
}

public func mediaURLs(from value: JSONValue?) -> [String] {
    if let string = value?.stringValue { return [string] }
    return value?.arrayValue?.compactMap(\.stringValue) ?? []
}

public func formatDuration(_ duration: Double) -> String {
    duration.rounded() == duration ? String(Int(duration)) : String(duration)
}

public func gcd(_ lhs: Int, _ rhs: Int) -> Int {
    var a = abs(lhs)
    var b = abs(rhs)
    while b != 0 {
        let next = a % b
        a = b
        b = next
    }
    return max(a, 1)
}

public func appendQueryItemIfMissing(url: String, name: String, value: String) -> String {
    guard var components = URLComponents(string: url) else { return url }
    var items = components.queryItems ?? []
    if !items.contains(where: { $0.name == name }) {
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
    }
    return components.url?.absoluteString ?? url
}

public extension AIHTTPRequest {
    func withURL(_ url: URL) -> AIHTTPRequest {
        AIHTTPRequest(method: method, url: url, headers: headers, body: body, abortSignal: abortSignal)
    }
}
