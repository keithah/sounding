import ArgumentParser
import Foundation
import SoundingKit

struct AppDiagnosticsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-diagnostics",
        abstract: "Summarize Sounding.app local runtime event, failure, and app-verify evidence logs."
    )

    @Option(name: .long, help: "Directory containing runtime-events.jsonl and runtime-errors.jsonl.")
    var logDirectory: String?

    @Option(name: .long, help: "Number of recent entries to print from each log.")
    var tail: Int = 40

    @Flag(name: .long, help: "Print raw JSONL entries instead of a compact summary.")
    var raw = false

    @Option(name: .long, help: "App-verify JSON evidence file to summarize. Repeat for multiple files.")
    var evidence: [String] = []

    mutating func run() throws {
        let directory = resolvedLogDirectory()
        let eventURL = directory.appendingPathComponent("runtime-events.jsonl")
        let failureURL = directory.appendingPathComponent("runtime-errors.jsonl")
        let events = readEntries(from: eventURL)
        let failures = readEntries(from: failureURL)
        let boundedTail = boundedTailLimit(tail)

        print("app-diagnostics logDirectory=[redacted-path]")
        print("app-diagnostics events=\(events.count) failures=\(failures.count)")
        printEventCounts(events)
        printPhaseCounts(events)
        print("app-diagnostics recent-events")
        printRecent(events, limit: boundedTail)
        print("app-diagnostics recent-failures")
        printRecent(failures, limit: boundedTail)

        try printEvidenceReviews()
    }

    private func resolvedLogDirectory() -> URL {
        if let logDirectory, !logDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: logDirectory, isDirectory: true)
        }
        return AppRuntimeDiagnosticsLog.defaultLogDirectory()
    }

    private func readEntries(from url: URL) -> [RuntimeLogEntry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? JSONDecoder().decode(RuntimeLogEntry.self, from: lineData)
            else { return nil }
            return entry.sanitized()
        }
    }

    private func printEventCounts(_ entries: [RuntimeLogEntry]) {
        print("app-diagnostics event-counts")
        for (event, count) in counted(entries.map(\.event)).prefix(20) {
            print("  \(event)=\(count)")
        }
    }

    private func printPhaseCounts(_ entries: [RuntimeLogEntry]) {
        print("app-diagnostics phase-counts")
        for (phase, count) in counted(entries.compactMap(\.phase)).prefix(20) {
            print("  \(phase)=\(count)")
        }
    }

    private func counted(_ values: [String]) -> [(String, Int)] {
        Dictionary(grouping: values, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1 }
    }

    private func boundedTailLimit(_ value: Int) -> Int {
        min(max(value, 0), 500)
    }

    private func printRecent(_ entries: [RuntimeLogEntry], limit: Int) {
        for entry in entries.suffix(limit) {
            if raw {
                if let data = try? JSONEncoder.sorted.encode(entry),
                   let json = String(data: data, encoding: .utf8)
                {
                    print(json)
                }
            } else {
                let stream = entry.streamID.map { " stream=\($0)" } ?? ""
                let phase = entry.phase.map { " phase=\($0)" } ?? ""
                let message = entry.message.map { " message=\($0)" } ?? ""
                let fields = entry.fields.isEmpty
                    ? ""
                    : " fields=" + entry.fields.sorted { $0.key < $1.key }
                        .map { "\($0.key):\($0.value)" }
                        .joined(separator: ",")
                print("  \(entry.timestamp) level=\(entry.level) event=\(entry.event)\(stream)\(phase)\(message)\(fields)")
            }
        }
    }

    private func printEvidenceReviews() throws {
        for evidencePath in evidence {
            switch AppVerifyEvidenceReview.load(path: evidencePath) {
            case .success(let review):
                review.printReview()
            case .failure(let error):
                writeStandardError(error.message + "\n")
                throw ExitCode.failure
            }
        }
    }

    private func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private enum AppVerifyEvidenceReviewError: Error, Equatable {
    case unreadable
    case malformed

    var message: String {
        switch self {
        case .unreadable:
            return "app-diagnostics evidence=[redacted-path] error=unreadable"
        case .malformed:
            return "app-diagnostics evidence=[redacted-path] error=malformed-app-verify-evidence"
        }
    }
}

private struct AppVerifyEvidenceReview {
    var evidence: AppVerifyEvidence

