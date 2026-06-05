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

    func shouldCaptureTranscript(
        overlapping chunk: DecodedAudioChunk,
        policy: TranscriptCapturePolicy
    ) -> Bool {
        switch policy {
        case .all:
            return true
        case .nonSongs:
            return !hasConfirmedMusicPlay(overlapping: chunk)
        }
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

    private let activeTimedMetadataLookup: ActiveTimedMetadataLookup

    init(activeTimedMetadataLookup: @escaping ActiveTimedMetadataLookup = { _, _ in nil }) {
        self.activeTimedMetadataLookup = activeTimedMetadataLookup
    }

    func resolve(
        chunk: DecodedAudioChunk,
        fingerprintSongPlays: [SongPlayDraft]
    ) throws -> ChunkProgramMetadataContext {
        let markers = normalizedTimelineMarkers(chunk.adMarkers, in: chunk)
        let timedMetadataSongPlays = songPlaysFromTimedMetadata(markers, in: chunk)
        if !timedMetadataSongPlays.isEmpty {
            return ChunkProgramMetadataContext(markers: markers, songPlays: timedMetadataSongPlays)
        }
        if let activeTimedSongPlay = try activeTimedMetadataLookup(chunk.startSeconds, chunk.endSeconds) {
            return ChunkProgramMetadataContext(markers: markers, songPlays: [activeTimedSongPlay])
        }
        return ChunkProgramMetadataContext(markers: markers, songPlays: fingerprintSongPlays)
    }

    private func normalizedTimelineMarkers(_ markers: [AdMarker], in chunk: DecodedAudioChunk) -> [AdMarker] {
        markers.map { marker in
            var normalized = marker
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
