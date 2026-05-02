import Foundation
import GRDB

public struct AppVerifyFixtureRunner: Sendable {
  public struct Configuration: Sendable {
    public var runRootDirectory: URL
    public var timeoutSeconds: Double
    public var now: @Sendable () -> Date
    public var timestamp: @Sendable () -> String
    public var makeRunID: @Sendable () -> String

    public init(
      runRootDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SoundingAppVerify", isDirectory: true),
      timeoutSeconds: Double = 8,
      now: @escaping @Sendable () -> Date = { Date() },
      timestamp: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) },
      makeRunID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
      self.runRootDirectory = runRootDirectory
      self.timeoutSeconds = timeoutSeconds.isFinite ? max(0.05, timeoutSeconds) : 8
      self.now = now
      self.timestamp = timestamp
      self.makeRunID = makeRunID
    }
  }

  public typealias RunDirectoryFactory =
    @Sendable (_ configuration: Configuration) throws -> (runID: String, directory: URL)
  public typealias FixtureSourceFactory =
    @Sendable (_ runDirectory: URL) throws -> AppVerifyFixtureSource
  public typealias DatabaseFactory = @Sendable (_ databaseURL: URL) throws -> SoundingDatabase
  public typealias DecoderFactory = @Sendable () -> any AudioDecoding
  public typealias PlayerFactory =
    @Sendable (_ volumeStore: AppPlaybackVolumeStore, _ diagnosticsLog: AppRuntimeDiagnosticsLog) ->
    any AppPCMPlaybackAdapting
  public typealias RuntimeFactory =
    @Sendable (
      _ registry: StreamRegistry,
      _ ingester: any AppStreamRuntimeIngesting,
      _ timeline: AppPlayerTimelineClock,
      _ rollingBuffer: RollingPCMBuffer,
      _ statusStore: AppStreamRuntimeStatusStore?,
      _ volumeStore: AppPlaybackVolumeStore,
      _ player: any AppPCMPlaybackAdapting,
      _ diagnosticsLog: AppRuntimeDiagnosticsLog
    ) -> any AppStreamRuntimeControlling
  public typealias IngesterFactory =
    @Sendable (
      _ database: SoundingDatabase,
      _ decoder: any AudioDecoding,
      _ transcriber: any MLTranscription,
      _ diarizer: any SpeakerDiarization,
      _ fingerprinter: any AudioFingerprinting,
      _ fingerprintEnricher: any AudioFingerprintEnriching,
      _ player: any AppPCMPlaybackAdapting,
      _ timeline: AppPlayerTimelineClock,
      _ rollingBuffer: RollingPCMBuffer,
      _ diagnosticsLog: AppRuntimeDiagnosticsLog,
      _ now: @escaping StreamIngestPipeline.TimestampProvider
    ) -> any AppStreamRuntimeIngesting

  private let configuration: Configuration
  private let runDirectoryFactory: RunDirectoryFactory
  private let fixtureSourceFactory: FixtureSourceFactory
  private let databaseFactory: DatabaseFactory
  private let decoderFactory: DecoderFactory
  private let playerFactory: PlayerFactory
  private let runtimeFactory: RuntimeFactory
  private let ingesterFactory: IngesterFactory

  public init(
    configuration: Configuration = Configuration(),
    runDirectoryFactory: @escaping RunDirectoryFactory = { configuration in
      try AppVerifyFixtureRunner.defaultRunDirectory(configuration: configuration)
    },
    fixtureSourceFactory: @escaping FixtureSourceFactory = { runDirectory in
      try AppVerifyFixtureSourceWriter.writeDeterministicWAV(in: runDirectory)
    },
    databaseFactory: @escaping DatabaseFactory = { url in try SoundingDatabase(fileURL: url) },
    decoderFactory: @escaping DecoderFactory = {
      AVFoundationAudioDecoder(chunkDurationSeconds: 0.25)
    },
    playerFactory: @escaping PlayerFactory = { volumeStore, diagnosticsLog in
      AVFoundationAppPCMPlayerAdapter(volumeStore: volumeStore, diagnosticsLog: diagnosticsLog)
    },
    runtimeFactory: @escaping RuntimeFactory = {
      registry, ingester, timeline, rollingBuffer, statusStore, volumeStore, player, diagnosticsLog
      in
      AppStreamRuntimeService(
        registry: registry,
        ingester: ingester,
        retryPolicy: .noRetry,
        statusStore: statusStore,
        volumeStore: volumeStore,
        playbackTimeline: timeline,
        rollingBuffer: rollingBuffer,
        playbackController: player,
        diagnosticsLog: diagnosticsLog
      )
    },
    ingesterFactory: @escaping IngesterFactory = {
      database, decoder, transcriber, diarizer, fingerprinter, fingerprintEnricher, player,
      timeline, rollingBuffer, diagnosticsLog, now in
      StreamIngestAppRuntimeRunner(
        database: database,
        decoder: decoder,
        transcriber: transcriber,
        diarizer: diarizer,
        fingerprinter: fingerprinter,
        fingerprintEnricher: fingerprintEnricher,
        player: player,
        timeline: timeline,
        rollingBuffer: rollingBuffer,
        diagnosticsLog: diagnosticsLog,
        keepPlaybackRunningAfterIngestCompletes: true,
        now: now
      )
    }
  ) {
    self.configuration = configuration
    self.runDirectoryFactory = runDirectoryFactory
    self.fixtureSourceFactory = fixtureSourceFactory
    self.databaseFactory = databaseFactory
    self.decoderFactory = decoderFactory
    self.playerFactory = playerFactory
    self.runtimeFactory = runtimeFactory
    self.ingesterFactory = ingesterFactory
  }

  public func run() async -> AppVerifyEvidence {
    let generatedAt = configuration.timestamp()
    let preparedRun: (runID: String, directory: URL)
    do {
      preparedRun = try runDirectoryFactory(configuration)
    } catch {
      let check = AppVerifyCheckRecord.fail(
        .fixtureSourceCreated,
        phase: .fixture,
        reason: "Fixture run directory creation failed: \(sanitize(error))."
      )
      return makeEvidence(runID: "unavailable", generatedAt: generatedAt, checks: [check])
    }

    let runID = preparedRun.runID
    let runDirectory = preparedRun.directory
    let artifacts = baseArtifacts(runDirectory: runDirectory)
    var checks: [AppVerifyCheckRecord] = []
    var runtimeFacts = AppVerifyRuntimeFacts(phase: .fixture)

    let fixture: AppVerifyFixtureSource
    do {
      fixture = try fixtureSourceFactory(runDirectory)
      checks.append(
        .pass(
          .fixtureSourceCreated,
          phase: .fixture,
          reason: "Created deterministic WAV fixture.",
          artifacts: [AppVerifyRedactedArtifact(kind: "fixture", path: fixture.url.path)]
        ))
    } catch let error as AppVerifyFixtureSourceError {
      checks.append(error.check)
      return makeEvidence(
        runID: runID, generatedAt: generatedAt, checks: checks, runtimeFacts: runtimeFacts,
        artifacts: artifacts)
    } catch {
      checks.append(
        .fail(
          .fixtureSourceCreated,
          phase: .fixture,
          reason: "Fixture source creation failed: \(sanitize(error))."
        ))
      return makeEvidence(
        runID: runID, generatedAt: generatedAt, checks: checks, runtimeFacts: runtimeFacts,
        artifacts: artifacts)
    }

    let databaseURL = runDirectory.appendingPathComponent("app-verify.sqlite")
    let database: SoundingDatabase
    do {
      database = try databaseFactory(databaseURL)
      checks.append(
        .pass(
          .databaseOpened,
          phase: .database,
          reason: "Opened temporary SoundingDatabase.",
          artifacts: [AppVerifyRedactedArtifact(kind: "database", path: databaseURL.path)]
        ))
    } catch {
      checks.append(
        .fail(
          .databaseOpened,
          phase: .database,
          reason: "Temporary SoundingDatabase open failed: \(sanitize(error)).",
          artifacts: [AppVerifyRedactedArtifact(kind: "database", path: databaseURL.path)]
        ))
      return makeEvidence(
        runID: runID, generatedAt: generatedAt, checks: checks, runtimeFacts: runtimeFacts,
        artifacts: artifacts)
    }

    let registry = StreamRegistry(database: database)
    let stream: StreamRecord
    do {
      stream = try registry.add(
        name: "App Verify Fixture \(runID)",
        streamType: StreamType.icecast.rawValue,
        source: fixture.url.absoluteString,
        createdAt: generatedAt
      )
      checks.append(
        .pass(
          .streamRegistered,
          phase: .registration,
          reason: "Registered generated fixture as an icecast stream.",
          artifacts: [
            AppVerifyRedactedArtifact(kind: "stream-source", path: stream.sourceDescription)
          ]
        ))
    } catch {
      checks.append(
        .fail(
          .streamRegistered,
          phase: .registration,
          reason: "Stream registration failed: \(sanitize(error))."
        ))
      return makeEvidence(
        runID: runID, generatedAt: generatedAt, checks: checks, runtimeFacts: runtimeFacts,
        artifacts: artifacts)
    }

    let diagnostics = AppRuntimeDiagnosticsLog(
      eventLogURL: runDirectory.appendingPathComponent("runtime-events.jsonl"),
      failureLogURL: runDirectory.appendingPathComponent("runtime-errors.jsonl"),
      now: configuration.timestamp
    )
    let volumeStore = AppPlaybackVolumeStore()
    let timeline = AppPlayerTimelineClock()
    let rollingBuffer = RollingPCMBuffer(
      configuration: RollingBufferConfiguration(targetDurationSeconds: 30))
    let player = playerFactory(volumeStore, diagnostics)
    let ingester = ingesterFactory(
      database,
      AppVerifyFixtureAdMarkerDecoratingDecoder(
        upstream: decoderFactory(),
        timestamp: configuration.timestamp
      ),
      AppVerifyDeterministicTranscriber(),
      AppVerifyDeterministicDiarizer(),
      DeterministicAudioFingerprinter(),
      NoOpAudioFingerprintEnricher(),
      player,
      timeline,
      rollingBuffer,
      diagnostics,
      configuration.timestamp
    )
    let runtime = runtimeFactory(
      registry, ingester, timeline, rollingBuffer, nil, volumeStore, player, diagnostics)

    diagnostics.recordEvent(
      "appverify.run.starting",
      streamID: stream.id,
      streamName: stream.name,
      sourceDescription: stream.sourceDescription,
      phase: "appverify.start",
      fields: ["runID": runID]
    )

    let events = await runtime.events()
    let eventRecorder = AppVerifyRuntimeEventRecorder()
    let eventTask = Task {
      for await event in events {
        await eventRecorder.append(event)
      }
    }
    defer { eventTask.cancel() }

    var controlChecks: [AppVerifyCheckRecord] = []
    var timeoutPhase: AppVerifyRuntimePhase?
    let targetVolume = 0.35

    do {
      try await runtime.start(streamID: stream.id)
      try await waitForRuntimePhase(
        .connecting,
        in: eventRecorder,
        streamID: stream.id,
        minimumCount: 1,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "initial connecting"
      )
      try await waitForRuntimePhase(
        .running,
        in: eventRecorder,
        streamID: stream.id,
        minimumCount: 1,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "initial running"
      )
      try await waitForDiagnosticEvent(
        "playback.play.scheduled",
        in: diagnostics,
        minimumCount: 1,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "initial playback scheduling"
      )

      let firstControlMarker = "initial-running"
      await runtime.setMuted(streamID: stream.id, isMuted: true)
      let mutedSnapshot = try await waitForVolumeSnapshot(
        streamID: stream.id,
        in: volumeStore,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "mute applied"
      ) { $0.isMuted && $0.effectiveVolume == 0 }
      try await waitForDiagnosticEvent(
        "playback.volume.applied",
        in: diagnostics,
        minimumCount: 2,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "mute playback volume diagnostic"
      )
      var diagnosticsSnapshot = self.diagnosticsSnapshot(for: diagnostics)
      controlChecks.append(
        controlCheck(
          .playbackMuted,
          requestedAction: "mute",
          runtimePhase: .playbackControl,
          timeline: await timeline.snapshot(),
          volume: mutedSnapshot,
          diagnostics: diagnosticsSnapshot,
          requiredDiagnosticEvents: [
            "runtime.mute.requested", "playback.volume.applied", "runtime.event.published",
          ],
          beforeMarker: firstControlMarker,
          afterMarker: "muted",
          artifacts: diagnosticsArtifacts(diagnostics)
        ))

      await runtime.setVolume(streamID: stream.id, volume: targetVolume)
      let volumeSnapshot = try await waitForVolumeSnapshot(
        streamID: stream.id,
        in: volumeStore,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "volume applied"
      ) { abs($0.volume - targetVolume) < 0.001 && $0.isMuted }
      try await waitForDiagnosticField(
        event: "runtime.volume.requested",
        field: "volume",
        value: "0.350",
        in: diagnostics,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "runtime volume diagnostic"
      )
      diagnosticsSnapshot = self.diagnosticsSnapshot(for: diagnostics)
      controlChecks.append(
        controlCheck(
          .playbackVolumeChanged,
          requestedAction: "volume",
          runtimePhase: .playbackControl,
          timeline: await timeline.snapshot(),
          volume: volumeSnapshot,
          diagnostics: diagnosticsSnapshot,
          requiredDiagnosticEvents: [
            "runtime.volume.requested", "playback.volume.applied", "runtime.event.published",
          ],
          beforeMarker: "muted",
          afterMarker: "volume-0.350",
          artifacts: diagnosticsArtifacts(diagnostics)
        ))

      await runtime.setMuted(streamID: stream.id, isMuted: false)
      let unmutedSnapshot = try await waitForVolumeSnapshot(
        streamID: stream.id,
        in: volumeStore,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "unmute applied"
      ) { !$0.isMuted && abs(Double($0.effectiveVolume) - targetVolume) < 0.001 }
      try await waitForDiagnosticField(
        event: "runtime.mute.requested",
        field: "isMuted",
        value: "false",
        in: diagnostics,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "runtime unmute diagnostic"
      )
      diagnosticsSnapshot = self.diagnosticsSnapshot(for: diagnostics)
      controlChecks.append(
        controlCheck(
          .playbackUnmuted,
          requestedAction: "unmute",
          runtimePhase: .playbackControl,
          timeline: await timeline.snapshot(),
          volume: unmutedSnapshot,
          diagnostics: diagnosticsSnapshot,
          requiredDiagnosticEvents: [
            "runtime.mute.requested", "playback.volume.applied", "runtime.event.published",
          ],
          beforeMarker: "volume-0.350",
          afterMarker: "unmuted",
          artifacts: diagnosticsArtifacts(diagnostics)
        ))

      let stoppedBefore = await eventRecorder.count(streamID: stream.id, phase: .stopped)
      await runtime.stop(streamID: stream.id)
      try await waitForRuntimePhase(
        .stopped,
        in: eventRecorder,
        streamID: stream.id,
        minimumCount: stoppedBefore + 1,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "explicit stop"
      )
      try await waitForTimelineState(
        .stopped,
        in: timeline,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "player stop"
      )
      try await waitForDiagnosticEvent(
        "playback.stop.applied",
        in: diagnostics,
        minimumCount: 1,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "playback stop diagnostic"
      )
      diagnosticsSnapshot = self.diagnosticsSnapshot(for: diagnostics)
      controlChecks.append(
        controlCheck(
          .runtimeStopObserved,
          requestedAction: "stop",
          runtimePhase: .runtimeStop,
          timeline: await timeline.snapshot(),
          volume: await volumeStore.snapshot(streamID: stream.id),
          diagnostics: diagnosticsSnapshot,
          requiredDiagnosticEvents: [
            "runtime.stop.requested", "playback.stop.applied", "runtime.event.published",
          ],
          beforeMarker: "unmuted",
          afterMarker: "stopped",
          artifacts: diagnosticsArtifacts(diagnostics)
        ))

      let connectingBeforeRestart = await eventRecorder.count(
        streamID: stream.id, phase: .connecting)
      let runningBeforeRestart = await eventRecorder.count(streamID: stream.id, phase: .running)
      let scheduledBeforeRestart = diagnosticsSnapshot.eventNames.filter {
        $0 == "playback.play.scheduled"
      }.count
      try await runtime.start(streamID: stream.id)
      try await waitForRuntimePhase(
        .connecting,
        in: eventRecorder,
        streamID: stream.id,
        minimumCount: connectingBeforeRestart + 1,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "restart connecting"
      )
      try await waitForRuntimePhase(
        .running,
        in: eventRecorder,
        streamID: stream.id,
        minimumCount: runningBeforeRestart + 1,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "restart running"
      )
      try await waitForDiagnosticEvent(
        "playback.play.scheduled",
        in: diagnostics,
        minimumCount: scheduledBeforeRestart + 1,
        timeoutSeconds: configuration.timeoutSeconds,
        phaseName: "restart playback scheduling"
      )
      diagnosticsSnapshot = self.diagnosticsSnapshot(for: diagnostics)
      controlChecks.append(
        controlCheck(
          .runtimeRestartObserved,
          requestedAction: "restart",
          runtimePhase: .runtimeRestart,
          timeline: await timeline.snapshot(),
          volume: await volumeStore.snapshot(streamID: stream.id),
          diagnostics: diagnosticsSnapshot,
          requiredDiagnosticEvents: [
            "runtime.start.requested", "playback.play.scheduled", "runtime.event.published",
          ],
          beforeMarker: "stopped",
          afterMarker: "restarted",
          artifacts: diagnosticsArtifacts(diagnostics)
        ))

      await runtime.stopAll()
      await player.stop(timeline: timeline)
      try? await Task.sleep(nanoseconds: 20_000_000)
    } catch let error as AppVerifyRunnerTimeoutError {
      timeoutPhase = phase(forTimeout: error)
      await runtime.stopAll()
      await player.stop(timeline: timeline)
      let diagnosticsSnapshot = self.diagnosticsSnapshot(for: diagnostics)
      let eventsSnapshot = await eventRecorder.snapshot()
      runtimeFacts = runtimeFactsFromCurrentState(
        phase: timeoutPhase ?? .runtimeStop,
        diagnosticsSnapshot: diagnosticsSnapshot,
        timeline: await timeline.snapshot()
      )
      checks.append(
        contentsOf: baseRuntimeChecks(
          events: eventsSnapshot,
          diagnosticsSnapshot: diagnosticsSnapshot,
          timeline: await timeline.snapshot(),
          facts: runtimeFacts,
          artifacts: diagnosticsArtifacts(diagnostics)
        ))
      checks.append(contentsOf: controlChecks)
      checks.append(
        contentsOf: missingControlChecks(
          excluding: controlChecks.map(\.name),
          reason: "Control window timed out: \(sanitize(error)).",
          diagnosticsSnapshot: diagnosticsSnapshot,
          timeline: await timeline.snapshot(),
          volume: await volumeStore.snapshot(streamID: stream.id),
          artifacts: diagnosticsArtifacts(diagnostics)
        ))
      checks.append(
        diagnosticsCheck(
          snapshot: diagnosticsSnapshot, artifacts: diagnosticsArtifacts(diagnostics)))
      return makeEvidence(
        runID: runID,
        generatedAt: generatedAt,
        checks: checks,
        runtimeFacts: runtimeFacts,
        artifacts: artifacts + diagnosticsArtifacts(diagnostics),
        metadata: ["timeoutPhase": timeoutPhase?.rawValue ?? "playback_control"]
      )
    } catch {
      await runtime.stopAll()
      await player.stop(timeline: timeline)
      let diagnosticsSnapshot = self.diagnosticsSnapshot(for: diagnostics)
      let eventsSnapshot = await eventRecorder.snapshot()
      runtimeFacts = runtimeFactsFromCurrentState(
        phase: .playbackControl,
        diagnosticsSnapshot: diagnosticsSnapshot,
        timeline: await timeline.snapshot()
      )
      checks.append(
        contentsOf: baseRuntimeChecks(
          events: eventsSnapshot,
          diagnosticsSnapshot: diagnosticsSnapshot,
          timeline: await timeline.snapshot(),
          facts: runtimeFacts,
          artifacts: diagnosticsArtifacts(diagnostics)
        ))
      checks.append(contentsOf: controlChecks)
      checks.append(
        contentsOf: missingControlChecks(
          excluding: controlChecks.map(\.name),
          reason: "Control window failed: \(sanitize(error)).",
          diagnosticsSnapshot: diagnosticsSnapshot,
          timeline: await timeline.snapshot(),
          volume: await volumeStore.snapshot(streamID: stream.id),
          artifacts: diagnosticsArtifacts(diagnostics)
        ))
      checks.append(
        diagnosticsCheck(
          snapshot: diagnosticsSnapshot, artifacts: diagnosticsArtifacts(diagnostics)))
      return makeEvidence(
        runID: runID,
        generatedAt: generatedAt,
        checks: checks,
        runtimeFacts: runtimeFacts,
        artifacts: artifacts + diagnosticsArtifacts(diagnostics)
      )
    }

    let diagnosticsSnapshot = self.diagnosticsSnapshot(for: diagnostics)
    let eventsSnapshot = await eventRecorder.snapshot()
    let timelineSnapshot = await timeline.snapshot()
    let eventPhases = eventsSnapshot.map(\.phase.statusPhase.rawValue)
    runtimeFacts = runtimeFactsFromCurrentState(
      phase: .diagnostics,
      diagnosticsSnapshot: diagnosticsSnapshot,
      timeline: timelineSnapshot
    )

    checks.append(
      contentsOf: baseRuntimeChecks(
        events: eventsSnapshot,
        diagnosticsSnapshot: diagnosticsSnapshot,
        timeline: timelineSnapshot,
        facts: runtimeFacts,
        artifacts: diagnosticsArtifacts(diagnostics)
      ))
    checks.append(contentsOf: controlChecks)
    checks.append(
      diagnosticsCheck(snapshot: diagnosticsSnapshot, artifacts: diagnosticsArtifacts(diagnostics)))
    checks.append(
      contentsOf: projectionChecks(
        database: database,
        streamID: stream.id,
        timeline: timelineSnapshot,
        diagnosticsSnapshot: diagnosticsSnapshot,
        refreshedAt: generatedAt
      ))

    diagnostics.recordEvent(
      "appverify.run.finished",
      streamID: stream.id,
      streamName: stream.name,
      sourceDescription: stream.sourceDescription,
      phase: "appverify.finish",
      fields: [
        "status": AppVerifyEvidenceSummary.aggregate(checks).status.rawValue,
        "eventPhases": eventPhases.joined(separator: ","),
      ]
    )

    return makeEvidence(
      runID: runID,
      generatedAt: generatedAt,
      checks: checks,
      runtimeFacts: runtimeFacts,
      artifacts: artifacts + diagnosticsArtifacts(diagnostics),
      metadata: [
        "runtimePhases": eventPhases.joined(separator: ","),
        "databasePath": AppVerifyEvidenceSanitizer.artifactPath(databaseURL.path),
      ]
    )
  }

  public static func defaultRunDirectory(configuration: Configuration) throws -> (
    runID: String, directory: URL
  ) {
    let runID = configuration.makeRunID()
    let directory = configuration.runRootDirectory
      .appendingPathComponent("app-verify-\(runID)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (runID, directory)
  }

  private func makeEvidence(
    runID: String,
    generatedAt: String,
    checks: [AppVerifyCheckRecord],
    runtimeFacts: AppVerifyRuntimeFacts? = nil,
    artifacts: [AppVerifyRedactedArtifact] = [],
    metadata: [String: String] = [:]
  ) -> AppVerifyEvidence {
    AppVerifyEvidence(
      generatedAt: generatedAt,
      runID: runID,
      checks: checks,
      runtimeFacts: runtimeFacts,
      artifacts: artifacts,
      metadata: metadata
    )
  }

  private func baseArtifacts(runDirectory: URL) -> [AppVerifyRedactedArtifact] {
    [AppVerifyRedactedArtifact(kind: "run-directory", path: runDirectory.path)]
  }

  private func diagnosticsArtifacts(_ diagnostics: AppRuntimeDiagnosticsLog)
    -> [AppVerifyRedactedArtifact]
  {
    [
      AppVerifyRedactedArtifact(kind: "runtime-events", path: diagnostics.eventLogURL.path),
      AppVerifyRedactedArtifact(kind: "runtime-errors", path: diagnostics.failureLogURL.path),
    ]
  }

  private func baseRuntimeChecks(
    events: [AppStreamRuntimeEvent],
    diagnosticsSnapshot: AppVerifyDiagnosticsSnapshot,
    timeline: AppPlayerTimelineSnapshot,
    facts: AppVerifyRuntimeFacts,
    artifacts: [AppVerifyRedactedArtifact]
  ) -> [AppVerifyCheckRecord] {
    let stoppedEvent =
      events.last { $0.phase.statusPhase == .stopped }
      ?? AppStreamRuntimeEvent(
        streamID: timeline.streamID ?? -1, phase: .stopped, message: "No stopped event recorded.")
    return [
      runtimeStartedCheck(events: events, facts: facts),
      AppVerifyCheckEvaluator.decodeCompleted(
        processedChunks: processedChunks(from: diagnosticsSnapshot),
        decodedChunks: timeline.decodedFrameCount,
        diagnosticEvents: diagnosticsSnapshot.recentNames
      ),
      playbackCheck(
        scheduledBuffers: scheduledBufferCount(from: timeline),
        diagnostics: diagnosticsSnapshot,
        facts: facts
      ),
      runtimeStoppedCheck(terminal: stoppedEvent, timeline: timeline, facts: facts),
    ]
  }

  private func runtimeFactsFromCurrentState(
    phase: AppVerifyRuntimePhase,
    diagnosticsSnapshot: AppVerifyDiagnosticsSnapshot,
    timeline: AppPlayerTimelineSnapshot
  ) -> AppVerifyRuntimeFacts {
    AppVerifyRuntimeFacts(
      phase: phase,
      processedChunks: processedChunks(from: diagnosticsSnapshot),
      decodedChunks: timeline.decodedFrameCount,
      scheduledBuffers: scheduledBufferCount(from: timeline),
      diagnosticCount: diagnosticsSnapshot.eventNames.count + diagnosticsSnapshot.errorNames.count,
      recentDiagnosticEvents: diagnosticsSnapshot.recentNames,
      timelineSnapshotFields: timelineFields(timeline)
    )
  }

  private func processedChunks(from snapshot: AppVerifyDiagnosticsSnapshot) -> Int {
    snapshot.eventEntries
      .last { $0.event == "runner.ingest.completed" }?
      .fields["processedChunks"]
      .flatMap(Int.init) ?? 0
  }

  private func controlCheck(
    _ name: AppVerifyCheckName,
    requestedAction: String,
    runtimePhase: AppVerifyRuntimePhase,
    timeline: AppPlayerTimelineSnapshot,
    volume: AppPlaybackVolumeSnapshot,
    diagnostics: AppVerifyDiagnosticsSnapshot,
    requiredDiagnosticEvents: [String],
    beforeMarker: String,
    afterMarker: String,
    artifacts: [AppVerifyRedactedArtifact]
  ) -> AppVerifyCheckRecord {
    AppVerifyCheckEvaluator.controlObserved(
      name,
      requestedAction: requestedAction,
      observedRuntimePhase: runtimePhase,
      timelineState: timelineStateName(timeline.state),
      volume: volume.volume,
      muted: volume.isMuted,
      effectiveVolume: Double(volume.effectiveVolume),
      diagnostics: diagnostics.recentEntries,
      requiredDiagnosticEvents: requiredDiagnosticEvents,
      beforeMarker: beforeMarker,
      afterMarker: afterMarker,
      artifacts: artifacts
    )
  }

  private func missingControlChecks(
    excluding completedNames: [AppVerifyCheckName],
    reason: String,
    diagnosticsSnapshot: AppVerifyDiagnosticsSnapshot,
    timeline: AppPlayerTimelineSnapshot,
    volume: AppPlaybackVolumeSnapshot,
    artifacts: [AppVerifyRedactedArtifact]
  ) -> [AppVerifyCheckRecord] {
    let completed = Set(completedNames)
    return AppVerifyCheckName.s02ControlRequired.filter { !completed.contains($0) }.map { name in
      let action: String
      switch name {
      case .playbackMuted: action = "mute"
      case .playbackUnmuted: action = "unmute"
      case .playbackVolumeChanged: action = "volume"
      case .runtimeStopObserved: action = "stop"
      case .runtimeRestartObserved: action = "restart"
      default: action = name.rawValue
      }
      return .fail(
        name,
        phase: controlPhase(for: name),
        reason: reason,
        controlFacts: AppVerifyControlObservationFacts(
          requestedAction: action,
          observedRuntimePhase: controlPhase(for: name),
          timelineState: timelineStateName(timeline.state),
          volume: volume.volume,
          muted: volume.isMuted,
          effectiveVolume: Double(volume.effectiveVolume),
          diagnosticEventNames: diagnosticsSnapshot.recentNames,
          diagnostics: diagnosticsSnapshot.recentEntries
        ),
        artifacts: artifacts
      )
    }
  }

  private func waitForRuntimePhase(
    _ phase: AppStreamRuntimeStatusPhase,
    in recorder: AppVerifyRuntimeEventRecorder,
    streamID: Int64,
    minimumCount: Int,
    timeoutSeconds: Double,
    phaseName: String
  ) async throws {
    try await waitUntil(timeoutSeconds: timeoutSeconds, phaseName: phaseName) {
      await recorder.count(streamID: streamID, phase: phase) >= minimumCount
    }
  }

  private func waitForDiagnosticEvent(
    _ event: String,
    in diagnostics: AppRuntimeDiagnosticsLog,
    minimumCount: Int,
    timeoutSeconds: Double,
    phaseName: String
  ) async throws {
    try await waitUntil(timeoutSeconds: timeoutSeconds, phaseName: phaseName) {
      diagnosticsSnapshot(for: diagnostics).eventNames.filter { $0 == event }.count >= minimumCount
    }
  }

  private func waitForDiagnosticField(
    event: String,
    field: String,
    value: String,
    in diagnostics: AppRuntimeDiagnosticsLog,
    timeoutSeconds: Double,
    phaseName: String
  ) async throws {
    try await waitUntil(timeoutSeconds: timeoutSeconds, phaseName: phaseName) {
      diagnosticsSnapshot(for: diagnostics).eventEntries.contains { entry in
        entry.event == event && entry.fields[field] == value
      }
    }
  }

  private func waitForVolumeSnapshot(
    streamID: Int64,
    in store: AppPlaybackVolumeStore,
    timeoutSeconds: Double,
    phaseName: String,
    predicate: @escaping @Sendable (AppPlaybackVolumeSnapshot) -> Bool
  ) async throws -> AppPlaybackVolumeSnapshot {
    var latest = await store.snapshot(streamID: streamID)
    try await waitUntil(timeoutSeconds: timeoutSeconds, phaseName: phaseName) {
      latest = await store.snapshot(streamID: streamID)
      return predicate(latest)
    }
    return latest
  }

  private func waitForTimelineState(
    _ state: AppPlayerState,
    in timeline: AppPlayerTimelineClock,
    timeoutSeconds: Double,
    phaseName: String
  ) async throws {
    try await waitUntil(timeoutSeconds: timeoutSeconds, phaseName: phaseName) {
      await timeline.snapshot().state == state
    }
  }

  private func waitUntil(
    timeoutSeconds: Double,
    phaseName: String,
    predicate: @escaping () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      if await predicate() { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw AppVerifyRunnerTimeoutError(phase: phaseName)
  }

  private func phase(forTimeout error: AppVerifyRunnerTimeoutError) -> AppVerifyRuntimePhase {
    if error.phase.contains("restart") { return .runtimeRestart }
    if error.phase.contains("stop") { return .runtimeStop }
    if error.phase.contains("playback") || error.phase.contains("volume")
      || error.phase.contains("mute")
    {
      return .playbackControl
    }
    return .runtimeStart
  }

  private func controlPhase(for name: AppVerifyCheckName) -> AppVerifyRuntimePhase {
    switch name {
    case .runtimeStopObserved: return .runtimeStop
    case .runtimeRestartObserved: return .runtimeRestart
    default: return .playbackControl
    }
  }

  private func collectTerminalEvent(
    from stream: AsyncStream<AppStreamRuntimeEvent>,
    timeoutSeconds: Double
  ) async throws -> AppVerifyCollectedRuntime {
    try await withThrowingTaskGroup(of: AppVerifyCollectedRuntime.self) { group in
      group.addTask {
        var iterator = stream.makeAsyncIterator()
        var events: [AppStreamRuntimeEvent] = []
        while let event = await iterator.next() {
          events.append(event)
          switch event.phase {
          case .stopped, .error:
            return AppVerifyCollectedRuntime(events: events, terminalEvent: event)
          default:
            continue
          }
        }
        throw AppVerifyRunnerTimeoutError(phase: "event-stream-ended")
      }
      group.addTask {
        let nanoseconds = UInt64((timeoutSeconds * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanoseconds)
        throw AppVerifyRunnerTimeoutError(phase: "runtime-terminal-event")
      }
      guard let first = try await group.next() else {
        throw AppVerifyRunnerTimeoutError(phase: "missing-terminal-event")
      }
      group.cancelAll()
      return first
    }
  }

  private func runtimeStartedCheck(events: [AppStreamRuntimeEvent], facts: AppVerifyRuntimeFacts)
    -> AppVerifyCheckRecord
  {
    let phases = events.map(\.phase.statusPhase)
    guard phases.contains(.connecting), phases.contains(.running) else {
      return .fail(
        .runtimeStarted,
        phase: .runtimeStart,
        reason: "Runtime event stream did not include both connecting and running phases.",
        facts: facts
      )
    }
    return .pass(.runtimeStarted, phase: .runtimeStart, facts: facts)
  }

  private func runtimeStoppedCheck(
    terminal: AppStreamRuntimeEvent,
    timeline: AppPlayerTimelineSnapshot,
    facts: AppVerifyRuntimeFacts
  ) -> AppVerifyCheckRecord {
    switch terminal.phase {
    case .stopped:
      guard timeline.state == .stopped else {
        return .fail(
          .runtimeStopped,
          phase: .runtimeStop,
          reason:
            "Runtime stopped but player timeline state was \(timelineStateName(timeline.state)).",
          facts: facts
        )
      }
      return .pass(.runtimeStopped, phase: .runtimeStop, facts: facts)
    case .error(let message):
      return .fail(
        .runtimeStopped,
        phase: .runtimeStop,
        reason: "Runtime ended in error: \(message).",
        facts: facts
      )
    default:
      return .fail(
        .runtimeStopped,
        phase: .runtimeStop,
        reason: "Runtime terminal event was not stopped or error.",
        facts: facts
      )
    }
  }

  private func playbackCheck(
    scheduledBuffers: Int,
    diagnostics: AppVerifyDiagnosticsSnapshot,
    facts: AppVerifyRuntimeFacts
  ) -> AppVerifyCheckRecord {
    let names = Set(diagnostics.eventNames)
    let hasPrepare = names.contains("playback.prepare.succeeded")
    let hasScheduledEvent = names.contains("playback.play.scheduled")
    guard scheduledBuffers > 0 else {
      return .fail(
        .avfoundationPlaybackScheduled,
        phase: .playback,
        reason:
          "Playback proof requires a player timeline with at least one decoded/scheduled buffer.",
        facts: facts
      )
    }
    guard hasPrepare, hasScheduledEvent else {
      return .fail(
        .avfoundationPlaybackScheduled,
        phase: .playback,
        reason:
          "Playback proof is missing required AVFoundation diagnostic events: prepare=\(hasPrepare), scheduled=\(hasScheduledEvent).",
        facts: facts
      )
    }
    return .pass(.avfoundationPlaybackScheduled, phase: .playback, facts: facts)
  }

  private func diagnosticsCheck(
    snapshot: AppVerifyDiagnosticsSnapshot,
    artifacts: [AppVerifyRedactedArtifact]
  ) -> AppVerifyCheckRecord {
    let facts = AppVerifyRuntimeFacts(
      phase: .diagnostics,
      diagnosticCount: snapshot.eventNames.count + snapshot.errorNames.count,
      recentDiagnosticEvents: snapshot.recentNames
    )
    guard snapshot.eventFileExists else {
      return .fail(
        .diagnosticsWritten,
        phase: .diagnostics,
        reason: "Diagnostics event log was not written.",
        facts: facts,
        artifacts: artifacts
      )
    }
    guard snapshot.malformedLineCount == 0 else {
      return .fail(
        .diagnosticsWritten,
        phase: .diagnostics,
        reason:
          "Diagnostics log contained \(snapshot.malformedLineCount) malformed JSONL entr\(snapshot.malformedLineCount == 1 ? "y" : "ies").",
        facts: facts,
        artifacts: artifacts
      )
    }
    guard snapshot.eventNames.contains("runtime.event.published") else {
      return .fail(
        .diagnosticsWritten,
        phase: .diagnostics,
        reason: "Diagnostics log is missing runtime.event.published entries.",
        facts: facts,
        artifacts: artifacts
      )
    }
    return .pass(
      .diagnosticsWritten,
      phase: .diagnostics,
      facts: facts,
      artifacts: artifacts
    )
  }

  private func projectionChecks(
    database: SoundingDatabase,
    streamID: Int64,
    timeline: AppPlayerTimelineSnapshot,
    diagnosticsSnapshot: AppVerifyDiagnosticsSnapshot,
    refreshedAt: String
  ) -> [AppVerifyCheckRecord] {
    do {
      let probe = try AppVerifyFixtureProjectionProbe.collect(
        database: database,
        streamID: streamID,
        timeline: timeline,
        refreshedAt: refreshedAt,
        diagnosticEvents: diagnosticsSnapshot.recentNames
      )
      return probe.checks
    } catch {
      let reason = "Projection probe failed: \(sanitize(error))."
      return AppVerifyCheckName.s03ProjectionRequired.map { name in
        .fail(
          name,
          phase: projectionPhase(for: name),
          reason: reason,
          projectionFacts: AppVerifyProjectionFacts(
            surface: projectionSurface(for: name),
            recentDiagnosticEvents: diagnosticsSnapshot.recentNames
          )
        )
      }
    }
  }

  private func projectionPhase(for name: AppVerifyCheckName) -> AppVerifyRuntimePhase {
    switch name {
    case .transcriptPersistence: return .transcriptPersistence
    case .transcriptTimelineProjection: return .transcriptTimelineProjection
    case .transcriptSearchProjection: return .transcriptSearchProjection
    case .songMetadataProjection: return .songMetadataProjection
    case .adMetadataProjection: return .adMetadataProjection
    default: return .output
    }
  }

  private func projectionSurface(for name: AppVerifyCheckName) -> String {
    switch name {
    case .transcriptPersistence: return "transcript persistence"
    case .transcriptTimelineProjection: return "transcript timeline"
    case .transcriptSearchProjection: return "transcript search"
    case .songMetadataProjection: return "song metadata"
    case .adMetadataProjection: return "ad metadata"
    default: return name.rawValue
    }
  }

  private func diagnosticsSnapshot(for diagnostics: AppRuntimeDiagnosticsLog)
    -> AppVerifyDiagnosticsSnapshot
  {
    let events = parseDiagnostics(at: diagnostics.eventLogURL)
    let errors = parseDiagnostics(at: diagnostics.failureLogURL)
    return AppVerifyDiagnosticsSnapshot(
      eventFileExists: FileManager.default.fileExists(atPath: diagnostics.eventLogURL.path),
      errorFileExists: FileManager.default.fileExists(atPath: diagnostics.failureLogURL.path),
      eventEntries: events.entries,
      errorEntries: errors.entries,
      malformedLineCount: events.malformedLineCount + errors.malformedLineCount
    )
  }

  private func parseDiagnostics(at url: URL) -> (
    entries: [AppVerifyParsedDiagnosticEntry], malformedLineCount: Int
  ) {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], 0) }
    let text = String(decoding: data, as: UTF8.self)
    var entries: [AppVerifyParsedDiagnosticEntry] = []
    var malformed = 0
    let decoder = JSONDecoder()
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let lineData = String(line).data(using: .utf8) else {
        malformed += 1
        continue
      }
      do {
        let entry = try decoder.decode(AppVerifyRawDiagnosticEntry.self, from: lineData)
        entries.append(
          AppVerifyParsedDiagnosticEntry(
            event: entry.event,
            phase: entry.phase,
            streamID: entry.streamID,
            message: entry.message,
            fields: entry.fields ?? [:]
          ))
      } catch {
        malformed += 1
      }
    }
    return (Array(entries.suffix(64)), malformed)
  }

  private func scheduledBufferCount(from timeline: AppPlayerTimelineSnapshot?) -> Int {
    timeline?.decodedFrameCount ?? 0
  }

  private func scheduledBufferCount(from timeline: AppPlayerTimelineSnapshot) -> Int {
    timeline.decodedFrameCount
  }

  private func timelineFields(_ timeline: AppPlayerTimelineSnapshot?) -> [String: String] {
    guard let timeline else { return [:] }
    let state = timelineStateName(timeline.state)
    return [
      "streamID": timeline.streamID.map(String.init) ?? "nil",
      "state": state,
      "positionSeconds": String(format: "%.3f", timeline.positionSeconds),
      "liveEdgeSeconds": String(format: "%.3f", timeline.liveEdgeSeconds),
      "bufferedStartSeconds": timeline.bufferedStartSeconds.map { String(format: "%.3f", $0) }
        ?? "nil",
      "bufferedEndSeconds": timeline.bufferedEndSeconds.map { String(format: "%.3f", $0) } ?? "nil",
      "driftSeconds": String(format: "%.3f", timeline.driftSeconds),
      "decodedFrameCount": String(timeline.decodedFrameCount),
      "lastMessage": timeline.lastMessage,
    ]
  }

  private func timelineStateName(_ state: AppPlayerState) -> String {
    switch state {
    case .idle: return "idle"
    case .buffering: return "buffering"
    case .playing: return "playing"
    case .paused: return "paused"
    case .stopped: return "stopped"
    case .failed(let message): return "failed: \(message)"
    }
  }

  private func sanitize(_ error: any Error) -> String {
    AppVerifyEvidenceSanitizer.redact(String(describing: error))
  }
}

