# Soak evidence runbook

This runbook is for an operator or future agent who needs to prove Sounding can remain observable during unattended operation without committing private stream data. After reading it, you should be able to run the short automated proof, collect a local 72-hour evidence set for three or more authorized streams, interpret the resulting status, database, queue, resource, reconnect, and HLS signals, and sanitize a summary for tracked project notes.

The short automated proof is safe for normal validation because it uses SoundingKit-owned synthetic streams. The 72-hour workflow is operator-local because it requires authorized live streams and may produce private transcripts, screenshots, databases, logs, and machine paths.

## Short automated proof

Run the synthetic short proof from the package root with a local database and an ignored evidence output path:

```sh
RUN_ID="$(date -u +%Y%m%d-%H%M)"
RUN_DIR="soak-proof.local/$RUN_ID"
mkdir -p "$RUN_DIR"

swift run sounding soak proof \
  --db "$RUN_DIR/proof.sqlite" \
  --evidence-out "$RUN_DIR/proof.json" \
  --duration-seconds 0.3 \
  --sample-interval-seconds 0.1 \
  --json | tee "$RUN_DIR/summary.json"
```

Use `--format ndjson` when appending multiple proof records to a local stream of evidence. Do not copy the generated evidence file into tracked text; copy only aggregate facts after the redaction checklist below passes.

A successful JSON summary reports `ok: true`, `verdict: pass`, `databaseHealthStatus: healthy`, `checkpointStatus: healthy`, `failureCount: 0`, and `redactionAuditStatus: pass`. A non-zero exit means the evidence file may still exist and should be inspected locally for a redacted failure reason.

## Evidence schema quick reference

The committed example in `docs/soak-evidence.example.json` shows the complete top-level shape using safe synthetic values. Current evidence contains:

- `schemaVersion`, `generatedAt`, and `timeRange` for the proof window.
- `limits` describing bounded collection caps so long runs do not emit unbounded arrays.
- `streams` from runtime status inspection, including phase, retry attempt, lifecycle reason, optional `recoveryLatencySeconds`, and HLS decision reason.
- `runtimeEvents` for status transitions such as reconnecting, suspended, recovering, running, and terminal error phases.
- `resourceSamples` for memory, CPU, and open file descriptors, or an explicit unavailable sample.
- `queueSnapshots` for submitted, started, completed, current depth, max depth, and busy state.
- `databaseSnapshots` for health and database checkpoint counters: status, journal mode, database/WAL/SHM byte counts, page count, quick check, foreign key check, checkpoint busy/log/checkpointed frame counts, and failures.
- `hlsDecisionCounts` for duplicate segment, media sequence gap, segment identity conflict, and unavailable decision totals.
- `thresholds` for runtime reconnect attempts, terminal runtime errors, queue final depth, queue max depth, database health/checkpoint, resource availability, and lifecycle recovery latency.
- `failures`, `summary`, and `redactionAudit` for pass/fail interpretation and leak detection.

Redaction constraints are stricter than general diagnostics: raw stream URLs, credentials, query keys or values, URL fragments, local database/evidence paths, WAL/SHM paths, and private artifact directory names must not appear in emitted evidence.

## Local-only artifact layout

Keep generated proof material under ignored local directories. Recommended layout:

```text
soak-proof.local/YYYYMMDD-HHMM/
  README.local.txt
  commands.local.sh
  short-proof.json
  short-proof.ndjson
  app-status-start.json
  app-status-hour-000.json
  database-health-start.json
  database-checkpoint-start.json
  database-health-hour-000.json
  database-checkpoint-hour-000.json
  sleep-wake-status-before.json
  sleep-wake-status-after.json
  operator-notes.local.md
  screenshots.local/
  transcripts.local/
  databases.local/
```

The directory name is safe to mention as an ignored workspace label, but populated contents are private. Do not commit generated databases, WAL files, SHM files, command transcripts, screenshots, logs, raw status output, copied stream configs, or populated evidence from this workspace.

## 72-hour authorized-stream workflow

Use this workflow only when the operator has permission to monitor at least three live streams. The goal is bounded evidence, not exhaustive logging.

### Start capture

1. Create a fresh ignored run directory and record the local clock source in `README.local.txt`.
2. Configure three or more authorized streams in the app database or local private config. Do not store raw sources in tracked docs.
3. Start Sounding.app and confirm every stream is actively monitored.
4. Capture a baseline status and database snapshot:

```sh
sounding streams status --db "$SOUNDING_DB_PATH" --json > "$RUN_DIR/app-status-start.json"
sounding database health --db "$SOUNDING_DB_PATH" --json > "$RUN_DIR/database-health-start.json"
sounding database checkpoint --db "$SOUNDING_DB_PATH" --mode passive --json > "$RUN_DIR/database-checkpoint-start.json"
```

5. Run the short synthetic proof once at the start so the local environment has a current synthetic baseline:

```sh
sounding soak proof \
  --db "$RUN_DIR/short-proof.sqlite" \
  --evidence-out "$RUN_DIR/short-proof.json" \
  --duration-seconds 0.3 \
  --sample-interval-seconds 0.1 \
  --json > "$RUN_DIR/short-proof-summary.json"
```

### During capture

