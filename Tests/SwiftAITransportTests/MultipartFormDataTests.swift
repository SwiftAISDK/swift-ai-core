import Foundation
import Testing
@testable import SwiftAITransport
import SwiftAIProvider

@Test func convertToMultipartFormDataAddsStringValues() {
    let body = multipartBodyText(convertToMultipartFormData([
        "model": .string("gpt-image-1"),
        "prompt": .string("A cute cat")
    ]))

    #expect(body.contains(#"name="model""#))
    #expect(body.contains("\r\n\r\ngpt-image-1\r\n"))
    #expect(body.contains(#"name="prompt""#))
    #expect(body.contains("\r\n\r\nA cute cat\r\n"))
}

@Test func convertToMultipartFormDataAddsNumberValuesAsStrings() {
    let body = multipartBodyText(convertToMultipartFormData([
        "n": .number(2),
        "seed": .number(42)
    ]))

    #expect(body.contains(#"name="n""#))
    #expect(body.contains("\r\n\r\n2\r\n"))
    #expect(body.contains(#"name="seed""#))
    #expect(body.contains("\r\n\r\n42\r\n"))
}

@Test func convertToMultipartFormDataAddsFileValues() {
    let body = multipartBodyText(convertToMultipartFormData([
        "image": .file(MultipartFormDataFile(fileName: "blob", mimeType: "image/png", data: Data("test".utf8)))
    ]))

    #expect(body.contains(#"name="image"; filename="blob""#))
    #expect(body.contains("Content-Type: image/png"))
    #expect(body.contains("\r\n\r\ntest\r\n"))
}

@Test func convertToMultipartFormDataSkipsNullAndNilValues() {
    let body = multipartBodyText(convertToMultipartFormData([
        "model": .string("gpt-image-1"),
        "mask": .null,
        "size": nil
    ]))

    #expect(body.contains(#"name="model""#))
    #expect(!body.contains(#"name="mask""#))
    #expect(!body.contains(#"name="size""#))
}

@Test func convertToMultipartFormDataAddsSingleElementArraysWithoutBracketSuffix() {
    let body = multipartBodyText(convertToMultipartFormData([
        "image": .array([
            .file(MultipartFormDataFile(fileName: "image.png", mimeType: "image/png", data: Data("test".utf8)))
        ])
    ]))

    #expect(body.contains(#"name="image"; filename="image.png""#))
    #expect(!body.contains(#"name="image[]""#))
}

@Test func convertToMultipartFormDataAddsMultiElementArraysWithBracketSuffix() {
    let body = multipartBodyText(convertToMultipartFormData([
        "image": .array([
            .file(MultipartFormDataFile(fileName: "one.png", mimeType: "image/png", data: Data("test1".utf8))),
            .file(MultipartFormDataFile(fileName: "two.jpg", mimeType: "image/jpeg", data: Data("test2".utf8)))
        ])
    ]))

    #expect(!body.contains(#"name="image";"#))
    #expect(multipartPartCount(named: "image[]", in: body) == 2)
    #expect(body.contains(#"filename="one.png""#))
    #expect(body.contains(#"filename="two.jpg""#))
}

@Test func convertToMultipartFormDataCanDisableArrayBracketSuffix() {
    let body = multipartBodyText(convertToMultipartFormData(
        [
            "image": .array([
                .file(MultipartFormDataFile(fileName: "one.png", mimeType: "image/png", data: Data("test1".utf8))),
                .file(MultipartFormDataFile(fileName: "two.jpg", mimeType: "image/jpeg", data: Data("test2".utf8)))
            ])
        ],
        useArrayBrackets: false
    ))

    #expect(!body.contains(#"name="image[]""#))
    #expect(multipartPartCount(named: "image", in: body) == 2)
}

@Test func convertToMultipartFormDataSkipsEmptyArrays() {
    let body = multipartBodyText(convertToMultipartFormData([
        "model": .string("test"),
        "images": .array([])
    ]))

    #expect(body.contains(#"name="model""#))
    #expect(!body.contains(#"name="images""#))
    #expect(!body.contains(#"name="images[]""#))
}

@Test func convertToMultipartFormDataAddsStringArraysWithBracketSuffix() {
    let body = multipartBodyText(convertToMultipartFormData([
        "tags": .array([.string("cat"), .string("cute"), .string("animal")])
    ]))

    #expect(multipartPartCount(named: "tags[]", in: body) == 3)
    #expect(body.contains("\r\n\r\ncat\r\n"))
    #expect(body.contains("\r\n\r\ncute\r\n"))
    #expect(body.contains("\r\n\r\nanimal\r\n"))
}

@Test func convertToMultipartFormDataHandlesMixedValues() {
    let body = multipartBodyText(convertToMultipartFormData([
        "model": .string("gpt-image-1"),
        "prompt": .string("Edit this image"),
        "image": .array([
            .file(MultipartFormDataFile(fileName: "blob", mimeType: "image/png", data: Data("image data".utf8)))
        ]),
        "mask": .null,
        "n": .number(1),
        "size": .string("1024x1024"),
        "quality": .string("high")
    ]))

    #expect(body.contains(#"name="model""#))
    #expect(body.contains(#"name="prompt""#))
    #expect(body.contains(#"name="image"; filename="blob""#))
    #expect(!body.contains(#"name="mask""#))
    #expect(body.contains(#"name="n""#))
    #expect(body.contains(#"name="size""#))
    #expect(body.contains(#"name="quality""#))
}

