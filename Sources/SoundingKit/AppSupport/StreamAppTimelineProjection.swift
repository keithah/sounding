import Foundation

struct StreamAppTimelineMetadataIndex: Sendable {
    struct AdWindow: Equatable, Sendable {
        var id: String
        var startSeconds: Double
        var endSeconds: Double
    }

    private let songMetadata: [StreamAppMetadataItem]
    private let confirmedSongMetadata: [StreamAppMetadataItem]
    private let adWindows: [AdWindow]
    private let nonSongWindows: [AdWindow]
    private let songBoundaryStarts: [Double]
    private let timelineCutPoints: [Double]
    private let artistSongMetadata: [StreamAppMetadataItem]

    init(metadataChanges: [StreamAppMetadataItem], timelineCutPointMetadata: [StreamAppMetadataItem]? = nil) {
        let songMetadata = metadataChanges
            .filter { $0.kind == .song }
            .sorted(by: StreamAppTimelineProjection.metadataSort)
        self.songMetadata = songMetadata
        self.confirmedSongMetadata = songMetadata.filter(Self.isConfirmedMusicMetadata)
        self.adWindows = Self.adWindows(from: metadataChanges)
        self.nonSongWindows = Self.nonSongWindows(from: metadataChanges)
        self.songBoundaryStarts = songMetadata.map(\.startSeconds).sorted()
        let cutPointMetadata = timelineCutPointMetadata ?? metadataChanges
        self.timelineCutPoints = Self.timelineCutPoints(from: cutPointMetadata)
        self.artistSongMetadata = songMetadata
            .filter { Self.firstNonEmpty([$0.artist]) != nil }
    }

    func recentSongs(limit: Int) -> [StreamAppMetadataItem] {
        Array(songMetadata.prefix(limit))
    }

    func currentSong(at playerPosition: Double?) -> StreamAppMetadataItem? {
        guard let playerPosition else {
            return songMetadata.first
        }
        if let exactMatch = songMetadata.first(where: { item in
            item.startSeconds <= playerPosition
                && (item.endSeconds ?? item.startSeconds) >= playerPosition
        }) {
            return exactMatch
        }
        return songMetadata.first { item in
            item.startSeconds <= playerPosition
        }
    }

    func hasSongBoundary(after lowerBound: Double, before upperBound: Double) -> Bool {
        guard lowerBound < upperBound else { return false }
        let index = firstBoundaryIndex(greaterThan: lowerBound)
        return index < songBoundaryStarts.count && songBoundaryStarts[index] <= upperBound
    }

    func hasTimelineBoundary(after lowerBound: Double, before upperBound: Double) -> Bool {
        !timelineBoundaries(after: lowerBound, before: upperBound).isEmpty
    }

    func timelineBoundaries(after lowerBound: Double, before upperBound: Double) -> [Double] {
        guard lowerBound < upperBound else { return [] }
        let adBoundarySeconds = adWindows.flatMap { [$0.startSeconds, $0.endSeconds] }
        return Array(Set(adBoundarySeconds + timelineCutPoints))
            .filter { $0 > lowerBound && $0 < upperBound }
            .sorted()
    }

    func artistMetadata(containingMidpoint midpoint: Double) -> StreamAppMetadataItem? {
        artistSongMetadata.first { item in
            let endSeconds = item.endSeconds ?? item.startSeconds + 8
            return item.startSeconds <= midpoint && endSeconds >= midpoint
        }
    }

    func overlapsConfirmedSong(startSeconds: Double, endSeconds: Double) -> Bool {
        confirmedSongMetadata.contains { item in
            let itemEnd = item.endSeconds ?? item.startSeconds + 8
            return max(startSeconds, item.startSeconds) < min(endSeconds, itemEnd)
        }
    }

    func overlapsAdBoundary(startSeconds: Double, endSeconds: Double) -> Bool {
        adWindow(overlappingStart: startSeconds, endSeconds: endSeconds) != nil
    }

    func overlapsNonSongMetadata(startSeconds: Double, endSeconds: Double) -> Bool {
        nonSongWindows.contains { window in
            max(startSeconds, window.startSeconds) < min(endSeconds, window.endSeconds)
        }
    }

    func adWindow(overlappingStart startSeconds: Double, endSeconds: Double) -> AdWindow? {
        adWindows.first { window in
            max(startSeconds, window.startSeconds) < min(endSeconds, window.endSeconds)
        }
    }

