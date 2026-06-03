import Foundation

enum AppVerifyFixtureChecks {
  static func runtimeStartedCheck(events: [AppStreamRuntimeEvent], facts: AppVerifyRuntimeFacts)
    -> AppVerifyCheckRecord
  {
    let phases = events.map(\.phase.statusPhase)
    guard phases.contains(.connecting), phases.contains(.running) else {
      return .fail(
        .runtimeStarted,
        phase: .runtimeStart,
        reason: "Runtime event stream did not include both connecting and running phases.",
        facts: facts
      )
    }
    return .pass(.runtimeStarted, phase: .runtimeStart, facts: facts)
  }

  static func runtimeStoppedCheck(
    terminal: AppStreamRuntimeEvent,
    timeline: AppPlayerTimelineSnapshot,
    facts: AppVerifyRuntimeFacts
  ) -> AppVerifyCheckRecord {
    switch terminal.phase {
    case .stopped:
      guard timeline.state == .stopped else {
        return .fail(
          .runtimeStopped,
          phase: .runtimeStop,
          reason:
            "Runtime stopped but player timeline state was \(timelineStateName(timeline.state)).",
          facts: facts
        )
      }
      return .pass(.runtimeStopped, phase: .runtimeStop, facts: facts)
    case .error(let message):
      return .fail(
        .runtimeStopped,
        phase: .runtimeStop,
        reason: "Runtime ended in error: \(message).",
        facts: facts
      )
    default:
      return .fail(
        .runtimeStopped,
        phase: .runtimeStop,
        reason: "Runtime terminal event was not stopped or error.",
        facts: facts
      )
    }
  }

  static func playbackCheck(
    scheduledBuffers: Int,
    diagnostics: AppVerifyDiagnosticsSnapshot,
    facts: AppVerifyRuntimeFacts
  ) -> AppVerifyCheckRecord {
    let names = Set(diagnostics.eventNames)
    let hasPrepare = names.contains("playback.prepare.succeeded")
    let hasScheduledEvent = names.contains("playback.play.scheduled")
    guard scheduledBuffers > 0 else {
      return .fail(
        .avfoundationPlaybackScheduled,
        phase: .playback,
        reason:
          "Playback proof requires a player timeline with at least one decoded/scheduled buffer.",
        facts: facts
      )
    }
    guard hasPrepare, hasScheduledEvent else {
      return .fail(
        .avfoundationPlaybackScheduled,
        phase: .playback,
        reason:
          "Playback proof is missing required AVFoundation diagnostic events: prepare=\(hasPrepare), scheduled=\(hasScheduledEvent).",
        facts: facts
      )
    }
    return .pass(.avfoundationPlaybackScheduled, phase: .playback, facts: facts)
  }

  static func diagnosticsCheck(
    snapshot: AppVerifyDiagnosticsSnapshot,
    artifacts: [AppVerifyRedactedArtifact]
  ) -> AppVerifyCheckRecord {
    let facts = AppVerifyRuntimeFacts(
      phase: .diagnostics,
      diagnosticCount: snapshot.eventNames.count + snapshot.errorNames.count,
      recentDiagnosticEvents: snapshot.recentNames
    )
    guard snapshot.eventFileExists else {
      return .fail(
        .diagnosticsWritten,
        phase: .diagnostics,
        reason: "Diagnostics event log was not written.",
        facts: facts,
        artifacts: artifacts
      )
    }
    guard snapshot.malformedLineCount == 0 else {
      return .fail(
        .diagnosticsWritten,
        phase: .diagnostics,
        reason:
          "Diagnostics log contained \(snapshot.malformedLineCount) malformed JSONL entr\(snapshot.malformedLineCount == 1 ? "y" : "ies").",
        facts: facts,
        artifacts: artifacts
      )
    }
    guard snapshot.eventNames.contains("runtime.event.published") else {
      return .fail(
        .diagnosticsWritten,
        phase: .diagnostics,
        reason: "Diagnostics log is missing runtime.event.published entries.",
        facts: facts,
        artifacts: artifacts
      )
    }
    return .pass(
      .diagnosticsWritten,
      phase: .diagnostics,
      facts: facts,
      artifacts: artifacts
    )
  }

