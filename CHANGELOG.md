# Changelog

## 1.4.0

- Add experimental typed field extraction with nullable answers, guesses, source metadata, whole-call validation/refusals, retries and abort-aware evidence downloads. Registries and custom fallbacks route Extraction V4. Incremental array parsing is local to each stream, and telemetry receives isolated provider-redacted views while application values remain intact. ModelCapability gains extraction; update exhaustive switches. Reviewed npm delta: ai 7.0.165 to 7.0.172, @ai-sdk/provider 4.0.37 to 4.0.38, @ai-sdk/provider-utils 5.0.76 to 5.0.81. Validation: `node Scripts/test-packages.mjs` passed all 52 owning suites and 1731 facade tests; tooling 27/27, generation/isolation checks, standalone exports and 106 minimum/latest consumers, documentation check and 101-page build passed. Publication requires green exact-source Swift 6.3.3 CI. Paid/live verification and full-package parity are not claimed.
  Compatibility: Additive native APIs or capabilities under the project minor-release convention. npm baselines and Swift SemVer are independent; this reviewed delta does not establish full-package or live-service parity.
