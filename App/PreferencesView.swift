import AppKit
import SoundingKit
import SwiftUI

@MainActor
final class AppPreferencesController: ObservableObject {
    @Published var databasePath: String
    @Published var whisperModelName: String
    @Published var rollingBufferMinutes: Double
    @Published private(set) var acoustIDKeyStatus: SoundingAppAcoustIDKeyStatus
    @Published private(set) var issues: [SoundingAppConfigurationIssue]
    @Published private(set) var actionMessage: String?
    @Published var acoustIDKeyDraft = ""

    private let storage: SoundingAppPreferencesStorage
    private let secretStore: any AppSecretStore

    init(
        storage: SoundingAppPreferencesStorage = SoundingAppPreferencesStorage(),
        secretStore: any AppSecretStore = AppKeychainSecretStore()
    ) {
        self.storage = storage
        self.secretStore = secretStore
        let preferences = storage.load(secretStore: secretStore)
        databasePath = preferences.databaseURL.path
        whisperModelName = preferences.whisperModelName
        rollingBufferMinutes = preferences.rollingBufferTargetSeconds / 60
        acoustIDKeyStatus = preferences.acoustIDKeyStatus
        issues = SoundingAppConfiguration.validated(preferences: preferences).issues
    }

    func currentPreferences() -> SoundingAppPreferences {
        storage.load(secretStore: secretStore)
    }

    func refreshStatus() {
        let preferences = currentPreferences()
        databasePath = preferences.databaseURL.path
        whisperModelName = preferences.whisperModelName
        rollingBufferMinutes = preferences.rollingBufferTargetSeconds / 60
        acoustIDKeyStatus = preferences.acoustIDKeyStatus
        issues = SoundingAppConfiguration.validated(preferences: preferences).issues
    }

    func saveNonSecretPreferences() {
        let databaseURL = URL(fileURLWithPath: databasePath, isDirectory: false)
        storage.saveNonSecretPreferences(
            databaseURL: databaseURL,
            whisperModelName: whisperModelName,
            rollingBufferTargetSeconds: rollingBufferMinutes * 60
        )
        actionMessage = "Preferences saved. Restart the app runtime to apply startup settings."
        refreshStatus()
    }

    func resetNonSecretPreferences() {
        storage.resetNonSecretPreferences()
        actionMessage = "Preferences reset to defaults."
        refreshStatus()
    }

    func chooseDatabaseLocation() {
        let panel = NSSavePanel()
        panel.title = "Choose Sounding Database Location"
        panel.prompt = "Use Location"
        panel.nameFieldStringValue = URL(fileURLWithPath: databasePath).lastPathComponent.isEmpty
            ? SoundingAppPreferences.defaultDatabaseFilename
            : URL(fileURLWithPath: databasePath).lastPathComponent
        panel.canCreateDirectories = true
        if !databasePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        databasePath = url.path
        saveNonSecretPreferences()
    }

    func saveAcoustIDKey() {
        do {
            try secretStore.saveAcoustIDKey(acoustIDKeyDraft)
            acoustIDKeyDraft = ""
            actionMessage = "AcoustID key saved securely. The key is not shown after saving."
        } catch {
            actionMessage = IngestRedaction.redact(String(describing: error))
        }
        refreshStatus()
    }

    func clearAcoustIDKey() {
        do {
            try secretStore.saveAcoustIDKey(nil)
            acoustIDKeyDraft = ""
            actionMessage = "AcoustID key cleared. AcoustID enrichment is disabled."
        } catch {
            actionMessage = IngestRedaction.redact(String(describing: error))
        }
        refreshStatus()
    }
}

