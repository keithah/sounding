import Foundation
import GRDB

public enum StreamAppSpeakerDisplayProjectionError: Error, Equatable, Sendable {
    case malformedRow(String)
}

public enum StreamAppSpeakerDisplayProjection {
    public static let unknownSpeakerLabel = "Unknown speaker"
    public static let allowedColorTokens: [String] = [
        "blue", "green", "orange", "pink", "purple", "teal", "violet", "yellow",
    ]

    public static func overrides(
        streamID: Int64,
        db: Database
    ) throws -> [String: StreamAppSpeakerDisplay] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT raw_label, display_label, color_token, updated_at
                FROM stream_app_speaker_overrides
                WHERE stream_id = ?
                ORDER BY raw_label COLLATE NOCASE
                """,
            arguments: [streamID]
        )
        var result: [String: StreamAppSpeakerDisplay] = [:]
        for row in rows {
            guard let rawLabel: String = row["raw_label"] else {
                throw StreamAppSpeakerDisplayProjectionError.malformedRow("override_raw_label")
            }
            guard let displayLabel: String = row["display_label"] else {
                throw StreamAppSpeakerDisplayProjectionError.malformedRow("override_display_label")
            }
            guard let colorToken: String = row["color_token"] else {
                throw StreamAppSpeakerDisplayProjectionError.malformedRow("override_color_token")
            }
            result[rawLabel] = StreamAppSpeakerDisplay(
                rawLabel: rawLabel,
                displayLabel: displayLabel,
                colorToken: colorToken,
                updatedAt: row["updated_at"]
            )
        }
        return result
    }

    public static func display(
        rawLabel: String?,
        overrides: [String: StreamAppSpeakerDisplay]
    ) -> StreamAppSpeakerDisplay {
        let trimmed = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed?.isEmpty == false ? trimmed! : unknownSpeakerLabel
        if let override = overrides[normalized] { return override }
        return StreamAppSpeakerDisplay(
            rawLabel: normalized,
            displayLabel: normalized,
            colorToken: fallbackColorToken(for: normalized)
        )
    }

    public static func displays(
        rawLabels: [String?],
        overrides: [String: StreamAppSpeakerDisplay]
    ) -> [StreamAppSpeakerDisplay] {
        var seen: Set<String> = []
        var displays: [StreamAppSpeakerDisplay] = []
        for rawLabel in rawLabels {
            let display = display(rawLabel: rawLabel, overrides: overrides)
            if seen.insert(display.rawLabel).inserted {
                displays.append(display)
            }
        }
        return displays.sorted { lhs, rhs in
            lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }
    }

    public static func fallbackColorToken(for rawLabel: String) -> String {
        let total = rawLabel.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return allowedColorTokens[abs(total) % allowedColorTokens.count]
    }
}
