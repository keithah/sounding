# Hybrid Timeline Cache Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hybrid timeline with a horizontal song/marker rail, durable optional audio archiving, replay from archive, and metadata/audio export.

**Architecture:** Keep timeline metadata durable in SQLite and keep audio archiving opt-in per stream. Add small boundaries: `StreamAppTimelineRailProjection` for UI spans, `AudioArchiveStore` for durable PCM files + DB rows, `TimelineReplayResolver` for rolling-buffer-then-archive playback, and `TimelineExportService` for JSON/CSV/text/audio exports.

**Tech Stack:** Swift 5.9, SwiftUI, GRDB, XCTest, existing `SoundingKit` app support/runtime/persistence boundaries.

---

## File Structure

- Create `Sources/SoundingKit/AppSupport/StreamAppTimelineRailProjection.swift`: derive horizontal rail spans from timeline items and marker metadata.
- Modify `Sources/SoundingKit/AppSupport/StreamAppTimelineSnapshot.swift`: add rail item models and archive availability fields.
- Modify `Sources/SoundingKit/AppSupport/StreamAppTimelineStore.swift`: fetch marker/source details needed by rail projection and archive availability.
- Create `Sources/SoundingKit/Persistence/AudioArchiveStore.swift`: durable audio archive DB/file boundary.
- Modify `Sources/SoundingKit/Persistence/SoundingDatabaseMigrator.swift`: add stream archive settings and audio archive tables.
- Modify `Sources/SoundingKit/Streams/StreamRegistry.swift`: expose per-stream archive settings.
- Modify `Sources/SoundingKit/Ingest/StreamIngestPipeline.swift`: write decoded frames into archive when enabled.
- Create `Sources/SoundingKit/AppSupport/TimelineReplayResolver.swift`: resolve timeline seeks from rolling buffer, then archive.
- Modify `Sources/SoundingKit/AppSupport/AppStreamPlaybackCommands.swift`: use `TimelineReplayResolver`.
- Create `Sources/SoundingKit/AppSupport/TimelineExportService.swift`: export timeline metadata and retained audio.
- Modify `App/TimelineViews.swift`: add horizontal rail view, zoom controls, context menu entries.
- Modify `App/StreamSidebarViews.swift`: add per-stream edit option for audio archive.
- Modify `App/StreamDetailViews.swift`: place rail above existing event feed.
- Add tests under `Tests/SoundingKitTests/` for rail projection, archive persistence, replay resolution, export, and registry settings.

---

### Task 1: Add Timeline Rail Projection Models

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/StreamAppTimelineSnapshot.swift`
- Create: `Sources/SoundingKit/AppSupport/StreamAppTimelineRailProjection.swift`
- Test: `Tests/SoundingKitTests/StreamAppTimelineRailProjectionTests.swift`

- [ ] **Step 1: Write the failing rail projection tests**

Create `Tests/SoundingKitTests/StreamAppTimelineRailProjectionTests.swift`:

```swift
import XCTest
@testable import SoundingKit

final class StreamAppTimelineRailProjectionTests: XCTestCase {
    func testBuildsSongAndMarkerRailItemsInWindow() {
        let items = [
            timeline("song:1", kind: .song, start: 10, end: 70, title: "ONE-LINERS", subtitle: "HEIDI FOSS"),
            timeline("event:id3:1", kind: .event, start: 24, end: 25, title: "Timed ID3 ad start", subtitle: "ID3"),
            timeline("event:scte35:1", kind: .event, start: 52, end: 55, title: "SCTE-35 break start", subtitle: "SCTE-35"),
            timeline("transcript:1", kind: .transcript, start: 20, end: 30, title: "Speaker", subtitle: "Words")
        ]

        let rail = StreamAppTimelineRailProjection.project(
            items: items,
            visibleStartSeconds: 0,
            visibleEndSeconds: 100
        )

        XCTAssertEqual(rail.visibleStartSeconds, 0)
        XCTAssertEqual(rail.visibleEndSeconds, 100)
        XCTAssertEqual(rail.spans.map(\.id), ["song:1"])
        XCTAssertEqual(rail.markers.map(\.source), [.timedID3, .scte35])
        XCTAssertEqual(rail.spans.first?.normalizedStart, 0.10, accuracy: 0.001)
        XCTAssertEqual(rail.spans.first?.normalizedEnd, 0.70, accuracy: 0.001)
    }

    func testClampsRailItemsToVisibleWindow() {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline("song:1", kind: .song, start: 90, end: 130, title: "Song", subtitle: "Artist")
            ],
            visibleStartSeconds: 100,
            visibleEndSeconds: 120
        )

        XCTAssertEqual(rail.spans.first?.normalizedStart, 0.0, accuracy: 0.001)
        XCTAssertEqual(rail.spans.first?.normalizedEnd, 1.0, accuracy: 0.001)
    }

    private func timeline(
        _ id: String,
        kind: StreamAppTimelineItemKind,
        start: Double,
        end: Double,
        title: String,
        subtitle: String?
    ) -> StreamAppTimelineItem {
        StreamAppTimelineItem(
            id: id,
            kind: kind,
            startSeconds: start,
            endSeconds: end,
            title: title,
            subtitle: subtitle,
            isSeekable: true
        )
    }
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
swift test --filter SoundingKitTests.StreamAppTimelineRailProjectionTests
```

Expected: compile failure because `StreamAppTimelineRailProjection`, `StreamAppTimelineRailSnapshot`, `StreamAppTimelineRailSpan`, `StreamAppTimelineRailMarker`, and `StreamAppTimelineMarkerSource` do not exist.

- [ ] **Step 3: Add rail models to the snapshot file**

Append to `Sources/SoundingKit/AppSupport/StreamAppTimelineSnapshot.swift`:

```swift
public enum StreamAppTimelineMarkerSource: String, Equatable, Sendable {
    case timedID3
    case scte35
    case unknown
}

public struct StreamAppTimelineRailSpan: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var startSeconds: Double
    public var endSeconds: Double
    public var normalizedStart: Double
    public var normalizedEnd: Double
    public var colorToken: String
    public var isSeekable: Bool
}

public struct StreamAppTimelineRailMarker: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var source: StreamAppTimelineMarkerSource
    public var seconds: Double
    public var normalizedPosition: Double
    public var colorToken: String
    public var isSeekable: Bool
}

public struct StreamAppTimelineRailSnapshot: Equatable, Sendable {
    public var visibleStartSeconds: Double
    public var visibleEndSeconds: Double
    public var spans: [StreamAppTimelineRailSpan]
    public var markers: [StreamAppTimelineRailMarker]

