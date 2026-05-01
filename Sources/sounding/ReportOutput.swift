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

    struct RepeatsPayload: Codable, Equatable {
        var results: [Repeat]
    }

    struct AdsPayload: Codable, Equatable {
        var events: [AdEvent]
        var summary: AdSummary
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

    struct Repeat: Codable, Equatable {
        var groupKey: String
        var song: Song
        var repeatCount: Int
        var totalDurationSeconds: Double
        var firstStartSeconds: Double
        var lastEndSeconds: Double
        var plays: [Play]
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

    struct AdEvent: Codable, Equatable {
        var identity: AdIdentity
        var classification: MarkerClassification
        var markerType: String
        var source: String
        var pts: Double?
        var segment: String?
        var observedAt: String
    }

    struct AdIdentity: Codable, Equatable {
        var eventID: Int64
        var streamID: Int64
        var streamType: String
        var streamSource: String
        var runID: Int64
        var chunkID: Int64?
        var chunkSequence: Int?
    }

    struct AdSummary: Codable, Equatable {
        var unknown: Int
        var adStart: Int
        var adEnd: Int
    }

    static func encodePlaysJSON(_ results: [SongReportQuery.PlayResult]) throws -> String {
        try encodePayload(PlaysPayload(results: try results.map(sanitizedPlay)))
    }

    static func encodeRepeatsJSON(_ results: [SongReportQuery.RepeatResult]) throws -> String {
        try encodePayload(RepeatsPayload(results: try results.map(sanitizedRepeat)))
    }

    static func encodeAdsJSON(_ result: AdReportQuery.Result) throws -> String {
        try encodePayload(
            AdsPayload(
                events: try result.events.map(sanitizedAdEvent),
                summary: AdSummary(
                    unknown: result.summary.unknown,
                    adStart: result.summary.adStart,
                    adEnd: result.summary.adEnd
                )
            )
        )
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

    static func formatRepeatsHuman(_ results: [SongReportQuery.RepeatResult]) throws -> String {
        guard !results.isEmpty else {
            return "No repeated songs found.\n"
        }

        return try results.enumerated().map { index, result in
            try validateRepeatTimes(result)
            var lines: [String] = []
            lines.append(
                "Repeat \(index + 1): group=\(result.groupKey) count=\(result.repeatCount) song=\(songLabel(result.song)) song_key=\(result.song.songKey)"
            )
            lines.append(
                "  window=\(formatRange(start: result.firstStartSeconds, end: result.lastEndSeconds)) total_duration=\(formatDuration(result.totalDurationSeconds))"
            )
            lines.append("  plays:")
            for play in result.plays {
                try validatePlayTimes(play)
                let source = play.source.map(redactedSourceDescription) ?? "unknown"
                lines.append(
                    "    - stream=\(streamDescription(play.identity)) run=\(play.identity.runID) play=\(play.identity.playID) chunks=\(play.identity.firstChunkID)(seq=\(play.identity.firstChunkSequence))-\(play.identity.lastChunkID)(seq=\(play.identity.lastChunkSequence)) time=\(formatRange(start: play.startSeconds, end: play.endSeconds)) duration=\(formatDuration(play.durationSeconds)) confidence=\(confidenceDescription(play.confidence)) source=\(source)"
                )
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }

    static func formatAdsHuman(_ result: AdReportQuery.Result) throws -> String {
        guard !result.events.isEmpty else {
            return "No ad events found.\n"
        }

        var sections: [String] = []
        sections.append(
            "Ad summary: total=\(result.events.count) unknown=\(result.summary.unknown) ad_start=\(result.summary.adStart) ad_end=\(result.summary.adEnd)"
        )
        sections.append(
            try result.events.enumerated().map { index, event in
                try validateAdTimes(event)
                let pts = event.pts.map(formatSeconds) ?? "unknown"
                let segment = event.segment.map(redactedSourceDescription) ?? "none"
                var lines: [String] = []
                lines.append(
                    "Ad Event \(index + 1): stream=\(adStreamDescription(event.identity)) run=\(event.identity.runID) event=\(event.identity.eventID) chunk=\(chunkDescription(event.identity))"
                )
                lines.append(
                    "  classification=\(event.classification.rawValue) marker=\(event.markerType) pts=\(pts) observed_at=\(event.observedAt)"
                )
                lines.append(
                    "  source=\(redactedSourceDescription(event.source)) segment=\(segment)"
                )
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
        )
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func encodePayload<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(payload)
            return String(decoding: data, as: UTF8.self) + "\n"
        } catch let error as OutputError {
            throw error
        } catch {
            throw OutputError.encodingFailed
        }
    }

    private static func sanitizedRepeat(_ result: SongReportQuery.RepeatResult) throws -> Repeat {
        try validateRepeatTimes(result)
        return Repeat(
            groupKey: result.groupKey,
            song: sanitizedSong(result.song),
            repeatCount: result.repeatCount,
            totalDurationSeconds: result.totalDurationSeconds,
            firstStartSeconds: result.firstStartSeconds,
            lastEndSeconds: result.lastEndSeconds,
            plays: try result.plays.map(sanitizedPlay)
        )
    }

    private static func sanitizedPlay(_ result: SongReportQuery.PlayResult) throws -> Play {
        try validatePlayTimes(result)
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
            song: sanitizedSong(result.song),
            startSeconds: result.startSeconds,
            endSeconds: result.endSeconds,
            durationSeconds: result.durationSeconds,
            confidence: result.confidence,
            source: result.source.map(redactedSourceDescription),
            createdAt: result.createdAt,
            updatedAt: result.updatedAt
        )
    }

    private static func sanitizedSong(_ song: SongReportQuery.SongDisplay) -> Song {
        Song(
            songID: song.songID,
            songKey: song.songKey,
            title: song.title,
            artist: song.artist,
            album: song.album,
            isrc: song.isrc,
            displayName: song.displayName,
            isUnknown: song.isUnknown,
            displayLabel: songLabel(song)
        )
    }

    private static func sanitizedAdEvent(_ result: AdReportQuery.EventResult) throws -> AdEvent {
        try validateAdTimes(result)
        return AdEvent(
            identity: AdIdentity(
                eventID: result.identity.eventID,
                streamID: result.identity.streamID,
                streamType: result.identity.streamType,
                streamSource: redactedSourceDescription(result.identity.streamSource),
                runID: result.identity.runID,
                chunkID: result.identity.chunkID,
                chunkSequence: result.identity.chunkSequence
            ),
            classification: result.classification,
            markerType: result.markerType,
            source: redactedSourceDescription(result.source),
            pts: result.pts,
            segment: result.segment.map(redactedSourceDescription),
            observedAt: result.observedAt
        )
    }

    private static func validateRepeatTimes(_ result: SongReportQuery.RepeatResult) throws {
        guard result.firstStartSeconds.isFinite else {
            throw OutputError.invalidTime("firstStartSeconds")
        }
        guard result.lastEndSeconds.isFinite else { throw OutputError.invalidTime("lastEndSeconds") }
        guard result.totalDurationSeconds.isFinite else {
            throw OutputError.invalidTime("totalDurationSeconds")
        }
    }

    private static func validatePlayTimes(_ result: SongReportQuery.PlayResult) throws {
        guard result.startSeconds.isFinite else { throw OutputError.invalidTime("startSeconds") }
        guard result.endSeconds.isFinite else { throw OutputError.invalidTime("endSeconds") }
        guard result.durationSeconds.isFinite else {
            throw OutputError.invalidTime("durationSeconds")
        }
    }

    private static func validateAdTimes(_ result: AdReportQuery.EventResult) throws {
        if let pts = result.pts, !pts.isFinite {
            throw OutputError.invalidTime("pts")
        }
    }

    private static func streamDescription(_ identity: SongReportQuery.PlayIdentity) -> String {
        "\(identity.streamID)(\(identity.streamType) source=\(redactedSourceDescription(identity.streamSource)))"
    }

    private static func adStreamDescription(_ identity: AdReportQuery.EventIdentity) -> String {
        "\(identity.streamID)(\(identity.streamType) source=\(redactedSourceDescription(identity.streamSource)))"
    }

    private static func chunkDescription(_ identity: AdReportQuery.EventIdentity) -> String {
        guard let chunkID = identity.chunkID else { return "none" }
        if let chunkSequence = identity.chunkSequence {
            return "\(chunkID)(seq=\(chunkSequence))"
        }
        return "\(chunkID)(seq=unknown)"
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
