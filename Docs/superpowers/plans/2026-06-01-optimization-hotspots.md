# Optimization Hotspots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the highest-risk live-stream hot spots found by the code optimizer without broad package restructuring.

**Architecture:** Keep changes localized to runtime buffering, URL loading, timeline database access, and timestamp projection. Preserve current public APIs unless a narrow internal helper is needed for testing.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, GRDB/SQLite, SwiftUI.

---

### Task 1: Rolling Buffer Keyed Dedupe

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/RollingBuffer.swift`
- Test: `Tests/SoundingKitTests/RollingBufferTests.swift`

- [ ] Add a regression test that appending duplicate HLS and PCM frames keeps one retained frame.
- [ ] Verify the test fails if dedupe state is not maintained independently.
- [ ] Add `RollingBufferFrameKey` and a `retainedFrameKeys` set.
- [ ] Insert keys on append and remove keys during eviction/cleanup/start.
- [ ] Run `swift test --filter SoundingKitTests.RollingBufferTests`.

### Task 2: Cancellation-Aware URL Loading

**Files:**
- Modify: `Sources/SoundingKit/Monitor/HLS/HLSURLSessionDataLoader.swift`
- Test: `Tests/SoundingKitTests/HLSURLSessionDataLoaderTests.swift`

- [ ] Add a URL protocol test that cancels an in-flight load and observes protocol cancellation.
- [ ] Implement a cancellation handler that cancels the underlying `URLSessionTask`.
- [ ] Keep the continuation bridge single-resume safe.
- [ ] Run `swift test --filter SoundingKitTests.HLSURLSessionDataLoaderTests`.

### Task 3: Timeline Query Indexes And Projection Churn

**Files:**
- Modify: `Sources/SoundingKit/Persistence/SoundingDatabaseMigrator.swift`
- Modify: `Sources/SoundingKit/AppSupport/StreamAppTimelineStore.swift`
- Modify: `App/ViewFormatting.swift`
- Test: `Tests/SoundingKitTests/SoundingDatabaseMigrationTests.swift`
- Test: `Tests/SoundingKitTests/StreamAppTimelineStoreTests.swift`

- [ ] Add migration coverage for transcript, ad-event, and song-play timeline indexes.
- [ ] Add query-plan checks where feasible for new timeline indexes.
- [ ] Add the composite indexes in a new migration.
- [ ] Cache ISO8601 parsing/formatting inside timeline projection and SwiftUI timestamp formatting.
- [ ] Run focused migration and timeline-store tests.

### Task 4: Verification

**Files:**
- Existing build/test files only.

- [ ] Run `swift build --product sounding`.
- [ ] Run focused test filters touched in Tasks 1-3.
- [ ] Run `swift test`.
- [ ] Run `git diff --check`.

### Task 5: Bound Live Verification Fan-Out

**Files:**
- Modify: `Sources/SoundingKit/LiveVerification/LiveStreamVerification.swift`
- Modify: `Sources/SoundingKit/LiveVerification/LiveStreamVerifier.swift`
- Test: `Tests/SoundingKitTests/LiveStreamVerifierTests.swift`

- [x] Add a regression test that explicit verifier fan-out preserves result order while limiting active stream checks.
- [x] Add a config-level regression test for `maxConcurrentStreams`.
- [x] Implement bounded task scheduling with a conservative default.
- [x] Decode and validate optional `maxConcurrentStreams` from live verification JSON config.
- [x] Run direct `LiveStreamVerifierTests`.

### Task 6: Cache Diagnostics Log Writers

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/AppRuntimeDiagnosticsLog.swift`
- Test: `Tests/SoundingKitTests/AppRuntimeDiagnosticsLogTests.swift`

- [x] Add a regression test for deterministic JSONL output across shared event/failure log writers.
- [x] Add a locked cached writer behind runtime diagnostics logging.
- [x] Add `closeCachedWriters()` for flush/cleanup at test and process boundaries.
- [x] Run direct `AppRuntimeDiagnosticsLogTests`.

