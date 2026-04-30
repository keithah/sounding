# Sounding — GSD Spec (v1)

**Repo:** `sounding` (Swift, macOS-native, supersedes `tidemark-python`)
**Mission:** A native macOS app that you point at any Icecast or HLS stream (with parity for MPEGTS and UDP from the tidemark-go lineage) and get a continuously-running, searchable record of everything that happened on it: ad markers, song identifications, full-text transcripts with speaker diarization, and live listen-with-rewind. Multiple streams in parallel, all logged to SQLite, all queryable. Personal-use first, shippable later.

---

## Guiding Principles

- **Native macOS, no Python in the hot path.** The whole pipeline is Swift. We pay a quality tax on diarization (FluidAudio vs pyannote-3.1) to keep distribution simple — one signed `.app`, no Python runtime, no homebrew dependencies for end users.
- **Library / app split.** All capability lives in a `SoundingKit` Swift package — ingest, markers, transcription, diarization, fingerprinting, storage, query. The macOS app and a thin CLI both consume the package. Nothing important lives only inside the app target.
- **SQLite is the source of truth.** One `.db` per "library" (default `~/Library/Application Support/Sounding/sounding.db`). Ad events, transcript words, speaker turns, songs, and stream metadata live in the same DB on a unified wall-clock timeline.
- **Passthrough listening with rolling rewind.** The app is the player. Audio flows: network → demuxer → ingest pipeline (markers/transcribe/fingerprint) and → audio output device. A rolling buffer (default 60 min/stream) backs scrubbing. Audio is not persisted — buffer evicts on rotation.
- **Talk-radio quality bar.** Diarization, transcription quality, and paragraph formatting are tuned for 2–4 speaker spoken-word content. Music-heavy streams still get fingerprinting, but we're not trying to diarize a four-piece band.
- **GSD-style vertical slices.** Every slice ships something usable end-to-end. No "build all the infrastructure first" milestones. Parity with tidemark-go's ad detection is M001 because that's the load-bearing capability we already trust.
- **tidemark-python is retired** when M001 passes side-by-side parity tests against the same streams.

---

## Key Swift Libraries

| Capability | Swift choice | Notes |
|---|---|---|
| HLS playlist parsing | Custom on `URLSession` + small m3u8 parser | No mature Swift m3u8 lib; manifest format is small enough to write |
| HLS / MPEGTS demux | `ffmpeg-kit` (LGPL, statically linkable) or `AVAssetReader` | ffmpeg-kit for parity with Go behavior; AVAssetReader for player path |
| SCTE-35 decode | Port `threefive` algorithms to Swift in `SoundingKit/Markers/SCTE35` | No Swift port exists; the spec is small and fixture-tested |
| ID3 parsing | Custom — ID3v2 reader in Swift, ~300 LOC | Plenty of references; avoids dragging in a heavy lib |
| ICY metadata | `URLSession` with `Icy-MetaData: 1`, custom chunker | Same pattern as Python `httpx` version |
| MPEGTS over HTTP / UDP | `Network.framework` + `ffmpeg-kit` for packet parsing | Native sockets, no third-party dep |
| Audio decode → PCM | `AVAudioFile` / `AVAudioConverter` for clean formats; `ffmpeg-kit` for everything else | 16 kHz mono Float32 for ML; native sample rate for player |
| Transcription | `WhisperKit` (Argmax) | `large-v3-turbo` default; configurable |
| Diarization | `FluidAudio` | Core ML diarization pipeline; quality acceptable for talk |
| Fingerprinting | `chromaprint` C lib via SwiftPM binary target | No Swift Chromaprint; wrap the C API |
| AcoustID lookup | `URLSession` + small client | Just an HTTP API |
| SQLite + FTS5 | `GRDB.swift` | Mature, type-safe, FTS5 first-class |
| Audio output / scrub | `AVAudioEngine` + custom ring buffer | Tap the same sample stream feeding ingest |
| App UI | SwiftUI (Tahoe / macOS 26+) | New SwiftUI windowing/observation features |
| CLI | `swift-argument-parser` | Same library backing both targets |