@Test func multipartStreamingBodyPreservesFieldAndFileOrderWithoutBuffering() async throws {
    var form = MultipartFormData()
    form.boundary = "ordered-boundary"
    form.appendField(name: "expires_after", value: "172800")
    form.appendField(name: "team_id", value: "team-1")
    form.appendFile(
        name: "file",
        fileName: "batch.jsonl",
        mimeType: "application/jsonl",
        content: .stream(AsyncThrowingStream { continuation in
            continuation.yield(Data("{\"a\":1}\n".utf8))
            continuation.yield(Data("{\"b\":2}\n".utf8))
            continuation.finish()
        })
    )

    let streaming = form.streamingBody()
    let body = String(decoding: try await collect(streaming.stream), as: UTF8.self)

    let expiry = try #require(body.range(of: #"name="expires_after""#)?.lowerBound)
    let team = try #require(body.range(of: #"name="team_id""#)?.lowerBound)
    let file = try #require(body.range(of: #"name="file"; filename="batch.jsonl""#)?.lowerBound)
    #expect(expiry < team)
    #expect(team < file)
    #expect(body.contains("{\"a\":1}\n{\"b\":2}\n"))
    #expect(body.hasSuffix("--ordered-boundary--\r\n"))
}

@Test func multipartStreamingBodyUsesSafeDefaultHeaders() async throws {
    var form = MultipartFormData()
    form.boundary = "safe-boundary"
    form.appendFile(
        name: "fi\r\neld",
        fileName: "quo\"te\\name\n.txt",
        mimeType: "text/plain\r\nX-Evil: yes",
        content: .stream(AsyncThrowingStream { continuation in
            continuation.yield(Data("ok".utf8))
            continuation.finish()
        })
    )

    let body = String(decoding: try await collect(form.streamingBody().stream), as: UTF8.self)
    #expect(body.contains(#"name="field""#))
    #expect(body.contains(#"filename="quo\"te\\name.txt""#))
    #expect(body.contains("Content-Type: text/plainX-Evil: yes"))
    #expect(!body.contains("\r\nX-Evil:"))
}

@Test func multipartStreamingBodyCancelsActiveAndUnenteredSources() async throws {
    let activeProbe = MultipartCancellationProbe()
    let unenteredProbe = MultipartCancellationProbe()
    var form = MultipartFormData()
    form.boundary = "cancel-boundary"
    form.appendFile(name: "first", content: cancellationObservedStream(activeProbe))
    form.appendFile(name: "second", content: cancellationObservedStream(unenteredProbe))
    let streaming = form.streamingBody()
    var iterator = streaming.stream.makeAsyncIterator()

    _ = try await iterator.next() // first file headers
    let pendingRead = Task { try await iterator.next() }
    await streaming.cancel()
    _ = try? await pendingRead.value

    #expect(await waitForMultipartTermination(activeProbe))
    #expect(await waitForMultipartTermination(unenteredProbe))
}

@Test func multipartStreamingBodyPropagatesSourceFailureAndTearsDownRemainingStreams() async throws {
    struct SourceFailure: Error {}
    let unenteredProbe = MultipartCancellationProbe()
    var form = MultipartFormData()
    form.boundary = "error-boundary"
    form.appendFile(name: "first", content: .stream(AsyncThrowingStream { continuation in
        continuation.yield(Data("partial".utf8))
        continuation.finish(throwing: SourceFailure())
    }))
    form.appendFile(name: "second", content: cancellationObservedStream(unenteredProbe))

    do {
        _ = try await collect(form.streamingBody().stream)
        Issue.record("Expected multipart source failure.")
    } catch is SourceFailure {
        // expected
    } catch {
        Issue.record("Expected SourceFailure, got \(error).")
    }
    #expect(await waitForMultipartTermination(unenteredProbe))
}

private func multipartBodyText(_ form: MultipartFormData) -> String {
    var form = form
    return String(data: form.finalize(), encoding: .utf8) ?? ""
}

private func multipartPartCount(named name: String, in body: String) -> Int {
    body.components(separatedBy: #"name="\#(name)""#).count - 1
}

private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
    var data = Data()
    for try await chunk in stream {
        data.append(chunk)
    }
    return data
}

private final class MultipartCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false

    var wasTerminated: Bool { lock.withLock { terminated } }

    func recordTermination() {
        lock.withLock { terminated = true }
    }
}

private func cancellationObservedStream(
    _ probe: MultipartCancellationProbe
) -> FileUploadData {
    .stream(AsyncThrowingStream { continuation in
        continuation.onTermination = { _ in probe.recordTermination() }
    })
}

private func waitForMultipartTermination(_ probe: MultipartCancellationProbe) async -> Bool {
    for _ in 0..<100 {
        if probe.wasTerminated { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return probe.wasTerminated
}
