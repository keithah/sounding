import Foundation

public protocol AppSecretStore: Sendable {
    func acoustIDKeyStatus() throws -> SoundingAppAcoustIDKeyStatus
    func saveAcoustIDKey(_ key: String?) throws
}

public enum SoundingAppAcoustIDKeyStatus: Equatable, Sendable {
    case missing
    case present
    case unavailable(message: String)

    public var isPresent: Bool {
        if case .present = self { return true }
        return false
    }

    public var redactedMessage: String? {
        switch self {
        case .missing, .present:
            return nil
        case .unavailable(let message):
            return IngestRedaction.redact(message)
        }
    }
}

public enum SoundingAppIssueSeverity: String, Equatable, Sendable {
    case info
    case warning
    case blocking

    public var blocksRuntime: Bool { self == .blocking }
}

public enum SoundingAppIssuePhase: String, Equatable, Sendable {
    case preferences
    case startup
    case runtime
}

public enum SoundingAppIssueCategory: String, Equatable, Sendable {
    case database
    case model
    case rollingBuffer
    case acoustID
    case secretStore
}

public enum SoundingAppIssueActionKind: String, Equatable, Sendable {
    case chooseDatabaseLocation
    case chooseWhisperModel
    case adjustRollingBuffer
    case addAcoustIDKey
    case retrySecretStore
    case openSettings
}

public struct SoundingAppConfigurationAction: Equatable, Sendable {
    public var kind: SoundingAppIssueActionKind
    public var label: String

    public init(kind: SoundingAppIssueActionKind, label: String) {
        self.kind = kind
        self.label = IngestRedaction.redact(label)
    }
}

public struct SoundingAppConfigurationIssue: Equatable, Identifiable, Sendable {
    public var id: String
    public var severity: SoundingAppIssueSeverity
    public var phase: SoundingAppIssuePhase
    public var category: SoundingAppIssueCategory
    public var message: String
    public var detail: String?
    public var action: SoundingAppConfigurationAction

    public init(
        id: String,
        severity: SoundingAppIssueSeverity,
        phase: SoundingAppIssuePhase,
        category: SoundingAppIssueCategory,
        message: String,
        detail: String? = nil,
        action: SoundingAppConfigurationAction
    ) {
        self.id = id
        self.severity = severity
        self.phase = phase
        self.category = category
        self.message = IngestRedaction.redact(message)
        self.detail = detail.map(IngestRedaction.redact)
        self.action = action
    }

    public var blocksRuntime: Bool { severity.blocksRuntime }
}

public struct SoundingAppPreferences: Equatable, Sendable {
    public static let defaultWhisperModelName = "tiny"
    public static let defaultDatabaseFilename = "Sounding.sqlite"

    public var databaseURL: URL
    public var whisperModelName: String
    public var rollingBufferTargetSeconds: Double
    public var isDiarizationEnabled: Bool
    public var acoustIDKeyStatus: SoundingAppAcoustIDKeyStatus

    public init(
        databaseURL: URL? = nil,
        whisperModelName: String = Self.defaultWhisperModelName,
        rollingBufferTargetSeconds: Double = RollingBufferConfiguration.appDefault().targetDurationSeconds,
        isDiarizationEnabled: Bool = false,
        acoustIDKeyStatus: SoundingAppAcoustIDKeyStatus = .missing,
        fileManager: FileManager = .default
    ) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL(fileManager: fileManager)
        self.whisperModelName = whisperModelName
        self.rollingBufferTargetSeconds = rollingBufferTargetSeconds
        self.isDiarizationEnabled = isDiarizationEnabled
        self.acoustIDKeyStatus = acoustIDKeyStatus
    }

    public init(
        databaseURL: URL? = nil,
        whisperModelName: String = Self.defaultWhisperModelName,
        rollingBufferTargetSeconds: Double = RollingBufferConfiguration.appDefault().targetDurationSeconds,
        isDiarizationEnabled: Bool = false,
        secretStore: any AppSecretStore,
        fileManager: FileManager = .default
    ) {
        let status: SoundingAppAcoustIDKeyStatus
        do {
            status = try secretStore.acoustIDKeyStatus()
        } catch {
            status = .unavailable(message: String(describing: error))
        }
        self.init(
            databaseURL: databaseURL,
            whisperModelName: whisperModelName,
            rollingBufferTargetSeconds: rollingBufferTargetSeconds,
            isDiarizationEnabled: isDiarizationEnabled,
            acoustIDKeyStatus: status,
            fileManager: fileManager
        )
    }

    public static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Sounding", isDirectory: true)
            .appendingPathComponent(defaultDatabaseFilename, isDirectory: false)
    }
}

