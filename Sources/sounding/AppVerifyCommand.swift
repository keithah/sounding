import ArgumentParser
import Foundation
import SoundingKit

struct AppVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-verify",
        abstract: "Run app-runtime verification checks and write redacted evidence.",
        subcommands: [Fixture.self, Live.self]
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

    struct Live: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "live",
            abstract: "Run configured live HTTP/HTTPS/HLS app-runtime verification streams."
        )

        @Option(name: .long, help: "Path to a local app-verify live JSON configuration file.")
        var config: String

        @Option(name: .long, help: "Path where redacted app verification JSON evidence should be written.")
        var json: String

        mutating func run() async throws {
            let adapter = AppVerifyLiveCommandAdapter()
            let exitCode = await adapter.run(configPath: config, jsonPath: json)
            guard exitCode == .success else {
                throw exitCode
            }
        }
    }
}

enum AppVerifyCommandSupport {
    static func encodeEvidence(_ evidence: AppVerifyEvidence) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(evidence)
    }

    static func writeEvidence(_ data: Data, toPath path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw AppVerifyCommandError.outputFailed
        }
    }

    static func summaryLine(for evidence: AppVerifyEvidence) -> String {
        let failedChecks = evidence.checks
            .filter { $0.status == .fail }
            .map { "\($0.name.rawValue):\($0.phase.rawValue):\($0.required ? "required" : "optional")" }
            .joined(separator: ", ")
        let suffix = failedChecks.isEmpty ? "" : "; failures=\(failedChecks)"
        return "app verification \(summaryVerb(for: evidence.summary.status)): status=\(evidence.summary.status.rawValue), required=\(evidence.summary.requiredCheckCount), requiredFailures=\(evidence.summary.failedRequiredCheckCount), warnings=\(evidence.summary.warningCheckCount)\(suffix)"
    }

    static func outputFailureMessage(_ error: any Error) -> String {
        switch error {
        case AppVerifyCommandError.outputFailed:
            return "App verification output failed: could not write evidence to redacted output path."
        default:
            return "App verification output failed: \(sanitizeDiagnostic(String(describing: error)))."
        }
    }

    static func configFailureMessage(_ error: any Error) -> String {
        switch error {
        case AppVerifyCommandError.configReadFailed:
            return "App verification live configuration failed: could not read redacted config path."
        case AppVerifyCommandError.configDecodeFailed:
            return "App verification live configuration failed: malformed JSON in redacted config path."
        default:
            return "App verification live configuration failed: \(sanitizeDiagnostic(String(describing: error)))."
        }
    }

    static func sanitizeDiagnostic(_ value: String) -> String {
        MonitorError.redactedSourceDescription(value)
    }

    private static func summaryVerb(for status: AppVerifyEvidenceStatus) -> String {
        switch status {
        case .pass:
            return "passed"
        case .warn:
            return "warned"
        case .fail:
            return "failed"
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
        try AppVerifyCommandSupport.encodeEvidence(evidence)
    }

    func writeEvidence(_ data: Data, toPath path: String) throws {
        try AppVerifyCommandSupport.writeEvidence(data, toPath: path)
    }

    func summaryLine(for evidence: AppVerifyEvidence) -> String {
        AppVerifyCommandSupport.summaryLine(for: evidence)
    }

    private func outputFailureMessage(_ error: any Error) -> String {
        AppVerifyCommandSupport.outputFailureMessage(error)
    }
}

struct AppVerifyLiveCommandAdapter: Sendable {
    typealias ConfigReader = @Sendable (_ path: String) throws -> Data
    typealias RunnerFactory = @Sendable (_ configuration: AppVerifyLiveRunner.Configuration) -> AppVerifyLiveRunning
    typealias OutputWriter = @Sendable (_ message: String) -> Void

    var configReader: ConfigReader
    var runnerFactory: RunnerFactory
    var standardOutput: OutputWriter
    var standardError: OutputWriter

    init(
        configReader: @escaping ConfigReader = { path in
            do {
                return try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw AppVerifyCommandError.configReadFailed
            }
        },
        runnerFactory: @escaping RunnerFactory = { configuration in
            AppVerifyLiveRunner(configuration: configuration)
        },
        standardOutput: @escaping OutputWriter = { message in
            FileHandle.standardOutput.write(Data((message + "\n").utf8))
        },
        standardError: @escaping OutputWriter = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    ) {
        self.configReader = configReader
        self.runnerFactory = runnerFactory
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    func run(configPath: String, jsonPath: String) async -> ExitCode {
        let configuration: AppVerifyLiveConfiguration
        do {
            let data = try configReader(configPath)
            configuration = try decodeConfiguration(data)
        } catch {
            standardError(AppVerifyCommandSupport.configFailureMessage(error))
            return .failure
        }

        let runnerConfiguration = AppVerifyLiveRunner.Configuration(
            liveConfiguration: configuration,
            configPath: configPath
        )
        let evidence = await runnerFactory(runnerConfiguration).run()

        do {
            let data = try AppVerifyCommandSupport.encodeEvidence(evidence)
            try AppVerifyCommandSupport.writeEvidence(data, toPath: jsonPath)
        } catch {
            standardError(AppVerifyCommandSupport.outputFailureMessage(error))
            return .failure
        }

        standardOutput(AppVerifyCommandSupport.summaryLine(for: evidence))
        return evidence.summary.status == .fail ? .failure : .success
    }

    private func decodeConfiguration(_ data: Data) throws -> AppVerifyLiveConfiguration {
        do {
            return try JSONDecoder().decode(AppVerifyLiveConfiguration.self, from: data)
        } catch let error as AppVerifyLiveConfigurationError {
            throw error
        } catch {
            throw AppVerifyCommandError.configDecodeFailed
        }
    }
}

protocol AppVerifyLiveRunning: Sendable {
    func run() async -> AppVerifyEvidence
}

extension AppVerifyLiveRunner: AppVerifyLiveRunning {}

enum AppVerifyCommandError: Error, Equatable {
    case outputFailed
    case configReadFailed
    case configDecodeFailed
}
