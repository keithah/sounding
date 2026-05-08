import Foundation
import XCTest

@testable import SoundingKit

final class SoundingAppPreferencesTests: XCTestCase {
    func testDefaultsMatchAppStartupContractWithoutKeyMaterial() {
        let preferences = SoundingAppPreferences()

        XCTAssertEqual(preferences.whisperModelName, "tiny")
        XCTAssertEqual(
            preferences.rollingBufferTargetSeconds,
            RollingBufferConfiguration.appDefault().targetDurationSeconds
        )
        XCTAssertEqual(preferences.acoustIDKeyStatus, .missing)
        XCTAssertFalse(preferences.isDiarizationEnabled)
        XCTAssertEqual(preferences.databaseURL.lastPathComponent, "Sounding.sqlite")
        XCTAssertEqual(preferences.databaseURL.deletingLastPathComponent().lastPathComponent, "Sounding")
        XCTAssertFalse(String(describing: preferences).contains("api_key"))
        XCTAssertFalse(String(describing: preferences).contains("secret"))
    }

    func testValidConfigurationKeepsModelDatabaseAndBufferAndReportsMissingAcoustIDAsNonBlocking() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Sounding.sqlite", isDirectory: false)
        let preferences = SoundingAppPreferences(
            databaseURL: databaseURL,
            whisperModelName: "tiny.en",
            rollingBufferTargetSeconds: 120,
            acoustIDKeyStatus: .missing
        )

        let configuration = SoundingAppConfiguration.validated(preferences: preferences)

