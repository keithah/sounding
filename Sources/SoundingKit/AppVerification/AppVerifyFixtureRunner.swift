import Foundation

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

    public typealias RunDirectoryFactory = @Sendable (_ configuration: Configuration) throws -> (runID: String, directory: URL)
    public typealias FixtureSourceFactory = @Sendable (_ runDirectory: URL) throws -> AppVerifyFixtureSource
    public typealias DatabaseFactory = @Sendable (_ databaseURL: URL) throws -> SoundingDatabase
    public typealias DecoderFactory = @Sendable () -> any AudioDecoding
    public typealias PlayerFactory = @Sendable (_ volumeStore: AppPlaybackVolumeStore, _ diagnosticsLog: AppRuntimeDiagnosticsLog) -> any AppPCMPlaybackAdapting
    public typealias RuntimeFactory = @Sendable (
        _ registry: StreamRegistry,
        _ ingester: any AppStreamRuntimeIngesting,
        _ timeline: AppPlayerTimelineClock,
        _ rollingBuffer: RollingPCMBuffer,
        _ statusStore: AppStreamRuntimeStatusStore?,
        _ volumeStore: AppPlaybackVolumeStore,
        _ player: any AppPCMPlaybackAdapting,
        _ diagnosticsLog: AppRuntimeDiagnosticsLog
    ) -> any AppStreamRuntimeControlling
    public typealias IngesterFactory = @Sendable (
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
        decoderFactory: @escaping DecoderFactory = { AVFoundationAudioDecoder(chunkDurationSeconds: 0.25) },
        playerFactory: @escaping PlayerFactory = { volumeStore, diagnosticsLog in
            AVFoundationAppPCMPlayerAdapter(volumeStore: volumeStore, diagnosticsLog: diagnosticsLog)
        },
        runtimeFactory: @escaping RuntimeFactory = { registry, ingester, timeline, rollingBuffer, statusStore, volumeStore, player, diagnosticsLog in
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
        ingesterFactory: @escaping IngesterFactory = { database, decoder, transcriber, diarizer, fingerprinter, fingerprintEnricher, player, timeline, rollingBuffer, diagnosticsLog, now in
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
                keepPlaybackRunningAfterIngestCompletes: false,
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
            checks.append(.pass(
                .fixtureSourceCreated,
                phase: .fixture,
                reason: "Created deterministic WAV fixture.",
                artifacts: [AppVerifyRedactedArtifact(kind: "fixture", path: fixture.url.path)]
            ))
        } catch let error as AppVerifyFixtureSourceError {
            checks.append(error.check)
            return makeEvidence(runID: runID, generatedAt: generatedAt, checks: checks, runtimeFacts: runtimeFacts, artifacts: artifacts)
        } catch {
            checks.append(.fail(
                .fixtureSourceCreated,
                phase: .fixture,
                reason: "Fixture source creation failed: \(sanitize(error))."
            ))
            return makeEvidence(runID: runID, generatedAt: generatedAt, checks: checks, runtimeFacts: runtimeFacts, artifacts: artifacts)
        }

        let databaseURL = runDirectory.appendingPathComponent("app-verify.sqlite")
        let database: SoundingDatabase
        do {
            database = try databaseFactory(databaseURL)
            checks.append(.pass(
                .databaseOpened,
                phase: .database,
                reason: "Opened temporary SoundingDatabase.",
                artifacts: [AppVerifyRedactedArtifact(kind: "database", path: databaseURL.path)]
            ))
        } catch {
            checks.append(.fail(
                .databaseOpened,
                phase: .database,
                reason: "Temporary SoundingDatabase open failed: \(sanitize(error)).",
                artifacts: [AppVerifyRedactedArtifact(kind: "database", path: databaseURL.path)]
            ))
            return makeEvidence(runID: runID, generatedAt: generatedAt, checks: checks, runtimeFacts: runtimeFacts, artifacts: artifacts)
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
            checks.append(.pass(
                .streamRegistered,
                phase: .registration,
                reason: "Registered generated fixture as an icecast stream.",
                artifacts: [AppVerifyRedactedArtifact(kind: "stream-source", path: stream.sourceDescription)]
            ))
        } catch {
            checks.append(.fail(
                .streamRegistered,
                phase: .registration,
                reason: "Stream registration failed: \(sanitize(error))."
            ))
            return makeEvidence(runID: runID, generatedAt: generatedAt, checks: checks, runtimeFacts: runtimeFacts, artifacts: artifacts)
        }

        let diagnostics = AppRuntimeDiagnosticsLog(
            eventLogURL: runDirectory.appendingPathComponent("runtime-events.jsonl"),
            failureLogURL: runDirectory.appendingPathComponent("runtime-errors.jsonl"),
            now: configuration.timestamp
        )
        let volumeStore = AppPlaybackVolumeStore()
        let timeline = AppPlayerTimelineClock()
        let rollingBuffer = RollingPCMBuffer(configuration: RollingBufferConfiguration(targetDurationSeconds: 30))
        let player = playerFactory(volumeStore, diagnostics)
        let ingester = ingesterFactory(
            database,
            decoderFactory(),
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
        let runtime = runtimeFactory(registry, ingester, timeline, rollingBuffer, nil, volumeStore, player, diagnostics)

        diagnostics.recordEvent(
            "appverify.run.starting",
            streamID: stream.id,
            streamName: stream.name,
            sourceDescription: stream.sourceDescription,
            phase: "appverify.start",
            fields: ["runID": runID]
        )

        let events = await runtime.events()
        var timeoutPhase: AppVerifyRuntimePhase?
        let terminal: AppVerifyCollectedRuntime
        do {
            try await runtime.start(streamID: stream.id)
            terminal = try await collectTerminalEvent(
                from: events,
                timeoutSeconds: configuration.timeoutSeconds
            )
        } catch let error as AppVerifyRunnerTimeoutError {
            timeoutPhase = .runtimeStop
            await runtime.stopAll()
            await player.stop(timeline: timeline)
            let diagnosticsSnapshot = diagnosticsSnapshot(for: diagnostics)
            runtimeFacts = AppVerifyRuntimeFacts(
                phase: .runtimeStop,
                diagnosticCount: diagnosticsSnapshot.eventNames.count + diagnosticsSnapshot.errorNames.count,
                recentDiagnosticEvents: diagnosticsSnapshot.recentNames
            )
            checks.append(.pass(.runtimeStarted, phase: .runtimeStart, reason: "Runtime start was requested before timeout."))
            checks.append(.fail(
                .runtimeStopped,
                phase: .runtimeStop,
                reason: "Runtime timed out while waiting for terminal event: \(sanitize(error)).",
                facts: runtimeFacts,
                artifacts: diagnosticsArtifacts(diagnostics)
            ))
            checks.append(diagnosticsCheck(snapshot: diagnosticsSnapshot, artifacts: diagnosticsArtifacts(diagnostics)))
            return makeEvidence(
                runID: runID,
                generatedAt: generatedAt,
                checks: checks,
                runtimeFacts: runtimeFacts,
                artifacts: artifacts + diagnosticsArtifacts(diagnostics),
                metadata: ["timeoutPhase": timeoutPhase?.rawValue ?? "runtime_stop"]
            )
        } catch {
            await runtime.stopAll()
            await player.stop(timeline: timeline)
            let diagnosticsSnapshot = diagnosticsSnapshot(for: diagnostics)
            runtimeFacts = AppVerifyRuntimeFacts(
                phase: .runtimeStart,
                diagnosticCount: diagnosticsSnapshot.eventNames.count + diagnosticsSnapshot.errorNames.count,
                recentDiagnosticEvents: diagnosticsSnapshot.recentNames
            )
            checks.append(.fail(
                .runtimeStarted,
                phase: .runtimeStart,
                reason: "Runtime start or event collection failed: \(sanitize(error)).",
                facts: runtimeFacts,
                artifacts: diagnosticsArtifacts(diagnostics)
            ))
            checks.append(diagnosticsCheck(snapshot: diagnosticsSnapshot, artifacts: diagnosticsArtifacts(diagnostics)))
            return makeEvidence(
                runID: runID,
                generatedAt: generatedAt,
                checks: checks,
                runtimeFacts: runtimeFacts,
                artifacts: artifacts + diagnosticsArtifacts(diagnostics)
            )
        }

        await runtime.stopAll()
        await player.stop(timeline: timeline)

        let diagnosticsSnapshot = diagnosticsSnapshot(for: diagnostics)
        let result = terminal.terminalEvent.result
        let eventPhases = terminal.events.map(\.phase.statusPhase.rawValue)
        let playerTimeline = result?.playerTimeline
        let decodedFrameCount = playerTimeline?.decodedFrameCount ?? 0
        let scheduledBuffers = scheduledBufferCount(from: playerTimeline)
        runtimeFacts = AppVerifyRuntimeFacts(
            phase: terminal.terminalEvent.phase.statusPhase == .error ? .runtimeStop : .diagnostics,
            processedChunks: result?.processedChunks ?? 0,
            decodedChunks: decodedFrameCount,
            scheduledBuffers: scheduledBuffers,
            diagnosticCount: diagnosticsSnapshot.eventNames.count + diagnosticsSnapshot.errorNames.count,
            recentDiagnosticEvents: diagnosticsSnapshot.recentNames,
            timelineSnapshotFields: timelineFields(playerTimeline)
        )

        checks.append(runtimeStartedCheck(events: terminal.events, facts: runtimeFacts))
        checks.append(AppVerifyCheckEvaluator.decodeCompleted(
            processedChunks: result?.processedChunks ?? 0,
            decodedChunks: decodedFrameCount,
            diagnosticEvents: diagnosticsSnapshot.recentNames
        ))
        checks.append(playbackCheck(
            scheduledBuffers: scheduledBuffers,
            diagnostics: diagnosticsSnapshot,
            facts: runtimeFacts
        ))
        checks.append(runtimeStoppedCheck(terminal: terminal.terminalEvent, facts: runtimeFacts))
        checks.append(diagnosticsCheck(snapshot: diagnosticsSnapshot, artifacts: diagnosticsArtifacts(diagnostics)))

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

    public static func defaultRunDirectory(configuration: Configuration) throws -> (runID: String, directory: URL) {
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

    private func diagnosticsArtifacts(_ diagnostics: AppRuntimeDiagnosticsLog) -> [AppVerifyRedactedArtifact] {
        [
            AppVerifyRedactedArtifact(kind: "runtime-events", path: diagnostics.eventLogURL.path),
            AppVerifyRedactedArtifact(kind: "runtime-errors", path: diagnostics.failureLogURL.path),
        ]
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

    private func runtimeStartedCheck(events: [AppStreamRuntimeEvent], facts: AppVerifyRuntimeFacts) -> AppVerifyCheckRecord {
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

    private func runtimeStoppedCheck(terminal: AppStreamRuntimeEvent, facts: AppVerifyRuntimeFacts) -> AppVerifyCheckRecord {
        switch terminal.phase {
        case .stopped:
            guard terminal.result != nil else {
                return .fail(
                    .runtimeStopped,
                    phase: .runtimeStop,
                    reason: "Runtime stopped without a terminal AppStreamRuntimeResult.",
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
                reason: "Playback proof requires a player timeline with at least one decoded/scheduled buffer.",
                facts: facts
            )
        }
        guard hasPrepare, hasScheduledEvent else {
            return .fail(
                .avfoundationPlaybackScheduled,
                phase: .playback,
                reason: "Playback proof is missing required AVFoundation diagnostic events: prepare=\(hasPrepare), scheduled=\(hasScheduledEvent).",
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
                reason: "Diagnostics log contained \(snapshot.malformedLineCount) malformed JSONL entr\(snapshot.malformedLineCount == 1 ? "y" : "ies").",
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

    private func diagnosticsSnapshot(for diagnostics: AppRuntimeDiagnosticsLog) -> AppVerifyDiagnosticsSnapshot {
        let events = parseDiagnostics(at: diagnostics.eventLogURL)
        let errors = parseDiagnostics(at: diagnostics.failureLogURL)
        return AppVerifyDiagnosticsSnapshot(
            eventFileExists: FileManager.default.fileExists(atPath: diagnostics.eventLogURL.path),
            errorFileExists: FileManager.default.fileExists(atPath: diagnostics.failureLogURL.path),
            eventNames: events.names,
            errorNames: errors.names,
            malformedLineCount: events.malformedLineCount + errors.malformedLineCount
        )
    }

    private func parseDiagnostics(at url: URL) -> (names: [String], malformedLineCount: Int) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], 0) }
        let text = String(decoding: data, as: UTF8.self)
        var names: [String] = []
        var malformed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8) else {
                malformed += 1
                continue
            }
            do {
                let entry = try JSONDecoder().decode(AppVerifyDiagnosticEntry.self, from: lineData)
                names.append(AppVerifyEvidenceSanitizer.redact(entry.event))
            } catch {
                malformed += 1
            }
        }
        return (Array(names.suffix(64)), malformed)
    }

    private func scheduledBufferCount(from timeline: AppPlayerTimelineSnapshot?) -> Int {
        timeline?.decodedFrameCount ?? 0
    }

    private func timelineFields(_ timeline: AppPlayerTimelineSnapshot?) -> [String: String] {
        guard let timeline else { return [:] }
        let state: String
        switch timeline.state {
        case .idle: state = "idle"
        case .buffering: state = "buffering"
        case .playing: state = "playing"
        case .paused: state = "paused"
        case .stopped: state = "stopped"
        case .failed(let message): state = "failed: \(message)"
        }
        return [
            "streamID": timeline.streamID.map(String.init) ?? "nil",
            "state": state,
            "positionSeconds": String(format: "%.3f", timeline.positionSeconds),
            "liveEdgeSeconds": String(format: "%.3f", timeline.liveEdgeSeconds),
            "bufferedStartSeconds": timeline.bufferedStartSeconds.map { String(format: "%.3f", $0) } ?? "nil",
            "bufferedEndSeconds": timeline.bufferedEndSeconds.map { String(format: "%.3f", $0) } ?? "nil",
            "driftSeconds": String(format: "%.3f", timeline.driftSeconds),
            "decodedFrameCount": String(timeline.decodedFrameCount),
            "lastMessage": timeline.lastMessage,
        ]
    }

    private func sanitize(_ error: any Error) -> String {
        AppVerifyEvidenceSanitizer.redact(String(describing: error))
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

private struct AppVerifyDiagnosticsSnapshot: Sendable {
    var eventFileExists: Bool
    var errorFileExists: Bool
    var eventNames: [String]
    var errorNames: [String]
    var malformedLineCount: Int

    var recentNames: [String] {
        Array((eventNames + errorNames).suffix(32))
    }
}

private struct AppVerifyDiagnosticEntry: Decodable {
    var event: String
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
                words: []
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
