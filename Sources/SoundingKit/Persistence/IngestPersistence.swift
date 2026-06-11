import Foundation
import GRDB

/// GRDB-backed writer for M002 ingest state.
///
/// The writer uses one database transaction per public write call. `persistTimeline`
/// intentionally writes all rows for a decoded chunk together, so partial segment,
/// word, speaker, marker, or diagnostic rows roll back when any row violates a
/// constraint.
public struct IngestPersistence {
    private let database: SoundingDatabase
    private let songPlayStore: SongPlayStore
    private let jsonEncoder: JSONEncoder

    public init(database: SoundingDatabase) {
        self.database = database
        self.songPlayStore = SongPlayStore(database: database)
        self.jsonEncoder = JSONEncoder()
    }

    public func createStream(
        streamType: String,
        source: String,
        createdAt: String,
        updatedAt: String? = nil
    ) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO streams (stream_type, source, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [streamType, source, createdAt, updatedAt ?? createdAt]
            )
            return db.lastInsertedRowID
        }
    }

    public func createRun(
        streamID: Int64,
        startedAt: String,
        status: IngestRunStatus,
        context: [String: JSONValue]? = nil
    ) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ingest_runs (stream_id, started_at, ended_at, status, context_json)
                    VALUES (?, ?, NULL, ?, ?)
                    """,
                arguments: [streamID, startedAt, status.rawValue, try jsonString(context)]
            )
            return db.lastInsertedRowID
        }
    }

    public func finishRun(
        runID: Int64,
        endedAt: String,
        status: IngestRunStatus,
        context: [String: JSONValue]? = nil
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE ingest_runs
                    SET ended_at = ?, status = ?, context_json = COALESCE(?, context_json)
                    WHERE id = ?
                    """,
                arguments: [endedAt, status.rawValue, try jsonString(context), runID]
            )
        }
    }

    public func createChunk(
        runID: Int64,
        sequence: Int,
        segmentURI: String? = nil,
        byteCount: Int? = nil,
        startedAt: String,
        endedAt: String? = nil,
        context: [String: JSONValue]? = nil
    ) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ingest_chunks (run_id, sequence, segment_uri, byte_count, started_at, ended_at, context_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    runID,
                    sequence,
                    segmentURI,
                    byteCount,
                    startedAt,
                    endedAt,
                    try jsonString(context)
                ]
            )
            return db.lastInsertedRowID
        }
    }

    public func lastPersistedHLSMediaSequence(streamID: Int64) throws -> Int? {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT MAX(media_sequence)
                    FROM hls_ingest_segments
                    WHERE stream_id = ?
                    """,
                arguments: [streamID]
            )
        }
    }

    public func lastPersistedHLSTimelineEndSeconds(streamID: Int64) throws -> Double? {
        try database.read { db in
            try Double.fetchOne(
                db,
                sql: """
                    SELECT MAX(json_extract(ingest_chunks.context_json, '$.endSeconds'))
                    FROM hls_ingest_segments
                    JOIN ingest_chunks ON ingest_chunks.id = hls_ingest_segments.chunk_id
                    WHERE hls_ingest_segments.stream_id = ?
                    """,
                arguments: [streamID]
            )
        }
    }

    public func hasPersistedHLSSegment(streamID: Int64, mediaSequence: Int) throws -> Bool {
        guard streamID > 0, mediaSequence >= 0 else { return false }
        return try database.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM hls_ingest_segments
                        WHERE stream_id = ?
                          AND media_sequence = ?
                    )
                    """,
                arguments: [streamID, mediaSequence]
            ) ?? false
        }
    }

    public func hasPersistedHLSSegment(
        streamID: Int64,
        mediaSequence: Int,
        segmentIdentity: String
    ) throws -> Bool {
        guard streamID > 0, mediaSequence >= 0 else { return false }
        let segmentIdentity = sanitizedHLSIdentity(segmentIdentity)
        guard !segmentIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try hasPersistedHLSSegment(streamID: streamID, mediaSequence: mediaSequence)
        }
        let segmentIdentityHash = stableHash(segmentIdentity)
        return try database.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM hls_ingest_segments
                        WHERE stream_id = ?
                          AND media_sequence = ?
                          AND segment_identity = ?
                          AND segment_identity_hash = ?
                    )
                    """,
                arguments: [streamID, mediaSequence, segmentIdentity, segmentIdentityHash]
            ) ?? false
        }
    }

    public func persistedHLSSegmentKeys(streamID: Int64) throws -> Set<HLSDecodedAudioSegmentKey> {
        guard streamID > 0 else { return [] }
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT media_sequence, segment_identity
                    FROM hls_ingest_segments
                    WHERE stream_id = ?
                    """,
                arguments: [streamID]
            )
            return Set(rows.compactMap { row in
                let segmentIdentity = row["segment_identity"] as String? ?? ""
                guard !segmentIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return HLSDecodedAudioSegmentKey(
                    mediaSequence: row["media_sequence"] as Int,
                    segmentIdentity: segmentIdentity
                )
            })
        }
    }

    public func claimHLSSegment(_ claim: HLSSegmentClaim?) throws -> HLSSegmentClaimResult {
        guard let claim else { return .noClaim }
        guard claim.streamID > 0, claim.mediaSequence >= 0 else { return .noClaim }

        let segmentIdentity = sanitizedHLSIdentity(claim.segmentIdentity)
        guard !segmentIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noClaim
        }
        let segmentIdentityHash = stableHash(segmentIdentity)

        return try database.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT segment_identity, segment_identity_hash, claimed_run_id, chunk_id
                    FROM hls_ingest_segments
                    WHERE stream_id = ? AND media_sequence = ?
                    LIMIT 1
                    """,
                arguments: [claim.streamID, claim.mediaSequence]
            ) {
                let existingRunID = existing["claimed_run_id"] as Int64?
                let existingChunkID = existing["chunk_id"] as Int64?
                let existingIdentity = existing["segment_identity"] as String? ?? ""
                let existingIdentityHash = existing["segment_identity_hash"] as String? ?? ""

                if existingIdentity == segmentIdentity && existingIdentityHash == segmentIdentityHash {
                    let diagnostic = HLSSegmentClaimDiagnostic(
                        severity: .info,
                        reason: "hls-segment-duplicate",
                        context: hlsDecisionContext(
                            decision: "duplicate-skip",
                            mediaSequence: claim.mediaSequence,
                            segmentIdentity: segmentIdentity,
                            segmentIdentityHash: segmentIdentityHash,
                            existingSegmentIdentity: existingIdentity,
                            existingSegmentIdentityHash: existingIdentityHash,
                            currentRunID: claim.runID,
                            existingRunID: existingRunID,
                            existingChunkID: existingChunkID
                        )
                    )
                    try insertHLSDecisionDiagnostic(
                        diagnostic,
                        streamID: claim.streamID,
                        runID: claim.runID,
                        chunkID: existingChunkID,
                        createdAt: claim.claimedAt,
                        db: db
                    )
                    return .duplicate(
                        existingRunID: existingRunID,
                        existingChunkID: existingChunkID,
                        diagnostic: diagnostic
                    )
                }

                let diagnostic = HLSSegmentClaimDiagnostic(
                    severity: .warning,
                    reason: "hls-media-sequence-reset",
                    context: hlsDecisionContext(
                        decision: "sequence-reset-reclaim",
                        mediaSequence: claim.mediaSequence,
                        segmentIdentity: segmentIdentity,
                        segmentIdentityHash: segmentIdentityHash,
                        existingSegmentIdentity: existingIdentity,
                        existingSegmentIdentityHash: existingIdentityHash,
                        currentRunID: claim.runID,
                        existingRunID: existingRunID,
                        existingChunkID: existingChunkID
                    )
                )
                try insertHLSDecisionDiagnostic(
                    diagnostic,
                    streamID: claim.streamID,
                    runID: claim.runID,
                    chunkID: existingChunkID,
                    createdAt: claim.claimedAt,
                    db: db
                )
                try db.execute(
                    sql: """
                        UPDATE hls_ingest_segments
                        SET segment_identity = ?,
                            segment_identity_hash = ?,
                            claimed_run_id = ?,
                            chunk_id = NULL,
                            claimed_at = ?,
                            finalized_at = NULL,
                            updated_at = ?
                        WHERE stream_id = ?
                          AND media_sequence = ?
                        """,
                    arguments: [
                        segmentIdentity,
                        segmentIdentityHash,
                        claim.runID,
                        claim.claimedAt,
                        claim.claimedAt,
                        claim.streamID,
                        claim.mediaSequence
                    ]
                )
                return .claimed(diagnostics: [diagnostic])
            }

            var diagnostics: [HLSSegmentClaimDiagnostic] = []
            let previousMediaSequence = try Int.fetchOne(
                db,
                sql: """
                    SELECT MAX(media_sequence)
                    FROM hls_ingest_segments
                    WHERE stream_id = ?
                    """,
                arguments: [claim.streamID]
            )
            if let previousMediaSequence, claim.mediaSequence > previousMediaSequence + 1 {
                let diagnostic = HLSSegmentClaimDiagnostic(
                    severity: .warning,
                    reason: "hls-media-sequence-gap",
                    context: hlsDecisionContext(
                        decision: "sequence-gap",
                        mediaSequence: claim.mediaSequence,
                        segmentIdentity: segmentIdentity,
                        segmentIdentityHash: segmentIdentityHash,
                        previousMediaSequence: previousMediaSequence,
                        expectedMediaSequence: previousMediaSequence + 1,
                        observedMediaSequence: claim.mediaSequence,
                        currentRunID: claim.runID
                    )
                )
                try insertHLSDecisionDiagnostic(
                    diagnostic,
                    streamID: claim.streamID,
                    runID: claim.runID,
                    chunkID: nil,
                    createdAt: claim.claimedAt,
                    db: db
                )
                diagnostics.append(diagnostic)
            }

            try db.execute(
                sql: """
                    INSERT INTO hls_ingest_segments (
                        stream_id, media_sequence, segment_identity, segment_identity_hash,
                        claimed_run_id, chunk_id, claimed_at, finalized_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, NULL, ?, NULL, ?)
                    """,
                arguments: [
                    claim.streamID,
                    claim.mediaSequence,
                    segmentIdentity,
                    segmentIdentityHash,
                    claim.runID,
                    claim.claimedAt,
                    claim.claimedAt
                ]
            )
            return .claimed(diagnostics: diagnostics)
        }
    }

    public func finalizeHLSSegmentClaim(
        streamID: Int64,
        mediaSequence: Int,
        runID: Int64,
        chunkID: Int64,
        finalizedAt: String
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE hls_ingest_segments
                    SET claimed_run_id = COALESCE(claimed_run_id, ?),
                        chunk_id = ?,
                        finalized_at = ?,
                        updated_at = ?
                    WHERE stream_id = ?
                      AND media_sequence = ?
                    """,
                arguments: [runID, chunkID, finalizedAt, finalizedAt, streamID, mediaSequence]
            )
            guard db.changesCount > 0 else {
                throw PersistenceError.missingHLSSegmentClaim(streamID: streamID, mediaSequence: mediaSequence)
            }
        }
    }

    public func abandonUnfinalizedHLSSegmentClaim(
        streamID: Int64,
        mediaSequence: Int,
        runID: Int64
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    DELETE FROM hls_ingest_segments
                    WHERE stream_id = ?
                      AND media_sequence = ?
                      AND claimed_run_id = ?
                      AND chunk_id IS NULL
                      AND finalized_at IS NULL
                    """,
                arguments: [streamID, mediaSequence, runID]
            )
        }
    }

    public func persistTimeline(_ timeline: IngestChunkTimeline) throws {
        try database.write { db in
            for segment in timeline.segments {
                let segmentID = try insertSegment(segment, timeline: timeline, db: db)
                try insertSearchText(forSegmentID: segmentID, segment: segment, db: db)
                for word in segment.words {
                    try insertWord(word, segmentID: segmentID, chunkID: timeline.chunkID, db: db)
                }
            }

            for speakerTurn in timeline.speakerTurns {
                try insertSpeakerTurn(speakerTurn, timeline: timeline, db: db)
            }

            for marker in timelineMarkersForPersistence(timeline, db: db) {
                try insertAdMarker(marker, timeline: timeline, db: db)
            }

            for diagnostic in timeline.diagnostics {
                try insertDiagnostic(diagnostic, timeline: timeline, db: db)
            }

            if !timeline.fingerprints.isEmpty || !timeline.songPlays.isEmpty {
                let streamID = try streamID(forRunID: timeline.runID, db: db)

                for fingerprint in timeline.fingerprints {
                    try insertFingerprint(fingerprint, streamID: streamID, timeline: timeline, db: db)
                }

                for play in timeline.songPlays {
                    try songPlayStore.persist(
                        play,
                        streamID: streamID,
                        timeline: timeline,
                        db: db
                    )
                }
            }
        }
    }

    private func timelineMarkersForPersistence(_ timeline: IngestChunkTimeline, db: Database) -> [AdMarker] {
        let streamID = try? streamID(forRunID: timeline.runID, db: db)
        return timeline.adMarkers.filter { marker in
            if marker.classification == .unknown,
               let metadata = ProgramMetadataExtractor.metadata(from: marker),
               metadata.classification == .music {
                if timeline.songPlays.contains(where: { metadataMatchesSongPlay(metadata, $0) }) {
                    return false
                }
                if let streamID,
                   metadataMatchesActiveTimedSongPlay(metadata, streamID: streamID, marker: marker, db: db) {
                    return false
                }
            }

            if isRepeatedGenericAdMarker(marker, streamID: streamID, db: db) {
                return false
            }

            return true
        }
    }

    private func metadataMatchesActiveTimedSongPlay(
        _ metadata: ProgramMetadata,
        streamID: Int64,
        marker: AdMarker,
        db: Database,
        toleranceSeconds: Double = 180
    ) -> Bool {
        guard let pts = marker.pts else { return false }
        let normalizedTitle = normalizedMetadataText(metadata.title)
        guard !normalizedTitle.isEmpty else { return false }
        let normalizedArtist = normalizedMetadataText(metadata.artist)
        let rows = (try? Row.fetchAll(
            db,
            sql: """
                SELECT songs.title, songs.artist, songs.display_name
                FROM song_plays
                JOIN songs ON songs.id = song_plays.song_id
                WHERE song_plays.stream_id = ?
                  AND songs.is_unknown = 0
                  AND LOWER(REPLACE(song_plays.source, '-', '_')) IN (
                      'timed_id3', 'id3', 'scte35', 'scte', 'icy', 'icecast', 'icy_stream'
                  )
                  AND song_plays.end_seconds >= ?
                  AND song_plays.start_seconds <= ?
                ORDER BY song_plays.end_seconds DESC, song_plays.id DESC
                LIMIT 8
                """,
            arguments: [streamID, pts - toleranceSeconds, pts + toleranceSeconds]
        )) ?? []

        return rows.contains { row in
            let rowTitle = normalizedMetadataText((row["title"] as String?) ?? (row["display_name"] as String?))
            guard rowTitle == normalizedTitle else { return false }
            let rowArtist = normalizedMetadataText(row["artist"] as String?)
            return normalizedArtist.isEmpty || rowArtist.isEmpty || normalizedArtist == rowArtist
        }
    }

    private func isRepeatedGenericAdMarker(_ marker: AdMarker, streamID: Int64?, db: Database) -> Bool {
        let duplicateClassifications: Set<MarkerClassification> = [.unknown, .adStart, .adEnd]
        guard duplicateClassifications.contains(marker.classification),
              let streamID,
              isGenericAdMarker(marker)
        else {
            return false
        }

        guard let pts = marker.pts else { return false }
        let markerTitle = ProgramMetadataExtractor.metadata(from: marker)?.title ?? "AD"
        let existing = try? Int.fetchOne(
            db,
            sql: """
                SELECT 1
                FROM ad_events
                JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
                WHERE ingest_runs.stream_id = ?
                  AND ad_events.pts IS NOT NULL
                  AND ad_events.classification IN (?, ?, ?)
                  AND ABS(ad_events.pts - ?) <= 90
                  AND (
                    lower(json_extract(ad_events.payload_json, '$.Tags.TIT2')) = lower(?)
                    OR lower(json_extract(ad_events.payload_json, '$.Fields.Title')) = lower(?)
                    OR lower(json_extract(ad_events.payload_json, '$.Fields.StreamTitle')) = lower(?)
                    OR lower(ad_events.payload_json) LIKE '%advertisement%'
                  )
                LIMIT 1
                """,
            arguments: [
                streamID,
                MarkerClassification.unknown.rawValue,
                MarkerClassification.adStart.rawValue,
                MarkerClassification.adEnd.rawValue,
                pts,
                markerTitle,
                markerTitle,
                markerTitle
            ]
        )
        return existing != nil
    }

    private func isGenericAdMarker(_ marker: AdMarker) -> Bool {
        let metadata = ProgramMetadataExtractor.metadata(from: marker)
        let metadataValues = [metadata?.title, metadata?.artist, metadata?.album].compactMap { $0 }
        let joined = (metadataValues + markerTextCandidates(marker)).joined(separator: " ").lowercased()
        return joined.contains("advertisement")
            || joined.contains("commercial")
            || joined.contains("promo")
            || joined.split { !$0.isLetter && !$0.isNumber }.contains("ad")
    }

    private func markerTextCandidates(_ marker: AdMarker) -> [String] {
        var candidates = marker.tags.values.compactMap(nonEmptyString)
        candidates.append(contentsOf: marker.fields.values.compactMap(nonEmptyString))
        if case let .array(frames)? = marker.fields["Frames"] {
            for frame in frames {
                guard case let .object(frameObject) = frame else { continue }
                candidates.append(contentsOf: frameObject.values.compactMap(nonEmptyString))
                if case let .array(texts)? = frameObject["Texts"] {
                    candidates.append(contentsOf: texts.compactMap(nonEmptyString))
                }
            }
        }
        return candidates
    }

    private func nonEmptyString(_ value: JSONValue) -> String? {
        guard case let .string(raw) = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func metadataMatchesSongPlay(_ metadata: ProgramMetadata, _ play: SongPlayDraft) -> Bool {
        guard normalizedMetadataText(metadata.title) == normalizedMetadataText(play.song.title ?? play.song.displayName)
        else {
            return false
        }
        let metadataArtist = normalizedMetadataText(metadata.artist)
        let playArtist = normalizedMetadataText(play.song.artist)
        return metadataArtist.isEmpty || playArtist.isEmpty || metadataArtist == playArtist
    }

    private func normalizedMetadataText(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public func activeTimedMetadataSongPlay(
        streamID: Int64,
        startSeconds: Double,
        endSeconds: Double,
        toleranceSeconds: Double = 15
    ) throws -> SongPlayDraft? {
        try songPlayStore.activeTimedMetadataSongPlay(
            streamID: streamID,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            toleranceSeconds: toleranceSeconds
        )
    }

    public func activeAdBreakOverlaps(
        streamID: Int64,
        startSeconds: Double,
        endSeconds: Double
    ) throws -> Bool {
        try database.read { db in
            let boundaryInWindow = try Int.fetchOne(
                db,
                sql: """
                    SELECT 1
                    FROM ad_events
                    JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
                    WHERE ingest_runs.stream_id = ?
                      AND ad_events.pts IS NOT NULL
                      AND ad_events.classification IN (?, ?)
                      AND ad_events.pts >= ?
                      AND ad_events.pts <= ?
                    LIMIT 1
                    """,
                arguments: [
                    streamID,
                    MarkerClassification.adStart.rawValue,
                    MarkerClassification.adEnd.rawValue,
                    startSeconds,
                    endSeconds
                ]
            )
            if boundaryInWindow != nil {
                return true
            }

            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        ad_events.classification,
                        ad_events.pts,
                        COALESCE(
                            json_extract(ad_events.payload_json, '$.BreakDuration'),
                            json_extract(ad_events.payload_json, '$.Fields.BreakDuration'),
                            json_extract(ad_events.payload_json, '$.Command.BreakDuration'),
                            CAST(json_extract(ad_events.payload_json, '$.Fields.durationMilliseconds') AS REAL) / 1000.0,
                            CAST(json_extract(ad_events.payload_json, '$.Fields.DurationMilliseconds') AS REAL) / 1000.0,
                            CAST(json_extract(ad_events.payload_json, '$.Fields.durationMs') AS REAL) / 1000.0,
                            CAST(json_extract(ad_events.payload_json, '$.Fields.DurationMs') AS REAL) / 1000.0
                        ) AS break_duration
                    FROM ad_events
                    JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
                    WHERE ingest_runs.stream_id = ?
                      AND ad_events.pts IS NOT NULL
                      AND ad_events.classification IN (?, ?)
                      AND ad_events.pts <= ?
                    ORDER BY ad_events.pts DESC, ad_events.observed_at DESC, ad_events.id DESC
                    LIMIT 1
                    """,
                arguments: [
                    streamID,
                    MarkerClassification.adStart.rawValue,
                    MarkerClassification.adEnd.rawValue,
                    startSeconds
                ]
            ) else {
                return false
            }

            let classification: String? = row["classification"]
            guard classification == MarkerClassification.adStart.rawValue else {
                return false
            }
            let pts: Double? = row["pts"]
            let breakDuration: Double? = row["break_duration"]
            guard let pts, let breakDuration, breakDuration.isFinite, breakDuration > 0 else {
                return true
            }
            let toleranceSeconds = 2.0
            return startSeconds <= pts + breakDuration + toleranceSeconds
        }
    }

    private func insertSegment(
        _ segment: TranscriptSegmentDraft,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO transcript_segments (
                    run_id, chunk_id, sequence, speaker_label, start_seconds,
                    end_seconds, text, confidence, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                timeline.runID,
                timeline.chunkID,
                segment.sequence,
                segment.speakerLabel,
                segment.startSeconds,
                segment.endSeconds,
                segment.text,
                segment.confidence,
                timeline.createdAt
            ]
        )
        return db.lastInsertedRowID
    }

    private func insertSearchText(
        forSegmentID segmentID: Int64,
        segment: TranscriptSegmentDraft,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO transcript_segments_fts (rowid, text, speaker_label)
                VALUES (?, ?, ?)
                """,
            arguments: [segmentID, segment.text, segment.speakerLabel]
        )
    }

    private func insertWord(
        _ word: TranscriptWordDraft,
        segmentID: Int64,
        chunkID: Int64,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO transcript_words (
                    segment_id, chunk_id, sequence, speaker_label, start_seconds,
                    end_seconds, text, confidence
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                segmentID,
                chunkID,
                word.sequence,
                word.speakerLabel,
                word.startSeconds,
                word.endSeconds,
                word.text,
                word.confidence
            ]
        )
    }

    private func insertSpeakerTurn(
        _ turn: SpeakerTurnDraft,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO speaker_turns (
                    run_id, chunk_id, speaker_label, start_seconds,
                    end_seconds, confidence, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                timeline.runID,
                timeline.chunkID,
                turn.speakerLabel,
                turn.startSeconds,
                turn.endSeconds,
                turn.confidence,
                timeline.createdAt
            ]
        )
    }

    private func insertAdMarker(
        _ marker: AdMarker,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ad_events (
                    run_id, chunk_id, classification, marker_type, source, pts,
                    segment, raw_base64, payload_json, observed_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                timeline.runID,
                timeline.chunkID,
                marker.classification.rawValue,
                marker.type,
                marker.source,
                marker.pts,
                marker.segment,
                marker.rawBase64,
                try jsonString(marker),
                marker.timestamp ?? timeline.createdAt
            ]
        )
    }

    private func insertDiagnostic(
        _ diagnostic: IngestDiagnosticDraft,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ingest_diagnostics (
                    stream_id, run_id, chunk_id, phase, severity, reason, source,
                    source_class, stream_type, context_json, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                diagnostic.streamID,
                timeline.runID,
                timeline.chunkID,
                diagnostic.phase.rawValue,
                diagnostic.severity.rawValue,
                diagnostic.reason,
                diagnostic.source,
                diagnostic.sourceClass,
                diagnostic.streamType,
                try jsonString(diagnostic.context),
                diagnostic.createdAt
            ]
        )
    }

    private func streamID(forRunID runID: Int64, db: Database) throws -> Int64 {
        guard let streamID = try Int64.fetchOne(
            db,
            sql: "SELECT stream_id FROM ingest_runs WHERE id = ?",
            arguments: [runID]
        ) else {
            throw PersistenceError.missingRun(runID)
        }
        return streamID
    }

    private func insertFingerprint(
        _ fingerprint: AudioFingerprintDraft,
        streamID: Int64,
        timeline: IngestChunkTimeline,
        db: Database
    ) throws {
        guard fingerprint.endSeconds >= fingerprint.startSeconds else {
            throw PersistenceError.invalidTimelineInterval
        }

        try db.execute(
            sql: """
                INSERT INTO audio_fingerprints (
                    stream_id, run_id, chunk_id, algorithm, algorithm_version,
                    fingerprint, fingerprint_hash, start_seconds, end_seconds,
                    confidence, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                streamID,
                timeline.runID,
                timeline.chunkID,
                fingerprint.algorithm,
                fingerprint.algorithmVersion,
                fingerprint.fingerprint,
                fingerprint.fingerprintHash,
                fingerprint.startSeconds,
                fingerprint.endSeconds,
                fingerprint.confidence,
                timeline.createdAt
            ]
        )
    }

    private enum PersistenceError: Error, Equatable {
        case missingRun(Int64)
        case missingHLSSegmentClaim(streamID: Int64, mediaSequence: Int)
        case invalidTimelineInterval
    }

    private func insertHLSDecisionDiagnostic(
        _ diagnostic: HLSSegmentClaimDiagnostic,
        streamID: Int64,
        runID: Int64?,
        chunkID: Int64?,
        createdAt: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ingest_diagnostics (
                    stream_id, run_id, chunk_id, phase, severity, reason, source,
                    source_class, stream_type, context_json, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
                """,
            arguments: [
                streamID,
                runID,
                chunkID,
                IngestDiagnosticPhase.persist.rawValue,
                diagnostic.severity.rawValue,
                diagnostic.reason,
                "hls_segment",
                "hls",
                try jsonString(IngestRedaction.context(diagnostic.context)),
                createdAt
            ]
        )
    }

    private func hlsDecisionContext(
        decision: String,
        mediaSequence: Int,
        segmentIdentity: String,
        segmentIdentityHash: String,
        existingSegmentIdentity: String? = nil,
        existingSegmentIdentityHash: String? = nil,
        previousMediaSequence: Int? = nil,
        expectedMediaSequence: Int? = nil,
        observedMediaSequence: Int? = nil,
        currentRunID: Int64? = nil,
        existingRunID: Int64? = nil,
        existingChunkID: Int64? = nil
    ) -> [String: JSONValue] {
        var context: [String: JSONValue] = [
            "decision": .string(decision),
            "mediaSequence": .number(Double(mediaSequence)),
            "segmentIdentity": .string(segmentIdentity),
            "segmentIdentityHash": .string(segmentIdentityHash)
        ]
        if let existingSegmentIdentity {
            context["existingSegmentIdentity"] = .string(existingSegmentIdentity)
        }
        if let existingSegmentIdentityHash {
            context["existingSegmentIdentityHash"] = .string(existingSegmentIdentityHash)
        }
        if let previousMediaSequence {
            context["previousMediaSequence"] = .number(Double(previousMediaSequence))
        }
        if let expectedMediaSequence {
            context["expectedMediaSequence"] = .number(Double(expectedMediaSequence))
        }
        if let observedMediaSequence {
            context["observedMediaSequence"] = .number(Double(observedMediaSequence))
        }
        if let currentRunID {
            context["currentRunID"] = .number(Double(currentRunID))
        }
        if let existingRunID {
            context["existingRunID"] = .number(Double(existingRunID))
        }
        if let existingChunkID {
            context["existingChunkID"] = .number(Double(existingChunkID))
        }
        return IngestRedaction.context(context) ?? context
    }

    private func sanitizedHLSIdentity(_ identity: String) -> String {
        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../")
            || trimmed.contains("://")
        {
            return IngestRedaction.sourceDescription(trimmed)
        }
        return IngestRedaction.redact(trimmed)
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func jsonString<Value: Encodable>(_ value: Value?) throws -> String? {
        guard let value else { return nil }
        let data = try jsonEncoder.encode(value)
        return String(data: data, encoding: .utf8)
    }
}
