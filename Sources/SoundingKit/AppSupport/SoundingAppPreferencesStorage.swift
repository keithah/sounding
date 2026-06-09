import Foundation

public struct SoundingAppPreferencesStorage {
    public enum Key {
        public static let databasePath = "sounding.preferences.databasePath"
        public static let whisperModelName = "sounding.preferences.whisperModelName"
        public static let rollingBufferTargetSeconds = "sounding.preferences.rollingBufferTargetSeconds"
        public static let audioArchiveDirectory = "sounding.preferences.audioArchiveDirectory"
        public static let audioArchiveMaximumBytes = "sounding.preferences.audioArchiveMaximumBytes"
        public static let audioArchiveDefaultRetentionSeconds =
            "sounding.preferences.audioArchiveDefaultRetentionSeconds"
        public static let isDiarizationEnabled = "sounding.preferences.isDiarizationEnabled"
        public static let isTranscriptAdVerifierEnabled =
            "sounding.preferences.isTranscriptAdVerifierEnabled"
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
        let audioArchiveDirectory = defaults.string(forKey: Key.audioArchiveDirectory)
            .flatMap { path in URL(fileURLWithPath: path, isDirectory: true) }
        let audioArchiveMaximumBytes = defaults.object(forKey: Key.audioArchiveMaximumBytes) == nil
            ? SoundingAppPreferences.defaultAudioArchiveMaximumBytes
            : Int64(defaults.integer(forKey: Key.audioArchiveMaximumBytes))
        let audioArchiveRetentionSeconds =
            defaults.object(forKey: Key.audioArchiveDefaultRetentionSeconds) == nil
            ? SoundingAppPreferences.defaultAudioArchiveRetentionSeconds
            : defaults.double(forKey: Key.audioArchiveDefaultRetentionSeconds)

        if let secretStore {
            return SoundingAppPreferences(
                databaseURL: databaseURL,
                whisperModelName: modelName,
                rollingBufferTargetSeconds: clampedRollingBufferSeconds(rawRollingBufferSeconds),
                audioArchiveDirectory: audioArchiveDirectory,
                audioArchiveMaximumBytes: validAudioArchiveMaximumBytes(audioArchiveMaximumBytes),
                audioArchiveDefaultRetentionSeconds: validAudioArchiveRetentionSeconds(
                    audioArchiveRetentionSeconds),
                isDiarizationEnabled: defaults.bool(forKey: Key.isDiarizationEnabled),
                isTranscriptAdVerifierEnabled: defaults.bool(forKey: Key.isTranscriptAdVerifierEnabled),
                secretStore: secretStore,
                fileManager: fileManager
            )
        }

        return SoundingAppPreferences(
            databaseURL: databaseURL,
            whisperModelName: modelName,
            rollingBufferTargetSeconds: clampedRollingBufferSeconds(rawRollingBufferSeconds),
            audioArchiveDirectory: audioArchiveDirectory,
            audioArchiveMaximumBytes: validAudioArchiveMaximumBytes(audioArchiveMaximumBytes),
            audioArchiveDefaultRetentionSeconds: validAudioArchiveRetentionSeconds(
                audioArchiveRetentionSeconds),
            isDiarizationEnabled: defaults.bool(forKey: Key.isDiarizationEnabled),
            isTranscriptAdVerifierEnabled: defaults.bool(forKey: Key.isTranscriptAdVerifierEnabled),
            fileManager: fileManager
        )
    }

    public func saveNonSecretPreferences(
        databaseURL: URL,
        whisperModelName: String,
        rollingBufferTargetSeconds: Double,
        audioArchiveDirectory: URL? = nil,
        audioArchiveMaximumBytes: Int64 = SoundingAppPreferences.defaultAudioArchiveMaximumBytes,
        audioArchiveDefaultRetentionSeconds: Double =
            SoundingAppPreferences.defaultAudioArchiveRetentionSeconds,
        isDiarizationEnabled: Bool = false,
        isTranscriptAdVerifierEnabled: Bool = false
    ) {
        defaults.set(databaseURL.path, forKey: Key.databasePath)
        defaults.set(whisperModelName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.whisperModelName)
        defaults.set(clampedRollingBufferSeconds(rollingBufferTargetSeconds), forKey: Key.rollingBufferTargetSeconds)
        if let audioArchiveDirectory {
            defaults.set(audioArchiveDirectory.path, forKey: Key.audioArchiveDirectory)
        } else {
            defaults.removeObject(forKey: Key.audioArchiveDirectory)
        }
        defaults.set(validAudioArchiveMaximumBytes(audioArchiveMaximumBytes), forKey: Key.audioArchiveMaximumBytes)
        defaults.set(
            validAudioArchiveRetentionSeconds(audioArchiveDefaultRetentionSeconds),
            forKey: Key.audioArchiveDefaultRetentionSeconds
        )
        defaults.set(isDiarizationEnabled, forKey: Key.isDiarizationEnabled)
        defaults.set(isTranscriptAdVerifierEnabled, forKey: Key.isTranscriptAdVerifierEnabled)
    }

    public func resetNonSecretPreferences() {
        defaults.removeObject(forKey: Key.databasePath)
        defaults.removeObject(forKey: Key.whisperModelName)
        defaults.removeObject(forKey: Key.rollingBufferTargetSeconds)
        defaults.removeObject(forKey: Key.audioArchiveDirectory)
        defaults.removeObject(forKey: Key.audioArchiveMaximumBytes)
        defaults.removeObject(forKey: Key.audioArchiveDefaultRetentionSeconds)
        defaults.removeObject(forKey: Key.isDiarizationEnabled)
        defaults.removeObject(forKey: Key.isTranscriptAdVerifierEnabled)
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

    private func validAudioArchiveMaximumBytes(_ value: Int64) -> Int64 {
        value > 0 ? value : SoundingAppPreferences.defaultAudioArchiveMaximumBytes
    }

    private func validAudioArchiveRetentionSeconds(_ value: Double) -> Double {
        value.isFinite && value > 0
            ? value
            : SoundingAppPreferences.defaultAudioArchiveRetentionSeconds
    }
}
