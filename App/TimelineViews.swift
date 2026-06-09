import AppKit
import SoundingKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptCard: View {
    var paragraphs: [StreamAppTranscriptParagraph]
    @Binding var autoscrolls: Bool
    var isSeekable: (StreamAppTranscriptParagraph) -> Bool
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void
    var clearTimeline: () -> Void
    var exportTimelineItem: (StreamAppTimelineItem) -> Void
    var exportTimelineRange: (StreamAppTimelineItem) -> Void
    var reportTimelineActionMessage: (String) -> Void

    private var newestFirstParagraphs: [StreamAppTranscriptParagraph] {
        paragraphs.sorted {
            if $0.endSeconds != $1.endSeconds { return $0.endSeconds > $1.endSeconds }
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds > $1.startSeconds }
            return $0.id > $1.id
        }
    }

    var body: some View {
        GroupBox("Transcript") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle("Follow live transcript", isOn: $autoscrolls)
                        .toggleStyle(.switch)
                    Spacer()
                    Button("Jump to Live", systemImage: "arrow.down.to.line") {
                        autoscrolls = true
                    }
                    Button("Clear", systemImage: "trash", role: .destructive) {
                        clearTimeline()
                    }
                    .disabled(paragraphs.isEmpty)
                }

                if paragraphs.isEmpty {
                    ContentUnavailableView(
                        "No transcript yet",
                        systemImage: "text.bubble",
                        description: Text(
                            "Bounded transcript paragraphs appear as the selected stream is processed."
                        )
                    )
                    .frame(minHeight: 120)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(newestFirstParagraphs) { paragraph in
                            TranscriptParagraphButton(
                                paragraph: paragraph,
                                isSeekable: isSeekable(paragraph),
                                seekToSeconds: seekToSeconds,
                                seekUnavailable: seekUnavailable,
                                exportTimelineItem: exportTimelineItem,
                                exportTimelineRange: exportTimelineRange,
                                reportTimelineActionMessage: reportTimelineActionMessage
                            )
                            .id(transcriptScrollID(paragraph.id))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TranscriptParagraphButton: View {
    var paragraph: StreamAppTranscriptParagraph
    var isSeekable: Bool
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void
    var exportTimelineItem: (StreamAppTimelineItem) -> Void
    var exportTimelineRange: (StreamAppTimelineItem) -> Void
    var reportTimelineActionMessage: (String) -> Void

    private var timelineItem: StreamAppTimelineItem {
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
            isSeekable: isSeekable
        )
    }

    var body: some View {
        Button {
            if isSeekable {
                seekToSeconds(paragraph.startSeconds)
            } else {
                seekUnavailable(paragraph.startSeconds)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                SpeakerBadge(speaker: paragraph.speakerDisplay)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(timeRange(start: paragraph.startSeconds, end: paragraph.endSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if !isSeekable {
                            Label("Not buffered", systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(paragraph.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if !paragraph.words.isEmpty {
                        Text(paragraph.words.map(\.text).joined(separator: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .timelineItemContextMenu(
            item: timelineItem,
            seekToSeconds: seekToSeconds,
            seekUnavailable: seekUnavailable,
            exportTimelineItem: exportTimelineItem,
            exportTimelineRange: exportTimelineRange,
            reportTimelineActionMessage: reportTimelineActionMessage
        )
        .accessibilityLabel(
            "Transcript from \(paragraph.speakerDisplay.displayLabel) at \(timeRange(start: paragraph.startSeconds, end: paragraph.endSeconds)): \(paragraph.text)"
        )
        .accessibilityHint(
            isSeekable
                ? "Seeks playback to this buffered transcript paragraph."
                : "Reports that this transcript paragraph is outside the buffered range.")
    }
}

struct TimelineItemsCard: View {
    var items: [StreamAppTimelineItem]
    var rail: StreamAppTimelineRailSnapshot
    var isDiarizationEnabled: Bool
    var actionMessage: String?
    var refreshTimeline: () -> Void
    var clearTimeline: () -> Void
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void
    var exportTimelineItem: (StreamAppTimelineItem) -> Void
    var exportTimelineRange: (StreamAppTimelineItem) -> Void
    var reportTimelineActionMessage: (String) -> Void

    private var newestFirstItems: [StreamAppTimelineItem] {
        items.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds > $1.startSeconds }
            return $0.id > $1.id
        }
    }

    var body: some View {
        GroupBox("Timeline") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise", action: refreshTimeline)
                    Button("Clear Timeline", systemImage: "trash", role: .destructive, action: clearTimeline)
                        .disabled(items.isEmpty)
                }
                if let actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TimelineRailView(
                    rail: rail,
                    seekToSeconds: seekToSeconds,
                    seekUnavailable: seekUnavailable
                )
                if items.isEmpty {
                    ContentUnavailableView(
                        "No timeline items yet",
                        systemImage: "list.bullet.indent",
                        description: Text("Transcript and metadata changes appear here once refreshed.")
                    )
                    .frame(minHeight: 100)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(newestFirstItems) { item in
                            TimelineItemButton(
                                item: item,
                                isDiarizationEnabled: isDiarizationEnabled,
                                seekToSeconds: seekToSeconds,
                                seekUnavailable: seekUnavailable,
                                exportTimelineItem: exportTimelineItem,
                                exportTimelineRange: exportTimelineRange,
                                reportTimelineActionMessage: reportTimelineActionMessage
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TimelineRailView: View {
    var rail: StreamAppTimelineRailSnapshot
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void

    @State private var viewportStartSeconds: Double?
    @State private var viewportEndSeconds: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Broadcast Timeline")
                        .font(.caption.weight(.semibold))
                    Text("\(clockLabel(viewport.start)) - \(clockLabel(viewport.end))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Out", systemImage: "minus.magnifyingglass") {
                    zoom(by: 2)
                }
                .disabled(!canZoomOut)
                Button("In", systemImage: "plus.magnifyingglass") {
                    zoom(by: 0.5)
                }
                .disabled(!canZoomIn)
                Button("Left", systemImage: "chevron.left") {
                    pan(direction: -1)
                }
                .disabled(!canPanLeft)
                Button("Right", systemImage: "chevron.right") {
                    pan(direction: 1)
                }
                .disabled(!canPanRight)
                Button("Live", systemImage: "dot.radiowaves.forward") {
                    jumpToLive()
                }
                .disabled(!canPanRight && isFullWindow)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack {
                Text(timeLabel(viewport.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(viewport.duration.rounded()))s visible")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeLabel(viewport.end))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(0.35))
                    if hasVisibleContent {
                        ForEach(viewportRail.spans) { span in
                            Button {
                                playOrReport(seconds: span.startSeconds, isSeekable: span.isSeekable)
                            } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(railColor(span.colorToken))
                                    .overlay(alignment: .leading) {
                                        Text(span.title)
                                            .font(.caption2.weight(.semibold))
                                            .lineLimit(1)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                    }
                            }
                            .buttonStyle(.plain)
                            .frame(
                                width: spanWidth(span, totalWidth: proxy.size.width),
                                height: 30
                            )
                            .offset(x: xOffset(span.normalizedStart, totalWidth: proxy.size.width))
                            .help(spanHelp(span))
                        }
                        ForEach(viewportRail.markers) { marker in
                            Button {
                                playOrReport(seconds: marker.seconds, isSeekable: marker.isSeekable)
                            } label: {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(railColor(marker.colorToken))
                                    .frame(width: 5, height: 34)
                            }
                            .buttonStyle(.plain)
                            .offset(x: xOffset(marker.normalizedPosition, totalWidth: proxy.size.width))
                            .help(markerHelp(marker))
                        }
                    } else {
                        Text("No metadata markers in this window")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .frame(height: 38)

            if fullDuration > minimumViewportDuration {
                Slider(
                    value: viewportCenterBinding,
                    in: viewportCenterRange
                )
                .controlSize(.small)
                .help("Scroll the visible broadcast timeline window.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline rail")
    }

    private var hasVisibleContent: Bool {
        !viewportRail.spans.isEmpty || !viewportRail.markers.isEmpty
    }

    private var fullStart: Double {
        let start = safeSeconds(rail.visibleStartSeconds, fallback: 0)
        let end = safeSeconds(rail.visibleEndSeconds, fallback: start)
        return min(start, end)
    }

    private var fullEnd: Double {
        let start = safeSeconds(rail.visibleStartSeconds, fallback: 0)
        let end = safeSeconds(rail.visibleEndSeconds, fallback: start)
        return max(start, end)
    }

    private var fullDuration: Double {
        max(0, fullEnd - fullStart)
    }

    private var minimumViewportDuration: Double {
        min(120, max(30, fullDuration))
    }

    private var viewport: (start: Double, end: Double, duration: Double) {
        guard fullDuration > 0 else {
            return (fullStart, fullEnd, 0)
        }
        let requestedStart = safeSeconds(viewportStartSeconds, fallback: fullStart)
        let requestedEnd = safeSeconds(viewportEndSeconds, fallback: fullEnd)
        var start = min(requestedStart, requestedEnd)
        var end = max(requestedStart, requestedEnd)
        if end <= start {
            end = start + fullDuration
        }
        let duration = min(fullDuration, max(minimumViewportDuration, end - start))
        start = min(max(fullStart, start), max(fullStart, fullEnd - duration))
        end = min(fullEnd, start + duration)
        return (start, end, end - start)
    }

    private var viewportRail: StreamAppTimelineRailSnapshot {
        let current = viewport
        guard current.duration > 0 else {
            return StreamAppTimelineRailSnapshot(
                visibleStartSeconds: current.start,
                visibleEndSeconds: current.end,
                spans: [],
                markers: []
            )
        }
        return StreamAppTimelineRailSnapshot(
            visibleStartSeconds: current.start,
            visibleEndSeconds: current.end,
            spans: rail.spans.compactMap { visibleSpan($0, in: current) },
            markers: rail.markers.compactMap { visibleMarker($0, in: current) }
        )
    }

    private var isFullWindow: Bool {
        abs(viewport.duration - fullDuration) < 0.001
    }

    private var canZoomIn: Bool {
        fullDuration > minimumViewportDuration && viewport.duration > minimumViewportDuration
    }

    private var canZoomOut: Bool {
        fullDuration > 0 && viewport.duration < fullDuration
    }

    private var canPanLeft: Bool {
        viewport.start > fullStart + 0.001
    }

    private var canPanRight: Bool {
        viewport.end < fullEnd - 0.001
    }

    private var viewportCenterRange: ClosedRange<Double> {
        let half = viewport.duration / 2
        let lower = fullStart + half
        let upper = fullEnd - half
        guard lower.isFinite, upper.isFinite, lower <= upper else {
            let center = (fullStart + fullEnd) / 2
            let safeCenter = center.isFinite ? center : 0
            return safeCenter...safeCenter
        }
        return lower...upper
    }

    private var viewportCenterBinding: Binding<Double> {
        Binding(
            get: {
                (viewport.start + viewport.end) / 2
            },
            set: { newCenter in
                setViewport(center: newCenter, duration: viewport.duration)
            }
        )
    }

    private func playOrReport(seconds: Double, isSeekable: Bool) {
        if isSeekable {
            seekToSeconds(seconds)
        } else {
            seekUnavailable(seconds)
        }
    }

    private func zoom(by factor: Double) {
        guard fullDuration > 0 else { return }
        let current = viewport
        let center = (current.start + current.end) / 2
        let duration = min(fullDuration, max(minimumViewportDuration, current.duration * factor))
        setViewport(center: center, duration: duration)
    }

    private func pan(direction: Double) {
        guard fullDuration > 0 else { return }
        let current = viewport
        let center = (current.start + current.end) / 2
        let step = max(10, current.duration * 0.5)
        setViewport(center: center + (step * direction), duration: current.duration)
    }

    private func jumpToLive() {
        setViewport(center: fullEnd - (viewport.duration / 2), duration: viewport.duration)
    }

    private func setViewport(center: Double, duration: Double) {
        guard fullDuration > 0 else {
            viewportStartSeconds = nil
            viewportEndSeconds = nil
            return
        }
        let safeDuration = min(fullDuration, max(minimumViewportDuration, duration))
        let safeCenter = safeSeconds(center, fallback: (fullStart + fullEnd) / 2)
        var start = safeCenter - safeDuration / 2
        var end = safeCenter + safeDuration / 2
        if start < fullStart {
            start = fullStart
            end = min(fullEnd, start + safeDuration)
        }
        if end > fullEnd {
            end = fullEnd
            start = max(fullStart, end - safeDuration)
        }
        viewportStartSeconds = start
        viewportEndSeconds = end
    }

    private func safeSeconds(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return value
    }

    private func visibleSpan(
        _ span: StreamAppTimelineRailSpan,
        in current: (start: Double, end: Double, duration: Double)
    ) -> StreamAppTimelineRailSpan? {
        guard span.endSeconds >= current.start && span.startSeconds <= current.end else {
            return nil
        }
        let clampedStart = min(max(span.startSeconds, current.start), current.end)
        let clampedEnd = min(max(span.endSeconds, current.start), current.end)
        return StreamAppTimelineRailSpan(
            id: span.id,
            title: span.title,
            subtitle: span.subtitle,
            source: span.source,
            isAd: span.isAd,
            startSeconds: span.startSeconds,
            endSeconds: span.endSeconds,
            normalizedStart: normalized(clampedStart, in: current),
            normalizedEnd: normalized(clampedEnd, in: current),
            colorToken: span.colorToken,
            isSeekable: span.isSeekable
        )
    }

    private func visibleMarker(
        _ marker: StreamAppTimelineRailMarker,
        in current: (start: Double, end: Double, duration: Double)
    ) -> StreamAppTimelineRailMarker? {
        guard marker.seconds >= current.start && marker.seconds <= current.end else {
            return nil
        }
        return StreamAppTimelineRailMarker(
            id: marker.id,
            title: marker.title,
            source: marker.source,
            seconds: marker.seconds,
            normalizedPosition: normalized(marker.seconds, in: current),
            colorToken: marker.colorToken,
            isSeekable: marker.isSeekable
        )
    }

    private func normalized(
        _ seconds: Double,
        in current: (start: Double, end: Double, duration: Double)
    ) -> Double {
        guard current.duration > 0 else { return 0 }
        return (seconds - current.start) / current.duration
    }

    private func spanWidth(_ span: StreamAppTimelineRailSpan, totalWidth: CGFloat) -> CGFloat {
        max(8, CGFloat(span.normalizedEnd - span.normalizedStart) * totalWidth)
    }

    private func xOffset(_ normalized: Double, totalWidth: CGFloat) -> CGFloat {
        min(max(0, CGFloat(normalized) * totalWidth), max(0, totalWidth - 5))
    }

    private func spanHelp(_ span: StreamAppTimelineRailSpan) -> String {
        let range = "\(timeLabel(span.startSeconds))-\(timeLabel(span.endSeconds))"
        if span.isAd {
            return [span.title, span.subtitle, range]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: " · ")
        }
        if let subtitle = span.subtitle, !subtitle.isEmpty {
            return "\(span.title) - \(subtitle) · \(range)"
        }
        return "\(span.title) · \(range)"
    }

    private func markerHelp(_ marker: StreamAppTimelineRailMarker) -> String {
        let label = marker.source == .scte35 ? "Ad marker" : marker.source.rawValue
        return "\(label): \(marker.title) · \(timeLabel(marker.seconds))"
    }

    private func railColor(_ token: String) -> Color {
        if token == "ad" {
            return Color(red: 1.0, green: 0.14, blue: 0.34)
        }
        if token == "gray" {
            return .secondary
        }
        return StreamAppSpeakerDisplay(rawLabel: token, displayLabel: token, colorToken: token).color
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%.0fs", seconds)
    }

    private func clockLabel(_ seconds: Double) -> String {
        let safeSeconds = max(0, Int(seconds.rounded()))
        let minutes = safeSeconds / 60
        let remainingSeconds = safeSeconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

struct TimelineItemButton: View {
    var item: StreamAppTimelineItem
    var isDiarizationEnabled: Bool
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void
    var exportTimelineItem: (StreamAppTimelineItem) -> Void
    var exportTimelineRange: (StreamAppTimelineItem) -> Void
    var reportTimelineActionMessage: (String) -> Void

    private var showsSpeaker: Bool {
        item.kind != .transcript || isDiarizationEnabled
    }

    private var primaryText: String {
        guard item.kind == .transcript, !isDiarizationEnabled else { return item.title }
        return item.subtitle ?? item.title
    }

    private var secondaryText: String? {
        if item.kind == .transcript, !isDiarizationEnabled {
            return nil
        }
        let parts = [item.subtitle, sourceLabel]
            .compactMap { value -> String? in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty
                else {
                    return nil
                }
                return value
            }
        var seen = Set<String>()
        let uniqueParts = parts.filter { seen.insert($0.lowercased()).inserted }
        guard !uniqueParts.isEmpty else { return nil }
        return uniqueParts.joined(separator: " · ")
    }

    private var sourceLabel: String? {
        guard item.kind != .transcript,
              let source = item.source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty
        else {
            return nil
        }
        let normalized = source.lowercased().replacingOccurrences(of: "-", with: "_")
        if normalized.contains("scte") { return "SCTE35" }
        if normalized.contains("id3") { return "ID3" }
        if normalized.contains("icy") || normalized.contains("icecast") { return "ICY" }
        return source
    }

    var body: some View {
        Button {
            if item.isSeekable {
                seekToSeconds(item.startSeconds)
            } else {
                seekUnavailable(item.startSeconds)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(item.isSeekable ? .blue : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(timeRange(item: item))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if showsSpeaker, let speaker = item.speakerDisplay {
                            SpeakerBadge(speaker: speaker)
                        }
                        Text(primaryText)
                            .font(item.kind == .transcript && !isDiarizationEnabled ? .body : .headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let subtitle = secondaryText {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if !item.isSeekable {
                    Text("Not buffered")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .timelineItemContextMenu(
            item: item,
            seekToSeconds: seekToSeconds,
            seekUnavailable: seekUnavailable,
            exportTimelineItem: exportTimelineItem,
            exportTimelineRange: exportTimelineRange,
            reportTimelineActionMessage: reportTimelineActionMessage
        )
        .accessibilityLabel(
            "\(item.kind.title) at \(timeRange(item: item)): \(primaryText)"
        )
        .accessibilityHint(
            item.isSeekable
                ? "Seeks playback to this buffered timeline item."
                : "This item is outside the current buffered audio range.")
    }

}

private extension View {
    func timelineItemContextMenu(
        item: StreamAppTimelineItem,
        seekToSeconds: @escaping (Double) -> Void,
        seekUnavailable: @escaping (Double) -> Void,
        exportTimelineItem: @escaping (StreamAppTimelineItem) -> Void,
        exportTimelineRange: @escaping (StreamAppTimelineItem) -> Void,
        reportTimelineActionMessage: @escaping (String) -> Void
    ) -> some View {
        contextMenu {
            Button("Play", systemImage: "play.fill") {
                if item.isSeekable {
                    seekToSeconds(item.startSeconds)
                } else {
                    seekUnavailable(item.startSeconds)
                }
            }
            Button("Copy Text", systemImage: "doc.on.doc") {
                let copied = copyTimelineText(
                    TimelineExportService.copyText(item: item, includesTime: false)
                )
                reportTimelineActionMessage(
                    copied ? "Copied timeline text." : "Copy failed: pasteboard was unavailable."
                )
            }
            Button("Copy with Time", systemImage: "clock.badge.checkmark") {
                let copied = copyTimelineText(
                    TimelineExportService.copyText(item: item, includesTime: true)
                )
                reportTimelineActionMessage(
                    copied
                        ? "Copied timeline text with timestamp."
                        : "Copy failed: pasteboard was unavailable."
                )
            }
            if let rawMetadata = item.rawMetadata?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawMetadata.isEmpty
            {
                Button("Copy Raw Metadata", systemImage: "curlybraces") {
                    let copied = copyTimelineText(rawMetadata)
                    reportTimelineActionMessage(
                        copied
                            ? "Copied raw metadata."
                            : "Copy failed: pasteboard was unavailable."
                    )
                }
            }
            Button("Save Text", systemImage: "square.and.arrow.down") {
                saveTimelineText(
                    item: item,
                    reportTimelineActionMessage: reportTimelineActionMessage
                )
            }
            Button("Export Clip", systemImage: "waveform.badge.plus") {
                exportTimelineItem(item)
            }
            Button("Export Timeline Range", systemImage: "square.and.arrow.down.on.square") {
                exportTimelineRange(item)
            }
        }
    }

    func copyTimelineText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func saveTimelineText(
        item: StreamAppTimelineItem,
        reportTimelineActionMessage: @escaping (String) -> Void
    ) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultSaveName(for: item, fileExtension: "txt")
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TimelineExportService.copyText(item: item, includesTime: true)
                .write(to: url, atomically: true, encoding: .utf8)
            reportTimelineActionMessage("Saved timeline text to \(url.lastPathComponent).")
        } catch {
            reportTimelineActionMessage(
                "Timeline text save failed: \(IngestRedaction.redact(String(describing: error)))"
            )
        }
    }

    func defaultSaveName(for item: StreamAppTimelineItem, fileExtension: String) -> String {
        let base = item.kind == .transcript ? "transcript" : "timeline"
        let id = item.id
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "\(base)-\(id).\(fileExtension)"
    }
}
