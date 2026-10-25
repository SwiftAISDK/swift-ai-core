<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-core 1.0.0

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-core.git", from: "1.0.0")
```

Products: `SwiftAI`, `SwiftAIProvider`, `SwiftAIProviderUtilities`, `SwiftAITransport`.
Contribute and report issues in the canonical SwiftAISDK repository.

## Authored usage guide

# Swift AI core

Shared runtime of the independent Swift-native port of Vercel AI SDK. This
package is maintained in the canonical SwiftAISDK repository and exported as an
independently versioned Swift package. Swift versions are independent of npm baselines.

It requires Swift 6.3 or newer and declares macOS 12 / iOS 15. The package has no
external dependencies and contains four products:

| Product | Purpose |
| --- | --- |
| `SwiftAIProvider` | Model protocols, request/result values, stream parts, errors and cancellation primitives |
| `SwiftAITransport` | Foundation HTTP/WebSocket transport, protected downloads, SSE and multipart |
| `SwiftAIProviderUtilities` | Shared conversions, schema validation, stream normalization and provider helpers |
| `SwiftAI` | Generation, tool execution, middleware, telemetry, agents and explicit provider registries |

Depend on `.product(name: "SwiftAI", package: "swift-ai-core")`. Import `SwiftAI` to use
the facade and shared types. Implement `LanguageModel`, then call:

```swift
let result = try await AI.generateText(
    model: myModel,
    request: LanguageModelRequest(messages: [.user("Hello")])
)
```

The core does not supply concrete provider factories or an implicit Gateway.
Build an `AICustomProvider`, register it with `createProviderRegistry`, and resolve
a model explicitly. Decision/evaluation `.modelID` references require the
explicit resolver initializer on `AICustomProvider`; otherwise use `.model(...)`.
The legacy `SwiftAISDK` aggregate retains its string overloads, default-provider
behavior, `customProvider(...)` convenience functions and built-in factories.
Use qualified `SwiftAI.AI` / `SwiftAISDK.AI` when importing both facade modules.

`AIProviderHTTPClient` is the neutral request kernel for adapters. It supports
injected transports, dynamic headers and request URL construction; authentication
policy and provider-specific error parsing belong to the adapter. Download
security, demand-driven bodies and cancellation remain enforced by the transport.
Cross-package helpers are public; orchestration-only helpers use package access.
Public helper signatures are part of the Swift package compatibility contract.
Application code should normally use the facade and typed provider factories.

Run `swift test --package-path Packages/swift-ai-core --no-parallel` from the
canonical repository. `node Scripts/verify-core-isolation.mjs` copies this package
and the `Examples/CoreOnly` client outside the repository and builds/runs the
client without aggregate sources. Existing mixed provider/core regressions remain
in the root test suite and must also pass.

Upstream package versions and candidate source/test relationships are in
`Porting/map.json` and the canonical `Porting/upstream-lock.json`. Module extraction
does not update npm baselines or claim new upstream parity. The runtime retains
the existing batch raw-finish-reason interpretation for compatibility; provider
implementation dependencies are absent.

Licensed under Apache-2.0; see LICENSE. Vercel AI SDK names describe provenance,
not affiliation or endorsement. Contribute through the canonical SwiftAISDK
repository, rather than editing generated distribution repositories.