Sample at a bounded cadence. A practical default is every 30 minutes for status and every 2 hours for database health/checkpoint, plus manual captures around sleep/wake and operator-observed incidents. Avoid unbounded `tail -f` logs; rotate large local logs and summarize counts instead.

For each status sample, store only local files:

```sh
HOUR="$(date -u +%H%M)"
sounding streams status --db "$SOUNDING_DB_PATH" --json > "$RUN_DIR/app-status-$HOUR.json"
```

For each database sample:

```sh
HOUR="$(date -u +%H%M)"
sounding database health --db "$SOUNDING_DB_PATH" --json > "$RUN_DIR/database-health-$HOUR.json"
sounding database checkpoint --db "$SOUNDING_DB_PATH" --mode passive --json > "$RUN_DIR/database-checkpoint-$HOUR.json"
```

If the Mac sleeps or wakes during the window, capture immediately before planned sleep when possible and immediately after wake:

```sh
sounding streams status --db "$SOUNDING_DB_PATH" --json > "$RUN_DIR/sleep-wake-status-before.json"
# sleep and wake the machine normally
sounding streams status --db "$SOUNDING_DB_PATH" --json > "$RUN_DIR/sleep-wake-status-after.json"
sounding database health --db "$SOUNDING_DB_PATH" --json > "$RUN_DIR/sleep-wake-database-health-after.json"
```

### End capture

At the end of 72 hours:

1. Capture final streams status, database health, and passive checkpoint output.
2. Run one final short synthetic proof to show the CLI-facing soak path still works.
3. Aggregate counts locally from the evidence files: stream count, reconnect attempts by stream, terminal runtime errors, sleep/wake recovery entries, maximum recovery latency, maximum queue depth, resource unavailability count, HLS duplicate/gap/conflict counts, database health status counts, checkpoint busy frame maxima, and redaction audit failures.
4. Write a sanitized human summary in tracked notes only after applying the redaction checklist.

## Interpretation guide

Use these pass/fail rules for both the short proof and the 72-hour local workflow.

### Runtime and lifecycle

Pass when every authorized stream remains represented in `sounding streams status --json`, phases are running or intentionally suspended/recovering during sleep/wake, reconnect attempts stay within configured expectations, terminal runtime errors are absent or explained by redacted failures, and `recoveryLatencySeconds` stays below the configured `lifecycleRecoveryLatency` threshold.

Fail when a stream disappears from status, a malformed phase is reported, a stream stays suspended/recovering after wake without a redacted failure, reconnect attempts climb without recovery, or terminal errors lack actionable redacted guidance.

### Queue and resource samples

Pass when queue snapshots drain to `currentDepth: 0`, maximum queue depth remains within the threshold, memory/CPU/file descriptor samples stay bounded, and unavailable resource samples are rare and explained.

Fail when queue depth grows monotonically, the final queue does not drain, resource sampling is unavailable when configured as fatal, or resource metrics grow without a stable plateau. For the 72-hour workflow, prefer summary aggregation over keeping every high-frequency sample.

### Database health and database checkpoint

Pass when `database health --json` reports `healthy`, SQLite checks are `ok`, WAL mode is active, and passive checkpoint counters show no persistent busy frames. A passive checkpoint can report log frames; it should not repeatedly fail to checkpoint because of a stuck writer or reader.

Degraded means the database opened but needs attention, such as busy checkpoint frames or warning checks. Unhealthy means the requested operation could not safely complete. Treat repeated degraded database checkpoint output or any unhealthy result as a failed soak until investigated locally.

### HLS counts

Pass when HLS duplicate segment, media sequence gap, segment identity conflict, and unavailable decision counts remain at expected synthetic or low live-run levels and do not correlate with transcript duplication or runtime failures.

Fail when HLS decision counts grow steadily for one stream, correlate with reconnect storms, or imply skipped/duplicated persisted data.

### Redaction and output failures

Pass when `redactionAudit.passed` is true and local scans find no raw URLs, credentials, query strings, fragments, local paths, database names, WAL/SHM names, or private artifact directory names.

Fail when redaction audit fails, CLI output reports validation/output/threshold/runtime/database failures, or any tracked candidate text contains private details.

## Redaction checklist before tracked notes

Before copying any facts from local soak work into tracked files, scan the candidate text and replace matches with placeholders:

- Raw stream URLs and protocol-bearing strings.
- Userinfo, credentials, passwords, signing/notary secrets, and token-like values.
- Query keys or values, including token-style names, and URL fragments.
- Local database, WAL, SHM, evidence, transcript, screenshot, log, model cache, and artifact paths.
- Private artifact directory names beyond the generic ignored workspace label.
- Raw SQLite, GRDB, or OS errors that include local file paths.

Safe tracked facts include command shape, exit code, bounded duration, number of authorized streams, aggregate reconnect/resource/queue/HLS/database counts, threshold verdicts, and redacted failure phases or reasons.

## Hygiene and retention

Keep generated files in ignored local directories and rotate them during long runs. Prefer one status sample per cadence plus aggregate summaries instead of raw continuous logs. Compress or delete bulky local screenshots, transcripts, and databases after the operator has extracted a sanitized pass/fail summary. If evidence is needed for private incident response, store it outside the repository using the team’s approved secure channel.
