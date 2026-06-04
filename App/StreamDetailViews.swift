import SoundingKit
import SwiftUI

struct VisibleIssueRow: View {
    var issue: StreamAppVisibleIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(issue.message, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text("Action: \(issue.actionLabel)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(issue.severity.rawValue) issue: \(issue.message). Action: \(issue.actionLabel)")
    }

    private var systemImage: String {
        switch issue.severity {
        case .info:
            return "info.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .blocking:
            return "exclamationmark.octagon.fill"
        }
    }

    private var color: Color {
        switch issue.severity {
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .blocking:
            return .red
        }
    }
}

struct StreamDetail: View {
    var selected: StreamAppSelectedStream
    var timelineActionMessage: String?
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void
    var refreshTimeline: () -> Void
    var clearTimeline: () -> Void
    var exportTimelineItem: (StreamAppTimelineItem) -> Void
    var exportTimelineRange: (StreamAppTimelineItem) -> Void
    var reportTimelineActionMessage: (String) -> Void
    @Binding var searchDraft: StreamAppSearchDraft
    var runSearch: () -> Void
    var clearSearch: () -> Void
    var selectSearchResult: (String) -> StreamAppSearchSelectionAction?
    var updateSpeakerDisplay: (String, String, String) -> Void

    @State private var transcriptAutoscrolls = true
    @State private var speakerLabelDrafts: [String: String] = [:]
    @State private var speakerColorDrafts: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if selected.item.diarizationEnabled {
                    SpeakerDisplayEditor(
                        speakers: selected.speakerDisplays,
                        labelDrafts: $speakerLabelDrafts,
                        colorDrafts: $speakerColorDrafts,
                        updateSpeakerDisplay: updateSpeakerDisplay
                    )
                }
                SearchCard(
                    selected: selected,
                    draft: $searchDraft,
                    runSearch: runSearch,
                    clearSearch: clearSearch,
                    selectResult: handleSearchResultSelection
                )
                TimelineItemsCard(
                    items: selected.timelineItems,
                    rail: selected.timelineRail,
                    isDiarizationEnabled: selected.item.diarizationEnabled,
                    actionMessage: timelineActionMessage,
                    refreshTimeline: refreshTimeline,
                    clearTimeline: clearTimeline,
                    seekToSeconds: seekToSeconds,
                    seekUnavailable: seekUnavailable,
                    exportTimelineItem: exportTimelineItem,
                    exportTimelineRange: exportTimelineRange,
                    reportTimelineActionMessage: reportTimelineActionMessage
                )
            }
            .padding(28)
        }
    }

    func handleSearchResultSelection(_ resultID: String) {
        guard let action = selectSearchResult(resultID) else { return }
        if action.shouldSeek, let seconds = action.seekSeconds, seconds.isFinite {
            seekToSeconds(seconds)
        }
    }

    func isSeekableTranscript(_ paragraph: StreamAppTranscriptParagraph) -> Bool {
        selected.timelineItems.first { $0.id == "transcript:\(paragraph.id)" }?.isSeekable ?? false
    }
}

struct SpeakerDisplayEditor: View {
    var speakers: [StreamAppSpeakerDisplay]
    @Binding var labelDrafts: [String: String]
    @Binding var colorDrafts: [String: String]
    var updateSpeakerDisplay: (String, String, String) -> Void

