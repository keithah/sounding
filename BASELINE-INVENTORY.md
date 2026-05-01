# Sounding Baseline Inventory

This inventory records the final M001 source baseline after slices S01-S04. It is a cold-agent handoff for source hygiene, persistence scope, monitor parity, local live verification, and proof caveats. After reading it, a future agent should know what M001 already proved, which artifacts must remain local-only, and which product capabilities are intentionally deferred to M002-M005.

## Generated Cleanup

- `.build/` is ignored by `sounding/.gitignore` and must remain absent from the `sounding` repository index.
- The physical `.build/` directory may still exist locally as ignored SwiftPM output after `swift build`; it is generated output, not a source candidate.
- The source hygiene check is `git -C sounding ls-files .build`, which should remain `0`.
- Additional local/generated ignore rules preserved in `.gitignore`: `.swiftpm/`, `DerivedData/`, local editor files, logs, caches, and environment files except `!.env.example`.
- Local-only live verification configs and evidence directories are ignored by `.gitignore`; `live-streams.example.json` is explicitly allowed as the committed safe schema reference.

## Package and Dependency Changes

Preserved package files:

- `Package.swift` adds the `SoundingKit` library target, the `sounding` executable target, GRDB as a dependency, and SQLite linker settings used by the library, executable, and tests.
- `Package.resolved` pins GRDB and swift-argument-parser dependency metadata. URL scan hits in these files are classified as public dependency metadata only.

## Persistence Baseline Files

Preserved persistence candidates:

- `Sources/SoundingKit/Persistence/SoundingDatabase.swift`
- `Sources/SoundingKit/Persistence/SoundingDatabaseMigrator.swift`
- `Tests/SoundingKitTests/SoundingDatabaseMigrationTests.swift`
- `Tests/SoundingKitTests/Support/TemporarySoundingDatabase.swift`

M001 persistence status:

- The baseline migration keeps the existing `createIngestBaseline` migration identifier and creates the M001 ingest tables: `streams`, `ingest_runs`, `ingest_chunks`, `ad_events`, and `ingest_diagnostics`.
- The durable marker timeline table is normalized to `ad_events` in both source and migration tests for M001.
- Transcript, word, speaker, search, song, and fingerprint/cache persistence remains future roadmap work, not part of the M001 source baseline.
- M002 owns transcript/word/speaker persistence and local transcript workflows. M003 owns ad analytics/reporting over the M001 `ad_events` foundation. M004 owns search-facing transcript/index behavior. M005 owns packaged application hardening and broader release readiness.

## Monitor and Parity Files

Preserved modified monitor/CLI files:

- `Sources/SoundingKit/Monitor/HLS/HLSMonitorAdapter.swift`
- `Sources/SoundingKit/Monitor/MonitorError.swift`
- `Sources/SoundingKit/Monitor/MonitorPipeline.swift`
- `Sources/sounding/MonitorCommand.swift`
- `Sources/sounding/SoundingCommand.swift`

Preserved new monitor/decoder candidates:

- `Sources/SoundingKit/Monitor/HLS/HLSSegmentID3Extractor.swift`
- `Sources/SoundingKit/Monitor/ICY/ICYMetadataError.swift`
- `Sources/SoundingKit/Monitor/ICY/ICYMetadataParser.swift`
- `Sources/SoundingKit/Monitor/ICY/ICYMetadataStreamReader.swift`
- `Sources/SoundingKit/Monitor/ICY/ICYMonitorAdapter.swift`
- `Sources/SoundingKit/Monitor/MPEGTSMonitorAdapter.swift`
- `Sources/SoundingKit/Monitor/UDPMonitorAdapter.swift`
- `Sources/SoundingKit/Markers/ID3/ID3Frame.swift`
- `Sources/SoundingKit/Markers/ID3/ID3FrameReader.swift`
- `Sources/SoundingKit/Markers/ID3/ID3MarkerDecoder.swift`
- `Sources/SoundingKit/Markers/ID3/ID3TextDecoder.swift`
- `Sources/SoundingKit/Markers/MPEGTS/MPEGTSExtractionError.swift`
- `Sources/SoundingKit/Markers/MPEGTS/MPEGTSPacket.swift`
- `Sources/SoundingKit/Markers/MPEGTS/MPEGTSProgramMap.swift`
- `Sources/SoundingKit/Markers/MPEGTS/MPEGTSSectionAssembler.swift`
- `Sources/SoundingKit/Markers/MPEGTS/MPEGTSSectionExtractor.swift`
- `Sources/SoundingKit/Markers/MPEGTS/UDPDatagramReplay.swift`
- `Sources/SoundingKit/Markers/MarkerClassifier.swift`