### Task 7: Reuse Ingest Timestamp Formatter

**Files:**
- Modify: `Sources/SoundingKit/Ingest/StreamIngestPipeline.swift`
- Test: `Tests/SoundingKitTests/StreamIngestPipelineHLSTests.swift`

- [x] Add a regression test that the default timestamp is ISO8601 parseable and explicit timestamp injection still wins.
- [x] Add a locked shared timestamp formatter for pipeline default run timestamps.
- [x] Run direct `StreamIngestPipelineHLSTests`.

### Task 8: Reuse Search Snapshot Timestamp Formatter

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/StreamAppSearchSnapshot.swift`
- Test: `Tests/SoundingKitTests/StreamAppSearchSnapshotTests.swift`

- [x] Add a regression test that search request default timestamps are ISO8601 parseable and explicit refresh timestamps still win.
- [x] Add a locked shared timestamp formatter for search request refresh timestamps.
- [x] Run direct `StreamAppSearchSnapshotTests`.

### Task 9: Centralize Default Timestamp Providers

**Files:**
- Add: `Sources/SoundingKit/SoundingTimestampClock.swift`
- Test: `Tests/SoundingKitTests/SoundingTimestampClockTests.swift`
- Modify: runtime, ingest, app verification, timeline, stream registry timestamp defaults

- [x] Add a regression test for a shared ISO8601 timestamp clock.
- [x] Replace direct default `ISO8601DateFormatter().string(from: Date())` allocations in production code with the shared clock.
- [x] Remove duplicate private timestamp clock implementations.
- [x] Run direct clock, ingest, timeline-store, registry, and diagnostics-log tests.

### Task 10: Centralize Stable JSON Encoder Factories

**Files:**
- Add: `Sources/SoundingKit/SoundingJSONCoding.swift`
- Test: `Tests/SoundingKitTests/SoundingJSONCodingTests.swift`
- Modify: live verification, app verification evidence, soak evidence, diagnostics logging

- [x] Add regression tests for stable sorted/no-escaped-slashes and pretty sorted encoder output.
- [x] Replace duplicate JSON encoder setup with shared factory methods.
- [x] Preserve app-verify, soak, live verification, and diagnostics JSON shapes.
- [x] Run direct JSON coding and affected evidence/verification tests.

### Task 11: Index Timeline Metadata Lookups

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/StreamAppTimelineProjection.swift`
- Test: `Tests/SoundingKitTests/StreamAppTimelineProjectionTests.swift`

- [x] Add regression tests for indexed song-boundary and artist-window lookup behavior.
- [x] Add a small metadata index used by transcript speaker projection and paragraph coalescing.
- [x] Replace repeated metadata filter/sort scans in timeline projection with the index.
- [x] Run direct timeline projection and timeline-store tests.

### Task 12: Reuse Timeline Song Metadata Index

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/StreamAppTimelineProjection.swift`
- Test: `Tests/SoundingKitTests/StreamAppTimelineProjectionTests.swift`

- [x] Add regression tests for indexed recent/current song metadata lookup.
- [x] Route `recentMetadata` and `currentMetadata` through the metadata index.
- [x] Keep current metadata fallback behavior when no player position is available.
- [x] Run direct timeline projection tests.

### Task 13: Partition Single-Path Playback Frames Once

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/SinglePathPCMDecoder.swift`
- Test: `Tests/SoundingKitTests/AppPlayerTimelineTests.swift`

- [x] Add regression tests for linear PCM partitioning and decoded-audio detection.
- [x] Use the partition in `SinglePathPCMDecoder` for rolling-buffer append, playback scheduling, and buffering diagnostics.
- [x] Avoid duplicate linear PCM scans while preserving playback dedupe behavior.
- [x] Run direct app-player timeline tests.
