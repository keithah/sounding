# ChromaSwift Fingerprinter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task.

**Goal:** Replace the app's no-op AcoustID fingerprint source with a real Chromaprint-compatible fingerprinter.

**Architecture:** Add ChromaSwift through SwiftPM and wrap it behind SoundingKit's existing `AudioFingerprinting` protocol. Reuse the current temporary WAV staging path for decoded PCM chunks, keep deterministic mode for tests, and connect real fingerprints to the existing AcoustID lookup/cache/enrichment seam only when an application key is configured.

**Tech Stack:** SwiftPM, SoundingKit, ChromaSwift, Chromaprint `.test2`, XCTest.

---

### Task 1: Real Fingerprint Generation

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/SoundingKit/Ingest/AudioFingerprinting.swift`
- Test: `Tests/SoundingKitTests/AudioFingerprintingTests.swift`

- [x] Write tests proving a linear PCM chunk produces non-empty Chromaprint `.test2` output and empty/non-PCM chunks do not fabricate rows.
- [x] Run the focused tests and verify the new type is missing.
- [x] Add ChromaSwift as a SwiftPM dependency and implement `ChromaSwiftAudioFingerprinter`.
- [x] Run the focused tests and verify they pass.

### Task 2: Runtime Wiring

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/SoundingAppRuntimeConfiguration.swift`
- Test: focused build/runtime tests.

- [x] Keep `SOUNDING_DETERMINISTIC_FINGERPRINT=1` on the deterministic test path.
- [x] Use `ChromaSwiftAudioFingerprinter` by default.
- [x] Use `AcoustIDAudioFingerprintEnricher` with `AcoustIDHTTPClientLookup` when `SOUNDING_ACOUSTID_API_KEY` is present, otherwise keep no-op enrichment.
- [x] Verify focused runtime/app tests and `swift build --product sounding`.