    public init(
        visibleStartSeconds: Double,
        visibleEndSeconds: Double,
        spans: [StreamAppTimelineRailSpan] = [],
        markers: [StreamAppTimelineRailMarker] = []
    ) {
        self.visibleStartSeconds = visibleStartSeconds
        self.visibleEndSeconds = visibleEndSeconds
        self.spans = spans
        self.markers = markers
    }
}
```

- [ ] **Step 4: Implement rail projection**

Create `Sources/SoundingKit/AppSupport/StreamAppTimelineRailProjection.swift`:

```swift
import Foundation

public enum StreamAppTimelineRailProjection {
    public static func project(
        items: [StreamAppTimelineItem],
        visibleStartSeconds: Double,
        visibleEndSeconds: Double
    ) -> StreamAppTimelineRailSnapshot {
        let start = min(visibleStartSeconds, visibleEndSeconds)
        let end = max(visibleStartSeconds, visibleEndSeconds)
        let duration = max(end - start, 0.001)

        let spans = items.compactMap { item -> StreamAppTimelineRailSpan? in
            guard item.kind == .song else { return nil }
            let itemEnd = item.endSeconds ?? item.startSeconds
            guard itemEnd >= start && item.startSeconds <= end else { return nil }
            let clampedStart = max(item.startSeconds, start)
            let clampedEnd = min(max(itemEnd, item.startSeconds + 0.001), end)
            let colorKey = item.speakerDisplay?.displayLabel ?? item.subtitle ?? item.title
            return StreamAppTimelineRailSpan(
                id: item.id,
                title: item.title,
                subtitle: item.subtitle,
                startSeconds: item.startSeconds,
                endSeconds: itemEnd,
                normalizedStart: (clampedStart - start) / duration,
                normalizedEnd: (clampedEnd - start) / duration,
                colorToken: StreamAppSpeakerDisplayProjection.fallbackColorToken(for: colorKey),
                isSeekable: item.isSeekable
            )
        }

        let markers = items.compactMap { item -> StreamAppTimelineRailMarker? in
            guard item.kind == .event else { return nil }
            guard item.startSeconds >= start && item.startSeconds <= end else { return nil }
            let source = markerSource(for: item)
            return StreamAppTimelineRailMarker(
                id: item.id,
                title: item.title,
                source: source,
                seconds: item.startSeconds,
                normalizedPosition: (item.startSeconds - start) / duration,
                colorToken: colorToken(for: source),
                isSeekable: item.isSeekable
            )
        }

        return StreamAppTimelineRailSnapshot(
            visibleStartSeconds: start,
            visibleEndSeconds: end,
            spans: spans.sorted { $0.startSeconds < $1.startSeconds },
            markers: markers.sorted { $0.seconds < $1.seconds }
        )
    }

    private static func markerSource(for item: StreamAppTimelineItem) -> StreamAppTimelineMarkerSource {
        let text = "\(item.id) \(item.title) \(item.subtitle ?? "")".lowercased()
        if text.contains("scte") { return .scte35 }
        if text.contains("id3") { return .timedID3 }
        return .unknown
    }

    private static func colorToken(for source: StreamAppTimelineMarkerSource) -> String {
        switch source {
        case .timedID3: return "orange"
        case .scte35: return "red"
        case .unknown: return "gray"
        }
    }
}
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
swift test --filter SoundingKitTests.StreamAppTimelineRailProjectionTests
```

Expected: PASS.

Commit:

```bash
git add Sources/SoundingKit/AppSupport/StreamAppTimelineSnapshot.swift Sources/SoundingKit/AppSupport/StreamAppTimelineRailProjection.swift Tests/SoundingKitTests/StreamAppTimelineRailProjectionTests.swift
git commit -m "feat: add timeline rail projection"
```

---

### Task 2: Add Per-Stream Audio Archive Settings

**Files:**
- Modify: `Sources/SoundingKit/Persistence/SoundingDatabaseMigrator.swift`
- Modify: `Sources/SoundingKit/Streams/StreamRegistry.swift`
- Modify: `Sources/SoundingKit/AppSupport/StreamAppModels.swift`
- Modify: `Sources/SoundingKit/AppSupport/StreamAppViewModel.swift`
- Test: `Tests/SoundingKitTests/StreamRegistryTests.swift`
- Test: `Tests/SoundingKitTests/StreamAppViewModelTests.swift`

- [ ] **Step 1: Write failing registry tests**

Add to `Tests/SoundingKitTests/StreamRegistryTests.swift`:

```swift
func testAudioArchiveSettingIsPerStreamAndPersists() throws {
    let temporary = try TemporarySoundingDatabase()
    let registry = StreamRegistry(database: temporary.database)
    let stream = try registry.add(name: "JFL", streamType: .hls, source: "https://example.test/live.m3u8")

    XCTAssertFalse(stream.audioArchiveEnabled)

    let enabled = try registry.updateAudioArchive(streamID: stream.id, isEnabled: true)
    XCTAssertTrue(enabled.record.audioArchiveEnabled)
    XCTAssertTrue(enabled.changed)

    let unchanged = try registry.updateAudioArchive(streamID: stream.id, isEnabled: true)
    XCTAssertTrue(unchanged.record.audioArchiveEnabled)
    XCTAssertFalse(unchanged.changed)

    XCTAssertTrue(try XCTUnwrap(registry.find(id: stream.id)).audioArchiveEnabled)
}
```

- [ ] **Step 2: Run the failing registry test**

Run:

```bash
swift test --filter SoundingKitTests.StreamRegistryTests/testAudioArchiveSettingIsPerStreamAndPersists
```

Expected: compile failure because `audioArchiveEnabled` and `updateAudioArchive` do not exist.

- [ ] **Step 3: Add migration and model fields**

Modify `StreamRecord` and `StreamReconnectSource` in `Sources/SoundingKit/Streams/StreamRegistry.swift` to include:

```swift
public var audioArchiveEnabled: Bool
```

Add `audioArchiveEnabled: Bool = false` to their initializers.

Add a migration in `Sources/SoundingKit/Persistence/SoundingDatabaseMigrator.swift` after existing stream-management migrations:

```swift
migrator.registerMigration("addStreamAudioArchiveSetting") { db in
    try db.alter(table: "streams") { table in
        table.column("audio_archive_enabled", .boolean).notNull().defaults(to: false)
    }
}
```

Update every `SELECT` in `StreamRegistry` that fetches stream rows to include:

```sql
COALESCE(audio_archive_enabled, 0) AS audio_archive_enabled
```

Update `decode(row:)` to read:

```swift
audioArchiveEnabled: row["audio_archive_enabled"]
```

- [ ] **Step 4: Add registry mutation**

Add to `StreamRegistry`:

```swift
public func updateAudioArchive(streamID: Int64, isEnabled: Bool) throws -> StreamMutationResult {
    let streamID = try validatedID(streamID)
    do {
        return try database.write { db in
            guard let existing = try fetchStream(id: streamID, includeRemoved: false, db: db) else {
                throw StreamRegistryError.streamNotFound
            }
            let changed = existing.audioArchiveEnabled != isEnabled
            if changed {
                try db.execute(
                    sql: """
                    UPDATE streams
                    SET audio_archive_enabled = ?, updated_at = ?
                    WHERE id = ? AND removed_at IS NULL
                    """,
                    arguments: [isEnabled, Self.nowString(), streamID]
                )
            }
            return StreamMutationResult(
                record: try fetchStream(id: streamID, includeRemoved: false, db: db) ?? existing,
                changed: changed
            )
        }
    } catch let error as StreamRegistryError {
        throw error
    } catch {
        throw StreamRegistryError.databaseWriteFailed(message: Self.redactedDatabaseMessage(error))
    }
}
```

- [ ] **Step 5: Surface setting in app models**

Add `audioArchiveEnabled` to `StreamAppListItem` and map it from `StreamRecord` in `StreamAppViewModel`. Add a view-model method:

```swift
public mutating func updateAudioArchive(
    streamID: Int64,
    isEnabled: Bool,
    using registry: StreamRegistry
) throws {
    let result = try registry.updateAudioArchive(streamID: streamID, isEnabled: isEnabled)
    replaceStream(result.record)
}
```

- [ ] **Step 6: Run tests and commit**

Run:

```bash
swift test --filter SoundingKitTests.StreamRegistryTests/testAudioArchiveSettingIsPerStreamAndPersists
swift test --filter SoundingKitTests.StreamAppViewModelTests
```

Expected: PASS.

Commit:

```bash
git add Sources/SoundingKit/Persistence/SoundingDatabaseMigrator.swift Sources/SoundingKit/Streams/StreamRegistry.swift Sources/SoundingKit/AppSupport/StreamAppModels.swift Sources/SoundingKit/AppSupport/StreamAppViewModel.swift Tests/SoundingKitTests/StreamRegistryTests.swift Tests/SoundingKitTests/StreamAppViewModelTests.swift
git commit -m "feat: add per-stream audio archive setting"
```

---

### Task 3: Add Durable Audio Archive Store

**Files:**
- Create: `Sources/SoundingKit/Persistence/AudioArchiveStore.swift`
- Modify: `Sources/SoundingKit/Persistence/SoundingDatabaseMigrator.swift`
- Test: `Tests/SoundingKitTests/AudioArchiveStoreTests.swift`

- [ ] **Step 1: Write failing archive store tests**

Create `Tests/SoundingKitTests/AudioArchiveStoreTests.swift`:

```swift
import XCTest
@testable import SoundingKit

