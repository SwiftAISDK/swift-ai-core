<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-core 1.4.0

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-core.git", from: "1.4.0")
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

Core 1.2 constructor and `AIRealtimeSession.connectServer` selectors remain
available as exact function references. Forwarding overloads retain their original
defaults while the new timing, uploaded-video, request URL, tool metadata,
capability and realtime-intent APIs remain available. Existing initializers do
not invent values for new optional fields; server sessions default to conversation.

`AISteering.queue` starts queued tasks one at a time after the current task
finishes; immediate `steer` messages take precedence. Delivered messages are
available as stream parts with delivery IDs and step numbers. URL transcription
uses `AudioURLTranscriptionRequest`, with a native provider hook and protected
download fallback. Shared timestamp requests and `TranscriptionResult.words`
expose provider-supported timings. Video results can contain `uploadedVideos`
descriptors for caller-storage delivery without a downloadable URL.

High-level text/object request URLs and `Telemetry.Event.requestURL` contain only
HTTP(S) origins. Content capture settings filter SDK-owned raw provider payloads.
Realtime event `usage` exposes provider snapshots without changing existing event
case arity. Consumers with exhaustive switches over `LanguageStreamPart` must
handle the new ping, request-metadata and delivered-steering cases.
Exhaustive switches must also handle `.provider` on `AIRealtimeConnectionKind`
and `AIModelCapabilities.Realtime.Connection`, plus `.video`, `.reranking` and
`.decision` on `AIModelCapabilitySection`. These additive enum cases follow the
project's minor-release convention; existing exhaustive switches need migration.

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

Experimental extraction is available through `AI.experimentalExtract`. Pass an
`AIExtractionModelV4`, shared `AIDecisionState`, and named `AIExtractionField`
descriptors for text, numbers, dates, times, datetimes, durations, or lists.
The facade validates every answer, confidence, number constraint and evidence
source; a refusal rejects the entire operation. A typed answer's `value == nil`
represents upstream JSON null. Text-source offsets use UTF-16 code units.
`AIExtractionLanguageModel` adapts structured language output and supports
parallel field groups with sibling cancellation and complete-usage aggregation.
A direct adapter call preserves provider answers; the facade performs final
field-value validation. `ModelCapability.extraction` is a new enum case.

`LanguageModelRequest.experimentalDownload` receives ordered URL requests with
cancellation and model URL-support information. It covers prompt assets and
model-generated file URLs. A nil prompt download preserves the URL; generated
files require bytes. `createDownload(transport:maxBytes:)` captures a protected
transport. Experimental decision and extraction calls also accept a `download`
callback. Swift retains its native DNS-pinned default for untrusted URLs; this
is intentionally stronger than the current unguarded JavaScript default.

Built-in structured-array streams scan new text and validate completed elements
once, keep the last item pending until the next begins or the envelope closes,
and retain legacy parsing for nonstandard envelopes. Parser state belongs to
each stream. Provider `LanguageModel.telemetryRedactor` hooks sanitize only
SDK-owned metadata copies; prompts, tool results and application context are
preserved. Nested telemetry integrations see sanitized provider result/error
views while callers receive the original forwarded results and errors. A failed
redactor omits the affected metadata. These hooks do not redact arbitrary user
content or promise general secret detection.
