import Foundation
import SoundingKit

enum TranscriptOutput {
    struct SearchPayload: Codable, Equatable {
        var results: [TranscriptQuery.SearchResult]
    }

    struct CountPayload: Codable, Equatable {
        var results: [TranscriptQuery.CountResult]
    }

    static func encodeSearchJSON(_ results: [TranscriptQuery.SearchResult]) throws -> String {
        try encode(SearchPayload(results: results))
    }

    static func encodeCountJSON(_ results: [TranscriptQuery.CountResult]) throws -> String {
        try encode(CountPayload(results: results))
    }

    static func formatSearchHuman(_ results: [TranscriptQuery.SearchResult]) -> String {
        guard !results.isEmpty else {
            return "No transcript matches found."
        }

        return results.enumerated().map { index, result in
            var lines: [String] = []
            lines.append(
                "Match \(index + 1): stream=\(streamDescription(result.identity)) run=\(result.identity.runID) chunk=\(result.identity.chunkID) segment=\(result.identity.segmentID)"
            )
            lines.append(
                "  time=\(formatRange(start: result.startSeconds, end: result.endSeconds)) speaker=\(speakerDescription(result.identity.speakerLabel)) occurrences=\(result.occurrenceCount)"
            )
            lines.append("  text: \(result.text)")

            if !result.context.isEmpty {
                lines.append("  context:")
                for context in result.context {
                    lines.append(
                        "    [\(context.role.rawValue)] \(formatRange(start: context.startSeconds, end: context.endSeconds)) speaker=\(speakerDescription(context.identity.speakerLabel)) segment=\(context.identity.segmentID): \(context.text)"
                    )
                }
            }

            if !result.words.isEmpty {
                let wordRange =
                    "words=\(result.words.first?.id ?? 0)...\(result.words.last?.id ?? 0)"
                lines.append("  \(wordRange) count=\(result.words.count)")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }

    static func formatCountHuman(_ results: [TranscriptQuery.CountResult]) -> String {
        guard !results.isEmpty else {
            return "No transcript matches found.\n"
        }

        return results.map { result in
            "stream=\(result.streamID)(\(result.streamType) source=\(result.streamSource)) run=\(result.runID) speaker=\(speakerDescription(result.speakerLabel)) occurrences=\(result.occurrenceCount) matching_segments=\(result.matchingSegmentCount)"
        }
        .joined(separator: "\n") + "\n"
    }

    static func formatRange(start: Double, end: Double) -> String {
        "\(formatSeconds(start))-\(formatSeconds(end))"
    }

    private static func streamDescription(_ identity: TranscriptQuery.SegmentIdentity) -> String {
        "\(identity.streamID)(\(identity.streamType) source=\(identity.streamSource))"
    }

    private static func speakerDescription(_ speakerLabel: String?) -> String {
        guard let speakerLabel, !speakerLabel.isEmpty else {
            return "unknown"
        }
        return speakerLabel
    }

    private static func encode<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self) + "\n"
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
}