**Load-bearing risk:** the SCTE-35 port and the chromaprint binary wrapping. Both are bounded but real. Plan covers them in M001-S002 and M003-S017.

---

## Repository Layout

```
sounding/
├── Package.swift                      # SoundingKit library + CLI executable
├── Sounding.xcodeproj                 # macOS app target only
│
├── Sources/
│   ├── SoundingKit/                   # The library — all capability lives here
│   │   ├── Ingest/
│   │   │   ├── IngestSource.swift     # Protocol, StreamEvent enum
│   │   │   ├── HLSIngest.swift        # m3u8 polling, segment fetch, sequence tracking
│   │   │   ├── IcecastIngest.swift    # ICY reader, metaint chunker
│   │   │   ├── MPEGTSIngest.swift     # Raw TS over HTTP / file
│   │   │   └── UDPIngest.swift        # Multicast receiver via Network.framework
│   │   │
│   │   ├── Markers/
│   │   │   ├── SCTE35.swift           # Native Swift decoder (port of threefive core)
│   │   │   ├── ID3.swift              # ID3v2 reader, PRIV frame SCTE-35 extraction
│   │   │   ├── ICY.swift              # StreamTitle ad-pattern recognition
│   │   │   ├── Classifier.swift       # AD_START / AD_END / UNKNOWN heuristics
│   │   │   └── AdMarker.swift         # Model
│   │   │
│   │   ├── Audio/
│   │   │   ├── Decoder.swift          # Bytes → PCM (16 kHz mono Float32 for ML)
│   │   │   ├── RollingBuffer.swift    # Per-stream ring buffer for live rewind
│   │   │   ├── PlayerEngine.swift     # AVAudioEngine wrapper, scrub support
│   │   │   └── AudioChunk.swift       # Model
│   │   │
│   │   ├── Transcribe/
│   │   │   ├── Transcriber.swift      # Protocol → TranscriptResult(words: [Word])
│   │   │   ├── WhisperKitTranscriber.swift
│   │   │   └── ParagraphFormatter.swift  # Speaker-change + pause-based paragraphing
│   │   │
│   │   ├── Diarize/
│   │   │   ├── Diarizer.swift         # Protocol → [SpeakerSegment]
│   │   │   ├── FluidAudioDiarizer.swift
│   │   │   └── Merge.swift            # Word-to-speaker midpoint assignment
│   │   │
│   │   ├── Fingerprint/
│   │   │   ├── Chromaprint.swift      # Swift wrapper around chromaprint C lib
│   │   │   ├── AcoustID.swift         # Lookup client + rate limiter
│   │   │   └── FingerprintCache.swift
│   │   │
│   │   ├── Store/
│   │   │   ├── Database.swift         # GRDB setup, migrations
│   │   │   ├── Schema.swift           # Migration definitions
│   │   │   └── Models/                # AdEvent, Segment, Word, SpeakerTurn, Song, Stream
│   │   │
│   │   ├── Query/
│   │   │   ├── Search.swift           # FTS5 phrase + filter queries
│   │   │   ├── Aggregates.swift       # "How many times did word X appear", plays, repeats
│   │   │   └── Export.swift           # Plain text + JSON exporters
│   │   │
│   │   ├── Pipeline/
│   │   │   ├── StreamPipeline.swift   # Per-stream orchestrator (one actor per stream)
│   │   │   └── Supervisor.swift       # Multi-stream coordinator, reconnect, lifecycle
│   │   │
│   │   └── Config/
│   │       └── Config.swift           # ~/.config/sounding/config.toml or app defaults
│   │
│   └── sounding-cli/                  # Thin CLI on swift-argument-parser
│       ├── Main.swift
│       ├── MonitorCommand.swift       # tidemark-go parity: real-time markers, JSON
│       ├── IngestCommand.swift        # Full pipeline → SQLite
│       ├── SearchCommand.swift
│       └── ReportCommand.swift
│
├── App/                               # Sounding.app (macOS)
│   ├── SoundingApp.swift              # @main, scene setup
│   ├── Views/
│   │   ├── StreamListView.swift       # Sidebar of configured streams
│   │   ├── NowPlayingView.swift       # Live player + scrub bar + rolling buffer view
│   │   ├── TranscriptView.swift       # Live transcript with speaker labels
│   │   ├── TimelineView.swift         # Songs + ad breaks across time
│   │   ├── SearchView.swift           # FTS results, jump-to-timestamp
│   │   └── PreferencesView.swift
│   └── ViewModels/                    # Observable wrappers around SoundingKit
│
├── Tests/
│   ├── SoundingKitTests/
│   │   ├── SCTE35Tests.swift          # Binary fixtures from tidemark-go test suite
│   │   ├── ID3Tests.swift
│   │   ├── ICYTests.swift
│   │   ├── HLSIngestTests.swift
│   │   ├── IcecastIngestTests.swift
│   │   ├── MPEGTSIngestTests.swift
│   │   ├── DecoderTests.swift
│   │   ├── TranscribeTests.swift
│   │   ├── DiarizeTests.swift
│   │   ├── MergeTests.swift
│   │   ├── FingerprintTests.swift
│   │   ├── StoreTests.swift
│   │   ├── SearchTests.swift
│   │   └── Fixtures/                  # .ts, .mp3, .m3u8, raw SCTE-35
│   │
│   └── ParityTests/
│       └── TidemarkGoParity.swift     # Side-by-side JSON comparison
│
└── docs/
    ├── sounding-gsd.md                # This document
    ├── ARCHITECTURE.md
    └── MIGRATION.md                   # tidemark-python → sounding
```

