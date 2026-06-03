import Foundation

public struct TimelineExportAudioRange: Codable, Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var fileName: String

    public init(startSeconds: Double, endSeconds: Double, fileName: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.fileName = fileName
    }
}

public struct TimelineExportMissingRange: Codable, Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct TimelineExportAudioManifest: Codable, Equatable, Sendable {
    public var retainedRanges: [TimelineExportAudioRange]
    public var missingRanges: [TimelineExportMissingRange]

    public init(
        retainedRanges: [TimelineExportAudioRange],
        missingRanges: [TimelineExportMissingRange]
    ) {
        self.retainedRanges = retainedRanges
        self.missingRanges = missingRanges
    }
}

public enum TimelineExportService {
    public static func transcriptText(items: [StreamAppTimelineItem]) -> String {
        items
            .filter { $0.kind == .transcript }
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { item in
                let start = item.startTimestamp ?? secondsLabel(item.startSeconds)
                let end = item.endTimestamp ?? secondsLabel(item.endSeconds ?? item.startSeconds)
                let text = item.subtitle ?? item.title
                return "[\(start) - \(end)] \(text)\n"
            }
            .joined()
    }

    public static func timelineJSON(items: [StreamAppTimelineItem]) throws -> Data {
        let rows = items
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { item in
                TimelineExportJSONRow(
                    id: item.id,
                    kind: item.kind.rawValue,
                    title: item.title,
                    subtitle: item.subtitle ?? "",
                    startSeconds: item.startSeconds,
                    endSeconds: item.endSeconds,
                    startTimestamp: item.startTimestamp ?? "",
                    endTimestamp: item.endTimestamp ?? "",
                    isSeekable: item.isSeekable
                )
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows)
    }

    public static func copyText(item: StreamAppTimelineItem, includesTime: Bool) -> String {
        let body: String
        switch item.kind {
        case .transcript:
            body = item.subtitle ?? item.title
        case .song, .event:
            body = [item.title, item.subtitle]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: " - ")
        }
        guard includesTime else { return body }
        let time = item.startTimestamp ?? secondsLabel(item.startSeconds)
        return "[\(time)] \(kindTitle(item.kind)): \(body)"
    }

    public static func audioManifest(
        requestedStartSeconds: Double,
        requestedEndSeconds: Double,
        retainedRanges: [TimelineExportAudioRange]
    ) -> TimelineExportAudioManifest {
        guard requestedStartSeconds.isFinite,
            requestedEndSeconds.isFinite,
            requestedEndSeconds > requestedStartSeconds
        else {
            return TimelineExportAudioManifest(retainedRanges: [], missingRanges: [])
        }

        let clipped = retainedRanges
            .filter { $0.startSeconds.isFinite && $0.endSeconds.isFinite }
            .filter { $0.endSeconds > requestedStartSeconds && $0.startSeconds < requestedEndSeconds }
            .filter { $0.endSeconds > $0.startSeconds }
            .sorted {
                if $0.startSeconds == $1.startSeconds {
                    return $0.endSeconds < $1.endSeconds
                }
                return $0.startSeconds < $1.startSeconds
            }

        var retained: [TimelineExportAudioRange] = []
        var missing: [TimelineExportMissingRange] = []
        var cursor = requestedStartSeconds

        for range in clipped {
            let start = max(range.startSeconds, requestedStartSeconds, cursor)
            let end = min(range.endSeconds, requestedEndSeconds)
            guard end > start else { continue }
            if start > cursor {
                missing.append(TimelineExportMissingRange(startSeconds: cursor, endSeconds: start))
            }
            retained.append(
                TimelineExportAudioRange(
                    startSeconds: start,
                    endSeconds: end,
                    fileName: range.fileName
                )
            )
            cursor = max(cursor, end)
        }

        if cursor < requestedEndSeconds {
            missing.append(
                TimelineExportMissingRange(
                    startSeconds: cursor,
                    endSeconds: requestedEndSeconds
                )
            )
        }

        return TimelineExportAudioManifest(retainedRanges: retained, missingRanges: missing)
    }

    private static func secondsLabel(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }

    private static func kindTitle(_ kind: StreamAppTimelineItemKind) -> String {
        switch kind {
        case .transcript:
            return "Transcript"
        case .song:
            return "Song"
        case .event:
            return "Event"
        }
    }
}

private struct TimelineExportJSONRow: Encodable {
    var id: String
    var kind: String
    var title: String
    var subtitle: String
    var startSeconds: Double
    var endSeconds: Double?
    var startTimestamp: String
    var endTimestamp: String
    var isSeekable: Bool
}
