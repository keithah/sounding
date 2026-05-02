import Foundation
import GRDB

public struct AppVerifyLiveStreamExecutionRequest: Sendable {
    public var runID: String
    public var runDirectory: URL
    public var streamDirectory: URL
    public var stream: AppVerifyLiveStreamSpec
    public var diagnosticsLogURL: URL
    public var generatedAt: String

    public init(
        runID: String,
        runDirectory: URL,
        streamDirectory: URL,
        stream: AppVerifyLiveStreamSpec,
        diagnosticsLogURL: URL,
        generatedAt: String
    ) {
        self.runID = runID
        self.runDirectory = runDirectory
        self.streamDirectory = streamDirectory
        self.stream = stream
        self.diagnosticsLogURL = diagnosticsLogURL
        self.generatedAt = generatedAt
    }
}

public struct AppVerifyLiveStreamStopRequest: Sendable {
    public var runID: String
    public var runDirectory: URL
    public var streamDirectory: URL
    public var stream: AppVerifyLiveStreamSpec
    public var diagnosticsLogURL: URL
    public var registeredStreamID: Int64?

    public init(
        runID: String,
        runDirectory: URL,
        streamDirectory: URL,
        stream: AppVerifyLiveStreamSpec,
        diagnosticsLogURL: URL,
        registeredStreamID: Int64? = nil
    ) {
        self.runID = runID
        self.runDirectory = runDirectory
        self.streamDirectory = streamDirectory
        self.stream = stream
        self.diagnosticsLogURL = diagnosticsLogURL
        self.registeredStreamID = registeredStreamID
    }
}

public struct AppVerifyLiveStreamExecutionResult: Sendable, Equatable {
    public var registeredStreamID: Int64?
    public var runtimeStarted: Bool
    public var processedChunks: Int
    public var decodedChunks: Int
    public var scheduledBuffers: Int
    public var transcriptCount: Int
    public var metadataCount: Int
    public var diagnosticEvents: [String]
    public var diagnosticsFileWritten: Bool
    public var artifacts: [AppVerifyRedactedArtifact]
    public var fields: [String: String]

    public init(
        registeredStreamID: Int64? = nil,
        runtimeStarted: Bool = true,
        processedChunks: Int = 0,
        decodedChunks: Int = 0,
        scheduledBuffers: Int = 0,
        transcriptCount: Int = 0,
        metadataCount: Int = 0,
        diagnosticEvents: [String] = [],
        diagnosticsFileWritten: Bool = false,
        artifacts: [AppVerifyRedactedArtifact] = [],
        fields: [String: String] = [:]
    ) {
        self.registeredStreamID = registeredStreamID
        self.runtimeStarted = runtimeStarted
        self.processedChunks = max(0, processedChunks)
        self.decodedChunks = max(0, decodedChunks)
        self.scheduledBuffers = max(0, scheduledBuffers)
        self.transcriptCount = max(0, transcriptCount)
        self.metadataCount = max(0, metadataCount)
        self.diagnosticEvents = Array(diagnosticEvents.prefix(32)).map(AppVerifyEvidenceSanitizer.redact)
        self.diagnosticsFileWritten = diagnosticsFileWritten
        self.artifacts = Array(artifacts.prefix(16))
        self.fields = fields.prefix(16).reduce(into: [:]) { partial, pair in
            partial[AppVerifyEvidenceSanitizer.redact(pair.key)] = AppVerifyEvidenceSanitizer.redact(pair.value)
        }
    }
}

public protocol AppVerifyLiveStreamExecuting: Sendable {
    func execute(_ request: AppVerifyLiveStreamExecutionRequest) async throws -> AppVerifyLiveStreamExecutionResult
    func stop(_ request: AppVerifyLiveStreamStopRequest) async throws
}

public struct AppVerifyLiveRunner: Sendable {
    public struct Configuration: Sendable {
        public var liveConfiguration: AppVerifyLiveConfiguration
        public var runRootDirectory: URL
        public var configPath: String?
        public var timestamp: @Sendable () -> String
        public var makeRunID: @Sendable () -> String