private actor AppVerifyRuntimeEventRecorder {
  private var events: [AppStreamRuntimeEvent] = []

  func append(_ event: AppStreamRuntimeEvent) {
    events.append(event)
  }

  func count(streamID: Int64, phase: AppStreamRuntimeStatusPhase) -> Int {
    events.filter { $0.streamID == streamID && $0.phase.statusPhase == phase }.count
  }

  func snapshot() -> [AppStreamRuntimeEvent] {
    events
  }
}

private struct AppVerifyCollectedRuntime: Sendable {
  var events: [AppStreamRuntimeEvent]
  var terminalEvent: AppStreamRuntimeEvent
}

private struct AppVerifyRunnerTimeoutError: Error, CustomStringConvertible, Sendable {
  var phase: String
  var description: String { "Timed out waiting for \(phase)." }
}

private struct AppVerifyFixtureAdMarkerDecoratingDecoder: AudioDecoding {
  var upstream: any AudioDecoding
  var timestamp: @Sendable () -> String

  func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
    var chunks = try await upstream.decodedChunks(for: request)
    guard !chunks.isEmpty else { return chunks }
    let index = chunks.startIndex
    let first = chunks[index]
    let markerPTS = first.startSeconds.isFinite ? first.startSeconds : 0
    let marker = AdMarker(
      type: "app_verify_fixture_splice_insert",
      classification: .adStart,
      source: "app_verify_fixture",
      pts: max(0, markerPTS),
      segment: "app-verify-fixture",
      timestamp: timestamp()
    )
    chunks[index].adMarkers.append(marker)
    return chunks
  }
}

