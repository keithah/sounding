# Changelog

## 0.2.2 - 2026-06-05

- Added a hybrid broadcast timeline with zoomable marker rails and persisted song/ad marker projection.
- Normalized program metadata at ingest so repeated ID3/fingerprint hits collapse into coherent song spans.
- Added per-stream transcript display modes so song lyrics can be hidden while non-song content remains available.
- Improved song timeline persistence, export-ready marker storage, and stream registry settings for cached audio.
- Hardened runtime stop, restart, and wake recovery so stuck AVFoundation playback cleanup cannot leave the app falsely running.
- Added regression coverage for metadata normalization, timeline projection, song persistence, and playback-stop timeouts.

## 0.2.1 - 2026-05-08

- Moved the selected-stream player back to the bottom of the app and removed duplicated stream identity text from the detail pane.
- Added stream editing from the sidebar context menu while keeping raw stream URLs private in list and diagnostics surfaces.
- Simplified transcript search by removing the speaker filter and clearing speaker filters before search execution.
- Added transcript timeline context actions for copy text, copy with timestamp, save to text file, and play from the row when buffered.
- Hid fingerprint-only unknown song misses from the user-facing timeline and player metadata.
- Tightened transcript paragraph grouping so same-speaker rows do not merge into oversized blocks.

## 0.2.0 - 2026-05-07

- Reworked live HLS ingest and playback around a shared rolling PCM buffer, including live restart handling and transcript click-to-play support for buffered audio.
- Improved timed ID3 handling so current metadata is surfaced in the player and metadata changes appear inline in the timeline without repeated stale rows.
- Simplified the main app layout with global selected-stream player controls, a collapsed Add Stream flow, and a Preferences area for global options.
- Made diarization a per-stream option and defaulted it off so transcript rows do not show placeholder speaker labels unless diarization is enabled.
- Updated transcript timeline behavior with newest-first display, clock timestamps, longer grouped transcript rows, clearing, and search support.
- Added AcoustID enrichment plumbing with ChromaSwift fingerprinting support, a bundled client key path, and override validation in Preferences.
- Hardened first-run database setup, stream persistence, and diagnostics so clean installs do not require manually created folders.
- Added Sparkle update metadata plus distribution checks for Developer ID signing, notarization, DMG packaging, and release appcast generation.

## 0.1.0

- Initial development release.
