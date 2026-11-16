import Foundation
import Testing
import SwiftAIProvider

// Translations of @ai-sdk/provider-utils@5.0.81 is-url-supported.test.ts and
// secure-json-parse.test.ts, plus JSON.parse grammar cases that the secure
// parser inherits from ECMAScript.

private func pattern(_ regex: String, caseInsensitive: Bool = false) -> AISupportedURLPattern {
    let expression = try! NSRegularExpression(pattern: regex, options: caseInsensitive ? [.caseInsensitive] : [])
    return AISupportedURLPattern { url in
        expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }
}

@Test func isURLSupportedReturnsFalseWithoutSupportedURLs() {
    #expect(!isURLSupported(mediaType: "text/plain", url: "https://example.com", supportedURLs: [:]))
}

@Test(arguments: ["image/png-not-supported", "image/png+invalid", "image/png;invalid"])
func isURLSupportedDoesNotMatchFullMediaTypeAgainstLongerMediaType(_ mediaType: String) {
    #expect(!isURLSupported(
        mediaType: mediaType,
        url: "gs://example-bucket/image",
        supportedURLs: ["image/png": [pattern("^gs://")]]
    ))
}

@Test func isURLSupportedMatchesSpecificMediaTypesAndURLs() {
    #expect(isURLSupported(mediaType: "text/plain", url: "https://example.com", supportedURLs: ["text/plain": [pattern(#"https://example\.com"#)]]))
    #expect(isURLSupported(mediaType: "image/png", url: "https://images.example.com/cat.png", supportedURLs: ["image/png": [pattern(#"https://images\.example\.com/.+"#)]]))
    #expect(isURLSupported(mediaType: "image/png", url: "https://another.com/img.png", supportedURLs: [
        "image/png": [pattern(#"https://images\.example\.com/.+"#), pattern(#"https://another\.com/img\.png"#)]
    ]))
    #expect(!isURLSupported(mediaType: "text/plain", url: "https://another.com", supportedURLs: ["text/plain": [pattern(#"https://example\.com"#)]]))
    #expect(!isURLSupported(mediaType: "image/png", url: "https://example.com", supportedURLs: ["text/plain": [pattern(#"https://example\.com"#)]]))
}

