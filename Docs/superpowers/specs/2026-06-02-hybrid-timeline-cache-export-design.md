# Hybrid Timeline, Replay Cache, and Export Design

## Goal

Sounding should let an operator scan a live or recorded stream visually, understand song and ad boundaries, click timeline content to hear it, and export both metadata and retained audio. The design keeps the current readable event feed, adds a horizontal overview rail, and separates durable metadata from optional durable audio storage.

## User-Facing Behavior

The stream detail view shows a hybrid timeline:

- A horizontal rail summarizes the selected time window.
- Song spans are colored blocks using artist/title metadata from timed ID3, SCTE-35-adjacent metadata, or fingerprint/AcoustID enrichment.
- Ad markers appear on the rail and in the feed. SCTE-35 and timed ID3 markers use distinct colors and labels.
- Transcript, song, and marker rows remain in the vertical feed below the rail with full text and timestamps.
- Zoom controls change the visible window. The underlying retained history is not changed by zooming.
- Clicking a rail segment or feed row seeks playback to that time when audio is retained.
- Right-click actions include `Play`, `Copy Text`, `Copy with Time`, `Export Clip`, and `Export Timeline Range`.

## Metadata Cache

Metadata remains durable by default in SQLite. This includes transcripts, speaker labels when enabled, audio fingerprints, AcoustID lookup matches, songs, song plays, timed ID3 markers, SCTE-35 markers, diagnostics, and timeline projection inputs.

The current fingerprint tables and AcoustID lookup cache remain the source of truth for song enrichment. Fingerprint cache export includes JSON and CSV so operators can preserve lookup results or inspect misses.

## Audio Replay Cache

Rolling PCM remains temporary by default. A new per-stream setting, `Archive audio for replay/export`, enables durable audio retention.

When enabled, decoded audio frames are written to an app-managed archive directory and indexed in SQLite by stream, run, chunk, time range, codec/container, byte count, checksum, and file path. Timeline playback resolves audio in this order:

1. Live rolling buffer.
2. Archived audio segment.
3. Unavailable state with a clear reason.

Archived audio remains reusable after app restart. Deleting a stream preserves historical archive files unless the user explicitly chooses a destructive cleanup action.

## Export

Export supports four scopes:

- Selected timeline row.
- Selected time range.
- Stream run.
- Full stream history.

Export formats:

- Timeline JSON with transcript, song, marker, and diagnostic rows.
- CSV summaries for songs, ad markers, and transcript segments.
- Plain text transcript with wall-clock timestamps.
- Audio clip for retained ranges.
- Bundle export containing metadata plus audio clips.

If a requested range has partial audio retention, export includes available clips and reports the missing ranges.

## Data Flow

Ingest persists metadata as it does today. When audio archiving is enabled, the decoded PCM path also writes archive segments through a small `AudioArchiveStore` boundary. The timeline projection receives both metadata rows and archive availability, so the UI can distinguish playable rows from metadata-only rows.

Click-to-play uses a `TimelineReplayResolver` that accepts stream ID and seconds, then checks rolling buffer first and archive second. This keeps UI code independent from storage details.

## Controls And Preferences

Per-stream options:

- Archive audio for replay/export.
- Audio archive retention limit for this stream, defaulting to global preference.

Global preferences:

- Archive location.
- Maximum archive size.
- Default archive retention duration.
- Export destination default.

The UI shows current archive health: retained duration, disk used, and last cleanup message.

## Testing

Tests should cover:

- Timeline projection includes song spans plus SCTE-35 and timed ID3 markers.
- Duplicate song metadata is coalesced while true changes remain visible.
- Click-to-play prefers rolling buffer, then archive.
- Export includes timestamps and reports partial audio retention.
- Archive cleanup respects retention limits and never removes metadata rows.
- App restart can replay archived audio from SQLite-indexed archive files.

## Non-Goals

This does not make audio archiving default-on. It also does not require waveform rendering in the first slice; colored spans and marker ticks are enough for the first shippable version.