    var body: some View {
        GroupBox("Speakers") {
            if speakers.isEmpty {
                ContentUnavailableView(
                    "No speaker labels yet",
                    systemImage: "person.2.wave.2",
                    description: Text(
                        "Speaker display overrides appear once transcript speaker labels arrive.")
                )
                .frame(minHeight: 80)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(speakers) { speaker in
                        HStack(spacing: 12) {
                            SpeakerBadge(speaker: speaker)
                            TextField(
                                "Display label",
                                text: Binding(
                                    get: { labelDrafts[speaker.rawLabel] ?? speaker.displayLabel },
                                    set: { labelDrafts[speaker.rawLabel] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Display label for \(speaker.rawLabel)")

                            Picker(
                                "Color",
                                selection: Binding(
                                    get: { colorDrafts[speaker.rawLabel] ?? speaker.colorToken },
                                    set: { colorDrafts[speaker.rawLabel] = $0 }
                                )
                            ) {
                                ForEach(StreamAppTimelineStore.allowedColorTokens, id: \.self) {
                                    token in
                                    Text(token.capitalized).tag(token)
                                }
                            }
                            .frame(width: 120)

                            Button("Save") {
                                updateSpeakerDisplay(
                                    speaker.rawLabel,
                                    labelDrafts[speaker.rawLabel] ?? speaker.displayLabel,
                                    colorDrafts[speaker.rawLabel] ?? speaker.colorToken
                                )
                            }
                            .accessibilityLabel("Save display override for \(speaker.rawLabel)")
                        }
                    }
                }
            }
        }
    }
}

struct StreamHeader: View {
    var selected: StreamAppSelectedStream

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(selected.item.name)
                    .font(.largeTitle.bold())
                StatusPill(status: selected.item.status)
            }
            Text(selected.item.sourceDescription)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RuntimeStatusCard: View {
    var selected: StreamAppSelectedStream

    var body: some View {
        GroupBox("Runtime Status") {
            HStack(alignment: .top, spacing: 12) {
                Image(
                    systemName: selected.item.status.isFailure
                        ? "exclamationmark.triangle.fill" : "dot.radiowaves.left.and.right"
                )
                .foregroundStyle(selected.item.status.isFailure ? .red : .blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.item.status.title)
                        .font(.headline)
                    Text(selected.runtimeStatusDetail)
                        .foregroundStyle(.secondary)
                    if let retry = selected.runtimeRetryDetail {
                        Text(retry)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let updated = selected.runtimeUpdatedAtDetail {
                        Text(updated)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let failure = selected.runtimeRecentFailureDetail {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let issue = selected.runtimeIssue {
                        VisibleIssueRow(issue: issue)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

struct PlayerCard: View {
    var selected: StreamAppSelectedStream
    var seekToLive: () -> Void
    var scrubBackward: () -> Void
    var startRuntime: () -> Void
    var restartRuntime: () -> Void
    var pauseRuntime: () -> Void
    var resumeRuntime: () -> Void
    var stopRuntime: () -> Void
    @Binding var volume: Double
    @Binding var isMuted: Bool

    var body: some View {
        GroupBox("Player") {
            VStack(alignment: .leading, spacing: 16) {
                Text(selected.playerStateTitle)
                    .font(.headline)
                Text(selected.playerStateDetail)
                    .foregroundStyle(.secondary)

                if let issue = selected.playerIssue {
                    VisibleIssueRow(issue: issue)
                }

                if let issue = selected.bufferIssue {
                    VisibleIssueRow(issue: issue)
                }

                HStack(spacing: 12) {
                    Button("Start", systemImage: "play.fill", action: startRuntime)
                        .disabled(!selected.canStartRuntime)
                    Button("Restart", systemImage: "arrow.clockwise", action: restartRuntime)
                        .disabled(!selected.canStopRuntime)
                    Button("Pause", systemImage: "pause.fill", action: pauseRuntime)
                        .disabled(!selected.canPauseRuntime)
                    Button("Resume", systemImage: "playpause.fill", action: resumeRuntime)
                        .disabled(!selected.canResumeRuntime)
                    Button("Stop", systemImage: "stop.fill", action: stopRuntime)
                        .disabled(!selected.canStopRuntime)
                    Button("-30s", systemImage: "gobackward.30", action: scrubBackward)
                        .disabled(!selected.canScrubBufferedRange)
                    Button("Live", systemImage: "dot.radiowaves.forward", action: seekToLive)
                        .disabled(!selected.canSeekToLive)
                }
                .disabled(!selected.controlsEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(isMuted ? "Muted" : "Volume", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(Int((volume * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Toggle("Mute", isOn: $isMuted)
                            .toggleStyle(.switch)
                            .accessibilityLabel("Mute stream")
                        Slider(value: $volume, in: 0...1)
                            .disabled(isMuted)
                            .accessibilityLabel("Stream volume")
                            .accessibilityValue("\(Int((volume * 100).rounded())) percent")
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.bufferedRangeTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: .constant(selected.scrubPositionFraction), in: 0...1)
                        .disabled(!selected.canScrubBufferedRange)
                        .accessibilityLabel("Buffered playback position")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}
