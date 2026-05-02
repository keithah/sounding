# Sounding

Sounding is the Swift baseline for a native macOS stream-monitoring app. At the end of M001, the shipped source baseline is a `SoundingKit` package plus a thin `sounding` CLI that can build locally, monitor fixture-backed HLS/ICY/MPEGTS/UDP ad-marker paths, persist the ingest baseline schema through `ad_events`, and run local-only live stream verification when an operator supplies authorized stream sources.

After reading this README, a future engineer or agent should be able to:

1. Build the package.
2. Run fixture monitor smoke paths for the current marker pipeline.
3. Run `live-verify` only with local authorized stream configuration.
4. Understand which proof is complete for M001 and which product work is intentionally deferred to M002-M005.

For the broader product direction, read [`sounding.md`](sounding.md). For the final M001 source inventory and caveats, read [`BASELINE-INVENTORY.md`](BASELINE-INVENTORY.md).

## Current M001 baseline

M001 is a source and CLI baseline, not a packaged app release. The important boundary is:

- `SoundingKit` owns the reusable stream monitoring, marker decoding/classification, ingest pipeline, persistence, live verification, and redaction behavior.
- `sounding` is the CLI shell over that package. It exposes `monitor`, `live-verify`, and the M002 `ingest` tracer path.
- SQLite persistence is established for the ingest baseline tables: `streams`, `ingest_runs`, `ingest_chunks`, `ad_events`, `ingest_diagnostics`, transcript segments, timestamped transcript words, speaker turns, and transcript FTS.
- Fixture-backed monitor paths cover HLS ID3, ICY metadata, MPEG-TS SCTE-35, UDP replay, marker classification, redacted diagnostics, and command smoke behavior.

M001 deliberately stops short of transcripts, diarization, search, song fingerprinting, the native app UI, distribution, notarization, and long-running soak guarantees.

## Build

From the repository root, build the package with:

```sh
swift build --package-path sounding
```

That is the primary M001 executable proof in this local environment. Generated SwiftPM output belongs under ignored package build directories and should not be committed.

## Fixture monitor smoke paths

Use fixture-backed monitor commands to exercise the current marker pipeline without live stream access. For example:

```sh
swift run --package-path sounding sounding monitor \
  sounding/Tests/SoundingKitTests/Fixtures/HLS/manifest-id3.m3u8 \
  --stream-type hls \
  --json \
  --timeout 2

swift run --package-path sounding sounding monitor \
  sounding/Tests/SoundingKitTests/Fixtures/MPEGTS/scte35_splice_null.ts \
  --stream-type mpegts \
  --filter scte35 \
  --json \
  --timeout 2
```

The test suite contains additional smoke and parity coverage for monitor options, pipeline timeout handling, command output, and migration shape. Full XCTest execution is currently a local environment caveat; see the proof section below before treating test execution as green.

## Bounded transcript ingest

M002 introduces a first vertical ingest path through the real CLI:

```sh
swift run --package-path sounding sounding ingest \
  "$SOUNDING_LIVE_URL" \
  --db /tmp/sounding-ingest.sqlite \
  --duration 60

swift run --package-path sounding sounding ingest \
  sounding/Tests/SoundingKitTests/Fixtures/HLS/manifest-id3.m3u8 \
  --db /tmp/sounding-ingest-fixture.sqlite \
  --stream-type hls \
  --max-chunks 1
```

`ingest` requires either `--duration` or `--max-chunks` and validates those bounds before opening the database or model providers. Database-open failures, source-open failures, and model setup failures are reported through redacted CLI diagnostics; recoverable per-chunk transcription and diarization failures are persisted in `ingest_diagnostics` for later inspection. On successful bounded runs, the database should contain stream/run/chunk rows plus any transcript segments, timestamped words, speaker turns, ad events, and diagnostics produced by the source and providers.

### Operational hardening proof for ingest

Use short, bounded runs and redacted placeholders when proving the M002 ingest path. Do not paste private URLs, credentials, local model cache paths, generated database paths, or runtime evidence into tracked files.

