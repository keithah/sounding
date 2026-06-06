import Foundation

/// Stateful marker classifier for source-specific semantic transitions.
///
/// The classifier intentionally keeps state on the instance so each monitor run or stream can
/// classify transitions independently without cross-stream bleed.
public struct MarkerClassifier: Sendable {
    private var icyAdIsActive: Bool

    public init() {
        self.icyAdIsActive = false
    }

    public mutating func classify(_ marker: AdMarker) -> AdMarker {
        if let hlsCueClassification = Self.classifyHLSCueTag(marker.tag) {
            return markerWithClassification(marker, hlsCueClassification)
        }

        if marker.type.caseInsensitiveCompare("ICY") == .orderedSame {
            guard let streamTitle = streamTitle(from: marker) else {
                return markerWithClassification(marker, .unknown)
            }

            return markerWithClassification(marker, classifyICYTitle(streamTitle))
        }

        if marker.type.caseInsensitiveCompare("SCTE35") == .orderedSame {
            return markerWithClassification(marker, Self.classifySCTE35(marker))
        }

        if marker.type.caseInsensitiveCompare("ID3") == .orderedSame {
            return markerWithClassification(marker, Self.classifyTextCandidates(Self.id3TextCandidates(from: marker)))
        }

        return markerWithClassification(marker, .unknown)
    }

    private mutating func classifyICYTitle(_ title: String) -> MarkerClassification {
        let normalizedTitle = title.lowercased()
        let isAdTitle = Self.startsWithAdWord(normalizedTitle)
        let isExplicitEnd = Self.containsEndKeyword(normalizedTitle)

        if icyAdIsActive {
            if isExplicitEnd || !isAdTitle {
                icyAdIsActive = false
                return .adEnd
            }

            return .unknown
        }

        if isAdTitle {
            icyAdIsActive = true
            return .adStart
        }

        return .unknown
    }

    private func streamTitle(from marker: AdMarker) -> String? {
        Self.nonEmptyString(from: marker.fields["StreamTitle"])
    }

    private func markerWithClassification(
        _ marker: AdMarker,
        _ classification: MarkerClassification
    ) -> AdMarker {
        var classified = marker
        classified.classification = classification
        return classified
    }

    private static func classifyHLSCueTag(_ tag: String?) -> MarkerClassification? {
        guard let rawTag = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTag.isEmpty else {
            return nil
        }

        let tagName = rawTag.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? rawTag
        switch tagName.uppercased() {
        case "#EXT-X-CUE-OUT":
            return .adStart
        case "#EXT-X-CUE-IN":
            return .adEnd
        default:
            return nil
        }
    }

    private static func classifySCTE35(_ marker: AdMarker) -> MarkerClassification {
        let commandName = normalizedCommandName(from: marker)

        switch commandName {
        case "SPLICE_INSERT_OON_TRUE":
            return .adStart
        case "SPLICE_INSERT_OON_FALSE":
            return .adEnd
        case "SPLICE_INSERT":
            if let outOfNetworkIndicator = outOfNetworkIndicator(from: marker) {
                return outOfNetworkIndicator ? .adStart : .adEnd
            }
            return .adStart
        case "TIME_SIGNAL":
            let ids = segmentationTypeIDs(from: marker)
            if ids.isEmpty {
                if hasSegmentationIntent(marker) {
                    // Caller provided a segmentation field/descriptor but we
                    // couldn't parse it — fail closed rather than guess.
                    return .unknown
                }
                // TIME_SIGNAL without any segmentation descriptor is, in
                // practice, almost always an ad insertion cue. Default to
                // adStart so it doesn't appear as UNKNOWN in the timeline.
                return .adStart
            }
            return classifySegmentationTypeIDs(ids)
        default:
            return .unknown
        }
    }

    private static func normalizedCommandName(from marker: AdMarker) -> String? {
        let rawName = nonEmptyString(from: marker.fields["CommandName"])
            ?? stringValue(for: "CommandName", in: marker.command)
            ?? stringValue(for: "Name", in: marker.command)

        guard let rawName else { return nil }
        return normalizeCommandName(rawName)
    }