final class AudioArchiveStoreTests: XCTestCase {
    func testWritesIndexesAndReadsArchivedFrame() throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(name: "JFL", streamType: .hls, source: "https://example.test/live.m3u8")
        let store = AudioArchiveStore(database: temporary.database, archiveDirectory: archiveDirectory)

        let frame = SharedPCMFrame(
            streamID: stream.id,
            sequence: 7,
            audio: Data([1, 2, 3, 4]),
            sampleRate: 48_000,
            channelCount: 2,
            startSeconds: 12,
            endSeconds: 18,
            byteCount: 4,
            hlsIdentity: nil
        )

        let row = try store.archive(frame: frame, runID: 41, chunkID: 99)
        XCTAssertEqual(row.streamID, stream.id)
        XCTAssertEqual(row.startSeconds, 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.fileURL.path))

        let resolved = try XCTUnwrap(store.frame(streamID: stream.id, seconds: 12.5))
        XCTAssertEqual(resolved.frame.audio, Data([1, 2, 3, 4]))
        XCTAssertEqual(resolved.row.id, row.id)
    }
}
```

- [ ] **Step 2: Run the failing archive store test**

Run:

```bash
swift test --filter SoundingKitTests.AudioArchiveStoreTests
```

Expected: compile failure because `AudioArchiveStore` and `AudioArchiveRow` do not exist.

- [ ] **Step 3: Add archive table migration**

Add to `SoundingDatabaseMigrator`:

```swift
migrator.registerMigration("addAudioArchiveSegments") { db in
    try db.create(table: "audio_archive_segments") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("stream_id", .integer).notNull().references("streams", onDelete: .cascade)
        table.column("run_id", .integer).notNull().references("ingest_runs", onDelete: .cascade)
        table.column("chunk_id", .integer).notNull().references("ingest_chunks", onDelete: .cascade)
        table.column("sequence", .integer).notNull()
        table.column("start_seconds", .double).notNull()
        table.column("end_seconds", .double).notNull()
        table.column("sample_rate", .double).notNull()
        table.column("channel_count", .integer).notNull()
        table.column("byte_count", .integer).notNull()
        table.column("sha256", .text).notNull()
        table.column("relative_path", .text).notNull()
        table.column("created_at", .text).notNull()
        table.check(sql: "end_seconds >= start_seconds")
        table.uniqueKey(["stream_id", "run_id", "chunk_id", "sequence"])
    }
    try db.create(index: "audio_archive_segments_on_stream_time", on: "audio_archive_segments", columns: ["stream_id", "start_seconds", "end_seconds"])
    try db.create(index: "audio_archive_segments_on_run_chunk", on: "audio_archive_segments", columns: ["run_id", "chunk_id"])
}
```

- [ ] **Step 4: Implement `AudioArchiveStore`**

Create `Sources/SoundingKit/Persistence/AudioArchiveStore.swift`:

```swift
import CryptoKit
import Foundation
import GRDB

public struct AudioArchiveRow: Equatable, Sendable {
    public var id: Int64
    public var streamID: Int64
    public var runID: Int64
    public var chunkID: Int64
    public var sequence: Int
    public var startSeconds: Double
    public var endSeconds: Double
    public var sampleRate: Double
    public var channelCount: Int
    public var byteCount: Int
    public var sha256: String
    public var fileURL: URL
    public var createdAt: String
}

public struct ArchivedAudioFrame: Equatable, Sendable {
    public var row: AudioArchiveRow
    public var frame: SharedPCMFrame
}

public struct AudioArchiveStore: Sendable {
    private let database: SoundingDatabase
    private let archiveDirectory: URL
    private let fileManager: FileManager

    public init(database: SoundingDatabase, archiveDirectory: URL, fileManager: FileManager = .default) {
        self.database = database
        self.archiveDirectory = archiveDirectory
        self.fileManager = fileManager
    }