        public init(
            liveConfiguration: AppVerifyLiveConfiguration,
            runRootDirectory: URL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SoundingAppVerifyLive", isDirectory: true),
            configPath: String? = nil,
            timestamp: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) },
            makeRunID: @escaping @Sendable () -> String = { UUID().uuidString }
        ) {
            self.liveConfiguration = liveConfiguration
            self.runRootDirectory = runRootDirectory
            self.configPath = configPath
            self.timestamp = timestamp
            self.makeRunID = makeRunID
        }
    }

    public typealias RunDirectoryFactory = @Sendable (_ configuration: Configuration) throws -> (runID: String, directory: URL)

    private let configuration: Configuration
    private let runDirectoryFactory: RunDirectoryFactory
    private let streamExecutor: any AppVerifyLiveStreamExecuting

    public init(
        configuration: Configuration,
        runDirectoryFactory: @escaping RunDirectoryFactory = { configuration in
            try AppVerifyLiveRunner.defaultRunDirectory(configuration: configuration)
        },
        streamExecutor: any AppVerifyLiveStreamExecuting = AppVerifyAVFoundationLiveStreamExecutor()
    ) {
        self.configuration = configuration
        self.runDirectoryFactory = runDirectoryFactory
        self.streamExecutor = streamExecutor
    }

    public func run() async -> AppVerifyEvidence {
        let generatedAt = configuration.timestamp()
        let preparedRun: (runID: String, directory: URL)
        do {
            preparedRun = try runDirectoryFactory(configuration)
        } catch {
            let check = AppVerifyCheckRecord.fail(
                .liveConfigValidated,
                phase: .liveConfig,
                reason: "Live app-verify run directory creation failed: \(sanitize(error))."
            )
            return AppVerifyEvidence(generatedAt: generatedAt, runID: "unavailable", checks: [check])
        }

        let runID = preparedRun.runID
        let runDirectory = preparedRun.directory
        var checks: [AppVerifyCheckRecord] = [
            .pass(
                .liveConfigValidated,
                phase: .liveConfig,
                reason: "Validated live app-verify configuration for \(configuration.liveConfiguration.streams.count) sequential stream(s).",
                artifacts: baseArtifacts(runDirectory: runDirectory)
            )
        ]
        var artifacts = baseArtifacts(runDirectory: runDirectory)
        if let configPath = configuration.configPath {
            artifacts.append(AppVerifyRedactedArtifact(kind: "live-config", path: configPath))
        }

        for (index, stream) in configuration.liveConfiguration.streams.enumerated() {
            let streamDirectory = runDirectory.appendingPathComponent("stream-\(index)-\(safeFileComponent(stream.id))", isDirectory: true)
            let diagnosticsLogURL = streamDirectory.appendingPathComponent("live-diagnostics.jsonl")
            let diagnosticsArtifact = AppVerifyRedactedArtifact(kind: "live-diagnostics", path: diagnosticsLogURL.path)
            artifacts.append(diagnosticsArtifact)

            do {
                try FileManager.default.createDirectory(at: streamDirectory, withIntermediateDirectories: true)
            } catch {
                let facts = liveFacts(stream: stream, diagnosticsEvents: [], fields: ["streamIndex": String(index)])
                checks.append(statusRecord(
                    .liveRegistration,
                    name: .liveStreamRegistered,
                    stream: stream,
                    success: false,
                    reason: "Live stream artifact directory creation failed: \(sanitize(error)).",
                    facts: facts,
                    artifacts: [diagnosticsArtifact]
                ))
                continue
            }

            let request = AppVerifyLiveStreamExecutionRequest(
                runID: runID,
                runDirectory: runDirectory,
                streamDirectory: streamDirectory,
                stream: stream,
                diagnosticsLogURL: diagnosticsLogURL,
                generatedAt: generatedAt
            )

            var result: AppVerifyLiveStreamExecutionResult?
            var executionError: (any Error)?
            do {
                result = try await executeWithTimeout(request)
            } catch {
                executionError = error
            }

            let registeredStreamID = result?.registeredStreamID
            var cleanupError: (any Error)?
            do {
                try await streamExecutor.stop(AppVerifyLiveStreamStopRequest(
                    runID: runID,
                    runDirectory: runDirectory,
                    streamDirectory: streamDirectory,
                    stream: stream,
                    diagnosticsLogURL: diagnosticsLogURL,
                    registeredStreamID: registeredStreamID
                ))
            } catch {
                cleanupError = error
            }

            let streamArtifacts = Array(([diagnosticsArtifact] + (result?.artifacts ?? [])).prefix(16))
            let fields = liveFields(index: index, diagnosticsLogURL: diagnosticsLogURL, result: result)
            let facts = liveFacts(stream: stream, result: result, fields: fields)

            if let executionError {
                checks.append(contentsOf: failureChecks(
                    stream: stream,
                    error: executionError,
                    facts: facts,
                    artifacts: streamArtifacts
                ))
            } else if let result {
                checks.append(contentsOf: successChecks(
                    stream: stream,
                    result: result,
                    facts: facts,
                    artifacts: streamArtifacts
                ))
            }

            if let cleanupError {
                checks.append(statusRecord(
                    .liveStop,
                    name: .liveRuntimeStopped,
                    stream: stream,
                    success: false,
                    reason: "Live stream cleanup failed: \(sanitize(cleanupError)).",
                    facts: facts,
                    artifacts: streamArtifacts
                ))
            } else {
                checks.append(.pass(
                    .liveRuntimeStopped,
                    phase: .liveStop,
                    required: stream.required,
                    reason: "Live stream cleanup completed for stream \(AppVerifyEvidenceSanitizer.redact(stream.id)).",
                    liveFacts: facts,
                    artifacts: streamArtifacts
                ))
            }

            let diagnosticsExists = result?.diagnosticsFileWritten == true
                || FileManager.default.fileExists(atPath: diagnosticsLogURL.path)
            checks.append(statusRecord(
                .liveDiagnostics,
                name: .liveDiagnosticsWritten,
                stream: stream,
                success: diagnosticsExists,
                reason: diagnosticsExists
                    ? "Live stream diagnostics artifact written."
                    : "Diagnostics artifact was not written for stream \(AppVerifyEvidenceSanitizer.redact(stream.id)).",
                facts: facts,
                artifacts: streamArtifacts
            ))

            checks.append(AppVerifyCheckEvaluator.liveTranscriptExpectation(
                observedCount: result?.transcriptCount ?? 0,
                expectation: stream.expectations.transcript,
                required: stream.required,
                streamID: stream.id,
                source: stream.source,
                facts: facts
            ))
            checks.append(AppVerifyCheckEvaluator.liveMetadataExpectation(
                observedCount: result?.metadataCount ?? 0,
                expectation: stream.expectations.metadata,
                required: stream.required,
                streamID: stream.id,
                source: stream.source,
                facts: facts
            ))
        }

        return AppVerifyEvidence(
            generatedAt: generatedAt,
            runID: runID,
            checks: checks,
            runtimeFacts: aggregateRuntimeFacts(checks),
            artifacts: artifacts,
            metadata: metadata(runDirectory: runDirectory)
        )
    }

    public static func defaultRunDirectory(configuration: Configuration) throws -> (runID: String, directory: URL) {
        let runID = configuration.makeRunID()
        let directory = configuration.runRootDirectory
            .appendingPathComponent("app-verify-live-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (runID, directory)
    }

    private func executeWithTimeout(_ request: AppVerifyLiveStreamExecutionRequest) async throws -> AppVerifyLiveStreamExecutionResult {
        try await withThrowingTaskGroup(of: AppVerifyLiveStreamExecutionResult.self) { group in
            group.addTask { try await streamExecutor.execute(request) }
            group.addTask {
                let nanoseconds = UInt64((request.stream.timeoutSeconds * 1_000_000_000).rounded())
                try await Task.sleep(nanoseconds: nanoseconds)
                throw AppVerifyLiveRunnerTimeoutError(streamID: request.stream.id, timeoutSeconds: request.stream.timeoutSeconds)
            }
            guard let first = try await group.next() else {
                throw AppVerifyLiveRunnerTimeoutError(streamID: request.stream.id, timeoutSeconds: request.stream.timeoutSeconds)
            }
            group.cancelAll()
            return first
        }
    }

    private func successChecks(
        stream: AppVerifyLiveStreamSpec,
        result: AppVerifyLiveStreamExecutionResult,
        facts: AppVerifyLiveStreamFacts,
        artifacts: [AppVerifyRedactedArtifact]
    ) -> [AppVerifyCheckRecord] {
        [
            statusRecord(
                .liveRegistration,
                name: .liveStreamRegistered,
                stream: stream,
                success: result.registeredStreamID != nil,
                reason: result.registeredStreamID == nil ? "Live stream was not registered." : "Live stream registered through app runtime boundary.",
                facts: facts,
                artifacts: artifacts
            ),
            statusRecord(
                .liveRuntimeStart,
                name: .liveRuntimeStarted,
                stream: stream,
                success: result.runtimeStarted,
                reason: result.runtimeStarted ? "Live stream runtime started." : "Live stream runtime did not report a started state.",
                facts: facts,
                artifacts: artifacts
            ),
            statusRecord(
                .liveDecode,
                name: .liveDecodeOpened,
                stream: stream,
                success: result.processedChunks > 0 && result.decodedChunks > 0,
                reason: result.processedChunks > 0 && result.decodedChunks > 0
                    ? "Live stream decode/open observed non-zero chunk counters."
                    : "Live decode/open proof requires processedChunks and decodedChunks greater than zero.",
                facts: facts,
                artifacts: artifacts
            ),
            statusRecord(
                .livePlayback,
                name: .livePlaybackScheduled,
                stream: stream,
                success: result.scheduledBuffers > 0,
                reason: result.scheduledBuffers > 0
                    ? "Live stream scheduled playback buffers."
                    : "Live playback proof requires at least one scheduled buffer.",
                facts: facts,
                artifacts: artifacts
            ),
        ]
    }

    private func failureChecks(
        stream: AppVerifyLiveStreamSpec,
        error: any Error,
        facts: AppVerifyLiveStreamFacts,
        artifacts: [AppVerifyRedactedArtifact]
    ) -> [AppVerifyCheckRecord] {
        let reason = "Live stream execution failed: \(sanitize(error))."
        return [
            statusRecord(.liveRegistration, name: .liveStreamRegistered, stream: stream, success: false, reason: reason, facts: facts, artifacts: artifacts),
            statusRecord(.liveRuntimeStart, name: .liveRuntimeStarted, stream: stream, success: false, reason: reason, facts: facts, artifacts: artifacts),
            statusRecord(.liveDecode, name: .liveDecodeOpened, stream: stream, success: false, reason: reason, facts: facts, artifacts: artifacts),
            statusRecord(.livePlayback, name: .livePlaybackScheduled, stream: stream, success: false, reason: reason, facts: facts, artifacts: artifacts),
        ]
    }

    private func statusRecord(
        _ phase: AppVerifyRuntimePhase,
        name: AppVerifyCheckName,
        stream: AppVerifyLiveStreamSpec,
        success: Bool,
        reason: String,
        facts: AppVerifyLiveStreamFacts,
        artifacts: [AppVerifyRedactedArtifact]
    ) -> AppVerifyCheckRecord {
        if success {
            return .pass(name, phase: phase, required: stream.required, reason: reason, liveFacts: facts, artifacts: artifacts)
        }
        if stream.required {
            return .fail(name, phase: phase, required: true, reason: reason, liveFacts: facts, artifacts: artifacts)
        }
        return .warn(name, phase: phase, required: false, reason: reason, liveFacts: facts, artifacts: artifacts)
    }

    private func liveFacts(
        stream: AppVerifyLiveStreamSpec,
        result: AppVerifyLiveStreamExecutionResult? = nil,
        diagnosticsEvents: [String]? = nil,
        fields: [String: String] = [:]
    ) -> AppVerifyLiveStreamFacts {
        AppVerifyLiveStreamFacts(
            streamID: stream.id,
            streamType: stream.streamType,
            resolvedStreamType: stream.resolvedStreamType,
            source: stream.source,
            timeoutSeconds: stream.timeoutSeconds,
            maxChunks: stream.maxChunks,
            required: stream.required,
            transcriptExpectation: stream.expectations.transcript,
            metadataExpectation: stream.expectations.metadata,
            registeredStreamID: result?.registeredStreamID,
            processedChunks: result?.processedChunks ?? 0,
            decodedChunks: result?.decodedChunks ?? 0,
            scheduledBuffers: result?.scheduledBuffers ?? 0,
            transcriptCount: result?.transcriptCount ?? 0,
            metadataCount: result?.metadataCount ?? 0,
            diagnosticCount: result?.diagnosticEvents.count ?? diagnosticsEvents?.count ?? 0,
            recentDiagnosticEvents: result?.diagnosticEvents ?? diagnosticsEvents ?? [],
            fields: fields
        )
    }

    private func liveFields(
        index: Int,
        diagnosticsLogURL: URL,
        result: AppVerifyLiveStreamExecutionResult?
    ) -> [String: String] {
        var fields = result?.fields ?? [:]
        fields["streamIndex"] = String(index)
        fields["diagnosticsPath"] = diagnosticsLogURL.path
        if let configPath = configuration.configPath {
            fields["configPath"] = configPath
        }
        return fields
    }

    private func aggregateRuntimeFacts(_ checks: [AppVerifyCheckRecord]) -> AppVerifyRuntimeFacts {
        let liveFacts = checks.compactMap(\.liveFacts)
        return AppVerifyRuntimeFacts(
            phase: .liveDiagnostics,
            processedChunks: liveFacts.reduce(0) { $0 + $1.processedChunks },
            decodedChunks: liveFacts.reduce(0) { $0 + $1.decodedChunks },
            scheduledBuffers: liveFacts.reduce(0) { $0 + $1.scheduledBuffers },
            diagnosticCount: liveFacts.reduce(0) { $0 + $1.diagnosticCount },
            recentDiagnosticEvents: Array(liveFacts.flatMap(\.recentDiagnosticEvents).suffix(32)),
            timelineSnapshotFields: ["streamCount": String(configuration.liveConfiguration.streams.count)]
        )
    }

    private func metadata(runDirectory: URL) -> [String: String] {
        var metadata: [String: String] = [
            "mode": "live",
            "streamCount": String(configuration.liveConfiguration.streams.count),
            "runDirectory": AppVerifyEvidenceSanitizer.artifactPath(runDirectory.path),
        ]
        if let configPath = configuration.configPath {
            metadata["config"] = AppVerifyEvidenceSanitizer.artifactPath(configPath)
        }
        return metadata
    }

    private func baseArtifacts(runDirectory: URL) -> [AppVerifyRedactedArtifact] {
        [AppVerifyRedactedArtifact(kind: "live-run-directory", path: runDirectory.path)]
    }

    private func sanitize(_ error: any Error) -> String {
        AppVerifyEvidenceSanitizer.redact(String(describing: error))
    }

    private func safeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let candidate = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return candidate.isEmpty ? "stream" : String(candidate.prefix(48))
    }
}

