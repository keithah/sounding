import SoundingKit
import SwiftUI

struct SearchCard: View {
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

    func optionalText(_ keyPath: WritableKeyPath<StreamAppSearchDraft, String?>)
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

struct SearchStatusView: View {
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

struct SearchResultButton: View {
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
