import Foundation
import SwiftAIProvider


public struct ServerSentEvent: Equatable, Sendable {
    public init(event: String? = nil, id: String? = nil, data: String) {
        self.event = event; self.id = id; self.data = data
    }
    public var event: String?
    public var id: String?
    public var data: String
}

public struct ServerSentEventParser {
    private var line = Data()
    private var previousByteWasCarriageReturn = false
    private var isFirstLine = true
    private var eventName: String?
    private var eventID: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func append(_ data: Data) throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        for byte in data {
            if previousByteWasCarriageReturn {
                previousByteWasCarriageReturn = false
                if byte == 0x0A {
                    continue
                }
            }

            switch byte {
            case 0x0D:
                processCurrentLine(into: &events)
                previousByteWasCarriageReturn = true
            case 0x0A:
                processCurrentLine(into: &events)
            default:
                line.append(byte)
            }
        }
        return events
    }

    public mutating func finish() throws -> [ServerSentEvent] {
        line.removeAll(keepingCapacity: false)
        previousByteWasCarriageReturn = false
        isFirstLine = true
        resetEvent()
        return []
    }

    private mutating func processCurrentLine(into events: inout [ServerSentEvent]) {
        if isFirstLine {
            isFirstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) {
                line.removeFirst(3)
            }
        }

        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else {
            dispatchEvent(into: &events)
            return
        }

        if line.first == 0x3A {
            return
        }

        let separator = line.firstIndex(of: 0x3A)
        let fieldBytes: Data
        let valueBytes: Data
        if let separator {
            fieldBytes = line[..<separator]
            var valueStart = line.index(after: separator)
            if valueStart < line.endIndex, line[valueStart] == 0x20 {
                valueStart = line.index(after: valueStart)
            }
            valueBytes = line[valueStart...]
        } else {
            fieldBytes = line
            valueBytes = Data()
        }

        let field = String(decoding: fieldBytes, as: UTF8.self)
        let value = String(decoding: valueBytes, as: UTF8.self)
        switch field {
        case "event":
            eventName = value.isEmpty ? nil : value
        case "data":
            dataLines.append(value)
        case "id":
            if !value.contains("\0") {
                eventID = value
            }
        case "retry":
            break
        default:
            break
        }
    }

    private mutating func dispatchEvent(into events: inout [ServerSentEvent]) {
        if !dataLines.isEmpty {
            events.append(ServerSentEvent(
                event: eventName,
                id: eventID,
                data: dataLines.joined(separator: "\n")
            ))
        }
        resetEvent()
    }

    private mutating func resetEvent() {
        eventName = nil
        eventID = nil
        dataLines.removeAll(keepingCapacity: true)
    }
}

public func parseServerSentEvents(_ data: Data) -> [ServerSentEvent] {
    var parser = ServerSentEventParser()
    var events = (try? parser.append(data)) ?? []
    events.append(contentsOf: (try? parser.finish()) ?? [])
    return events
}