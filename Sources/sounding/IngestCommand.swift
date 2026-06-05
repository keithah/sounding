import ArgumentParser
import Foundation
import SoundingKit

struct IngestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Run bounded stream ingest into a Sounding SQLite database."
    )

    @Argument(help: "One or two media source URLs or local fixture paths to ingest.")
    var sources: [String] = []

    @Option(name: .long, help: "Path to the Sounding SQLite database to open or create.")
    var db: String?

    @Option(
        name: .long,
        help: "Managed stream name or id to ingest from an existing active registry row.")
    var stream: String?

    @Option(name: .long, help: "Stream type hint: auto, hls, icecast, icy, mpegts, or udp.")
    var streamType: StreamTypeArgument = .auto

    @Option(name: .long, help: "Stop ingest after this many seconds of decoded media.")
    var duration: Double?

    @Option(name: .long, help: "Stop ingest after this many decoded chunks.")
    var maxChunks: Int?

    mutating func validate() throws {
        do {
            try validateConfiguration()
        } catch let error as IngestCommandError {
            throw ValidationError(error.description)
        }
    }

    mutating func run() async throws {
        do {
            try validateConfiguration()
        } catch let error as IngestCommandError {
            standardErrorWrite(error.description)
            throw ExitCode.failure
        }

        let dbPath = normalizedDatabasePath
        let database: SoundingDatabase
        do {
            database = try SoundingDatabase(fileURL: URL(fileURLWithPath: dbPath))
        } catch {
            standardErrorWrite(IngestCommandError.databaseOpenFailed.description)
            throw ExitCode.failure
        }

        let managedStream: ManagedIngestStream?
        do {
            managedStream = try resolveManagedStream(database: database)
        } catch let error as IngestCommandError {
            standardErrorWrite(error.description)
            throw ExitCode.failure
        } catch let error as StreamRegistryError {
            standardErrorWrite(IngestCommandError.registry(error).description)
            throw ExitCode.failure
        }

        let progressSink = CLIModelProgressSink()
        let cache = ModelCache(progressHandler: { progress in
            progressSink.emit(progress)
        })
        let queue = InferenceQueue()
        let providers = makeProviders(cache: cache, queue: queue)
        let fingerprinter = makeFingerprinter()
        let fingerprintEnricher = makeFingerprintEnricher(database: database)

        do {
            if let managedStream {
                let result = try await StreamIngestPipeline(
                    database: database,
                    decoder: AVFoundationAudioDecoder(),
                    transcriber: providers.transcriber,
                    diarizer: providers.diarizer,
                    fingerprinter: fingerprinter,
                    fingerprintEnricher: fingerprintEnricher,
                    transcriptionPolicy: .always,
                    deduplicatesHLSSegments: false
                ).run(
                    streamID: managedStream.id,
                    source: managedStream.source,
                    streamType: managedStream.streamType,
                    durationSeconds: duration,
                    maxChunks: maxChunks
                )
                if let setupDiagnostic = result.diagnostics.first(where: {
                    $0.phase == .modelSetup && $0.severity == .error
                }) {
                    standardErrorWrite(
                        "Ingest modelSetup failed: \(setupDiagnostic.reason). See persisted ingest_diagnostics for redacted run details."
                    )
                    throw ExitCode.failure
                }
                print(
                    "ingest completed: stream=\(result.streamID) run=\(result.runID) chunks=\(result.processedChunks) diagnostics=\(result.diagnostics.count)"
                )
                return
            }

            if normalizedSources.count == 1 {
                let result = try await StreamIngestPipeline(
                    database: database,
                    decoder: AVFoundationAudioDecoder(),
                    transcriber: providers.transcriber,
                    diarizer: providers.diarizer,
                    fingerprinter: fingerprinter,
                    fingerprintEnricher: fingerprintEnricher,
                    transcriptionPolicy: .always,
                    deduplicatesHLSSegments: false
                ).run(
                    source: normalizedSources[0],
                    streamType: streamType.value,
                    durationSeconds: duration,
                    maxChunks: maxChunks
                )
                if let setupDiagnostic = result.diagnostics.first(where: {
                    $0.phase == .modelSetup && $0.severity == .error
                }) {
                    standardErrorWrite(
                        "Ingest modelSetup failed: \(setupDiagnostic.reason). See persisted ingest_diagnostics for redacted run details."
                    )
                    throw ExitCode.failure
                }
                print(
                    "ingest completed: stream=\(result.streamID) run=\(result.runID) chunks=\(result.processedChunks) diagnostics=\(result.diagnostics.count)"
                )
                return
            }

            let supervisor = MultiStreamIngestSupervisor(
                database: database,
                maximumRequests: Self.maximumSourceCount,
                decoderFactory: { _ in AVFoundationAudioDecoder() },
                transcriber: providers.transcriber,
                diarizer: providers.diarizer,
                fingerprinter: fingerprinter,
                fingerprintEnricher: fingerprintEnricher,
                deduplicatesHLSSegments: false
            )
            let outcomes = try await supervisor.run(
                normalizedSources.map { source in
                    StreamIngestRequest(
                        source: source,
                        streamType: streamType.value,
                        durationSeconds: duration,
                        maxChunks: maxChunks,
                        transcriptionPolicy: .always
                    )
                }
            )
            for (index, outcome) in outcomes.enumerated() {
                print(summaryLine(for: outcome, index: index))
            }
            if outcomes.contains(where: { $0.status != .completed }) {
                standardErrorWrite(
                    "Ingest failed: one or more stream outcomes require operator inspection. See persisted ingest_diagnostics for redacted run details."
                )
                throw ExitCode.failure
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            standardErrorWrite(diagnosticMessage(for: error))
            throw ExitCode.failure
        }
    }

    private static let maximumSourceCount = 2

    private var normalizedSources: [String] {
        sources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var normalizedDatabasePath: String {
        db?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var normalizedStreamReference: String? {
        let trimmed = stream?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func validateConfiguration() throws {
        let normalizedSources = normalizedSources
        let managedStreamReference = normalizedStreamReference
        guard !normalizedDatabasePath.isEmpty else {
            throw IngestCommandError.configuration(
                "provide --db before ingest can start")
        }
        if managedStreamReference != nil {
            guard normalizedSources.isEmpty else {
                throw IngestCommandError.configuration(
                    "provide either --stream or positional source arguments, not both")
            }
        } else {
            guard !normalizedSources.isEmpty else {
                throw IngestCommandError.configuration(
                    "provide at least one non-empty source before ingest can start")
            }
        }
        guard normalizedSources.count <= Self.maximumSourceCount else {
            throw IngestCommandError.configuration(
                "requested \(normalizedSources.count) sources, but this M002 proof supports at most \(Self.maximumSourceCount) sources"
            )
        }
        guard duration != nil || maxChunks != nil else {
            throw IngestCommandError.configuration(
                "provide either duration or max-chunks before ingest can start")
        }
        if let duration, duration <= 0 || !duration.isFinite {
            throw IngestCommandError.configuration("duration must be greater than zero")
        }
        if let maxChunks, maxChunks <= 0 {
            throw IngestCommandError.configuration("max-chunks must be greater than zero")
        }
    }

    private func resolveManagedStream(database: SoundingDatabase) throws -> ManagedIngestStream? {
        guard let reference = normalizedStreamReference else { return nil }
        let registry = StreamRegistry(database: database)
        let record: StreamRecord?
        if let id = Int64(reference), id > 0 {
            record = try registry.find(id: id, includeRemoved: true)
        } else {
            record = try registry.find(name: reference, includeRemoved: true)
        }
        guard let record else {
            throw IngestCommandError.streamNotFound
        }
        guard record.status == .active else {
            throw IngestCommandError.streamNotActive(status: record.status.rawValue)
        }
        let type = try streamType(for: record)
        guard let reconnect = try registry.reconnectSource(id: record.id, includeRemoved: true) else {
            throw IngestCommandError.streamNotFound
        }
        return ManagedIngestStream(
            id: reconnect.streamID,
            source: reconnect.source,
            sourceDescription: reconnect.sourceDescription,
            streamType: type
        )
    }

    private func streamType(for record: StreamRecord) throws -> StreamType {
        guard let streamType = StreamType(rawValue: record.streamType) else {
            throw IngestCommandError.invalidManagedStreamType(record.streamType)
        }
        return streamType
    }

    private func makeProviders(
        cache: ModelCache,
        queue: InferenceQueue
    ) -> (transcriber: any MLTranscription, diarizer: any SpeakerDiarization) {
        if ProcessInfo.processInfo.environment["SOUNDING_DETERMINISTIC_ML"] == "1" {
            return (
                QueuedTranscriber(DeterministicCLITranscriber(), queue: queue),
                QueuedDiarizer(DeterministicCLIDiarizer(), queue: queue)
            )
        }
        if ProcessInfo.processInfo.environment["SOUNDING_ENABLE_FLUIDAUDIO"] != "1" {
            return (
                QueuedTranscriber(WhisperKitTranscriber(cache: cache), queue: queue),
                QueuedDiarizer(NoOpSpeakerDiarizer(), queue: queue)
            )
        }
        return (
            QueuedTranscriber(WhisperKitTranscriber(cache: cache), queue: queue),
            QueuedDiarizer(FluidAudioDiarizer(cache: cache), queue: queue)
        )
    }

    private func makeFingerprinter() -> any AudioFingerprinting {
        let environment = ProcessInfo.processInfo.environment
        if environment["SOUNDING_DETERMINISTIC_FINGERPRINT"] == "1"
            || environment["SOUNDING_DETERMINISTIC_ML"] == "1"
        {
            return DeterministicAudioFingerprinter()
        }

        let apiKey = environment["SOUNDING_ACOUSTID_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let realMode = environment["SOUNDING_ACOUSTID_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard apiKey?.isEmpty == false, realMode == "real" else {
            return NoOpAudioFingerprinter()
        }
        return ChromaSwiftAudioFingerprinter()
    }

    private func makeFingerprintEnricher(database: SoundingDatabase)
        -> any AudioFingerprintEnriching
    {
        AcoustIDAudioFingerprintEnricher(
            cache: AcoustIDLookupCache(database: database),
            lookup: makeAcoustIDLookup()
        )
    }

    private func makeAcoustIDLookup() -> any AcoustIDLookuping {
        let environment = ProcessInfo.processInfo.environment
        let stubMode = environment["SOUNDING_ACOUSTID_STUB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch stubMode {
        case "success":
            return DeterministicAcoustIDLookup()
        case "not-found":
            return StubAcoustIDLookup(
                outcome: .notFound(
                    reason:
                        "no AcoustID result for https://user:pass@example.test/lookup?token=synthetic-secret"
                )
            )
        case "transient":
            return StubAcoustIDLookup(
                outcome: .transientFailure(
                    reason:
                        "temporary AcoustID failure reading /tmp/acoustid-token=synthetic-secret.json"
                )
            )
        case "rate-limit":
            return StubAcoustIDLookup(outcome: .rateLimited(retryAfterSeconds: 30))
        case "malformed":
            return StubAcoustIDLookup(
                outcome: .malformedResponse(
                    reason:
                        "malformed AcoustID body raw={\"api_key\":\"synthetic-secret\",\"url\":\"https://user:pass@example.test/lookup?token=synthetic-secret\"} file=/tmp/acoustid-token=synthetic-secret.json"
                )
            )
        case .some(let stubMode) where !stubMode.isEmpty:
            return NoOpAcoustIDLookup(
                reason: "unknown SOUNDING_ACOUSTID_STUB value; acoustid lookup disabled"
            )
        default:
            break
        }

        let apiKey = environment["SOUNDING_ACOUSTID_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey?.isEmpty == false else {
            return NoOpAcoustIDLookup(reason: "acoustid api key missing")
        }

        let realMode = environment["SOUNDING_ACOUSTID_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard realMode == "real" else {
            return NoOpAcoustIDLookup(reason: "acoustid live lookup not enabled")
        }

        return AcoustIDHTTPClientLookup(clientKey: apiKey ?? "")
    }

    private func summaryLine(for outcome: MultiStreamIngestOutcome, index: Int) -> String {
        var fields = [
            "ingest stream summary:",
            "index=\(index)",
            "source=\(outcome.sourceDescription)",
            "status=\(outcome.status.rawValue)",
            "chunks=\(outcome.processedChunks)",
            "diagnostics=\(outcome.diagnosticCount)",
        ]
        if let streamID = outcome.streamID { fields.append("stream=\(streamID)") }
        if let runID = outcome.runID { fields.append("run=\(runID)") }
        if let errorDescription = outcome.errorDescription {
            fields.append("error=\(IngestRedaction.redact(errorDescription))")
        }
        return fields.joined(separator: " ")
    }

    private func diagnosticMessage(for error: Error) -> String {
        if let diagnostic = error as? IngestDiagnosticError {
            return
                "Ingest \(diagnostic.ingestDiagnosticPhase.rawValue) failed: \(diagnostic.ingestDiagnosticReason). \(sanitize(String(describing: error)))"
        }
        return "Ingest failed: \(sanitize(String(describing: error)))"
    }

    private func sanitize(_ value: String) -> String {
        IngestRedaction.redact(value)
    }

    private func standardErrorWrite(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private struct ManagedIngestStream {
    var id: Int64
    var source: String
    var sourceDescription: String
    var streamType: StreamType
}

private enum IngestCommandError: Error, CustomStringConvertible {
    case configuration(String)
    case databaseOpenFailed
    case registry(StreamRegistryError)
    case streamNotFound
    case streamNotActive(status: String)
    case invalidManagedStreamType(String)

    var description: String {
        switch self {
        case .configuration(let reason):
            return "Ingest configuration failed: \(IngestRedaction.redact(reason))."
        case .databaseOpenFailed:
            return "Ingest database failed: could not open redacted database path."
        case .registry(let error):
            return registryDescription(error)
        case .streamNotFound:
            return "Ingest state failed: stream reference was not found."
        case .streamNotActive(let status):
            return
                "Ingest state failed: stream is not active (status=\(IngestRedaction.redact(status)))."
        case .invalidManagedStreamType(let streamType):
            return
                "Ingest configuration failed: managed stream has invalid stream type \(IngestRedaction.redact(streamType))."
        }
    }

    private func registryDescription(_ error: StreamRegistryError) -> String {
        switch error {
        case .invalidID:
            return "Ingest configuration failed: stream id must be greater than zero."
        case .invalidName:
            return "Ingest configuration failed: stream name must not be empty."
        case .invalidSource:
            return "Ingest configuration failed: stream source must not be empty."
        case .invalidStreamType:
            return "Ingest configuration failed: stream type must not be empty."
        case .invalidStatus(let status):
            return
                "Ingest database failed: invalid stream status \(IngestRedaction.redact(status))."
        case .duplicateName:
            return "Ingest state failed: duplicate active stream name."
        case .streamNotFound:
            return "Ingest state failed: stream reference was not found."
        case .streamRemoved:
            return "Ingest state failed: stream is not active (status=removed)."
        case .databaseReadFailed(let message):
            return "Ingest database failed: \(IngestRedaction.redact(message))."
        case .databaseWriteFailed(let message):
            return "Ingest database failed: \(IngestRedaction.redact(message))."
        }
    }
}

private final class CLIModelProgressSink: @unchecked Sendable {
    private let lock = NSLock()

    func emit(_ progress: ModelCacheProgress) {
        lock.lock()
        defer { lock.unlock() }

        let suffix: String
        if let fraction = progress.fractionCompleted {
            let percent = max(0, min(100, Int((fraction * 100).rounded())))
            suffix = " \(percent)%"
        } else {
            suffix = ""
        }
        let line =
            "model \(progress.event.rawValue): provider=\(IngestRedaction.component(progress.provider)) model=\(IngestRedaction.component(progress.model))\(suffix)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

private struct StubAcoustIDLookup: AcoustIDLookuping {
    var outcome: AcoustIDLookupOutcome

    func lookup(_ request: AcoustIDLookupRequest) async -> AcoustIDLookupOutcome {
        outcome
    }
}

private struct DeterministicCLITranscriber: MLTranscription {
    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        let speaker = "cli-speaker-\(chunk.sequence)"
        let words = ["cli", "shared", "phrase", "stream", "\(chunk.sequence)"]
        let duration = max((chunk.endSeconds - chunk.startSeconds) / Double(words.count), 0.1)
        return [
            TranscriptSegmentDraft(
                sequence: 0,
                speakerLabel: speaker,
                startSeconds: chunk.startSeconds,
                endSeconds: max(chunk.endSeconds, chunk.startSeconds + duration),
                text: words.joined(separator: " "),
                confidence: 0.99,
                words: words.enumerated().map { offset, text in
                    TranscriptWordDraft(
                        sequence: offset,
                        speakerLabel: speaker,
                        startSeconds: chunk.startSeconds + (Double(offset) * duration),
                        endSeconds: chunk.startSeconds + (Double(offset + 1) * duration),
                        text: text,
                        confidence: 0.99
                    )
                }
            )
        ]
    }
}

private struct DeterministicCLIDiarizer: SpeakerDiarization {
    func diarize(
        _ chunk: DecodedAudioChunk,
        transcriptSegments: [TranscriptSegmentDraft]
    ) async throws -> [SpeakerTurnDraft] {
        transcriptSegments.map { segment in
            SpeakerTurnDraft(
                speakerLabel: segment.speakerLabel ?? "cli-speaker",
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                confidence: 0.99
            )
        }
    }
}