public struct SoundingAppConfiguration: Equatable, Sendable {
    public static let minimumRollingBufferSeconds: Double = 30
    public static let maximumRollingBufferSeconds: Double = 6 * 60 * 60

    public var databaseURL: URL
    public var whisperModelName: String
    public var rollingBuffer: RollingBufferConfiguration
    public var isDiarizationEnabled: Bool
    public var acoustIDKeyStatus: SoundingAppAcoustIDKeyStatus
    public var issues: [SoundingAppConfigurationIssue]

    public var hasBlockingIssues: Bool {
        issues.contains { $0.blocksRuntime }
    }

    public init(
        databaseURL: URL,
        whisperModelName: String,
        rollingBuffer: RollingBufferConfiguration,
        isDiarizationEnabled: Bool = false,
        acoustIDKeyStatus: SoundingAppAcoustIDKeyStatus,
        issues: [SoundingAppConfigurationIssue] = []
    ) {
        self.databaseURL = databaseURL
        self.whisperModelName = whisperModelName
        self.rollingBuffer = rollingBuffer
        self.isDiarizationEnabled = isDiarizationEnabled
        self.acoustIDKeyStatus = acoustIDKeyStatus
        self.issues = issues
    }

    public static func validated(
        preferences: SoundingAppPreferences = SoundingAppPreferences(),
        fileManager: FileManager = .default
    ) -> SoundingAppConfiguration {
        var issues: [SoundingAppConfigurationIssue] = []

        let modelName = validateModelName(preferences.whisperModelName, issues: &issues)
        let rollingBuffer = rollingBufferConfiguration(
            targetSeconds: preferences.rollingBufferTargetSeconds,
            issues: &issues
        )
        validateDatabaseURL(preferences.databaseURL, fileManager: fileManager, issues: &issues)
        issues.append(contentsOf: acoustIDIssues(for: preferences.acoustIDKeyStatus))

        return SoundingAppConfiguration(
            databaseURL: preferences.databaseURL,
            whisperModelName: modelName,
            rollingBuffer: rollingBuffer,
            isDiarizationEnabled: preferences.isDiarizationEnabled,
            acoustIDKeyStatus: preferences.acoustIDKeyStatus,
            issues: issues
        )
    }

    private static func validateModelName(
        _ rawModelName: String,
        issues: inout [SoundingAppConfigurationIssue]
    ) -> String {
        do {
            return try ModelCache.safeComponent(rawModelName)
        } catch {
            issues.append(
                SoundingAppConfigurationIssue(
                    id: "model.invalid-name",
                    severity: .blocking,
                    phase: .startup,
                    category: .model,
                    message: "Choose a valid Whisper model before starting transcription.",
                    detail: "Model names may contain letters, numbers, dots, underscores, and hyphens only.",
                    action: SoundingAppConfigurationAction(
                        kind: .chooseWhisperModel,
                        label: "Choose Whisper model"
                    )
                )
            )
            return SoundingAppPreferences.defaultWhisperModelName
        }
    }

