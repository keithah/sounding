import Foundation

public enum StreamAppTimelineRailProjection {
    public static func project(
        items: [StreamAppTimelineItem],
        visibleStartSeconds: Double,
        visibleEndSeconds: Double
    ) -> StreamAppTimelineRailSnapshot {
        let orderedVisibleStartSeconds = min(visibleStartSeconds, visibleEndSeconds)
        let orderedVisibleEndSeconds = max(visibleStartSeconds, visibleEndSeconds)
        let duration = max(orderedVisibleEndSeconds - orderedVisibleStartSeconds, 0)
        let spans = items
            .filter { $0.kind == .song }
            .compactMap { item in
                span(
                    for: item,
                    visibleStartSeconds: orderedVisibleStartSeconds,
                    visibleEndSeconds: orderedVisibleEndSeconds,
                    duration: duration
                )
            }
            .sorted {
                if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
                return $0.id < $1.id
            }
        let markers = items
            .filter { $0.kind == .event }
            .compactMap { item in
                marker(
                    for: item,
                    visibleStartSeconds: orderedVisibleStartSeconds,
                    visibleEndSeconds: orderedVisibleEndSeconds,
                    duration: duration
                )
            }
            .sorted {
                if $0.seconds != $1.seconds { return $0.seconds < $1.seconds }
                return $0.id < $1.id
            }

        return StreamAppTimelineRailSnapshot(
            visibleStartSeconds: orderedVisibleStartSeconds,
            visibleEndSeconds: orderedVisibleEndSeconds,
            spans: spans,
            markers: markers
        )
    }

    private static func span(
        for item: StreamAppTimelineItem,
        visibleStartSeconds: Double,
        visibleEndSeconds: Double,
        duration: Double
    ) -> StreamAppTimelineRailSpan? {
        guard duration > 0 else { return nil }
        let endSeconds = item.endSeconds ?? item.startSeconds
        guard endSeconds >= visibleStartSeconds && item.startSeconds <= visibleEndSeconds else {
            return nil
        }
        let clampedStart = clamp(item.startSeconds, lower: visibleStartSeconds, upper: visibleEndSeconds)
        let clampedEnd = clamp(endSeconds, lower: visibleStartSeconds, upper: visibleEndSeconds)
        return StreamAppTimelineRailSpan(
            id: item.id,
            title: item.title,
            subtitle: item.subtitle,
            startSeconds: item.startSeconds,
            endSeconds: endSeconds,
            normalizedStart: normalized(clampedStart, visibleStartSeconds: visibleStartSeconds, duration: duration),
            normalizedEnd: normalized(clampedEnd, visibleStartSeconds: visibleStartSeconds, duration: duration),
            colorToken: StreamAppSpeakerDisplayProjection.fallbackColorToken(for: item.title),
            isSeekable: item.isSeekable
        )
    }

    private static func marker(
        for item: StreamAppTimelineItem,
        visibleStartSeconds: Double,
        visibleEndSeconds: Double,
        duration: Double
    ) -> StreamAppTimelineRailMarker? {
        guard duration > 0,
              item.startSeconds >= visibleStartSeconds,
              item.startSeconds <= visibleEndSeconds else {
            return nil
        }
        let source = markerSource(for: item)
        return StreamAppTimelineRailMarker(
            id: item.id,
            title: item.title,
            source: source,
            seconds: item.startSeconds,
            normalizedPosition: normalized(item.startSeconds, visibleStartSeconds: visibleStartSeconds, duration: duration),
            colorToken: markerColorToken(for: source),
            isSeekable: item.isSeekable
        )
    }

    private static func markerSource(for item: StreamAppTimelineItem) -> StreamAppTimelineMarkerSource {
        let text = [item.id, item.title, item.subtitle ?? ""].joined(separator: " ").lowercased()
        if scte35Markers.contains(where: { containsMarker($0, in: text) }) { return .scte35 }
        if timedID3Markers.contains(where: { containsMarker($0, in: text) }) { return .timedID3 }
        return .unknown
    }

    private static let scte35Markers = [
        "scte",
        "splice_insert",
        "splice insert",
        "ext-x-cue-out",
        "ext-x-cue-in",
        "cue-out",
        "cue-in",
    ]

    private static let timedID3Markers = [
        "id3",
        "timed id3",
        "timed-id3",
    ]

    private static func containsMarker(_ marker: String, in text: String) -> Bool {
        let pattern = "(^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: marker) + "([^a-z0-9]|$)"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func markerColorToken(for source: StreamAppTimelineMarkerSource) -> String {
        switch source {
        case .timedID3:
            return "orange"
        case .scte35:
            return "red"
        case .unknown:
            return "gray"
        }
    }

    private static func normalized(
        _ seconds: Double,
        visibleStartSeconds: Double,
        duration: Double
    ) -> Double {
        (seconds - visibleStartSeconds) / duration
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