private struct AppVerifyFixtureProjectionProbe: Sendable {
  var checks: [AppVerifyCheckRecord]

  static func collect(
    database: SoundingDatabase,
    streamID: Int64,
    timeline: AppPlayerTimelineSnapshot,
    refreshedAt: String,
    diagnosticEvents: [String]
  ) throws -> AppVerifyFixtureProjectionProbe {
    let counts = try AppVerifyFixtureProjectionCounts.fetch(database: database, streamID: streamID)
    let timelineSnapshot = try StreamAppTimelineStore(database: database).snapshot(
      request: StreamAppTimelineRequest(
        streamID: streamID,
        player: timeline,
        paragraphLimit: 10,
        wordLimitPerParagraph: 10,
        metadataLimit: 10,
        timelineLimit: 20,
        lookbackSeconds: nil,
        refreshedAt: refreshedAt
      )
    )
    let searchSnapshot = try StreamAppSearchStore(database: database).snapshot(
      request: StreamAppSearchRequest(
        phrase: "app verify fixture",
        streamIDs: [streamID],
        limit: 10,
        contextSegments: 1,
        player: timeline,
        refreshedAt: refreshedAt
      )
    )

    let transcriptTimelineItems = timelineSnapshot.timelineItems.filter { $0.kind == .transcript }
      .count
    let songMetadataItems = timelineSnapshot.recentMetadata.filter { $0.kind == .song }.count
    let songTimelineItems = timelineSnapshot.timelineItems.filter { $0.kind == .song }.count
    let adMetadataItems = timelineSnapshot.recentMetadata.filter { $0.kind == .event }.count
    let adTimelineItems = timelineSnapshot.timelineItems.filter { $0.kind == .event }.count

    return AppVerifyFixtureProjectionProbe(checks: [
      AppVerifyCheckEvaluator.projectionPopulated(
        .transcriptPersistence,
        surface: "transcript persistence",
        rowCount: min(counts.transcriptSegments, counts.transcriptWords, counts.transcriptFTSRows),
        sampleFields: [
          "segments": String(counts.transcriptSegments),
          "words": String(counts.transcriptWords),
          "ftsRows": String(counts.transcriptFTSRows),
        ],
        diagnosticEvents: diagnosticEvents
      ),
      AppVerifyCheckEvaluator.projectionPopulated(
        .transcriptTimelineProjection,
        surface: "transcript timeline",
        rowCount: counts.transcriptSegments,
        projectionCount: min(timelineSnapshot.transcriptParagraphs.count, transcriptTimelineItems),
        sampleFields: [
          "paragraphs": String(timelineSnapshot.transcriptParagraphs.count),
          "timelineTranscriptItems": String(transcriptTimelineItems),
          "speakers": String(timelineSnapshot.speakers.count),
        ],
        diagnosticEvents: diagnosticEvents
      ),
      AppVerifyCheckEvaluator.projectionPopulated(
        .transcriptSearchProjection,
        surface: "transcript search",
        rowCount: counts.transcriptFTSRows,
        projectionCount: searchSnapshot.results.count,
        sampleFields: [
          "phrase": "app verify fixture",
          "results": String(searchSnapshot.results.count),
          "status": searchSnapshot.diagnostics.status.title,
        ],
        diagnosticEvents: diagnosticEvents
      ),
      AppVerifyCheckEvaluator.projectionPopulated(
        .songMetadataProjection,
        surface: "song metadata",
        rowCount: counts.songRows,
        metadataCount: min(
          counts.songRows, counts.songPlays, max(songMetadataItems, songTimelineItems)),
        sampleFields: [
          "songRows": String(counts.songRows),
          "songPlays": String(counts.songPlays),
          "timelineSongItems": String(songTimelineItems),
          "recentSongMetadata": String(songMetadataItems),
        ],
        diagnosticEvents: diagnosticEvents
      ),
      AppVerifyCheckEvaluator.projectionPopulated(
        .adMetadataProjection,
        surface: "ad metadata",
        rowCount: counts.adEvents,
        metadataCount: min(counts.adEventsWithPTS, max(adMetadataItems, adTimelineItems)),
        sampleFields: [
          "adEvents": String(counts.adEvents),
          "adEventsWithPTS": String(counts.adEventsWithPTS),
          "timelineAdItems": String(adTimelineItems),
          "recentAdMetadata": String(adMetadataItems),
        ],
        diagnosticEvents: diagnosticEvents
      ),
    ])
  }
}

