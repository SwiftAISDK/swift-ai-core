import Foundation
import SwiftAIProvider


/// Ordered multipart/form-data builder with buffered and single-use streamed
/// file parts. Provider adapters append fields in wire order; serialization
/// preserves that order exactly.
public struct MultipartFormData {
    public init(boundary: String = "SwiftAISDK-\(UUID().uuidString)") { self.boundary = boundary }
    public var boundary: String = "SwiftAISDK-\(UUID().uuidString)"
    private var parts: [MultipartPart] = []

    public mutating func appendField(name: String, value: String) {
        parts.append(.field(name: name, value: value))
    }

    public mutating func appendFile(name: String, fileName: String, mimeType: String, data: Data) {
        parts.append(.file(
            name: name,
            fileName: fileName,
            mimeType: mimeType,
            content: .data(data)
        ))
    }

    public mutating func appendFile(
        name: String,
        fileName: String = "blob",
        mimeType: String = "application/octet-stream",
        content: FileUploadData
    ) {
        parts.append(.file(
            name: name,
            fileName: fileName,
            mimeType: mimeType,
            content: content
        ))
    }

    public var containsStream: Bool {
        parts.contains { part in
            guard case let .file(_, _, _, content) = part else { return false }
            return content.isStream
        }
    }

    public mutating func finalize() -> Data {
        precondition(!containsStream, "Use streamingBody() for multipart forms containing stream data.")
        return serializedSegments().reduce(into: Data()) { body, segment in
            guard case let .bytes(data) = segment else { return }
            body.append(data)
        }
    }

    public func streamingBody() -> MultipartStreamingBody {
        MultipartStreamingBody(segments: serializedSegments())
    }

    private func serializedSegments() -> [MultipartSegment] {
        var output: [MultipartSegment] = []
        for part in parts {
            switch part {
            case let .field(name, value):
                output.append(.bytes(Data((
                    "--\(boundary)\r\n" +
                    "Content-Disposition: form-data; name=\"\(escapeMultipartHeaderValue(name))\"\r\n\r\n" +
                    "\(value)\r\n"
                ).utf8)))
            case let .file(name, fileName, mimeType, content):
                let safeMediaType = mimeType.replacingOccurrences(
                    of: "[\r\n]",
                    with: "",
                    options: .regularExpression
                )
                output.append(.bytes(Data((
                    "--\(boundary)\r\n" +
                    "Content-Disposition: form-data; name=\"\(escapeMultipartHeaderValue(name))\"; " +
                    "filename=\"\(escapeMultipartHeaderValue(fileName))\"\r\n" +
                    "Content-Type: \(safeMediaType.isEmpty ? "application/octet-stream" : safeMediaType)\r\n\r\n"
                ).utf8)))
                switch content {
                case let .data(data):
                    output.append(.bytes(data))
                case let .stream(stream):
                    output.append(.stream(stream))
                }
                output.append(.bytes(Data("\r\n".utf8)))
            }
        }
        output.append(.bytes(Data("--\(boundary)--\r\n".utf8)))
        return output
    }
}

public struct MultipartStreamingBody: Sendable {
    public let stream: AsyncThrowingStream<Data, Error>
    private let producer: MultipartStreamProducer

    fileprivate init(segments: [MultipartSegment]) {
        let producer = MultipartStreamProducer(segments: segments)
        self.producer = producer
        self.stream = AsyncThrowingStream(unfolding: {
            do {
                return try await producer.next()
            } catch {
                await producer.cancel()
                throw error
            }
        })
    }

    public func cancel() async {
        await producer.cancel()
    }
}

private enum MultipartPart: Sendable {
    case field(name: String, value: String)
    case file(name: String, fileName: String, mimeType: String, content: FileUploadData)
}

private enum MultipartSegment: Sendable {
    case bytes(Data)
    case stream(AsyncThrowingStream<Data, Error>)
}