    static func load(path: String) -> Result<AppVerifyEvidenceReview, AppVerifyEvidenceReviewError> {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return .failure(.unreadable)
        }

        do {
            let evidence = try JSONDecoder().decode(AppVerifyEvidence.self, from: data)
            return .success(AppVerifyEvidenceReview(evidence: evidence))
        } catch {
            return .failure(.malformed)
        }
    }

    func printReview() {
        print("app-diagnostics evidence=[redacted-path]")
        print("  schemaVersion=\(max(0, evidence.schemaVersion)) runID=\(safe(evidence.runID)) status=\(evidence.summary.status.rawValue)")
        print("  required=\(evidence.summary.requiredCheckCount) requiredFailures=\(evidence.summary.failedRequiredCheckCount) warnings=\(evidence.summary.warningCheckCount) checks=\(evidence.checks.count)")
        print("  message=\(safe(evidence.summary.message))")
        printPhaseCounts()
        printFailedRequiredChecks()
        printWarnings()
        printArtifacts()
        printRecentDiagnosticEvents()
    }

    private func printPhaseCounts() {
        print("  phase-counts")
        for (phase, count) in counted(evidence.checks.map { safe($0.phase.rawValue) }).prefix(20) {
            print("    \(phase)=\(count)")
        }
    }

    private func printFailedRequiredChecks() {
        print("  failed-required-checks")
        let failed = evidence.checks.filter { $0.required && $0.status == .fail }
        for check in failed.prefix(20) {
            printCheck(check)
        }
    }

    private func printWarnings() {
        print("  warnings")
        let warnings = evidence.checks.filter { $0.status == .warn }
        for check in warnings.prefix(20) {
            printCheck(check)
        }
    }

    private func printCheck(_ check: AppVerifyCheckRecord) {
        let reason = check.reason.map { " reason=\(safe($0))" } ?? ""
        let context = factContext(for: check).map { " facts=\($0)" } ?? ""
        print("    check=\(safe(check.name.rawValue)) phase=\(safe(check.phase.rawValue)) required=\(check.required) status=\(check.status.rawValue)\(reason)\(context)")
    }

    private func printArtifacts() {
        print("  artifacts")
        let artifacts = allArtifacts()
        guard !artifacts.isEmpty else { return }
        for artifact in artifacts.prefix(32) {
            let note = artifact.note.map { " note=\(safe($0))" } ?? ""
            print("    kind=\(safe(artifact.kind)) path=\(artifactPath(artifact.path))\(note)")
        }
    }

    private func printRecentDiagnosticEvents() {
        print("  recent-diagnostic-events")
        for event in recentDiagnosticEvents().prefix(32) {
            print("    \(safe(event))")
        }
    }

    private func counted(_ values: [String]) -> [(String, Int)] {
        Dictionary(grouping: values, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1 }
    }

    private func allArtifacts() -> [AppVerifyRedactedArtifact] {
        var artifacts = evidence.artifacts
        for check in evidence.checks {
            artifacts.append(contentsOf: check.artifacts)
        }
        return artifacts
    }

    private func recentDiagnosticEvents() -> [String] {
        var events: [String] = []
        if let runtimeFacts = evidence.runtimeFacts {
            events.append(contentsOf: runtimeFacts.recentDiagnosticEvents)
        }
        for check in evidence.checks {
            if let facts = check.facts {
                events.append(contentsOf: facts.recentDiagnosticEvents)
            }
            if let controlFacts = check.controlFacts {
                events.append(contentsOf: controlFacts.diagnosticEventNames)
                events.append(contentsOf: controlFacts.diagnostics.map(\.event))
            }
            if let projectionFacts = check.projectionFacts {
                events.append(contentsOf: projectionFacts.recentDiagnosticEvents)
            }
            if let liveFacts = check.liveFacts {
                events.append(contentsOf: liveFacts.recentDiagnosticEvents)
            }
        }
        return unique(events.map(safe))
    }

    private func factContext(for check: AppVerifyCheckRecord) -> String? {
        var parts: [String] = []
        if let facts = check.facts {
            parts.append("runtime(processed=\(facts.processedChunks),decoded=\(facts.decodedChunks),scheduled=\(facts.scheduledBuffers),diagnostics=\(facts.diagnosticCount))")
        }
        if let controlFacts = check.controlFacts {
            var control = [
                "action=\(safe(controlFacts.requestedAction))",
                "observedPhase=\(safe(controlFacts.observedRuntimePhase.rawValue))",
            ]
            if let timelineState = controlFacts.timelineState {
                control.append("timeline=\(safe(timelineState))")
            }
            if let muted = controlFacts.muted {
                control.append("muted=\(muted)")
            }
            if let effectiveVolume = controlFacts.effectiveVolume {
                control.append("effectiveVolume=\(String(format: "%.3f", effectiveVolume))")
            }
            if !controlFacts.diagnosticEventNames.isEmpty {
                control.append("events=\(safeList(controlFacts.diagnosticEventNames, limit: 6))")
            }
            parts.append("control(\(control.joined(separator: ",")))")
        }
        if let projectionFacts = check.projectionFacts {
            parts.append("projection(surface=\(safe(projectionFacts.surface)),rows=\(projectionFacts.rowCount),projections=\(projectionFacts.projectionCount),metadata=\(projectionFacts.metadataCount),events=\(safeList(projectionFacts.recentDiagnosticEvents, limit: 6)))")
        }
        if let liveFacts = check.liveFacts {
            parts.append("live(stream=\(safe(liveFacts.streamID)),type=\(liveFacts.resolvedStreamType.rawValue),required=\(liveFacts.required),processed=\(liveFacts.processedChunks),decoded=\(liveFacts.decodedChunks),scheduled=\(liveFacts.scheduledBuffers),transcripts=\(liveFacts.transcriptCount),metadata=\(liveFacts.metadataCount),events=\(safeList(liveFacts.recentDiagnosticEvents, limit: 6)))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ";")
    }

    private func safeList(_ values: [String], limit: Int) -> String {
        let values = values.prefix(limit).map(safe)
        return values.isEmpty ? "none" : values.joined(separator: "|")
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private func artifactPath(_ value: String) -> String {
        let redacted = safe(value)
        if redacted.contains("[redacted-path]") {
            return "[redacted-path]"
        }
        return redacted
    }

    private func safe(_ value: String) -> String {
        AppDiagnosticsRedaction.bounded(AppDiagnosticsRedaction.scrubSecretKeyNames(IngestRedaction.redact(value)))
    }
}

private enum AppDiagnosticsRedaction {
    static func scrubSecretKeyNames(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)\b(?:token|access_token|api[_-]?key|secret|password|passwd|pwd|key)=\[redacted\]"#,
            with: "[redacted-secret]",
            options: .regularExpression
        )
    }

    static func bounded(_ value: String) -> String {
        let limit = 512
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }
}

