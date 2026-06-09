import Foundation
import XCTest

@testable import SoundingKit

final class SoundingAppPreferencesStorageTests: XCTestCase {
    func testSavedNonSecretDefaultsFeedRuntimePreferencesWithoutKeyMaterial() throws {
        let defaults = try makeIsolatedDefaults()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Configured.sqlite", isDirectory: false)
        let archiveDirectory = directory.appendingPathComponent("Archive", isDirectory: true)
        let storage = SoundingAppPreferencesStorage(defaults: defaults)

        storage.saveNonSecretPreferences(
            databaseURL: databaseURL,
            whisperModelName: " base.en ",
            rollingBufferTargetSeconds: 120,
            audioArchiveDirectory: archiveDirectory,
            audioArchiveMaximumBytes: 123_456,
            audioArchiveDefaultRetentionSeconds: 3_600,
            isDiarizationEnabled: true,
            isTranscriptAdVerifierEnabled: true
        )
        let preferences = storage.load(secretStore: StatusSecretStore(status: .present))

        XCTAssertEqual(preferences.databaseURL, databaseURL)
        XCTAssertEqual(preferences.whisperModelName, "base.en")
        XCTAssertEqual(preferences.rollingBufferTargetSeconds, 120)
        XCTAssertEqual(preferences.audioArchiveDirectory, archiveDirectory)
        XCTAssertEqual(preferences.audioArchiveMaximumBytes, 123_456)
        XCTAssertEqual(preferences.audioArchiveDefaultRetentionSeconds, 3_600)
        XCTAssertEqual(preferences.isDiarizationEnabled, true)
        XCTAssertEqual(preferences.isTranscriptAdVerifierEnabled, true)
        XCTAssertEqual(preferences.acoustIDKeyStatus, .present)
        XCTAssertFalse(String(describing: preferences).contains("acoustid-secret"))
    }

    func testRollingBufferIsClampedBeforePersistingZeroOversizedAndNonFiniteValues() throws {
        let defaults = try makeIsolatedDefaults()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SoundingAppPreferencesStorage(defaults: defaults)
        let databaseURL = directory.appendingPathComponent("Sounding.sqlite", isDirectory: false)

        storage.saveNonSecretPreferences(databaseURL: databaseURL, whisperModelName: "tiny", rollingBufferTargetSeconds: 0)
        XCTAssertEqual(storage.load().rollingBufferTargetSeconds, SoundingAppConfiguration.minimumRollingBufferSeconds)

        storage.saveNonSecretPreferences(
            databaseURL: databaseURL,
            whisperModelName: "tiny",
            rollingBufferTargetSeconds: SoundingAppConfiguration.maximumRollingBufferSeconds * 10
        )
        XCTAssertEqual(storage.load().rollingBufferTargetSeconds, SoundingAppConfiguration.maximumRollingBufferSeconds)

        storage.saveNonSecretPreferences(databaseURL: databaseURL, whisperModelName: "tiny", rollingBufferTargetSeconds: .infinity)
        XCTAssertEqual(storage.load().rollingBufferTargetSeconds, RollingBufferConfiguration.appDefault().targetDurationSeconds)
    }

    func testInvalidModelAndDatabasePersistButProjectAsRedactedConfigurationIssues() throws {
        let defaults = try makeIsolatedDefaults()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingDatabase = directory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("Sounding.sqlite", isDirectory: false)
        let rawModel = "/Users/example/private-model?api_key=secret"
        let storage = SoundingAppPreferencesStorage(defaults: defaults)

        storage.saveNonSecretPreferences(
            databaseURL: missingDatabase,
            whisperModelName: rawModel,
            rollingBufferTargetSeconds: 90
        )
        let configuration = SoundingAppConfiguration.validated(
            preferences: storage.load(secretStore: StatusSecretStore(status: .present))
        )

        XCTAssertTrue(configuration.hasBlockingIssues)
        XCTAssertTrue(configuration.issues.contains { $0.category == .model })
        XCTAssertFalse(configuration.issues.contains { $0.category == .database })
        XCTAssertFalse(String(describing: configuration.issues).contains(rawModel))
        XCTAssertFalse(String(describing: configuration.issues).contains(directory.path))
        XCTAssertFalse(String(describing: configuration.issues).contains("api_key=secret"))
    }

    func testSecretStoreFailureMessageIsRedactedWhenLoadingStatus() throws {
        let defaults = try makeIsolatedDefaults()
        let storage = SoundingAppPreferencesStorage(defaults: defaults)
        let rawSecret = "acoustid-api-key-should-not-render"

        let preferences = storage.load(
            secretStore: StatusSecretStore(
                error: SecretStoreTestError(
                    message: "Security failed for key=\(rawSecret)"
                )
            )
        )
        let configuration = SoundingAppConfiguration.validated(preferences: preferences)
        let issue = try XCTUnwrap(configuration.issues.first { $0.category == .secretStore })

        XCTAssertEqual(preferences.acoustIDKeyStatus.isPresent, false)
        XCTAssertFalse(issue.detail?.contains(rawSecret) ?? true, issue.detail ?? "")
        XCTAssertEqual(issue.action.kind, .retrySecretStore)
        XCTAssertFalse(configuration.hasBlockingIssues)
    }

    func testResetReturnsDefaultsAndMissingKeyStatus() throws {
        let defaults = try makeIsolatedDefaults()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SoundingAppPreferencesStorage(defaults: defaults)

        storage.saveNonSecretPreferences(
            databaseURL: directory.appendingPathComponent("Custom.sqlite"),
            whisperModelName: "small",
            rollingBufferTargetSeconds: 300
        )
        storage.resetNonSecretPreferences()
        let preferences = storage.load(secretStore: StatusSecretStore(status: .missing))

        XCTAssertEqual(preferences.whisperModelName, SoundingAppPreferences.defaultWhisperModelName)
        XCTAssertEqual(preferences.rollingBufferTargetSeconds, RollingBufferConfiguration.appDefault().targetDurationSeconds)
        XCTAssertFalse(preferences.isDiarizationEnabled)
        XCTAssertFalse(preferences.isTranscriptAdVerifierEnabled)
        XCTAssertEqual(preferences.acoustIDKeyStatus, .missing)
        XCTAssertEqual(preferences.databaseURL.lastPathComponent, SoundingAppPreferences.defaultDatabaseFilename)
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "SoundingAppPreferencesStorageTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SoundingAppPreferencesStorageTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct SecretStoreTestError: Error, CustomStringConvertible, Sendable {
    var message: String
    var description: String { message }
}

private final class StatusSecretStore: AppSecretStore, @unchecked Sendable {
    private let status: SoundingAppAcoustIDKeyStatus
    private let error: (any Error)?

    init(status: SoundingAppAcoustIDKeyStatus = .missing, error: (any Error)? = nil) {
        self.status = status
        self.error = error
    }

    func acoustIDKeyStatus() throws -> SoundingAppAcoustIDKeyStatus {
        if let error { throw error }
        return status
    }

    func saveAcoustIDKey(_ key: String?) throws {}
}