    @discardableResult
    public func archive(frame: SharedPCMFrame, runID: Int64, chunkID: Int64) throws -> AudioArchiveRow {
        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let relativePath = "stream-\(frame.streamID)/run-\(runID)/chunk-\(chunkID)-frame-\(frame.sequence).pcm"
        let fileURL = archiveDirectory.appendingPathComponent(relativePath, isDirectory: false)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try frame.audio.write(to: fileURL, options: .atomic)
        let hash = SHA256.hash(data: frame.audio).map { String(format: "%02x", $0) }.joined()
        let createdAt = SoundingTimestampClock.timestamp()

        return try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO audio_archive_segments (
                    stream_id, run_id, chunk_id, sequence, start_seconds, end_seconds,
                    sample_rate, channel_count, byte_count, sha256, relative_path, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(stream_id, run_id, chunk_id, sequence) DO UPDATE SET
                    end_seconds = excluded.end_seconds,
                    byte_count = excluded.byte_count,
                    sha256 = excluded.sha256,
                    relative_path = excluded.relative_path
                """,
                arguments: [
                    frame.streamID, runID, chunkID, frame.sequence, frame.startSeconds, frame.endSeconds,
                    frame.sampleRate, frame.channelCount, frame.audio.count, hash, relativePath, createdAt
                ]
            )
            let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM audio_archive_segments WHERE stream_id = ? AND run_id = ? AND chunk_id = ? AND sequence = ?",
                arguments: [frame.streamID, runID, chunkID, frame.sequence]
            ) ?? db.lastInsertedRowID
            return AudioArchiveRow(
                id: id,
                streamID: frame.streamID,
                runID: runID,
                chunkID: chunkID,
                sequence: frame.sequence,
                startSeconds: frame.startSeconds,
                endSeconds: frame.endSeconds,
                sampleRate: frame.sampleRate,
                channelCount: frame.channelCount,
                byteCount: frame.audio.count,
                sha256: hash,
                fileURL: fileURL,
                createdAt: createdAt
            )
        }
    }

    public func frame(streamID: Int64, seconds: Double) throws -> ArchivedAudioFrame? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM audio_archive_segments
                WHERE stream_id = ? AND start_seconds <= ? AND end_seconds >= ?
                ORDER BY start_seconds DESC, id DESC
                LIMIT 1
                """,
                arguments: [streamID, seconds, seconds]
            ) else { return nil }
            let archiveRow = try decode(row)
            let data = try Data(contentsOf: archiveRow.fileURL)
            let frame = SharedPCMFrame(
                streamID: archiveRow.streamID,
                sequence: archiveRow.sequence,
                audio: data,
                sampleRate: archiveRow.sampleRate,
                channelCount: archiveRow.channelCount,
                startSeconds: archiveRow.startSeconds,
                endSeconds: archiveRow.endSeconds,
                byteCount: data.count,
                hlsIdentity: nil
            )
            return ArchivedAudioFrame(row: archiveRow, frame: frame)
        }
    }

    private func decode(_ row: Row) throws -> AudioArchiveRow {
        let relativePath: String = row["relative_path"]
        return AudioArchiveRow(
            id: row["id"],
            streamID: row["stream_id"],
            runID: row["run_id"],
            chunkID: row["chunk_id"],
            sequence: row["sequence"],
            startSeconds: row["start_seconds"],
            endSeconds: row["end_seconds"],
            sampleRate: row["sample_rate"],
            channelCount: row["channel_count"],
            byteCount: row["byte_count"],
            sha256: row["sha256"],
            fileURL: archiveDirectory.appendingPathComponent(relativePath, isDirectory: false),
            createdAt: row["created_at"]
        )
    }
}
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
swift test --filter SoundingKitTests.AudioArchiveStoreTests
```

Expected: PASS.

Commit:

```bash
git add Sources/SoundingKit/Persistence/SoundingDatabaseMigrator.swift Sources/SoundingKit/Persistence/AudioArchiveStore.swift Tests/SoundingKitTests/AudioArchiveStoreTests.swift
git commit -m "feat: persist archived audio segments"
```

---

### Task 4: Archive Decoded Audio During Runtime

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/SoundingAppPreferences.swift`
- Modify: `Sources/SoundingKit/AppSupport/SoundingAppPreferencesStorage.swift`
- Modify: `Sources/SoundingKit/AppSupport/SoundingAppRuntimeConfiguration.swift`
- Modify: `Sources/SoundingKit/Ingest/StreamIngestPipeline.swift`
- Modify: `Sources/SoundingKit/AppSupport/StreamIngestAppRuntimeRunner.swift`
- Test: `Tests/SoundingKitTests/IntegratedAppUATTests.swift`

- [ ] **Step 1: Write failing integrated archive test**

Add to `Tests/SoundingKitTests/IntegratedAppUATTests.swift`:

```swift
func testRuntimeArchivesDecodedAudioWhenStreamArchiveIsEnabled() async throws {
    let temporary = try TemporarySoundingDatabase()
    let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
        .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: archiveDirectory) }
    let registry = StreamRegistry(database: temporary.database)
    let stream = try registry.add(name: "JFL", streamType: .hls, source: "https://example.test/live.m3u8")
    _ = try registry.updateAudioArchive(streamID: stream.id, isEnabled: true)

    let timeline = AppPlayerTimelineClock()
    let spillDirectory = temporary.fileURL.deletingLastPathComponent()
        .appendingPathComponent("SoundingSpill-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: spillDirectory) }
    let rollingBuffer = RollingPCMBuffer(configuration: .appDefault(spillDirectory: spillDirectory))
    let player = DeterministicAppPCMPlayerAdapter()
    let runner = StreamIngestAppRuntimeRunner(
        database: temporary.database,
        decoder: PipelineFakeDecoder(chunks: [
            DecodedAudioChunk(
                sequence: 0,
                segmentURI: "https://example.test/segment-0.ts",
                audio: Data([1, 2, 3, 4]),
                audioFormat: .linearPCM(sampleRate: 44_100, channelCount: 1, bitDepth: 16),
                startSeconds: 0,
                endSeconds: 4,
                startedAt: "2026-06-02T12:00:00Z",
                endedAt: "2026-06-02T12:00:04Z"
            )
        ]),
        transcriber: PipelineFakeTranscriber(segments: [StreamIngestPipelineTestCase.segment(text: "hello", startSeconds: 0, endSeconds: 4)]),
        diarizer: PipelineFakeDiarizer(),
        player: player,
        timeline: timeline,
        rollingBuffer: rollingBuffer,
        audioArchiveStore: AudioArchiveStore(database: temporary.database, archiveDirectory: archiveDirectory),
        ingestMode: .singlePass
    )

    _ = try await runner.run(
        AppStreamRuntimeRequest(
            streamID: stream.id,
            name: stream.name,
            streamType: .hls,
            source: "https://example.test/live.m3u8",
            sourceDescription: stream.sourceDescription,
            isDiarizationEnabled: false,
            isAudioArchiveEnabled: true
        )
    )

    let archived = try XCTUnwrap(AudioArchiveStore(database: temporary.database, archiveDirectory: archiveDirectory).frame(streamID: stream.id, seconds: 1))
    XCTAssertEqual(archived.frame.audio, Data([1, 2, 3, 4]))
}
```

- [ ] **Step 2: Run the failing integrated test**

Run:

