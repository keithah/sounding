import ArgumentParser
import Foundation
import SoundingKit

struct SoakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "soak",
        abstract: "Run short automated soak proofs and emit redacted evidence.",
        subcommands: [Proof.self]
    )

    struct Proof: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "proof",
            abstract: "Run a bounded synthetic short soak and write redacted JSON or NDJSON evidence."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to exercise.")
        var db: String

        @Option(name: .long, help: "Path where redacted soak evidence should be written.")
        var evidenceOut: String

        @Option(name: .long, help: "Short soak duration in seconds. Must be greater than zero and at most 30 seconds.")
        var durationSeconds: Double = 0.3

        @Option(name: .long, help: "Resource/status sample interval in seconds. Must be at least 0.01 seconds.")
        var sampleIntervalSeconds: Double = 0.1

        @Option(name: .long, help: "Evidence format: json or ndjson.")
        var format: SoakEvidenceFormatArgument = .json

        @Flag(name: .long, help: "Emit stable redacted JSON summary.")
        var json = false

        @Option(name: .long, help: .hidden)
        var maximumQueueDepth: Int = 4

        @Flag(name: .long, help: .hidden)
        var failOnUnavailableResources = false

        mutating func validate() throws {
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                throw ValidationError("--duration-seconds must be a positive finite value")
            }
            guard durationSeconds <= 30 else {
                throw ValidationError("--duration-seconds must be 30 seconds or less")
            }
            guard sampleIntervalSeconds.isFinite, sampleIntervalSeconds > 0 else {
                throw ValidationError("--sample-interval-seconds must be a positive finite value")
            }
            guard sampleIntervalSeconds >= 0.01 else {
                throw ValidationError("--sample-interval-seconds must be at least 0.01 seconds")
            }
            guard maximumQueueDepth >= 0 else {
                throw ValidationError("--maximum-queue-depth must be zero or greater")
            }
        }

        mutating func run() async throws {
            let database: SoundingDatabase
            do {
                database = try SoundingDatabase(fileURL: URL(fileURLWithPath: db))
            } catch {
                writeStandardError(SoakCommandError.databaseOpenFailed.description)
                throw ExitCode.failure
            }

            let runner = SoakProofRunner(
                database: database,
                configuration: SoakProofRunnerConfiguration(
                    durationSeconds: durationSeconds,
                    sampleIntervalSeconds: sampleIntervalSeconds,
                    maximumSamples: 8,
                    maximumQueueDepth: maximumQueueDepth,
                    failOnUnavailableResources: failOnUnavailableResources
                ),
                evidenceFormat: format.value
            )

            let result: SoakProofRunnerResult
            do {
                result = try await runner.run()
            } catch let error as SoakProofRunnerError {
                writeStandardError(SoakCommandError.validationFailed(error.description).description)
                throw ExitCode.failure
            } catch let error as SoakEvidenceEncodingFailure {
                writeStandardError(SoakCommandError.encodingFailed(error.message).description)
                throw ExitCode.failure
            } catch {
                writeStandardError(SoakCommandError.runnerFailed.description)
                throw ExitCode.failure
            }

            do {
                try writeEvidence(result.encodedEvidence, toPath: evidenceOut)
            } catch {
                writeStandardError(SoakCommandError.outputFailed.description)
                throw ExitCode.failure
            }

            let summary = SoakProofSummary(evidence: result.evidence)
            do {
                try writeStandardOutput(render(summary: summary, json: json))
            } catch {
                writeStandardError(SoakCommandError.summaryOutputFailed.description)
                throw ExitCode.failure
            }

            guard summary.ok else {
                throw ExitCode.failure
            }
        }

        private func writeEvidence(_ data: Data, toPath path: String) throws {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        private func render(summary: SoakProofSummary, json: Bool) throws -> String {
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                return String(decoding: try encoder.encode(summary), as: UTF8.self) + "\n"
            }
            return [
                "soak proof \(summary.ok ? "passed" : "failed"):",
                "streams=\(summary.streamCount)",
                "reconnects=\(summary.reconnectCount)",
                "queueMaxDepth=\(summary.queueMaxDepth)",
                "dbHealth=\(summary.databaseHealthStatus)",
                "checkpoint=\(summary.checkpointStatus)",
                "failures=\(summary.failureCount)",
                "redaction=\(summary.redactionAuditStatus)"
            ].joined(separator: " ") + "\n"
        }

        private func writeStandardOutput(_ text: String) throws {
            guard let data = text.data(using: .utf8) else {
                throw SoakCommandError.summaryOutputFailed
            }
            FileHandle.standardOutput.write(data)
        }

        private func writeStandardError(_ message: String) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }
}

