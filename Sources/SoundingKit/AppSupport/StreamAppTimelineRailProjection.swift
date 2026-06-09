import Foundation

public enum StreamAppTimelineRailProjection {
    public static func project(
        metadata: [StreamAppMetadataItem],
        visibleStartSeconds: Double,
        visibleEndSeconds: Double
    ) -> StreamAppTimelineRailSnapshot {
        project(
            metadata: metadata,
            paragraphs: [],
            visibleStartSeconds: visibleStartSeconds,
            visibleEndSeconds: visibleEndSeconds
        )
    }

    public static func project(
        metadata: [StreamAppMetadataItem],
        paragraphs: [StreamAppTranscriptParagraph],
        visibleStartSeconds: Double,
        visibleEndSeconds: Double
    ) -> StreamAppTimelineRailSnapshot {
        let items = broadcastItems(from: metadata)
        return project(
            items: items,
            paragraphs: paragraphs,
            visibleStartSeconds: visibleStartSeconds,
            visibleEndSeconds: visibleEndSeconds
        )
    }

    public static func project(
        items: [StreamAppTimelineItem],
        visibleStartSeconds: Double,
        visibleEndSeconds: Double
    ) -> StreamAppTimelineRailSnapshot {
        project(
            items: items,
            paragraphs: [],
            visibleStartSeconds: visibleStartSeconds,
            visibleEndSeconds: visibleEndSeconds
        )
    }