private actor MultipartStreamProducer {
    private let segments: [MultipartSegment]
    private var segmentIndex = 0
    private var streamIterator: MultipartStreamIteratorBox?
    private var cancelled = false

    init(segments: [MultipartSegment]) {
        self.segments = segments
    }

    func next() async throws -> Data? {
        while !cancelled, segmentIndex < segments.count {
            switch segments[segmentIndex] {
            case let .bytes(data):
                segmentIndex += 1
                if !data.isEmpty { return data }
            case let .stream(stream):
                let iterator = streamIterator ?? MultipartStreamIteratorBox(stream)
                streamIterator = iterator
                do {
                    if let chunk = try await iterator.next() {
                        if !chunk.isEmpty { return chunk }
                    } else {
                        streamIterator = nil
                        segmentIndex += 1
                    }
                } catch {
                    await cancel()
                    throw error
                }
            }
        }
        return nil
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        streamIterator = nil
        for segment in segments {
            guard case let .stream(stream) = segment else { continue }
            await cancelAsyncThrowingStream(stream)
        }
    }
}

private final class MultipartStreamIteratorBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator

    init(_ stream: AsyncThrowingStream<Data, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Data? {
        try await iterator.next()
    }
}

extension FileUploadData {
    public func cancelStream() async {
        guard case let .stream(stream) = self else { return }
        await cancelAsyncThrowingStream(stream)
    }
}


/// `AsyncThrowingStream` has no public cancel method. Starting one pending read
/// in an already-cancelled task causes its continuation to receive the standard
/// cancellation termination, including for streams rejected before a request.
private func cancelAsyncThrowingStream(_ stream: AsyncThrowingStream<Data, Error>) async {
    let task = Task {
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
    }
    task.cancel()
    _ = await task.result
}

private func escapeMultipartHeaderValue(_ value: String) -> String {
    value
        .replacingOccurrences(of: "[\r\n]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

struct MultipartFormDataFile: Equatable, Sendable {
    var fileName: String
    var mimeType: String
    var data: Data

    init(fileName: String = "blob", mimeType: String = "application/octet-stream", data: Data) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }
}

enum MultipartFormDataValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case file(MultipartFormDataFile)
    case array([MultipartFormDataValue])
    case null
}

func convertToMultipartFormData(
    _ values: [String: MultipartFormDataValue?],
    useArrayBrackets: Bool = true
) -> MultipartFormData {
    var form = MultipartFormData()

    func append(name: String, value: MultipartFormDataValue) {
        switch value {
        case let .string(string):
            form.appendField(name: name, value: string)
        case let .number(number):
            form.appendField(name: name, value: multipartNumberString(number))
        case let .bool(bool):
            form.appendField(name: name, value: String(bool))
        case let .file(file):
            form.appendFile(name: name, fileName: file.fileName, mimeType: file.mimeType, data: file.data)
        case let .array(array):
            guard !array.isEmpty else { return }
            let fieldName = array.count == 1 || !useArrayBrackets ? name : "\(name)[]"
            for item in array {
                append(name: fieldName, value: item)
            }
        case .null:
            return
        }
    }

    for (name, value) in values {
        guard let value else { continue }
        append(name: name, value: value)
    }

    return form
}

public func jsonScalarString(_ value: JSONValue) -> String? {
    switch value {
    case let .string(string):
        return string
    case let .number(number):
        return multipartNumberString(number)
    case let .bool(bool):
        return String(bool)
    case .null, .array, .object:
        return nil
    }
}

private func multipartNumberString(_ number: Double) -> String {
    if let integer = Int(exactly: number) {
        return String(integer)
    }
    guard number.isFinite,
          number.rounded() == number,
          abs(number) < 1e21 else {
        return String(number)
    }

    let locale = Locale(identifier: "en_US_POSIX")
    guard var decimal = Decimal(string: String(number), locale: locale) else {
        return String(number)
    }
    return NSDecimalString(&decimal, locale)
}