        XCTAssertEqual(configuration.databaseURL, databaseURL)
        XCTAssertEqual(configuration.whisperModelName, "tiny.en")
        XCTAssertEqual(configuration.rollingBuffer.targetDurationSeconds, 120)
        XCTAssertFalse(configuration.isDiarizationEnabled)
        XCTAssertFalse(configuration.hasBlockingIssues)
        XCTAssertEqual(configuration.issues.map(\.id), ["acoustid.key-missing"])
        XCTAssertEqual(configuration.issues.first?.severity, .warning)
        XCTAssertEqual(configuration.issues.first?.action.kind, .addAcoustIDKey)
    }

    func testPresentAcoustIDStatusIsStatusOnlyAndProducesNoIssue() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingSecretStore(status: .present)
        let preferences = SoundingAppPreferences(
            databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
            secretStore: store
        )

        let configuration = SoundingAppConfiguration.validated(preferences: preferences)

        XCTAssertEqual(preferences.acoustIDKeyStatus, .present)
        XCTAssertEqual(configuration.acoustIDKeyStatus, .present)
        XCTAssertFalse(configuration.issues.contains { $0.category == .acoustID })
        XCTAssertFalse(String(describing: preferences).contains(store.rawKeyThatMustNeverSurface))
        XCTAssertFalse(String(describing: configuration).contains(store.rawKeyThatMustNeverSurface))
    }

    func testSecretStoreReadFailureBecomesRedactedActionableNonBlockingIssue() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawSecret = "acoustid-api-key-should-not-render"
        let store = RecordingSecretStore(
            thrownError: SecretStoreTestError(
                message: "key=\(rawSecret) failed for https://user:pass@example.test/keychain?token=secret#frag"
            )
        )
        let preferences = SoundingAppPreferences(
            databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
            secretStore: store
        )

        let configuration = SoundingAppConfiguration.validated(preferences: preferences)
        let issue = try XCTUnwrap(configuration.issues.first { $0.category == .secretStore })

        XCTAssertEqual(issue.severity, .warning)
        XCTAssertFalse(issue.blocksRuntime)
        XCTAssertEqual(issue.action.kind, .retrySecretStore)
        XCTAssertFalse(issue.detail?.contains(rawSecret) ?? true, issue.detail ?? "")
        XCTAssertFalse(issue.detail?.contains("user:pass") ?? true, issue.detail ?? "")
        XCTAssertFalse(issue.detail?.contains("token=secret") ?? true, issue.detail ?? "")
        XCTAssertFalse(configuration.hasBlockingIssues)
    }

    func testInvalidModelNameIsRejectedBeforeModelSetupWithoutLeakingRawText() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawModelName = "/Users/example/private-model?api_key=secret"
        let preferences = SoundingAppPreferences(
            databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
            whisperModelName: rawModelName,
            acoustIDKeyStatus: .present
        )

        let configuration = SoundingAppConfiguration.validated(preferences: preferences)
        let issue = try XCTUnwrap(configuration.issues.first { $0.category == .model })

        XCTAssertEqual(issue.severity, .blocking)
        XCTAssertEqual(issue.phase, .startup)
        XCTAssertEqual(issue.action.kind, .chooseWhisperModel)
        XCTAssertEqual(configuration.whisperModelName, "tiny")
        XCTAssertTrue(configuration.hasBlockingIssues)
        XCTAssertFalse(String(describing: issue).contains(rawModelName))
        XCTAssertFalse(String(describing: issue).contains("api_key=secret"))
        XCTAssertFalse(String(describing: issue).contains("/Users/example"))
    }

    func testDatabaseValidationCreatesMissingParentFolderForSavedAppLocation() throws {
        let directory = try makeTemporaryDirectory()
        let missingParent = directory.appendingPathComponent("missing", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = missingParent.appendingPathComponent("Sounding.sqlite", isDirectory: false)
        let preferences = SoundingAppPreferences(
            databaseURL: databaseURL,
            acoustIDKeyStatus: .present
        )

        let configuration = SoundingAppConfiguration.validated(preferences: preferences)

        XCTAssertFalse(configuration.hasBlockingIssues)
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingParent.path))
        XCTAssertFalse(configuration.issues.contains { $0.category == .database })
    }

    func testDirectoryDatabasePathIsBlockingAndRedacted() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = SoundingAppPreferences(
            databaseURL: directory,
            acoustIDKeyStatus: .present
        )

        let configuration = SoundingAppConfiguration.validated(preferences: preferences)
        let issue = try XCTUnwrap(configuration.issues.first { $0.category == .database })

        XCTAssertEqual(issue.severity, .blocking)
        XCTAssertFalse(issue.detail?.contains(directory.path) ?? true, issue.detail ?? "")
    }

    func testRollingBufferRejectsZeroNegativeAndNonFiniteValuesWithSafeDefault() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for rawValue in [0, -1, Double.infinity, Double.nan] {
            let preferences = SoundingAppPreferences(
                databaseURL: directory.appendingPathComponent(UUID().uuidString),
                rollingBufferTargetSeconds: rawValue,
                acoustIDKeyStatus: .present
            )

            let configuration = SoundingAppConfiguration.validated(preferences: preferences)
            let issue = try XCTUnwrap(configuration.issues.first { $0.category == .rollingBuffer })

            XCTAssertEqual(issue.id, "rolling-buffer.too-small")
            XCTAssertEqual(issue.severity, .blocking)
            XCTAssertEqual(issue.action.kind, .adjustRollingBuffer)
            XCTAssertEqual(
                configuration.rollingBuffer.targetDurationSeconds,
                RollingBufferConfiguration.appDefault().targetDurationSeconds
            )
        }
    }

    func testHugeRollingBufferPreferenceIsCappedWithActionableWarning() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = SoundingAppPreferences(
            databaseURL: directory.appendingPathComponent("Sounding.sqlite"),
            rollingBufferTargetSeconds: SoundingAppConfiguration.maximumRollingBufferSeconds * 10,
            acoustIDKeyStatus: .present
        )

        let configuration = SoundingAppConfiguration.validated(preferences: preferences)
        let issue = try XCTUnwrap(configuration.issues.first { $0.category == .rollingBuffer })

        XCTAssertEqual(issue.id, "rolling-buffer.too-large")
        XCTAssertEqual(issue.severity, .warning)
        XCTAssertEqual(issue.action.kind, .adjustRollingBuffer)
        XCTAssertEqual(
            configuration.rollingBuffer.targetDurationSeconds,
            SoundingAppConfiguration.maximumRollingBufferSeconds
        )
        XCTAssertFalse(configuration.hasBlockingIssues)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SoundingAppPreferencesTests-\(UUID().uuidString)",
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

private final class RecordingSecretStore: AppSecretStore, @unchecked Sendable {
    let rawKeyThatMustNeverSurface = "raw-acoustid-key-never-render"
    private let status: SoundingAppAcoustIDKeyStatus
    private let thrownError: (any Error)?

    init(status: SoundingAppAcoustIDKeyStatus = .missing, thrownError: (any Error)? = nil) {
        self.status = status
        self.thrownError = thrownError
    }

    func acoustIDKeyStatus() throws -> SoundingAppAcoustIDKeyStatus {
        if let thrownError { throw thrownError }
        return status
    }

    func saveAcoustIDKey(_ key: String?) throws {}
}
