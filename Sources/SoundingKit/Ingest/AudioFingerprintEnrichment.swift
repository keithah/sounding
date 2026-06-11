import Foundation

public protocol AcoustIDLookupCaching: Sendable {
    func fetch(identity: AcoustIDLookupCacheIdentity) throws -> AcoustIDLookupCacheRow?
    func upsert(_ entry: AcoustIDLookupCacheEntry) throws
}

extension AcoustIDLookupCache: AcoustIDLookupCaching {}

public struct AudioFingerprintEnrichmentDiagnostic: Equatable, Sendable {
    public var severity: IngestDiagnosticSeverity
    public var reason: String
    public var context: [String: JSONValue]

    public init(
        severity: IngestDiagnosticSeverity = .warning,
        reason: String,
        context: [String: JSONValue] = [:]
    ) {
        self.severity = severity
        self.reason = reason
        self.context = IngestRedaction.context(context) ?? [:]
    }
}

public struct AudioFingerprintEnrichmentResult: Equatable, Sendable {
    public var fingerprintResult: AudioFingerprintResult
    public var diagnostics: [AudioFingerprintEnrichmentDiagnostic]

    public init(
        fingerprintResult: AudioFingerprintResult,
        diagnostics: [AudioFingerprintEnrichmentDiagnostic] = []
    ) {
        self.fingerprintResult = fingerprintResult
        self.diagnostics = diagnostics
    }
}

public protocol AudioFingerprintEnriching: Sendable {
    func enrich(
        _ result: AudioFingerprintResult,
        chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async -> AudioFingerprintEnrichmentResult
}

public struct NoOpAudioFingerprintEnricher: AudioFingerprintEnriching {
    public init() {}

    public func enrich(
        _ result: AudioFingerprintResult,
        chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async -> AudioFingerprintEnrichmentResult {
        AudioFingerprintEnrichmentResult(fingerprintResult: result)
    }
}

public struct AcoustIDAudioFingerprintEnricher: AudioFingerprintEnriching {
    public typealias TimestampProvider = @Sendable () -> String

    private let cache: any AcoustIDLookupCaching
    private let lookup: any AcoustIDLookuping
    private let now: TimestampProvider

    public init(
        cache: any AcoustIDLookupCaching,
        lookup: any AcoustIDLookuping,
        now: @escaping TimestampProvider = { SoundingTimestampClock.timestamp() }
    ) {
        self.cache = cache
        self.lookup = lookup
        self.now = now
    }

    public func enrich(
        _ result: AudioFingerprintResult,
        chunk: DecodedAudioChunk,
        request: AudioFingerprintRequest
    ) async -> AudioFingerprintEnrichmentResult {
        guard !result.fingerprints.isEmpty, !result.songPlays.isEmpty else {
            return AudioFingerprintEnrichmentResult(fingerprintResult: result)
        }

        var enriched = result
        var diagnostics: [AudioFingerprintEnrichmentDiagnostic] = []

        for fingerprint in result.fingerprints {
            guard let identity = identity(for: fingerprint) else {
                diagnostics.append(
                    diagnostic(
                        reason: "acoustid-malformed-request",
                        fingerprint: fingerprint,
                        chunk: chunk,
                        context: ["detail": "empty fingerprint identity"]
                    )
                )
                continue
            }

            if let match = fetchCachedMatch(identity: identity, fingerprint: fingerprint, chunk: chunk, diagnostics: &diagnostics) {
                apply(match: match, fingerprintHash: identity.fingerprintHash, to: &enriched)
                continue
            }

            let lookupRequest = AcoustIDLookupRequest(
                algorithm: identity.algorithm,
                algorithmVersion: identity.algorithmVersion,
                fingerprint: fingerprint.fingerprint,
                fingerprintHash: identity.fingerprintHash,
                durationSeconds: duration(for: fingerprint)
            )
            let outcome = await lookup.lookup(lookupRequest)
            handle(
                outcome: outcome,
                identity: identity,
                fingerprint: fingerprint,
                chunk: chunk,
                enriched: &enriched,
                diagnostics: &diagnostics
            )
        }

        return AudioFingerprintEnrichmentResult(
            fingerprintResult: enriched,
            diagnostics: diagnostics
        )
    }

