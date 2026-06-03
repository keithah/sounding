import AppKit
import SoundingKit
import SwiftUI

@MainActor
final class AppPreferencesController: ObservableObject {
    @Published var databasePath: String
    @Published var whisperModelName: String
    @Published var rollingBufferMinutes: Double
    @Published var audioArchivePath: String
    @Published var audioArchiveMaximumGB: Double
    @Published var audioArchiveRetentionHours: Double
    @Published var isDiarizationEnabled: Bool
    @Published private(set) var acoustIDKeyStatus: SoundingAppAcoustIDKeyStatus
    @Published private(set) var issues: [SoundingAppConfigurationIssue]
    @Published private(set) var actionMessage: String?
    @Published private(set) var isTestingAcoustIDKey = false
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
        audioArchivePath = preferences.audioArchiveDirectory?.path ?? ""
        audioArchiveMaximumGB = Double(preferences.audioArchiveMaximumBytes) / 1_073_741_824
        audioArchiveRetentionHours = preferences.audioArchiveDefaultRetentionSeconds / 3_600
        isDiarizationEnabled = preferences.isDiarizationEnabled
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
        audioArchivePath = preferences.audioArchiveDirectory?.path ?? ""
        audioArchiveMaximumGB = Double(preferences.audioArchiveMaximumBytes) / 1_073_741_824
        audioArchiveRetentionHours = preferences.audioArchiveDefaultRetentionSeconds / 3_600
        isDiarizationEnabled = preferences.isDiarizationEnabled
        acoustIDKeyStatus = preferences.acoustIDKeyStatus
        issues = SoundingAppConfiguration.validated(preferences: preferences).issues
    }

    func saveNonSecretPreferences() {
        let databaseURL = URL(fileURLWithPath: databasePath, isDirectory: false)
        storage.saveNonSecretPreferences(
            databaseURL: databaseURL,
            whisperModelName: whisperModelName,
            rollingBufferTargetSeconds: rollingBufferMinutes * 60,
            audioArchiveDirectory: archiveDirectory(),
            audioArchiveMaximumBytes: Int64(max(0.01, audioArchiveMaximumGB) * 1_073_741_824),
            audioArchiveDefaultRetentionSeconds: max(0.01, audioArchiveRetentionHours) * 3_600,
            isDiarizationEnabled: isDiarizationEnabled
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

    func chooseAudioArchiveLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio Archive Folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if !audioArchivePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: audioArchivePath, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        audioArchivePath = url.path
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

    func testAcoustIDKey() {
        let key = acoustIDKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            actionMessage = "Enter an AcoustID application key before testing."
            return
        }

        isTestingAcoustIDKey = true
        actionMessage = "Testing AcoustID key…"
        Task {
            do {
                let message = try await AcoustIDApplicationKeyTester().test(apiKey: key)
                actionMessage = message
            } catch {
                let redacted = IngestRedaction.redact(String(describing: error))
                    .replacingOccurrences(of: key, with: "[redacted-key]")
                actionMessage = redacted
            }
            isTestingAcoustIDKey = false
        }
    }

    func clearAcoustIDKey() {
        do {
            try secretStore.saveAcoustIDKey(nil)
            acoustIDKeyDraft = ""
            actionMessage = "AcoustID key cleared. Timed stream metadata is unaffected."
        } catch {
            actionMessage = IngestRedaction.redact(String(describing: error))
        }
        refreshStatus()
    }

    private func archiveDirectory() -> URL? {
        let trimmed = audioArchivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }
}

struct PreferencesView: View {
    @ObservedObject var controller: AppPreferencesController
    @ObservedObject var softwareUpdateController: SoftwareUpdateController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                softwareUpdateSection
                acoustIDEnrichmentSection
                whisperSection
                rollingBufferSection
                audioArchiveSection
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

