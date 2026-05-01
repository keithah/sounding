import Foundation
import SoundingKit

enum ExportOutput {
    enum Format: String, Equatable {
        case text
        case json
    }

    typealias OutputError = ReportOutput.OutputError

    struct TranscriptPayload: Codable, Equatable {
        var segments: [TranscriptSegment]
    }

    struct TranscriptSegment: Codable, Equatable {
        var identity: TranscriptSegmentIdentity
        var startSeconds: Double
        var endSeconds: Double
        var text: String
        var confidence: Double?
        var createdAt: String?
        var words: [TranscriptWord]
    }

    struct TranscriptSegmentIdentity: Codable, Equatable {
        var streamID: Int64
        var streamType: String
        var streamSource: String
        var runID: Int64
        var chunkID: Int64
        var segmentID: Int64
        var sequence: Int
        var speakerLabel: String?
    }

    struct TranscriptWord: Codable, Equatable {
        var id: Int64
        var sequence: Int
        var speakerLabel: String?
        var startSeconds: Double
        var endSeconds: Double
        var text: String
        var confidence: Double?
    }

    static func encodeTranscriptsJSON(_ segments: [TranscriptExportQuery.SegmentExportRow]) throws
        -> String
    {
        try encodePayload(TranscriptPayload(segments: try segments.map(sanitizedTranscriptSegment)))
    }

    static func formatTranscriptsHuman(_ segments: [TranscriptExportQuery.SegmentExportRow]) throws
        -> String
    {
        guard !segments.isEmpty else {
            return "No transcript segments found.\n"
        }

        return try segments.enumerated().map { index, segment in
            try validateTranscriptSegmentTimes(segment)
            let identity = segment.identity
            var lines: [String] = []
            lines.append(
                "Segment \(index + 1): stream=\(streamDescription(identity)) run=\(identity.runID) chunk=\(identity.chunkID) segment=\(identity.segmentID) sequence=\(identity.sequence)"
            )
            lines.append(
                "  time=\(formatRange(start: segment.startSeconds, end: segment.endSeconds)) speaker=\(speakerDescription(identity.speakerLabel)) confidence=\(confidenceDescription(segment.confidence)) created_at=\(segment.createdAt ?? "unknown")"
            )
            lines.append("  text: \(segment.text)")

            if !segment.words.isEmpty {
                lines.append("  words:")
                for word in segment.words {
                    try validateTranscriptWordTimes(word)
                    lines.append(
                        "    - id=\(word.id) sequence=\(word.sequence) time=\(formatRange(start: word.startSeconds, end: word.endSeconds)) speaker=\(speakerDescription(word.speakerLabel)) confidence=\(confidenceDescription(word.confidence)) text=\(word.text)"
                    )
                }
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }

    static func encodeMarkersJSON(_ result: AdReportQuery.Result) throws -> String {
        try ReportOutput.encodeAdsJSON(result)
    }

    static func formatMarkersHuman(_ result: AdReportQuery.Result) throws -> String {
        try ReportOutput.formatAdsHuman(result)
    }

    static func encodeReportPlaysJSON(_ results: [SongReportQuery.PlayResult]) throws -> String {
        try ReportOutput.encodePlaysJSON(results)
    }

    static func formatReportPlaysHuman(_ results: [SongReportQuery.PlayResult]) -> String {
        ReportOutput.formatPlaysHuman(results)
    }

    static func encodeReportRepeatsJSON(_ results: [SongReportQuery.RepeatResult]) throws -> String {
        try ReportOutput.encodeRepeatsJSON(results)
    }

    static func formatReportRepeatsHuman(_ results: [SongReportQuery.RepeatResult]) throws -> String {
        try ReportOutput.formatRepeatsHuman(results)
    }

    static func encodeReportAdsJSON(_ result: AdReportQuery.Result) throws -> String {
        try ReportOutput.encodeAdsJSON(result)
    }

    static func formatReportAdsHuman(_ result: AdReportQuery.Result) throws -> String {
        try ReportOutput.formatAdsHuman(result)
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

    private static func sanitizedTranscriptSegment(
        _ row: TranscriptExportQuery.SegmentExportRow
    ) throws -> TranscriptSegment {
        try validateTranscriptSegmentTimes(row)
        return TranscriptSegment(
            identity: TranscriptSegmentIdentity(
                streamID: row.identity.streamID,
                streamType: row.identity.streamType,
                streamSource: redactedSourceDescription(row.identity.streamSource),
                runID: row.identity.runID,
                chunkID: row.identity.chunkID,
                segmentID: row.identity.segmentID,
                sequence: row.identity.sequence,
                speakerLabel: row.identity.speakerLabel
            ),
            startSeconds: row.startSeconds,
            endSeconds: row.endSeconds,
            text: row.text,
            confidence: row.confidence,
            createdAt: row.createdAt,
            words: try row.words.map(sanitizedTranscriptWord)
        )
    }

    private static func sanitizedTranscriptWord(
        _ word: SoundingKit.TranscriptQuery.TranscriptWord
    ) throws -> TranscriptWord {
        try validateTranscriptWordTimes(word)
        return TranscriptWord(
            id: word.id,
            sequence: word.sequence,
            speakerLabel: word.speakerLabel,
            startSeconds: word.startSeconds,
            endSeconds: word.endSeconds,
            text: word.text,
            confidence: word.confidence
        )
    }

    private static func validateTranscriptSegmentTimes(
        _ row: TranscriptExportQuery.SegmentExportRow
    ) throws {
        guard row.startSeconds.isFinite else { throw OutputError.invalidTime("startSeconds") }
        guard row.endSeconds.isFinite else { throw OutputError.invalidTime("endSeconds") }
    }

    private static func validateTranscriptWordTimes(
        _ word: SoundingKit.TranscriptQuery.TranscriptWord
    ) throws {
        guard word.startSeconds.isFinite else { throw OutputError.invalidTime("word.startSeconds") }
        guard word.endSeconds.isFinite else { throw OutputError.invalidTime("word.endSeconds") }
    }

    private static func streamDescription(_ identity: TranscriptQuery.SegmentIdentity) -> String {
        "\(identity.streamID)(\(identity.streamType) source=\(redactedSourceDescription(identity.streamSource)))"
    }

    private static func speakerDescription(_ speakerLabel: String?) -> String {
        guard let speakerLabel, !speakerLabel.isEmpty else {
            return "unknown"
        }
        return speakerLabel
    }

    private static func confidenceDescription(_ confidence: Double?) -> String {
        guard let confidence, confidence.isFinite else { return "unknown" }
        return String(format: "%.3f", confidence)
    }

    private static func formatRange(start: Double, end: Double) -> String {
        "\(formatSeconds(start))-\(formatSeconds(end))"
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
