import SoundingKit
import SwiftUI

struct GlobalPlayerBar: View {
    var selected: StreamAppSelectedStream
    var seekToLive: () -> Void
    var scrubBackward: () -> Void
    var startRuntime: () -> Void
    var restartRuntime: () -> Void
    var pauseRuntime: () -> Void
    var resumeRuntime: () -> Void
    var stopRuntime: () -> Void
    @Binding var volume: Double
    @Binding var isMuted: Bool

    private var nowPlaying: StreamAppMetadataItem? {
        selected.currentMetadata ?? selected.recentMetadata.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.item.name)
                        .font(.headline)
                    Text(selected.playerStateTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start", systemImage: "play.fill", action: startRuntime)
                    .disabled(!selected.canStartRuntime)
                Button("Restart", systemImage: "arrow.clockwise", action: restartRuntime)
                    .disabled(!selected.canStopRuntime)
                Button("Pause", systemImage: "pause.fill", action: pauseRuntime)
                    .disabled(!selected.canPauseRuntime)
                Button("Resume", systemImage: "playpause.fill", action: resumeRuntime)
                    .disabled(!selected.canResumeRuntime)
                Button("Stop", systemImage: "stop.fill", action: stopRuntime)
                    .disabled(!selected.canStopRuntime)
                Button("-30s", systemImage: "gobackward.30", action: scrubBackward)
                    .disabled(!selected.canScrubBufferedRange)
                Button("Live", systemImage: "dot.radiowaves.forward", action: seekToLive)
                    .disabled(!selected.canSeekToLive)
            }
            .disabled(!selected.controlsEnabled)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                if let nowPlaying {
                    Text(nowPlaying.artist ?? "Metadata")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(nowPlaying.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let subtitle = nowPlaying.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text("No current metadata")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Toggle("Mute", isOn: $isMuted)
                    .toggleStyle(.switch)
                Slider(value: $volume, in: 0...1)
                    .disabled(isMuted)
                Text("\(Int((volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Text(selected.bufferedRangeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
