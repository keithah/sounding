import SwiftUI
import SoundingKit
import Darwin

@main
struct SoundingApp: App {
    init() {
        SoundingProcessEnvironment.configure()
    }

    private let packageIdentity = SoundingKitVersion.current
    @StateObject private var preferencesController = AppPreferencesController()
    @StateObject private var softwareUpdateController = SoftwareUpdateController()

    var body: some Scene {
        WindowGroup(packageIdentity.name) {
            ContentView(preferences: preferencesController.currentPreferences())
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    softwareUpdateController.checkForUpdates()
                }
                .disabled(!softwareUpdateController.canCheckForUpdates)
            }
        }

        Settings {
            PreferencesView(
                controller: preferencesController,
                softwareUpdateController: softwareUpdateController
            )
        }
    }
}

private enum SoundingProcessEnvironment {
    static func configure() {
        let modelRoot = ModelCache.defaultRootDirectory()
        let huggingFaceRoot = modelRoot
            .deletingLastPathComponent()
            .appendingPathComponent("huggingface", isDirectory: true)
        try? FileManager.default.createDirectory(at: huggingFaceRoot, withIntermediateDirectories: true)
        setenvIfMissing("HF_HOME", huggingFaceRoot.path)
        setenvIfMissing("HF_HUB_CACHE", huggingFaceRoot.path)
        if let acoustIDClientKey = try? AppKeychainSecretStore().acoustIDClientKey(),
           !acoustIDClientKey.isEmpty {
            setenvIfMissing("SOUNDING_ACOUSTID_API_KEY", acoustIDClientKey)
        }
    }

    private static func setenvIfMissing(_ name: String, _ value: String) {
        guard ProcessInfo.processInfo.environment[name]?.isEmpty != false else { return }
        setenv(name, value, 1)
    }
}