private struct AppVerifyFixtureProjectionCounts: Sendable {
  var transcriptSegments: Int
  var transcriptWords: Int
  var transcriptFTSRows: Int
  var songRows: Int
  var songPlays: Int
  var adEvents: Int
  var adEventsWithPTS: Int

  static func fetch(database: SoundingDatabase, streamID: Int64) throws
    -> AppVerifyFixtureProjectionCounts
  {
    try database.read { db in
      AppVerifyFixtureProjectionCounts(
        transcriptSegments: try count(
          db,
          sql: """
            SELECT COUNT(*)
            FROM transcript_segments
            JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
            WHERE ingest_runs.stream_id = ?
            """,
          streamID: streamID
        ),
        transcriptWords: try count(
          db,
          sql: """
            SELECT COUNT(*)
            FROM transcript_words
            JOIN transcript_segments ON transcript_segments.id = transcript_words.segment_id
            JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
            WHERE ingest_runs.stream_id = ?
            """,
          streamID: streamID
        ),
        transcriptFTSRows: try count(
          db,
          sql: """
            SELECT COUNT(*)
            FROM transcript_segments_fts
            JOIN transcript_segments ON transcript_segments.id = transcript_segments_fts.rowid
            JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
            WHERE ingest_runs.stream_id = ?
            """,
          streamID: streamID
        ),
        songRows: try count(
          db,
          sql: """
            SELECT COUNT(DISTINCT songs.id)
            FROM songs
            JOIN song_plays ON song_plays.song_id = songs.id
            WHERE song_plays.stream_id = ?
            """,
          streamID: streamID
        ),
        songPlays: try count(
          db,
          sql: "SELECT COUNT(*) FROM song_plays WHERE stream_id = ?",
          streamID: streamID
        ),
        adEvents: try count(
          db,
          sql: """
            SELECT COUNT(*)
            FROM ad_events
            JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
            WHERE ingest_runs.stream_id = ?
            """,
          streamID: streamID
        ),
        adEventsWithPTS: try count(
          db,
          sql: """
            SELECT COUNT(*)
            FROM ad_events
            JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
            WHERE ingest_runs.stream_id = ?
              AND ad_events.pts IS NOT NULL
            """,
          streamID: streamID
        )
      )
    }
  }

