import Foundation

/// SoundingKit-owned monitor filter contract.
public enum MonitorFilter: Equatable, Sendable {
    case all
    case ad
    case classification(MarkerClassification)
    case markerType(String)

    public init(normalizing rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalized {
        case "all", "":
            self = .all
        case "ad":
            self = .ad
        case "ad_start", "ad-start", "adstart":
            self = .classification(.adStart)
        case "ad_end", "ad-end", "adend":
            self = .classification(.adEnd)
        case "unknown":
            self = .classification(.unknown)
        case "scte35", "id3", "icy":
            self = .markerType(normalized)
        default:
            throw MonitorError.invalidFilter(rawValue)
        }
    }
}
