import AppKit
import SoundingKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private let registry: StreamRegistry?
    private let runtime: (any AppStreamRuntimeControlling)?
    private let timelineStore: StreamAppTimelineStore?
    private let searchStore: StreamAppSearchStore?
    private let statusStore: AppStreamRuntimeStatusStore?
    private let diagnosticsLog = AppRuntimeDiagnosticsLog()
    private let transportDetector = StreamAppTransportDetector()
    @State private var viewModel: StreamAppViewModel
    @State private var persistenceError: String?
    @State private var timelineActionMessage: String?
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
                            "Add a stream URL to prepare it for the app runtime.")
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
                                Button(
                                    stream.audioArchiveEnabled
                                        ? "Disable Audio Archive"
                                        : "Enable Audio Archive",
                                    systemImage: stream.audioArchiveEnabled
                                        ? "externaldrive.badge.minus"
                                        : "externaldrive.badge.plus"
                                ) {
                                    setAudioArchiveEnabled(
                                        for: stream.id,
                                        isEnabled: !stream.audioArchiveEnabled
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
                    viewModel.addDraft = StreamAppAddDraft()
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
                "https://example.test/live",
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
                    seekToSeconds: { seekToSeconds($0, streamID: selected.item.id) },
                    seekUnavailable: { seconds in
                        reportSeekUnavailable(seconds: seconds, selected: selected)
                    },
                    refreshTimeline: { refreshSelectedTimeline() },
                    clearTimeline: { clearTimeline(for: selected.item.id) },
                    exportTimelineItem: { item in
                        exportTimelineItem(item, selected: selected, range: false)
                    },
                    exportTimelineRange: { item in
                        exportTimelineItem(item, selected: selected, range: true)
                    },
                    reportTimelineActionMessage: { message in
                        timelineActionMessage = message
                    },
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
                    seekToLive: { seekToLive(streamID: selected.item.id) },
                    scrubBackward: { scrubBackward(seconds: 30, streamID: selected.item.id) },
                    startRuntime: { startRuntime(for: selected.item.id) },
                    restartRuntime: { restartRuntime(for: selected.item.id) },
                    pauseRuntime: { pauseRuntime(for: selected.item.id) },
                    resumeRuntime: { resumeRuntime(for: selected.item.id) },
                    stopRuntime: { stopRuntime(for: selected.item.id) },
                    volume: Binding(
                        get: { viewModel.volume(for: selected.item.id) },
                        set: { updateVolume(for: selected.item.id, volume: $0) }
                    ),
                    isMuted: Binding(
                        get: { viewModel.isMuted(streamID: selected.item.id) },
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

    @MainActor
    private func addStream() async {
        guard let registry else {
            persistenceError =
                "Sounding database unavailable. Choose a writable Application Support location."
            return
        }

        do {
            let request = try await StreamAppViewModel.validateAddDraft(
                viewModel.addDraft,
                detector: transportDetector
            )
            let added = try viewModel.addStream(using: registry, request: request)
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
        Task { @MainActor in
            if let editingStreamID {
                await updateStream(editingStreamID)
            } else {
                await addStream()
            }
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

    @MainActor
    private func updateStream(_ streamID: Int64) async {
        guard let registry else { return }
        do {
            let request = try await StreamAppViewModel.validateAddDraft(
                viewModel.addDraft,
                detector: transportDetector
            )
            _ = try registry.update(
                id: streamID,
                name: request.name,
                streamType: request.registryStreamType,
                source: request.source
            )
            try viewModel.reload(from: registry)
            viewModel.selectedStreamID = streamID
            viewModel.addDraft = StreamAppAddDraft()
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

    private func restartRuntime(for streamID: Int64) {
        guard let runtime else {
            persistenceError = "Sounding runtime unavailable."
            return
        }
        Task {
            diagnosticsLog.recordEvent(
                "ui.restart.clicked",
                streamID: streamID,
                phase: "ui.control"
            )
            do {
                try await runtime.restart(streamID: streamID)
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

    private func setAudioArchiveEnabled(for streamID: Int64, isEnabled: Bool) {
        guard let registry else {
            persistenceError = "Sounding database unavailable."
            return
        }
        Task {
            diagnosticsLog.recordEvent(
                "ui.stream.audioArchive.toggled",
                streamID: streamID,
                phase: "ui.stream",
                fields: ["isEnabled": String(isEnabled)]
            )
            do {
                _ = try viewModel.updateAudioArchive(
                    streamID: streamID,
                    isEnabled: isEnabled,
                    using: registry
                )
                persistenceError = nil
                timelineActionMessage = isEnabled
                    ? "Audio archive enabled for this stream. Restart the stream to apply it."
                    : "Audio archive disabled for this stream. Restart the stream to apply it."
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

    private func seekToLive(streamID: Int64) {
        guard let runtime else { return }
        Task { await runtime.seekToLive(streamID: streamID) }
    }

    private func scrubBackward(seconds: Double, streamID: Int64) {
        guard let runtime else { return }
        Task { await runtime.scrubBackward(seconds: seconds, streamID: streamID) }
    }

    private func seekToSeconds(_ seconds: Double, streamID: Int64) {
        guard let runtime else {
            timelineActionMessage = "Sounding runtime unavailable."
            return
        }
        timelineActionMessage = String(format: "Seeking to %.1fs…", seconds)
        Task { await runtime.seek(to: seconds, streamID: streamID) }
    }

    private func updateVolume(for streamID: Int64, volume: Double) {
        let clamped = min(max(volume, 0), 1)
        viewModel.updateVolume(streamID: streamID, volume: clamped)
        diagnosticsLog.recordEvent(
            "ui.volume.changed",
            streamID: streamID,
            phase: "ui.volume",
            fields: ["volume": String(format: "%.3f", clamped)]
        )
        Task { await runtime?.setVolume(streamID: streamID, volume: clamped) }
    }

    private func updateMuted(for streamID: Int64, isMuted: Bool) {
        viewModel.updateMuted(streamID: streamID, isMuted: isMuted)
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

    private func exportTimelineItem(
        _ item: StreamAppTimelineItem,
        selected: StreamAppSelectedStream,
        range: Bool
    ) {
        do {
            if range {
                let items = selected.timelineItems.filter { candidate in
                    guard let itemEnd = item.endSeconds else { return candidate.id == item.id }
                    let candidateEnd = candidate.endSeconds ?? candidate.startSeconds
                    return candidate.startSeconds < itemEnd && candidateEnd > item.startSeconds
                }
                let data = try TimelineExportService.timelineJSON(items: items.isEmpty ? [item] : items)
                try saveExportData(
                    data,
                    defaultName: exportFileName(item: item, suffix: "timeline", fileExtension: "json"),
                    contentType: .json,
                    successMessage: "Exported timeline range for \(timeRange(item: item))."
                )
            } else {
                guard item.isSeekable else {
                    timelineActionMessage =
                        "Clip export unavailable: \(timeRange(item: item)) is outside the buffered or archived audio range."
                    return
                }
                let requestedEnd = item.endSeconds ?? item.startSeconds
                let manifest = TimelineExportService.audioManifest(
                    requestedStartSeconds: item.startSeconds,
                    requestedEndSeconds: max(requestedEnd, item.startSeconds + 0.001),
                    retainedRanges: []
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(manifest)
                try saveExportData(
                    data,
                    defaultName: exportFileName(
                        item: item,
                        suffix: "clip-audio-availability",
                        fileExtension: "json"
                    ),
                    contentType: .json,
                    successMessage:
                        "Exported clip audio availability manifest for \(timeRange(item: item))."
                )
            }
        } catch {
            timelineActionMessage =
                "Timeline export failed: \(IngestRedaction.redact(String(describing: error)))"
        }
    }

    private func saveExportData(
        _ data: Data,
        defaultName: String,
        contentType: UTType,
        successMessage: String
    ) throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [contentType]
        guard panel.runModal() == .OK, let url = panel.url else {
            timelineActionMessage = "Timeline export canceled."
            return
        }
        try data.write(to: url, options: .atomic)
        timelineActionMessage = successMessage
    }

    private func exportFileName(
        item: StreamAppTimelineItem,
        suffix: String,
        fileExtension: String
    ) -> String {
        let id = item.id
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "\(suffix)-\(id).\(fileExtension)"
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

#Preview {
    ContentView()
}