---

## SQLite Schema (GRDB migrations)

Same shape as the tidemark-python schema, with additions for streams (multi-stream first-class), speaker turns (diarization output), and a per-stream config snapshot. All timestamps are wall-clock epoch seconds (Double / `unixepoch('now','subsec')`).

```sql
-- Configured streams (one row per stream the user has added)
CREATE TABLE streams (
    id              INTEGER PRIMARY KEY,
    name            TEXT NOT NULL,            -- user-friendly label
    url             TEXT NOT NULL UNIQUE,
    stream_type     TEXT NOT NULL,            -- 'hls' | 'icecast' | 'mpegts' | 'udp' | 'auto'
    is_active       INTEGER NOT NULL DEFAULT 1,
    created_at      REAL NOT NULL DEFAULT (unixepoch('now','subsec'))
);

-- Ad marker events (port of Go's JSON output into DB; unchanged shape)
CREATE TABLE ad_events (
    id              INTEGER PRIMARY KEY,
    stream_id       INTEGER NOT NULL REFERENCES streams(id),
    marker_type     TEXT NOT NULL,            -- 'SCTE35' | 'ID3' | 'ICY'
    classification  TEXT NOT NULL,            -- 'AD_START' | 'AD_END' | 'UNKNOWN'
    source          TEXT,                     -- 'hls_manifest' | 'hls_segment' | 'icy_metadata' | 'udp' | 'mpegts'
    tag             TEXT,
    segment_seq     INTEGER,
    pts             REAL,
    break_duration  REAL,
    raw_json        TEXT,
    ts              REAL NOT NULL,
    created_at      REAL NOT NULL DEFAULT (unixepoch('now','subsec'))
);

-- Audio segments ingested (no audio_path — we don't retain audio)
CREATE TABLE segments (
    id          INTEGER PRIMARY KEY,
    stream_id   INTEGER NOT NULL REFERENCES streams(id),
    seq         INTEGER,                      -- HLS sequence or chunk counter
    start_ts    REAL NOT NULL,
    duration_s  REAL NOT NULL,
    sha256      TEXT UNIQUE,                  -- dedup on restart
    created_at  REAL NOT NULL DEFAULT (unixepoch('now','subsec'))
);

-- Words from transcription
CREATE TABLE words (
    id          INTEGER PRIMARY KEY,
    segment_id  INTEGER NOT NULL REFERENCES segments(id),
    speaker_id  INTEGER REFERENCES speaker_turns(id),  -- nullable until merge runs
    word        TEXT NOT NULL,
    start_ts    REAL NOT NULL,
    end_ts      REAL NOT NULL,
    confidence  REAL
);

-- FTS5 over words (queries: phrase + speaker filter via JOIN)
CREATE VIRTUAL TABLE words_fts USING fts5(
    word,
    content='words',
    content_rowid='id',
    tokenize='porter ascii'
);

-- Speaker turns from diarization (per-stream, anonymous speaker IDs)
CREATE TABLE speaker_turns (
    id          INTEGER PRIMARY KEY,
    stream_id   INTEGER NOT NULL REFERENCES streams(id),
    speaker_tag TEXT NOT NULL,                -- 'SPEAKER_00', 'SPEAKER_01', etc.
    start_ts    REAL NOT NULL,
    end_ts      REAL NOT NULL,
    created_at  REAL NOT NULL DEFAULT (unixepoch('now','subsec'))
);

-- Optional human-friendly names for recurring speakers (filled in by user, per-stream)
CREATE TABLE speaker_names (
    id          INTEGER PRIMARY KEY,
    stream_id   INTEGER NOT NULL REFERENCES streams(id),
    speaker_tag TEXT NOT NULL,
    display_name TEXT NOT NULL,
    UNIQUE(stream_id, speaker_tag)
);

-- Song fingerprints + AcoustID results
CREATE TABLE songs (
    id              INTEGER PRIMARY KEY,
    stream_id       INTEGER NOT NULL REFERENCES streams(id),
    segment_id      INTEGER REFERENCES segments(id),
    fingerprint     TEXT NOT NULL,
    acoustid_id     TEXT,
    title           TEXT,
    artist          TEXT,
    album           TEXT,
    score           REAL,
    start_ts        REAL,                     -- merged song boundaries
    end_ts          REAL,
    lookup_ts       REAL,
    created_at      REAL NOT NULL DEFAULT (unixepoch('now','subsec'))
);

-- Dedup cache: same fingerprint never hits AcoustID twice
CREATE TABLE fingerprint_cache (
    fingerprint     TEXT PRIMARY KEY,
    acoustid_id     TEXT,
    title           TEXT,
    artist          TEXT,
    score           REAL,
    cached_at       REAL NOT NULL DEFAULT (unixepoch('now','subsec'))
);

-- Useful indexes
CREATE INDEX idx_ad_events_stream_ts    ON ad_events(stream_id, ts);
CREATE INDEX idx_segments_stream_ts     ON segments(stream_id, start_ts);
CREATE INDEX idx_words_segment          ON words(segment_id);
CREATE INDEX idx_words_speaker          ON words(speaker_id);
CREATE INDEX idx_speaker_turns_stream   ON speaker_turns(stream_id, start_ts);
CREATE INDEX idx_songs_stream_ts        ON songs(stream_id, start_ts);
```

