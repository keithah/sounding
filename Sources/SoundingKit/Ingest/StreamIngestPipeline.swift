import Foundation

/// Summary returned by a bounded ingest run after state has been persisted.
public struct StreamIngestResult: Equatable, Sendable {
    public var streamID: Int64
    public var runID: Int64
    public var processedChunks: Int
    public var diagnostics: [IngestDiagnosticDraft]

    public init(
        streamID: Int64,
        runID: Int64,
        processedChunks: Int,
        diagnostics: [IngestDiagnosticDraft] = []
    ) {
        self.streamID = streamID
        self.runID = runID
        self.processedChunks = processedChunks
        self.diagnostics = diagnostics
    }
}

/// Bounded ingest service that wires source decoding, transcription, diarization, and GRDB persistence.
///
/// The pipeline is intentionally instance-scoped: all runtime dependencies are injected through the
/// initializer, avoiding global mutable provider state so later concurrent ingest work can create one
/// independent pipeline per run.
public struct StreamIngestPipeline {
    public typealias TimestampProvider = @Sendable () -> String

    private let database: SoundingDatabase
    private let decoder: any AudioDecoding
    private let transcriber: any MLTranscription
    private let diarizer: any SpeakerDiarization
    private let now: TimestampProvider

    public init(
        database: SoundingDatabase,
        decoder: any AudioDecoding,
        transcriber: any MLTranscription,
        diarizer: any SpeakerDiarization,
        now: @escaping TimestampProvider = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.database = database
        self.decoder = decoder
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.now = now
    }