@Test func isURLSupportedMatchesWildcardAndSpecificMediaTypes() {
    #expect(isURLSupported(mediaType: "text/plain", url: "https://example.com", supportedURLs: ["*": [pattern(#"https://example\.com"#)]]))
    #expect(isURLSupported(mediaType: "image/jpeg", url: "https://images.example.com/dog.jpg", supportedURLs: ["*": [pattern(#"https://images\.example\.com/.+"#)]]))
    #expect(!isURLSupported(mediaType: "video/mp4", url: "https://another.com", supportedURLs: ["*": [pattern(#"https://example\.com"#)]]))

    let supportedURLs = ["text/plain": [pattern(#"https://text\.com"#)], "*": [pattern(#"https://any\.com"#)]]
    #expect(isURLSupported(mediaType: "text/plain", url: "https://text.com", supportedURLs: supportedURLs))
    #expect(isURLSupported(mediaType: "text/plain", url: "https://any.com", supportedURLs: supportedURLs))
    #expect(isURLSupported(mediaType: "image/png", url: "https://any.com", supportedURLs: supportedURLs))
    #expect(!isURLSupported(mediaType: "text/plain", url: "https://other.com", supportedURLs: supportedURLs))
    #expect(!isURLSupported(mediaType: "image/png", url: "https://other.com", supportedURLs: supportedURLs))
}

@Test func isURLSupportedHandlesEmptyURLsCaseAndWildcardSubtypes() {
    #expect(isURLSupported(mediaType: "text/plain", url: "", supportedURLs: ["text/plain": [pattern(".*")]]))
    #expect(!isURLSupported(mediaType: "text/plain", url: "", supportedURLs: ["text/plain": [pattern("https://.+")]]))

    #expect(isURLSupported(
        mediaType: "image/png",
        url: "https://assets.example/Images/Photo.PNG",
        supportedURLs: ["image/*": [pattern(#"^https://assets\.example/Images/Photo\.PNG$"#)]]
    ))
    #expect(isURLSupported(mediaType: "TEXT/PLAIN", url: "https://example.com", supportedURLs: ["text/plain": [pattern(#"https://example\.com"#)]]))
    #expect(isURLSupported(
        mediaType: "image/png",
        url: "https://assets.example/photo.png?token=AbC123",
        supportedURLs: ["image/*": [pattern(#"^https://assets\.example/photo\.png\?token=AbC123$"#)]]
    ))
    #expect(isURLSupported(mediaType: "text/plain", url: "https://EXAMPLE.com/path", supportedURLs: [
        "text/plain": [pattern(#"https://example\.com/path"#, caseInsensitive: true)]
    ]))
    #expect(!isURLSupported(mediaType: "text/plain", url: "https://example.com/PATH", supportedURLs: ["text/plain": [pattern(#"https://example\.com/path"#)]]))

    #expect(isURLSupported(mediaType: "image/png", url: "https://example.com", supportedURLs: ["image/*": [pattern(#"https://example\.com"#)]]))
    #expect(isURLSupported(mediaType: "image/png", url: "https://any.com", supportedURLs: [
        "image/*": [pattern(#"https://images\.com"#)], "*": [pattern(#"https://any\.com"#)]
    ]))
}

@Test func isURLSupportedHandlesTopLevelOnlyMediaTypesAndEmptyArrays() {
    #expect(isURLSupported(mediaType: "image", url: "https://example.com/cat.png", supportedURLs: ["image/*": [pattern(#"https://example\.com/.+"#)]]))
    #expect(isURLSupported(mediaType: "image", url: "https://example.com", supportedURLs: ["*": [pattern(#"https://example\.com"#)]]))
    #expect(!isURLSupported(mediaType: "image", url: "https://example.com/cat.png", supportedURLs: ["image/png": [pattern(#"https://example\.com/.+"#)]]))
    #expect(!isURLSupported(mediaType: "image", url: "https://example.com/audio.mp3", supportedURLs: ["audio/*": [pattern(#"https://example\.com/.+"#)]]))

    #expect(!isURLSupported(mediaType: "text/plain", url: "https://example.com", supportedURLs: ["text/plain": []]))
    #expect(isURLSupported(mediaType: "text/plain", url: "https://any.com", supportedURLs: ["text/plain": [], "*": [pattern(#"https://any\.com"#)]]))
    #expect(!isURLSupported(mediaType: "text/plain", url: "https://another.com", supportedURLs: ["text/plain": [], "*": [pattern(#"https://any\.com"#)]]))
}

@Test func secureJSONParseMatchesUpstreamSecureJsonParseCases() throws {
    #expect(try secureJSONParse(#"{"a": 5, "b": 6}"#) == ["a": 5, "b": 6])
    #expect(try secureJSONParse("null") == .null)
    #expect(try secureJSONParse("0") == 0)
    #expect(try secureJSONParse(#""X""#) == "X")
    #expect(try secureJSONParse(#"{ "constructor": "string value" }"#) == ["constructor": "string value"])
    #expect(try secureJSONParse(#"{ "constructor": null }"#) == ["constructor": .null])

    for text in [
        #"{ "constructor": { "prototype": { "isAdmin": true } } }"#,
        #"{ "__proto__": { "isAdmin": true } }"#,
        #"{ "__proto__": { "isAdmin": true } }"#,
        #"{ "__proto__": { "isAdmin": true } }"#,
        #"{ "constructor": { "prototype": { "isAdmin": true } } }"#,
        #"{ "constructor": { "prototype": { "isAdmin": true } } }"#
    ] {
        #expect(throws: AIJSONParseError.self) { try secureJSONParse(text) }
    }
}

@Test func secureJSONParseUsesJSONParseGrammar() throws {
    // JSON.parse keeps the last duplicate key.
    #expect(try secureJSONParse(#"{"a":1,"a":2}"#) == ["a": 2])
    #expect(try secureJSONParse(#"{"constructor":{"prototype":1},"constructor":1}"#) == ["constructor": 1])
    #expect(try secureJSONParse(" [ true , false , null ] ") == [true, false, .null])
    #expect(try secureJSONParse(#""café 😀 \/\b\f\n\r\t\"\\""#) == "café 😀 /\u{08}\u{0C}\n\r\t\"\\")
    #expect(try secureJSONParse("1.5e-3") == 0.0015)
    #expect(try secureJSONParse("1e400") == .number(.infinity))
    // Lone surrogates have no Swift representation; they become U+FFFD.
    #expect(try secureJSONParse(#""\ud800x""#) == "\u{FFFD}x")

    for text in [
        "[1,]", #"{"a":1,}"#, "\u{FEFF}{}", "{a:1}", "[1 2]", "01", "1.", "-", "NaN", "Infinity", "'x'",
        "\"\t\"", #""\x""#, #""\u12""#, "[", #"{"a""#, "tru", "\u{2028}1", "", " ", "1 2", "{} x"
    ] {
        #expect(throws: AIJSONParseError.self, "rejects \(text.debugDescription)") { try secureJSONParse(text) }
    }
}
