import ArgumentParser
import Foundation
import SoundingKit

struct AppVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-verify",
        abstract: "Run app-runtime verification checks and write redacted evidence.",
        subcommands: [Fixture.self]
    )

    struct Fixture: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fixture",
            abstract: "Run the deterministic app-runtime fixture verification path."
        )

        @Option(name: .long, help: "Path where redacted app verification JSON evidence should be written.")
        var json: String

        mutating func run() async throws {
            let adapter = AppVerifyFixtureCommandAdapter()
            let exitCode = await adapter.run(jsonPath: json)
            guard exitCode == .success else {
                throw exitCode
            }
        }
    }
}

struct AppVerifyFixtureCommandAdapter: Sendable {
    typealias EvidenceRunner = @Sendable () async -> AppVerifyEvidence
    typealias OutputWriter = @Sendable (_ message: String) -> Void

    var runner: EvidenceRunner
    var standardOutput: OutputWriter
    var standardError: OutputWriter

    init(
        runner: @escaping EvidenceRunner = { await AppVerifyFixtureRunner().run() },
        standardOutput: @escaping OutputWriter = { message in
            FileHandle.standardOutput.write(Data((message + "\n").utf8))
        },
        standardError: @escaping OutputWriter = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    ) {
        self.runner = runner
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    func run(jsonPath: String) async -> ExitCode {
        let evidence = await runner()

        do {
            let data = try encodeEvidence(evidence)
            try writeEvidence(data, toPath: jsonPath)
        } catch {
            standardError(outputFailureMessage(error))
            return .failure
        }

        standardOutput(summaryLine(for: evidence))
        return evidence.summary.status == .fail ? .failure : .success
    }

    func encodeEvidence(_ evidence: AppVerifyEvidence) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(evidence)
    }

    func writeEvidence(_ data: Data, toPath path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw AppVerifyCommandError.outputFailed
        }
    }

    func summaryLine(for evidence: AppVerifyEvidence) -> String {
        let failedChecks = evidence.checks
            .filter { $0.status == .fail }
            .map { "\($0.name.rawValue):\($0.phase.rawValue):\($0.required ? "required" : "optional")" }
            .joined(separator: ", ")
        let suffix = failedChecks.isEmpty ? "" : "; failures=\(failedChecks)"
        return "app verification \(summaryVerb(for: evidence.summary.status)): status=\(evidence.summary.status.rawValue), required=\(evidence.summary.requiredCheckCount), requiredFailures=\(evidence.summary.failedRequiredCheckCount), warnings=\(evidence.summary.warningCheckCount)\(suffix)"
    }

    private func summaryVerb(for status: AppVerifyEvidenceStatus) -> String {
        switch status {
        case .pass:
            return "passed"
        case .warn:
            return "warned"
        case .fail:
            return "failed"
        }
    }

    private func outputFailureMessage(_ error: any Error) -> String {
        switch error {
        case AppVerifyCommandError.outputFailed:
            return "App verification output failed: could not write evidence to redacted output path."
        default:
            return "App verification output failed: \(sanitizeDiagnostic(String(describing: error)))."
        }
    }

    private func sanitizeDiagnostic(_ value: String) -> String {
        MonitorError.redactedSourceDescription(value)
    }
}

enum AppVerifyCommandError: Error, Equatable {
    case outputFailed
}