    private var softwareUpdateSection: some View {
        SettingsSection(title: "Software Updates", systemImage: "arrow.down.app") {
            HStack(alignment: .center, spacing: 12) {
                if softwareUpdateController.canCheckForUpdates {
                    Pill(text: "Enabled", color: .green, systemImage: "checkmark.circle")
                } else {
                    Pill(text: "Setup needed", color: .orange, systemImage: "exclamationmark.triangle")
                }
                Text(softwareUpdateController.statusMessage)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text("Sparkle checks the signed appcast configured by SUFeedURL. Keep Sparkle private keys out of the repository.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Check for Updates…", systemImage: "arrow.clockwise") {
                softwareUpdateController.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .disabled(!softwareUpdateController.canCheckForUpdates)
        }
    }

    private var acoustIDEnrichmentSection: some View {
        SettingsSection(title: "AcoustID Enrichment", systemImage: "key.horizontal") {
            HStack(alignment: .center, spacing: 12) {
                statusPill(for: controller.acoustIDKeyStatus)
                Text(acoustIDStatusDetail)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text("Used only as an AcoustID application-key override. HLS timed ID3 metadata and transcript ingest continue without this key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Public builds can include a bundled application key. A saved Keychain key overrides the bundled key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("Paste AcoustID API key", text: $controller.acoustIDKeyDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("AcoustID API key")
                .accessibilityHint("The key is saved to Keychain and cleared from this field after saving.")

            HStack {
                Button("Save or Replace Key", systemImage: "key.fill") {
                    controller.saveAcoustIDKey()
                }
                .buttonStyle(.borderedProminent)

                Button("Test Key", systemImage: "checkmark.shield") {
                    controller.testAcoustIDKey()
                }
                .buttonStyle(.bordered)
                .disabled(
                    controller.isTestingAcoustIDKey
                        || controller.acoustIDKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

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

    private var audioArchiveSection: some View {
        SettingsSection(title: "Audio Archive", systemImage: "externaldrive") {
            Text("Per-stream replay/export archive settings. Streams must opt in from their stream options.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Audio archive folder", text: $controller.audioArchivePath)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .accessibilityLabel("Audio archive folder")

            HStack {
                TextField(
                    "Maximum archive GB",
                    value: $controller.audioArchiveMaximumGB,
                    format: .number.precision(.fractionLength(1))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .accessibilityLabel("Maximum archive gigabytes")

                TextField(
                    "Default retention hours",
                    value: $controller.audioArchiveRetentionHours,
                    format: .number.precision(.fractionLength(1))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
                .accessibilityLabel("Default archive retention hours")
            }

            HStack {
                Button("Choose Folder…", systemImage: "folder") {
                    controller.chooseAudioArchiveLocation()
                }
                Button("Save Archive Settings", systemImage: "checkmark.circle") {
                    controller.saveNonSecretPreferences()
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
            return "Missing — timed metadata still works; fingerprint lookup has no key override."
        case .present:
            return "Configured — key material remains in Keychain for fingerprint lookup override."
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

private struct AcoustIDApplicationKeyTester {
    private let validationTrackID = "9ff43b6a-4f16-427c-93c2-92307ca505e0"

    func test(apiKey: String) async throws -> String {
        var components = URLComponents(string: "https://api.acoustid.org/v2/lookup")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "trackid", value: validationTrackID),
            URLQueryItem(name: "meta", value: "recordingids")
        ]

        guard let url = components?.url else {
            throw AcoustIDApplicationKeyTesterError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AcoustIDApplicationKeyTesterError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(AcoustIDApplicationKeyTestResponse.self, from: data)
        if decoded.status == "ok" {
            return "AcoustID application key test passed. Save the key to store it as the app override."
        }

        if let message = decoded.error?.message, !message.isEmpty {
            throw AcoustIDApplicationKeyTesterError.service(message)
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AcoustIDApplicationKeyTesterError.httpStatus(httpResponse.statusCode)
        }

        throw AcoustIDApplicationKeyTesterError.service("AcoustID rejected the application key.")
    }
}

private struct AcoustIDApplicationKeyTestResponse: Decodable {
    var status: String
    var error: AcoustIDApplicationKeyTestError?
}

private struct AcoustIDApplicationKeyTestError: Decodable {
    var message: String?
}

private enum AcoustIDApplicationKeyTesterError: Error, CustomStringConvertible {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case service(String)

    var description: String {
        switch self {
        case .invalidRequest:
            return "AcoustID key test failed: could not build the validation request."
        case .invalidResponse:
            return "AcoustID key test failed: the service returned an invalid response."
        case .httpStatus(let status):
            return "AcoustID key test failed: the service returned HTTP \(status)."
        case .service(let message):
            return "AcoustID key test failed: \(IngestRedaction.redact(message))"
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
