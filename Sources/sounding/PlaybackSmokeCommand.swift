import ArgumentParser
import Foundation
import SoundingKit

struct PlaybackSmokeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playback-smoke",
        abstract: "Decode a stream and play it through the same SoundingKit AVFoundation playback adapter used by the app."
    )

    @Argument(help: "Media source URL or local media path to decode and play.")
    var source: String

    @Option(name: .long, help: "Stream type hint: auto, hls, icecast, icy, mpegts, or udp.")
    var streamType: StreamTypeArgument = .auto

    @Option(name: .long, help: "How long to leave playback running after scheduling decoded audio.")
    var seconds: Double = 6

    @Flag(name: .long, help: "Toggle mute on and off during playback to prove volume control reaches the adapter.")
    var testMute = false

    mutating func validate() throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("provide a non-empty source URL or path")
        }
        guard seconds.isFinite && seconds > 0 else {
            throw ValidationError("--seconds must be greater than zero")
        }
    }

    mutating func run() async throws {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = resolvedStreamType(for: normalizedSource)
        let playbackSeconds = min(max(seconds, 1), 30)
        let volumeStore = AppPlaybackVolumeStore()
        let adapter = AVFoundationAppPCMPlayerAdapter(volumeStore: volumeStore)
        let timeline = AppPlayerTimelineClock()
        let decoder = AVFoundationAudioDecoder(chunkDurationSeconds: playbackSeconds)

        do {
            print("playback-smoke phase=decode source=\(IngestRedaction.sourceDescription(normalizedSource)) type=\(type.rawValue)")
            let chunks = try await decoder.decodedChunks(
                for: AudioDecodeRequest(
                    source: normalizedSource,
                    streamType: type,
                    durationSeconds: playbackSeconds,
                    maxChunks: 1
                )
            )
            let frames = chunks.map { SharedPCMFrame(streamID: 1, chunk: $0) }
            let playableFrames = frames.filter { $0.format.payloadKind == .linearPCM }
            guard !playableFrames.isEmpty else {
                throw PlaybackSmokeError.noPlayablePCM(chunks.count)
            }

            let byteCount = playableFrames.reduce(0) { $0 + $1.byteCount }
            let firstFormat = playableFrames[0].format
            print(
                "playback-smoke phase=decoded chunks=\(chunks.count) playable=\(playableFrames.count) bytes=\(byteCount) sampleRate=\(firstFormat.sampleRate ?? 0) channels=\(firstFormat.channelCount ?? 0) bitDepth=\(firstFormat.bitDepth ?? 0)"
            )

            try await adapter.prepare(
                streamID: 1,
                sourceDescription: IngestRedaction.sourceDescription(normalizedSource),
                timeline: timeline
            )
            try await adapter.play(playableFrames, timeline: timeline)
            print("playback-smoke phase=playing seconds=\(playbackSeconds)")

            if testMute {
                try await sleep(seconds: min(2, playbackSeconds / 3))
                await volumeStore.setMuted(streamID: 1, isMuted: true)
                print("playback-smoke phase=muted")
                try await sleep(seconds: min(1, playbackSeconds / 3))
                await volumeStore.setMuted(streamID: 1, isMuted: false)
                print("playback-smoke phase=unmuted")
                try await sleep(seconds: max(0.5, playbackSeconds - min(3, playbackSeconds)))
            } else {
                try await sleep(seconds: playbackSeconds)
            }

            await adapter.stop(timeline: timeline)
            let snapshot = await timeline.snapshot()
            print("playback-smoke phase=stopped state=\(snapshot.state.title) decodedFrames=\(snapshot.decodedFrameCount) liveEdge=\(snapshot.liveEdgeSeconds)")
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            await adapter.stop(timeline: timeline)
            standardErrorWrite("playback-smoke failed: \(IngestRedaction.redact(String(describing: error)))")
            throw ExitCode.failure
        }
    }

    private func resolvedStreamType(for source: String) -> StreamType {
        if streamType.value != .auto { return streamType.value }
        let lowercased = source.lowercased()
        if lowercased.contains(".m3u8") { return .hls }
        return .auto
    }

    private func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func standardErrorWrite(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private enum PlaybackSmokeError: Error, CustomStringConvertible {
    case noPlayablePCM(Int)

    var description: String {
        switch self {
        case .noPlayablePCM(let chunkCount):
            return "decoded \(chunkCount) chunk(s), but none were playable linear PCM"
        }
    }
}
