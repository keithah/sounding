import Foundation
import SoundingKit

enum ReportOutput {
    enum OutputError: Error, Equatable {
        case invalidTime(String)
        case encodingFailed
    }

    struct PlaysPayload: Codable, Equatable {
        var results: [Play]
    }

    struct Play: Codable, Equatable {
        var identity: Identity
        var song: Song
        var startSeconds: Double
        var endSeconds: Double
        var durationSeconds: Double
        var confidence: Double?
        var source: String?
        var createdAt: String
        var updatedAt: String
    }

    struct Identity: Codable, Equatable {
        var playID: Int64
        var streamID: Int64
        var streamType: String
        var streamSource: String
        var runID: Int64
        var firstChunkID: Int64
        var firstChunkSequence: Int
        var lastChunkID: Int64
        var lastChunkSequence: Int
    }

    struct Song: Codable, Equatable {
        var songID: Int64
        var songKey: String
        var title: String?
        var artist: String?
        var album: String?
        var isrc: String?
        var displayName: String
        var isUnknown: Bool
        var displayLabel: String
    }

    static func encodePlaysJSON(_ results: [SongReportQuery.PlayResult]) throws -> String {
        let payload = PlaysPayload(results: try results.map(sanitizedPlay))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(payload)
            return String(decoding: data, as: UTF8.self) + "\n"
        } catch {
            throw OutputError.encodingFailed
        }
    }

    static func formatPlaysHuman(_ results: [SongReportQuery.PlayResult]) -> String {
        guard !results.isEmpty else {
            return "No song plays found.\n"
        }

        return results.enumerated().map { index, result in
            let source = result.source.map(redactedSourceDescription) ?? "unknown"
            var lines: [String] = []
            lines.append(
                "Play \(index + 1): stream=\(streamDescription(result.identity)) run=\(result.identity.runID) play=\(result.identity.playID)"
            )
            lines.append(
                "  chunks=\(result.identity.firstChunkID)(seq=\(result.identity.firstChunkSequence))-\(result.identity.lastChunkID)(seq=\(result.identity.lastChunkSequence)) time=\(formatRange(start: result.startSeconds, end: result.endSeconds)) duration=\(formatDuration(result.durationSeconds))"
            )
            lines.append(
                "  song=\(songLabel(result.song)) song_key=\(result.song.songKey) unknown=\(result.song.isUnknown) confidence=\(confidenceDescription(result.confidence)) source=\(source)"
            )
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }

    private static func sanitizedPlay(_ result: SongReportQuery.PlayResult) throws -> Play {
        guard result.startSeconds.isFinite else { throw OutputError.invalidTime("startSeconds") }
        guard result.endSeconds.isFinite else { throw OutputError.invalidTime("endSeconds") }
        guard result.durationSeconds.isFinite else {
            throw OutputError.invalidTime("durationSeconds")
        }
        return Play(
            identity: Identity(
                playID: result.identity.playID,
                streamID: result.identity.streamID,
                streamType: result.identity.streamType,
                streamSource: redactedSourceDescription(result.identity.streamSource),
                runID: result.identity.runID,
                firstChunkID: result.identity.firstChunkID,
                firstChunkSequence: result.identity.firstChunkSequence,
                lastChunkID: result.identity.lastChunkID,
                lastChunkSequence: result.identity.lastChunkSequence
            ),
            song: Song(
                songID: result.song.songID,
                songKey: result.song.songKey,
                title: result.song.title,
                artist: result.song.artist,
                album: result.song.album,
                isrc: result.song.isrc,
                displayName: result.song.displayName,
                isUnknown: result.song.isUnknown,
                displayLabel: songLabel(result.song)
            ),
            startSeconds: result.startSeconds,
            endSeconds: result.endSeconds,
            durationSeconds: result.durationSeconds,
            confidence: result.confidence,
            source: result.source.map(redactedSourceDescription),
            createdAt: result.createdAt,
            updatedAt: result.updatedAt
        )
    }

    private static func streamDescription(_ identity: SongReportQuery.PlayIdentity) -> String {
        "\(identity.streamID)(\(identity.streamType) source=\(redactedSourceDescription(identity.streamSource)))"
    }

    private static func songLabel(_ song: SongReportQuery.SongDisplay) -> String {
        if song.isUnknown {
            return "unknown(\(emptyAware(song.displayName)))"
        }
        if let artist = song.artist, !artist.isEmpty, let title = song.title, !title.isEmpty {
            return "\(artist) — \(title)"
        }
        return emptyAware(song.displayName)
    }

    private static func emptyAware(_ value: String) -> String {
        value.isEmpty ? "unknown" : value
    }

    private static func confidenceDescription(_ confidence: Double?) -> String {
        guard let confidence, confidence.isFinite else { return "unknown" }
        return String(format: "%.3f", confidence)
    }

    private static func formatRange(start: Double, end: Double) -> String {
        "\(formatSeconds(start))-\(formatSeconds(end))"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "unknown" }
        return formatSeconds(max(0, seconds))
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--.---" }
        let clamped = max(0, seconds)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let displaySeconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let displayMinutes = totalMinutes % 60
        let hours = totalMinutes / 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d.%03d", hours, displayMinutes, displaySeconds, milliseconds)
        }
        return String(format: "%02d:%02d.%03d", displayMinutes, displaySeconds, milliseconds)
    }

    private static func redactedSourceDescription(_ source: String) -> String {
        MonitorError.redactedSourceDescription(source)
    }
}
