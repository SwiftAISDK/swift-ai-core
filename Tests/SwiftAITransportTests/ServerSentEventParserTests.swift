import Foundation
import Testing
@testable import SwiftAITransport
import SwiftAIProvider

@Test func serverSentEventParserHandlesArbitraryByteSplitsAndUTF8() throws {
    let payload = Data("\u{FEFF}: keep-alive\r\nid: cursor-1\r\nevent: message\r\ndata: こんにちは 👋\r\ndata: второй ряд\r\n\r\n".utf8)
    let expected = [ServerSentEvent(
        event: "message",
        id: "cursor-1",
        data: "こんにちは 👋\nвторой ряд"
    )]

    for splitIndex in 0...payload.count {
        var parser = ServerSentEventParser()
        var events = try parser.append(payload.prefix(splitIndex))
        events.append(contentsOf: try parser.append(payload.suffix(from: splitIndex)))
        events.append(contentsOf: try parser.finish())
        #expect(events == expected, "Failed split at byte \(splitIndex)")
    }

    var byteParser = ServerSentEventParser()
    var byteEvents: [ServerSentEvent] = []
    for byte in payload {
        byteEvents.append(contentsOf: try byteParser.append(Data([byte])))
    }
    byteEvents.append(contentsOf: try byteParser.finish())
    #expect(byteEvents == expected)
}

@Test(arguments: ["\n", "\r\n", "\r"])
func serverSentEventParserSupportsAllLineEndings(_ newline: String) throws {
    let payload = "event: update\(newline)id: 7\(newline)data: first\(newline)data: second\(newline)\(newline)"
    var parser = ServerSentEventParser()

    let events = try parser.append(Data(payload.utf8))

    #expect(events == [ServerSentEvent(event: "update", id: "7", data: "first\nsecond")])
    #expect(try parser.finish().isEmpty)
}

@Test func serverSentEventParserRemovesExactlyOneOptionalSpaceAndIgnoresOtherFields() throws {
    let payload = ": comment\nretry: 1000\nunknown: ignored\nevent:  custom \nid:  cursor \ndata: first \ndata:\tsecond\n\n"
    var parser = ServerSentEventParser()

    let events = try parser.append(Data(payload.utf8))

    #expect(events == [ServerSentEvent(
        event: " custom ",
        id: " cursor ",
        data: "first \n\tsecond"
    )])
}

@Test func serverSentEventParserDispatchesEmptyDataButIgnoresIDContainingNull() throws {
    var parser = ServerSentEventParser()
    let events = try parser.append(Data("id: valid-id\nid: invalid\0id\ndata:\n\n".utf8))

    #expect(events == [ServerSentEvent(event: nil, id: "valid-id", data: "")])
}

@Test func serverSentEventParserDoesNotDispatchIncompleteEventAtEOF() throws {
    var parser = ServerSentEventParser()
    #expect(try parser.append(Data("event: message\ndata: incomplete\n".utf8)).isEmpty)
    #expect(try parser.finish().isEmpty)

    var partialLineParser = ServerSentEventParser()
    #expect(try partialLineParser.append(Data("data: incomplete".utf8)).isEmpty)
    #expect(try partialLineParser.finish().isEmpty)

    #expect(parseServerSentEvents(Data("data: incomplete\n".utf8)).isEmpty)
}

@Test func serverSentEventParserDispatchesOnlyAtBlankLine() throws {
    var parser = ServerSentEventParser()
    #expect(try parser.append(Data("data: ready\n".utf8)).isEmpty)
    #expect(try parser.append(Data("\n".utf8)) == [ServerSentEvent(event: nil, id: nil, data: "ready")])
}