---

## CLI Surface

The CLI is a thin shell on `SoundingKit`. Same binary works for parity-with-tidemark-go (`monitor`) and full ingest (`ingest`).

```
# Real-time ad marker monitoring — drop-in for tidemark-go
sounding monitor <url>
    [--stream-type hls|icecast|mpegts|udp|auto]
    [--filter scte35|id3|icy]
    [--json]
    [--json-out <file>]
    [--quiet]
    [--timeout <seconds>]

# Full pipeline: markers + transcribe + diarize + fingerprint → SQLite
sounding ingest <url>
    [--name <label>]
    [--stream-type hls|icecast|mpegts|udp|auto]
    [--db <path>]
    [--no-transcribe]
    [--no-diarize]
    [--no-fingerprint]
    [--whisper-model tiny|base|small|large-v3-turbo]   # default: large-v3-turbo

# Search
sounding search <phrase>
    [--db <path>]
    [--stream <name|url>]                  # default: all streams
    [--speaker <tag-or-name>]
    [--since <duration>]                   # 2h, 24h, 7d
    [--context <seconds>]                  # default: 5
    [--json]

# Aggregate queries — answers "how many times did X come up"
sounding count <phrase>
    [--db <path>] [--stream <name|url>] [--since <duration>] [--by hour|day|speaker]

# Reports
sounding report plays   [--stream <name|url>] [--since <duration>]
sounding report repeats [--stream <name|url>] [--since <duration>] [--min-count 2]
sounding report ads     [--stream <name|url>] [--since <duration>]

# Export
sounding export transcript --stream <name|url> --since <duration> [--format text|json] [--out <file>]
sounding export markers    --stream <name|url> --since <duration> [--format text|json] [--out <file>]

# Stream management
sounding streams list
sounding streams add <url> [--name <label>] [--stream-type ...]
sounding streams remove <name|url>
sounding streams pause <name|url>
sounding streams resume <name|url>
```

