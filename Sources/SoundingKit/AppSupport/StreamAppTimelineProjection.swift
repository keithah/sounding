import Foundation

struct StreamAppTimelineMetadataIndex: Sendable {
    private let songMetadata: [StreamAppMetadataItem]
    private let confirmedSongMetadata: [StreamAppMetadataItem]
    private let songBoundaryStarts: [Double]
    private let artistSongMetadata: [StreamAppMetadataItem]

    init(metadataChanges: [StreamAppMetadataItem]) {
        let songMetadata = metadataChanges
            .filter { $0.kind == .song }
            .sorted(by: StreamAppTimelineProjection.metadataSort)
        self.songMetadata = songMetadata
        self.confirmedSongMetadata = songMetadata.filter(Self.isConfirmedMusicMetadata)
        self.songBoundaryStarts = songMetadata.map(\.startSeconds).sorted()
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
}

public struct StreamAppTimelineProjection: Sendable {
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
        let metadataIndex = StreamAppTimelineMetadataIndex(metadataChanges: metadataChanges)
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
            transcriptParagraphsWithMetadataSpeakers(paragraphs, metadataIndex: metadataIndex),
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
                speakerDisplay: Self.metadataSpeakerDisplay(for: item),
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
        let eventItems = items.filter { $0.kind != .song }
        let songItems = items.filter { $0.kind == .song }
        let samplesByTimestamp = Dictionary(grouping: songItems) { item in
            Int((item.startSeconds * 10).rounded())
        }
        let sorted = (samplesByTimestamp.values.compactMap(Self.preferredMetadataSample) + eventItems).sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        var coalesced: [StreamAppMetadataItem] = []
        for item in sorted {
            if item.kind != .song {
                coalesced.append(item)
                continue
            }
            if let last = coalesced.last {
                if Self.shouldSuppressFingerprintGuess(after: last, candidate: item) {
                    coalesced[coalesced.count - 1].endSeconds = max(
                        coalesced[coalesced.count - 1].endSeconds ?? last.startSeconds,
                        item.endSeconds ?? item.startSeconds
                    )
                    coalesced[coalesced.count - 1].endTimestamp = item.endTimestamp
                    continue
                }
                if Self.isSameMetadataChange(last, item) {
                    coalesced[coalesced.count - 1].endSeconds = max(
                        coalesced[coalesced.count - 1].endSeconds ?? last.startSeconds,
                        item.endSeconds ?? item.startSeconds
                    )
                    coalesced[coalesced.count - 1].endTimestamp = item.endTimestamp
                    continue
                }
                coalesced[coalesced.count - 1].endSeconds = item.startSeconds
                coalesced[coalesced.count - 1].endTimestamp = item.startTimestamp
            }
            var next = item
            next.endSeconds = item.endSeconds ?? item.startSeconds + 8
            coalesced.append(next)
        }
        return coalesced
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
                !metadataIndex.overlapsConfirmedSong(
                    startSeconds: paragraph.startSeconds,
                    endSeconds: paragraph.endSeconds
                )
            }
        }
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
        lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.subtitle == rhs.subtitle
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
        let source = (item.source ?? item.id).lowercased()
        return source.contains("scte")
            || source.contains("id3")
            || source.contains("timed")
            || item.id.hasPrefix("event:")
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
                let last = result.last,
                last.kind == .song,
                Self.isSameTimelineMetadata(last, item)
            {
                result[result.count - 1] = item
            } else {
                result.append(item)
            }
        }
        return result
    }

    private static func isSameTimelineMetadata(
        _ lhs: StreamAppTimelineItem,
        _ rhs: StreamAppTimelineItem
    ) -> Bool {
        lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.speakerDisplay?.displayLabel == rhs.speakerDisplay?.displayLabel
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
            let smallGap = paragraph.startSeconds - last.endSeconds <= 12
            let boundedDuration = paragraph.endSeconds - last.startSeconds <= 60
            let noMetadataBoundary = !metadataIndex.hasSongBoundary(
                after: last.endSeconds,
                before: paragraph.startSeconds
            )
            if sameSpeaker && smallGap && boundedDuration && noMetadataBoundary {
                result[result.count - 1] = Self.mergedTranscriptParagraph(last, paragraph)
            } else {
                result.append(paragraph)
            }
        }
        return result
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
