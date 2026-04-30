import SwiftUI
import SoundingKit

@main
struct SoundingApp: App {
    private let packageIdentity = SoundingKitVersion.current

    var body: some Scene {
        WindowGroup(packageIdentity.name) {
            ContentView()
        }
    }
}
