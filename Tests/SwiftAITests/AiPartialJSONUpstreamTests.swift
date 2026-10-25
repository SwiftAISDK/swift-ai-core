import Testing
@testable import SwiftAI
import SwiftAIProvider

@Test func aiFixJsonHandlesEmptyInputLikeUpstream() {
    #expect(fixJson("") == "")
}

@Test func aiFixJsonHandlesLiteralCasesLikeUpstream() {
    assertFixJsonCases([
        ("nul", "null"),
        ("t", "true"),
        ("fals", "false")
    ])
}

@Test func aiFixJsonHandlesNumberCasesLikeUpstream() {
    assertFixJsonCases([
        ("12.", "12"),
        ("12.2", "12.2"),
        ("-12", "-12"),
        ("-", ""),
        ("2.5e", "2.5"),
        ("2.5e-", "2.5"),
        ("2.5e3", "2.5e3"),
        ("-2.5e3", "-2.5e3"),
        ("2.5E", "2.5"),
        ("2.5E-", "2.5"),
        ("2.5E3", "2.5E3"),
        ("-2.5E3", "-2.5E3"),
        ("12.e", "12"),
        ("12.34e", "12.34"),
        ("5e", "5")
    ])
}

@Test func aiFixJsonHandlesStringCasesLikeUpstream() {
    assertFixJsonCases([
        ("\"abc", "\"abc\""),
        (
            "\"value with \\\"quoted\\\" text and \\\\ escape",
            "\"value with \\\"quoted\\\" text and \\\\ escape\""
        ),
        (#""value with \"#, "\"value with \""),
        ("\"\\u", "\"\""),
        ("\"\\u12", "\"\""),
        ("\"text \\u00", "\"text \""),
        ("{\"a\":\"\\u12", "{\"a\":\"\"}"),
        (#""value with unicode <""#, #""value with unicode <""#)
    ])

    for input in ["\"\\u", "\"\\u12", "\"text \\u00", "{\"a\":\"\\u12"] {
        #expect((try? secureJSONParse(fixJson(input))) != nil)
    }
}

@Test func aiFixJsonHandlesArrayCasesLikeUpstream() {
    assertFixJsonCases([
        ("[", "[]"),
        ("[[1], [2", "[[1], [2]]"),
        (#"[["1"], ["2"#, #"[["1"], ["2"]]"#),
        ("[[false], [nu", "[[false], [null]]"),
        ("[[[]], [[]", "[[[]], [[]]]"),
        ("[[{}], [{", "[[{}], [{}]]"),
        ("[1, ", "[1]"),
        ("[[], 123", "[[], 123]")
    ])
}

@Test func aiFixJsonHandlesObjectCasesLikeUpstream() {
    assertFixJsonCases([
        (#"{"key":"#, "{}"),
        (#"{"a": {"b": 1}, "c": {"d": 2"#, #"{"a": {"b": 1}, "c": {"d": 2}}"#),
        (#"{"a": {"b": "1"}, "c": {"d": 2"#, #"{"a": {"b": "1"}, "c": {"d": 2}}"#),
        (#"{"a": {"b": false}, "c": {"d": 2"#, #"{"a": {"b": false}, "c": {"d": 2}}"#),
        (#"{"a": {"b": []}, "c": {"d": 2"#, #"{"a": {"b": []}, "c": {"d": 2}}"#),
        (#"{"a": {"b": {}}, "c": {"d": 2"#, #"{"a": {"b": {}}, "c": {"d": 2}}"#),
        (#"{"ke"#, "{}"),
        (#"{"k1": 1, "k2"#, #"{"k1": 1}"#),
        (#"{"k1": 1, "k2":"#, #"{"k1": 1}"#),
        (#"{"key": "value"  "#, #"{"key": "value"}"#),
        (#"{"a": {"b": {}"#, #"{"a": {"b": {}}}"#)
    ])
}

@Test func aiFixJsonHandlesNestingCasesLikeUpstream() {
    assertFixJsonCases([
        ("[1, [2, 3, [", "[1, [2, 3, []]]"),
        ("[false, [true, [", "[false, [true, []]]"),
        (#"{"key": {"subKey":"#, #"{"key": {}}"#),
        (#"{"key": 123, "key2": {"subKey":"#, #"{"key": 123, "key2": {}}"#),
        (#"{"key": null, "key2": {"subKey":"#, #"{"key": null, "key2": {}}"#),
        (#"{"key": [1, 2, {"#, #"{"key": [1, 2, {}]}"#),
        (#"[1, 2, {"key": "value","#, #"[1, 2, {"key": "value"}]"#),
        (#"{"a": {"b": ["c", {"d": "e","#, #"{"a": {"b": ["c", {"d": "e"}]}}"#),
        (#"{"a": {"b": {"c": {"d":"#, #"{"a": {"b": {"c": {}}}}"#),
        (#"{"a": 1, "b": ["#, #"{"a": 1, "b": []}"#),
        (#"{"a": 1, "b": {"#, #"{"a": 1, "b": {}}"#),
        (#"{"a": 1, "b": ""#, #"{"a": 1, "b": ""}"#)
    ])
}

@Test func aiFixJsonHandlesRegressionCasesLikeUpstream() {
    let complexInput = [
        "{",
        #"  "a": ["#,
        "    {",
        #"      "a1": "v1","#,
        #"      "a2": "v2","#,
        #"      "a3": "v3""#,
        "    }",
        "  ],",
        #"  "b": ["#,
        "    {",
        #"      "b1": "n"#
    ].joined(separator: "\n")
    let complexExpected = [
        "{",
        #"  "a": ["#,
        "    {",
        #"      "a1": "v1","#,
        #"      "a2": "v2","#,
        #"      "a3": "v3""#,
        "    }",
        "  ],",
        #"  "b": ["#,
        "    {",
        #"      "b1": "n"}]}"#
    ].joined(separator: "\n")

    assertFixJsonCases([
        (complexInput, complexExpected),
        (
            #"{"type":"div","children":[{"type":"Card","props":{}"#,
            #"{"type":"div","children":[{"type":"Card","props":{}}]}"#
        )
    ])
}

@Test func aiParsePartialJSONHandlesNilInputLikeUpstream() {
    #expect(parsePartialJSON(nil) == AIParsePartialJSONResult(value: nil, state: .undefinedInput))
}

@Test func aiParsePartialJSONParsesValidJSONLikeUpstream() {
    #expect(parsePartialJSON(#"{"key": "value"}"#) == AIParsePartialJSONResult(
        value: ["key": "value"],
        state: .successfulParse
    ))
}

@Test func aiParsePartialJSONRepairsAndParsesPartialJSONLikeUpstream() {
    #expect(parsePartialJSON(#"{"key": "value""#) == AIParsePartialJSONResult(
        value: ["key": "value"],
        state: .repairedParse
    ))
}

@Test func aiParsePartialJSONReturnsFailedParseForUnrepairableJSONLikeUpstream() {
    #expect(parsePartialJSON("not json at all") == AIParsePartialJSONResult(
        value: nil,
        state: .failedParse
    ))
}

private func assertFixJsonCases(_ cases: [(input: String, expected: String)], sourceLocation: SourceLocation = #_sourceLocation) {
    for testCase in cases {
        #expect(fixJson(testCase.input) == testCase.expected, sourceLocation: sourceLocation)
    }
}