M001 monitor status:

- Fixture-backed HLS ID3, ICY metadata, MPEG-TS SCTE-35, and UDP replay paths are represented in source and tests.
- Integrated monitor parity and redacted diagnostic behavior are source/build/smoke-proven for M001, with command smoke tests covering the CLI surfaces.
- The remaining caveat is local XCTest runtime availability in this environment: `swift test --package-path sounding` is blocked by `no such module XCTest`, so full XCTest execution remains an environment proof gap rather than an implementation deferral.

## Live Verification Workflow

M001 includes a local-only live verification workflow:

- `Sources/sounding/LiveVerifyCommand.swift` exposes `sounding live-verify`.
- `Sources/SoundingKit/LiveVerification/` contains the live verification model, runner, evidence writer, and redaction support.
- `Docs/live-stream-verification.md` explains how an operator copies `live-streams.example.json`, supplies private stream sources in ignored local config, and writes evidence to ignored local output.
- `live-streams.example.json` is the committed safe shape reference and uses reserved example sources only.

The operational inspection surface is `sounding live-verify --evidence-out` plus evidence categories such as passed streams, unavailable streams, timeouts, missing markers, unsupported/skipped streams, parser/adapter regressions, and configuration failures. Real stream URLs, credentials, private config paths, and evidence paths must remain out of committed docs, summaries, and issue comments. Operator-supplied real-stream evidence is still a future local qualification activity, not committed M001 source proof.

## Fixtures and Tests

Preserved modified test/support files:

- `Tests/SoundingKitTests/Fixtures/README.md`
- `Tests/SoundingKitTests/HLSMonitorAdapterTests.swift`
- `Tests/SoundingKitTests/MonitorOptionsTests.swift`
- `Tests/SoundingKitTests/SCTE35FixtureTests.swift`
- `Tests/SoundingKitTests/Support/SemanticJSON.swift`

Preserved new test/support/fixture candidates:

- `Tests/SoundingKitTests/Fixtures/HLS/manifest-id3.m3u8`
- `Tests/SoundingKitTests/Fixtures/HLS/segments/id3-segment.aac`
- `Tests/SoundingKitTests/Fixtures/ID3/expected-apple-priv-marker.json`
- `Tests/SoundingKitTests/Fixtures/MPEGTS/scte35_splice_null.ts`
- `Tests/SoundingKitTests/HLSID3MarkerTests.swift`
- `Tests/SoundingKitTests/ICYMetadataTests.swift`
- `Tests/SoundingKitTests/ID3FrameReaderTests.swift`
- `Tests/SoundingKitTests/ID3MarkerDecoderTests.swift`
- `Tests/SoundingKitTests/IntegratedMonitorParityTests.swift`
- `Tests/SoundingKitTests/LiveStreamVerifierTests.swift`
- `Tests/SoundingKitTests/LiveVerifyCommandSmokeTests.swift`
- `Tests/SoundingKitTests/MPEGTSSectionExtractionTests.swift`
- `Tests/SoundingKitTests/MarkerClassifierTests.swift`
- `Tests/SoundingKitTests/MonitorCommandSmokeTests.swift`
- `Tests/SoundingKitTests/MonitorPipelineICYTests.swift`
- `Tests/SoundingKitTests/MonitorPipelineMPEGTSUDPTests.swift`
- `Tests/SoundingKitTests/MonitorPipelineTimeoutTests.swift`
- `Tests/SoundingKitTests/SoundingDatabaseMigrationTests.swift`
- `Tests/SoundingKitTests/Support/ID3FixtureBuilder.swift`
- `Tests/SoundingKitTests/Support/MPEGTSFixtureBuilder.swift`
- `Tests/SoundingKitTests/Support/TemporarySoundingDatabase.swift`
- `Tests/SoundingKitTests/UDPDatagramReplayTests.swift`

