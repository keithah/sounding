# Live Stream Verification

This runbook is for a future Sounding agent or engineer who needs to verify real live stream behavior without committing stream URLs, credentials, or evidence files. After reading it, you should be able to copy the safe example config, populate local-only streams, run `sounding live-verify`, interpret the evidence categories, and keep private artifacts out of source control.

## Local-only configuration

Start from the committed safe example:

```sh
cp live-streams.example.json live-streams.local.json
```

Edit `live-streams.local.json` locally and replace the reserved example sources with the real stream sources you are allowed to test. Do not commit the local file. The local config is intentionally gitignored, while `live-streams.example.json` remains tracked as the shape reference.

Each stream entry has these fields:

- `id`: stable non-secret label used in console output and evidence.
- `streamType`: `auto`, `hls`, `icecast`, `icy`, `mpegts`, or `udp`.
- `source`: local fixture path or real stream URL. Evidence stores a redacted source class, not this literal value.
- `filter`: marker filter such as `all` or `scte35`.
- `timeoutSeconds`: optional per-stream monitor timeout.
- `minimumMarkers`: minimum marker count needed for a pass.
- `required`: `true` fails the run on that stream failure; `false` records an optional failure without failing the aggregate run.

If there is no private config on the machine, use a temporary fixture config for deterministic smoke checks instead of treating missing live URLs as a source failure.

## Build and run

Build the executable first:

```sh
swift build --package-path .
```

Run live verification from the package root and write evidence to a gitignored local path:

```sh
.build/arm64-apple-macosx/debug/sounding live-verify \
  --config live-streams.local.json \
  --evidence-out live-verification-evidence/latest.json
```

Use `--format ndjson` when you want one evidence object per line:

```sh
.build/arm64-apple-macosx/debug/sounding live-verify \
  --config live-streams.local.json \
  --evidence-out live-verification-evidence/latest.ndjson \
  --format ndjson
```

For a missing-source smoke check, point a required fixture entry at a nonexistent local path and write evidence under `/tmp`. The expected result is a non-zero process exit with a `stream_unavailable` result in evidence and no raw source, token, credential, config path, or evidence path in stdout or stderr.

## Evidence categories

The evidence file is the durable operational surface for later debugging. Inspect the `category`, `diagnostic`, `required`, `markerCount`, and `durationMilliseconds` fields before rerunning.

| Category | Meaning | Usual next step |
|---|---|---|
| `passed` | The stream met `minimumMarkers` before timeout. | Preserve evidence if this was a release or live-source qualification run. |
| `stream_unavailable` | The source could not be opened or read. | Check the local source value, network access, and whether credentials expired. |
| `timeout` | Monitoring exceeded `timeoutSeconds`. | Increase the local timeout only if the stream is expected to be slow; otherwise treat as a live-source failure. |
| `no_markers_observed` | The stream was readable but did not emit enough matching markers. | Verify the filter and whether the stream should currently contain ad markers. |
| `unsupported_or_skipped` | The configured type is not supported for this live verification path. | Confirm the stream type; UDP live monitoring may need fixture or replay coverage instead. |
| `parser_adapter_regression` | The monitor pipeline surfaced an adapter or parsing failure. | Treat as a Sounding regression until proven to be malformed source data. |
| `configuration_failure` | The config could not be decoded or validated. | Fix the local JSON shape; diagnostics should name the field class without echoing private values. |

## Sanitized failure behavior

Malformed or missing configs should fail before streams run. The diagnostic should say the live verification configuration failed and, for missing paths, refer to a redacted config path rather than the literal path. Invalid stream values may mention the stream `id`, but must not echo raw `source` values, credentials, query tokens, or fragments.

Output write failures should report a redacted output path. If a diagnostic includes a raw URL, credential, token, local config path, or evidence path, fix the CLI redaction before trusting new evidence.

## Source-control hygiene

Before finishing a live verification run, confirm local-only artifacts remain ignored:

```sh
git status --short -- live-streams.local.json live-verification-evidence
```

That command should print nothing for ignored local artifacts. Also confirm generated SwiftPM output remains untracked:

```sh
git ls-files .build | wc -l | tr -d ' '
```

The expected count is `0`. Do not paste private stream URLs, credentials, or raw evidence paths into summaries, docs, commits, or issue comments.
