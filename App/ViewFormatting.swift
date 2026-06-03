import SoundingKit
import SwiftUI

struct SpeakerBadge: View {
    var speaker: StreamAppSpeakerDisplay

    var body: some View {
        Text(speaker.displayLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(speaker.color.accessibleForeground)
            .background(speaker.color, in: Capsule())
            .accessibilityLabel("Speaker \(speaker.displayLabel)")
    }
}

struct StatusPill: View {
    var status: StreamAppStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(foregroundStyle)
            .background(backgroundStyle, in: Capsule())
    }

    private var foregroundStyle: Color {
        switch status {
        case .error, .removed:
            return .red
        case .running:
            return .green
        case .connecting, .recovering, .reconnecting:
            return .orange
        case .ready, .paused, .suspended, .stopped:
            return .secondary
        }
    }

    private var backgroundStyle: Color {
        foregroundStyle.opacity(0.14)
    }
}

func transcriptScrollID(_ id: Int64) -> String {
    "transcript-paragraph-\(id)"
}

func timeRange(start: Double, end: Double?) -> String {
    guard let end, end != start else { return String(format: "%.1fs", start) }
    return String(format: "%.1f–%.1fs", start, end)
}

func timeRange(item: StreamAppTimelineItem) -> String {
    guard let start = clockTime(item.startTimestamp) else {
        return timeRange(start: item.startSeconds, end: item.endSeconds)
    }
    let duration = max(0, (item.endSeconds ?? item.startSeconds) - item.startSeconds)
    guard let end = clockTime(item.endTimestamp), end != start else {
        return "\(start) \(String(format: "%.0fs", duration))"
    }
    return "\(start) - \(end) \(String(format: "%.0fs", duration))"
}

func clockTime(_ timestamp: String?) -> String? {
    guard let timestamp,
          let date = AppViewTimestampFormatters.date(from: timestamp) else { return nil }
    return AppViewTimestampFormatters.clockTime(from: date)
}

private enum AppViewTimestampFormatters {
    private static let iso8601: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func date(from timestamp: String) -> Date? {
        iso8601.date(from: timestamp)
    }

    static func clockTime(from date: Date) -> String {
        clock.string(from: date)
    }
}

extension StreamAppSearchResult {
    var streamTitle: String {
        if let streamName, !streamName.isEmpty { return streamName }
        return streamType.uppercased()
    }
}

extension TranscriptQuery.ContextRole {
    var searchCardTitle: String {
        switch self {
        case .before:
            return "Before"
        case .match:
            return "Match"
        case .after:
            return "After"
        }
    }
}

extension StreamAppMetadataKind {
    var title: String {
        switch self {
        case .song:
            return "Song"
        case .event:
            return "Event"
        }
    }
}

extension StreamAppTimelineItemKind {
    var title: String {
        switch self {
        case .transcript:
            return "Transcript"
        case .song:
            return "Song"
        case .event:
            return "Event"
        }
    }

    var systemImage: String {
        switch self {
        case .transcript:
            return "text.bubble"
        case .song:
            return "music.note"
        case .event:
            return "flag"
        }
    }
}

extension StreamAppSpeakerDisplay {
    static func fallbackColorToken(for rawLabel: String) -> String {
        let total = rawLabel.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let tokens = ["blue", "green", "orange", "pink", "purple", "teal", "violet", "yellow"]
        return tokens[abs(total) % tokens.count]
    }

    var color: Color {
        switch colorToken {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "pink": return .pink
        case "purple": return .purple
        case "teal": return .teal
        case "violet": return .indigo
        case "yellow": return .yellow
        default: return .secondary
        }
    }
}

extension Color {
    var accessibleForeground: Color {
        self == .yellow ? .black : .white
    }
}
