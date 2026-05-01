import SoundingKit
import SwiftUI

struct ContentView: View {
    private let registry: StreamRegistry?
    @State private var viewModel: StreamAppViewModel
    @State private var persistenceError: String?

    init() {
        let initial = Self.makeInitialState()
        registry = initial.registry
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

            TextField(
                "https://example.test/live.m3u8",
                text: Binding(
                    get: { viewModel.addDraft.source },
                    set: { viewModel.addDraft.source = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)

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
            }

            if let persistenceError {
                Text(persistenceError)
                    .font(.caption)
                    .foregroundStyle(.red)
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
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selected = viewModel.selectedStream {
            StreamDetail(selected: selected)
        } else {
            ContentUnavailableView(
                viewModel.emptyStateTitle,
                systemImage: "waveform.badge.magnifyingglass",
                description: Text(
                    "Select or add a supported stream. Runtime, player, and rewind controls are staged but disabled until the next slice tasks wire the in-process SoundingKit runtime."
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
        } catch {
            // The view model stores redacted, user-facing validation errors.
        }
    }

    private static func makeInitialState() -> (
        registry: StreamRegistry?,
        viewModel: StreamAppViewModel,
        persistenceError: String?
    ) {
        do {
            let databaseURL = try defaultDatabaseURL()
            let database = try SoundingDatabase(fileURL: databaseURL)
            let registry = StreamRegistry(database: database)
            var viewModel = StreamAppViewModel()
            try viewModel.reload(from: registry)
            return (registry, viewModel, nil)
        } catch {
            return (
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
    }
}

private struct StreamDetail: View {
    var selected: StreamAppSelectedStream

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
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
            }

            GroupBox("Player") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(selected.playerStateTitle)
                        .font(.headline)
                    Text(selected.playerStateDetail)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("Start", systemImage: "play.fill") {}
                        Button("Stop", systemImage: "stop.fill") {}
                        Button("Live", systemImage: "dot.radiowaves.forward") {}
                    }
                    .disabled(!selected.controlsEnabled)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(selected.bufferedRangeTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: .constant(1.0), in: 0...1)
                            .disabled(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .padding(28)
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

#Preview {
    ContentView()
}
