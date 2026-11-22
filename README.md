<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-core 1.7.0

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-core.git", from: "1.7.0")
```

Products: `SwiftAI`, `SwiftAIProvider`, `SwiftAIProviderUtilities`, `SwiftAITransport`.
Contribute and report issues in the canonical SwiftAISDK repository.

## Authored usage guide

# SwiftAISDK core for Swift

`swift-ai-core` is the shared runtime of [SwiftAISDK](https://github.com/SwiftAISDK/SwiftAISDK),
an independent Swift port of the Vercel AI SDK. It contains the `AI` facade,
model protocols, request and result types, streaming, tools, structured output,
middleware, telemetry, agents and explicit provider registries. It has no
external dependencies and no concrete providers.

**Documentation:** <https://swiftaisdk.github.io/SwiftAISDK/>

## Products

| Product | Purpose |
| --- | --- |
| `SwiftAI` | Generation facade, tool execution, structured output, middleware, telemetry, agents and registries |
| `SwiftAIProvider` | Model protocols, request/result values, stream parts, errors and cancellation primitives |
| `SwiftAITransport` | Foundation HTTP/WebSocket transport, protected downloads, SSE and multipart |
| `SwiftAIProviderUtilities` | Shared conversions, schema validation and stream normalization for provider packages |

## Usage

Applications add the `SwiftAI` product together with one or more provider
packages, such as `swift-ai-openai`:

```swift
import SwiftAI
import SwiftAIOpenAI

let provider = try AIProviders.openAI(configuration: OpenAIProviderSettings())
let model = try provider.languageModel("gpt-6.1-sol")
let result = try await model.generateText("Write one sentence about Swift.")
print(result.text)
```

Core does not create providers or an implicit Gateway: pass model objects
directly or resolve them through `createProviderRegistry`. To plug in your own
model, implement `LanguageModel` (or another model protocol) or build an
`AICustomProvider`.

- [Install and choose packages](https://swiftaisdk.github.io/SwiftAISDK/getting-started/install/)
- [Generate text](https://swiftaisdk.github.io/SwiftAISDK/core/generate-text/) and the other task guides
- [Providers](https://swiftaisdk.github.io/SwiftAISDK/providers/)

## Contributing

This package is exported from `Packages/swift-ai-core` in the canonical
[SwiftAISDK](https://github.com/SwiftAISDK/SwiftAISDK) repository. Open issues
and pull requests there. Licensed under Apache-2.0; Vercel AI SDK names describe
provenance, not affiliation or endorsement.
