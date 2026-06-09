import AppKit
import SwiftUI
import SoundingKit
import Darwin

@main
struct SoundingApp: App {
    init() {
        SoundingProcessEnvironment.configure()
    }

    private let packageIdentity = SoundingKitVersion.current
    @NSApplicationDelegateAdaptor(SoundingAppDelegate.self) private var appDelegate
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

private final class SoundingAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        presentApplicationWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentApplicationWindow()
        return true
    }

    private func presentApplicationWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let visibleWindows = NSApp.windows.filter { !$0.isMiniaturized && $0.isVisible }
        if let mainWindow = visibleWindows.first {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        if let miniaturizedWindow = NSApp.windows.first(where: { $0.isMiniaturized }) {
            miniaturizedWindow.deminiaturize(nil)
            miniaturizedWindow.makeKeyAndOrderFront(nil)
            return
        }

        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
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