  private static func count(_ db: Database, sql: String, streamID: Int64) throws -> Int {
    try Int.fetchOne(db, sql: sql, arguments: [streamID]) ?? 0
  }
}

private struct AppVerifyDiagnosticsSnapshot: Sendable {
  var eventFileExists: Bool
  var errorFileExists: Bool
  var eventEntries: [AppVerifyParsedDiagnosticEntry]
  var errorEntries: [AppVerifyParsedDiagnosticEntry]
  var malformedLineCount: Int

  var eventNames: [String] {
    eventEntries.map(\.event)
  }

  var errorNames: [String] {
    errorEntries.map(\.event)
  }

  var recentNames: [String] {
    Array((eventNames + errorNames).suffix(32))
  }

  var recentEntries: [AppVerifyParsedDiagnosticEntry] {
    Array((eventEntries + errorEntries).suffix(32))
  }
}

private struct AppVerifyRawDiagnosticEntry: Decodable {
  var event: String
  var phase: String?
  var streamID: Int64?
  var message: String?
  var fields: [String: String]?
}

private struct AppVerifyDeterministicTranscriber: MLTranscription {
  func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
    [
      TranscriptSegmentDraft(
        sequence: chunk.sequence,
        startSeconds: chunk.startSeconds,
        endSeconds: chunk.endSeconds,
        text: "app verify fixture chunk \(chunk.sequence)",
        confidence: 1,
        words: [
          TranscriptWordDraft(
            sequence: 0,
            speakerLabel: "fixture-speaker",
            startSeconds: chunk.startSeconds,
            endSeconds: min(chunk.endSeconds, chunk.startSeconds + 0.25),
            text: "app",
            confidence: 1
          ),
          TranscriptWordDraft(
            sequence: 1,
            speakerLabel: "fixture-speaker",
            startSeconds: min(chunk.endSeconds, chunk.startSeconds + 0.25),
            endSeconds: min(chunk.endSeconds, chunk.startSeconds + 0.50),
            text: "verify",
            confidence: 1
          ),
          TranscriptWordDraft(
            sequence: 2,
            speakerLabel: "fixture-speaker",
            startSeconds: min(chunk.endSeconds, chunk.startSeconds + 0.50),
            endSeconds: chunk.endSeconds,
            text: "fixture",
            confidence: 1
          ),
        ]
      )
    ]
  }
}

private struct AppVerifyDeterministicDiarizer: SpeakerDiarization {
  func diarize(
    _ chunk: DecodedAudioChunk,
    transcriptSegments: [TranscriptSegmentDraft]
  ) async throws -> [SpeakerTurnDraft] {
    [
      SpeakerTurnDraft(
        speakerLabel: "fixture-speaker",
        startSeconds: chunk.startSeconds,
        endSeconds: chunk.endSeconds,
        confidence: 1
      )
    ]
  }
}
