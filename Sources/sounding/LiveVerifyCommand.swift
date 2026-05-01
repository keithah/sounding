import ArgumentParser
import Foundation
import SoundingKit

struct LiveVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live-verify",
        abstract: "Run configured live stream verification and write redacted evidence."
    )

    @Option(name: .long, help: "Path to a local JSON live verification config.")
    var config: String

    @Option(name: .long, help: "Path where redacted verification evidence should be written.")
    var evidenceOut: String

    @Option(name: .long, help: "Evidence format: json or ndjson.")
    var format: LiveVerifyEvidenceFormat = .json

    mutating func run() async throws {
        let verifier = LiveStreamVerifier()
        let verificationConfig: LiveStreamVerificationConfig

        do {
            verificationConfig = try readConfig(atPath: config)
        } catch let error as LiveStreamVerificationError {
            standardErrorWrite(error.description)
            throw ExitCode.failure
        } catch {
            standardErrorWrite(LiveStreamVerificationError.configurationFailed(sanitizeDiagnostic(String(describing: error))).description)
            throw ExitCode.failure
        }

        let summary = await verifier.verify(config: verificationConfig)

        do {
            let evidence = try encode(summary: summary, verifier: verifier)
            try writeEvidence(evidence, toPath: evidenceOut)
        } catch let error as LiveStreamVerificationError {
            standardErrorWrite(error.description)
            throw ExitCode.failure
        } catch {
            standardErrorWrite(LiveStreamVerificationError.outputFailed(sanitizeDiagnostic(String(describing: error))).description)
            throw ExitCode.failure
        }

        print(summaryLine(for: summary))

        guard summary.passed else {
            throw ExitCode.failure
        }
    }

    private func readConfig(atPath path: String) throws -> LiveStreamVerificationConfig {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(LiveStreamVerificationConfig.self, from: data)
        } catch let error as LiveStreamVerificationError {
            throw error
        } catch let error as DecodingError {
            throw LiveStreamVerificationError.configurationFailed(sanitizedDecodingError(error))
        } catch {
            throw LiveStreamVerificationError.configurationFailed("could not read live verification config from redacted config path")
        }
    }

    private func encode(
        summary: LiveStreamVerificationSummary,
        verifier: LiveStreamVerifier
    ) throws -> Data {
        switch format.value {
        case .json:
            return try verifier.encodeSummaryJSON(summary)
        case .ndjson:
            return try verifier.encodeResultsNDJSON(summary.results)
        }
    }

    private func writeEvidence(_ data: Data, toPath path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw LiveStreamVerificationError.outputFailed("could not write evidence to redacted output path")
        }
    }

    private func summaryLine(for summary: LiveStreamVerificationSummary) -> String {
        let failedCategories = summary.results
            .filter { $0.category != .passed }
            .map { "\($0.id):\($0.category.rawValue):\($0.required ? "required" : "optional")" }
            .joined(separator: ", ")
        let suffix = failedCategories.isEmpty ? "" : "; failures=\(failedCategories)"
        return "live verification \(summary.passed ? "passed" : "failed"): total=\(summary.totalStreams), requiredFailures=\(summary.requiredFailures), optionalFailures=\(summary.optionalFailures)\(suffix)"
    }

    private func sanitizedDecodingError(_ error: DecodingError) -> String {
        switch error {
        case let .dataCorrupted(context):
            return sanitizedCodingContext("malformed JSON", context: context)
        case let .keyNotFound(key, context):
            return sanitizedCodingContext("missing key '\(key.stringValue)'", context: context)
        case let .typeMismatch(type, context):
            return sanitizedCodingContext("type mismatch for \(type)", context: context)
        case let .valueNotFound(type, context):
            return sanitizedCodingContext("missing value for \(type)", context: context)
        @unknown default:
            return "configuration could not be decoded"
        }
    }

    private func sanitizedCodingContext(_ prefix: String, context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        let suffix = path.isEmpty ? "" : " at \(path)"
        return sanitizeDiagnostic(prefix + suffix)
    }

    private func sanitizeDiagnostic(_ value: String) -> String {
        MonitorError.redactedSourceDescription(value)
    }

    private func standardErrorWrite(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

struct LiveVerifyEvidenceFormat: ExpressibleByArgument, Equatable {
    static let json = LiveVerifyEvidenceFormat(value: .json)
    static let ndjson = LiveVerifyEvidenceFormat(value: .ndjson)

    let value: Value

    init(value: Value) {
        self.value = value
    }

    init?(argument: String) {
        guard let value = Value(rawValue: argument.lowercased()) else {
            return nil
        }
        self.value = value
    }

    enum Value: String {
        case json
        case ndjson
    }
}