public struct AppVerifyAVFoundationLiveStreamExecutor: AppVerifyLiveStreamExecuting {
    public typealias DatabaseFactory = @Sendable (_ databaseURL: URL) throws -> SoundingDatabase
    public typealias DecoderFactory = @Sendable () -> any AudioDecoding
    public typealias PlayerFactory = @Sendable (_ volumeStore: AppPlaybackVolumeStore, _ diagnosticsLog: AppRuntimeDiagnosticsLog) -> any AppPCMPlaybackAdapting
    public typealias RuntimeFactory = @Sendable (
        _ registry: StreamRegistry,
        _ ingester: any AppStreamRuntimeIngesting,
        _ timeline: AppPlayerTimelineClock,
        _ rollingBuffer: RollingPCMBuffer,
        _ volumeStore: AppPlaybackVolumeStore,
        _ player: any AppPCMPlaybackAdapting,
        _ diagnosticsLog: AppRuntimeDiagnosticsLog
    ) -> any AppStreamRuntimeControlling
    public typealias IngesterFactory = @Sendable (
        _ database: SoundingDatabase,
        _ decoder: any AudioDecoding,
        _ transcriber: any MLTranscription,
        _ diarizer: any SpeakerDiarization,
        _ player: any AppPCMPlaybackAdapting,
        _ timeline: AppPlayerTimelineClock,
        _ rollingBuffer: RollingPCMBuffer,
        _ diagnosticsLog: AppRuntimeDiagnosticsLog,
        _ now: @escaping StreamIngestPipeline.TimestampProvider
    ) -> any AppStreamRuntimeIngesting