private struct RuntimeLogEntry: Codable {
    var timestamp: String
    var level: String
    var event: String
    var streamID: Int64?
    var streamName: String?
    var source: String?
    var phase: String?
    var errorType: String?
    var message: String?
    var fields: [String: String]

    func sanitized() -> RuntimeLogEntry {
        RuntimeLogEntry(
            timestamp: Self.sanitize(timestamp),
            level: Self.sanitize(level),
            event: Self.sanitize(event),
            streamID: streamID,
            streamName: streamName.map(Self.sanitize),
            source: source.map(Self.sanitizeSource),
            phase: phase.map(Self.sanitize),
            errorType: errorType.map(Self.sanitize),
            message: message.map(Self.sanitize),
            fields: Self.sanitizeFields(fields)
        )
    }

    private static func sanitizeFields(_ fields: [String: String]) -> [String: String] {
        fields.sorted { $0.key < $1.key }.prefix(32).reduce(into: [:]) { partial, pair in
            partial[sanitizeFieldKey(pair.key)] = sanitize(pair.value)
        }
    }

    private static func sanitizeFieldKey(_ key: String) -> String {
        let redacted = sanitize(key)
        if redacted.range(
            of: #"(?i)\b(token|access[_-]?token|api[_-]?key|secret|password|passwd|pwd|credential|authorization)\b"#,
            options: .regularExpression
        ) != nil {
            return "[redacted-secret-key]"
        }
        return redacted
    }

    private static func sanitizeSource(_ value: String) -> String {
        bounded(IngestRedaction.sourceDescription(value))
    }

    private static func sanitize(_ value: String) -> String {
        AppDiagnosticsRedaction.bounded(AppDiagnosticsRedaction.scrubSecretKeyNames(IngestRedaction.redact(value)))
    }

    private static func bounded(_ value: String) -> String {
        AppDiagnosticsRedaction.bounded(value)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
