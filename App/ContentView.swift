import SwiftUI
import SoundingKit

struct ContentView: View {
    private let version = SoundingKitVersion.current

    var body: some View {
        VStack(spacing: 12) {
            Text(version.name)
                .font(.title)
                .fontWeight(.semibold)

            Text("SoundingKit \(version.string)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 320, minHeight: 180)
    }
}