struct PreferencesView: View {
    @ObservedObject var controller: AppPreferencesController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                acoustIDSection
                whisperSection
                rollingBufferSection
                databaseSection
                diagnosticsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 640)
        .frame(minHeight: 620)
        .onAppear { controller.refreshStatus() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sounding Preferences")
                .font(.largeTitle.bold())
            Text("Local runtime settings and redacted diagnostics. Secret values are stored in Keychain and never echoed here.")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var acoustIDSection: some View {
        SettingsSection(title: "AcoustID", systemImage: "key.horizontal") {
            HStack(alignment: .center, spacing: 12) {
                statusPill(for: controller.acoustIDKeyStatus)
                Text(acoustIDStatusDetail)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            SecureField("Paste AcoustID API key", text: $controller.acoustIDKeyDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("AcoustID API key")
                .accessibilityHint("The key is saved to Keychain and cleared from this field after saving.")

            HStack {
                Button("Save or Replace Key", systemImage: "key.fill") {
                    controller.saveAcoustIDKey()
                }
                .buttonStyle(.borderedProminent)

                Button("Clear Key", systemImage: "trash") {
                    controller.clearAcoustIDKey()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var whisperSection: some View {
        SettingsSection(title: "Whisper Model", systemImage: "waveform.and.mic") {
            TextField("tiny", text: $controller.whisperModelName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Whisper model name")
                .accessibilityHint("Use letters, numbers, dots, underscores, and hyphens only.")

            Picker("Common models", selection: $controller.whisperModelName) {
                ForEach(["tiny", "tiny.en", "base", "base.en", "small", "small.en"], id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.segmented)

            Button("Save Model", systemImage: "checkmark.circle") {
                controller.saveNonSecretPreferences()
            }
        }
    }

    private var rollingBufferSection: some View {
        SettingsSection(title: "Rolling Buffer", systemImage: "clock.arrow.circlepath") {
            HStack(alignment: .firstTextBaseline) {
                Slider(
                    value: $controller.rollingBufferMinutes,
                    in: SoundingAppConfiguration.minimumRollingBufferSeconds / 60 ... SoundingAppConfiguration.maximumRollingBufferSeconds / 60,
                    step: 0.5
                )
                Text("\(Int(controller.rollingBufferMinutes)) min")
                    .font(.body.monospacedDigit())
                    .frame(width: 72, alignment: .trailing)
            }
            Text("Clamped between 30 seconds and 6 hours before saving to protect runtime memory and spill storage.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Save Buffer", systemImage: "checkmark.circle") {
                controller.saveNonSecretPreferences()
            }
        }
    }

    private var databaseSection: some View {
        SettingsSection(title: "Database Location", systemImage: "externaldrive") {
            TextField("Database path", text: $controller.databasePath)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .accessibilityLabel("Sounding database path")

            HStack {
                Button("Choose Location…", systemImage: "folder") {
                    controller.chooseDatabaseLocation()
                }
                Button("Save Location", systemImage: "checkmark.circle") {
                    controller.saveNonSecretPreferences()
                }
                Button("Reset Defaults", systemImage: "arrow.counterclockwise") {
                    controller.resetNonSecretPreferences()
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        SettingsSection(title: "Diagnostics", systemImage: "stethoscope") {
            if let actionMessage = controller.actionMessage {
                Label(actionMessage, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Settings action: \(actionMessage)")
            }

            if controller.issues.isEmpty {
                Label("No configuration issues detected.", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                ForEach(controller.issues) { issue in
                    IssueRow(issue: issue)
                }
            }

            Button("Refresh Diagnostics", systemImage: "arrow.clockwise") {
                controller.refreshStatus()
            }
        }
    }

    private var acoustIDStatusDetail: String {
        switch controller.acoustIDKeyStatus {
        case .missing:
            return "Missing — metadata lookup is disabled, stream ingest can continue."
        case .present:
            return "Configured — key material remains in Keychain."
        case .unavailable(let message):
            return "Error — \(IngestRedaction.redact(message))"
        }
    }

    @ViewBuilder
    private func statusPill(for status: SoundingAppAcoustIDKeyStatus) -> some View {
        switch status {
        case .missing:
            Pill(text: "Missing", color: .secondary, systemImage: "key.slash")
        case .present:
            Pill(text: "Configured", color: .green, systemImage: "checkmark.circle")
        case .unavailable:
            Pill(text: "Error", color: .orange, systemImage: "exclamationmark.triangle")
        }
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

private struct IssueRow: View {
    var issue: SoundingAppConfigurationIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(issue.message, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            if let detail = issue.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Action: \(issue.action.label)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(issue.severity.rawValue) configuration issue: \(issue.message). \(issue.detail ?? "") Action: \(issue.action.label)")
    }

    private var systemImage: String {
        switch issue.severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .blocking: "exclamationmark.octagon.fill"
        }
    }

    private var color: Color {
        switch issue.severity {
        case .info: .secondary
        case .warning: .orange
        case .blocking: .red
        }
    }
}

private struct Pill: View {
    var text: String
    var color: Color
    var systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}