struct SoakEvidenceFormatArgument: ExpressibleByArgument, CustomStringConvertible, Equatable {
    static let json = SoakEvidenceFormatArgument(value: .json)
    static let ndjson = SoakEvidenceFormatArgument(value: .ndjson)

    let value: SoakEvidenceFormat

    var description: String { value.rawValue }

    init(value: SoakEvidenceFormat) {
        self.value = value
    }

    init?(argument: String) {
        guard let value = SoakEvidenceFormat(rawValue: argument.lowercased()) else {
            return nil
        }
        self.value = value
    }
}

private struct SoakProofSummary: Codable, Equatable {
    var ok: Bool
    var verdict: String
    var streamCount: Int
    var reconnectCount: Int
    var queueMaxDepth: Int
    var databaseHealthStatus: String
    var checkpointStatus: String
    var failureCount: Int
    var redactionAuditStatus: String

    init(evidence: SoakEvidence) {
        let failedThresholds = evidence.thresholds.contains { $0.status == .fail }
        self.ok = evidence.summary.verdict == .pass && !failedThresholds && evidence.redactionAudit.passed
        self.verdict = evidence.summary.verdict.rawValue
        self.streamCount = evidence.summary.streamCount
        self.reconnectCount = evidence.runtimeEvents.filter { $0.phase == "reconnecting" }.count
        self.queueMaxDepth = evidence.queueSnapshots.map(\.maxDepth).max() ?? 0
        self.databaseHealthStatus = Self.firstDatabaseStatus(in: evidence) ?? "unavailable"
        self.checkpointStatus = Self.firstCheckpointStatus(in: evidence) ?? "unavailable"
        self.failureCount = evidence.summary.failureCount
        self.redactionAuditStatus = evidence.redactionAudit.passed ? "pass" : "fail"
    }

    private static func firstDatabaseStatus(in evidence: SoakEvidence) -> String? {
        evidence.databaseSnapshots
            .compactMap { snapshot -> String? in
                guard snapshot.quickCheckStatus != nil || snapshot.foreignKeyCheckStatus != nil || snapshot.pageCount != nil else {
                    return nil
                }
                return snapshot.status?.rawValue
            }
            .first
    }

    private static func firstCheckpointStatus(in evidence: SoakEvidence) -> String? {
        evidence.databaseSnapshots
            .compactMap { snapshot -> String? in
                guard snapshot.checkpointLogFrames != nil || snapshot.checkpointedFrames != nil || snapshot.checkpointBusyFrames != nil else {
                    return nil
                }
                return snapshot.status?.rawValue
            }
            .first
    }
}

private enum SoakCommandError: Error, CustomStringConvertible {
    case databaseOpenFailed
    case validationFailed(String)
    case encodingFailed(String)
    case runnerFailed
    case outputFailed
    case summaryOutputFailed

    var description: String {
        switch self {
        case .databaseOpenFailed:
            return "Soak proof database failed: could not open redacted database path; run database health for redacted database guidance."
        case .validationFailed(let message):
            return "Soak proof validation failed: \(SoakCommandError.sanitize(message))."
        case .encodingFailed(let message):
            return "Soak proof encoding failed: \(SoakCommandError.sanitize(message))."
        case .runnerFailed:
            return "Soak proof runtime failed: short soak runner stopped before evidence could be produced."
        case .outputFailed:
            return "Soak proof output failed: could not write evidence to redacted output path."
        case .summaryOutputFailed:
            return "Soak proof output failed: could not write redacted summary."
        }
    }

    private static func sanitize(_ message: String) -> String {
        MonitorError.redactedSourceDescription(message)
    }
}
