import Foundation

public struct SoundingAppPreferencesStorage {
    public enum Key {
        public static let databasePath = "sounding.preferences.databasePath"
        public static let whisperModelName = "sounding.preferences.whisperModelName"
        public static let rollingBufferTargetSeconds = "sounding.preferences.rollingBufferTargetSeconds"
        public static let isDiarizationEnabled = "sounding.preferences.isDiarizationEnabled"
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager

    public init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    public func load(secretStore: (any AppSecretStore)? = nil) -> SoundingAppPreferences {
        let databaseURL = defaults.string(forKey: Key.databasePath)
            .flatMap { path in URL(fileURLWithPath: path, isDirectory: false) }
        let modelName = defaults.string(forKey: Key.whisperModelName)
            ?? SoundingAppPreferences.defaultWhisperModelName
        let rawRollingBufferSeconds = defaults.object(forKey: Key.rollingBufferTargetSeconds) == nil
            ? RollingBufferConfiguration.appDefault().targetDurationSeconds
            : defaults.double(forKey: Key.rollingBufferTargetSeconds)

        if let secretStore {
            return SoundingAppPreferences(
                databaseURL: databaseURL,
                whisperModelName: modelName,
                rollingBufferTargetSeconds: clampedRollingBufferSeconds(rawRollingBufferSeconds),
                isDiarizationEnabled: defaults.bool(forKey: Key.isDiarizationEnabled),
                secretStore: secretStore,
                fileManager: fileManager
            )
        }

        return SoundingAppPreferences(
            databaseURL: databaseURL,
            whisperModelName: modelName,
            rollingBufferTargetSeconds: clampedRollingBufferSeconds(rawRollingBufferSeconds),
            isDiarizationEnabled: defaults.bool(forKey: Key.isDiarizationEnabled),
            fileManager: fileManager
        )
    }

    public func saveNonSecretPreferences(
        databaseURL: URL,
        whisperModelName: String,
        rollingBufferTargetSeconds: Double,
        isDiarizationEnabled: Bool = false
    ) {
        defaults.set(databaseURL.path, forKey: Key.databasePath)
        defaults.set(whisperModelName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.whisperModelName)
        defaults.set(clampedRollingBufferSeconds(rollingBufferTargetSeconds), forKey: Key.rollingBufferTargetSeconds)
        defaults.set(isDiarizationEnabled, forKey: Key.isDiarizationEnabled)
    }

    public func resetNonSecretPreferences() {
        defaults.removeObject(forKey: Key.databasePath)
        defaults.removeObject(forKey: Key.whisperModelName)
        defaults.removeObject(forKey: Key.rollingBufferTargetSeconds)
        defaults.removeObject(forKey: Key.isDiarizationEnabled)
    }

    public static func clampedRollingBufferSeconds(_ value: Double) -> Double {
        guard value.isFinite else { return RollingBufferConfiguration.appDefault().targetDurationSeconds }
        return min(
            max(value, SoundingAppConfiguration.minimumRollingBufferSeconds),
            SoundingAppConfiguration.maximumRollingBufferSeconds
        )
    }

    private func clampedRollingBufferSeconds(_ value: Double) -> Double {
        Self.clampedRollingBufferSeconds(value)
    }
}
