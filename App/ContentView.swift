import SoundingKit
import SwiftUI

struct ContentView: View {
    private let registry: StreamRegistry?
    private let runtime: (any AppStreamRuntimeControlling)?
    private let timelineStore: StreamAppTimelineStore?
    @State private var viewModel: StreamAppViewModel
    @State private var persistenceError: String?
    @State private var timelineActionMessage: String?

    init() {
        let initial = Self.makeInitialState()
        registry = initial.registry
        runtime = initial.runtime
        timelineStore = initial.timelineStore
        _viewModel = State(initialValue: initial.viewModel)
        _persistenceError = State(initialValue: initial.persistenceError)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 920, minHeight: 560)
        .task {
            await observeRuntime()
        }
        .task(id: viewModel.selectedStreamID) {
            await refreshSelectedTimelineLoop(streamID: viewModel.selectedStreamID)
        }
        .onChange(of: viewModel.selectedStreamID) { _, _ in
            refreshSelectedTimeline()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedStreamID) {
                if viewModel.streams.isEmpty {
                    ContentUnavailableView(
                        "No Streams",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text(
                            "Add an HLS or Icecast/ICY stream to prepare it for the app runtime.")
                    )
                } else {
                    ForEach(viewModel.streams) { stream in
                        StreamRow(item: stream)
                            .tag(stream.id)
                    }
                }
            }

            Divider()