    public static func project(
        items: [StreamAppTimelineItem],
        paragraphs: [StreamAppTranscriptParagraph],
        visibleStartSeconds: Double,
        visibleEndSeconds: Double
    ) -> StreamAppTimelineRailSnapshot {
        let finiteVisibleStartSeconds = visibleStartSeconds.isFinite ? visibleStartSeconds : 0
        let finiteVisibleEndSeconds = visibleEndSeconds.isFinite ? visibleEndSeconds : finiteVisibleStartSeconds
        let orderedVisibleStartSeconds = min(finiteVisibleStartSeconds, finiteVisibleEndSeconds)
        let orderedVisibleEndSeconds = max(finiteVisibleStartSeconds, finiteVisibleEndSeconds)
        let duration = max(orderedVisibleEndSeconds - orderedVisibleStartSeconds, 0)
        let songSpans = items
            .filter { $0.kind == .song }
            .compactMap { item in
                span(
                    for: item,
                    visibleStartSeconds: orderedVisibleStartSeconds,
                    visibleEndSeconds: orderedVisibleEndSeconds,
                    duration: duration
                )
            }
        let adSpans = adBreakSpans(
            from: items,
            visibleStartSeconds: orderedVisibleStartSeconds,
            visibleEndSeconds: orderedVisibleEndSeconds,
            duration: duration
        )
        let transcriptAdSpans = inferredTranscriptAdSpans(
            from: paragraphs,
            visibleStartSeconds: orderedVisibleStartSeconds,
            visibleEndSeconds: orderedVisibleEndSeconds,
            duration: duration
        )
        let spans = (songSpans + mergedWithTranscriptAdSpans(
            definiteSpans: coalescedAdSpans(adSpans),
            transcriptSpans: transcriptAdSpans
        ))
            .sorted {
                if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
                if $0.isAd != $1.isAd { return !$0.isAd && $1.isAd }
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

    private static func inferredTranscriptAdSpans(
        from paragraphs: [StreamAppTranscriptParagraph],
        visibleStartSeconds: Double,
        visibleEndSeconds: Double,
        duration: Double
    ) -> [StreamAppTimelineRailSpan] {
        guard duration > 0 else { return [] }
        let visibleParagraphs = paragraphs.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }.filter {
            $0.endSeconds >= visibleStartSeconds && $0.startSeconds <= visibleEndSeconds
        }
        let scores = TranscriptAdScorer.scores(for: visibleParagraphs)
        let scored = visibleParagraphs.compactMap { paragraph -> (StreamAppTranscriptParagraph, TranscriptAdScorer.Score)? in
            guard let score = scores[paragraph.id],
                  score.confidence >= 0.50 else { return nil }
            return (paragraph, score)
        }

        var grouped: [(paragraphs: [StreamAppTranscriptParagraph], scores: [TranscriptAdScorer.Score])] = []
        for entry in scored {
            if var last = grouped.last,
               let previous = last.paragraphs.last,
               entry.0.startSeconds <= previous.endSeconds + 10 {
                last.paragraphs.append(entry.0)
                last.scores.append(entry.1)
                grouped[grouped.count - 1] = last
            } else {
                grouped.append(([entry.0], [entry.1]))
            }
        }

        return grouped.compactMap { group in
            guard let first = group.paragraphs.first,
                  let last = group.paragraphs.last else {
                return nil
            }
            let start = first.startSeconds
            let end = last.endSeconds
            guard end > start else { return nil }
            let clampedStart = clamp(start, lower: visibleStartSeconds, upper: visibleEndSeconds)
            let clampedEnd = clamp(end, lower: visibleStartSeconds, upper: visibleEndSeconds)
            let confidence = group.scores.map(\.confidence).max()
            let signals = Array(Set(group.scores.flatMap(\.signals))).sorted()
            return StreamAppTimelineRailSpan(
                id: "ad-inferred:\(first.id)",
                title: "AD",
                subtitle: inferredAdSubtitle(confidence: confidence, signals: signals),
                source: .transcript,
                isAd: true,
                startSeconds: start,
                endSeconds: end,
                normalizedStart: normalized(clampedStart, visibleStartSeconds: visibleStartSeconds, duration: duration),
                normalizedEnd: normalized(clampedEnd, visibleStartSeconds: visibleStartSeconds, duration: duration),
                colorToken: "ad-inferred",
                isSeekable: false,
                confidence: confidence,
                signals: signals
            )
        }
    }

    private static func inferredAdSubtitle(confidence: Double?, signals: [String]) -> String {
        let confidenceLabel = confidence.map { "\(Int(($0 * 100).rounded()))%" } ?? "Inferred"
        let labels = friendlySignalLabels(for: signals)
        guard !labels.isEmpty else { return "Transcript inferred · \(confidenceLabel)" }
        return "Transcript inferred · \(confidenceLabel) · \(labels.prefix(4).joined(separator: ", "))"
    }

    private static func friendlySignalLabels(for signals: [String]) -> [String] {
        let labeled = signals.compactMap { signal -> (label: String, priority: Int)? in
            if signal.hasPrefix("url:") { return ("URL", 0) }
            if signal.hasPrefix("disclaimer") { return ("legal disclaimer", 1) }
            if signal.hasPrefix("sponsor:") { return ("sponsor", 2) }
            if signal.hasPrefix("cta") { return ("call to action", 3) }
            if signal == "commercial-pitch" { return ("commercial pitch", 4) }
            if signal == "music-sfx" { return ("music/SFX cue", 5) }
            if signal.hasPrefix("keyword") { return ("ad keyword", 6) }
            if signal.hasPrefix("neighbor-reinforced") { return ("nearby ad copy", 7) }
            if signal == "length>=20s" { return ("long read", 8) }
            return nil
        }
        var bestPriorityByLabel: [String: Int] = [:]
        for entry in labeled {
            bestPriorityByLabel[entry.label] = min(entry.priority, bestPriorityByLabel[entry.label] ?? entry.priority)
        }
        return bestPriorityByLabel
            .sorted {
                if $0.value != $1.value { return $0.value < $1.value }
                return $0.key < $1.key
            }
            .map(\.key)
    }

    private static func coalescedAdSpans(
        _ spans: [StreamAppTimelineRailSpan]
    ) -> [StreamAppTimelineRailSpan] {
        let ordered = spans.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        var result: [StreamAppTimelineRailSpan] = []
        for span in ordered {
            guard var last = result.last, last.isAd, span.isAd, span.startSeconds < last.endSeconds else {
                result.append(span)
                continue
            }
            last.endSeconds = max(last.endSeconds, span.endSeconds)
            last.normalizedEnd = max(last.normalizedEnd, span.normalizedEnd)
            if last.source == nil {
                last.source = span.source
            }
            result[result.count - 1] = last
        }
        return result
    }

    private static func mergedWithTranscriptAdSpans(
        definiteSpans: [StreamAppTimelineRailSpan],
        transcriptSpans: [StreamAppTimelineRailSpan]
    ) -> [StreamAppTimelineRailSpan] {
        var result = definiteSpans
        for transcriptSpan in transcriptSpans {
            guard result.contains(where: { overlapsDefiniteAdSpan($0, transcriptSpan) }) else {
                result.append(transcriptSpan)
                continue
            }
        }
        return result
    }

    private static func overlapsDefiniteAdSpan(
        _ lhs: StreamAppTimelineRailSpan,
        _ rhs: StreamAppTimelineRailSpan
    ) -> Bool {
        lhs.isAd
            && rhs.isAd
            && lhs.source != .transcript
            && max(lhs.startSeconds, rhs.startSeconds) < min(lhs.endSeconds, rhs.endSeconds)
    }

    private static func broadcastItems(from metadata: [StreamAppMetadataItem]) -> [StreamAppTimelineItem] {
        let sorted = StreamAppTimelineProjection.coalescedMetadataChanges(metadata).sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        let smoothedSongs = smoothSongMetadata(sorted.filter { $0.kind == .song })
        let songItems = smoothedSongs.map { item in
            StreamAppTimelineItem(
                id: item.id,
                kind: .song,
                startSeconds: item.startSeconds,
                endSeconds: item.endSeconds,
                startTimestamp: item.startTimestamp,
                endTimestamp: item.endTimestamp,
                title: item.title,
                subtitle: item.subtitle,
                source: item.source,
                speakerDisplay: metadataSpeakerDisplay(for: item),
                isSeekable: false
            )
        }
        let eventItems = sorted.filter { $0.kind == .event }.map { item in
            StreamAppTimelineItem(
                id: item.id,
                kind: .event,
                startSeconds: item.startSeconds,
                endSeconds: item.endSeconds,
                startTimestamp: item.startTimestamp,
                endTimestamp: item.endTimestamp,
                title: item.title,
                subtitle: item.subtitle,
                source: item.source,
                isSeekable: false
            )
        }
        return songItems + eventItems
    }

    private static func smoothSongMetadata(_ songs: [StreamAppMetadataItem]) -> [StreamAppMetadataItem] {
        var result: [StreamAppMetadataItem] = []
        for song in songs {
            var candidate = song
            candidate.endSeconds = candidate.endSeconds ?? candidate.startSeconds
            guard let last = result.last else {
                result.append(candidate)
                continue
            }
            let lastEnd = last.endSeconds ?? last.startSeconds
            let candidateEnd = candidate.endSeconds ?? candidate.startSeconds
            if sameSong(last, candidate) {
                result[result.count - 1].endSeconds = max(lastEnd, candidateEnd)
                result[result.count - 1].endTimestamp = candidate.endTimestamp
                continue
            }
            let gap = candidate.startSeconds - lastEnd
            let duration = max(0, candidateEnd - candidate.startSeconds)
            if isFingerprint(candidate), !isTrusted(last), gap <= 30, duration < 20 {
                result[result.count - 1].endSeconds = max(lastEnd, candidateEnd)
                result[result.count - 1].endTimestamp = candidate.endTimestamp
                continue
            }
            if isFingerprint(candidate), isTrusted(last), gap <= 45, duration < 30 {
                result[result.count - 1].endSeconds = max(lastEnd, candidateEnd)
                result[result.count - 1].endTimestamp = candidate.endTimestamp
                continue
            }
            result.append(candidate)
        }
        return result
    }

    private static func sameSong(_ lhs: StreamAppMetadataItem, _ rhs: StreamAppMetadataItem) -> Bool {
        lhs.title.caseInsensitiveCompare(rhs.title) == .orderedSame
            && (lhs.artist ?? "").caseInsensitiveCompare(rhs.artist ?? "") == .orderedSame
    }

    private static func isTrusted(_ item: StreamAppMetadataItem) -> Bool {
        let source = (item.source ?? item.id).lowercased()
        return source.contains("id3")
            || source.contains("scte")
            || source.contains("icy")
            || source.contains("icecast")
            || source.contains("timed")
            || item.id.hasPrefix("event:")
    }

    private static func isFingerprint(_ item: StreamAppMetadataItem) -> Bool {
        let source = (item.source ?? item.id).lowercased()
        return source.contains("fingerprint") || source.contains("chromaprint") || source.contains("acoust")
    }

    private static func metadataSpeakerDisplay(for item: StreamAppMetadataItem) -> StreamAppSpeakerDisplay? {
        guard let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty else {
            return nil
        }
        return StreamAppSpeakerDisplay(
            rawLabel: artist,
            displayLabel: artist,
            colorToken: StreamAppSpeakerDisplayProjection.fallbackColorToken(for: artist)
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
            colorToken: railSongColorToken(for: item.title),
            isSeekable: item.isSeekable
        )
    }

    private static func adBreakSpans(
        from items: [StreamAppTimelineItem],
        visibleStartSeconds: Double,
        visibleEndSeconds: Double,
        duration: Double
    ) -> [StreamAppTimelineRailSpan] {
        guard duration > 0 else { return [] }
        let orderedItems = items.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        var spans: [StreamAppTimelineRailSpan] = []
        var pendingStart: StreamAppTimelineItem?
        for event in orderedItems {
            if event.kind == .song, let start = pendingStart, event.startSeconds > start.startSeconds {
                if let completed = adSpan(
                    start: start,
                    end: event.startSeconds,
                    visibleStartSeconds: visibleStartSeconds,
                    visibleEndSeconds: visibleEndSeconds,
                    duration: duration
                ) {
                    spans.append(completed)
                }
                pendingStart = nil
                continue
            }
            guard event.kind == .event else { continue }
            let source = markerSource(for: event)
            let startsAdBreak = isAdBreakStart(event)
            let endsAdBreak = isAdBreakEnd(event)
            guard source == .scte35 || startsAdBreak || endsAdBreak else { continue }
            if startsAdBreak {
                if let start = pendingStart,
                   let completed = adSpan(
                    start: start,
                    end: max(event.startSeconds, start.startSeconds),
                    visibleStartSeconds: visibleStartSeconds,
                    visibleEndSeconds: visibleEndSeconds,
                    duration: duration
                   ) {
                    spans.append(completed)
                }
                if let completed = adSpan(
                    start: event,
                    end: explicitAdEndSeconds(for: event),
                    visibleStartSeconds: visibleStartSeconds,
                    visibleEndSeconds: visibleEndSeconds,
                    duration: duration
                ) {
                    spans.append(completed)
                    pendingStart = nil
                } else {
                    pendingStart = event
                }
                continue
            }
            if endsAdBreak, let start = pendingStart {
                if let completed = adSpan(
                    start: start,
                    end: max(event.startSeconds, start.startSeconds),
                    visibleStartSeconds: visibleStartSeconds,
                    visibleEndSeconds: visibleEndSeconds,
                    duration: duration
                ) {
                    spans.append(completed)
                }
                pendingStart = nil
            }
        }
        if let start = pendingStart,
           let completed = adSpan(
            start: start,
            end: visibleEndSeconds,
            visibleStartSeconds: visibleStartSeconds,
            visibleEndSeconds: visibleEndSeconds,
            duration: duration
           ) {
            spans.append(completed)
        }
        return spans
    }

    private static func explicitAdEndSeconds(for event: StreamAppTimelineItem) -> Double? {
        if let end = event.endSeconds, end > event.startSeconds {
            return end
        }
        guard let duration = adDurationSeconds(for: event), duration > 0 else {
            return nil
        }
        return event.startSeconds + duration
    }

    private static func adDurationSeconds(for item: StreamAppTimelineItem) -> Double? {
        let text = timelineText(for: item)
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

    private static func adSpan(
        start: StreamAppTimelineItem,
        end: Double?,
        visibleStartSeconds: Double,
        visibleEndSeconds: Double,
        duration: Double
    ) -> StreamAppTimelineRailSpan? {
        guard let end, end > start.startSeconds else { return nil }
        guard end >= visibleStartSeconds && start.startSeconds <= visibleEndSeconds else {
            return nil
        }
        let clampedStart = clamp(start.startSeconds, lower: visibleStartSeconds, upper: visibleEndSeconds)
        let clampedEnd = clamp(end, lower: visibleStartSeconds, upper: visibleEndSeconds)
        let source = markerSource(for: start)
        return StreamAppTimelineRailSpan(
            id: "ad:\(start.id)",
            title: "AD",
            subtitle: adSubtitle(for: start, source: source),
            source: source,
            isAd: true,
            startSeconds: start.startSeconds,
            endSeconds: end,
            normalizedStart: normalized(clampedStart, visibleStartSeconds: visibleStartSeconds, duration: duration),
            normalizedEnd: normalized(clampedEnd, visibleStartSeconds: visibleStartSeconds, duration: duration),
            colorToken: "ad",
            isSeekable: start.isSeekable
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
            title: isAdEvent(item) ? "AD" : item.title,
            source: source,
            seconds: item.startSeconds,
            normalizedPosition: normalized(item.startSeconds, visibleStartSeconds: visibleStartSeconds, duration: duration),
            colorToken: isAdEvent(item) ? "ad" : markerColorToken(for: source),
            isSeekable: item.isSeekable
        )
    }

    private static func markerSource(for item: StreamAppTimelineItem) -> StreamAppTimelineMarkerSource {
        let text = timelineText(for: item)
        if scte35Markers.contains(where: { containsMarker($0, in: text) }) { return .scte35 }
        if icyMarkers.contains(where: { containsMarker($0, in: text) }) { return .icy }
        if timedID3Markers.contains(where: { containsMarker($0, in: text) }) { return .timedID3 }
        return .unknown
    }

    private static func isAdBreakStart(_ item: StreamAppTimelineItem) -> Bool {
        let text = timelineText(for: item)
        return text.contains("ad break start")
            || text.contains(" advertisement ")
            || text.contains("break start")
            || text.contains("cue-out")
            || text.contains("ext-x-cue-out")
            || text.contains("splice_insert")
            || text.contains("splice insert")
    }

    private static func isAdEvent(_ item: StreamAppTimelineItem) -> Bool {
        normalized(item.title) == "ad"
            || isAdBreakStart(item)
            || isAdBreakEnd(item)
    }

    private static func isAdBreakEnd(_ item: StreamAppTimelineItem) -> Bool {
        let text = timelineText(for: item)
        return text.contains("ad break end")
            || text.contains("break end")
            || text.contains("cue-in")
            || text.contains("ext-x-cue-in")
    }

    private static func timelineText(for item: StreamAppTimelineItem) -> String {
        [item.id, item.title, item.subtitle ?? "", item.source ?? ""]
            .joined(separator: " ")
            .lowercased()
    }

    private static func adSubtitle(
        for item: StreamAppTimelineItem,
        source: StreamAppTimelineMarkerSource = .scte35
    ) -> String {
        let sourceLabel = adSourceLabel(for: source)
        var parts = [sourceLabel]
        if let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subtitle.isEmpty,
           !subtitle.localizedCaseInsensitiveContains(sourceLabel) {
            parts.append(subtitle)
        }
        if let end = explicitAdEndSeconds(for: item), end > item.startSeconds {
            parts.append(String(format: "%.0fs", end - item.startSeconds))
        }
        return parts.joined(separator: " · ")
    }

    private static func adSourceLabel(for source: StreamAppTimelineMarkerSource) -> String {
        switch source {
        case .scte35: return "SCTE-35"
        case .icy: return "ICY"
        case .timedID3: return "ID3"
        case .transcript: return "Transcript"
        case .unknown: return "Ad cue"
        }
    }

    private static let scte35Markers = [
        "scte35",
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

    private static let icyMarkers = [
        "icy",
        "icy_stream",
        "icecast",
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
            return "ad"
        case .icy:
            return "blue"
        case .transcript:
            return "ad-inferred"
        case .unknown:
            return "gray"
        }
    }

    private static func railSongColorToken(for title: String) -> String {
        let total = title.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let tokens = ["blue", "green", "orange", "purple", "teal", "violet", "yellow"]
        return tokens[abs(total) % tokens.count]
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