`monitor` matches `tidemark-go`'s output schema exactly (modulo wall-clock fields). `ingest` is the full pipeline; the macOS app calls the same `SoundingKit` orchestrator directly (no subprocess).

---

## Milestones

---

### M001 — tidemark-go Parity: Ad Marker Detection in Swift

**Done when:** `sounding monitor` produces output identical to `tidemark-go` on the same HLS, Icecast, MPEGTS, and UDP streams. Side-by-side parity test passes. tidemark-python is retired.

| Slice | Title | Deliverable |
|-------|-------|-------------|
| S001 | Project scaffold | `Package.swift` with `SoundingKit` + `sounding-cli`, Xcode project for the app shell, GRDB and swift-argument-parser wired in, CI on macOS arm64, schema migrations file committed. App target builds an empty window. |
| S002 | SCTE-35 decoder | `SoundingKit/Markers/SCTE35.swift`: native Swift port of threefive's splice_info decoding. Unit-tested against the same binary fixtures as the Go and Python ports — byte-equivalent JSON output for splice_insert, time_signal, and segmentation_descriptor. |
| S003 | HLS ingest + SCTE-35 | `HLSIngest.swift`: m3u8 polling on `URLSession`, segment fetch, `EXT-X-MEDIA-SEQUENCE` tracking. Manifest tag detection (`#EXT-X-CUE-OUT`, `#EXT-X-DATERANGE`, `#EXT-X-SCTE35`) and raw segment scanning route to `SCTE35.swift`. |
| S004 | ID3 parser | `ID3.swift`: ID3v2 frame reader. Pulls SCTE-35 from `PRIV` frames and recognizes `com.apple.streaming.transportStreamTimestamp`. Tested against fixture `.ts` files. |
| S005 | ICY / Icecast ingest | `IcecastIngest.swift`: `Icy-MetaData: 1` request, metaint chunker, `StreamTitle` extractor. `ICY.swift`: ad-field pattern recognition (configurable per-station regex). |
| S006 | MPEGTS ingest | `MPEGTSIngest.swift`: raw TS over HTTPS via `URLSession.bytes`. Packet alignment, PID filtering, SCTE-35 PID feeding into `SCTE35.swift`. Also accepts a local file path. |
| S007 | UDP multicast | `UDPIngest.swift`: `Network.framework` UDP listener, multicast group join, TS packet reassembly. |
| S008 | Classifier | `Classifier.swift`: port of Go's `AD_START` / `AD_END` / `UNKNOWN` heuristics. Pure function on raw marker → classification. |
| S009 | `monitor` CLI + output | `MonitorCommand.swift`: wires every ingest source. JSON, NDJSON-to-file, color summary (using `swift-argument-parser`'s pretty-printing or `Rainbow`), `--filter`, `--quiet`, `--timeout`. Output schema bit-for-bit matches Go tool. |
| S010 | Parity test suite | `Tests/ParityTests/`: capture `tidemark-go` and `tidemark-python` output on 3–4 real streams (Keith's TuneIn URLs). Replay the same windowed captures into `sounding monitor`. Assert JSON equality modulo wall-clock fields. tidemark-python is archived after this passes. |

---

### M002 — Ingest Pipeline: Transcription + Diarization + Search

**Done when:** `sounding ingest <url>` runs continuously, producing speaker-tagged transcript words in SQLite. `sounding search "phrase"` returns hits with timestamps, speaker labels, and ±N second context. `sounding count "phrase"` returns aggregate counts.

| Slice | Title | Deliverable |
|-------|-------|-------------|
| S011 | Audio decoder | `Audio/Decoder.swift`: `.ts` / `.mp3` / raw bytes → 16 kHz mono Float32 PCM for ML, native sample rate retained for player path. ffmpeg-kit for messy formats, AVAudioConverter for clean ones. Fixture-tested. |
| S012 | WhisperKit transcriber | `Transcribe/WhisperKitTranscriber.swift`: load `large-v3-turbo` (configurable), word-level timestamps, `condition_on_previous_text` carryover across chunks. `Transcriber` protocol so we can swap engines later. |
| S013 | FluidAudio diarizer | `Diarize/FluidAudioDiarizer.swift`: per-stream pipeline producing `[SpeakerSegment]` with stable per-stream speaker tags across chunk boundaries. Embedding-based clustering so the same speaker keeps the same tag within a session. |
| S014 | Merge: words ↔ speakers | `Diarize/Merge.swift`: midpoint-assignment of words into speaker segments, with majority-overlap fallback for words straddling a boundary. Outputs words enriched with `speaker_id`. |
| S015 | Paragraph formatter | `Transcribe/ParagraphFormatter.swift`: speaker change OR pause >1.5s OR >120 words → new paragraph. Returns rendered text + spans for UI highlighting. |
| S016 | SQLite write path | `Store/Database.swift`: bulk insert for `segments`, `words`, `speaker_turns`, plus `ad_events` from the marker pipeline. Single `WriteAhead` connection, batched transactions per chunk. FTS5 trigger maintained. |
| S017 | Multi-stream supervisor | `Pipeline/Supervisor.swift`: launch / pause / resume one `StreamPipeline` actor per configured stream. 2–5 concurrent streams on a 16 GB M-series Mac is the design target. WhisperKit and FluidAudio shared across streams (single model load, queued inference). |
| S018 | Search CLI + context | `SearchCommand.swift`: FTS5 phrase match → JOIN to `words` → fetch ±N seconds with speaker labels → render with stream name and timestamp. `--speaker`, `--stream`, `--since` filters. |
| S019 | Count / aggregate CLI | `CountCommand.swift`: phrase counts grouped by hour, day, or speaker. Powers the "how many times did this word come up" use case. |

---

### M003 — Fingerprinting + Song Reports + Stream Management

**Done when:** Songs are identified with title/artist, `sounding report plays` shows a timestamped playlist, `sounding streams add` lets you manage streams without editing config files.

| Slice | Title | Deliverable |
|-------|-------|-------------|
| S020 | Chromaprint Swift wrapper | SwiftPM binary target wrapping `libchromaprint`. Thin `Fingerprint/Chromaprint.swift` exposes `fingerprint(pcm:) -> String`. Cross-checked against the C `fpcalc` tool on fixture audio. |
| S021 | AcoustID lookup + cache | `Fingerprint/AcoustID.swift`: API key from config. `FingerprintCache.swift` checks SQLite first. On miss, lookup, store result. Token-bucket limiter at 1 req/s default (you said once-a-minute is fine; default is conservative but raisable). |
| S022 | Song boundary detection | Merge consecutive segments with the same `acoustid_id` into a single `songs` row spanning `start_ts` → `end_ts`. Detect changes, log boundaries to the same timeline as ad events. |
| S023 | Reports CLI | `report plays`, `report repeats`, `report ads` — each filterable by stream and `--since`. Output as colored table or `--json`. |
| S024 | Streams CLI | `streams list/add/remove/pause/resume` — manages the `streams` table. Live changes signalled to the running supervisor (if any) via a SQLite-backed inbox row or a Unix signal to the daemon. |
| S025 | Export CLI | `export transcript` and `export markers`: plain text and JSON. Plain text is paragraph-formatted with speaker labels and timestamps; JSON is the raw row dump. No SRT/VTT, no audio clips (per spec). |

---

### M004 — Native macOS App: Listen, Scrub, Watch, Search

**Done when:** Sounding.app opens, you add a stream, audio plays through your speakers, the transcript scrolls live with speaker labels, you can scrub backward 60 minutes, and search jumps you to the right moment.

| Slice | Title | Deliverable |
|-------|-------|-------------|
| S026 | App shell + stream sidebar | `SoundingApp.swift` + `StreamListView`: SwiftUI window, sidebar listing streams from DB, "+" to add, status dot per stream (idle / running / error). The supervisor from S017 runs inside the app process. |
| S027 | Passthrough player | `PlayerEngine.swift`: AVAudioEngine graph that taps the same PCM stream feeding the ingest pipeline. No second decode. Play/pause, volume, output device picker. |
| S028 | Rolling buffer + scrub | `RollingBuffer.swift`: per-stream ring buffer, default 60 min at native sample rate (≈300 MB/stream for 16-bit 44.1 kHz stereo — fine in RAM, can spill to a temp file if user bumps the window). Scrub bar in `NowPlayingView` seeks within the buffer. |
| S029 | Live transcript view | `TranscriptView.swift`: paragraph-formatted, speaker-colored, autoscrolls. Tap a paragraph to seek the player to that timestamp. Speaker labels editable inline → writes `speaker_names`. |
| S030 | Live metadata view | `NowPlayingView`: current song (from `songs`), upcoming/recent ad markers (from `ad_events`), ICY `StreamTitle`, HLS sequence — whatever the active stream type provides, surfaced live. |
| S031 | Timeline view | `TimelineView`: horizontal scrollable timeline showing songs, ad breaks, speaker turns color-coded. Click any element to seek (within rolling buffer) or jump to that point in the transcript. |
| S032 | Search UI | `SearchView`: query box → results grouped by stream → click jumps to `TranscriptView` at that timestamp. Filters for stream, speaker, date range. |
| S033 | Preferences | `PreferencesView`: AcoustID API key, Whisper model, rolling buffer size, default DB location, per-stream paragraph break threshold. Backed by `UserDefaults` + `Config.swift`. |

---

### M005 — Robustness, Distribution, Shipping Prep

**Done when:** Runs unattended for 72 hours across 3+ streams, survives stream drops and laptop sleep/wake, ships as a notarized signed `.app` you could put on a website.

| Slice | Title | Deliverable |
|-------|-------|-------------|
| S034 | Reconnect + backoff | Exponential backoff per stream (cap 60s). HLS sequence-number resume. Segment dedup via `sha256`. Sleep/wake handling: on wake, every stream re-establishes within 30s. |
| S035 | Structured logging + status | `os_log` subsystem `com.sounding.*`. `sounding status` CLI reads supervisor state from a JSON status file (or DB row) — segment latency, transcribe queue depth, errors, model load state. App has a hidden "diagnostics" window. |
| S036 | Background-safe operation | Long-running ingest survives app being backgrounded; user can quit the app and a launchd-managed helper keeps streams running if they opt in. (If too much for one slice, helper is parked as a stretch and we ship "must keep app open.") |
| S037 | Crash + DB safety | GRDB WAL mode, scheduled checkpoints, recovery on corrupt DB (read-only mount + reindex). On unexpected exit, no transcript loss beyond the in-flight chunk. |
| S038 | Code signing + notarization | Developer ID signed, hardened runtime, notarized, stapled. `.dmg` artifact in CI. First-run gatekeeper UX clean. |
| S039 | Smoke + soak suite | `Tests/Soak/`: 72-hour run against 3 streams, measuring memory growth (target <100 MB drift), DB size, transcribe queue saturation. Runs on a self-hosted Mac runner. |
| S040 | README + user docs | `README.md` (install, quick start), `docs/MIGRATION.md` (tidemark-python → sounding command map), `docs/ARCHITECTURE.md` (the diagram from this spec, expanded). |

---

## Migration from tidemark-python / tidemark-go

- `sounding monitor` is a drop-in replacement for `tidemark-go` and the `tidemark monitor` command in tidemark-python. Same flags (with aliases for Go-only spellings), same JSON schema, same color output.
- Schema is forward-compatible from tidemark-python with one wrinkle: tidemark-python's schema uses `source_url` columns where Sounding uses `stream_id` foreign keys. `MIGRATION.md` ships a one-shot SQLite migration script that creates `streams` rows from distinct `source_url` values and rewrites the foreign keys.
- tidemark-python's `audio_path` and `ad_events.raw_json` survive the migration; Sounding ignores `audio_path` (no audio retention) but keeps the column so re-imports are lossless.

---

## Dependencies (`Package.swift` highlights)

```swift
dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift",          from: "6.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/argmaxinc/WhisperKit",       from: "0.9.0"),
    .package(url: "https://github.com/FluidInference/FluidAudio",  from: "0.4.0"),  // verify exact name/version at start of M002
    // ffmpeg-kit and chromaprint via SwiftPM binary targets — versions pinned at slice kickoff
]
```

Version numbers are placeholders to confirm at slice kickoff — both WhisperKit and FluidAudio move fast, and a six-week-stale pin is a footgun.

---

## Open Questions (parked)

- **FluidAudio quality on talk radio.** Spec assumes it's "good enough." First time it bites is M002-S013. Mitigation: `Diarizer` is a protocol; if FluidAudio underperforms, drop in a Python pyannote sidecar managed via XPC — slot it as M002-S013b without disturbing the rest of the pipeline.
- **WhisperKit model size on disk.** `large-v3-turbo` is ~1.5 GB. Bundle it, download on first run, or both? Default plan: download on first run to `~/Library/Application Support/Sounding/models/`, with a "download now" button in Preferences.
- **Multi-stream Whisper contention.** Single model, queued inference is fine for 2–3 streams. At 5 streams of dense talk, queue may grow. Mitigation: per-stream chunk size tuning, or a second WhisperKit instance for parallelism. Decide at M002-S017 based on measurement.
- **Rolling buffer overflow on long sessions.** 60 min RAM buffer × 5 streams × stereo 44.1 kHz ≈ 1.5 GB. Fine on 16 GB Macs, tight on 8 GB. Plan: spill-to-disk option in Preferences, default ON for buffers >30 min.
- **SCTE-35 port test corpus.** Need fixtures from the Go/Python codebases. Mitigation: copy `tests/fixtures/` from tidemark-python into `Tests/SoundingKitTests/Fixtures/` at S001 and translate test cases in S002.
- **launchd helper for unattended operation.** S036 may be too big for one slice if we need full XPC-based comms. Acceptable to ship M005 with "keep app open" and add helper post-1.0.
- **App Store vs Developer ID distribution.** Personal use first means Developer ID + notarization (S038). App Store revisited if/when it makes sense; sandboxing implications would need a separate review.
- **Live MPEGTS in the app.** CLI MPEGTS works via S006. Whether the app GUI exposes MPEGTS/UDP as first-class stream types or keeps them CLI-only is a UX call to make at M004-S026.