            addStreamForm
                .padding(16)
        }
    }

    private var addStreamForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add Stream", systemImage: "plus.circle")
                .font(.headline)

            TextField(
                "Name",
                text: Binding(
                    get: { viewModel.addDraft.name },
                    set: { viewModel.addDraft.name = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Stream name")

            TextField(
                "https://example.test/live.m3u8",
                text: Binding(
                    get: { viewModel.addDraft.source },
                    set: { viewModel.addDraft.source = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Stream URL")

            Picker(
                "Type",
                selection: Binding(
                    get: { viewModel.addDraft.transport },
                    set: { viewModel.addDraft.transport = $0 }
                )
            ) {
                ForEach(StreamAppTransport.allCases) { transport in
                    Text(transport.displayName).tag(transport)
                }
            }
            .pickerStyle(.segmented)

            if let addError = viewModel.addError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(addError.description)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(addError.recoverySuggestion)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let persistenceError {
                Text(persistenceError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Persistence error: \(persistenceError)")
            }

            Button {
                addStream()
            } label: {
                Label("Save Stream", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(registry == nil)

            Text(viewModel.lastLifecycleMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityLabel("Lifecycle status: \(viewModel.lastLifecycleMessage)")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected = viewModel.selectedStream {
            StreamDetail(
                selected: selected,
                timelineActionMessage: timelineActionMessage,
                startRuntime: { startRuntime(for: selected.item.id) },
                pauseRuntime: { pauseRuntime() },
                resumeRuntime: { resumeRuntime() },
                stopRuntime: { stopRuntime() },
                seekToLive: { seekToLive() },
                scrubBackward: { scrubBackward(seconds: 30) },
                seekToSeconds: { seekToSeconds($0) },
                seekUnavailable: { seconds in reportSeekUnavailable(seconds: seconds, selected: selected) },
                refreshTimeline: { refreshSelectedTimeline() },
                updateSpeakerDisplay: { rawLabel, displayLabel, colorToken in
                    updateSpeakerDisplay(rawLabel: rawLabel, displayLabel: displayLabel, colorToken: colorToken)
                }
            )
        } else {
            ContentUnavailableView(
                viewModel.emptyStateTitle,
                systemImage: "waveform.badge.magnifyingglass",
                description: Text(
                    "Select or add a supported stream. Start, stop, pause, and resume controls use the in-process SoundingKit runtime; shared PCM playback and rewind controls land in the next S01 tasks."
                )
            )
        }
    }

    private func addStream() {
        guard let registry else {
            persistenceError =
                "Sounding database unavailable. Choose a writable Application Support location."
            return
        }

        do {
            _ = try viewModel.addStream(using: registry)
            persistenceError = nil
            timelineActionMessage = nil
            refreshSelectedTimeline()
        } catch {
            // The view model stores redacted, user-facing validation errors.
        }
    }

    private func startRuntime(for streamID: Int64) {
        guard let runtime else {
            persistenceError = "Sounding runtime unavailable."
            return
        }
        Task {
            do {
                try await runtime.start(streamID: streamID)
                persistenceError = nil
            } catch {
                persistenceError = IngestRedaction.redact(String(describing: error))
            }
        }
    }

    private func pauseRuntime() {
        guard let runtime else { return }
        Task { await runtime.pause() }
    }

    private func resumeRuntime() {
        guard let runtime else { return }
        Task { await runtime.resume() }
    }

    private func stopRuntime() {
        guard let runtime else { return }
        Task { await runtime.stop() }
    }

    private func seekToLive() {
        guard let runtime else { return }
        Task { await runtime.seekToLive() }
    }

    private func scrubBackward(seconds: Double) {
        guard let runtime else { return }
        Task { await runtime.scrubBackward(seconds: seconds) }
    }

    private func seekToSeconds(_ seconds: Double) {
        guard let runtime else {
            timelineActionMessage = "Sounding runtime unavailable."
            return
        }
        timelineActionMessage = String(format: "Seeking to %.1fs…", seconds)
        Task { await runtime.seek(to: seconds) }
    }

    private func reportSeekUnavailable(seconds: Double, selected: StreamAppSelectedStream) {
        timelineActionMessage = selected.bufferedSeekUnavailableMessage
            ?? String(
                format: "%.1fs is outside the current buffered range. %@",
                seconds,
                selected.bufferedRangeTitle
            )
    }

    private func observeRuntime() async {
        guard let runtime else { return }
        for await event in await runtime.events() {
            viewModel.applyRuntimeEvent(event)
            if event.streamID == viewModel.selectedStreamID {
                timelineActionMessage = event.result?.playerTimeline?.unavailableRangeMessage
                    ?? event.result?.playerTimeline?.lastMessage
                    ?? event.message
                refreshSelectedTimeline()
            }
        }
    }

    private func refreshSelectedTimelineLoop(streamID: Int64?) async {
        guard streamID != nil else { return }
        refreshSelectedTimeline()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, streamID == viewModel.selectedStreamID else { return }
            if viewModel.selectedStream?.item.status == .running {
                refreshSelectedTimeline()
            }
        }
    }

    private func refreshSelectedTimeline() {
        guard let timelineStore, viewModel.selectedStreamID != nil else { return }
        do {
            _ = try viewModel.refreshSelectedTimeline(using: timelineStore)
        } catch {
            // The view model preserves the last good snapshot and stores a redacted error message.
        }
    }

    private func updateSpeakerDisplay(rawLabel: String, displayLabel: String, colorToken: String) {
        guard let timelineStore else {
            timelineActionMessage = "Timeline store unavailable."
            return
        }
        do {
            try viewModel.updateSelectedSpeakerDisplay(
                rawLabel: rawLabel,
                displayLabel: displayLabel,
                colorToken: colorToken,
                using: timelineStore
            )
            timelineActionMessage = "Updated speaker display."
        } catch {
            timelineActionMessage = IngestRedaction.redact(String(describing: error))
        }
    }

    private static func makeInitialState() -> (
        registry: StreamRegistry?,
        runtime: (any AppStreamRuntimeControlling)?,
        timelineStore: StreamAppTimelineStore?,
        viewModel: StreamAppViewModel,
        persistenceError: String?
    ) {
        do {
            let databaseURL = try defaultDatabaseURL()
            let database = try SoundingDatabase(fileURL: databaseURL)
            let registry = StreamRegistry(database: database)
            let timelineStore = StreamAppTimelineStore(database: database)
            let queue = InferenceQueue()
            let cache = ModelCache()
            let timeline = AppPlayerTimelineClock()
            let rollingBuffer = RollingPCMBuffer(configuration: .appDefault())
            let runner = StreamIngestAppRuntimeRunner(
                database: database,
                decoder: AVFoundationAudioDecoder(),
                transcriber: QueuedTranscriber(WhisperKitTranscriber(cache: cache), queue: queue),
                diarizer: QueuedDiarizer(FluidAudioDiarizer(cache: cache), queue: queue),
                player: AVFoundationAppPCMPlayerAdapter(),
                timeline: timeline,
                rollingBuffer: rollingBuffer
            )
            let runtime = AppStreamRuntimeService(
                registry: registry,
                ingester: runner,
                playbackTimeline: timeline,
                rollingBuffer: rollingBuffer
            )
            var viewModel = StreamAppViewModel()
            try viewModel.reload(from: registry)
            return (registry, runtime, timelineStore, viewModel, nil)
        } catch {
            return (
                nil,
                nil,
                nil,
                StreamAppViewModel(),
                "Sounding database failed: \(IngestRedaction.redact(String(describing: error)))."
            )
        }
    }

    private static func defaultDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Sounding", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Sounding.sqlite", isDirectory: false)
    }
}

private struct StreamRow: View {
    var item: StreamAppListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name)
                    .font(.headline)
                Spacer()
                StatusPill(status: item.status)
            }
            Text(item.transportLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.sourceDescription)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct StreamDetail: View {
    var selected: StreamAppSelectedStream
    var timelineActionMessage: String?
    var startRuntime: () -> Void
    var pauseRuntime: () -> Void
    var resumeRuntime: () -> Void
    var stopRuntime: () -> Void
    var seekToLive: () -> Void
    var scrubBackward: () -> Void
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void
    var refreshTimeline: () -> Void
    var updateSpeakerDisplay: (String, String, String) -> Void

    @State private var transcriptAutoscrolls = true
    @State private var speakerLabelDrafts: [String: String] = [:]
    @State private var speakerColorDrafts: [String: String] = [:]

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StreamHeader(selected: selected)
                    RuntimeStatusCard(selected: selected)
                    PlayerCard(
                        selected: selected,
                        seekToLive: seekToLive,
                        scrubBackward: scrubBackward,
                        startRuntime: startRuntime,
                        pauseRuntime: pauseRuntime,
                        resumeRuntime: resumeRuntime,
                        stopRuntime: stopRuntime
                    )
                    TimelineDiagnosticsCard(
                        selected: selected,
                        timelineActionMessage: timelineActionMessage,
                        refreshTimeline: refreshTimeline
                    )
                    MetadataCard(selected: selected)
                    SpeakerDisplayEditor(
                        speakers: selected.speakerDisplays,
                        labelDrafts: $speakerLabelDrafts,
                        colorDrafts: $speakerColorDrafts,
                        updateSpeakerDisplay: updateSpeakerDisplay
                    )
                    TranscriptCard(
                        paragraphs: selected.recentTranscriptParagraphs,
                        autoscrolls: $transcriptAutoscrolls,
                        isSeekable: isSeekableTranscript,
                        seekToSeconds: seekToSeconds,
                        seekUnavailable: seekUnavailable
                    )
                    TimelineItemsCard(
                        items: selected.timelineItems,
                        seekToSeconds: seekToSeconds,
                        seekUnavailable: seekUnavailable
                    )
                }
                .padding(28)
            }
            .onChange(of: selected.recentTranscriptParagraphs.last?.id) { _, _ in
                guard transcriptAutoscrolls, let lastID = selected.recentTranscriptParagraphs.last?.id else {
                    return
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollProxy.scrollTo(transcriptScrollID(lastID), anchor: .bottom)
                }
            }
        }
    }

    private func isSeekableTranscript(_ paragraph: StreamAppTranscriptParagraph) -> Bool {
        selected.timelineItems.first { $0.id == "transcript:\(paragraph.id)" }?.isSeekable ?? false
    }
}