- **Bounded success:** run a fixture or authorized live source with `--max-chunks 1` or a short `--duration`; expect stdout shaped like `ingest completed: stream=<id> run=<id> chunks=<n> diagnostics=<n>`, an `ingest_runs.status` of `completed`, sanitized `streams.source` / `ingest_chunks.segment_uri` values, and any transcript rows to remain queryable.
- **Model cache reuse:** run the same bounded live proof twice on the same machine. The first run may emit redacted `model downloading` / `model cached` progress lines, while the second should reuse cached providers without printing model cache filesystem paths.
- **Recoverable chunk failure:** when a chunk-level transcription or diarization error occurs after some valid chunks, expect the run to finish with persisted `ingest_diagnostics` rows that include `phase`, `reason`, `created_at`, run/chunk identity, and redacted context while valid transcript rows remain searchable and countable.
- **Fatal setup failure:** missing bounds, invalid bounds, database-open failures, source-open failures, and provider setup failures should fail before unrelated work continues. Stderr should use messages such as `Ingest configuration failed`, `Ingest database failed`, `Ingest sourceOpen failed`, or `Ingest modelSetup failed` with redacted source and path details.
- **Cancellation or interrupt:** an interrupted run should write a terminal `cancelled` ingest run once, preserve any completed chunk diagnostics, and avoid duplicate terminal state updates.
- **Search/count after ingest:** after valid transcript rows exist, run `search` and `count` against the same database to prove transcript FTS and phrase aggregates still work after success or recoverable failures.
- **Two-stream shared-queue proof:** run exactly two authorized bounded sources in one `ingest` process, not two shell processes, so both streams share one model cache and one in-process inference queue. Keep the database under `/tmp` or another ignored local path and use placeholders in notes:

```sh
swift run --package-path sounding sounding ingest \
  "$SOUNDING_LIVE_URL_A" \
  "$SOUNDING_LIVE_URL_B" \
  --db /tmp/sounding-two-stream.sqlite \
  --duration 60

swift run --package-path sounding sounding search "sponsor message" \
  --db /tmp/sounding-two-stream.sqlite \
  --json

swift run --package-path sounding sounding count "sponsor message" \
  --db /tmp/sounding-two-stream.sqlite \
  --json
```

Expect one redacted `ingest stream summary:` line per source with `index`, `status`, `chunks`, `diagnostics`, `stream`, and `run` fields. If either stream fails, the command exits non-zero after printing all available per-stream summaries; inspect `ingest_diagnostics` for the stream-scoped `phase` and `reason` rather than rerunning with private URLs in logs.

For local inspection, prefer deterministic SQL that avoids leaking values:

```sh
sqlite3 /tmp/sounding-ingest.sqlite \
  "SELECT status, COUNT(*) FROM ingest_runs GROUP BY status;"

sqlite3 /tmp/sounding-ingest.sqlite \
  "SELECT phase, reason, COUNT(*) FROM ingest_diagnostics GROUP BY phase, reason;"

sqlite3 /tmp/sounding-two-stream.sqlite \
  "SELECT stream_id, status, COUNT(*) FROM ingest_runs GROUP BY stream_id, status;"

sqlite3 /tmp/sounding-two-stream.sqlite \
  "SELECT streams.id, streams.type, COUNT(transcript_segments.id) AS segments FROM streams LEFT JOIN ingest_runs ON ingest_runs.stream_id = streams.id LEFT JOIN ingest_chunks ON ingest_chunks.run_id = ingest_runs.id LEFT JOIN transcript_segments ON transcript_segments.chunk_id = ingest_chunks.id GROUP BY streams.id, streams.type;"
```

For M002/S05 proof, use the ignored `live-proof.local/` workspace for populated configs, command transcripts, generated databases, and copied evidence. Before any tracked summary or validation note cites live proof, apply this redaction checklist:

- Raw live URLs, signed query strings, fragments, userinfo, credentials, and tokens are replaced with placeholders such as `[authorized-live-url-a]`.
- Local database, evidence, config, audio segment, and model cache paths are replaced with `[redacted-path]` or the non-secret ignored workspace label `live-proof.local/...`.
- Only non-secret proof facts are preserved: command shape, exit code, bounded duration or chunk count, stream index, run/stream identifiers, aggregate table counts, and redacted diagnostic phase/reason.
- Candidate tracked text is scanned for `://`, `?`, `#`, `token`, `password`, `/Users/`, `/tmp/`, `/private/tmp/`, `/var/`, and model cache directory names before it is committed.

