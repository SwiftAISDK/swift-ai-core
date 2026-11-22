# Changelog

## 1.7.0

- Add pre-output steering interrupts, per-item structured text batch output and extraction model aliases and lifecycle telemetry. Preserve tool replay approval verification while keeping automatic denials unsigned. Normalize empty extraction answers at the facade and preserve structured Gateway errors. Reviewed npm: @ai-sdk/provider 4.0.38 to 4.0.39, @ai-sdk/provider-utils 5.0.81 to 5.0.83, ai 7.0.173 to 7.0.179. Offline validation passed: node Scripts/test-packages.mjs (56 packages, 3672 owning tests and 1760 compatibility tests), generation, tooling, isolation, and version selection. The Swift unary facade uses a caller-wide abort signal. Browser runtimes and Node tracing channels are outside the SDK. See Docs/Archive/WeeklyUpstreamAudit20261122.md for retained gaps. Paid provider calls were skipped.
  Compatibility: Existing Swift overloads remain available. Use steering interrupts to retry the same logical step before output. Extraction facade results represent empty strings and lists as missing values.