private struct StreamHeader: View {
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

private struct RuntimeStatusCard: View {
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
                    Text(selected.item.status.detail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct PlayerCard: View {
    var selected: StreamAppSelectedStream
    var seekToLive: () -> Void
    var scrubBackward: () -> Void
    var startRuntime: () -> Void
    var pauseRuntime: () -> Void
    var resumeRuntime: () -> Void
    var stopRuntime: () -> Void

    var body: some View {
        GroupBox("Player") {
            VStack(alignment: .leading, spacing: 16) {
                Text(selected.playerStateTitle)
                    .font(.headline)
                Text(selected.playerStateDetail)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Start", systemImage: "play.fill", action: startRuntime)
                        .disabled(!selected.canStartRuntime)
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

private struct TimelineDiagnosticsCard: View {
    var selected: StreamAppSelectedStream
    var timelineActionMessage: String?
    var refreshTimeline: () -> Void

    var body: some View {
        GroupBox("Timeline Health") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(selected.timelineFreshnessMessage, systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise", action: refreshTimeline)
                }
                if let lag = selected.timelineLagMessage {
                    Label(lag, systemImage: "timer")
                }
                if let diagnostics = selected.timelineDiagnostics {
                    TimelineDiagnosticGrid(diagnostics: diagnostics)
                }
                ForEach(selected.timelineDiagnostics?.validationErrors ?? [], id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let message = selected.timelineRefreshErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if let message = selected.speakerEditErrorMessage {
                    Label(message, systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.red)
                }
                if let message = selected.bufferedSeekUnavailableMessage ?? timelineActionMessage {
                    Label(message, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct TimelineDiagnosticGrid: View {
    var diagnostics: StreamAppTimelineDiagnostics

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            diagnosticRow("Latest segment", diagnostics.latestSegmentEndSeconds)
            diagnosticRow("Player position", diagnostics.playerPositionSeconds)
            diagnosticRow("Live edge", diagnostics.playerLiveEdgeSeconds)
            diagnosticRow("Lag", diagnostics.lagSeconds)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func diagnosticRow(_ title: String, _ value: Double?) -> some View {
        GridRow {
            Text(title)
            Text(value.map { String(format: "%.1fs", $0) } ?? "—")
        }
    }
}

private struct MetadataCard: View {
    var selected: StreamAppSelectedStream

    var body: some View {
        GroupBox("Metadata") {
            VStack(alignment: .leading, spacing: 12) {
                if let current = selected.currentMetadata {
                    MetadataRow(title: "Current", item: current)
                } else {
                    ContentUnavailableView(
                        "No current metadata",
                        systemImage: "music.note.list",
                        description: Text("Metadata appears here after the stream yields song or event timing.")
                    )
                    .frame(minHeight: 80)
                }

                if !selected.recentMetadata.isEmpty {
                    Divider()
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(selected.recentMetadata) { item in
                        MetadataRow(title: item.kind.title, item: item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MetadataRow: View {
    var title: String
    var item: StreamAppMetadataItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(timeRange(start: item.startSeconds, end: item.endSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SpeakerDisplayEditor: View {
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
                    description: Text("Speaker display overrides appear once transcript speaker labels arrive.")
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
                                ForEach(StreamAppTimelineStore.allowedColorTokens, id: \.self) { token in
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

private struct TranscriptCard: View {
    var paragraphs: [StreamAppTranscriptParagraph]
    @Binding var autoscrolls: Bool
    var isSeekable: (StreamAppTranscriptParagraph) -> Bool
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void

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
                }

                if paragraphs.isEmpty {
                    ContentUnavailableView(
                        "No transcript yet",
                        systemImage: "text.bubble",
                        description: Text("Bounded transcript paragraphs appear as the selected stream is processed.")
                    )
                    .frame(minHeight: 120)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(paragraphs) { paragraph in
                            TranscriptParagraphButton(
                                paragraph: paragraph,
                                isSeekable: isSeekable(paragraph),
                                seekToSeconds: seekToSeconds,
                                seekUnavailable: seekUnavailable
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

private struct TranscriptParagraphButton: View {
    var paragraph: StreamAppTranscriptParagraph
    var isSeekable: Bool
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void

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
        .accessibilityLabel("Transcript from \(paragraph.speakerDisplay.displayLabel) at \(timeRange(start: paragraph.startSeconds, end: paragraph.endSeconds)): \(paragraph.text)")
        .accessibilityHint(isSeekable ? "Seeks playback to this buffered transcript paragraph." : "Reports that this transcript paragraph is outside the buffered range.")
    }
}

private struct TimelineItemsCard: View {
    var items: [StreamAppTimelineItem]
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void

    var body: some View {
        GroupBox("Timeline") {
            if items.isEmpty {
                ContentUnavailableView(
                    "No timeline items yet",
                    systemImage: "list.bullet.indent",
                    description: Text("Transcript, metadata, and event moments appear here once refreshed.")
                )
                .frame(minHeight: 100)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        TimelineItemButton(
                            item: item,
                            seekToSeconds: seekToSeconds,
                            seekUnavailable: seekUnavailable
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TimelineItemButton: View {
    var item: StreamAppTimelineItem
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void

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
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Text(timeRange(start: item.startSeconds, end: item.endSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
        .accessibilityLabel("\(item.kind.title) at \(timeRange(start: item.startSeconds, end: item.endSeconds)): \(item.title)")
        .accessibilityHint(item.isSeekable ? "Seeks playback to this buffered timeline item." : "Reports that this timeline item is outside the buffered range.")
    }
}

private struct SpeakerBadge: View {
    var speaker: StreamAppSpeakerDisplay

    var body: some View {
        Text(speaker.displayLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(speaker.color.accessibleForeground)
            .background(speaker.color, in: Capsule())
            .accessibilityLabel("Speaker \(speaker.displayLabel)")
    }
}

private struct StatusPill: View {
    var status: StreamAppStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(foregroundStyle)
            .background(backgroundStyle, in: Capsule())
    }

    private var foregroundStyle: Color {
        switch status {
        case .error, .removed:
            return .red
        case .running:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .ready, .paused, .stopped:
            return .secondary
        }
    }

    private var backgroundStyle: Color {
        foregroundStyle.opacity(0.14)
    }
}

private func transcriptScrollID(_ id: Int64) -> String {
    "transcript-paragraph-\(id)"
}

private func timeRange(start: Double, end: Double?) -> String {
    guard let end, end != start else { return String(format: "%.1fs", start) }
    return String(format: "%.1f–%.1fs", start, end)
}

private extension StreamAppMetadataKind {
    var title: String {
        switch self {
        case .song:
            return "Song"
        case .event:
            return "Event"
        }
    }
}

private extension StreamAppTimelineItemKind {
    var title: String {
        switch self {
        case .transcript:
            return "Transcript"
        case .song:
            return "Song"
        case .event:
            return "Event"
        }
    }

    var systemImage: String {
        switch self {
        case .transcript:
            return "text.bubble"
        case .song:
            return "music.note"
        case .event:
            return "flag"
        }
    }
}

private extension StreamAppSpeakerDisplay {
    var color: Color {
        switch colorToken {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "pink": return .pink
        case "purple": return .purple
        case "teal": return .teal
        case "violet": return .indigo
        case "yellow": return .yellow
        default: return .secondary
        }
    }
}

private extension Color {
    var accessibleForeground: Color {
        self == .yellow ? .black : .white
    }
}

#Preview {
    ContentView()
}