Real ML/live proof is intentionally local-only: provide an authorized `SOUNDING_LIVE_URL`, let WhisperKit/FluidAudio download or reuse cached models, then inspect the SQLite counts with `sqlite3` or GRDB. Do not commit live URLs, model cache paths, generated databases, or runtime evidence files.

After ingest writes transcript rows, use `search` for timestamped transcript blocks with stream/run/chunk/segment identity, speaker labels, context, and word ranges:

```sh
swift run --package-path sounding sounding search "sponsor message" \
  --db /tmp/sounding-ingest.sqlite \
  --limit 10 \
  --context 1

swift run --package-path sounding sounding search "sponsor message" \
  --db /tmp/sounding-ingest.sqlite \
  --context 1 \
  --json
```

Use `count` for stream-aware phrase aggregates grouped by stream, run, and speaker:

```sh
swift run --package-path sounding sounding count "sponsor message" \
  --db /tmp/sounding-ingest.sqlite

swift run --package-path sounding sounding count "sponsor message" \
  --db /tmp/sounding-ingest.sqlite \
  --json
```

Both commands validate empty phrases and invalid search bounds before opening the database, and database-open failures report redacted paths.

## Stream runtime diagnostics

M005 adds an operator-facing status surface for Sounding.app runtime reconnect/backoff state. The app runtime persists one redacted row per stream in `stream_runtime_status`; the CLI reads those same rows without requiring app IPC:

```sh
swift run --package-path sounding sounding streams status \
  --db /tmp/sounding-app.sqlite

swift run --package-path sounding sounding streams status \
  --db /tmp/sounding-app.sqlite \
  --json
```

Use `--include-removed` when diagnosing a stream that was soft-removed after a failure. Output includes the stream id/name/type/source description, registry status, runtime phase, reconnect attempt/max attempts, next retry delay/time, updated timestamp, and recent redacted failure. Streams with no runtime row are reported as `phase=unknown` rather than causing the whole inspection to fail. Malformed persisted phases are projected as `phase=error` with an actionable redacted failure message so an operator can clear or refresh the status row.

M005/S04 also wires Sounding.app to macOS sleep/wake notifications. The app observes `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification` only at the SwiftUI/AppKit seam, delegates lifecycle policy to SoundingKit, and refreshes the same `stream_runtime_status` rows used by the app and CLI. During a system sleep/wake cycle, active streams should move through `suspended` and `recovering`, then return to running or publish a redacted failure through the normal reconnect-source path.

Deterministic automated proof does not require putting the Mac to sleep:

```sh
swift test --filter SoundingKitTests.AppStreamRuntimeTests
swift test --filter SoundingKitTests.AppStreamRuntimeStatusStoreTests
swift test --filter SoundingKitTests.StreamAppViewModelTests
swift test --filter SoundingKitTests.StreamsCommandSmokeTests
swift test --filter SoundingKitTests.SoundingDatabaseMigrationTests
swift build --product sounding
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Sounding.xcodeproj -scheme Sounding -configuration Debug build
```

For a compact one-line slice check, run:

```sh
swift test --filter SoundingKitTests.AppStreamRuntimeTests && \
swift test --filter SoundingKitTests.AppStreamRuntimeStatusStoreTests && \
swift test --filter SoundingKitTests.StreamAppViewModelTests && \
swift test --filter SoundingKitTests.StreamsCommandSmokeTests && \
swift test --filter SoundingKitTests.SoundingDatabaseMigrationTests && \
swift build --product sounding
```

After deterministic or live app proof, inspect the persisted lifecycle surface with placeholder paths only:

```sh
swift run sounding streams status --db "[redacted-db-path]"
swift run sounding streams status --db "[redacted-db-path]" --json
```

The JSON form should expose only redacted stream descriptions and lifecycle evidence such as `phase`, `lifecycleReason`, `suspendedAt`, `recoveryStartedAt`, `recoveredAt`, and recovery latency fields. It must not include raw stream URLs, signed query strings, URL fragments, credentials, local database paths, screenshots, or evidence artifact paths.

Operator-local live sleep/wake checklist:

