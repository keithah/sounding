import SoundingKit
import SwiftUI

struct StreamRow: View {
    var item: StreamAppListItem
    var isMuted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name)
                    .font(.headline)
                if isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Muted")
                }
                Spacer()
                StatusPill(status: item.status)
            }
            Text(item.transportLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.sourceDescription)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let detail = item.runtimeStatusDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if item.diarizationEnabled {
                Text("Speaker diarization on")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text("Control-click for stream options")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .opacity(isMuted ? 0.6 : 1.0)
        .accessibilityElement(children: .combine)
    }
}