    public func run(
        source: String,
        streamType requestedStreamType: StreamType = .auto,
        durationSeconds: Double? = nil,
        maxChunks: Int? = nil
    ) async throws -> StreamIngestResult {
        let streamType = resolvedStreamType(for: source, requested: requestedStreamType)
        let persistence = IngestPersistence(database: database)
        let createdAt = now()
        let redactedSource = IngestRedaction.sourceDescription(source)
        let streamID = try persistence.createStream(
            streamType: streamType.rawValue,
            source: redactedSource,
            createdAt: createdAt
        )
        let runID = try persistence.createRun(
            streamID: streamID,
            startedAt: now(),
            status: .running,
            context: runContext(durationSeconds: durationSeconds, maxChunks: maxChunks)
        )

        var diagnostics: [IngestDiagnosticDraft] = []
        var processedChunks = 0
        var nextSegmentSequence = 0
        var terminalRunFinished = false

        func finishRunOnce(
            status: IngestRunStatus,
            diagnostic: IngestDiagnosticDraft? = nil,
            chunkID: Int64? = nil,
            context: [String: JSONValue]
        ) throws {
            guard !terminalRunFinished else { return }

            if let diagnostic {
                let diagnosticChunkID: Int64
                if let chunkID {
                    diagnosticChunkID = chunkID
                } else {
                    diagnosticChunkID = try persistence.createChunk(
                        runID: runID,
                        sequence: -1,
                        startedAt: now(),
                        endedAt: now(),
                        context: ["synthetic": true, "terminalStatus": .string(status.rawValue)]
                    )
                }
                try persistence.persistTimeline(
                    IngestChunkTimeline(runID: runID, chunkID: diagnosticChunkID, diagnostics: [diagnostic], createdAt: now())
                )
            }

            try persistence.finishRun(runID: runID, endedAt: now(), status: status, context: context)
            terminalRunFinished = true
        }

        func terminalContext(
            status: IngestRunStatus,
            diagnosticCount: Int,
            phase: IngestDiagnosticPhase? = nil,
            reason: String? = nil
        ) -> [String: JSONValue] {
            var context: [String: JSONValue] = [
                "processedChunks": .number(Double(processedChunks)),
                "diagnosticCount": .number(Double(diagnosticCount)),
                "terminalStatus": .string(status.rawValue)
            ]
            if let phase {
                context["terminalPhase"] = .string(phase.rawValue)
            }
            if let reason {
                context["terminalReason"] = .string(IngestRedaction.redact(reason))
            }
            return context
        }

        do {
            try Task.checkCancellation()
            let decoded = try await decoder.decodedChunks(
                for: AudioDecodeRequest(
                    source: source,
                    streamType: streamType,
                    durationSeconds: durationSeconds,
                    maxChunks: maxChunks
                )
            )
            try Task.checkCancellation()
            let bounded = applyBounds(decoded, durationSeconds: durationSeconds, maxChunks: maxChunks)

            for chunk in bounded {
                try Task.checkCancellation()
                if chunk.audio.isEmpty || chunk.byteCount <= 0 {
                    let diagnostic = self.diagnostic(
                        streamID: streamID,
                        phase: .decode,
                        severity: .warning,
                        reason: "empty-audio-chunk",
                        source: redactedSource,
                        streamType: streamType,
                        context: ["chunkSequence": .number(Double(chunk.sequence))]
                    )
                    let chunkID = try persistence.createChunk(
                        runID: runID,
                        sequence: chunk.sequence,
                        segmentURI: redactedSourceDescription(chunk.segmentURI),
                        byteCount: max(chunk.byteCount, 0),
                        startedAt: chunk.startedAt,
                        endedAt: chunk.endedAt,
                        context: chunkContext(chunk)
                    )
                    try persistence.persistTimeline(
                        IngestChunkTimeline(
                            runID: runID,
                            chunkID: chunkID,
                            adMarkers: redactedMarkers(chunk.adMarkers),
                            diagnostics: [diagnostic],
                            createdAt: now()
                        )
                    )
                    diagnostics.append(diagnostic)
                    processedChunks += 1
                    continue
                }

                let chunkID = try persistence.createChunk(
                    runID: runID,
                    sequence: chunk.sequence,
                    segmentURI: redactedSourceDescription(chunk.segmentURI),
                    byteCount: chunk.byteCount,
                    startedAt: chunk.startedAt,
                    endedAt: chunk.endedAt,
                    context: chunkContext(chunk)
                )

                var chunkDiagnostics: [IngestDiagnosticDraft] = []
                var segments: [TranscriptSegmentDraft] = []
                do {
                    try Task.checkCancellation()
                    segments = try await transcriber.transcribe(chunk)
                    let validation = validateAndNormalize(segments, nextSequence: nextSegmentSequence)
                    segments = validation.segments
                    nextSegmentSequence += segments.count
                    chunkDiagnostics.append(contentsOf: validation.diagnostics.map { template in
                        diagnostic(
                            streamID: streamID,
                            phase: .transcribe,
                            severity: .warning,
                            reason: template.reason,
                            source: redactedSource,
                            streamType: streamType,
                            context: template.context
                        )
                    })
                } catch let cancellation as CancellationError {
                    throw cancellation
                } catch {
                    let diagnosticError = error as? IngestDiagnosticError
                    let phase = diagnosticError?.ingestDiagnosticPhase ?? .transcribe
                    let reason = diagnosticError?.ingestDiagnosticReason ?? "transcription-failed"
                    let providerDiagnostic = diagnostic(
                        streamID: streamID,
                        phase: phase,
                        severity: .error,
                        reason: reason,
                        source: redactedSource,
                        streamType: streamType,
                        context: errorContext(error, chunk: chunk)
                    )
                    if phase == .modelSetup {
                        try finishRunOnce(
                            status: .failed,
                            diagnostic: providerDiagnostic,
                            chunkID: chunkID,
                            context: terminalContext(status: .failed, diagnosticCount: diagnostics.count + 1, phase: phase, reason: reason)
                        )
                        throw error
                    }
                    chunkDiagnostics.append(providerDiagnostic)
                    segments = []
                }

                var speakerTurns: [SpeakerTurnDraft] = []
                do {
                    try Task.checkCancellation()
                    speakerTurns = try await diarizer.diarize(chunk, transcriptSegments: segments)
                } catch let cancellation as CancellationError {
                    throw cancellation
                } catch {
                    let diagnosticError = error as? IngestDiagnosticError
                    let phase = diagnosticError?.ingestDiagnosticPhase ?? .diarize
                    let reason = diagnosticError?.ingestDiagnosticReason ?? "diarization-failed"
                    let providerDiagnostic = diagnostic(
                        streamID: streamID,
                        phase: phase,
                        severity: .error,
                        reason: reason,
                        source: redactedSource,
                        streamType: streamType,
                        context: errorContext(error, chunk: chunk)
                    )
                    if phase == .modelSetup {
                        try finishRunOnce(
                            status: .failed,
                            diagnostic: providerDiagnostic,
                            chunkID: chunkID,
                            context: terminalContext(status: .failed, diagnosticCount: diagnostics.count + chunkDiagnostics.count + 1, phase: phase, reason: reason)
                        )
                        throw error
                    }
                    chunkDiagnostics.append(providerDiagnostic)
                    speakerTurns = []
                }

                try persistence.persistTimeline(
                    IngestChunkTimeline(
                        runID: runID,
                        chunkID: chunkID,
                        segments: segments,
                        speakerTurns: speakerTurns,
                        adMarkers: redactedMarkers(chunk.adMarkers),
                        diagnostics: chunkDiagnostics,
                        createdAt: now()
                    )
                )
                diagnostics.append(contentsOf: chunkDiagnostics)
                processedChunks += 1
            }

            try finishRunOnce(
                status: .completed,
                context: terminalContext(status: .completed, diagnosticCount: diagnostics.count)
            )
            return StreamIngestResult(streamID: streamID, runID: runID, processedChunks: processedChunks, diagnostics: diagnostics)
        } catch is CancellationError {
            let diagnostic = self.diagnostic(
                streamID: streamID,
                phase: .decode,
                severity: .error,
                reason: "ingest-cancelled",
                source: redactedSource,
                streamType: streamType,
                context: [
                    "processedChunks": .number(Double(processedChunks)),
                    "error": .string("CancellationError")
                ]
            )
            try? finishRunOnce(
                status: .cancelled,
                diagnostic: diagnostic,
                context: terminalContext(status: .cancelled, diagnosticCount: diagnostics.count + 1, phase: .decode, reason: "ingest-cancelled")
            )
            throw CancellationError()
        } catch {
            if terminalRunFinished {
                throw error
            }
            let decodingDiagnostic = error as? IngestDiagnosticError
            let phase = decodingDiagnostic?.ingestDiagnosticPhase ?? .decode
            let reason = decodingDiagnostic?.ingestDiagnosticReason ?? "decoder-failed"
            let diagnostic = self.diagnostic(
                streamID: streamID,
                phase: phase,
                severity: .error,
                reason: reason,
                source: redactedSource,
                streamType: streamType,
                context: ["error": .string(IngestRedaction.redact(String(describing: error)))]
            )
            try finishRunOnce(
                status: .failed,
                diagnostic: diagnostic,
                context: terminalContext(status: .failed, diagnosticCount: diagnostics.count + 1, phase: phase, reason: reason)
            )
            throw error
        }
    }

