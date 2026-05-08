import AppKit
import SoundingKit
import SwiftUI

struct ContentView: View {
    private let registry: StreamRegistry?
    private let runtime: (any AppStreamRuntimeControlling)?
    private let timelineStore: StreamAppTimelineStore?
    private let searchStore: StreamAppSearchStore?
    private let statusStore: AppStreamRuntimeStatusStore?
    private let diagnosticsLog = AppRuntimeDiagnosticsLog()
    @State private var viewModel: StreamAppViewModel
    @State private var persistenceError: String?
    @State private var timelineActionMessage: String?
    @State private var streamVolumes: [Int64: Double] = [:]
    @State private var mutedStreamIDs: Set<Int64> = []
    @State private var isAddingStream = false
    @State private var editingStreamID: Int64?

    init(preferences: SoundingAppPreferences? = nil) {
        let initial = Self.makeInitialState(preferences: preferences)
        registry = initial.registry
        runtime = initial.runtime
        timelineStore = initial.timelineStore
        searchStore = initial.searchStore
        statusStore = initial.statusStore
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
            refreshRuntimeStatuses()
            await observeRuntime()
        }
        .task(id: viewModel.selectedStreamID) {
            await refreshSelectedTimelineLoop(streamID: viewModel.selectedStreamID)
        }
        .onChange(of: viewModel.selectedStreamID) { _, _ in
            refreshRuntimeStatuses()
            refreshSelectedTimeline()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.willSleepNotification)
        ) { _ in
            handleSystemSleepNotification()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didWakeNotification)
        ) { _ in
            handleSystemWakeNotification()
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
                            .contextMenu {
                                Button("Edit Stream", systemImage: "pencil") {
                                    editStream(stream.id)
                                }
                                Divider()
                                Button("Remove Stream", systemImage: "trash", role: .destructive) {
                                    removeStream(stream.id)
                                }
                                Divider()
                                Button(
                                    stream.diarizationEnabled
                                        ? "Disable Speaker Diarization"
                                        : "Enable Speaker Diarization",
                                    systemImage: stream.diarizationEnabled
                                        ? "person.wave.2.fill"
                                        : "person.wave.2"
                                ) {
                                    setDiarizationEnabled(
                                        for: stream.id,
                                        isEnabled: !stream.diarizationEnabled
                                    )
                                }
                            }
                    }
                }
            }

            Divider()

            sidebarAddStreamArea
                .padding(16)
        }
    }

    private var sidebarAddStreamArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isAddingStream {
                addStreamForm
            } else {
                Button {
                    isAddingStream = true
                } label: {
                    Label("Add Stream", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            SettingsLink {
                Label("Preferences", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var addStreamForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    editingStreamID == nil ? "Add Stream" : "Edit Stream",
                    systemImage: editingStreamID == nil ? "plus.circle" : "pencil"
                )
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    isAddingStream = false
                    editingStreamID = nil
                    viewModel.addDraft = StreamAppAddDraft(transport: viewModel.addDraft.transport)
                }
            }

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
                saveStreamDraft()
            } label: {
                Label(editingStreamID == nil ? "Save Stream" : "Update Stream", systemImage: "tray.and.arrow.down")
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
            VStack(spacing: 0) {
                StreamDetail(
                    selected: selected,
                    timelineActionMessage: timelineActionMessage,
                    seekToSeconds: { seekToSeconds($0) },
                    seekUnavailable: { seconds in
                        reportSeekUnavailable(seconds: seconds, selected: selected)
                    },
                    refreshTimeline: { refreshSelectedTimeline() },
                    clearTimeline: { clearTimeline(for: selected.item.id) },
                    searchDraft: Binding(
                        get: { viewModel.searchDraft },
                        set: { viewModel.updateSearchDraft($0) }
                    ),
                    runSearch: { runSearch() },
                    clearSearch: { clearSearch() },
                    selectSearchResult: { resultID in selectSearchResult(resultID) },
                    updateSpeakerDisplay: { rawLabel, displayLabel, colorToken in
                        updateSpeakerDisplay(
                            rawLabel: rawLabel, displayLabel: displayLabel, colorToken: colorToken)
                    }
                )
                Divider()
                GlobalPlayerBar(
                    selected: selected,
                    seekToLive: { seekToLive() },
                    scrubBackward: { scrubBackward(seconds: 30) },
                    startRuntime: { startRuntime(for: selected.item.id) },
                    pauseRuntime: { pauseRuntime(for: selected.item.id) },
                    resumeRuntime: { resumeRuntime(for: selected.item.id) },
                    stopRuntime: { stopRuntime(for: selected.item.id) },
                    volume: Binding(
                        get: { streamVolumes[selected.item.id] ?? 1.0 },
                        set: { updateVolume(for: selected.item.id, volume: $0) }
                    ),
                    isMuted: Binding(
                        get: { mutedStreamIDs.contains(selected.item.id) },
                        set: { updateMuted(for: selected.item.id, isMuted: $0) }
                    )
                )
            }
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
            let added = try viewModel.addStream(using: registry)
            diagnosticsLog.recordEvent(
                "ui.stream.added",
                streamID: added.id,
                streamName: added.name,
                sourceDescription: added.sourceDescription,
                phase: "ui.addStream",
                fields: ["transport": added.transportLabel]
            )
            persistenceError = nil
            timelineActionMessage = nil
            isAddingStream = false
            editingStreamID = nil
            refreshRuntimeStatuses()
            refreshSelectedTimeline()
        } catch {
            // The view model stores redacted, user-facing validation errors.
        }
    }

    private func saveStreamDraft() {
        if let editingStreamID {
            updateStream(editingStreamID)
        } else {
            addStream()
        }
    }

    private func editStream(_ streamID: Int64) {
        guard let registry else { return }
        do {
            let source = try registry.reconnectSource(id: streamID)
            guard let source else { return }
            viewModel.addDraft = StreamAppAddDraft(
                name: source.name,
                source: source.source,
                transport: StreamAppTransport.fromRegistryStreamType(source.streamType) ?? .hls
            )
            editingStreamID = streamID
            isAddingStream = true
        } catch {
            persistenceError = IngestRedaction.redact(String(describing: error))
        }
    }

    private func updateStream(_ streamID: Int64) {
        guard let registry else { return }
        do {
            let request = try StreamAppViewModel.validateAddDraft(viewModel.addDraft)
            _ = try registry.update(
                id: streamID,
                name: request.name,
                streamType: request.registryStreamType,
                source: request.source
            )
            try viewModel.reload(from: registry)
            viewModel.selectedStreamID = streamID
            viewModel.addDraft = StreamAppAddDraft(transport: request.transport)
            editingStreamID = nil
            isAddingStream = false
            persistenceError = nil
        } catch let error as StreamAppValidationError {
            persistenceError = error.description
        } catch {
            persistenceError = IngestRedaction.redact(String(describing: error))
        }
    }

    private func startRuntime(for streamID: Int64) {
        guard let runtime else {
            persistenceError = "Sounding runtime unavailable."
            return
        }
        Task {
            diagnosticsLog.recordEvent(
                "ui.start.clicked",
                streamID: streamID,
                phase: "ui.control"
            )
            do {
                try await runtime.start(streamID: streamID)
                persistenceError = nil
            } catch {
                persistenceError = IngestRedaction.redact(String(describing: error))
            }
        }
    }

    private func pauseRuntime(for streamID: Int64) {
        guard let runtime else { return }
        Task {
            diagnosticsLog.recordEvent("ui.pause.clicked", streamID: streamID, phase: "ui.control")
            await runtime.pause(streamID: streamID)
        }
    }

    private func resumeRuntime(for streamID: Int64) {
        guard let runtime else { return }
        Task {
            diagnosticsLog.recordEvent("ui.resume.clicked", streamID: streamID, phase: "ui.control")
            await runtime.resume(streamID: streamID)
        }
    }

    private func stopRuntime(for streamID: Int64) {
        guard let runtime else { return }
        Task {
            diagnosticsLog.recordEvent("ui.stop.clicked", streamID: streamID, phase: "ui.control")
            await runtime.stop(streamID: streamID)
        }
    }

    private func removeStream(_ streamID: Int64) {
        guard let registry else {
            persistenceError = "Sounding database unavailable."
            return
        }
        Task {
            diagnosticsLog.recordEvent("ui.remove.clicked", streamID: streamID, phase: "ui.remove")
            await runtime?.stop(streamID: streamID)
            do {
                _ = try registry.remove(id: streamID)
                diagnosticsLog.recordEvent("ui.stream.removed", streamID: streamID, phase: "ui.remove")
                if viewModel.selectedStreamID == streamID {
                    viewModel.selectedStreamID = nil
                }
                try viewModel.reload(from: registry)
                mutedStreamIDs.remove(streamID)
                streamVolumes[streamID] = nil
                persistenceError = nil
                timelineActionMessage = "Removed stream."
                refreshRuntimeStatuses()
                refreshSelectedTimeline()
            } catch {
                persistenceError = IngestRedaction.redact(String(describing: error))
            }
        }
    }

    private func setDiarizationEnabled(for streamID: Int64, isEnabled: Bool) {
        guard let registry else {
            persistenceError = "Sounding database unavailable."
            return
        }
        Task {
            diagnosticsLog.recordEvent(
                "ui.stream.diarization.toggled",
                streamID: streamID,
                phase: "ui.stream",
                fields: ["isEnabled": String(isEnabled)]
            )
            do {
                _ = try registry.setDiarizationEnabled(id: streamID, isEnabled: isEnabled)
                try viewModel.reload(from: registry)
                persistenceError = nil
                timelineActionMessage = isEnabled
                    ? "Speaker diarization enabled for this stream. Restart the stream to apply it."
                    : "Speaker diarization disabled for this stream. Restart the stream to apply it."
                refreshRuntimeStatuses()
                refreshSelectedTimeline()
            } catch {
                persistenceError = IngestRedaction.redact(String(describing: error))
            }
        }
    }

    private func handleSystemSleepNotification() {
        guard let runtime else { return }
        Task {
            await runtime.suspendForSystemSleep(reason: "system-sleep")
            refreshRuntimeStatuses()
        }
    }

    private func handleSystemWakeNotification() {
        guard let runtime else { return }
        Task {
            await runtime.recoverFromSystemWake(reason: "system-wake")
            refreshRuntimeStatuses()
        }
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

    private func updateVolume(for streamID: Int64, volume: Double) {
        let clamped = min(max(volume, 0), 1)
        streamVolumes[streamID] = clamped
        diagnosticsLog.recordEvent(
            "ui.volume.changed",
            streamID: streamID,
            phase: "ui.volume",
            fields: ["volume": String(format: "%.3f", clamped)]
        )
        Task { await runtime?.setVolume(streamID: streamID, volume: clamped) }
    }

    private func updateMuted(for streamID: Int64, isMuted: Bool) {
        if isMuted {
            mutedStreamIDs.insert(streamID)
        } else {
            mutedStreamIDs.remove(streamID)
        }
        diagnosticsLog.recordEvent(
            "ui.mute.changed",
            streamID: streamID,
            phase: "ui.volume",
            fields: ["isMuted": String(isMuted)]
        )
        Task { await runtime?.setMuted(streamID: streamID, isMuted: isMuted) }
    }

    private func reportSeekUnavailable(seconds: Double, selected: StreamAppSelectedStream) {
        timelineActionMessage =
            selected.bufferedSeekUnavailableMessage
            ?? String(
                format: "%.1fs is outside the current buffered range. %@",
                seconds,
                selected.bufferedRangeTitle
            )
    }

    private func observeRuntime() async {
        guard let runtime else { return }
        for await event in await runtime.events() {
            diagnosticsLog.recordEvent(
                "ui.runtime.event.received",
                streamID: event.streamID,
                phase: event.phase.statusPhase.rawValue,
                message: event.message,
                fields: ["hasResult": String(event.result != nil)]
            )
            viewModel.applyRuntimeEvent(event)
            refreshRuntimeStatus(streamID: event.streamID)
            if event.streamID == viewModel.selectedStreamID {
                timelineActionMessage =
                    event.result?.playerTimeline?.unavailableRangeMessage
                    ?? event.result?.playerTimeline?.lastMessage
                    ?? event.message
                refreshRuntimeStatuses()
                refreshSelectedTimeline()
            }
        }
    }

    private func refreshRuntimeStatuses() {
        guard let statusStore else { return }
        do {
            viewModel.applyRuntimeStatuses(try statusStore.statuses())
            persistenceError = nil
        } catch {
            persistenceError = IngestRedaction.redact(String(describing: error))
        }
    }

    private func refreshRuntimeStatus(streamID: Int64) {
        guard let statusStore else { return }
        do {
            if let snapshot = try statusStore.status(streamID: streamID) {
                viewModel.applyRuntimeStatus(snapshot)
            }
        } catch {
            persistenceError = IngestRedaction.redact(String(describing: error))
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
                if let runtime, let streamID, let event = await runtime.snapshot(streamID: streamID) {
                    viewModel.applyRuntimeEvent(event)
                }
                refreshRuntimeStatuses()
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

    private func clearTimeline(for streamID: Int64) {
        guard let timelineStore else {
            timelineActionMessage = "Timeline storage is unavailable."
            return
        }

        do {
            let deletedCount = try timelineStore.clearTimeline(streamID: streamID)
            viewModel.clearSearch()
            refreshSelectedTimeline()
            timelineActionMessage = deletedCount == 0
                ? "No timeline rows to clear."
                : "Cleared \(deletedCount) timeline rows."
        } catch {
            timelineActionMessage = "Timeline clear failed."
        }
    }

    private func runSearch() {
        guard let searchStore else {
            timelineActionMessage = "Transcript search is unavailable."
            return
        }
        do {
            var draft = viewModel.searchDraft
            draft.speakerLabels = []
            viewModel.updateSearchDraft(draft)
            _ = try viewModel.runSearch(using: searchStore)
            timelineActionMessage = nil
        } catch {
            // The view model stores a redacted, user-facing search message.
        }
    }

    private func clearSearch() {
        viewModel.clearSearch()
        timelineActionMessage = nil
    }

    private func selectSearchResult(_ resultID: String) -> StreamAppSearchSelectionAction? {
        guard let timelineStore else {
            timelineActionMessage = "Timeline store unavailable."
            return StreamAppSearchSelectionAction(
                shouldSeek: false,
                message: timelineActionMessage
            )
        }
        do {
            let action = try viewModel.selectSearchResult(id: resultID, using: timelineStore)
            timelineActionMessage = action.message
            return action
        } catch {
            // The view model stores a redacted jump message and preserves the last good timeline.
            return StreamAppSearchSelectionAction(
                shouldSeek: false,
                message: viewModel.selectedStream?.searchJumpMessage
            )
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

    private static func makeInitialState(preferences: SoundingAppPreferences? = nil)
        -> SoundingAppRuntimeStartupState
    {
        if let preferences {
            return SoundingAppRuntimeFactory().makeStartupState(preferences: preferences)
        }
        return SoundingAppRuntimeFactory().makeStartupState()
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
            if let detail = item.runtimeStatusDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if item.diarizationEnabled {
                Text("Speaker diarization on")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text("Control-click for stream options")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct StreamDetail: View {
    var selected: StreamAppSelectedStream
    var timelineActionMessage: String?
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void
    var refreshTimeline: () -> Void
    var clearTimeline: () -> Void
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
                    isDiarizationEnabled: selected.item.diarizationEnabled,
                    actionMessage: timelineActionMessage,
                    refreshTimeline: refreshTimeline,
                    clearTimeline: clearTimeline,
                    seekToSeconds: seekToSeconds,
                    seekUnavailable: seekUnavailable
                )
            }
            .padding(28)
        }
    }

    private func handleSearchResultSelection(_ resultID: String) {
        guard let action = selectSearchResult(resultID) else { return }
        if action.shouldSeek, let seconds = action.seekSeconds, seconds.isFinite {
            seekToSeconds(seconds)
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

private struct PlayerCard: View {
    var selected: StreamAppSelectedStream
    var seekToLive: () -> Void
    var scrubBackward: () -> Void
    var startRuntime: () -> Void
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
                    Button("Restart", systemImage: "arrow.clockwise", action: startRuntime)
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

private struct GlobalPlayerBar: View {
    var selected: StreamAppSelectedStream
    var seekToLive: () -> Void
    var scrubBackward: () -> Void
    var startRuntime: () -> Void
    var pauseRuntime: () -> Void
    var resumeRuntime: () -> Void
    var stopRuntime: () -> Void
    @Binding var volume: Double
    @Binding var isMuted: Bool

    private var nowPlaying: StreamAppMetadataItem? {
        selected.currentMetadata ?? selected.recentMetadata.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.item.name)
                        .font(.headline)
                    Text(selected.playerStateTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start", systemImage: "play.fill", action: startRuntime)
                    .disabled(!selected.canStartRuntime)
                Button("Restart", systemImage: "arrow.clockwise", action: startRuntime)
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

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                if let nowPlaying {
                    Text(nowPlaying.artist ?? "Metadata")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(nowPlaying.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let subtitle = nowPlaying.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text("No current metadata")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Toggle("Mute", isOn: $isMuted)
                    .toggleStyle(.switch)
                Slider(value: $volume, in: 0...1)
                    .disabled(isMuted)
                Text("\(Int((volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Text(selected.bufferedRangeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct VisibleIssueRow: View {
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

    private var displayedCurrentMetadata: StreamAppMetadataItem? {
        selected.currentMetadata ?? selected.recentMetadata.first
    }

    private var recentMetadata: [StreamAppMetadataItem] {
        guard let displayedCurrentMetadata else { return selected.recentMetadata }
        return selected.recentMetadata.filter { $0.id != displayedCurrentMetadata.id }
    }

    var body: some View {
        GroupBox("Metadata") {
            VStack(alignment: .leading, spacing: 12) {
                if let current = displayedCurrentMetadata {
                    MetadataRow(title: selected.currentMetadata == nil ? "Latest" : "Current", item: current)
                } else {
                    ContentUnavailableView(
                        "No current metadata",
                        systemImage: "music.note.list",
                        description: Text(
                            "Metadata appears here after the stream yields song or event timing.")
                    )
                    .frame(minHeight: 80)
                }

                if !recentMetadata.isEmpty {
                    Divider()
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(recentMetadata) { item in
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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !artist.isEmpty {
                        SpeakerBadge(
                            speaker: StreamAppSpeakerDisplay(
                                rawLabel: artist,
                                displayLabel: artist,
                                colorToken: StreamAppSpeakerDisplay.fallbackColorToken(for: artist)
                            )
                        )
                    }
                    Text(item.title)
                        .font(.headline)
                }
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

private struct SearchCard: View {
    var selected: StreamAppSelectedStream
    @Binding var draft: StreamAppSearchDraft
    var runSearch: () -> Void
    var clearSearch: () -> Void
    var selectResult: (String) -> Void

    var body: some View {
        GroupBox("Transcript Search") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        "Search transcript text",
                        text: Binding(
                            get: { draft.phrase },
                            set: { draft.phrase = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runSearch)
                    .accessibilityLabel("Search transcript text")
                    .accessibilityHint(
                        "Enter text to find in persisted transcript paragraphs, then press Search.")

                    Picker(
                        "Scope",
                        selection: Binding(
                            get: { draft.scopeToSelectedStream },
                            set: { draft.scopeToSelectedStream = $0 }
                        )
                    ) {
                        Text("Selected stream").tag(true)
                        Text("All streams").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Search scope")
                    .accessibilityHint(
                        "Choose whether transcript search is limited to the selected stream or all persisted streams."
                    )
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Run from")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("2026-05-01T18:00:00Z", text: optionalText(\.runStartedAtFrom))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Run date from filter")
                            .accessibilityHint(
                                "Optional ISO timestamp for the earliest ingest run to search.")
                    }
                    GridRow {
                        Text("Run through")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("2026-05-01T19:00:00Z", text: optionalText(\.runStartedAtThrough))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Run date through filter")
                            .accessibilityHint(
                                "Optional ISO timestamp for the latest ingest run to search.")
                    }
                }

                HStack(spacing: 12) {
                    Button("Search", systemImage: "magnifyingglass", action: runSearch)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityHint(
                            "Runs one bounded persisted transcript search with the current filters."
                        )
                    Button("Clear", systemImage: "xmark.circle") {
                        draft = StreamAppSearchDraft(
                            scopeToSelectedStream: draft.scopeToSelectedStream)
                        clearSearch()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(
                        "Clears the search text, filters, results, and selected transcript jump.")
                }

                SearchStatusView(selected: selected)

                if selected.searchResults.isEmpty {
                    if selected.searchSnapshot != nil, selected.searchErrorMessage == nil {
                        ContentUnavailableView(
                            "No search results",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(
                                "Try a different phrase, scope, or run date filter.")
                        )
                        .frame(minHeight: 96)
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(selected.searchResults) { result in
                            SearchResultButton(
                                result: result,
                                isSelected: selected.selectedSearchResultID == result.id,
                                selectResult: selectResult
                            )
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func optionalText(_ keyPath: WritableKeyPath<StreamAppSearchDraft, String?>)
        -> Binding<String>
    {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                draft[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
            }
        )
    }
}

private struct SearchStatusView: View {
    var selected: StreamAppSelectedStream

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let diagnostics = selected.searchDiagnostics {
                Label(
                    diagnostics.statusMessage,
                    systemImage: diagnostics.status == .empty
                        ? "magnifyingglass" : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(diagnostics.status == .empty ? Color.secondary : Color.green)
                .accessibilityLabel("Search status: \(diagnostics.statusMessage)")

                Text(
                    "\(diagnostics.resultCount) result\(diagnostics.resultCount == 1 ? "" : "s") • refreshed \(diagnostics.refreshedAt)"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Search result count \(diagnostics.resultCount)")

                if diagnostics.unseekableResultCount > 0 {
                    Label(
                        "\(diagnostics.unseekableResultCount) result\(diagnostics.unseekableResultCount == 1 ? "" : "s") outside the playback buffer",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHint(
                        "Selecting these results scrolls the transcript but does not seek playback."
                    )
                }

                ForEach(diagnostics.validationErrors, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Search validation error: \(message)")
                }
                if let message = diagnostics.databaseErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Search database error: \(message)")
                }
            } else {
                Label(
                    "Enter a phrase and run Search to query persisted transcripts.",
                    systemImage: "magnifyingglass"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let message = selected.searchErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Search error: \(message)")
            }
            if let message = selected.searchJumpMessage {
                Label(message, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Search selection status: \(message)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SearchResultButton: View {
    var result: StreamAppSearchResult
    var isSelected: Bool
    var selectResult: (String) -> Void

    var body: some View {
        Button {
            selectResult(result.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SpeakerBadge(speaker: result.speakerDisplay)
                    Text(timeRange(start: result.startSeconds, end: result.endSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(result.streamTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isSelected {
                        Label("Selected", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    Label(
                        result.isSeekable ? "Buffered" : "Not buffered",
                        systemImage: result.isSeekable ? "play.circle" : "exclamationmark.circle"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.isSeekable ? .blue : .secondary)
                }

                Text(result.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                if !result.context.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.context) { context in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(context.role.searchCardTitle)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading)
                                Text(
                                    timeRange(start: context.startSeconds, end: context.endSeconds)
                                )
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                Text(context.speakerDisplay.displayLabel)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(context.text)
                                    .font(.caption)
                                    .foregroundStyle(context.role == .match ? .primary : .secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                if let runStartedAt = result.runStartedAt {
                    Text("Run \(runStartedAt) • \(result.sourceDescription)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let message = result.seekUnavailableMessage, !result.isSeekable {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Search result from \(result.speakerDisplay.displayLabel) at \(timeRange(start: result.startSeconds, end: result.endSeconds)): \(result.text)"
        )
        .accessibilityHint(
            result.isSeekable
                ? "Reveals this transcript result and seeks playback because it is buffered."
                : "Reveals this transcript result without seeking because it is outside the playback buffer."
        )
    }
}

private struct TranscriptCard: View {
    var paragraphs: [StreamAppTranscriptParagraph]
    @Binding var autoscrolls: Bool
    var isSeekable: (StreamAppTranscriptParagraph) -> Bool
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void
    var clearTimeline: () -> Void

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
        .accessibilityLabel(
            "Transcript from \(paragraph.speakerDisplay.displayLabel) at \(timeRange(start: paragraph.startSeconds, end: paragraph.endSeconds)): \(paragraph.text)"
        )
        .accessibilityHint(
            isSeekable
                ? "Seeks playback to this buffered transcript paragraph."
                : "Reports that this transcript paragraph is outside the buffered range.")
    }
}

private struct TimelineItemsCard: View {
    var items: [StreamAppTimelineItem]
    var isDiarizationEnabled: Bool
    var actionMessage: String?
    var refreshTimeline: () -> Void
    var clearTimeline: () -> Void
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void

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
                                seekUnavailable: seekUnavailable
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

private struct TimelineItemButton: View {
    var item: StreamAppTimelineItem
    var isDiarizationEnabled: Bool
    var seekToSeconds: (Double) -> Void
    var seekUnavailable: (Double) -> Void

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
        .contextMenu {
            Button("Copy Text", systemImage: "doc.on.doc") {
                copyTimelineText(copyText)
            }
            Button("Copy All", systemImage: "doc.on.clipboard") {
                copyTimelineText(copyAllText)
            }
            Button("Save", systemImage: "square.and.arrow.down") {
                saveTimelineText()
            }
            Button("Play From Here", systemImage: "play.fill") {
                if item.isSeekable {
                    seekToSeconds(item.startSeconds)
                } else {
                    seekUnavailable(item.startSeconds)
                }
            }
            .disabled(!item.isSeekable)
        }
        .accessibilityLabel(
            "\(item.kind.title) at \(timeRange(item: item)): \(primaryText)"
        )
        .accessibilityHint(
            item.isSeekable
                ? "Seeks playback to this buffered timeline item."
                : "This item is outside the current buffered audio range.")
    }

    private func copyTimelineText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func saveTimelineText() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultSaveName
        panel.allowedFileTypes = ["txt"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? copyAllText.write(to: url, atomically: true, encoding: .utf8)
    }

    private var copyText: String {
        switch item.kind {
        case .transcript:
            return item.subtitle ?? item.title
        case .song, .event:
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                return "\(item.title)\n\(subtitle)"
            }
            return item.title
        }
    }

    private var copyAllText: String {
        let timestamp = timeRange(item: item)
        switch item.kind {
        case .transcript:
            return "\(timestamp)\n\(item.subtitle ?? item.title)"
        case .song, .event:
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                return "\(timestamp)\n\(item.title)\n\(subtitle)"
            }
            return "\(timestamp)\n\(item.title)"
        }
    }

    private var defaultSaveName: String {
        let base = item.kind == .transcript ? "transcript" : "timeline"
        let id = item.id
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "\(base)-\(id).txt"
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
        case .connecting, .recovering, .reconnecting:
            return .orange
        case .ready, .paused, .suspended, .stopped:
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

private func timeRange(item: StreamAppTimelineItem) -> String {
    guard let start = clockTime(item.startTimestamp) else {
        return timeRange(start: item.startSeconds, end: item.endSeconds)
    }
    let duration = max(0, (item.endSeconds ?? item.startSeconds) - item.startSeconds)
    guard let end = clockTime(item.endTimestamp), end != start else {
        return "\(start) \(String(format: "%.0fs", duration))"
    }
    return "\(start) - \(end) \(String(format: "%.0fs", duration))"
}

private func clockTime(_ timestamp: String?) -> String? {
    guard let timestamp,
          let date = ISO8601DateFormatter().date(from: timestamp) else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

extension StreamAppSearchResult {
    fileprivate var streamTitle: String {
        if let streamName, !streamName.isEmpty { return streamName }
        return streamType.uppercased()
    }
}

extension TranscriptQuery.ContextRole {
    fileprivate var searchCardTitle: String {
        switch self {
        case .before:
            return "Before"
        case .match:
            return "Match"
        case .after:
            return "After"
        }
    }
}

extension StreamAppMetadataKind {
    fileprivate var title: String {
        switch self {
        case .song:
            return "Song"
        case .event:
            return "Event"
        }
    }
}

extension StreamAppTimelineItemKind {
    fileprivate var title: String {
        switch self {
        case .transcript:
            return "Transcript"
        case .song:
            return "Song"
        case .event:
            return "Event"
        }
    }

    fileprivate var systemImage: String {
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

extension StreamAppSpeakerDisplay {
    fileprivate static func fallbackColorToken(for rawLabel: String) -> String {
        let total = rawLabel.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let tokens = ["blue", "green", "orange", "pink", "purple", "teal", "violet", "yellow"]
        return tokens[abs(total) % tokens.count]
    }

    fileprivate var color: Color {
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

extension Color {
    fileprivate var accessibleForeground: Color {
        self == .yellow ? .black : .white
    }
}

#Preview {
    ContentView()
}
