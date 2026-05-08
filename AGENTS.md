# Repository Guidelines

## Project Structure & Module Organization

Sounding is a Swift 5.9 macOS project. `Package.swift` defines the `SoundingKit` library and `sounding` CLI executable. Core code lives in `Sources/SoundingKit/`, organized by domain: `Ingest`, `Monitor`, `Markers`, `Persistence`, `Query`, `Soak`, `LiveVerification`, and `AppSupport`. CLI commands live in `Sources/sounding/`. The SwiftUI app is in `App/`, with XcodeGen configuration in `project.yml` and the generated project in `Sounding.xcodeproj/`. Tests are under `Tests/SoundingKitTests/`; helpers are in `Support/` and media fixtures in `Fixtures/`. Operational docs and examples live in `Docs/`; local proof/output directories such as `live-proof.local/` and `shipping.local/` must remain untracked.

## Build, Test, and Development Commands

- `swift build --product sounding`: builds the CLI and library.
- `swift run sounding streams status --db "[redacted-db-path]" --json`: runs the CLI locally with redacted placeholder paths in shared notes.
- `swift test`: runs the full SwiftPM test suite when XCTest is available.
- `swift test --filter SoundingKitTests.AppStreamRuntimeTests`: runs one focused test class.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Sounding.xcodeproj -scheme Sounding -configuration Debug build`: verifies the macOS app target.
- `scripts/distribution/check --json`: runs credential-safe distribution readiness checks.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for methods/properties, and domain suffixes such as `Runner`, `Store`, `Adapter`, `Decoder`, and `Command`. Keep command output formatting in `Sources/sounding/*Output.swift` and shared behavior in `SoundingKit`. Prefer dependency injection for testable runners, stores, and adapters. No project formatter is configured; match neighboring files.

## Testing Guidelines

Use XCTest in `Tests/SoundingKitTests`. Name test files after the unit or workflow under test, ending in `Tests.swift`; CLI smoke tests use `*CommandSmokeTests.swift`. Add fixtures under `Fixtures/` only when deterministic and safe to commit. Prefer focused filters during iteration, then run broader `swift test`. If `swift test --filter ...` only builds, execute the bundle directly, for example `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xctest -XCTest SoundingKitTests.AppPlayerTimelineTests .build/debug/SoundingPackageTests.xctest`.

## Commit & Pull Request Guidelines

Recent history uses concise Conventional Commit prefixes such as `feat:`, `test:`, `docs:`, and `chore:`. Keep subjects imperative and specific, for example `test: Add live verifier redaction coverage`. Pull requests should describe the behavior change, list verification commands run, link related issues or milestone slices, and include screenshots only for app UI changes.

## Security & Configuration Tips

Never commit raw stream URLs, signed query strings, credentials, local database paths, evidence artifact paths, `.env` contents, or Apple signing/notary details. In tracked docs and examples, use placeholders like `[authorized-live-url]`, `[redacted-db-path]`, and `live-proof.local/...`.
