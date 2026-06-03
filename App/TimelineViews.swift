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

    private var hasVisibleContent: Bool {
        !rail.spans.isEmpty || !rail.markers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(timeLabel(rail.visibleStartSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeLabel(rail.visibleEndSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(0.35))
                    if hasVisibleContent {
                        ForEach(rail.spans) { span in
                            Button {
                                playOrReport(seconds: span.startSeconds, isSeekable: span.isSeekable)
                            } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(StreamAppSpeakerDisplay(rawLabel: span.id, displayLabel: span.title, colorToken: span.colorToken).color)
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
                        ForEach(rail.markers) { marker in
                            Button {
                                playOrReport(seconds: marker.seconds, isSeekable: marker.isSeekable)
                            } label: {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(StreamAppSpeakerDisplay(rawLabel: marker.id, displayLabel: marker.title, colorToken: marker.colorToken).color)
                                    .frame(width: 5, height: 34)
                            }
                            .buttonStyle(.plain)
                            .offset(x: xOffset(marker.normalizedPosition, totalWidth: proxy.size.width))
                            .help("\(marker.source.rawValue): \(marker.title)")
                        }
                    }
                }
            }
            .frame(height: 36)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline rail")
    }

    private func playOrReport(seconds: Double, isSeekable: Bool) {
        if isSeekable {
            seekToSeconds(seconds)
        } else {
            seekUnavailable(seconds)
        }
    }

    private func spanWidth(_ span: StreamAppTimelineRailSpan, totalWidth: CGFloat) -> CGFloat {
        max(8, CGFloat(span.normalizedEnd - span.normalizedStart) * totalWidth)
    }

    private func xOffset(_ normalized: Double, totalWidth: CGFloat) -> CGFloat {
        min(max(0, CGFloat(normalized) * totalWidth), max(0, totalWidth - 5))
    }

    private func spanHelp(_ span: StreamAppTimelineRailSpan) -> String {
        if let subtitle = span.subtitle, !subtitle.isEmpty {
            return "\(span.title) - \(subtitle)"
        }
        return span.title
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%.0fs", seconds)
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
        guard item.kind == .transcript, !isDiarizationEnabled else { return item.subtitle }
        return nil
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