    private static func normalizeCommandName(_ rawName: String) -> String {
        rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber {
                    return character
                }
                return "_"
            }
            .reduce(into: "") { partial, character in
                if character == "_", partial.last == "_" {
                    return
                }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func outOfNetworkIndicator(from marker: AdMarker) -> Bool? {
        boolValue(for: "OutOfNetworkIndicator", in: marker.command)
            ?? boolValue(from: marker.fields["OutOfNetworkIndicator"])
    }

    private static func classifySegmentationTypeIDs(_ ids: [Int]) -> MarkerClassification {
        if ids.contains(where: isAdEndSegmentationTypeID) {
            return .adEnd
        }
        if ids.contains(where: isAdStartSegmentationTypeID) {
            return .adStart
        }
        return .unknown
    }

    private static func hasSegmentationIntent(_ marker: AdMarker) -> Bool {
        if marker.fields["SegmentationTypeID"] != nil { return true }
        for descriptor in marker.descriptors {
            guard case let .object(object) = descriptor else { continue }
            if object["SegmentationTypeID"] != nil { return true }
        }
        return false
    }

    private static func segmentationTypeIDs(from marker: AdMarker) -> [Int] {
        var ids = [Int]()

        if let id = intValue(from: marker.fields["SegmentationTypeID"]) {
            ids.append(id)
        }

        for descriptor in marker.descriptors {
            guard case let .object(object) = descriptor,
                  let id = intValue(from: object["SegmentationTypeID"]) else {
                continue
            }
            ids.append(id)
        }

        return ids
    }

    private static func isAdStartSegmentationTypeID(_ id: Int) -> Bool {
        // Provider/Distributor ad (0x30/32), placement opportunities (0x34/36),
        // overlay placement (0x38), unscheduled events (0x40/42), alternate
        // content (0x44), promo (0x46/48), network (0x4A/4C). Even IDs in the
        // 0x30-0x4F band are starts per SCTE-35.
        [0x30, 0x32, 0x34, 0x36, 0x38, 0x40, 0x42, 0x44, 0x46, 0x48, 0x4A, 0x4C]
            .contains(id)
    }

    private static func isAdEndSegmentationTypeID(_ id: Int) -> Bool {
        [0x31, 0x33, 0x35, 0x37, 0x39, 0x41, 0x43, 0x45, 0x47, 0x49, 0x4B, 0x4D]
            .contains(id)
    }

    private static func id3TextCandidates(from marker: AdMarker) -> [String] {
        var candidates = marker.tags.values.compactMap(nonEmptyString(from:))

        guard case let .array(frames)? = marker.fields["Frames"] else {
            return candidates
        }

        for frame in frames {
            guard case let .object(frameObject) = frame else { continue }
            if let description = nonEmptyString(from: frameObject["Description"]) {
                candidates.append(description)
            }
            if let text = nonEmptyString(from: frameObject["Text"]) {
                candidates.append(text)
            }
            if case let .array(texts)? = frameObject["Texts"] {
                candidates.append(contentsOf: texts.compactMap(nonEmptyString(from:)))
            }
        }

        return candidates
    }

    private static func classifyTextCandidates(_ candidates: [String]) -> MarkerClassification {
        if candidates.contains(where: containsEndKeyword) {
            return .adEnd
        }
        if candidates.contains(where: containsStartWord) {
            return .adStart
        }
        return .unknown
    }

    private static func containsEndKeyword(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("ad_end") || normalized.contains("content_start")
    }

    private static func containsStartWord(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return ["ad", "advertisement", "spot", "promo", "commercial"].contains { word in
            containsWord(word, in: normalized)
        }
    }

    private static func startsWithAdWord(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstWordStart = trimmed.firstIndex { scalarBoundaryCharacter in
            scalarBoundaryCharacter.unicodeScalars.contains { isWordScalar($0) }
        } ?? trimmed.endIndex
        guard firstWordStart < trimmed.endIndex else { return false }
        let candidate = String(trimmed[firstWordStart...])
        return ["ad", "advertisement", "spot", "promo", "commercial"].contains { word in
            guard candidate.hasPrefix(word) else { return false }
            let end = candidate.index(candidate.startIndex, offsetBy: word.count)
            return isBoundary(after: end, in: candidate)
        }
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: word, options: [], range: searchRange) {
            if isBoundary(before: range.lowerBound, in: text), isBoundary(after: range.upperBound, in: text) {
                return true
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }

    private static func isBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex, let previous = text[..<index].unicodeScalars.last else {
            return true
        }
        return !isWordScalar(previous)
    }

    private static func isBoundary(after index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex, let next = text[index...].unicodeScalars.first else {
            return true
        }
        return !isWordScalar(next)
    }

    private static func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static func stringValue(for key: String, in value: JSONValue?) -> String? {
        guard case let .object(object)? = value else { return nil }
        return nonEmptyString(from: object[key])
    }

    private static func boolValue(for key: String, in value: JSONValue?) -> Bool? {
        guard case let .object(object)? = value else { return nil }
        return boolValue(from: object[key])
    }

    private static func nonEmptyString(from value: JSONValue?) -> String? {
        guard case let .string(rawValue)? = value else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolValue(from value: JSONValue?) -> Bool? {
        switch value {
        case let .bool(value):
            return value
        case let .string(rawValue):
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func intValue(from value: JSONValue?) -> Int? {
        switch value {
        case let .number(value):
            guard value.isFinite, value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        case let .string(rawValue):
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("0x") {
                return Int(trimmed.dropFirst(2), radix: 16)
            }
            return Int(trimmed)
        default:
            return nil
        }
    }
}
