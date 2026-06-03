import Foundation

public actor AppVerifyLiveActiveRuntimeStore {
    private var handles: [String: AppVerifyLiveRuntimeHandle] = [:]

    public init() {}

    func insert(_ handle: AppVerifyLiveRuntimeHandle, for request: AppVerifyLiveStreamExecutionRequest) {
        handles[key(runID: request.runID, streamID: request.stream.id)] = handle
    }

    func remove(for request: AppVerifyLiveStreamStopRequest) -> AppVerifyLiveRuntimeHandle? {
        handles.removeValue(forKey: key(runID: request.runID, streamID: request.stream.id))
    }

    private func key(runID: String, streamID: String) -> String {
        "\(runID)::\(streamID)"
    }
}

struct AppVerifyLiveRuntimeHandle: Sendable {
    var runtime: any AppStreamRuntimeControlling
    var player: any AppPCMPlaybackAdapting
    var timeline: AppPlayerTimelineClock
    var rollingBuffer: RollingPCMBuffer
    var diagnostics: AppRuntimeDiagnosticsLog
    var database: SoundingDatabase
    var streamID: Int64?
}

actor AppVerifyLiveRuntimeEventRecorder {
    private var events: [AppStreamRuntimeEvent] = []

    func append(_ event: AppStreamRuntimeEvent) {
        events.append(event)
    }

    func count(streamID: Int64, phase: AppStreamRuntimeStatusPhase) -> Int {
        events.filter { $0.streamID == streamID && $0.phase.statusPhase == phase }.count
    }
}

struct AppVerifyLiveDiagnosticsSnapshot: Sendable {
    var eventFileExists: Bool
    var errorFileExists: Bool
    var eventEntries: [AppVerifyParsedDiagnosticEntry]
    var errorEntries: [AppVerifyParsedDiagnosticEntry]
    var malformedLineCount: Int

    var eventNames: [String] { eventEntries.map(\.event) }
    var errorNames: [String] { errorEntries.map(\.event) }
    var recentNames: [String] { Array((eventNames + errorNames).suffix(32)) }
}

struct AppVerifyLiveRawDiagnosticEntry: Decodable {
    var event: String
    var phase: String?
    var streamID: Int64?
    var message: String?
    var fields: [String: String]?
}

enum AppVerifyLiveExecutionError: Error, CustomStringConvertible, Sendable {
    case databaseOpenFailed(String)
    case streamRegistrationFailed(String)
    case unsupportedResolvedStreamType(String)
    case runtimeStartFailed(String)
    case runtimeProofTimeout(String)
    case cleanupFailed(String)

    var description: String {
        switch self {
        case .databaseOpenFailed(let message):
            return "database open failed: \(AppVerifyEvidenceSanitizer.redact(message))"
        case .streamRegistrationFailed(let message):
            return "stream registration failed: \(AppVerifyEvidenceSanitizer.redact(message))"
        case .unsupportedResolvedStreamType(let streamType):
            return "unsupported resolved stream type for app runtime: \(AppVerifyEvidenceSanitizer.redact(streamType))"
        case .runtimeStartFailed(let message):
            return "runtime start failed: \(AppVerifyEvidenceSanitizer.redact(message))"
        case .runtimeProofTimeout(let message):
            return "runtime proof timed out or failed: \(AppVerifyEvidenceSanitizer.redact(message))"
        case .cleanupFailed(let message):
            return "cleanup failed: \(AppVerifyEvidenceSanitizer.redact(message))"
        }
    }
}

struct AppVerifyLiveNoOpTranscriber: MLTranscription {
    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] { [] }
}

struct AppVerifyLiveNoOpDiarizer: SpeakerDiarization {
    func diarize(_ chunk: DecodedAudioChunk, transcriptSegments: [TranscriptSegmentDraft]) async throws -> [SpeakerTurnDraft] { [] }
}

struct AppVerifyLiveRunnerTimeoutError: Error, CustomStringConvertible, Sendable {
    var streamID: String
    var timeoutSeconds: Double

    var description: String {
        "Timed out waiting for live stream \(AppVerifyEvidenceSanitizer.redact(streamID)) after \(String(format: "%.3f", timeoutSeconds)) seconds."
    }
}