    private static func rollingBufferConfiguration(
        targetSeconds: Double,
        issues: inout [SoundingAppConfigurationIssue]
    ) -> RollingBufferConfiguration {
        let fallback = RollingBufferConfiguration.appDefault().targetDurationSeconds
        let target: Double
        if !targetSeconds.isFinite || targetSeconds < minimumRollingBufferSeconds {
            issues.append(
                SoundingAppConfigurationIssue(
                    id: "rolling-buffer.too-small",
                    severity: .blocking,
                    phase: .preferences,
                    category: .rollingBuffer,
                    message: "Rolling buffer duration is too small.",
                    detail: "Choose at least \(Int(minimumRollingBufferSeconds)) seconds so rewind storage stays useful and safe.",
                    action: SoundingAppConfigurationAction(
                        kind: .adjustRollingBuffer,
                        label: "Adjust rolling buffer"
                    )
                )
            )
            target = fallback
        } else if targetSeconds > maximumRollingBufferSeconds {
            issues.append(
                SoundingAppConfigurationIssue(
                    id: "rolling-buffer.too-large",
                    severity: .warning,
                    phase: .preferences,
                    category: .rollingBuffer,
                    message: "Rolling buffer duration was capped to prevent unbounded storage.",
                    detail: "Sounding caps the app rolling buffer at \(Int(maximumRollingBufferSeconds / 3600)) hours.",
                    action: SoundingAppConfigurationAction(
                        kind: .adjustRollingBuffer,
                        label: "Lower rolling buffer"
                    )
                )
            )
            target = maximumRollingBufferSeconds
        } else {
            target = targetSeconds
        }

        let defaultConfiguration = RollingBufferConfiguration.appDefault()
        return RollingBufferConfiguration(
            targetDurationSeconds: target,
            hotMemoryDurationSeconds: min(defaultConfiguration.hotMemoryDurationSeconds, target),
            maximumSpillBytes: defaultConfiguration.maximumSpillBytes,
            spillSegmentDurationSeconds: defaultConfiguration.spillSegmentDurationSeconds,
            spillDirectory: defaultConfiguration.spillDirectory
        )
    }

    private static func validateDatabaseURL(
        _ url: URL,
        fileManager: FileManager,
        issues: inout [SoundingAppConfigurationIssue]
    ) {
        guard url.isFileURL else {
            issues.append(databaseIssue(detail: "Database location must be a local file URL."))
            return
        }

        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            issues.append(databaseIssue(detail: "Database folder is unavailable: \(parent.path)."))
            return
        }
        guard fileManager.isWritableFile(atPath: parent.path) else {
            issues.append(databaseIssue(detail: "Database folder is not writable: \(parent.path)."))
            return
        }
        var databaseIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &databaseIsDirectory), databaseIsDirectory.boolValue {
            issues.append(databaseIssue(detail: "Database location points at a folder: \(url.path)."))
        }
    }

    private static func databaseIssue(detail: String) -> SoundingAppConfigurationIssue {
        SoundingAppConfigurationIssue(
            id: "database.location-unavailable",
            severity: .blocking,
            phase: .startup,
            category: .database,
            message: "Choose a writable Sounding database location before starting the app runtime.",
            detail: detail,
            action: SoundingAppConfigurationAction(
                kind: .chooseDatabaseLocation,
                label: "Choose database location"
            )
        )
    }

    private static func acoustIDIssues(
        for status: SoundingAppAcoustIDKeyStatus
    ) -> [SoundingAppConfigurationIssue] {
        switch status {
        case .present:
            return []
        case .missing:
            return [
                SoundingAppConfigurationIssue(
                    id: "acoustid.key-missing",
                    severity: .warning,
                    phase: .preferences,
                    category: .acoustID,
                    message: "AcoustID enrichment is disabled until an API key is added.",
                    detail: "Stream ingest can continue; only AcoustID song metadata lookup is skipped.",
                    action: SoundingAppConfigurationAction(
                        kind: .addAcoustIDKey,
                        label: "Add AcoustID key"
                    )
                )
            ]
        case .unavailable(let message):
            return [
                SoundingAppConfigurationIssue(
                    id: "acoustid.secret-store-unavailable",
                    severity: .warning,
                    phase: .preferences,
                    category: .secretStore,
                    message: "AcoustID key status could not be read.",
                    detail: message,
                    action: SoundingAppConfigurationAction(
                        kind: .retrySecretStore,
                        label: "Retry secure storage"
                    )
                )
            ]
        }
    }
}
