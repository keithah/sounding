# Codebase Decomposition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the current god-file hotspots without changing app behavior.

**Architecture:** Keep public behavior stable and carve existing responsibilities into focused files. Start with mechanical SwiftUI extraction, then move pure timeline projection policies out of SQL storage, then split runtime, playback, verification, and test contracts by responsibility.

**Tech Stack:** Swift 5.9, SwiftUI, GRDB, AVFoundation, XCTest.

---

### Task 1: Split SwiftUI View Declarations Out Of `ContentView`

**Files:**
- Modify: `App/ContentView.swift`
- Create: `App/StreamSidebarViews.swift`
- Create: `App/StreamDetailViews.swift`
- Create: `App/GlobalPlayerBar.swift`
- Create: `App/SearchViews.swift`
- Create: `App/TimelineViews.swift`
- Create: `App/ViewFormatting.swift`

- [x] **Step 1: Baseline build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Sounding.xcodeproj -scheme Sounding -configuration Debug build
```

Expected: build succeeds before refactor.

- [x] **Step 2: Move only view structs and formatting helpers**

Move `StreamRow`, `StreamDetail`, `GlobalPlayerBar`, search views, timeline views, `SpeakerBadge`, `StatusPill`, and formatting helpers out of `ContentView.swift`. Do not change their bodies except access control required for cross-file compilation.

- [x] **Step 3: Build**

Run the same Xcode build. Expected: build succeeds.

### Task 2: Split Timeline Projection From SQL Store

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/StreamAppTimelineStore.swift`
- Create: `Sources/SoundingKit/AppSupport/StreamAppTimelineProjection.swift`
- Test: `Tests/SoundingKitTests/StreamAppTimelineProjectionTests.swift`

- [x] **Step 1: Add projection tests**

Create tests covering metadata coalescing, transcript paragraph merging, and metadata-speaker overlay. Use simple in-memory values and no database.

- [x] **Step 2: Verify red**

Run:

```bash
swift test --filter SoundingKitTests.StreamAppTimelineProjectionTests
```

Expected: fails because `StreamAppTimelineProjection` does not exist.

- [x] **Step 3: Move pure projection methods**

Move `coalescedMetadataChanges`, `makeTimelineItems`, transcript coalescing, metadata-speaker overlay, and seekability into `StreamAppTimelineProjection`. Keep SQL fetches in `StreamAppTimelineStore`.

- [x] **Step 4: Verify green**

Run projection tests, then:

```bash
swift test --filter SoundingKitTests.StreamAppTimelineStoreTests
```

### Task 3: Split Runtime And Playback Boundaries

**Files:**
- Modify: `Sources/SoundingKit/AppSupport/AppStreamRuntime.swift`
- Modify: `Sources/SoundingKit/AppSupport/AppPlayerTimeline.swift`
- Create: `Sources/SoundingKit/AppSupport/AppStreamRuntimeModels.swift`
- Create: `Sources/SoundingKit/AppSupport/StreamIngestAppRuntimeRunner.swift`
- Create: `Sources/SoundingKit/AppSupport/AppStreamPlaybackCommands.swift`
- Create: `Sources/SoundingKit/AppSupport/AppPlaybackVolumeStore.swift`
- Create: `Sources/SoundingKit/AppSupport/AppPCMPlaybackAdapter.swift`
- Create: `Sources/SoundingKit/AppSupport/AVFoundationAppPCMPlayerAdapter.swift`
- Create: `Sources/SoundingKit/AppSupport/DeterministicAppPCMPlayerAdapter.swift`
- Create: `Sources/SoundingKit/AppSupport/SinglePathPCMDecoder.swift`
- Test: `Tests/SoundingKitTests/AppStreamRuntime*Tests.swift`

- [x] **Step 1: Preserve existing runtime tests**

Run:

```bash
swift test --filter AppStreamRuntime
```

- [x] **Step 2: Extract playback commands**

