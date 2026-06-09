import Foundation

public enum ProgramMetadataSource: String, Codable, Equatable, Sendable {
    case timedID3 = "timed_id3"
    case scte35 = "scte35"
    case icy
    case chromaprint
    case acoustID = "acoustid"
    case deterministicFingerprint = "deterministic_fingerprint"
    case other

    public init(raw rawValue: String?) {
        let normalized = (rawValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        if Self.timedID3Aliases.contains(normalized) {
            self = .timedID3
        } else if Self.scte35Aliases.contains(normalized) {
            self = .scte35
        } else if Self.icyAliases.contains(normalized) {
            self = .icy
        } else if Self.chromaprintAliases.contains(normalized) {
            self = .chromaprint
        } else if Self.acoustIDAliases.contains(normalized) {
            self = .acoustID
        } else if Self.deterministicFingerprintAliases.contains(normalized) {
            self = .deterministicFingerprint
        } else {
            self = .other
        }
    }

    public init(marker: AdMarker) {
        for rawValue in [marker.type, marker.source, marker.tag] {
            let source = ProgramMetadataSource(raw: rawValue)
            if source != .other {
                self = source
                return
            }
        }
        self = .other
    }

    private static let timedID3Aliases: Set<String> = [
        "id3",
        "id3v2",
        "timed_id3",
        "hls_id3",
        "hls_timed_id3",
    ]

    private static let scte35Aliases: Set<String> = [
        "scte",
        "scte35",
        "scte_35",
        "hls_scte35",
        "mpegts_scte35_section",
        "splice_insert",
    ]

    private static let icyAliases: Set<String> = [
        "icy",
        "icy_stream",
        "icecast",
        "streamtitle",
    ]

    private static let chromaprintAliases: Set<String> = [
        "chromaprint",
    ]

    private static let acoustIDAliases: Set<String> = [
        "acoustid",
        "acoust_id",
    ]

    private static let deterministicFingerprintAliases: Set<String> = [
        "deterministic_fingerprint",
        "fingerprint",
        "test_fingerprint",
    ]

    public var isTimedMetadata: Bool {
        self == .timedID3 || self == .scte35 || self == .icy
    }

    public var isAudioFingerprint: Bool {
        self == .chromaprint || self == .acoustID || self == .deterministicFingerprint
    }
}

public enum ProgramMetadataClassification: String, Codable, Equatable, Sendable {
    case music
    case nonMusic
    case unknown
}

public struct ProgramMetadata: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var source: ProgramMetadataSource
    public var classification: ProgramMetadataClassification

    public init(
        title: String,
        artist: String?,
        album: String?,
        source: ProgramMetadataSource
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.source = source
        self.classification = ProgramMetadataClassifier.classify(
            title: title,
            artist: artist,
            album: album,
            source: source,
            isUnknown: false
        )
    }

    public var songKey: String {
        [
            source.rawValue,
            artist ?? "",
            title,
            album ?? ""
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .joined(separator: ":")
    }
}

public enum ProgramMetadataClassifier {
    public static func classify(
        title: String,
        artist: String?,
        album: String?,
        source: ProgramMetadataSource,
        isUnknown: Bool
    ) -> ProgramMetadataClassification {
        if isUnknown {
            return .unknown
        }
        if looksLikeNonMusic(title: title, artist: artist, album: album) {
            return .nonMusic
        }
        if source.isTimedMetadata || source.isAudioFingerprint {
            return .music
        }
        return .unknown
    }

    public static func isMusic(
        title: String,
        artist: String?,
        album: String?,
        source: ProgramMetadataSource,
        isUnknown: Bool
    ) -> Bool {
        classify(title: title, artist: artist, album: album, source: source, isUnknown: isUnknown) == .music
    }

    public static func looksLikeNonMusic(title: String, artist: String?, album: String?) -> Bool {
        let values = [title, artist, album].compactMap { $0?.lowercased() }
        let joined = values.joined(separator: " ")
        let tokens = Set(
            joined
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        if tokens.contains("ad") || tokens.contains("ads") {
            return true
        }
        let nonMusicPhraseHints = [
            "advert", "commercial", "promo", "sponsor", "stingray", "tunein",
            "station", "break", "padult", "sweeper", "imaging", "bumper",
            "be right back", "back soon", "will return", "returns shortly"
        ]
        if nonMusicPhraseHints.contains(where: { joined.contains($0) }) {
            return true
        }
        let compactTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        if compactTitle.count <= 16,
            compactTitle.rangeOfCharacter(from: codeCharacters.inverted) == nil,
            compactTitle.rangeOfCharacter(from: .decimalDigits) != nil
        {
            return true
        }
        return false
    }
}

public enum ProgramMetadataExtractor {
    public static func metadata(from marker: AdMarker) -> ProgramMetadata? {
        let source = ProgramMetadataSource(marker: marker)
        guard source.isTimedMetadata else { return nil }
        if source == .icy {
            return icyMetadata(from: marker, source: source)
        }
        guard let title = firstNonEmptyJSONValue(
            from: marker.tags,
            keys: ["TIT2", "Title", "title", "ProgramTitle", "Program"]
        ) ?? firstNonEmptyJSONValue(
            from: marker.fields,
            keys: ["TIT2", "Title", "title", "ProgramTitle", "Program"]
        ) else {
            return nil
        }
        let artist = firstNonEmptyJSONValue(
            from: marker.tags,
            keys: ["TPE1", "Artist", "artist", "Performer", "Provider"]
        ) ?? firstNonEmptyJSONValue(
            from: marker.fields,
            keys: ["TPE1", "Artist", "artist", "Performer", "Provider"]
        )
        let album = firstNonEmptyJSONValue(
            from: marker.tags,
            keys: ["TALB", "Album", "album"]
        ) ?? firstNonEmptyJSONValue(
            from: marker.fields,
            keys: ["TALB", "Album", "album", "Series"]
        )
        return ProgramMetadata(title: title, artist: artist, album: album, source: source)
    }

    private static func icyMetadata(from marker: AdMarker, source: ProgramMetadataSource) -> ProgramMetadata? {
        let explicitTitle = firstNonEmptyJSONValue(
            from: marker.fields,
            keys: ["Title", "title", "TIT2", "ProgramTitle", "Program"]
        )
        let explicitArtist = firstNonEmptyJSONValue(
            from: marker.fields,
            keys: ["Artist", "artist", "TPE1", "Performer", "Provider"]
        )
        let streamTitle = firstNonEmptyJSONValue(from: marker.fields, keys: ["StreamTitle"])

        let split = streamTitle.flatMap(splitStreamTitle)
        guard let title = explicitTitle ?? split?.title ?? streamTitle else { return nil }
        let artist = explicitArtist ?? split?.artist
        let album = firstNonEmptyJSONValue(
            from: marker.fields,
            keys: ["Album", "album", "TALB", "Series", "StreamUrl"]
        )
        return ProgramMetadata(title: title, artist: artist, album: album, source: source)
    }

    private static func splitStreamTitle(_ value: String) -> (artist: String, title: String)? {
        for separator in [" - ", " – ", " — "] {
            let parts = value.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }
            let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = parts.dropFirst().joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty && !title.isEmpty {
                return (artist, title)
            }
        }
        return nil
    }

    private static func firstNonEmptyJSONValue(
        from values: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = nonEmptyString(from: values[key]) {
                return value
            }
        }
        return nil
    }

    private static func nonEmptyString(from value: JSONValue?) -> String? {
        guard case let .string(raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
