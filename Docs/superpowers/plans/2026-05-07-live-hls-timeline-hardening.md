# Live HLS Timeline Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Sounding's app path trustworthy for live HLS playback, metadata, transcript timeline, AcoustID visibility, and release verification.

**Architecture:** Keep the existing SwiftUI -> app runtime -> ingest pipeline -> SQLite -> timeline projection architecture. Tighten the contracts between HLS decode, playable PCM buffering, timeline projection, and global app preferences rather than introducing a second playback path.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation, GRDB, XCTest, Xcode/xctest, existing SoundingKit runtime and CLI scripts.

---

### Task 1: HLS Decode And Playback Contract

**Files:**
- Modify: `Sources/SoundingKit/Ingest/AVFoundationAudioDecoder.swift`
- Modify: `Sources/SoundingKit/AppSupport/AppStreamRuntime.swift`
- Modify: `Sources/SoundingKit/AppSupport/AppPlayerTimeline.swift`
- Test: `Tests/SoundingKitTests/AVFoundationAudioDecoderTests.swift`
- Test: `Tests/SoundingKitTests/AppPlayerTimelineTests.swift`

- [x] Add failing tests proving live HLS only loads one new segment per app ingest pass and decode fallback does not claim playable audio.
- [x] Implement bounded live segment selection and explicit PCM-only playback state.
- [x] Verify with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctest -XCTest SoundingKitTests.AVFoundationAudioDecoderTests .build/debug/SoundingPackageTests.xctest`.
- [x] Verify with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctest -XCTest SoundingKitTests.AppPlayerTimelineTests .build/debug/SoundingPackageTests.xctest`.

### Task 2: Timeline Metadata And Transcript Projection

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/StreamAppTimelineStore.swift`
- Modify: `App/ContentView.swift`
- Test: `Tests/SoundingKitTests/StreamAppTimelineStoreTests.swift`

- [x] Verify existing coverage for clearing transcript plus metadata, collapsing consecutive song metadata, hiding deterministic unknown songs, metadata-as-speaker projection, and full timeline transcript text.
- [x] Add projection coverage for timestamp fields, diarization-off presentation, metadata-derived speaker labels, and seekability.
- [x] Verify with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctest -XCTest SoundingKitTests.StreamAppTimelineStoreTests .build/debug/SoundingPackageTests.xctest`.

### Task 3: AcoustID Runtime Truthfulness

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/SoundingAppRuntimeConfiguration.swift`
- Modify: `Sources/sounding/IngestCommand.swift` if helper reuse is practical
- Modify: `App/PreferencesView.swift`
- Test: `Tests/SoundingKitTests/AppStreamRuntimeTests.swift`
- Test: `Tests/SoundingKitTests/SoundingAppPreferencesTests.swift`

- [x] Add failing tests for real AcoustID HTTP lookup request shape, parsing, and redacted non-fatal failures.
- [x] Wire the CLI real-mode lookup path to the HTTP client and seed the app process environment from Keychain or the bundled key.
- [x] Clarify preferences/status copy so AcoustID is presented as an application-key override, not proof of app-side live fingerprint enrichment.
- [x] Verify with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctest -XCTest SoundingKitTests.AcoustIDLookupTests .build/debug/SoundingPackageTests.xctest`.
- [x] Verify with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctest -XCTest SoundingKitTests.AcoustIDEnrichmentTests .build/debug/SoundingPackageTests.xctest`.
- [x] Verify with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctest -XCTest SoundingKitTests.SoundingAppPreferencesTests .build/debug/SoundingPackageTests.xctest`.
- [x] Remaining gap closed: default app runtime now uses ChromaSwift/Chromaprint `.test2` fingerprints before AcoustID enrichment when decoded linear PCM is available.

### Task 4: Synthetic Live HLS Harness

**Files:**
- Create or extend fixtures under `Tests/SoundingKitTests/Fixtures/HLS/`
- Modify: `Tests/SoundingKitTests/IntegratedAppUATTests.swift` or add focused runtime/timeline tests

- [x] Extend integrated app UAT to prove selected-stream timeline persistence/search, deterministic metadata enrichment, and selected-stream playback routing without AVAudioPlayerNode hangs.
- [x] Verify with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctest -XCTest SoundingKitTests.IntegratedAppUATTests .build/debug/SoundingPackageTests.xctest`.
- [x] Root-cause and fix direct `HLSID3MarkerTests/testSegmentID3ExtractorDemuxesMPEGTSTimedID3Payloads` crash under local `xcrun xctest`.
- [x] Add synthetic HLS UAT coverage for timed-ID3 metadata, PCM playback scheduling, rolling-buffer seekability, transcript projection, and metadata de-duplication.

### Task 5: Docs And Release Verification

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `Docs/shipping.md`

- [x] Update docs to reflect current app, Sparkle, distribution, notarization, and the reliable XCTest invocation.
- [x] Run distribution readiness check and Xcode Debug build.
- [x] Summarize remaining live/operator-only verification gaps.