    private func fetchCachedMatch(
        identity: AcoustIDLookupCacheIdentity,
        fingerprint: AudioFingerprintDraft,
        chunk: DecodedAudioChunk,
        diagnostics: inout [AudioFingerprintEnrichmentDiagnostic]
    ) -> AcoustIDMatch? {
        do {
            guard let row = try cache.fetch(identity: identity) else { return nil }
            return match(from: row)
        } catch {
            diagnostics.append(
                diagnostic(
                    reason: "acoustid-cache-read-failed",
                    fingerprint: fingerprint,
                    chunk: chunk,
                    context: ["error": .string(String(describing: error))]
                )
            )
            return nil
        }
    }

    private func handle(
        outcome: AcoustIDLookupOutcome,
        identity: AcoustIDLookupCacheIdentity,
        fingerprint: AudioFingerprintDraft,
        chunk: DecodedAudioChunk,
        enriched: inout AudioFingerprintResult,
        diagnostics: inout [AudioFingerprintEnrichmentDiagnostic]
    ) {
        switch outcome {
        case .matched(let match):
            guard isUsable(match) else {
                diagnostics.append(
                    diagnostic(
                        reason: "acoustid-malformed-response",
                        fingerprint: fingerprint,
                        chunk: chunk,
                        context: ["detail": "matched response did not contain usable metadata"]
                    )
                )
                return
            }

            apply(match: match, fingerprintHash: identity.fingerprintHash, to: &enriched)
            do {
                try cache.upsert(entry(from: match, identity: identity))
            } catch {
                diagnostics.append(
                    diagnostic(
                        reason: "acoustid-cache-write-failed",
                        fingerprint: fingerprint,
                        chunk: chunk,
                        context: ["error": .string(String(describing: error))]
                    )
                )
            }
        case .disabled(let reason):
            diagnostics.append(outcomeDiagnostic("acoustid-lookup-disabled", reason: reason, fingerprint: fingerprint, chunk: chunk))
        case .notFound(let reason):
            removeUnknownSongPlay(fingerprintHash: identity.fingerprintHash, from: &enriched)
            diagnostics.append(outcomeDiagnostic("acoustid-not-found", reason: reason, fingerprint: fingerprint, chunk: chunk))
        case .transientFailure(let reason):
            diagnostics.append(outcomeDiagnostic("acoustid-transient-failure", reason: reason, fingerprint: fingerprint, chunk: chunk))
        case .rateLimited(let retryAfterSeconds):
            var context: [String: JSONValue] = [:]
            if let retryAfterSeconds {
                context["retryAfterSeconds"] = .number(Double(retryAfterSeconds))
            }
            diagnostics.append(
                diagnostic(
                    reason: "acoustid-rate-limited",
                    fingerprint: fingerprint,
                    chunk: chunk,
                    context: context
                )
            )
        case .malformedResponse(let reason):
            diagnostics.append(outcomeDiagnostic("acoustid-malformed-response", reason: reason, fingerprint: fingerprint, chunk: chunk))
        }
    }

    private func outcomeDiagnostic(
        _ diagnosticReason: String,
        reason: String,
        fingerprint: AudioFingerprintDraft,
        chunk: DecodedAudioChunk
    ) -> AudioFingerprintEnrichmentDiagnostic {
        diagnostic(
            reason: diagnosticReason,
            fingerprint: fingerprint,
            chunk: chunk,
            context: ["lookupReason": .string(AcoustIDLookupOutcome.sanitizedReason(reason))]
        )
    }

    private func diagnostic(
        reason: String,
        fingerprint: AudioFingerprintDraft,
        chunk: DecodedAudioChunk,
        context: [String: JSONValue] = [:]
    ) -> AudioFingerprintEnrichmentDiagnostic {
        var diagnosticContext = context
        diagnosticContext["chunkSequence"] = .number(Double(chunk.sequence))
        diagnosticContext["algorithm"] = .string(fingerprint.algorithm)
        diagnosticContext["algorithmVersion"] = .string(fingerprint.algorithmVersion)
        if !fingerprint.fingerprintHash.isEmpty {
            diagnosticContext["fingerprintHash"] = .string(fingerprint.fingerprintHash)
        }
        return AudioFingerprintEnrichmentDiagnostic(
            severity: .warning,
            reason: reason,
            context: diagnosticContext
        )
    }