    public struct FactoryConfiguration: Equatable, Sendable {
        public var database: String
        public var registry: String
        public var runtime: String
        public var decoder: String
        public var player: String
        public var rollingBuffer: String

        public init(
            database: String = "SoundingDatabase",
            registry: String = "StreamRegistry",
            runtime: String = "StreamIngestAppRuntimeRunner/AppStreamRuntimeService",
            decoder: String = "AVFoundationAudioDecoder",
            player: String = "AVFoundationAppPCMPlayerAdapter",
            rollingBuffer: String = "RollingPCMBuffer"
        ) {
            self.database = database
            self.registry = registry
            self.runtime = runtime
            self.decoder = decoder
            self.player = player
            self.rollingBuffer = rollingBuffer
        }
    }

    public var factoryConfiguration: FactoryConfiguration

    private let databaseFactory: DatabaseFactory
    private let decoderFactory: DecoderFactory
    private let playerFactory: PlayerFactory
    private let runtimeFactory: RuntimeFactory
    private let ingesterFactory: IngesterFactory
    private let activeRuns: AppVerifyLiveActiveRuntimeStore

    public init(
        factoryConfiguration: FactoryConfiguration = FactoryConfiguration(),
        databaseFactory: @escaping DatabaseFactory = { url in try SoundingDatabase(fileURL: url) },
        decoderFactory: @escaping DecoderFactory = { AVFoundationAudioDecoder(chunkDurationSeconds: 0.25) },
        playerFactory: @escaping PlayerFactory = { volumeStore, diagnosticsLog in
            AVFoundationAppPCMPlayerAdapter(volumeStore: volumeStore, diagnosticsLog: diagnosticsLog)
        },
        runtimeFactory: @escaping RuntimeFactory = { registry, ingester, timeline, rollingBuffer, volumeStore, player, diagnosticsLog in
            AppStreamRuntimeService(
                registry: registry,
                ingester: ingester,
                retryPolicy: .noRetry,
                volumeStore: volumeStore,
                playbackTimeline: timeline,
                rollingBuffer: rollingBuffer,
                playbackController: player,
                diagnosticsLog: diagnosticsLog
            )
        },
        ingesterFactory: @escaping IngesterFactory = { database, decoder, transcriber, diarizer, player, timeline, rollingBuffer, diagnosticsLog, now in
            StreamIngestAppRuntimeRunner(
                database: database,
                decoder: decoder,
                transcriber: transcriber,
                diarizer: diarizer,
                player: player,
                timeline: timeline,
                rollingBuffer: rollingBuffer,
                diagnosticsLog: diagnosticsLog,
                keepPlaybackRunningAfterIngestCompletes: true,
                now: now
            )
        },
        activeRuns: AppVerifyLiveActiveRuntimeStore = AppVerifyLiveActiveRuntimeStore()
    ) {
        self.factoryConfiguration = factoryConfiguration
        self.databaseFactory = databaseFactory
        self.decoderFactory = decoderFactory
        self.playerFactory = playerFactory
        self.runtimeFactory = runtimeFactory
        self.ingesterFactory = ingesterFactory
        self.activeRuns = activeRuns
    }