    private func firstBoundaryIndex(greaterThan lowerBound: Double) -> Int {
        var low = 0
        var high = songBoundaryStarts.count
        while low < high {
            let mid = (low + high) / 2
            if songBoundaryStarts[mid] <= lowerBound {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    private static func isConfirmedMusicMetadata(_ item: StreamAppMetadataItem) -> Bool {
        ProgramMetadataClassifier.isMusic(
            title: item.title,
            artist: item.artist,
            album: item.subtitle,
            source: ProgramMetadataSource(raw: item.source),
            isUnknown: item.kind != .song || item.isUnknown
        )
    }

    private static func isAdBoundaryMetadata(_ item: StreamAppMetadataItem) -> Bool {
        isAdStartMetadata(item) || isAdEndMetadata(item)
    }

    private static func isAdStartMetadata(_ item: StreamAppMetadataItem) -> Bool {
        let text = [
            item.id,
            item.title,
            item.subtitle ?? "",
            item.source ?? "",
        ]
        .joined(separator: " ")
        .lowercased()
        return text.contains("ad break start")
            || text.contains(" advertisement ")
            || text.contains("cue-out")
            || text.contains("scte35") && (text.contains("duration") || text.contains(" ad"))
            || text.split(separator: " ").contains("ad")
    }

    private static func isAdEndMetadata(_ item: StreamAppMetadataItem) -> Bool {
        let text = [
            item.id,
            item.title,
            item.subtitle ?? "",
            item.source ?? "",
        ]
        .joined(separator: " ")
        .lowercased()
        return text.contains("ad break end")
            || text.contains("cue-in")
    }

    private static func adWindows(from items: [StreamAppMetadataItem]) -> [AdWindow] {
        let ordered = items.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        var windows: [AdWindow] = []
        var pendingStart: StreamAppMetadataItem?
        for item in ordered {
            if isAdStartMetadata(item) {
                if let start = pendingStart, item.startSeconds > start.startSeconds {
                    windows.append(AdWindow(id: start.id, startSeconds: start.startSeconds, endSeconds: item.startSeconds))
                }
                if let explicitEnd = explicitAdEndSeconds(for: item), explicitEnd > item.startSeconds {
                    windows.append(AdWindow(id: item.id, startSeconds: item.startSeconds, endSeconds: explicitEnd))
                    pendingStart = nil
                } else {
                    pendingStart = item
                }
                continue
            }
            if isAdEndMetadata(item), let start = pendingStart {
                let end = max(item.startSeconds, start.startSeconds)
                if end > start.startSeconds {
                    windows.append(AdWindow(id: start.id, startSeconds: start.startSeconds, endSeconds: end))
                }
                pendingStart = nil
                continue
            }
            if item.kind == .song, let start = pendingStart, item.startSeconds > start.startSeconds {
                windows.append(AdWindow(id: start.id, startSeconds: start.startSeconds, endSeconds: item.startSeconds))
                pendingStart = nil
            }
        }
        if let start = pendingStart {
            windows.append(AdWindow(id: start.id, startSeconds: start.startSeconds, endSeconds: start.startSeconds + 300))
        }
        return coalescedAdWindows(windows)
    }

    private static func nonSongWindows(from items: [StreamAppMetadataItem]) -> [AdWindow] {
        let ordered = items.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        var windows: [AdWindow] = []
        for (index, item) in ordered.enumerated() {
            guard isNonSongTimedMetadataEvent(item) else { continue }
            let end = ordered[(index + 1)...].first { next in
                next.startSeconds > item.startSeconds
                    && (next.kind == .song || isNonSongTimedMetadataEvent(next) || isAdEndMetadata(next))
            }?.startSeconds ?? item.startSeconds + 300
            guard end > item.startSeconds else { continue }
            windows.append(AdWindow(id: item.id, startSeconds: item.startSeconds, endSeconds: end))
        }
        return coalescedAdWindows(windows)
    }

    private static func timelineCutPoints(from items: [StreamAppMetadataItem]) -> [Double] {
        items.compactMap { item in
            guard isAdStartMetadata(item) || isNonSongTimedMetadataEvent(item) else {
                return nil
            }
            return item.startSeconds
        }
        .sorted()
    }

    private static func isNonSongTimedMetadataEvent(_ item: StreamAppMetadataItem) -> Bool {
        guard item.kind == .event, !isAdEndMetadata(item) else { return false }
        let source = [
            item.id,
            item.source ?? "",
            item.subtitle ?? "",
        ].joined(separator: " ").lowercased()
        let isICYMetadata = source.contains("icy")
            || source.contains("icecast")
            || source.contains("timed")
        guard isICYMetadata else { return false }
        return true
    }

    private static func explicitAdEndSeconds(for item: StreamAppMetadataItem) -> Double? {
        if let end = item.endSeconds, end > item.startSeconds {
            guard !isGenericAdStartWithoutDuration(item) else {
                return nil
            }
            return end
        }
        guard let duration = adDurationSeconds(for: item), duration > 0 else {
            return nil
        }
        return item.startSeconds + duration
    }

    private static func isGenericAdStartWithoutDuration(_ item: StreamAppMetadataItem) -> Bool {
        let title = item.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard title == "ad" || title == "advertisement" else { return false }
        return adDurationSeconds(for: item) == nil
    }

    private static func adDurationSeconds(for item: StreamAppMetadataItem) -> Double? {
        let text = [
            item.id,
            item.title,
            item.subtitle ?? "",
            item.source ?? "",
        ]
        .joined(separator: " ")
        .lowercased()
        let patterns = [
            #"duration\s+([0-9]+(?:\.[0-9]+)?)\s*s?"#,
            #"breakduration["':\s]+([0-9]+(?:\.[0-9]+)?)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text),
                  let value = Double(text[valueRange])
            else {
                continue
            }
            return value
        }
        return nil
    }

    private static func coalescedAdWindows(_ windows: [AdWindow]) -> [AdWindow] {
        let ordered = windows.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        var result: [AdWindow] = []
        for window in ordered {
            guard var last = result.last, window.startSeconds < last.endSeconds else {
                result.append(window)
                continue
            }
            last.endSeconds = max(last.endSeconds, window.endSeconds)
            result[result.count - 1] = last
        }
        return result
    }
}

public struct StreamAppTimelineProjection: Sendable {
    private static let maximumMergedAdTranscriptDuration = 60.0

    public let paragraphs: [StreamAppTranscriptParagraph]
    public let metadataChanges: [StreamAppMetadataItem]
    public let player: AppPlayerTimelineSnapshot?
    private let metadataIndex: StreamAppTimelineMetadataIndex

    public init(
        paragraphs: [StreamAppTranscriptParagraph],
        metadata: [StreamAppMetadataItem],
        player: AppPlayerTimelineSnapshot? = nil,
        transcriptionPolicy: StreamTranscriptionPolicy = .defaultValue
    ) {
        let metadataChanges = Self.coalescedMetadataChanges(metadata)
        self.metadataChanges = metadataChanges
        self.player = player
        let metadataIndex = StreamAppTimelineMetadataIndex(
            metadataChanges: metadataChanges,
            timelineCutPointMetadata: metadata
        )
        self.metadataIndex = metadataIndex
        self.paragraphs = Self.filteredParagraphs(
            paragraphs,
            policy: transcriptionPolicy,
            metadataIndex: metadataIndex
        )
    }

    public func recentMetadata(limit: Int) -> [StreamAppMetadataItem] {
        metadataIndex.recentSongs(limit: limit)
    }

    public func currentMetadata() -> StreamAppMetadataItem? {
        metadataIndex.currentSong(at: player?.positionSeconds)
    }

    public func timelineItems(limit: Int) -> [StreamAppTimelineItem] {
        let transcriptItems = coalescedTranscriptParagraphs(
            transcriptParagraphsWithMetadataSpeakers(
                Self.transcriptParagraphsSplitAtTimelineBoundaries(
                    paragraphs,
                    metadataIndex: metadataIndex
                ),
                metadataIndex: metadataIndex
            ),
            metadataIndex: metadataIndex
        ).map { paragraph in
            StreamAppTimelineItem(
                id: "transcript:\(paragraph.id)",
                kind: .transcript,
                startSeconds: paragraph.startSeconds,
                endSeconds: paragraph.endSeconds,
                startTimestamp: paragraph.startTimestamp,
                endTimestamp: paragraph.endTimestamp,
                title: paragraph.speakerDisplay.displayLabel,
                subtitle: paragraph.text,
                speakerDisplay: paragraph.speakerDisplay,
                isSeekable: isSeekable(paragraph.startSeconds)
            )
        }
        let metadataItems = metadataChanges.map { item in
            StreamAppTimelineItem(
                id: item.id,
                kind: item.kind == .song ? .song : .event,
                startSeconds: item.startSeconds,
                endSeconds: item.endSeconds,
                startTimestamp: item.startTimestamp,
                endTimestamp: item.endTimestamp,
                title: item.title,
                subtitle: item.subtitle,
                source: item.source,
                speakerDisplay: Self.metadataSpeakerDisplay(for: item),
                rawMetadata: item.rawMetadata,
                isSeekable: isSeekable(item.startSeconds)
            )
        }
        return Array(
            coalescedTimelineMetadataRuns(transcriptItems + metadataItems)
                .sorted(by: Self.timelineSort)
                .prefix(limit)
        )
    }

    static func metadataSort(_ lhs: StreamAppMetadataItem, _ rhs: StreamAppMetadataItem) -> Bool {
        if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds > rhs.startSeconds }
        return lhs.id < rhs.id
    }

    static func coalescedMetadataChanges(_ items: [StreamAppMetadataItem]) -> [StreamAppMetadataItem] {
        let normalizedItems = items.map(normalizedMetadataKindForDisplay)
        let eventItems = normalizedItems.filter { $0.kind != .song }
        let songItems = normalizedItems.filter { $0.kind == .song }
        let samplesByTimestamp = Dictionary(grouping: songItems) { item in
            Int((item.startSeconds * 10).rounded())
        }
        let sorted = (samplesByTimestamp.values.compactMap(Self.preferredMetadataSample) + eventItems).sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            if $0.kind != $1.kind { return $0.kind == .song }
            return $0.id < $1.id
        }
        var coalesced: [StreamAppMetadataItem] = []
        var activeSongIndex: Int?
        for item in sorted {
            if let activeSongIndex,
               activeSongIndex < coalesced.count,
               shouldMergeIntoActiveTrack(coalesced[activeSongIndex], candidate: item)
            {
                coalesced[activeSongIndex] = mergedTrackRun(coalesced[activeSongIndex], item)
                continue
            }
            if item.kind != .song {
                coalesced.append(item)
                continue
            }
            var item = item
            if firstNonEmpty([item.artist]) != nil {
                item = Self.removingPromotedTitleOnlyDuplicates(from: &coalesced, for: item)
                activeSongIndex = nil
            }
            if let last = coalesced.last {
                if Self.shouldSuppressFingerprintGuess(after: last, candidate: item) {
                    coalesced[coalesced.count - 1].endSeconds = max(
                        coalesced[coalesced.count - 1].endSeconds ?? last.startSeconds,
                        item.endSeconds ?? item.startSeconds
                    )
                    coalesced[coalesced.count - 1].endTimestamp = item.endTimestamp
                    if coalesced[coalesced.count - 1].kind == .song {
                        activeSongIndex = coalesced.count - 1
                    }
                    continue
                }
                if Self.isSameMetadataChange(last, item) {
                    coalesced[coalesced.count - 1].endSeconds = max(
                        coalesced[coalesced.count - 1].endSeconds ?? last.startSeconds,
                        item.endSeconds ?? item.startSeconds
                    )
                    coalesced[coalesced.count - 1].endTimestamp = item.endTimestamp
                    if coalesced[coalesced.count - 1].kind == .song {
                        activeSongIndex = coalesced.count - 1
                    }
                    continue
                }
                if let activeSongIndex, activeSongIndex < coalesced.count {
                    coalesced[activeSongIndex].endSeconds = item.startSeconds
                    coalesced[activeSongIndex].endTimestamp = item.startTimestamp
                } else if coalesced[coalesced.count - 1].kind == .song {
                    coalesced[coalesced.count - 1].endSeconds = item.startSeconds
                    coalesced[coalesced.count - 1].endTimestamp = item.startTimestamp
                }
            }
            var next = item
            next.endSeconds = item.endSeconds ?? item.startSeconds + 8
            coalesced.append(next)
            activeSongIndex = coalesced.count - 1
        }
        return coalescedTitleOnlyMetadataEchoes(
            coalescedAdBoundaryDuplicates(
                coalescedEventDuplicatesAgainstSongs(coalesced)
            )
        )
    }

    private static func coalescedTitleOnlyMetadataEchoes(
        _ items: [StreamAppMetadataItem]
    ) -> [StreamAppMetadataItem] {
        // Suppression policy: once an artist-backed song row exists for a given
        // title, drop matching title-only echoes until the track changes (i.e.,
        // until a different artist-backed title takes over). This is what the
        // user expects when an ICY title repeats while the same song is playing.
        var artistBackedTitleKeys = Set<String>()
        for item in items
        where item.kind == .song
            && firstNonEmpty([item.artist]) != nil
            && !isAdBoundaryEvent(item) {
            artistBackedTitleKeys.insert(metadataTitleKey(item))
        }

        var result: [StreamAppMetadataItem] = []
        var activeTitleOnlyIndexByKey: [String: Int] = [:]
        var activeArtistBackedTitleKey: String?
        var activeArtistBackedIndex: Int?
        for item in items {
            guard !isAdBoundaryEvent(item),
                  !metadataTitleKey(item).isEmpty,
                  !ProgramMetadataClassifier.looksLikeNonMusic(
                    title: item.title,
                    artist: item.artist,
                    album: item.subtitle
                  )
            else {
                result.append(item)
                continue
            }

            let titleKey = metadataTitleKey(item)
            let isArtistBacked = firstNonEmpty([item.artist]) != nil

            if isArtistBacked && item.kind == .song {
                activeArtistBackedTitleKey = titleKey
                activeArtistBackedIndex = result.count
            }

            if !isArtistBacked,
               artistBackedTitleKeys.contains(titleKey),
               activeArtistBackedTitleKey == titleKey
            {
                // We've already shown the artist-backed row for the active
                // track; suppress repeated title-only echoes until the track
                // changes.
                if let activeArtistBackedIndex,
                   activeArtistBackedIndex < result.count
                {
                    result[activeArtistBackedIndex].endSeconds = max(
                        result[activeArtistBackedIndex].endSeconds ?? result[activeArtistBackedIndex].startSeconds,
                        (item.endSeconds ?? item.startSeconds) + 8
                    )
                    result[activeArtistBackedIndex].endTimestamp = item.endTimestamp ?? result[activeArtistBackedIndex].endTimestamp
                }
                continue
            }

            let key = titleOnlyRunKey(item)
            if !isArtistBacked,
               let index = activeTitleOnlyIndexByKey[key],
               index < result.count,
               shouldMergeTitleOnlyEcho(result[index], item)
            {
                result[index] = mergedTrackRun(result[index], item)
                continue
            }

            result.append(item)
            if !isArtistBacked {
                activeTitleOnlyIndexByKey[key] = result.count - 1
            } else {
                activeTitleOnlyIndexByKey.removeValue(forKey: key)
            }
        }
        return result
    }

    private static func titleOnlyItem(
        _ item: StreamAppMetadataItem,
        isCoveredBy artistBackedSongs: [StreamAppMetadataItem]
    ) -> Bool {
        artistBackedSongs.contains { song in
            guard metadataTitleKey(song) == metadataTitleKey(item),
                  metadataArtistsAreCompatible(song, item)
            else { return false }
            let songEnd = song.endSeconds ?? song.startSeconds
            let itemEnd = item.endSeconds ?? item.startSeconds
            return item.startSeconds <= songEnd + 180
                && itemEnd >= song.startSeconds - 180
        }
    }

    private static func shouldMergeTitleOnlyEcho(
        _ existing: StreamAppMetadataItem,
        _ candidate: StreamAppMetadataItem
    ) -> Bool {
        guard firstNonEmpty([existing.artist]) == nil,
              firstNonEmpty([candidate.artist]) == nil,
              titleOnlyRunKey(existing) == titleOnlyRunKey(candidate)
        else { return false }
        let existingEnd = existing.endSeconds ?? existing.startSeconds
        let candidateEnd = candidate.endSeconds ?? candidate.startSeconds
        return candidate.startSeconds <= existingEnd + 300
            || candidateEnd <= existingEnd + 300
    }

    private static func titleOnlyRunKey(_ item: StreamAppMetadataItem) -> String {
        [
            metadataTitleKey(item),
            normalizedMetadataText(item.subtitle)
        ].joined(separator: "|")
    }

    private static func coalescedEventDuplicatesAgainstSongs(
        _ items: [StreamAppMetadataItem]
    ) -> [StreamAppMetadataItem] {
        var result: [StreamAppMetadataItem] = []
        var latestEventIndexByKey: [String: Int] = [:]
        for item in items {
            if item.kind == .event,
               let songIndex = matchingSongDuplicateIndex(item, in: result)
            {
                result[songIndex].endSeconds = max(
                    result[songIndex].endSeconds ?? result[songIndex].startSeconds,
                    (item.endSeconds ?? item.startSeconds) + 8
                )
                result[songIndex].endTimestamp = item.endTimestamp ?? result[songIndex].endTimestamp
                continue
            }
            if item.kind == .event && !isAdBoundaryEvent(item) {
                let key = eventDuplicateKey(item)
                if let index = latestEventIndexByKey[key], index < result.count,
                   shouldMergeRepeatedEvent(result[index], item)
                {
                    result[index].endSeconds = max(
                        result[index].endSeconds ?? result[index].startSeconds,
                        item.endSeconds ?? item.startSeconds
                    )
                    result[index].endTimestamp = item.endTimestamp ?? result[index].endTimestamp
                    continue
                }
                latestEventIndexByKey[key] = result.count
            }
            result.append(item)
        }
        return result
    }

    private static func coalescedAdBoundaryDuplicates(
        _ items: [StreamAppMetadataItem]
    ) -> [StreamAppMetadataItem] {
        var result: [StreamAppMetadataItem] = []
        var latestGenericAdIndex: Int?
        for item in items {
            guard isGenericAdEvent(item) else {
                result.append(item)
                if item.kind == .song || isExplicitAdBoundaryEvent(item) {
                    latestGenericAdIndex = nil
                }
                continue
            }
            if let index = latestGenericAdIndex,
               index < result.count,
               shouldMergeGenericAdEvent(result[index], item)
            {
                result[index].endSeconds = max(
                    result[index].endSeconds ?? result[index].startSeconds,
                    item.endSeconds ?? item.startSeconds
                )
                result[index].endTimestamp = item.endTimestamp ?? result[index].endTimestamp
                continue
            }
            result.append(item)
            latestGenericAdIndex = result.count - 1
        }
        return result
    }

    private static func shouldMergeGenericAdEvent(
        _ existing: StreamAppMetadataItem,
        _ candidate: StreamAppMetadataItem
    ) -> Bool {
        guard isGenericAdEvent(existing), isGenericAdEvent(candidate) else { return false }
        let existingEnd = existing.endSeconds ?? existing.startSeconds
        let candidateEnd = candidate.endSeconds ?? candidate.startSeconds
        return candidate.startSeconds <= existingEnd + 180
            || candidateEnd <= existingEnd + 180
    }

    private static func isGenericAdEvent(_ item: StreamAppMetadataItem) -> Bool {
        guard item.kind == .event else { return false }
        return normalizedMetadataText(item.title) == "ad"
            || normalizedMetadataText(item.title) == "advertisement"
    }

    private static func isExplicitAdBoundaryEvent(_ item: StreamAppMetadataItem) -> Bool {
        let text = [
            item.id,
            item.title,
            item.subtitle ?? "",
            item.source ?? "",
        ]
        .joined(separator: " ")
        .lowercased()
        return text.contains("ad break start")
            || text.contains("ad break end")
            || text.contains("cue-out")
            || text.contains("cue-in")
    }

    private static func matchingSongDuplicateIndex(
        _ event: StreamAppMetadataItem,
        in items: [StreamAppMetadataItem]
    ) -> Int? {
        guard !isAdBoundaryEvent(event),
              !metadataTitleKey(event).isEmpty
        else { return nil }
        return items.lastIndex { existing in
            guard existing.kind == .song,
                  metadataTitleKey(existing) == metadataTitleKey(event),
                  metadataArtistsAreCompatible(existing, event)
            else { return false }
            let existingEnd = existing.endSeconds ?? existing.startSeconds
            let eventEnd = event.endSeconds ?? event.startSeconds
            return event.startSeconds <= existingEnd + 180
                && eventEnd >= existing.startSeconds - 180
        }
    }

    private static func shouldMergeRepeatedEvent(
        _ existing: StreamAppMetadataItem,
        _ candidate: StreamAppMetadataItem
    ) -> Bool {
        guard existing.kind == .event,
              candidate.kind == .event,
              !isAdBoundaryEvent(existing),
              !isAdBoundaryEvent(candidate),
              eventDuplicateKey(existing) == eventDuplicateKey(candidate)
        else { return false }
        let existingEnd = existing.endSeconds ?? existing.startSeconds
        let candidateEnd = candidate.endSeconds ?? candidate.startSeconds
        return candidate.startSeconds <= existingEnd + 180
            || candidateEnd <= existingEnd + 180
    }

    private static func eventDuplicateKey(_ item: StreamAppMetadataItem) -> String {
        [
            metadataTitleKey(item),
            normalizedMetadataText(item.artist),
            normalizedMetadataText(item.subtitle)
        ].joined(separator: "|")
    }

    private static func normalizedMetadataKindForDisplay(
        _ item: StreamAppMetadataItem
    ) -> StreamAppMetadataItem {
        guard item.kind == .event, isSongLikeMetadataEvent(item) else {
            return item
        }
        var normalized = item
        normalized.kind = .song
        return normalized
    }

    private static func isSongLikeMetadataEvent(_ item: StreamAppMetadataItem) -> Bool {
        guard item.kind == .event else { return false }
        guard !isAdBoundaryEvent(item) else { return false }
        guard !ProgramMetadataClassifier.looksLikeNonMusic(
            title: item.title,
            artist: item.artist,
            album: item.subtitle
        ) else {
            return false
        }
        if firstNonEmpty([item.artist]) != nil {
            return true
        }
        let source = metadataSourceText(item)
        if ProgramMetadataSource(raw: source).isTimedMetadata {
            return true
        }
        return source.contains("hls_segment")
            || source.contains("icy_stream")
            || source.contains("timed")
            || source.contains("id3")
    }

    private static func isAdBoundaryEvent(_ item: StreamAppMetadataItem) -> Bool {
        let text = [
            item.id,
            item.title,
            item.subtitle ?? "",
            item.source ?? "",
        ]
        .joined(separator: " ")
        .lowercased()
        return text.contains("ad break start")
            || text.contains("ad break end")
            || text.contains(" advertisement ")
            || text.contains("cue-out")
            || text.contains("cue-in")
            || normalizedMetadataText(item.title) == "ad"
    }

    private static func removingPromotedTitleOnlyDuplicates(
        from coalesced: inout [StreamAppMetadataItem],
        for artistBackedSong: StreamAppMetadataItem
    ) -> StreamAppMetadataItem {
        var promoted = artistBackedSong
        let titleKey = metadataTitleKey(artistBackedSong)
        let lowerBoundIndex = coalesced.lastIndex { candidate in
            candidate.kind == .song
                && metadataTitleKey(candidate) != titleKey
                && !isAdBoundaryEvent(candidate)
        }.map { $0 + 1 } ?? coalesced.startIndex
        guard lowerBoundIndex < coalesced.endIndex else { return promoted }

        var indexesToRemove: [Int] = []
        for index in lowerBoundIndex..<coalesced.endIndex {
            let candidate = coalesced[index]
            guard metadataTitleKey(candidate) == titleKey,
                  metadataArtistMatchesOrIsMissing(candidate, artistBackedSong),
                  !ProgramMetadataClassifier.looksLikeNonMusic(
                    title: candidate.title,
                    artist: candidate.artist,
                    album: candidate.subtitle
                  )
            else { continue }
            if candidate.startSeconds < promoted.startSeconds {
                promoted.startSeconds = candidate.startSeconds
                promoted.startTimestamp = candidate.startTimestamp ?? promoted.startTimestamp
            }
            promoted.endSeconds = max(
                promoted.endSeconds ?? promoted.startSeconds,
                candidate.endSeconds ?? candidate.startSeconds
            )
            promoted.endTimestamp = candidate.endTimestamp ?? promoted.endTimestamp
            indexesToRemove.append(index)
        }

        for index in indexesToRemove.reversed() {
            coalesced.remove(at: index)
        }
        return promoted
    }

    private static func metadataArtistMatchesOrIsMissing(
        _ candidate: StreamAppMetadataItem,
        _ artistBackedSong: StreamAppMetadataItem
    ) -> Bool {
        metadataArtistsAreCompatible(candidate, artistBackedSong)
    }

    private static func metadataArtistsAreCompatible(
        _ lhs: StreamAppMetadataItem,
        _ rhs: StreamAppMetadataItem
    ) -> Bool {
        let lhsArtist = normalizedMetadataText(lhs.artist)
        let rhsArtist = normalizedMetadataText(rhs.artist)
        if lhsArtist.isEmpty || rhsArtist.isEmpty { return true }
        return lhsArtist == rhsArtist
    }

    private static func shouldMergeIntoActiveTrack(
        _ active: StreamAppMetadataItem,
        candidate: StreamAppMetadataItem
    ) -> Bool {
        guard active.kind == .song,
              metadataTitleKey(active) == metadataTitleKey(candidate),
              metadataArtistsAreCompatible(active, candidate),
              !ProgramMetadataClassifier.looksLikeNonMusic(
                title: candidate.title,
                artist: candidate.artist,
                album: candidate.subtitle
              )
        else {
            return false
        }
        let activeEnd = active.endSeconds ?? active.startSeconds
        let candidateEnd = candidate.endSeconds ?? candidate.startSeconds
        let overlapsOrFollows = candidate.startSeconds <= activeEnd + 180
            || candidateEnd <= activeEnd + 180
        return overlapsOrFollows
    }

    private static func mergedTrackRun(
        _ active: StreamAppMetadataItem,
        _ duplicate: StreamAppMetadataItem
    ) -> StreamAppMetadataItem {
        var merged = preferredMetadataSample([active, duplicate]) ?? active
        merged.startSeconds = min(active.startSeconds, duplicate.startSeconds)
        merged.startTimestamp = active.startSeconds <= duplicate.startSeconds
            ? (active.startTimestamp ?? duplicate.startTimestamp)
            : (duplicate.startTimestamp ?? active.startTimestamp)
        merged.endSeconds = max(
            active.endSeconds ?? active.startSeconds,
            duplicate.endSeconds ?? duplicate.startSeconds
        )
        merged.endTimestamp = duplicate.endTimestamp ?? active.endTimestamp
        return merged
    }

    private static func filteredParagraphs(
        _ paragraphs: [StreamAppTranscriptParagraph],
        policy: StreamTranscriptionPolicy,
        metadataIndex: StreamAppTimelineMetadataIndex
    ) -> [StreamAppTranscriptParagraph] {
        switch policy {
        case .always:
            return paragraphs
        case .hidden:
            return []
        case .nonSongs:
            return paragraphs.filter { paragraph in
                if metadataIndex.overlapsAdBoundary(
                    startSeconds: paragraph.startSeconds,
                    endSeconds: paragraph.endSeconds
                ) {
                    return true
                }
                if metadataIndex.overlapsNonSongMetadata(
                    startSeconds: paragraph.startSeconds,
                    endSeconds: paragraph.endSeconds
                ) {
                    return true
                }
                if isLikelyMusicTranscript(paragraph),
                   TranscriptAdScorer.score(paragraph: paragraph, neighbors: []).confidence < 0.50 {
                    return false
                }
                return !metadataIndex.overlapsConfirmedSong(
                    startSeconds: paragraph.startSeconds,
                    endSeconds: paragraph.endSeconds
                )
            }
        }
    }

    private static func isLikelyMusicTranscript(_ paragraph: StreamAppTranscriptParagraph) -> Bool {
        let normalized = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("♪") { return true }
        let musicTagCount = [
            "[music]",
            "[music playing]",
            "(upbeat music)",
            "(music)",
        ].filter { normalized.contains($0) }.count
        guard musicTagCount > 0 else { return false }
        let wordCount = normalized.split { !$0.isLetter && !$0.isNumber }.count
        return musicTagCount >= 2 || wordCount <= 24 || normalized.contains("lyrics")
    }

    private static func transcriptParagraphsSplitAtTimelineBoundaries(
        _ paragraphs: [StreamAppTranscriptParagraph],
        metadataIndex: StreamAppTimelineMetadataIndex
    ) -> [StreamAppTranscriptParagraph] {
        paragraphs.flatMap { paragraph in
            splitTranscriptParagraphAtTimelineBoundaries(paragraph, metadataIndex: metadataIndex)
        }
    }

    private static func splitTranscriptParagraphAtTimelineBoundaries(
        _ paragraph: StreamAppTranscriptParagraph,
        metadataIndex: StreamAppTimelineMetadataIndex
    ) -> [StreamAppTranscriptParagraph] {
        let boundaries = metadataIndex.timelineBoundaries(
            after: paragraph.startSeconds,
            before: paragraph.endSeconds
        )
        guard !boundaries.isEmpty, !paragraph.words.isEmpty else {
            return [paragraph]
        }

        let intervals = zip(
            [paragraph.startSeconds] + boundaries,
            boundaries + [paragraph.endSeconds]
        )
        var result: [StreamAppTranscriptParagraph] = []
        for (offset, interval) in intervals.enumerated() {
            let isLastInterval = offset == boundaries.count
            let words = paragraph.words.filter { word in
                let midpoint = (word.startSeconds + word.endSeconds) / 2
                if isLastInterval {
                    return midpoint >= interval.0 && midpoint <= interval.1
                }
                return midpoint >= interval.0 && midpoint < interval.1
            }
            guard !words.isEmpty else { continue }
            var split = paragraph
            split.id = paragraph.id * 10_000 + Int64(offset)
            split.sequence = paragraph.sequence * 10_000 + offset
            split.startSeconds = words.first?.startSeconds ?? interval.0
            split.endSeconds = words.last?.endSeconds ?? interval.1
            split.text = words.map(\.text).joined(separator: " ")
            split.words = words
            result.append(split)
        }
        return result.isEmpty ? [paragraph] : result
    }

    private static func preferredMetadataSample(_ items: [StreamAppMetadataItem]) -> StreamAppMetadataItem? {
        items.max { lhs, rhs in
            let lhsScore = metadataPreferenceScore(lhs)
            let rhsScore = metadataPreferenceScore(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
            return metadataIDNumber(lhs.id) < metadataIDNumber(rhs.id)
        }
    }

    private static func metadataPreferenceScore(_ item: StreamAppMetadataItem) -> Int {
        var score = item.kind == .song ? 100 : 0
        if isTrustedTimedMetadata(item) { score += 40 }
        if item.id.hasPrefix("song:") { score += 10 }
        if isFingerprintMetadata(item) { score -= 20 }
        if Self.firstNonEmpty([item.artist]) != nil { score += 20 }
        if !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 10 }
        if Self.firstNonEmpty([item.subtitle]) != nil { score += 1 }
        return score
    }

    private static func metadataIDNumber(_ id: String) -> Int64 {
        Int64(id.split(separator: ":").last ?? "") ?? 0
    }

    private static func isSameMetadataChange(
        _ lhs: StreamAppMetadataItem,
        _ rhs: StreamAppMetadataItem
    ) -> Bool {
        guard lhs.kind == rhs.kind,
              metadataTitleKey(lhs) == metadataTitleKey(rhs)
        else { return false }
        if lhs.kind == .song {
            return metadataArtistsAreCompatible(lhs, rhs)
        }
        return normalizedMetadataText(lhs.artist) == normalizedMetadataText(rhs.artist)
            && normalizedMetadataText(lhs.subtitle) == normalizedMetadataText(rhs.subtitle)
    }

    private static func metadataTitleKey(_ item: StreamAppMetadataItem) -> String {
        normalizedMetadataText(item.title)
    }

    private static func normalizedMetadataText(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func shouldSuppressFingerprintGuess(
        after trusted: StreamAppMetadataItem,
        candidate: StreamAppMetadataItem
    ) -> Bool {
        guard trusted.kind == .song,
              candidate.kind == .song,
              isTrustedTimedMetadata(trusted),
              isFingerprintMetadata(candidate),
              !isSameMetadataChange(trusted, candidate) else {
            return false
        }
        let trustedEnd = trusted.endSeconds ?? trusted.startSeconds
        let candidateEnd = candidate.endSeconds ?? candidate.startSeconds
        let gap = candidate.startSeconds - trustedEnd
        let overlaps = candidate.startSeconds <= trustedEnd
        let nearTimedMetadata = gap <= 30
        return overlaps || nearTimedMetadata || candidateEnd <= trustedEnd + 30
    }

    fileprivate static func isTrustedTimedMetadata(_ item: StreamAppMetadataItem) -> Bool {
        let source = metadataSourceText(item)
        return source.contains("scte")
            || source.contains("icy")
            || source.contains("icecast")
            || source.contains("id3")
            || source.contains("timed")
            || item.id.hasPrefix("event:")
    }

    private static func metadataSourceText(_ item: StreamAppMetadataItem) -> String {
        [
            item.source,
            item.subtitle,
            item.id
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }

    fileprivate static func isFingerprintMetadata(_ item: StreamAppMetadataItem) -> Bool {
        let source = (item.source ?? item.id).lowercased()
        return source.contains("fingerprint")
            || source.contains("chromaprint")
            || source.contains("acoust")
    }

    private func coalescedTimelineMetadataRuns(
        _ items: [StreamAppTimelineItem]
    ) -> [StreamAppTimelineItem] {
        let sorted = items.sorted(by: Self.timelineSort)
        var result: [StreamAppTimelineItem] = []
        for item in sorted {
            if item.kind == .song,
               let index = result.lastIndex(where: { Self.shouldMergeTimelineMetadata($0, item) })
            {
                result[index] = Self.mergedTimelineMetadata(result[index], item)
                continue
            }
            result.append(item)
        }
        return result
    }

    private static func shouldMergeTimelineMetadata(
        _ lhs: StreamAppTimelineItem,
        _ rhs: StreamAppTimelineItem
    ) -> Bool {
        guard lhs.kind == .song,
              rhs.kind == .song,
              normalizedMetadataText(lhs.title) == normalizedMetadataText(rhs.title)
        else {
            return false
        }
        let lhsArtist = normalizedMetadataText(lhs.speakerDisplay?.displayLabel)
        let rhsArtist = normalizedMetadataText(rhs.speakerDisplay?.displayLabel)
        if !lhsArtist.isEmpty && !rhsArtist.isEmpty && lhsArtist != rhsArtist {
            return false
        }
        let lhsEnd = lhs.endSeconds ?? lhs.startSeconds
        let rhsEnd = rhs.endSeconds ?? rhs.startSeconds
        return rhs.startSeconds <= lhsEnd + 300
            || rhsEnd <= lhsEnd + 300
    }

    private static func mergedTimelineMetadata(
        _ lhs: StreamAppTimelineItem,
        _ rhs: StreamAppTimelineItem
    ) -> StreamAppTimelineItem {
        let preferred = preferredTimelineMetadata(lhs, rhs)
        let earlier = lhs.startSeconds <= rhs.startSeconds ? lhs : rhs
        let later = (lhs.endSeconds ?? lhs.startSeconds) >= (rhs.endSeconds ?? rhs.startSeconds) ? lhs : rhs
        return StreamAppTimelineItem(
            id: preferred.id,
            kind: preferred.kind,
            startSeconds: min(lhs.startSeconds, rhs.startSeconds),
            endSeconds: max(lhs.endSeconds ?? lhs.startSeconds, rhs.endSeconds ?? rhs.startSeconds),
            startTimestamp: earlier.startTimestamp ?? preferred.startTimestamp,
            endTimestamp: later.endTimestamp ?? preferred.endTimestamp,
            title: preferred.title,
            subtitle: preferred.subtitle,
            source: preferred.source,
            speakerDisplay: preferred.speakerDisplay,
            rawMetadata: preferred.rawMetadata ?? lhs.rawMetadata ?? rhs.rawMetadata,
            isSeekable: lhs.isSeekable || rhs.isSeekable,
            isAd: preferred.isAd,
            colorToken: preferred.colorToken,
            confidence: preferred.confidence,
            signals: preferred.signals,
            brand: preferred.brand,
            product: preferred.product,
            adType: preferred.adType
        )
    }

    private static func preferredTimelineMetadata(
        _ lhs: StreamAppTimelineItem,
        _ rhs: StreamAppTimelineItem
    ) -> StreamAppTimelineItem {
        let lhsHasArtist = !(lhs.speakerDisplay?.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let rhsHasArtist = !(rhs.speakerDisplay?.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if lhsHasArtist != rhsHasArtist {
            return rhsHasArtist ? rhs : lhs
        }
        let lhsHasSubtitle = !(lhs.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let rhsHasSubtitle = !(rhs.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if lhsHasSubtitle != rhsHasSubtitle {
            return rhsHasSubtitle ? rhs : lhs
        }
        return rhs
    }

    private func coalescedTranscriptParagraphs(
        _ paragraphs: [StreamAppTranscriptParagraph],
        metadataIndex: StreamAppTimelineMetadataIndex
    ) -> [StreamAppTranscriptParagraph] {
        let sorted = paragraphs.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        var result: [StreamAppTranscriptParagraph] = []
        for paragraph in sorted {
            guard let last = result.last else {
                result.append(paragraph)
                continue
            }
            let sameSpeaker = last.speakerDisplay == paragraph.speakerDisplay
            let sameAdWindow = Self.sameAdWindow(last, paragraph, metadataIndex: metadataIndex)
            let smallGap = paragraph.startSeconds - last.endSeconds <= 12
            let boundedDuration = paragraph.endSeconds - last.startSeconds <= 30
            let boundedAdDuration = paragraph.endSeconds - last.startSeconds <= Self.maximumMergedAdTranscriptDuration
            let noMetadataBoundary = !metadataIndex.hasSongBoundary(
                after: last.endSeconds,
                before: paragraph.startSeconds
            )
            let noTimelineBoundary = !metadataIndex.hasTimelineBoundary(
                after: last.endSeconds,
                before: paragraph.startSeconds
            )
            if (sameAdWindow && smallGap && boundedAdDuration && noTimelineBoundary)
                || (sameSpeaker && smallGap && boundedDuration && noMetadataBoundary && noTimelineBoundary) {
                result[result.count - 1] = Self.mergedTranscriptParagraph(last, paragraph)
            } else {
                result.append(paragraph)
            }
        }
        return result
    }

    private static func sameAdWindow(
        _ lhs: StreamAppTranscriptParagraph,
        _ rhs: StreamAppTranscriptParagraph,
        metadataIndex: StreamAppTimelineMetadataIndex
    ) -> Bool {
        guard let lhsWindow = metadataIndex.adWindow(
            overlappingStart: lhs.startSeconds,
            endSeconds: lhs.endSeconds
        ),
            let rhsWindow = metadataIndex.adWindow(
                overlappingStart: rhs.startSeconds,
                endSeconds: rhs.endSeconds
            )
        else {
            return false
        }
        return lhsWindow == rhsWindow
    }

    private func transcriptParagraphsWithMetadataSpeakers(
        _ paragraphs: [StreamAppTranscriptParagraph],
        metadataIndex: StreamAppTimelineMetadataIndex
    ) -> [StreamAppTranscriptParagraph] {
        paragraphs.map { paragraph in
            guard let metadataItem = metadataSpeakerMetadata(for: paragraph, metadataIndex: metadataIndex),
                  let speaker = Self.metadataSpeakerDisplay(for: metadataItem) else {
                return paragraph
            }
            var updated = paragraph
            updated.speakerDisplay = speaker
            updated.words = updated.words.map { word in
                var updatedWord = word
                updatedWord.speakerDisplay = speaker
                return updatedWord
            }
            return updated
        }
    }

    private func metadataSpeakerMetadata(
        for paragraph: StreamAppTranscriptParagraph,
        metadataIndex: StreamAppTimelineMetadataIndex
    ) -> StreamAppMetadataItem? {
        let midpoint = (paragraph.startSeconds + paragraph.endSeconds) / 2
        return metadataIndex.artistMetadata(containingMidpoint: midpoint)
    }

    private static func mergedTranscriptParagraph(
        _ lhs: StreamAppTranscriptParagraph,
        _ rhs: StreamAppTranscriptParagraph
    ) -> StreamAppTranscriptParagraph {
        StreamAppTranscriptParagraph(
            id: lhs.id,
            streamID: lhs.streamID,
            runID: lhs.runID,
            chunkID: lhs.chunkID,
            sequence: lhs.sequence,
            speakerDisplay: lhs.speakerDisplay,
            startSeconds: lhs.startSeconds,
            endSeconds: rhs.endSeconds,
            startTimestamp: lhs.startTimestamp,
            endTimestamp: rhs.endTimestamp,
            text: joinedTranscriptText(lhs.text, rhs.text),
            confidence: [lhs.confidence, rhs.confidence].compactMap { $0 }.min(),
            words: lhs.words + rhs.words
        )
    }

    private static func joinedTranscriptText(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    private static func metadataSpeakerDisplay(for item: StreamAppMetadataItem) -> StreamAppSpeakerDisplay? {
        guard item.kind == .song, let artist = Self.firstNonEmpty([item.artist]) else { return nil }
        return StreamAppSpeakerDisplay(
            rawLabel: artist,
            displayLabel: artist,
            colorToken: StreamAppSpeakerDisplayProjection.fallbackColorToken(for: artist)
        )
    }

    private static func timelineSort(_ lhs: StreamAppTimelineItem, _ rhs: StreamAppTimelineItem) -> Bool {
        if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id < rhs.id
    }

    private func isSeekable(_ seconds: Double) -> Bool {
        guard let player, player.streamID != nil else { return false }
        if let start = player.bufferedStartSeconds, let end = player.bufferedEndSeconds {
            return seconds >= start && seconds <= end
        }
        if let range = player.rollingBuffer?.bufferedRange {
            return seconds >= range.startSeconds && seconds <= range.endSeconds
        }
        return false
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }
}