    private func applyBounds(
        _ chunks: [DecodedAudioChunk],
        durationSeconds: Double?,
        maxChunks: Int?
    ) -> [DecodedAudioChunk] {
        var bounded = chunks
        if let durationSeconds {
            bounded = bounded.filter { $0.startSeconds < durationSeconds }
        }
        if let maxChunks {
            bounded = Array(bounded.prefix(max(0, maxChunks)))
        }
        return bounded
    }

    private struct SegmentValidationDiagnostic {
        var reason: String
        var context: [String: JSONValue]
    }

    private func validateAndNormalize(
        _ segments: [TranscriptSegmentDraft],
        nextSequence: Int
    ) -> (segments: [TranscriptSegmentDraft], diagnostics: [SegmentValidationDiagnostic]) {
        var accepted: [TranscriptSegmentDraft] = []
        var diagnostics: [SegmentValidationDiagnostic] = []

        for segment in segments {
            var previousStart = -Double.infinity
            var validWords: [TranscriptWordDraft] = []
            var invalidWordCount = 0

            for word in segment.words.sorted(by: { $0.sequence < $1.sequence }) {
                guard word.startSeconds >= previousStart, word.endSeconds >= word.startSeconds else {
                    invalidWordCount += 1
                    continue
                }
                previousStart = word.startSeconds
                validWords.append(word)
            }

            if invalidWordCount > 0 {
                diagnostics.append(
                    SegmentValidationDiagnostic(
                        reason: "non-monotonic-word-timestamps",
                        context: [
                            "segmentSequence": .number(Double(segment.sequence)),
                            "invalidWordCount": .number(Double(invalidWordCount))
                        ]
                    )
                )
            }

            guard segment.endSeconds >= segment.startSeconds else {
                diagnostics.append(
                    SegmentValidationDiagnostic(
                        reason: "invalid-segment-timestamps",
                        context: ["segmentSequence": .number(Double(segment.sequence))]
                    )
                )
                continue
            }

            var normalized = segment
            normalized.sequence = nextSequence + accepted.count
            normalized.words = validWords.enumerated().map { offset, word in
                var normalizedWord = word
                normalizedWord.sequence = offset
                return normalizedWord
            }
            accepted.append(normalized)
        }

        return (accepted, diagnostics)
    }