  static func projectionChecks(
    database: SoundingDatabase,
    streamID: Int64,
    timeline: AppPlayerTimelineSnapshot,
    diagnosticsSnapshot: AppVerifyDiagnosticsSnapshot,
    refreshedAt: String
  ) -> [AppVerifyCheckRecord] {
    do {
      let probe = try AppVerifyFixtureProjectionProbe.collect(
        database: database,
        streamID: streamID,
        timeline: timeline,
        refreshedAt: refreshedAt,
        diagnosticEvents: diagnosticsSnapshot.recentNames
      )
      return probe.checks
    } catch {
      let reason = "Projection probe failed: \(sanitize(error))."
      return AppVerifyCheckName.s03ProjectionRequired.map { name in
        .fail(
          name,
          phase: projectionPhase(for: name),
          reason: reason,
          projectionFacts: AppVerifyProjectionFacts(
            surface: projectionSurface(for: name),
            recentDiagnosticEvents: diagnosticsSnapshot.recentNames
          )
        )
      }
    }
  }

  static func projectionPhase(for name: AppVerifyCheckName) -> AppVerifyRuntimePhase {
    switch name {
    case .transcriptPersistence: return .transcriptPersistence
    case .transcriptTimelineProjection: return .transcriptTimelineProjection
    case .transcriptSearchProjection: return .transcriptSearchProjection
    case .songMetadataProjection: return .songMetadataProjection
    case .adMetadataProjection: return .adMetadataProjection
    default: return .output
    }
  }

  static func projectionSurface(for name: AppVerifyCheckName) -> String {
    switch name {
    case .transcriptPersistence: return "transcript persistence"
    case .transcriptTimelineProjection: return "transcript timeline"
    case .transcriptSearchProjection: return "transcript search"
    case .songMetadataProjection: return "song metadata"
    case .adMetadataProjection: return "ad metadata"
    default: return name.rawValue
    }
  }

  static func diagnosticsSnapshot(for diagnostics: AppRuntimeDiagnosticsLog)
    -> AppVerifyDiagnosticsSnapshot
  {
    let events = parseDiagnostics(at: diagnostics.eventLogURL)
    let errors = parseDiagnostics(at: diagnostics.failureLogURL)
    return AppVerifyDiagnosticsSnapshot(
      eventFileExists: FileManager.default.fileExists(atPath: diagnostics.eventLogURL.path),
      errorFileExists: FileManager.default.fileExists(atPath: diagnostics.failureLogURL.path),
      eventEntries: events.entries,
      errorEntries: errors.entries,
      malformedLineCount: events.malformedLineCount + errors.malformedLineCount
    )
  }

  static func parseDiagnostics(at url: URL) -> (
    entries: [AppVerifyParsedDiagnosticEntry], malformedLineCount: Int
  ) {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], 0) }
    let text = String(decoding: data, as: UTF8.self)
    var entries: [AppVerifyParsedDiagnosticEntry] = []
    var malformed = 0
    let decoder = JSONDecoder()
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let lineData = String(line).data(using: .utf8) else {
        malformed += 1
        continue
      }
      do {
        let entry = try decoder.decode(AppVerifyRawDiagnosticEntry.self, from: lineData)
        entries.append(
          AppVerifyParsedDiagnosticEntry(
            event: entry.event,
            phase: entry.phase,
            streamID: entry.streamID,
            message: entry.message,
            fields: entry.fields ?? [:]
          ))
      } catch {
        malformed += 1
      }
    }
    return (Array(entries.suffix(64)), malformed)
  }

  static func scheduledBufferCount(from timeline: AppPlayerTimelineSnapshot?) -> Int {
    timeline?.decodedFrameCount ?? 0
  }

  static func scheduledBufferCount(from timeline: AppPlayerTimelineSnapshot) -> Int {
    timeline.decodedFrameCount
  }

  static func timelineFields(_ timeline: AppPlayerTimelineSnapshot?) -> [String: String] {
    guard let timeline else { return [:] }
    let state = timelineStateName(timeline.state)
    return [
      "streamID": timeline.streamID.map(String.init) ?? "nil",
      "state": state,
      "positionSeconds": String(format: "%.3f", timeline.positionSeconds),
      "liveEdgeSeconds": String(format: "%.3f", timeline.liveEdgeSeconds),
      "bufferedStartSeconds": timeline.bufferedStartSeconds.map { String(format: "%.3f", $0) }
        ?? "nil",
      "bufferedEndSeconds": timeline.bufferedEndSeconds.map { String(format: "%.3f", $0) } ?? "nil",
      "driftSeconds": String(format: "%.3f", timeline.driftSeconds),
      "decodedFrameCount": String(timeline.decodedFrameCount),
      "lastMessage": timeline.lastMessage,
    ]
  }

  static func timelineStateName(_ state: AppPlayerState) -> String {
    switch state {
    case .idle: return "idle"
    case .buffering: return "buffering"
    case .playing: return "playing"
    case .paused: return "paused"
    case .stopped: return "stopped"
    case .failed(let message): return "failed: \(message)"
    }
  }

  static func sanitize(_ error: any Error) -> String {
    AppVerifyEvidenceSanitizer.redact(String(describing: error))
  }
}
