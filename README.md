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
- M005 hardens unattended operation, logging/status surfaces, crash and database safety, soak verification, code signing, notarization, and user-facing documentation.

Do not use this README to promise polished installation, packaged distribution, app-store readiness, or release support before M005 completes.