    private func diagnostic(
        streamID: Int64,
        phase: IngestDiagnosticPhase,
        severity: IngestDiagnosticSeverity,
        reason: String,
        source: String,
        streamType: StreamType,
        context: [String: JSONValue]? = nil
    ) -> IngestDiagnosticDraft {
        IngestDiagnosticDraft(
            streamID: streamID,
            phase: phase,
            severity: severity,
            reason: reason,
            source: source,
            sourceClass: sourceClass(for: streamType),
            streamType: streamType.rawValue,
            context: IngestRedaction.context(context),
            createdAt: now()
        )
    }

    private func errorContext(_ error: Error, chunk: DecodedAudioChunk) -> [String: JSONValue] {
        [
            "chunkSequence": .number(Double(chunk.sequence)),
            "error": .string(IngestRedaction.redact(String(describing: error)))
        ]
    }

    private func chunkContext(_ chunk: DecodedAudioChunk) -> [String: JSONValue] {
        [
            "startSeconds": .number(chunk.startSeconds),
            "endSeconds": .number(chunk.endSeconds)
        ]
    }

    private func runContext(durationSeconds: Double?, maxChunks: Int?) -> [String: JSONValue] {
        var context: [String: JSONValue] = [:]
        if let durationSeconds {
            context["durationSeconds"] = .number(durationSeconds)
        }
        if let maxChunks {
            context["maxChunks"] = .number(Double(maxChunks))
        }
        return context
    }

    private func redactedMarkers(_ markers: [AdMarker]) -> [AdMarker] {
        markers.map { marker in
            var redacted = marker
            redacted.segment = redactedSourceDescription(marker.segment)
            redacted.rawBase64 = marker.rawBase64 == nil ? nil : "[redacted]"
            return redacted
        }
    }

    private func redactedSourceDescription(_ value: String?) -> String? {
        guard let value else { return nil }
        return IngestRedaction.sourceDescription(value)
    }

    private func resolvedStreamType(for source: String, requested streamType: StreamType) -> StreamType {
        guard streamType == .auto else {
            return streamType
        }
        if source.lowercased().contains(".m3u8") {
            return .hls
        }
        if URLComponents(string: source)?.scheme?.lowercased() == "udp" {
            return .udp
        }
        return .icecast
    }

    private func sourceClass(for streamType: StreamType) -> String {
        switch streamType {
        case .hls:
            return "hls_manifest"
        case .icecast, .icy:
            return "icy_stream"
        case .mpegts:
            return "mpegts_stream"
        case .udp:
            return "udp_datagram_replay"
        case .auto:
            return "auto_stream"
        }
    }
}