```bash
swift test --filter SoundingKitTests.IntegratedAppUATTests/testRuntimeArchivesDecodedAudioWhenStreamArchiveIsEnabled
```

Expected: compile failure because runtime request/archive injection fields do not exist.

- [ ] **Step 3: Add app archive preferences**

Add to `SoundingAppPreferences`:

```swift
public var audioArchiveDirectory: URL?
public var audioArchiveMaximumBytes: Int64
public var audioArchiveDefaultRetentionSeconds: Double
```

Use defaults:

```swift
public static let defaultAudioArchiveMaximumBytes: Int64 = 10 * 1024 * 1024 * 1024
public static let defaultAudioArchiveRetentionSeconds: Double = 7 * 24 * 60 * 60
```

Persist non-secret preferences in `SoundingAppPreferencesStorage` with keys:

```swift
public static let audioArchiveDirectory = "sounding.preferences.audioArchiveDirectory"
public static let audioArchiveMaximumBytes = "sounding.preferences.audioArchiveMaximumBytes"
public static let audioArchiveDefaultRetentionSeconds = "sounding.preferences.audioArchiveDefaultRetentionSeconds"
```

- [ ] **Step 4: Inject archive store into runtime**

Modify `SoundingAppRuntimeConfiguration` so the default archive directory is:

```swift
let archiveDirectory = configuration.audioArchiveDirectory
    ?? configuration.databaseURL.deletingLastPathComponent().appendingPathComponent("AudioArchive", isDirectory: true)
let audioArchiveStore = AudioArchiveStore(database: database, archiveDirectory: archiveDirectory)
```

Pass `audioArchiveStore` into `StreamIngestAppRuntimeRunner`.

- [ ] **Step 5: Archive frames after chunk persistence**

Add optional archive inputs to `StreamIngestPipeline`:

```swift
private let audioArchiveStore: AudioArchiveStore?
private let audioArchiveEnabled: Bool
```

After a chunk is persisted and its `chunkID` is known, archive only linear PCM chunks:

```swift
if audioArchiveEnabled,
   let audioArchiveStore,
   chunk.audioFormat.payloadKind == .linearPCM
{
    let frame = SharedPCMFrame(streamID: streamID, chunk: chunk)
    do {
        _ = try audioArchiveStore.archive(frame: frame, runID: runID, chunkID: chunkID)
    } catch {
        chunkDiagnostics.append(
            diagnostic(
                streamID: streamID,
                source: redactedSource,
                streamType: streamType,
                phase: .persistence,
                message: "Audio archive write failed.",
                context: ["archiveError": .string(IngestRedaction.redact(String(describing: error)))]
            )
        )
    }
}
```

- [ ] **Step 6: Run test and commit**

Run:

```bash
swift test --filter SoundingKitTests.IntegratedAppUATTests/testRuntimeArchivesDecodedAudioWhenStreamArchiveIsEnabled
```

Expected: PASS.

Commit:

```bash
git add Sources/SoundingKit/AppSupport/SoundingAppPreferences.swift Sources/SoundingKit/AppSupport/SoundingAppPreferencesStorage.swift Sources/SoundingKit/AppSupport/SoundingAppRuntimeConfiguration.swift Sources/SoundingKit/AppSupport/StreamIngestAppRuntimeRunner.swift Sources/SoundingKit/Ingest/StreamIngestPipeline.swift Tests/SoundingKitTests/IntegratedAppUATTests.swift
git commit -m "feat: archive runtime audio when enabled"
```

---

### Task 5: Resolve Timeline Replay From Rolling Buffer Then Archive

**Files:**
- Create: `Sources/SoundingKit/AppSupport/TimelineReplayResolver.swift`
- Modify: `Sources/SoundingKit/AppSupport/AppStreamPlaybackCommands.swift`
- Test: `Tests/SoundingKitTests/TimelineReplayResolverTests.swift`
- Test: `Tests/SoundingKitTests/AppStreamRuntimeSeekTests.swift`

- [ ] **Step 1: Write failing resolver tests**

Create `Tests/SoundingKitTests/TimelineReplayResolverTests.swift`:

```swift
import XCTest
@testable import SoundingKit

final class TimelineReplayResolverTests: XCTestCase {
    func testReplayPrefersRollingBufferOverArchive() async throws {
        let temporary = try TemporarySoundingDatabase()
        let archiveDirectory = temporary.fileURL.deletingLastPathComponent()
            .appendingPathComponent("SoundingArchive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }
        let archive = AudioArchiveStore(database: temporary.database, archiveDirectory: archiveDirectory)
        let registry = StreamRegistry(database: temporary.database)
        let stream = try registry.add(name: "JFL", streamType: .hls, source: "https://example.test/live.m3u8")
        _ = try archive.archive(frame: frame(streamID: stream.id, sequence: 1, start: 10, end: 20, bytes: [9]), runID: 1, chunkID: 1)

        let rolling = RollingPCMBuffer(configuration: RollingBufferConfiguration(targetDurationSeconds: 60, hotMemoryDurationSeconds: 60, maximumSpillBytes: 0))
        await rolling.start(streamID: stream.id)
        _ = await rolling.append([frame(streamID: stream.id, sequence: 2, start: 10, end: 20, bytes: [7])])

        let result = await TimelineReplayResolver(rollingBuffer: rolling, audioArchiveStore: archive).resolve(streamID: stream.id, seconds: 12)

        guard case .available(let resolvedFrame, let source) = result else {
            return XCTFail("Expected playable frame")
        }
        XCTAssertEqual(source, .rollingBuffer)
        XCTAssertEqual(resolvedFrame.audio, Data([7]))
    }

    private func frame(
        streamID: Int64,
        sequence: Int,
        start: Double,
        end: Double,
        bytes: [UInt8]
    ) -> SharedPCMFrame {
        SharedPCMFrame(
            streamID: streamID,
            sequence: sequence,
            audio: Data(bytes),
            sampleRate: 44_100,
            channelCount: 1,
            startSeconds: start,
            endSeconds: end,
            byteCount: bytes.count,
            hlsIdentity: nil
        )
    }
}
```

- [ ] **Step 2: Run the failing resolver tests**

Run:

```bash
swift test --filter SoundingKitTests.TimelineReplayResolverTests
```

Expected: compile failure because `TimelineReplayResolver` does not exist.

- [ ] **Step 3: Implement replay resolver**

Create `Sources/SoundingKit/AppSupport/TimelineReplayResolver.swift`:

