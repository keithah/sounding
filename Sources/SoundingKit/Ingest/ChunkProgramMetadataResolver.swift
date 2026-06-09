import Foundation

enum TranscriptCapturePolicy: Equatable, Sendable {
    case all
    case nonSongs
}

extension StreamTranscriptionPolicy {
    var capturePolicy: TranscriptCapturePolicy {
        switch self {
        case .always:
            return .all
        case .nonSongs, .hidden:
            return .nonSongs
        }
    }
}

struct ChunkProgramMetadataContext: Equatable, Sendable {
    var markers: [AdMarker]
    var songPlays: [SongPlayDraft]
    var activeAdBreak: Bool = false

    func shouldCaptureTranscript(
        overlapping chunk: DecodedAudioChunk,
        policy: TranscriptCapturePolicy
    ) -> Bool {
        switch policy {
        case .all:
            return true
        case .nonSongs:
            return activeAdBreak || hasAdCue(overlapping: chunk) || !hasConfirmedMusicPlay(overlapping: chunk)
        }
    }

    private func hasAdCue(overlapping chunk: DecodedAudioChunk) -> Bool {
        markers.contains { marker in
            isAdCue(marker) && markerOverlapsChunk(marker, chunk)
        }
    }

    private func isAdCue(_ marker: AdMarker) -> Bool {
        switch marker.classification {
        case .adStart, .adEnd:
            return true
        case .unknown:
            return isAdvertisementID3Marker(marker)
        }
    }

    private func isAdvertisementID3Marker(_ marker: AdMarker) -> Bool {
        guard marker.type.caseInsensitiveCompare("ID3") == .orderedSame else {
            return false
        }
        return markerTextCandidates(marker).contains { candidate in
            candidate.range(of: "advertisement", options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
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

    private func markerOverlapsChunk(_ marker: AdMarker, _ chunk: DecodedAudioChunk) -> Bool {
        guard let pts = marker.pts else { return true }
        return pts >= chunk.startSeconds && pts <= chunk.endSeconds
    }

    private func hasConfirmedMusicPlay(overlapping chunk: DecodedAudioChunk) -> Bool {
        songPlays.contains { play in
            isConfirmedMusicPlay(play)
                && max(0, min(play.endSeconds, chunk.endSeconds) - max(play.startSeconds, chunk.startSeconds)) > 0
        }
    }

    private func isConfirmedMusicPlay(_ play: SongPlayDraft) -> Bool {
        ProgramMetadataClassifier.isMusic(
            title: play.song.title ?? play.song.displayName,
            artist: play.song.artist,
            album: play.song.album,
            source: ProgramMetadataSource(raw: play.source),
            isUnknown: play.song.isUnknown
        )
    }
}

struct ChunkProgramMetadataResolver {
    typealias ActiveTimedMetadataLookup = (_ startSeconds: Double, _ endSeconds: Double) throws -> SongPlayDraft?
    typealias ActiveAdBreakLookup = (_ startSeconds: Double, _ endSeconds: Double) throws -> Bool

    private let activeTimedMetadataLookup: ActiveTimedMetadataLookup
    private let activeAdBreakLookup: ActiveAdBreakLookup

    init(
        activeTimedMetadataLookup: @escaping ActiveTimedMetadataLookup = { _, _ in nil },
        activeAdBreakLookup: @escaping ActiveAdBreakLookup = { _, _ in false }
    ) {
        self.activeTimedMetadataLookup = activeTimedMetadataLookup
        self.activeAdBreakLookup = activeAdBreakLookup
    }

    func resolve(
        chunk: DecodedAudioChunk,
        fingerprintSongPlays: [SongPlayDraft]
    ) throws -> ChunkProgramMetadataContext {
        let markers = normalizedTimelineMarkers(chunk.adMarkers, in: chunk)
        let activeAdBreak = try activeAdBreakLookup(chunk.startSeconds, chunk.endSeconds)
        let timedMetadataSongPlays = songPlaysFromTimedMetadata(markers, in: chunk)
        if !timedMetadataSongPlays.isEmpty {
            return ChunkProgramMetadataContext(
                markers: markers,
                songPlays: timedMetadataSongPlays,
                activeAdBreak: activeAdBreak
            )
        }
        if let activeTimedSongPlay = try activeTimedMetadataLookup(chunk.startSeconds, chunk.endSeconds) {
            return ChunkProgramMetadataContext(
                markers: markers,
                songPlays: [activeTimedSongPlay],
                activeAdBreak: activeAdBreak
            )
        }
        return ChunkProgramMetadataContext(
            markers: markers,
            songPlays: fingerprintSongPlays,
            activeAdBreak: activeAdBreak
        )
    }

    private func normalizedTimelineMarkers(_ markers: [AdMarker], in chunk: DecodedAudioChunk) -> [AdMarker] {
        var classifier = MarkerClassifier()
        return markers.map { marker in
            var normalized = classifier.classify(marker)
            if marker.classification != .unknown, normalized.classification == .unknown {
                normalized.classification = marker.classification
            }
            guard ProgramMetadataSource(marker: marker).isTimedMetadata else { return normalized }
            guard let pts = marker.pts else {
                normalized.pts = chunk.startSeconds
                return normalized
            }
            guard pts < chunk.startSeconds || pts > chunk.endSeconds else {
                return normalized
            }
            normalized.pts = chunk.startSeconds
            return normalized
        }
    }

    private func songPlaysFromTimedMetadata(
        _ markers: [AdMarker],
        in chunk: DecodedAudioChunk
    ) -> [SongPlayDraft] {
        var seen = Set<String>()
        return markers.compactMap { marker in
            guard let metadata = ProgramMetadataExtractor.metadata(from: marker),
                metadata.classification == .music
            else {
                return nil
            }
            let songKey = metadata.songKey
            guard seen.insert(songKey).inserted else { return nil }
            return SongPlayDraft(
                song: UnresolvedSongDraft(
                    songKey: songKey,
                    title: metadata.title,
                    artist: metadata.artist,
                    album: metadata.album,
                    displayName: [metadata.title, metadata.artist].compactMap { $0 }.joined(separator: " - "),
                    isUnknown: false
                ),
                startSeconds: chunk.startSeconds,
                endSeconds: chunk.endSeconds,
                confidence: 1.0,
                source: metadata.source.rawValue
            )
        }
    }
}
