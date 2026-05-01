import SwiftUI
import SoundingKit

@main
struct SoundingApp: App {
    private let packageIdentity = SoundingKitVersion.current
    @StateObject private var preferencesController = AppPreferencesController()

    var body: some Scene {
        WindowGroup(packageIdentity.name) {
            ContentView(preferences: preferencesController.currentPreferences())
        }

        Settings {
            PreferencesView(controller: preferencesController)
        }
    }
}
