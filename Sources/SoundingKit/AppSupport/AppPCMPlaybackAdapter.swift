import Foundation

public enum AppPlayerAdapterError: Error, Equatable, CustomStringConvertible, Sendable {
    case independentSourcePathRejected(String)
    case audioDeviceUnavailable(String)
    case decodeFailed(String)
    case unsupportedPCMFormat(String)
    case schedulingFailed(String)

    public var description: String {
        switch self {
        case .independentSourcePathRejected(let message), .audioDeviceUnavailable(let message),
            .decodeFailed(let message), .unsupportedPCMFormat(let message),
            .schedulingFailed(let message):
            return IngestRedaction.redact(message)
        }
    }

    var redacted: AppPlayerAdapterError {
        switch self {
        case .independentSourcePathRejected:
            return .independentSourcePathRejected(description)
        case .audioDeviceUnavailable:
            return .audioDeviceUnavailable(description)
        case .decodeFailed:
            return .decodeFailed(description)
        case .unsupportedPCMFormat:
            return .unsupportedPCMFormat(description)
        case .schedulingFailed:
            return .schedulingFailed(description)
        }
    }
}

/// App-facing playback adapter. Implementations consume decoded frames only;
/// source-opening belongs exclusively to the ingest decoder.
public protocol AppPCMPlaybackAdapting: Sendable {
    func prepare(streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock)
        async throws
    func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws
    func playReplacingScheduledBuffers(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock)
        async throws
    func pause(timeline: AppPlayerTimelineClock) async
    func resume(timeline: AppPlayerTimelineClock) async
    func stop(timeline: AppPlayerTimelineClock) async
    func applyPlaybackVolume(streamID: Int64) async
}

public extension AppPCMPlaybackAdapting {
    func applyPlaybackVolume(streamID: Int64) async {}

    func playReplacingScheduledBuffers(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock)
        async throws
    {
        try await play(frames, timeline: timeline)
    }
}

/// Minimal AVFoundation-backed app adapter. It owns the audio-device boundary and
/// intentionally has no API for opening a network source, preserving the single
/// decode path enforced by `SinglePathPCMDecoder`.