    public func execute(_ request: AppVerifyLiveStreamExecutionRequest) async throws -> AppVerifyLiveStreamExecutionResult {
        let resolvedType = request.stream.resolvedStreamType
        guard Self.appRuntimeSupportedTypes.contains(resolvedType) else {
            throw AppVerifyLiveExecutionError.unsupportedResolvedStreamType(resolvedType.rawValue)
        }

        let databaseURL = request.streamDirectory.appendingPathComponent("live-runtime.sqlite")
        let database: SoundingDatabase
        do {
            database = try databaseFactory(databaseURL)
        } catch {
            throw AppVerifyLiveExecutionError.databaseOpenFailed(String(describing: error))
        }

        let registry = StreamRegistry(database: database)
        let streamRecord: StreamRecord
        do {
            streamRecord = try registry.add(
                name: "App Verify Live \(request.runID) \(request.stream.id)",
                streamType: resolvedType.rawValue,
                source: request.stream.source,
                createdAt: request.generatedAt
            )
        } catch {
            throw AppVerifyLiveExecutionError.streamRegistrationFailed(String(describing: error))
        }

        let diagnostics = AppRuntimeDiagnosticsLog(
            eventLogURL: request.streamDirectory.appendingPathComponent("runtime-events.jsonl"),
            failureLogURL: request.streamDirectory.appendingPathComponent("runtime-errors.jsonl"),
            now: { request.generatedAt }
        )
        let volumeStore = AppPlaybackVolumeStore()
        let timeline = AppPlayerTimelineClock()
        let rollingBuffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: max(1, request.stream.timeoutSeconds),
                hotMemoryDurationSeconds: max(1, min(request.stream.timeoutSeconds, 30)),
                maximumSpillBytes: 8 * 1024 * 1024,
                spillSegmentDurationSeconds: max(1, min(request.stream.timeoutSeconds, 30)),
                spillDirectory: request.streamDirectory.appendingPathComponent("rolling-buffer", isDirectory: true)
            )
        )
        let player = playerFactory(volumeStore, diagnostics)
        let ingester = ingesterFactory(
            database,
            decoderFactory(),
            AppVerifyLiveNoOpTranscriber(),
            AppVerifyLiveNoOpDiarizer(),
            player,
            timeline,
            rollingBuffer,
            diagnostics,
            { request.generatedAt }
        )
        let runtime = runtimeFactory(registry, ingester, timeline, rollingBuffer, volumeStore, player, diagnostics)
        let handle = AppVerifyLiveRuntimeHandle(
            runtime: runtime,
            player: player,
            timeline: timeline,
            rollingBuffer: rollingBuffer,
            diagnostics: diagnostics,
            database: database,
            streamID: streamRecord.id
        )
        await activeRuns.insert(handle, for: request)

        diagnostics.recordEvent(
            "appverify.live.run.starting",
            streamID: streamRecord.id,
            streamName: streamRecord.name,
            sourceDescription: streamRecord.sourceDescription,
            phase: "live.runtime.start",
            fields: [
                "runID": request.runID,
                "resolvedStreamType": resolvedType.rawValue,
                "sourceClass": sourceClass(for: request.stream.source),
                "maxChunks": String(request.stream.maxChunks),
            ]
        )

        let events = await runtime.events()
        let recorder = AppVerifyLiveRuntimeEventRecorder()
        let eventTask = Task {
            for await event in events {
                await recorder.append(event)
            }
        }
        defer { eventTask.cancel() }

        do {
            try await runtime.start(streamID: streamRecord.id)
        } catch {
            throw AppVerifyLiveExecutionError.runtimeStartFailed(String(describing: error))
        }

        do {
            try await waitForRuntimePhase(.connecting, in: recorder, streamID: streamRecord.id, timeoutSeconds: request.stream.timeoutSeconds)
            try await waitForRuntimePhase(.running, in: recorder, streamID: streamRecord.id, timeoutSeconds: request.stream.timeoutSeconds)
            try await waitForDiagnosticEvent("playback.play.scheduled", in: diagnostics, timeoutSeconds: request.stream.timeoutSeconds)
        } catch {
            throw AppVerifyLiveExecutionError.runtimeProofTimeout(String(describing: error))
        }

        let diagnosticsSnapshot = self.diagnosticsSnapshot(for: diagnostics)
        let timelineSnapshot = await timeline.snapshot()
        let counts = (try? liveObservationCounts(database: database, streamID: streamRecord.id)) ?? (transcripts: 0, metadata: 0)
        let artifacts = [
            AppVerifyRedactedArtifact(kind: "runtime-events", path: diagnostics.eventLogURL.path),
            AppVerifyRedactedArtifact(kind: "runtime-errors", path: diagnostics.failureLogURL.path),
            AppVerifyRedactedArtifact(kind: "live-runtime-database", path: databaseURL.path),
        ]
        let fields = liveFields(
            request: request,
            streamRecord: streamRecord,
            timeline: timelineSnapshot,
            diagnostics: diagnosticsSnapshot,
            databaseURL: databaseURL
        )
        return AppVerifyLiveStreamExecutionResult(
            registeredStreamID: streamRecord.id,
            runtimeStarted: await recorder.count(streamID: streamRecord.id, phase: .running) > 0,
            processedChunks: processedChunks(from: diagnosticsSnapshot),
            decodedChunks: timelineSnapshot.decodedFrameCount,
            scheduledBuffers: timelineSnapshot.decodedFrameCount,
            transcriptCount: counts.transcripts,
            metadataCount: counts.metadata,
            diagnosticEvents: diagnosticsSnapshot.recentNames,
            diagnosticsFileWritten: diagnosticsSnapshot.eventFileExists || diagnosticsSnapshot.errorFileExists,
            artifacts: artifacts,
            fields: fields
        )
    }

    public func stop(_ request: AppVerifyLiveStreamStopRequest) async throws {
        guard let handle = await activeRuns.remove(for: request) else { return }
        await handle.runtime.stopAll()
        if let registeredStreamID = request.registeredStreamID ?? handle.streamID {
            await handle.runtime.stop(streamID: registeredStreamID)
        }
        await handle.player.stop(timeline: handle.timeline)
        _ = await handle.rollingBuffer.cleanup()
        handle.diagnostics.recordEvent(
            "appverify.live.cleanup.completed",
            streamID: request.registeredStreamID ?? handle.streamID,
            phase: "live.cleanup",
            fields: ["runID": request.runID]
        )
    }

    private static let appRuntimeSupportedTypes: Set<StreamType> = [.hls, .icecast, .icy]

    private func waitForRuntimePhase(
        _ phase: AppStreamRuntimeStatusPhase,
        in recorder: AppVerifyLiveRuntimeEventRecorder,
        streamID: Int64,
        timeoutSeconds: Double
    ) async throws {
        try await waitUntil(timeoutSeconds: timeoutSeconds, phaseName: "runtime phase \(phase.rawValue)") {
            await recorder.count(streamID: streamID, phase: phase) > 0
        }
    }

    private func waitForDiagnosticEvent(
        _ event: String,
        in diagnostics: AppRuntimeDiagnosticsLog,
        timeoutSeconds: Double
    ) async throws {
        try await waitUntil(timeoutSeconds: timeoutSeconds, phaseName: "diagnostic event \(event)") {
            diagnosticsSnapshot(for: diagnostics).eventNames.contains(event)
        }
    }

    private func waitUntil(
        timeoutSeconds: Double,
        phaseName: String,
        predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(max(0.001, timeoutSeconds))
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw AppVerifyLiveRunnerTimeoutError(streamID: phaseName, timeoutSeconds: timeoutSeconds)
    }

    private func diagnosticsSnapshot(for diagnostics: AppRuntimeDiagnosticsLog) -> AppVerifyLiveDiagnosticsSnapshot {
        let events = parseDiagnostics(at: diagnostics.eventLogURL)
        let errors = parseDiagnostics(at: diagnostics.failureLogURL)
        return AppVerifyLiveDiagnosticsSnapshot(
            eventFileExists: FileManager.default.fileExists(atPath: diagnostics.eventLogURL.path),
            errorFileExists: FileManager.default.fileExists(atPath: diagnostics.failureLogURL.path),
            eventEntries: events.entries,
            errorEntries: errors.entries,
            malformedLineCount: events.malformedLineCount + errors.malformedLineCount
        )
    }

    private func parseDiagnostics(at url: URL) -> (entries: [AppVerifyParsedDiagnosticEntry], malformedLineCount: Int) {
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
                let entry = try decoder.decode(AppVerifyLiveRawDiagnosticEntry.self, from: lineData)
                entries.append(AppVerifyParsedDiagnosticEntry(
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

    private func processedChunks(from snapshot: AppVerifyLiveDiagnosticsSnapshot) -> Int {
        snapshot.eventEntries
            .last { $0.event == "runner.ingest.completed" }?
            .fields["processedChunks"]
            .flatMap(Int.init) ?? 0
    }

    private func liveObservationCounts(database: SoundingDatabase, streamID: Int64) throws -> (transcripts: Int, metadata: Int) {
        try database.read { db in
            let transcripts = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM transcript_segments
                JOIN ingest_runs ON ingest_runs.id = transcript_segments.run_id
                WHERE ingest_runs.stream_id = ?
                """,
                arguments: [streamID]
            ) ?? 0
            let songPlays = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song_plays WHERE stream_id = ?", arguments: [streamID]) ?? 0
            let adEvents = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM ad_events
                JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
                WHERE ingest_runs.stream_id = ?
                """,
                arguments: [streamID]
            ) ?? 0
            return (transcripts, songPlays + adEvents)
        }
    }

    private func liveFields(
        request: AppVerifyLiveStreamExecutionRequest,
        streamRecord: StreamRecord,
        timeline: AppPlayerTimelineSnapshot,
        diagnostics: AppVerifyLiveDiagnosticsSnapshot,
        databaseURL: URL
    ) -> [String: String] {
        [
            "executor": "app-runtime-avfoundation",
            "database": factoryConfiguration.database,
            "registry": factoryConfiguration.registry,
            "runtime": factoryConfiguration.runtime,
            "decoder": factoryConfiguration.decoder,
            "player": factoryConfiguration.player,
            "rollingBuffer": factoryConfiguration.rollingBuffer,
            "registeredSourceDescription": streamRecord.sourceDescription,
            "sourceClass": sourceClass(for: request.stream.source),
            "resolvedStreamType": request.stream.resolvedStreamType.rawValue,
            "timelineState": timelineStateName(timeline.state),
            "decodedFrameCount": String(timeline.decodedFrameCount),
            "diagnosticMalformedLines": String(diagnostics.malformedLineCount),
            "databasePath": databaseURL.path,
        ]
    }

    private func sourceClass(for source: String) -> String {
        guard let scheme = URL(string: source)?.scheme?.lowercased() else { return "file-or-path" }
        switch scheme {
        case "http", "https": return scheme
        case "file": return "file"
        default: return "other"
        }
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
}

public actor AppVerifyLiveActiveRuntimeStore {
    private var handles: [String: AppVerifyLiveRuntimeHandle] = [:]

    public init() {}

    func insert(_ handle: AppVerifyLiveRuntimeHandle, for request: AppVerifyLiveStreamExecutionRequest) {
        handles[key(runID: request.runID, streamID: request.stream.id)] = handle
    }

    func remove(for request: AppVerifyLiveStreamStopRequest) -> AppVerifyLiveRuntimeHandle? {
        handles.removeValue(forKey: key(runID: request.runID, streamID: request.stream.id))
    }

    private func key(runID: String, streamID: String) -> String {
        "\(runID)::\(streamID)"
    }
}

struct AppVerifyLiveRuntimeHandle: Sendable {
    var runtime: any AppStreamRuntimeControlling
    var player: any AppPCMPlaybackAdapting
    var timeline: AppPlayerTimelineClock
    var rollingBuffer: RollingPCMBuffer
    var diagnostics: AppRuntimeDiagnosticsLog
    var database: SoundingDatabase
    var streamID: Int64?
}

private actor AppVerifyLiveRuntimeEventRecorder {
    private var events: [AppStreamRuntimeEvent] = []

    func append(_ event: AppStreamRuntimeEvent) {
        events.append(event)
    }

    func count(streamID: Int64, phase: AppStreamRuntimeStatusPhase) -> Int {
        events.filter { $0.streamID == streamID && $0.phase.statusPhase == phase }.count
    }
}

private struct AppVerifyLiveDiagnosticsSnapshot: Sendable {
    var eventFileExists: Bool
    var errorFileExists: Bool
    var eventEntries: [AppVerifyParsedDiagnosticEntry]
    var errorEntries: [AppVerifyParsedDiagnosticEntry]
    var malformedLineCount: Int

    var eventNames: [String] { eventEntries.map(\.event) }
    var errorNames: [String] { errorEntries.map(\.event) }
    var recentNames: [String] { Array((eventNames + errorNames).suffix(32)) }
}

private struct AppVerifyLiveRawDiagnosticEntry: Decodable {
    var event: String
    var phase: String?
    var streamID: Int64?
    var message: String?
    var fields: [String: String]?
}

private enum AppVerifyLiveExecutionError: Error, CustomStringConvertible, Sendable {
    case databaseOpenFailed(String)
    case streamRegistrationFailed(String)
    case unsupportedResolvedStreamType(String)
    case runtimeStartFailed(String)
    case runtimeProofTimeout(String)
    case cleanupFailed(String)

    var description: String {
        switch self {
        case .databaseOpenFailed(let message):
            return "database open failed: \(AppVerifyEvidenceSanitizer.redact(message))"
        case .streamRegistrationFailed(let message):
            return "stream registration failed: \(AppVerifyEvidenceSanitizer.redact(message))"
        case .unsupportedResolvedStreamType(let streamType):
            return "unsupported resolved stream type for app runtime: \(AppVerifyEvidenceSanitizer.redact(streamType))"
        case .runtimeStartFailed(let message):
            return "runtime start failed: \(AppVerifyEvidenceSanitizer.redact(message))"
        case .runtimeProofTimeout(let message):
            return "runtime proof timed out or failed: \(AppVerifyEvidenceSanitizer.redact(message))"
        case .cleanupFailed(let message):
            return "cleanup failed: \(AppVerifyEvidenceSanitizer.redact(message))"
        }
    }
}

private struct AppVerifyLiveNoOpTranscriber: MLTranscription {
    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] { [] }
}

private struct AppVerifyLiveNoOpDiarizer: SpeakerDiarization {
    func diarize(_ chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft] { [] }
}

private struct AppVerifyLiveRunnerTimeoutError: Error, CustomStringConvertible, Sendable {
    var streamID: String
    var timeoutSeconds: Double

    var description: String {
        "Timed out waiting for live stream \(AppVerifyEvidenceSanitizer.redact(streamID)) after \(String(format: "%.3f", timeoutSeconds)) seconds."
    }
}