1. Use an authorized stream source already stored in the app database; do not paste the raw URL into tracked notes.
2. Start Sounding.app, start one or more streams, and confirm `sounding streams status --db "[redacted-db-path]" --json` reports a running phase using only a placeholder database path in any notes.
3. Put the Mac to sleep and wake it normally. Do not automate this in CI and do not commit screenshots, generated databases, app logs, or command transcripts from the local machine.
4. Re-run `sounding streams status --db "[redacted-db-path]" --json` and confirm each active stream shows suspended/recovering/recovered lifecycle evidence or a redacted recovery failure.
5. Before copying any live proof into tracked text, scan it for `://`, `?`, `#`, `token`, `password`, `/Users/`, `/tmp/`, `/private/tmp/`, `/var/`, `.sqlite`, `.db`, `.wal`, `.shm`, and local evidence directory names. Replace any match with placeholders such as `[authorized-live-url]`, `[redacted-db-path]`, or `live-proof.local/...`.

Do not paste generated database paths, raw `source_url` values, signed query strings, credentials, URL fragments, evidence paths, or secret-like filenames into tracked diagnostics. The status command should only print redacted stream descriptions and redacted failure text; if private source details appear, treat that as a redaction bug.

## Soak evidence proof

M005/S05 adds a short synthetic soak proof and a local-only 72-hour evidence workflow. Use the short proof for routine validation because it exercises runtime status, reconnect evidence, queue/resource samples, lifecycle recovery, database checkpoint health, threshold verdicts, and redaction audit behavior without private streams:

```sh
swift run --package-path sounding sounding soak proof \
  --db /tmp/sounding-soak-proof.sqlite \
  --evidence-out /tmp/sounding-soak-proof.json \
  --duration-seconds 0.3 \
  --sample-interval-seconds 0.1 \
  --json
```

For operator-local unattended proof with three or more authorized streams, follow [`docs/soak-evidence.md`](docs/soak-evidence.md). The runbook defines the ignored `soak-proof.local/YYYYMMDD-HHMM/` artifact layout, start/during/end capture cadence, sleep/wake capture, DB/WAL/checkpoint interpretation, queue/resource/reconnect/HLS count interpretation, pass/fail criteria, and the redaction checklist. The schema example in [`docs/soak-evidence.example.json`](docs/soak-evidence.example.json) is safe synthetic content only; do not replace it with generated local evidence.

## Distribution and shipping

M005 adds a script-backed Developer ID distribution path plus a cold-reader shipping runbook. Start with the no-credential readiness and dry-run packaging checks, then use operator-local credentials only when producing a real notarized release:

```sh
scripts/distribution/check --json
scripts/distribution/package --dry-run --json --output-dir shipping.local/dry-run
```

The full workflow is documented in [`Docs/shipping.md`](Docs/shipping.md). Its synthetic diagnostics example is [`Docs/shipping-diagnostics.example.json`](Docs/shipping-diagnostics.example.json). The dry-run path proves local packaging, redacted phase/status diagnostics, and generated-artifact hygiene without Apple credentials. A signed, notarized, stapled, Gatekeeper-checked release remains operator-local because it requires a locally installed Developer ID identity and notarytool keychain profile; do not commit Apple accounts, signing identities, notary profile values, raw logs, generated disk images, archives, or local output paths.

## Database health and recovery

M005 adds a database inspection surface for the same SQLite database used by Sounding.app and the CLI. Use it when the app reports persistence trouble, before and after copying a database for local investigation, after an unclean shutdown, or when WAL growth suggests checkpoint work is not completing.

```sh
swift run --package-path sounding sounding database health \
  --db "$SOUNDING_DB_PATH" \
  --json

swift run --package-path sounding sounding database checkpoint \
  --db "$SOUNDING_DB_PATH" \
  --mode passive \
  --json
```

`database health` opens the database through SoundingKit and reports operator-safe WAL and SQLite checks: journal mode, WAL auto-checkpoint pages, database/WAL/SHM byte counts, page size/count, `quick_check`, `foreign_key_check`, optional `integrity_check`, classified failure phase, and recovery guidance. The default check depth is `quick`; add `--check-depth integrity` only when investigating suspected corruption or when slower full-file checks are acceptable.

