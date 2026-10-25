import Foundation
import SwiftAIProvider


public func providerURL(_ string: String, queryParams: [String: String]) throws -> URL {
    guard !queryParams.isEmpty else { return try requireURL(string) }
    guard var components = URLComponents(string: string) else { throw AIError.invalidURL(string) }
    var items = components.queryItems ?? []
    for key in queryParams.keys.sorted() {
        items.append(URLQueryItem(name: key, value: queryParams[key]))
    }
    components.queryItems = items
    guard let url = components.url else { throw AIError.invalidURL(string) }
    return url
}