```swift
import Foundation

public enum TimelineReplaySource: Equatable, Sendable {
    case rollingBuffer
    case audioArchive
}

public enum TimelineReplayResult: Equatable, Sendable {
    case available(SharedPCMFrame, source: TimelineReplaySource)
    case unavailable(requestedSeconds: Double, bufferedRange: RollingBufferRange?, reason: String)
}

public struct TimelineReplayResolver: Sendable {
    private let rollingBuffer: RollingPCMBuffer?
    private let audioArchiveStore: AudioArchiveStore?

    public init(rollingBuffer: RollingPCMBuffer?, audioArchiveStore: AudioArchiveStore?) {
        self.rollingBuffer = rollingBuffer
        self.audioArchiveStore = audioArchiveStore
    }

    public func resolve(streamID: Int64, seconds: Double) async -> TimelineReplayResult {
        if let rollingBuffer {
            let snapshot = await rollingBuffer.snapshot()
            if snapshot.streamID == streamID {
                let result = await rollingBuffer.seek(to: seconds)
                if case .available(let frame) = result {
                    return .available(frame, source: .rollingBuffer)
                }
            }
        }

        if let audioArchiveStore, let archived = try? audioArchiveStore.frame(streamID: streamID, seconds: seconds) {
            return .available(archived.frame, source: .audioArchive)
        }

        let range = await rollingBuffer?.snapshot().bufferedRange
        return .unavailable(
            requestedSeconds: seconds,
            bufferedRange: range,
            reason: "Requested time is not available in rolling buffer or audio archive."
        )
    }
}
```

- [ ] **Step 4: Wire resolver into playback commands**

Modify `AppStreamPlaybackCommands.seek(to:streamID:)` to use:

```swift
let resolver = TimelineReplayResolver(
    rollingBuffer: rollingBuffer,
    audioArchiveStore: audioArchiveStore
)
let result = await resolver.resolve(streamID: streamID, seconds: seconds)
switch result {
case .available(let frame, _):
    try await playbackController?.playReplacingScheduledBuffers([frame], timeline: playbackTimeline)
case .unavailable(let requested, let range, _):
    await playbackTimeline.applySeekResult(.unavailable(requestedSeconds: requested, bufferedRange: range))
}
```

Add `audioArchiveStore: AudioArchiveStore?` to `AppStreamPlaybackCommands` and pass it from `AppStreamRuntimeService`.

- [ ] **Step 5: Run tests and commit**

Run:

```bash
swift test --filter SoundingKitTests.TimelineReplayResolverTests
swift test --filter SoundingKitTests.AppStreamRuntimeSeekTests
```

Expected: PASS.

Commit:

```bash
git add Sources/SoundingKit/AppSupport/TimelineReplayResolver.swift Sources/SoundingKit/AppSupport/AppStreamPlaybackCommands.swift Sources/SoundingKit/AppSupport/AppStreamRuntime.swift Tests/SoundingKitTests/TimelineReplayResolverTests.swift Tests/SoundingKitTests/AppStreamRuntimeSeekTests.swift
git commit -m "feat: replay timeline from archive fallback"
```

---

### Task 6: Add Timeline Metadata And Audio Export

**Files:**
- Create: `Sources/SoundingKit/AppSupport/TimelineExportService.swift`
- Test: `Tests/SoundingKitTests/TimelineExportServiceTests.swift`

- [ ] **Step 1: Write failing export tests**

Create `Tests/SoundingKitTests/TimelineExportServiceTests.swift`:

```swift
import XCTest
@testable import SoundingKit

final class TimelineExportServiceTests: XCTestCase {
    func testExportsTranscriptTextWithTimestamps() throws {
        let item = StreamAppTimelineItem(
            id: "transcript:1",
            kind: .transcript,
            startSeconds: 10,
            endSeconds: 22,
            startTimestamp: "2026-06-02T12:00:10Z",
            endTimestamp: "2026-06-02T12:00:22Z",
            title: "Host",
            subtitle: "This is the transcript.",
            isSeekable: true
        )

        let text = TimelineExportService.transcriptText(items: [item])

        XCTAssertEqual(text, "[2026-06-02T12:00:10Z - 2026-06-02T12:00:22Z] This is the transcript.\n")
    }

    func testExportReportsMissingAudioRanges() throws {
        let result = TimelineExportService.audioManifest(
            requestedStartSeconds: 10,
            requestedEndSeconds: 20,
            retainedRanges: [TimelineExportAudioRange(startSeconds: 10, endSeconds: 14, fileName: "clip-1.pcm")]
        )

        XCTAssertEqual(result.missingRanges, [TimelineExportMissingRange(startSeconds: 14, endSeconds: 20)])
    }
}
```

- [ ] **Step 2: Run failing export tests**

Run:

```bash
swift test --filter SoundingKitTests.TimelineExportServiceTests
```

Expected: compile failure because export types do not exist.

- [ ] **Step 3: Implement export service**

Create `Sources/SoundingKit/AppSupport/TimelineExportService.swift`:

```swift
import Foundation

public struct TimelineExportAudioRange: Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var fileName: String
}

public struct TimelineExportMissingRange: Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
}

public struct TimelineExportAudioManifest: Equatable, Sendable {
    public var retainedRanges: [TimelineExportAudioRange]
    public var missingRanges: [TimelineExportMissingRange]
}

public enum TimelineExportService {
    public static func transcriptText(items: [StreamAppTimelineItem]) -> String {
        items
            .filter { $0.kind == .transcript }
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { item in
                let start = item.startTimestamp ?? String(format: "%.1fs", item.startSeconds)
                let end = item.endTimestamp ?? item.endSeconds.map { String(format: "%.1fs", $0) } ?? start
                let text = item.subtitle ?? item.title
                return "[\(start) - \(end)] \(text)\n"
            }
            .joined()
    }

    public static func timelineJSON(items: [StreamAppTimelineItem]) throws -> Data {
        let rows = items.sorted { $0.startSeconds < $1.startSeconds }.map { item in
            [
                "id": item.id,
                "kind": item.kind.rawValue,
                "title": item.title,
                "subtitle": item.subtitle ?? "",
                "startTimestamp": item.startTimestamp ?? "",
                "endTimestamp": item.endTimestamp ?? "",
            ]
        }
        return try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    }

    public static func audioManifest(
        requestedStartSeconds: Double,
        requestedEndSeconds: Double,
        retainedRanges: [TimelineExportAudioRange]
    ) -> TimelineExportAudioManifest {
        let sorted = retainedRanges.sorted { $0.startSeconds < $1.startSeconds }
        var missing: [TimelineExportMissingRange] = []
        var cursor = requestedStartSeconds
        for range in sorted {
            if range.startSeconds > cursor {
                missing.append(TimelineExportMissingRange(startSeconds: cursor, endSeconds: min(range.startSeconds, requestedEndSeconds)))
            }
            cursor = max(cursor, range.endSeconds)
        }
        if cursor < requestedEndSeconds {
            missing.append(TimelineExportMissingRange(startSeconds: cursor, endSeconds: requestedEndSeconds))
        }
        return TimelineExportAudioManifest(retainedRanges: sorted, missingRanges: missing)
    }
}
```

- [ ] **Step 4: Run tests and commit**

Run:

```bash
swift test --filter SoundingKitTests.TimelineExportServiceTests
```