`database checkpoint` runs a constrained WAL checkpoint and then prints post-checkpoint health. The default mode is `passive`, which observes checkpoint progress without blocking active readers or truncating the WAL. Use stronger modes (`full`, `restart`, or `truncate`) only during a maintenance window or when the app is stopped, because those modes can wait on concurrent database users and change WAL file state.

Interpret `status` consistently:

- `healthy` means WAL mode, file metrics, and requested SQLite checks completed without detected issues.
- `degraded` means the database opened but one or more checks or checkpoint counters need attention, such as busy frames that could not be checkpointed while another process held the database.
- `unhealthy` means Sounding could not safely complete the requested operation, such as open failure or corruption classification. Treat this as an incident until a known-good copy is restored or the database is rebuilt from trusted source data.

Recovery guidance is phase-specific:

- **Open failures:** confirm the app/CLI is pointed at the intended local database, verify the containing directory and file permissions locally, and retry with JSON output for a stable redacted payload. Do not paste the real path into tracked issues or docs.
- **Locked or busy checkpoints:** stop Sounding.app and any other process using the database, rerun a passive checkpoint, then escalate to `full` or `restart` only if busy frames remain and a maintenance window is available.
- **Corruption:** stop writers immediately, preserve a local-only copy for investigation, run `health --check-depth integrity`, and restore from a known-good backup if corruption remains. Do not continue ingesting into a database classified as corrupt.
- **Degraded checks:** inspect the redacted check name, status, issue count, and guidance before deciding whether to retry, restore, or rebuild derived data.

Database recovery evidence is private by default. Copied databases, backups, WAL/SHM companions, command transcripts, screenshots, and investigation notes with machine-specific paths belong only in ignored local workspaces. Tracked text must redact database paths, WAL/SHM paths, local recovery artifact paths, raw SQLite or GRDB errors, stream URLs, credentials, signed query tokens, and URL fragments. If any `sounding database` output includes those details, treat it as a redaction bug rather than evidence to preserve.

## Local-only live verification

Live stream verification is available through:

```sh
swift run --package-path sounding sounding live-verify \
  --config live-streams.local.json \
  --evidence-out live-verification-evidence/latest.json
```

Do not commit real stream URLs, credentials, local config files, or evidence output. Start from the safe schema reference in [`live-streams.example.json`](live-streams.example.json), then follow the full local-only runbook in [`Docs/live-stream-verification.md`](Docs/live-stream-verification.md). The live verification evidence categories are the operational inspection surface for future agents: passed streams, unavailable streams, timeouts, missing markers, unsupported or skipped streams, parser/adapter regressions, and configuration failures.

If authorized stream sources are not available on the machine, do not invent live proof. Use fixture smoke paths and document that live verification remains local-only and unrun for that environment.

## Proof status and caveats

M001 evidence is source/build/smoke oriented:

- `swift build --package-path sounding` is expected to pass and proves the package and CLI compile.
- The authored XCTest files describe the intended fixture, command-smoke, migration, and live verification behaviors.
- The baseline migration and tests normalize the durable marker timeline to `ad_events`.
- Redaction behavior is represented in command smoke and live verification code paths so future evidence should not echo private stream sources or output paths.

The known caveat for this local environment is full XCTest execution: `swift test --package-path sounding` has been blocked by `no such module XCTest`. Treat that as an environment proof gap, not as a product feature deferral. Re-run it in an environment with XCTest available before claiming the full test suite is green.

## Deferred roadmap

The deferred roadmap is product expansion beyond the M001 ad-marker and live-verification baseline:

- M002 adds transcript ingestion, word and speaker persistence, diarization/transcription workflows, and local transcript/search foundations.
- M003 adds song fingerprinting, AcoustID lookup/cache behavior, stream management, and reports over `ad_events` and future song rows.
- M004 adds the native macOS app experience: stream sidebar, passthrough listening, rolling rewind, live transcript, timeline, and search UI.
- M005 hardens unattended operation, logging/status surfaces, crash and database safety, soak verification, script-backed Developer ID distribution, notarization diagnostics, and user-facing documentation.

Do not use this README to promise App Store readiness or public release support. Distribution is now documented and script/runbook-backed for local dry-run proof, but a signed, notarized, stapled release still requires operator-local Apple credentials and must keep generated artifacts and raw logs out of tracked files.
