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
    private let fingerprinter: any AudioFingerprinting
    private let fingerprintEnricher: any AudioFingerprintEnriching
    private let audioArchiveStore: AudioArchiveStore?
    private let audioArchiveEnabled: Bool
    private let transcriptionPolicy: StreamTranscriptionPolicy
    private let deduplicatesHLSSegments: Bool
    private let now: TimestampProvider

    public static func defaultTimestamp() -> String {
        SoundingTimestampClock.timestamp()
    }

    public init(
        database: SoundingDatabase,
        decoder: any AudioDecoding,
        transcriber: any MLTranscription,
        diarizer: any SpeakerDiarization,
        fingerprinter: any AudioFingerprinting = NoOpAudioFingerprinter(),
        fingerprintEnricher: any AudioFingerprintEnriching = NoOpAudioFingerprintEnricher(),
        audioArchiveStore: AudioArchiveStore? = nil,
        audioArchiveEnabled: Bool = false,
        transcriptionPolicy: StreamTranscriptionPolicy = .defaultValue,
        deduplicatesHLSSegments: Bool = true,
        now: @escaping TimestampProvider = { StreamIngestPipeline.defaultTimestamp() }
    ) {
        self.database = database
        self.decoder = decoder
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.fingerprinter = fingerprinter
        self.fingerprintEnricher = fingerprintEnricher
        self.audioArchiveStore = audioArchiveStore
        self.audioArchiveEnabled = audioArchiveEnabled
        self.transcriptionPolicy = transcriptionPolicy
        self.deduplicatesHLSSegments = deduplicatesHLSSegments
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
        let streamID = try persistence.createStream(
            streamType: streamType.rawValue,
            source: IngestRedaction.sourceDescription(source),
            createdAt: createdAt
        )
        return try await run(
            streamID: streamID,
            source: source,
            streamType: streamType,
            durationSeconds: durationSeconds,
            maxChunks: maxChunks
        )
    }

    public func run(
        streamID: Int64,
        source: String,
        streamType requestedStreamType: StreamType,
        durationSeconds: Double? = nil,
        maxChunks: Int? = nil
    ) async throws -> StreamIngestResult {
        let streamType = resolvedStreamType(for: source, requested: requestedStreamType)
        let persistence = IngestPersistence(database: database)
        let redactedSource = IngestRedaction.sourceDescription(source)
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
        var pendingHLSClaim: HLSProcessedClaim?

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
                    IngestChunkTimeline(
                        runID: runID, chunkID: diagnosticChunkID, diagnostics: [diagnostic],
                        createdAt: now())
                )
            }

            try persistence.finishRun(
                runID: runID, endedAt: now(), status: status, context: context)
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
                "terminalStatus": .string(status.rawValue),
            ]
            if let phase {
                context["terminalPhase"] = .string(phase.rawValue)
            }
            if let reason {
                context["terminalReason"] = .string(IngestRedaction.redact(reason))
            }
            return context
        }

        let programMetadataResolver = ChunkProgramMetadataResolver { startSeconds, endSeconds in
            try persistence.activeTimedMetadataSongPlay(
                streamID: streamID,
                startSeconds: startSeconds,
                endSeconds: endSeconds
            )
        }

        do {
            try Task.checkCancellation()
            let decoded = try await decoder.decodedChunks(
                for: AudioDecodeRequest(
                    source: source,
                    streamType: streamType,
                    durationSeconds: durationSeconds,
	                    maxChunks: maxChunks,
	                    minimumHLSMediaSequence: minimumHLSMediaSequence(
	                        streamID: streamID,
	                        streamType: streamType,
	                        persistence: persistence
	                    ),
	                    excludedHLSSegmentKeys: excludedHLSSegmentKeys(
	                        streamID: streamID,
	                        streamType: streamType,
	                        persistence: persistence
	                    ),
	                    hlsTimelineStartSeconds: hlsTimelineStartSeconds(
	                        streamID: streamID,
	                        streamType: streamType,
	                        persistence: persistence
                    )
                )
            )
            try Task.checkCancellation()
            let bounded = applyBounds(
                decoded, durationSeconds: durationSeconds, maxChunks: maxChunks)

            for chunk in bounded {
                try Task.checkCancellation()
                var processedHLSClaim: HLSProcessedClaim?
                switch try persistence.claimHLSSegment(hlsClaim(for: chunk, streamID: streamID, runID: runID)) {
                case .noClaim:
                    processedHLSClaim = nil
                case .claimed(let claimDiagnostics):
                    processedHLSClaim = HLSProcessedClaim(mediaSequence: chunk.hlsIdentity?.mediaSequence)
                    pendingHLSClaim = processedHLSClaim
                    diagnostics.append(contentsOf: claimDiagnostics.map { hlsDiagnosticDraft(
                        $0,
                        streamID: streamID,
                        source: redactedSource,
                        streamType: streamType
                    ) })
                case .duplicate(_, _, let claimDiagnostic), .conflict(_, _, let claimDiagnostic):
                    diagnostics.append(
                        hlsDiagnosticDraft(
                            claimDiagnostic,
                            streamID: streamID,
                            source: redactedSource,
                            streamType: streamType
                        ))
                    continue
                }

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
                    try finalizeHLSClaimIfNeeded(
                        processedHLSClaim,
                        persistence: persistence,
                        streamID: streamID,
                        runID: runID,
                        chunkID: chunkID
                    )
                    pendingHLSClaim = nil
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
                if audioArchiveEnabled,
                    let audioArchiveStore,
                    chunk.audioFormat.payloadKind == .linearPCM
                {
                    do {
                        _ = try audioArchiveStore.archive(
                            frame: SharedPCMFrame(streamID: streamID, chunk: chunk),
                            runID: runID,
                            chunkID: chunkID
                        )
                    } catch {
                        chunkDiagnostics.append(
                            diagnostic(
                                streamID: streamID,
                                phase: .persist,
                                severity: .warning,
                                reason: "audio-archive-write-failed",
                                source: redactedSource,
                                streamType: streamType,
                                context: [
                                    "archiveError": .string(
                                        IngestRedaction.redact(String(describing: error)))
                                ]
                            )
                        )
                    }
                }
                var fingerprints: [AudioFingerprintDraft] = []
                var songPlays: [SongPlayDraft] = []
                do {
                    try Task.checkCancellation()
                    let fingerprintRequest = AudioFingerprintRequest(
                        source: redactedSource,
                        streamType: streamType,
                        streamID: streamID,
                        runID: runID
                    )
                    let fingerprintResult = try await fingerprinter.fingerprint(
                        chunk,
                        request: fingerprintRequest
                    )
                    try validate(fingerprintResult)
                    let enrichment = await fingerprintEnricher.enrich(
                        fingerprintResult,
                        chunk: chunk,
                        request: fingerprintRequest
                    )
                    fingerprints = enrichment.fingerprintResult.fingerprints
                    songPlays = enrichment.fingerprintResult.songPlays
                    chunkDiagnostics.append(
                        contentsOf: enrichment.diagnostics.map { enrichmentDiagnostic in
                            diagnostic(
                                streamID: streamID,
                                phase: .fingerprint,
                                severity: enrichmentDiagnostic.severity,
                                reason: enrichmentDiagnostic.reason,
                                source: redactedSource,
                                streamType: streamType,
                                context: enrichmentDiagnostic.context
                            )
                        }
                    )
                } catch let cancellation as CancellationError {
                    throw cancellation
                } catch {
                    let diagnosticError = error as? IngestDiagnosticError
                    chunkDiagnostics.append(
                        diagnostic(
                            streamID: streamID,
                            phase: diagnosticError?.ingestDiagnosticPhase ?? .fingerprint,
                            severity: .error,
                            reason: diagnosticError?.ingestDiagnosticReason ?? "fingerprint-failed",
                            source: redactedSource,
                            streamType: streamType,
                            context: errorContext(error, chunk: chunk)
                        )
                    )
                }

                let programContext = try programMetadataResolver.resolve(
                    chunk: chunk,
                    fingerprintSongPlays: songPlays
                )
                let timelineAdMarkers = programContext.markers
                songPlays = programContext.songPlays

                var segments: [TranscriptSegmentDraft] = []
                var speakerTurns: [SpeakerTurnDraft] = []
                if programContext.shouldCaptureTranscript(
                    overlapping: chunk,
                    policy: transcriptionPolicy.capturePolicy
                ) {
                    do {
                        try Task.checkCancellation()
                        segments = try await transcriber.transcribe(chunk)
                        let validation = validateAndNormalize(
                            segments, nextSequence: nextSegmentSequence)
                        segments = validation.segments
                        chunkDiagnostics.append(
                            contentsOf: validation.diagnostics.map { template in
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
                                context: terminalContext(
                                    status: .failed, diagnosticCount: diagnostics.count + 1,
                                    phase: phase, reason: reason)
                            )
                            throw error
                        }
                        chunkDiagnostics.append(providerDiagnostic)
                        segments = []
                    }

                    do {
                        try Task.checkCancellation()
                        speakerTurns = try await diarizer.diarize(chunk, transcriptSegments: segments)
                        segments = applySpeakerTurns(
                            speakerTurns,
                            to: segments,
                            startingSequence: nextSegmentSequence
                        )
                        nextSegmentSequence += segments.count
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
                                context: terminalContext(
                                    status: .failed,
                                    diagnosticCount: diagnostics.count + chunkDiagnostics.count + 1,
                                    phase: phase, reason: reason)
                            )
                            throw error
                        }
                        chunkDiagnostics.append(providerDiagnostic)
                        speakerTurns = []
                        nextSegmentSequence += segments.count
                    }
                }

                try persistence.persistTimeline(
                    IngestChunkTimeline(
                        runID: runID,
                        chunkID: chunkID,
                        segments: segments,
                        speakerTurns: speakerTurns,
                        adMarkers: redactedMarkers(timelineAdMarkers),
                        diagnostics: chunkDiagnostics,
                        fingerprints: fingerprints,
                        songPlays: songPlays,
                        createdAt: now()
                    )
                )
                try finalizeHLSClaimIfNeeded(
                    processedHLSClaim,
                    persistence: persistence,
                    streamID: streamID,
                    runID: runID,
                    chunkID: chunkID
                )
                pendingHLSClaim = nil
                diagnostics.append(contentsOf: chunkDiagnostics)
                processedChunks += 1
            }

            try finishRunOnce(
                status: .completed,
                context: terminalContext(status: .completed, diagnosticCount: diagnostics.count)
            )
            return StreamIngestResult(
                streamID: streamID, runID: runID, processedChunks: processedChunks,
                diagnostics: diagnostics)
        } catch is CancellationError {
            abandonHLSClaimIfNeeded(pendingHLSClaim, persistence: persistence, streamID: streamID, runID: runID)
            let diagnostic = self.diagnostic(
                streamID: streamID,
                phase: .decode,
                severity: .error,
                reason: "ingest-cancelled",
                source: redactedSource,
                streamType: streamType,
                context: [
                    "processedChunks": .number(Double(processedChunks)),
                    "error": .string("CancellationError"),
                ]
            )
            try? finishRunOnce(
                status: .cancelled,
                diagnostic: diagnostic,
                context: terminalContext(
                    status: .cancelled, diagnosticCount: diagnostics.count + 1, phase: .decode,
                    reason: "ingest-cancelled")
            )
            throw CancellationError()
        } catch {
            abandonHLSClaimIfNeeded(pendingHLSClaim, persistence: persistence, streamID: streamID, runID: runID)
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
                context: terminalContext(
                    status: .failed, diagnosticCount: diagnostics.count + 1, phase: phase,
                    reason: reason)
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
                guard word.startSeconds >= previousStart, word.endSeconds >= word.startSeconds
                else {
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
                            "invalidWordCount": .number(Double(invalidWordCount)),
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

    private func applySpeakerTurns(
        _ turns: [SpeakerTurnDraft],
        to segments: [TranscriptSegmentDraft],
        startingSequence: Int
    ) -> [TranscriptSegmentDraft] {
        guard !turns.isEmpty else { return segments }
        let sortedTurns = turns.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            if $0.endSeconds != $1.endSeconds { return $0.endSeconds < $1.endSeconds }
            return $0.speakerLabel < $1.speakerLabel
        }

        let splitSegments = segments.flatMap { segment in
            let segmentSpeaker = speakerLabel(
                forStart: segment.startSeconds,
                end: segment.endSeconds,
                in: sortedTurns
            ) ?? segment.speakerLabel
            var updated = segment
            updated.speakerLabel = segmentSpeaker
            updated.words = segment.words.map { word in
                var updatedWord = word
                updatedWord.speakerLabel = speakerLabel(
                    forStart: word.startSeconds,
                    end: word.endSeconds,
                    in: sortedTurns
                ) ?? segmentSpeaker
                return updatedWord
            }
            return splitSegmentBySpeaker(updated)
        }
        return splitSegments.enumerated().map { offset, segment in
            var renumbered = segment
            renumbered.sequence = startingSequence + offset
            return renumbered
        }
    }

    private func splitSegmentBySpeaker(
        _ segment: TranscriptSegmentDraft
    ) -> [TranscriptSegmentDraft] {
        guard !segment.words.isEmpty else { return [segment] }
        var groups: [[TranscriptWordDraft]] = []
        for word in segment.words {
            if let last = groups.last,
               last.last?.speakerLabel == word.speakerLabel {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        guard groups.count > 1 else { return [segment] }

        return groups.enumerated().map { offset, words in
            let text = words.map(\.text).joined(separator: " ")
            let speakerLabel = words.first?.speakerLabel ?? segment.speakerLabel
            let wordConfidences = words.map(\.confidence).compactMap { $0 }
            return TranscriptSegmentDraft(
                sequence: segment.sequence + offset,
                speakerLabel: speakerLabel,
                startSeconds: words.first?.startSeconds ?? segment.startSeconds,
                endSeconds: words.last?.endSeconds ?? segment.endSeconds,
                text: text.isEmpty ? segment.text : text,
                confidence: wordConfidences.min() ?? segment.confidence,
                words: words.enumerated().map { wordOffset, word in
                    var updatedWord = word
                    updatedWord.sequence = wordOffset
                    return updatedWord
                }
            )
        }
    }

    private func speakerLabel(
        forStart startSeconds: Double,
        end endSeconds: Double,
        in turns: [SpeakerTurnDraft]
    ) -> String? {
        let midpoint = (startSeconds + endSeconds) / 2
        if let containing = turns.first(where: {
            $0.startSeconds <= midpoint && $0.endSeconds >= midpoint
        }) {
            return containing.speakerLabel
        }
        var bestLabel: String?
        var bestOverlap = 0.0
        for turn in turns {
            let overlap = max(0, min(endSeconds, turn.endSeconds) - max(startSeconds, turn.startSeconds))
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestLabel = turn.speakerLabel
            }
        }
        return bestLabel
    }

    private func validate(_ fingerprintResult: AudioFingerprintResult) throws {
        for fingerprint in fingerprintResult.fingerprints {
            guard !fingerprint.algorithm.isEmpty else {
                throw FingerprintOutputValidationError(
                    reason: "malformed-fingerprint-output", detail: "empty algorithm")
            }
            guard !fingerprint.algorithmVersion.isEmpty else {
                throw FingerprintOutputValidationError(
                    reason: "malformed-fingerprint-output", detail: "empty algorithm version")
            }
            guard !fingerprint.fingerprint.isEmpty else {
                throw FingerprintOutputValidationError(
                    reason: "malformed-fingerprint-output", detail: "empty fingerprint")
            }
            guard !fingerprint.fingerprintHash.isEmpty else {
                throw FingerprintOutputValidationError(
                    reason: "malformed-fingerprint-output", detail: "empty fingerprint hash")
            }
            guard fingerprint.endSeconds >= fingerprint.startSeconds else {
                throw FingerprintOutputValidationError(
                    reason: "malformed-fingerprint-output", detail: "invalid fingerprint interval")
            }
        }

        for play in fingerprintResult.songPlays {
            guard !play.song.songKey.isEmpty else {
                throw FingerprintOutputValidationError(
                    reason: "malformed-fingerprint-output", detail: "empty song key")
            }
            guard !play.song.displayName.isEmpty else {
                throw FingerprintOutputValidationError(
                    reason: "malformed-fingerprint-output", detail: "empty song display name")
            }
            guard play.endSeconds >= play.startSeconds else {
                throw FingerprintOutputValidationError(
                    reason: "malformed-fingerprint-output", detail: "invalid song play interval")
            }
        }
    }

    private struct HLSProcessedClaim {
        var mediaSequence: Int?
    }

    private func hlsClaim(
        for chunk: DecodedAudioChunk,
        streamID: Int64,
        runID: Int64
    ) -> HLSSegmentClaim? {
        guard deduplicatesHLSSegments, let identity = chunk.hlsIdentity else { return nil }
        return HLSSegmentClaim(
            streamID: streamID,
            runID: runID,
            mediaSequence: identity.mediaSequence,
            segmentIdentity: identity.segmentIdentity,
            claimedAt: now()
        )
    }

    private func hlsDiagnosticDraft(
        _ claimDiagnostic: HLSSegmentClaimDiagnostic,
        streamID: Int64,
        source: String,
        streamType: StreamType
    ) -> IngestDiagnosticDraft {
        diagnostic(
            streamID: streamID,
            phase: .persist,
            severity: claimDiagnostic.severity,
            reason: claimDiagnostic.reason,
            source: source,
            streamType: streamType,
            context: claimDiagnostic.context
        )
    }

    private func finalizeHLSClaimIfNeeded(
        _ claim: HLSProcessedClaim?,
        persistence: IngestPersistence,
        streamID: Int64,
        runID: Int64,
        chunkID: Int64
    ) throws {
        guard let mediaSequence = claim?.mediaSequence else { return }
        try persistence.finalizeHLSSegmentClaim(
            streamID: streamID,
            mediaSequence: mediaSequence,
            runID: runID,
            chunkID: chunkID,
            finalizedAt: now()
        )
    }

    private func abandonHLSClaimIfNeeded(
        _ claim: HLSProcessedClaim?,
        persistence: IngestPersistence,
        streamID: Int64,
        runID: Int64
    ) {
        guard let mediaSequence = claim?.mediaSequence else { return }
        try? persistence.abandonUnfinalizedHLSSegmentClaim(
            streamID: streamID,
            mediaSequence: mediaSequence,
            runID: runID
        )
    }

    private func minimumHLSMediaSequence(
        streamID: Int64,
        streamType: StreamType,
        persistence: IngestPersistence
    ) -> Int? {
        guard streamType == .hls else { return nil }
        guard let last = try? persistence.lastPersistedHLSMediaSequence(streamID: streamID) else {
            return nil
        }
        return last + 1
    }

	    private func hlsTimelineStartSeconds(
	        streamID: Int64,
	        streamType: StreamType,
	        persistence: IngestPersistence
	    ) -> Double? {
        guard streamType == .hls else { return nil }
	        return try? persistence.lastPersistedHLSTimelineEndSeconds(streamID: streamID)
	    }

	    private func excludedHLSSegmentKeys(
	        streamID: Int64,
	        streamType: StreamType,
	        persistence: IngestPersistence
	    ) -> Set<HLSDecodedAudioSegmentKey> {
	        guard streamType == .hls else { return [] }
	        return (try? persistence.persistedHLSSegmentKeys(streamID: streamID)) ?? []
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
            "error": .string(IngestRedaction.redact(String(describing: error))),
        ]
    }

    private func chunkContext(_ chunk: DecodedAudioChunk) -> [String: JSONValue] {
        var context: [String: JSONValue] = [
            "startSeconds": .number(chunk.startSeconds),
            "endSeconds": .number(chunk.endSeconds),
        ]
        if let hlsIdentity = chunk.hlsIdentity {
            var hls: [String: JSONValue] = [
                "mediaSequence": .number(Double(hlsIdentity.mediaSequence)),
                "segmentIdentity": .string(hlsIdentity.segmentIdentity),
            ]
            if let manifestPosition = hlsIdentity.manifestPosition {
                hls["manifestPosition"] = .number(Double(manifestPosition))
            }
            context["hls"] = .object(hls)
        }
        return IngestRedaction.context(context) ?? context
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
        var seen = Set<String>()
        return markers.compactMap { marker in
            let key = markerDeduplicationKey(marker)
            var redacted = marker
            redacted.segment = redactedSourceDescription(marker.segment)
            redacted.rawBase64 = marker.rawBase64 == nil ? nil : "[redacted]"
            guard seen.insert(key).inserted else { return nil }
            return redacted
        }
    }

    private func markerDeduplicationKey(_ marker: AdMarker) -> String {
        [
            marker.classification.rawValue,
            marker.type,
            marker.pts.map { String(format: "%.6f", $0) } ?? "",
            marker.segment ?? "",
            marker.rawBase64 ?? "",
            marker.tag ?? "",
        ].joined(separator: "|")
    }

    private func redactedSourceDescription(_ value: String?) -> String? {
        guard let value else { return nil }
        return IngestRedaction.sourceDescription(value)
    }

    private func resolvedStreamType(for source: String, requested streamType: StreamType)
        -> StreamType
    {
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

private struct FingerprintOutputValidationError: Error, CustomStringConvertible,
    IngestDiagnosticError
{
    var ingestDiagnosticPhase: IngestDiagnosticPhase { .fingerprint }
    let ingestDiagnosticReason: String
    let detail: String

    init(reason: String, detail: String) {
        self.ingestDiagnosticReason = reason
        self.detail = detail
    }

    var description: String {
        "\(ingestDiagnosticReason): \(detail)"
    }
}