Expected: PASS.

Commit:

```bash
git add Sources/SoundingKit/AppSupport/TimelineExportService.swift Tests/SoundingKitTests/TimelineExportServiceTests.swift
git commit -m "feat: add timeline export service"
```

---

### Task 7: Add Hybrid Rail UI Above Event Feed

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/StreamAppTimelineSnapshot.swift`
- Modify: `Sources/SoundingKit/AppSupport/StreamAppTimelineStore.swift`
- Modify: `App/TimelineViews.swift`
- Modify: `App/StreamDetailViews.swift`
- Test: `Tests/SoundingKitTests/StreamAppTimelineStoreTests.swift`

- [ ] **Step 1: Write failing snapshot/store test**

Add to `Tests/SoundingKitTests/StreamAppTimelineStoreTests.swift`:

```swift
func testSnapshotIncludesTimelineRail() throws {
    let fixture = try makeFixture()
    let store = StreamAppTimelineStore(database: fixture.temporary.database)

    let snapshot = try store.snapshot(
        request: StreamAppTimelineRequest(
            streamID: fixture.mainStreamID,
            timelineLimit: 10,
            lookbackSeconds: nil
        )
    )

    XCTAssertEqual(snapshot.timelineRail.spans.map(\.title), ["Fixture Song"])
    XCTAssertEqual(snapshot.timelineRail.markers.map(\.source), [.scte35, .scte35])
}
```

- [ ] **Step 2: Run failing store test**

Run:

```bash
swift test --filter SoundingKitTests.StreamAppTimelineStoreTests/testSnapshotIncludesTimelineRail
```

Expected: compile failure because `StreamAppTimelineSnapshot.timelineRail` does not exist.

- [ ] **Step 3: Add rail to snapshot and store**

Add to `StreamAppTimelineSnapshot`:

```swift
public var timelineRail: StreamAppTimelineRailSnapshot
```

Default it in the initializer:

```swift
timelineRail: StreamAppTimelineRailSnapshot = StreamAppTimelineRailSnapshot(visibleStartSeconds: 0, visibleEndSeconds: 0)
```

In `StreamAppTimelineStore.snapshot`, after `timelineItems`:

```swift
let visibleEnd = request.player?.liveEdgeSeconds
    ?? timelineItems.map { $0.endSeconds ?? $0.startSeconds }.max()
    ?? 0
let visibleStart = request.lookbackSeconds.map { max(0, visibleEnd - $0) }
    ?? timelineItems.map(\.startSeconds).min()
    ?? 0
