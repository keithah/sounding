import Foundation
import GRDB

/// One bounded stream request managed by `MultiStreamIngestSupervisor`.
public struct StreamIngestRequest: Equatable, Sendable {
    public var source: String
    public var streamType: StreamType
    public var durationSeconds: Double?
    public var maxChunks: Int?

    public init(
        source: String,
        streamType: StreamType = .auto,
        durationSeconds: Double? = nil,
        maxChunks: Int? = nil
    ) {
        self.source = source
        self.streamType = streamType
        self.durationSeconds = durationSeconds
        self.maxChunks = maxChunks
    }
}

/// Per-stream terminal summary suitable for CLI/operator reporting.
public struct MultiStreamIngestOutcome: Equatable, Sendable {
    public var sourceDescription: String
    public var streamID: Int64?
    public var runID: Int64?
    public var status: IngestRunStatus
    public var processedChunks: Int
    public var diagnosticCount: Int
    public var errorDescription: String?

    public init(
        sourceDescription: String,
        streamID: Int64? = nil,
        runID: Int64? = nil,
        status: IngestRunStatus,
        processedChunks: Int,
        diagnosticCount: Int,
        errorDescription: String? = nil
    ) {
        self.sourceDescription = sourceDescription
        self.streamID = streamID
        self.runID = runID
        self.status = status
        self.processedChunks = processedChunks
        self.diagnosticCount = diagnosticCount
        self.errorDescription = errorDescription
    }
}

public enum MultiStreamIngestSupervisorError: Error, Equatable, LocalizedError, Sendable {
    case emptyRequests
    case tooManyRequests(count: Int, maximum: Int)
    case unboundedRequest(index: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyRequests:
            return "At least one bounded stream ingest request is required."
        case .tooManyRequests(let count, let maximum):
            return "Requested \(count) streams, but the supervisor maximum is \(maximum)."
        case .unboundedRequest(let index):
            return "Stream request \(index) must specify durationSeconds or maxChunks."
        }
    }
}

/// Runs multiple bounded stream ingests in one process against one database.
///
/// The supervisor is deliberately a composition layer: it creates one independent
/// `StreamIngestPipeline` per request and does not make the pipeline itself globally
/// multi-stream aware. Child tasks catch their own errors so a failed stream cannot
/// cancel sibling ingests in the non-throwing task group.
public struct MultiStreamIngestSupervisor {
    public typealias DecoderFactory =
        @Sendable (StreamIngestRequest) async throws -> any AudioDecoding
    public typealias TimestampProvider = StreamIngestPipeline.TimestampProvider

    private let database: SoundingDatabase
    private let maximumRequests: Int
    private let decoderFactory: DecoderFactory
    private let transcriber: any MLTranscription
    private let diarizer: any SpeakerDiarization
    private let fingerprinter: any AudioFingerprinting
    private let fingerprintEnricher: any AudioFingerprintEnriching
    private let deduplicatesHLSSegments: Bool
    private let now: TimestampProvider

    public init(
        database: SoundingDatabase,
        maximumRequests: Int = 2,
        decoderFactory: @escaping DecoderFactory,
        transcriber: any MLTranscription,
        diarizer: any SpeakerDiarization,
        fingerprinter: any AudioFingerprinting = NoOpAudioFingerprinter(),
        fingerprintEnricher: any AudioFingerprintEnriching = NoOpAudioFingerprintEnricher(),
        deduplicatesHLSSegments: Bool = true,
        now: @escaping TimestampProvider = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.database = database
        self.maximumRequests = maximumRequests
        self.decoderFactory = decoderFactory
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.fingerprinter = fingerprinter
        self.fingerprintEnricher = fingerprintEnricher
        self.deduplicatesHLSSegments = deduplicatesHLSSegments
        self.now = now
    }

    public func run(_ requests: [StreamIngestRequest]) async throws -> [MultiStreamIngestOutcome] {
        try validate(requests)

        return await withTaskGroup(of: (Int, MultiStreamIngestOutcome).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    let outcome = await runOne(request)
                    return (index, outcome)
                }
            }

