# Project Review: 2026-05-07

## Scope

This review maps the current Sounding repository after the recent app, HLS, timeline, AcoustID, Sparkle, and distribution work. It focuses on code paths that affect whether a public macOS build is trustworthy: live HLS playback, transcript/metadata projection, replay buffer behavior, preferences, release packaging, and documentation.

## Repository Map

- `App/`: SwiftUI shell, global player controls, preferences, Sparkle update integration, Keychain-backed app secrets.
- `Sources/SoundingKit/AppSupport/`: app runtime orchestration, selected-stream view model, rolling buffer, timeline/search snapshots, player timeline, runtime status persistence.
- `Sources/SoundingKit/Ingest/`: AVFoundation decoding, WhisperKit transcription, FluidAudio diarization, fingerprinting, AcoustID enrichment contracts, ingest pipeline.
- `Sources/SoundingKit/Monitor/`: HLS/ICY/MPEGTS/UDP marker extraction and source adapters.
- `Sources/SoundingKit/Persistence/`: GRDB database, migrations, ingest persistence, AcoustID cache.
- `Sources/sounding/`: CLI commands for monitor, ingest, app-verify, stream status, search, export, soak, and distribution support.
- `Tests/SoundingKitTests/`: XCTest unit, smoke, fixture, migration, runtime, and distribution script coverage.
- `Docs/` and `scripts/distribution/`: operator runbooks, shipping checks, package/appcast scripts, and redaction policy.

## Findings

### High: Live HLS fallback could look buffered while silent

`AVFoundationAudioDecoder` can fall back from failed PCM decode to `.containerBytes` at `Sources/SoundingKit/Ingest/AVFoundationAudioDecoder.swift:81`. Before this review, `SinglePathPCMDecoder` recorded those frames as buffered playback. I added regression coverage and changed the app playback path so non-PCM chunks keep ingest moving without claiming playable buffered audio.

### Medium: AcoustID app fingerprinting now has a real Chromaprint path

`AcoustIDHTTPClientLookup` now performs real HTTP lookup through an injected transport and the CLI `SOUNDING_ACOUSTID_MODE=real` path uses it. The app can seed `SOUNDING_ACOUSTID_API_KEY` from Keychain or the bundled Info.plist key, and default app ingest now uses `ChromaSwiftAudioFingerprinter` for Chromaprint `.test2` fingerprints when decoded linear PCM is available. Deterministic fingerprinting remains available behind `SOUNDING_DETERMINISTIC_FINGERPRINT=1` for fixture-backed proof runs.

### Medium: Timeline projection is strong, but UI-only behavior still needs screenshot coverage

Store-level and integrated app tests cover clearing transcript plus metadata, collapsing repeated ID3 song rows, hiding deterministic unknown songs, metadata-as-speaker projection, clock timestamp fields, diarization-off transcript projection, and seekability. SwiftUI presentation rules live in `App/ContentView.swift`; screenshot coverage is still useful before larger UI churn.

### Medium: Diarization quality should stay opt-in

FluidAudio is correctly per-stream and default-off. Given the live observations, shipping with diarization disabled by default is the right product call; metadata-derived artist labels are better for music/program timeline speaker display than noisy diarization labels.

### Fixed: Timed-ID3 direct XCTest crash

`HLSID3MarkerTests/testSegmentID3ExtractorDemuxesMPEGTSTimedID3Payloads` previously exited with code `-1` under direct `xcrun xctest`. The root cause was `Data` indexing after `removeFirst` in the MPEG-TS PES assembler. `HLSSegmentID3Extractor` now normalizes PES packet/header bytes before indexing, and the focused direct XCTest passes.

## Verified This Pass

- `swift build --product sounding`: package/CLI build succeeded.
- `AppPlayerTimelineTests`: direct XCTest execution, 13 tests, 0 failures.
- `StreamAppTimelineStoreTests`: direct XCTest execution, 11 tests, 0 failures.
- `AVFoundationAudioDecoderTests`: direct XCTest execution, 11 tests, 0 failures.
- `AppStreamRuntimeTests`: direct XCTest execution, 29 tests, 0 failures.
- `StreamAppViewModelTests`: direct XCTest execution, 18 tests, 0 failures.
- `StreamAppViewModelTimelineTests`: direct XCTest execution, 5 tests, 0 failures.
- `AcoustIDLookupTests`: direct XCTest execution, 8 tests, 0 failures.
- `AcoustIDEnrichmentTests`: direct XCTest execution, 6 tests, 0 failures.
- `SoundingAppPreferencesTests`: direct XCTest execution, 9 tests, 0 failures.
- `IntegratedAppUATTests/testSyntheticTimedID3HLSFixtureProjectsPlaybackBufferMetadataAndTranscriptTimeline`: direct XCTest execution, 1 test, 0 failures.
- `HLSID3MarkerTests/testSegmentID3ExtractorDemuxesMPEGTSTimedID3Payloads`: SwiftPM and direct XCTest execution, 1 test, 0 failures.
- `xcodebuild -project Sounding.xcodeproj -scheme Sounding -configuration Debug -destination 'platform=macOS' build`: succeeded.
- `scripts/distribution/check --json --developer-id-identity "Developer ID Application" --notary-profile "sounding-notary"`: `overallStatus=ready`.
- `git diff --check`: clean.

SwiftPM `swift test --filter ...` only built in this environment; direct `xcrun xctest` is the reliable execution path.

## Known Verification Gap

- Default app-side AcoustID enrichment now has a Chromaprint-compatible fingerprinter. Lookup, cache, key storage, and CLI real-mode lookup are verified; a live keyed stream proof should still be captured before marketing this as high-confidence song recognition.

## Recommended Roadmap

1. Capture a live keyed AcoustID proof against a stream segment with known music content and archive the evidence with distribution checks.
2. Add SwiftUI-level tests or screenshot checks for global controls, diarization-off presentation, clock timestamps, add-stream popover, and preferences.
3. Keep live/operator proof local: authorized stream verification, notarization, Sparkle appcast generation, and Gatekeeper checks should produce redacted summaries only.