Secret hygiene adjustment preserved from M001 cleanup: UDP test/source literals use reserved example hostnames or numeric multicast fixture values while preserving test semantics. Synthetic token/key/password-like strings are retained only when they are redaction/security test data.

## Deferred Product Roadmap

The final M001 source baseline deliberately stops at ingest persistence, marker normalization, fixture-backed monitor parity, redacted diagnostics, and local live verification plumbing. Future work is product expansion rather than stale cleanup:

- M002: transcript ingestion, word/speaker persistence, and local transcript workflows.
- M003: ad analytics and reporting over `ad_events`.
- M004: search/index behavior and user-facing query workflows.
- M005: packaged app hardening, distribution readiness, and broader release verification.

## Secret Hygiene Classification

The scan excludes `.git` and `.build` and should report no unclassified live-looking URL or credential candidates after sanitizing non-reserved UDP test literals.

Classifications:

- Dependency metadata: `Package.swift` and `Package.resolved` public repository URLs.
- Documentation/example content: `sounding.md`, fixture README prose, the live verification runbook, and reserved example URLs/hosts in tests and `live-streams.example.json`.
- Local-only live verification artifacts: real stream configs and evidence belong in ignored `live-streams.local.json`, `live-streams.*.local.json`, `live-streams.private.json`, `live-streams.*.private.json`, `live-verification-evidence/`, or `live-verify-evidence/` paths and must not be committed.
- Synthetic redaction/security test data: test strings containing token/key/password-like labels, ID3 PRIV frame terminology, monitor option redaction assertions, and command smoke tests. These are retained only as tests/docs and are not live credentials.
- Protocol examples: numeric multicast UDP examples retained as protocol fixtures; no private stream hostnames are recorded in this inventory.
- Local artifacts: `.env*`, secret/credential/local/database file scans should find no candidate paths outside ignored generated output.

## Verification Evidence

| Check | Result | Notes |
|---|---:|---|
| `git -C sounding ls-files .build` count | `0` | Confirms generated SwiftPM output is not tracked after cleanup. |
| Focused git status | reviewed | Non-generated changes are preserved for package, source, tests, fixtures, `.gitignore`, docs, live verification config example, and this inventory. |
| Redacted URL/credential scan excluding `.git` and `.build` | reviewed | Suspicious URL/credential candidates should classify as dependency metadata, reserved examples, docs, or synthetic test contexts. |
| Local artifact scan excluding `.build` | reviewed | No private local config, evidence, credential, SQLite, or database artifacts should be committed. |
| `swift build --package-path sounding` | expected source proof | Build is the M001 executable proof in this local environment. XCTest remains blocked locally by `no such module XCTest`. |

## Agent Diagnostics

Future agents can re-check this baseline with:

```sh
git -C sounding ls-files .build | wc -l | tr -d ' '
git -C sounding status --short -- Package.swift Package.resolved Sources Tests Docs .gitignore live-streams.example.json BASELINE-INVENTORY.md
URL_PATTERN='https?:/{2}|udp:/{2}|token[=]|access_token|api[_-]?key|password[=]?|passwd|secret[=]?|:/{2}[^[:space:]]+@'
rg -n --hidden -g '!.git' -g '!.build' "$URL_PATTERN" sounding
find sounding -maxdepth 3 \( -name '.env*' -o -name '*secret*' -o -name '*credential*' -o -name '*.local*' -o -name '*.sqlite' -o -name '*.db' \) -not -path '*/.build/*' -print
swift build --package-path sounding
```

Do not paste live private stream URLs, credentials, raw local config paths, or raw evidence paths into command output, summaries, or future inventory updates.
