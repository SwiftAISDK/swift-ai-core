import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public struct AIToolInputExampleFormatContext: Sendable {
    public var example: JSONValue
    public var index: Int

    public init(example: JSONValue, index: Int) {
        self.example = example
        self.index = index
    }
}

public func addToolInputExamplesMiddleware(
    prefix: String = "Input Examples:",
    remove: Bool = true,
    format: (@Sendable (AIToolInputExampleFormatContext) -> String)? = nil
) -> AILanguageModelMiddleware {
    AILanguageModelMiddleware(transformRequest: { context in
        var request = context.request
        request.tools = request.tools.mapValues { tool in
            toolWithInputExamplesInDescription(
                tool,
                prefix: prefix,
                remove: remove,
                format: format ?? defaultFormatToolInputExample
            )
        }
        return request
    })
}

func toolWithInputExamplesInDescription(
    _ tool: JSONValue,
    prefix: String,
    remove: Bool,
    format: @Sendable (AIToolInputExampleFormatContext) -> String
) -> JSONValue {
    guard var object = tool.objectValue,
          let examples = object["inputExamples"]?.arrayValue,
          !examples.isEmpty else {
        return tool
    }

    let formattedExamples = examples.enumerated()
        .map { index, example in format(AIToolInputExampleFormatContext(example: example, index: index)) }
        .joined(separator: "\n")
    let examplesSection = prefix + "\n" + formattedExamples
    if let description = object["description"]?.stringValue, !description.isEmpty {
        object["description"] = .string(description + "\n\n" + examplesSection)
    } else {
        object["description"] = .string(examplesSection)
    }
    if remove {
        object.removeValue(forKey: "inputExamples")
    }
    return .object(object)
}

func defaultFormatToolInputExample(_ context: AIToolInputExampleFormatContext) -> String {
    if let input = context.example["input"] {
        return compactJSONString(input)
    }
    return compactJSONString(context.example)
}

func compactJSONString(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let string = String(data: data, encoding: .utf8) else {
        return String(describing: value)
    }
    return string
}