let timelineRail = StreamAppTimelineRailProjection.project(
    items: timelineItems,
    visibleStartSeconds: visibleStart,
    visibleEndSeconds: visibleEnd
)
```

Pass `timelineRail` into the snapshot initializer.

- [ ] **Step 4: Add SwiftUI rail view**

Add to `App/TimelineViews.swift`:

```swift
struct TimelineRailView: View {
    var rail: StreamAppTimelineRailSnapshot
    var seekToSeconds: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(wallClockLabel(rail.visibleStartSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(wallClockLabel(rail.visibleEndSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary.opacity(0.35))
                    .frame(height: 30)
                ForEach(rail.spans) { span in
                    Button {
                        seekToSeconds(span.startSeconds)
                    } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color(for: span.colorToken))
                            .overlay(Text(span.title).font(.caption2.bold()).lineLimit(1).padding(.horizontal, 4), alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(8, CGFloat(span.normalizedEnd - span.normalizedStart) * 600), height: 30)
                    .offset(x: CGFloat(span.normalizedStart) * 600)
                }
                ForEach(rail.markers) { marker in
                    Button {
                        seekToSeconds(marker.seconds)
                    } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: marker.colorToken))
                            .frame(width: 5, height: 34)
                    }
                    .buttonStyle(.plain)
                    .offset(x: CGFloat(marker.normalizedPosition) * 600)
                    .help("\(marker.source.rawValue): \(marker.title)")
                }
            }
            .frame(height: 36)
        }
    }
}
```

Use existing color helpers if present; otherwise add a local `color(for:)` mapping in `TimelineViews.swift`.

- [ ] **Step 5: Place rail above feed**

In `TimelineItemsCard`, render:

```swift
TimelineRailView(rail: rail, seekToSeconds: seekToSeconds)
```

above the `LazyVStack`, and add `rail: StreamAppTimelineRailSnapshot` to `TimelineItemsCard`.

In `StreamDetail`, pass:

```swift
rail: selected.timeline.timelineRail
```

or the equivalent selected snapshot property.

- [ ] **Step 6: Build app and commit**

Run:

```bash
swift test --filter SoundingKitTests.StreamAppTimelineStoreTests/testSnapshotIncludesTimelineRail
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Sounding.xcodeproj -scheme Sounding -configuration Debug build
```

Expected: test PASS and app build succeeds.

Commit:

```bash
git add Sources/SoundingKit/AppSupport/StreamAppTimelineSnapshot.swift Sources/SoundingKit/AppSupport/StreamAppTimelineStore.swift App/TimelineViews.swift App/StreamDetailViews.swift Tests/SoundingKitTests/StreamAppTimelineStoreTests.swift
git commit -m "feat: show hybrid timeline rail"
```

---

### Task 8: Add Context Menu Actions For Play, Copy, And Export

**Files:**
- Modify: `App/TimelineViews.swift`
- Modify: `App/ContentView.swift`
- Test: `Tests/SoundingKitTests/TimelineExportServiceTests.swift`

- [ ] **Step 1: Extend export tests for copy text**

Add to `TimelineExportServiceTests`:

```swift
func testCopyWithTimeIncludesKindAndTimestamp() {
    let item = StreamAppTimelineItem(
        id: "song:1",
        kind: .song,
        startSeconds: 10,
        endSeconds: 70,
        startTimestamp: "2026-06-02T12:00:10Z",
        title: "ONE-LINERS",
        subtitle: "HEIDI FOSS",
        isSeekable: true
    )

    XCTAssertEqual(
        TimelineExportService.copyText(item: item, includesTime: true),
        "[2026-06-02T12:00:10Z] Song: ONE-LINERS - HEIDI FOSS"
    )
}
```

- [ ] **Step 2: Implement copy helper**

Add to `TimelineExportService`:

```swift
public static func copyText(item: StreamAppTimelineItem, includesTime: Bool) -> String {
    let body: String
    switch item.kind {
    case .transcript:
        body = item.subtitle ?? item.title
    case .song:
        body = [item.title, item.subtitle].compactMap { $0 }.joined(separator: " - ")
    case .event:
        body = [item.title, item.subtitle].compactMap { $0 }.joined(separator: " - ")
    }
    guard includesTime else { return body }
    let time = item.startTimestamp ?? String(format: "%.1fs", item.startSeconds)
    return "[\(time)] \(item.kind.title): \(body)"
}
```

- [ ] **Step 3: Update context menu**

In `TimelineItemButton.contextMenu`, replace current items with:

```swift
Button("Play", systemImage: "play.fill") {
    if item.isSeekable {
        seekToSeconds(item.startSeconds)
    } else {
        seekUnavailable(item.startSeconds)
    }
}
Button("Copy Text", systemImage: "doc.on.doc") {
    copyTimelineText(TimelineExportService.copyText(item: item, includesTime: false))
}
Button("Copy with Time", systemImage: "clock.badge.checkmark") {
    copyTimelineText(TimelineExportService.copyText(item: item, includesTime: true))
}
Button("Export Clip", systemImage: "waveform.badge.plus") {
    exportTimelineItem(item)
}
.disabled(!item.isSeekable)
Button("Export Timeline Range", systemImage: "square.and.arrow.down") {
    exportTimelineRange(item)
}
```

Add closures to `TimelineItemButton` and `TimelineItemsCard`:

```swift
var exportTimelineItem: (StreamAppTimelineItem) -> Void
var exportTimelineRange: (StreamAppTimelineItem) -> Void
```

- [ ] **Step 4: Add no-op app wiring with visible message**

In `ContentView`, implement export callbacks by setting `timelineActionMessage`:

```swift
timelineActionMessage = "Export queued for \(item.kind.title.lowercased()) at \(timeRange(item: item))."
```

This keeps the UI path wired before file panels are added.

- [ ] **Step 5: Test, build, commit**

Run:

```bash
swift test --filter SoundingKitTests.TimelineExportServiceTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Sounding.xcodeproj -scheme Sounding -configuration Debug build
```

Expected: tests PASS and app build succeeds.

Commit:

```bash
git add Sources/SoundingKit/AppSupport/TimelineExportService.swift App/TimelineViews.swift App/ContentView.swift Tests/SoundingKitTests/TimelineExportServiceTests.swift
git commit -m "feat: add timeline copy and export actions"
```

---

### Task 9: Add Archive Controls To Stream Edit And Preferences

**Files:**
- Modify: `App/StreamSidebarViews.swift`
- Modify: `App/ContentView.swift`
- Modify: `Sources/SoundingKit/AppSupport/SoundingAppPreferences.swift`
- Modify: `Sources/SoundingKit/AppSupport/SoundingAppPreferencesStorage.swift`
- Test: `Tests/SoundingKitTests/SoundingAppRuntimeFactoryTests.swift`

- [ ] **Step 1: Add preference storage test**

Add to `SoundingAppRuntimeFactoryTests` or a focused preferences test:

```swift
func testAudioArchivePreferencesRoundTrip() {
    let suiteName = "SoundingAudioArchivePreferences-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = SoundingAppPreferencesStorage(defaults: defaults)
    let archiveURL = URL(fileURLWithPath: "/tmp/SoundingAudioArchive", isDirectory: true)

    storage.saveNonSecretPreferences(
        databaseURL: URL(fileURLWithPath: "/tmp/sounding.sqlite"),
        whisperModelName: "base",
        rollingBufferTargetSeconds: 1800,
        isDiarizationEnabled: false,
        audioArchiveDirectory: archiveURL,
        audioArchiveMaximumBytes: 123_456,
        audioArchiveDefaultRetentionSeconds: 3600
    )

    let loaded = storage.load()
    XCTAssertEqual(loaded.audioArchiveDirectory, archiveURL)
    XCTAssertEqual(loaded.audioArchiveMaximumBytes, 123_456)
    XCTAssertEqual(loaded.audioArchiveDefaultRetentionSeconds, 3600)
}
```

- [ ] **Step 2: Run failing preference test**

Run:

```bash
swift test --filter SoundingKitTests.SoundingAppRuntimeFactoryTests/testAudioArchivePreferencesRoundTrip
```

Expected: compile failure until preference arguments exist.

- [ ] **Step 3: Add UI controls**

In the stream options/edit menu under the existing remove/edit actions, add:

```swift
Toggle("Archive audio for replay/export", isOn: Binding(
    get: { selected.item.audioArchiveEnabled },
    set: { updateAudioArchive(selected.item.id, $0) }
))
```

In Preferences, add fields:

```swift
TextField("Audio archive folder", text: $audioArchiveDirectoryDraft)
TextField("Maximum archive GB", value: $audioArchiveMaximumGBDraft, format: .number)
TextField("Default retention hours", value: $audioArchiveRetentionHoursDraft, format: .number)
```

Keep labels explicit: archive is opt-in and can use disk.

- [ ] **Step 4: Test, build, commit**

Run:

```bash
swift test --filter SoundingKitTests.SoundingAppRuntimeFactoryTests/testAudioArchivePreferencesRoundTrip
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Sounding.xcodeproj -scheme Sounding -configuration Debug build
```

Expected: PASS and build succeeds.

Commit:

```bash
git add App/StreamSidebarViews.swift App/ContentView.swift Sources/SoundingKit/AppSupport/SoundingAppPreferences.swift Sources/SoundingKit/AppSupport/SoundingAppPreferencesStorage.swift Tests/SoundingKitTests/SoundingAppRuntimeFactoryTests.swift
git commit -m "feat: add audio archive controls"
```

---

### Task 10: Final Verification And Release Candidate Build

**Files:**
- No planned source edits unless verification exposes failures.

- [ ] **Step 1: Run focused suites**

Run:

```bash
swift test --filter SoundingKitTests.StreamAppTimelineRailProjectionTests
swift test --filter SoundingKitTests.AudioArchiveStoreTests
swift test --filter SoundingKitTests.TimelineReplayResolverTests
swift test --filter SoundingKitTests.TimelineExportServiceTests
swift test --filter SoundingKitTests.StreamRegistryTests
swift test --filter SoundingKitTests.StreamAppViewModelTests
```

Expected: all pass.

- [ ] **Step 2: Run full direct XCTest**

Run:

```bash
swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctest .build/debug/SoundingPackageTests.xctest
```

Expected: `swift test` builds the suite and direct XCTest reports zero failures.

- [ ] **Step 3: Build app**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Sounding.xcodeproj -scheme Sounding -configuration Debug build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual smoke check**

Launch the debug app, add an HLS or MP3 stream, start playback, and verify:

- Timeline rail appears above feed.
- Song spans appear when metadata/fingerprints produce song rows.
- SCTE-35 and timed ID3 marker ticks use distinct colors.
- Timeline click plays if buffered.
- With archive enabled, restart app and replay an archived range.
- Context menu can copy text and copy with timestamp.
- Export action shows a queued/export message.

- [ ] **Step 5: Commit any verification fixes**

If fixes were needed:

```bash
git add <changed-files>
git commit -m "fix: stabilize hybrid timeline archive export"
```

If no fixes were needed, do not create an empty commit.