    private func identity(for fingerprint: AudioFingerprintDraft) -> AcoustIDLookupCacheIdentity? {
        let algorithm = fingerprint.algorithm.trimmingCharacters(in: .whitespacesAndNewlines)
        let algorithmVersion = fingerprint.algorithmVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprintHash = fingerprint.fingerprintHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !algorithm.isEmpty, !algorithmVersion.isEmpty, !fingerprintHash.isEmpty else {
            return nil
        }
        return AcoustIDLookupCacheIdentity(
            algorithm: algorithm,
            algorithmVersion: algorithmVersion,
            fingerprintHash: fingerprintHash
        )
    }

    private func duration(for fingerprint: AudioFingerprintDraft) -> Double? {
        guard fingerprint.endSeconds >= fingerprint.startSeconds else { return nil }
        return fingerprint.endSeconds - fingerprint.startSeconds
    }

    private func isUsable(_ match: AcoustIDMatch) -> Bool {
        [match.acoustID, match.recordingID, match.title, match.artist, match.album, match.isrc]
            .contains { value in
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    private func apply(
        match: AcoustIDMatch,
        fingerprintHash: String,
        to result: inout AudioFingerprintResult
    ) {
        let songKey = "fingerprint:\(fingerprintHash)"
        result.songPlays = result.songPlays.map { play in
            guard play.song.songKey == songKey else { return play }
            var enrichedPlay = play
            enrichedPlay.song = enrichedSong(from: play.song, match: match)
            return enrichedPlay
        }
    }

    private func removeUnknownSongPlay(
        fingerprintHash: String,
        from result: inout AudioFingerprintResult
    ) {
        let songKey = "fingerprint:\(fingerprintHash)"
        result.songPlays.removeAll { play in
            play.song.songKey == songKey && play.song.isUnknown
        }
    }

    private func enrichedSong(
        from song: UnresolvedSongDraft,
        match: AcoustIDMatch
    ) -> UnresolvedSongDraft {
        let title = normalized(match.title) ?? song.title
        let artist = normalized(match.artist) ?? song.artist
        let album = normalized(match.album) ?? song.album
        let isrc = normalized(match.isrc) ?? song.isrc
        return UnresolvedSongDraft(
            songKey: song.songKey,
            title: title,
            artist: artist,
            album: album,
            isrc: isrc,
            displayName: displayName(title: title, artist: artist, fallback: song.displayName),
            isUnknown: false
        )
    }

    private func displayName(title: String?, artist: String?, fallback: String) -> String {
        switch (title, artist) {
        case (.some(let title), .some(let artist)):
            return "\(title) — \(artist)"
        case (.some(let title), .none):
            return title
        case (.none, .some(let artist)):
            return artist
        case (.none, .none):
            return fallback
        }
    }

    private func match(from row: AcoustIDLookupCacheRow) -> AcoustIDMatch {
        AcoustIDMatch(
            acoustID: row.acoustID,
            recordingID: row.recordingID,
            title: row.title,
            artist: row.artist,
            album: row.album,
            isrc: row.isrc,
            durationSeconds: row.durationSeconds,
            score: row.score,
            responseJSON: row.responseJSON
        )
    }

    private func entry(
        from match: AcoustIDMatch,
        identity: AcoustIDLookupCacheIdentity
    ) -> AcoustIDLookupCacheEntry {
        AcoustIDLookupCacheEntry(
            identity: identity,
            acoustID: normalized(match.acoustID),
            recordingID: normalized(match.recordingID),
            title: normalized(match.title),
            artist: normalized(match.artist),
            album: normalized(match.album),
            isrc: normalized(match.isrc),
            durationSeconds: match.durationSeconds,
            score: match.score,
            responseJSON: normalized(match.responseJSON),
            fetchedAt: now()
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}
