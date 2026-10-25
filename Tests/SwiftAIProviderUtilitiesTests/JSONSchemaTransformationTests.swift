import Testing
@testable import SwiftAIProviderUtilities
import SwiftAIProvider
import SwiftAITransport

@Test func addAdditionalPropertiesToJSONSchemaAddsToObjectsRecursivelyLikeUpstream() {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "user": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"]
                ]
            ],
            "age": ["type": "number"]
        ]
    ]

    #expect(addAdditionalPropertiesToJSONSchema(schema) == [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "user": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "name": ["type": "string"]
                ]
            ],
            "age": ["type": "number"]
        ]
    ])
}

@Test func addAdditionalPropertiesToJSONSchemaHandlesArraysUnionsAndDefinitionsLikeUpstream() {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "ingredients": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "amount": ["type": "string"]
                    ],
                    "required": ["name", "amount"]
                ]
            ],
            "response": [
                "type": ["object", "null"],
                "properties": [
                    "name": ["type": "string"]
                ]
            ],
            "choice": [
                "anyOf": [
                    ["type": "object", "properties": ["a": ["type": "string"]]],
                    ["type": "object", "properties": ["b": ["type": "string"]]]
                ],
                "allOf": [
                    ["type": "object", "properties": ["c": ["type": "string"]]]
                ],
                "oneOf": [
                    ["type": "object", "properties": ["d": ["type": "boolean"]]]
                ]
            ],
            "node": ["$ref": "#/definitions/Node"]
        ],
        "required": ["ingredients"],
        "definitions": [
            "Node": [
                "type": "object",
                "properties": [
                    "value": ["type": "string"],
                    "next": ["$ref": "#/definitions/Node"]
                ]
            ]
        ]
    ]

    let result = addAdditionalPropertiesToJSONSchema(schema)

    #expect(result["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["ingredients"]?["items"]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["response"]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["choice"]?["anyOf"]?[0]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["choice"]?["anyOf"]?[1]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["choice"]?["allOf"]?[0]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["choice"]?["oneOf"]?[0]?["additionalProperties"]?.boolValue == false)
    #expect(result["definitions"]?["Node"]?["additionalProperties"]?.boolValue == false)
}

@Test func addAdditionalPropertiesToJSONSchemaOverwritesExistingFlagsLikeUpstream() {
    let schema: JSONValue = [
        "type": "object",
        "additionalProperties": true,
        "properties": [
            "meta": [
                "type": "object",
                "additionalProperties": true,
                "properties": [
                    "id": ["type": "string"]
                ]
            ]
        ]
    ]

    #expect(addAdditionalPropertiesToJSONSchema(schema) == [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "meta": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "id": ["type": "string"]
                ]
            ]
        ]
    ])
}

@Test func addAdditionalPropertiesToJSONSchemaPreservesSchemaValuedCatchallsLikeUpstream() {
    let schema: JSONValue = [
        "type": "object",
        "additionalProperties": [
            "type": "object",
            "properties": [
                "value": ["type": "string"]
            ]
        ]
    ]

    #expect(addAdditionalPropertiesToJSONSchema(schema) == [
        "type": "object",
        "additionalProperties": [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "value": ["type": "string"]
            ]
        ]
    ])
}

@Test func addAdditionalPropertiesToJSONSchemaNormalizesNestedObjectSchemas() {
    let schema: JSONValue = [
        "type": "object",
        "additionalProperties": true,
        "properties": [
            "plain": ["type": "string"],
            "nested": [
                "type": "object",
                "properties": [
                    "value": ["type": "string"]
                ]
            ],
            "union": [
                "type": ["object", "null"],
                "properties": [
                    "id": ["type": "string"]
                ]
            ],
            "array": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "item": ["type": "string"]
                    ]
                ]
            ],
            "tuple": [
                "type": "array",
                "items": [
                    ["type": "object", "properties": ["left": ["type": "string"]]],
                    ["type": "string"]
                ]
            ],
            "choice": [
                "anyOf": [
                    ["type": "object", "properties": ["a": ["type": "string"]]],
                    ["type": "string"]
                ],
                "allOf": [
                    ["type": "object", "properties": ["b": ["type": "string"]]]
                ],
                "oneOf": [
                    ["type": "object", "properties": ["c": ["type": "string"]]]
                ]
            ]
        ],
        "definitions": [
            "Defined": [
                "type": "object",
                "properties": ["name": ["type": "string"]]
            ]
        ]
    ]

    let result = addAdditionalPropertiesToJSONSchema(schema)

    #expect(result["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["nested"]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["union"]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["array"]?["items"]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["tuple"]?["items"]?[0]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["tuple"]?["items"]?[1]?["additionalProperties"] == nil)
    #expect(result["properties"]?["choice"]?["anyOf"]?[0]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["choice"]?["anyOf"]?[1]?["additionalProperties"] == nil)
    #expect(result["properties"]?["choice"]?["allOf"]?[0]?["additionalProperties"]?.boolValue == false)
    #expect(result["properties"]?["choice"]?["oneOf"]?[0]?["additionalProperties"]?.boolValue == false)
    #expect(result["definitions"]?["Defined"]?["additionalProperties"]?.boolValue == false)
}

@Test func addAdditionalPropertiesToJSONSchemaLeavesNonObjectSchemasUntouched() {
    let stringSchema: JSONValue = ["type": "string", "properties": ["ignored": ["type": "object"]]]
    let boolSchema: JSONValue = true

    #expect(addAdditionalPropertiesToJSONSchema(stringSchema) == stringSchema)
    #expect(addAdditionalPropertiesToJSONSchema(boolSchema) == boolSchema)
}