            var indexedOutcomes: [(Int, MultiStreamIngestOutcome)] = []
            for await outcome in group {
                indexedOutcomes.append(outcome)
            }
            return
                indexedOutcomes
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    private func validate(_ requests: [StreamIngestRequest]) throws {
        guard !requests.isEmpty else { throw MultiStreamIngestSupervisorError.emptyRequests }
        guard requests.count <= maximumRequests else {
            throw MultiStreamIngestSupervisorError.tooManyRequests(
                count: requests.count,
                maximum: maximumRequests
            )
        }

        for (index, request) in requests.enumerated() {
            if request.durationSeconds == nil && request.maxChunks == nil {
                throw MultiStreamIngestSupervisorError.unboundedRequest(index: index)
            }
        }
    }

    private func runOne(_ request: StreamIngestRequest) async -> MultiStreamIngestOutcome {
        let sourceDescription = IngestRedaction.sourceDescription(request.source)

        do {
            let decoder = try await decoderFactory(request)
            let pipeline = StreamIngestPipeline(
                database: database,
                decoder: decoder,
                transcriber: transcriber,
                diarizer: diarizer,
                fingerprinter: fingerprinter,
                fingerprintEnricher: fingerprintEnricher,
                deduplicatesHLSSegments: deduplicatesHLSSegments,
                now: now
            )
            let result = try await pipeline.run(
                source: request.source,
                streamType: request.streamType,
                durationSeconds: request.durationSeconds,
                maxChunks: request.maxChunks
            )
            return MultiStreamIngestOutcome(
                sourceDescription: sourceDescription,
                streamID: result.streamID,
                runID: result.runID,
                status: .completed,
                processedChunks: result.processedChunks,
                diagnosticCount: result.diagnostics.count
            )
        } catch is CancellationError {
            return persistedFailureOutcome(
                sourceDescription: sourceDescription,
                fallbackStatus: .cancelled,
                error: CancellationError()
            )
        } catch {
            return persistedFailureOutcome(
                sourceDescription: sourceDescription,
                fallbackStatus: .failed,
                error: error
            )
        }
    }

    private func persistedFailureOutcome(
        sourceDescription: String,
        fallbackStatus: IngestRunStatus,
        error: any Error
    ) -> MultiStreamIngestOutcome {
        let redactedError = IngestRedaction.redact(String(describing: error))
        let persisted = try? latestRunSummary(sourceDescription: sourceDescription)
        return MultiStreamIngestOutcome(
            sourceDescription: sourceDescription,
            streamID: persisted?.streamID,
            runID: persisted?.runID,
            status: persisted?.status ?? fallbackStatus,
            processedChunks: persisted?.processedChunks ?? 0,
            diagnosticCount: persisted?.diagnosticCount ?? 0,
            errorDescription: redactedError
        )
    }

    private struct PersistedRunSummary {
        var streamID: Int64
        var runID: Int64
        var status: IngestRunStatus
        var processedChunks: Int
        var diagnosticCount: Int
    }

    private func latestRunSummary(sourceDescription: String) throws -> PersistedRunSummary? {
        try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT
                            streams.id AS stream_id,
                            ingest_runs.id AS run_id,
                            ingest_runs.status AS status,
                            (SELECT COUNT(*) FROM ingest_chunks WHERE ingest_chunks.run_id = ingest_runs.id AND sequence >= 0) AS processed_chunks,
                            (SELECT COUNT(*) FROM ingest_diagnostics WHERE ingest_diagnostics.run_id = ingest_runs.id) AS diagnostic_count
                        FROM streams
                        JOIN ingest_runs ON ingest_runs.stream_id = streams.id
                        WHERE streams.source = ?
                        ORDER BY ingest_runs.id DESC
                        LIMIT 1
                        """,
                    arguments: [sourceDescription]
                )
            else {
                return nil
            }
            guard
                let streamID: Int64 = row["stream_id"],
                let runID: Int64 = row["run_id"],
                let rawStatus: String = row["status"],
                let status = IngestRunStatus(rawValue: rawStatus),
                let processedChunks: Int = row["processed_chunks"],
                let diagnosticCount: Int = row["diagnostic_count"]
            else {
                return nil
            }
            return PersistedRunSummary(
                streamID: streamID,
                runID: runID,
                status: status,
                processedChunks: processedChunks,
                diagnosticCount: diagnosticCount
            )
        }
    }
}