Move `setVolume`, `setMuted`, `seek`, `seekToLive`, and `scrubBackward` orchestration into `AppStreamPlaybackCommands`.

- [x] **Step 3: Split runtime and playback models**

Move runtime contracts and runner implementation out of `AppStreamRuntime.swift`. Split player timeline models, volume store, adapter protocol, AVFoundation adapter, deterministic adapter, and decoder tee out of `AppPlayerTimeline.swift`.

- [x] **Step 4: Verify runtime tests**

Run the direct XCTest classes for lifecycle, seek, pipeline runner, and factory coverage.

### Task 4: Reduce Verification Runner Duplication

**Files:**
- Modify: `Sources/SoundingKit/AppVerification/AppVerifyFixtureRunner.swift`
- Modify: `Sources/SoundingKit/AppVerification/AppVerifyLiveRunner.swift`
- Create: `Sources/SoundingKit/AppVerification/AppVerifyFixtureRunnerChecks.swift`
- Create: `Sources/SoundingKit/AppVerification/AppVerifyFixtureSupport.swift`
- Create: `Sources/SoundingKit/AppVerification/AppVerifyLiveStreamExecution.swift`
- Create: `Sources/SoundingKit/AppVerification/AppVerifyLiveSupport.swift`

- [x] **Step 1: Extract focused artifact/check helpers**

Move fixture checks, fixture support types, live stream execution contracts, and live runtime support types into focused files.

- [x] **Step 2: Verify app verification tests**

Run:

```bash
swift test --filter SoundingKitTests.AppVerify
```

### Task 5: Split Runtime And Ingest Pipeline Test Monoliths

**Files:**
- Delete: `Tests/SoundingKitTests/AppStreamRuntimeTests.swift`
- Create: `Tests/SoundingKitTests/AppStreamRuntimeLifecycleTests.swift`
- Create: `Tests/SoundingKitTests/AppStreamRuntimeSeekTests.swift`
- Create: `Tests/SoundingKitTests/AppStreamRuntimePipelineRunnerTests.swift`
- Create: `Tests/SoundingKitTests/AppStreamRuntimeTestSupport.swift`
- Create: `Tests/SoundingKitTests/SoundingAppRuntimeFactoryTests.swift`
- Delete: `Tests/SoundingKitTests/StreamIngestPipelineTests.swift`
- Create: `Tests/SoundingKitTests/StreamIngestPipelineHLSTests.swift`
- Create: `Tests/SoundingKitTests/StreamIngestPipelineInferenceTests.swift`
- Create: `Tests/SoundingKitTests/StreamIngestPipelineFailureTests.swift`
- Create: `Tests/SoundingKitTests/StreamIngestPipelineTestSupport.swift`

- [x] **Step 1: Split runtime tests by behavior**

Move lifecycle, seek, pipeline runner, and factory tests into separate classes with shared test support.

- [x] **Step 2: Split ingest pipeline tests by behavior**

Move HLS, inference, and failure tests into separate classes with prefixed shared fixtures to avoid test-target name collisions.

- [x] **Step 3: Verify split test classes**

Run direct `xcrun xctest` selectors for the split classes.

### Task 6: Introduce Typed Registry Transport Boundary

**Files:**
- Modify: `Sources/SoundingKit/Streams/StreamRegistry.swift`
- Modify: `Sources/SoundingKit/AppSupport/StreamAppViewModel.swift`
- Modify: query models that expose stream type strings.

- [x] **Step 1: Add typed accessors**

Add typed `StreamType` accessors while leaving database storage raw.

- [x] **Step 2: Migrate call sites**

Prefer typed accessors in app/runtime code. Keep raw strings only in database and export/query DTOs.

- [x] **Step 3: Run registry and view model tests**

```bash
swift test --filter SoundingKitTests.StreamRegistryTests
swift test --filter SoundingKitTests.StreamAppViewModelTests
```
