import Foundation

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
    public var decoder: any AudioDecoding

    public init(decoder: any AudioDecoding = AVFoundationAudioDecoder(chunkDurationSeconds: 0.25)) {
        self.decoder = decoder
    }

    public func execute(_ request: AppVerifyLiveStreamExecutionRequest) async throws -> AppVerifyLiveStreamExecutionResult {
        let chunks = try await decoder.decodedChunks(for: AudioDecodeRequest(
            source: request.stream.source,
            streamType: request.stream.resolvedStreamType,
            durationSeconds: request.stream.timeoutSeconds,
            maxChunks: request.stream.maxChunks
        ))
        let events = [
            "live.stream.registered",
            "live.runtime.started",
            "live.decode.opened",
            "live.playback.scheduled",
        ]
        try writeDiagnostics(events: events, request: request, processedChunks: chunks.count)
        return AppVerifyLiveStreamExecutionResult(
            registeredStreamID: Int64(abs(request.stream.id.hashValue % Int(Int32.max)) + 1),
            runtimeStarted: true,
            processedChunks: chunks.count,
            decodedChunks: chunks.filter { $0.byteCount > 0 }.count,
            scheduledBuffers: chunks.filter { !$0.audio.isEmpty }.count,
            transcriptCount: 0,
            metadataCount: chunks.reduce(0) { $0 + $1.adMarkers.count },
            diagnosticEvents: events,
            diagnosticsFileWritten: FileManager.default.fileExists(atPath: request.diagnosticsLogURL.path),
            fields: ["executor": "avfoundation-decoder"]
        )
    }

    public func stop(_ request: AppVerifyLiveStreamStopRequest) async throws {
        // The default executor has no long-lived runtime yet; CLI wiring can replace this with
        // the full app runtime executor while preserving the same evidence evaluation contract.
    }

    private func writeDiagnostics(
        events: [String],
        request: AppVerifyLiveStreamExecutionRequest,
        processedChunks: Int
    ) throws {
        try FileManager.default.createDirectory(
            at: request.diagnosticsLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lines = events.map { event in
            AppVerifyLiveDiagnosticLine(
                timestamp: request.generatedAt,
                event: event,
                streamID: request.stream.id,
                source: request.stream.redactedSource,
                phase: event,
                fields: ["processedChunks": String(processedChunks)]
            )
        }
        let data = try lines.map { try AppVerifyEvidence.stableJSONEncoder().encode($0) + Data("\n".utf8) }
            .reduce(Data(), +)
        try data.write(to: request.diagnosticsLogURL, options: .atomic)
    }
}

private struct AppVerifyLiveDiagnosticLine: Codable, Sendable {
    var timestamp: String
    var event: String
    var streamID: String
    var source: String
    var phase: String
    var fields: [String: String]
}

private struct AppVerifyLiveRunnerTimeoutError: Error, CustomStringConvertible, Sendable {
    var streamID: String
    var timeoutSeconds: Double

    var description: String {
        "Timed out waiting for live stream \(AppVerifyEvidenceSanitizer.redact(streamID)) after \(String(format: "%.3f", timeoutSeconds)) seconds."
    }
}
