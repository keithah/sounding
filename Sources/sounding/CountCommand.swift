import ArgumentParser
import Foundation
import SoundingKit

struct CountCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "count",
        abstract: "Count literal phrase occurrences in persisted transcript segments."
    )

    @Argument(help: "Literal phrase to count in persisted transcript text.")
    var phrase: String

    @Option(name: .long, help: "Path to the Sounding SQLite database to read.")
    var db: String

    @Flag(name: .long, help: "Emit count aggregates as stable JSON.")
    var json = false

    mutating func validate() throws {
        do {
            try validateInputs()
        } catch let error as TranscriptCommandError {
            throw ValidationError(error.description)
        }
    }

    mutating func run() async throws {
        do {
            try validateInputs()
        } catch let error as TranscriptCommandError {
            standardErrorWrite(error.description)
            throw ExitCode.failure
        }

        let database: SoundingDatabase
        do {
            database = try SoundingDatabase(fileURL: URL(fileURLWithPath: db))
        } catch {
            standardErrorWrite(
                TranscriptCommandError.databaseOpenFailed(command: "Count").description)
            throw ExitCode.failure
        }

        do {
            let results = try TranscriptQuery(database: database).count(phrase: phrase)
            if json {
                print(try TranscriptOutput.encodeCountJSON(results), terminator: "")
            } else {
                print(TranscriptOutput.formatCountHuman(results), terminator: "")
            }
        } catch let error as TranscriptQuery.QueryError {
            standardErrorWrite(
                TranscriptCommandError.queryFailed(
                    command: "Count", reason: error.localizedDescription
                ).description)
            throw ExitCode.failure
        } catch let error as EncodingError {
            standardErrorWrite(
                TranscriptCommandError.outputFailed(
                    command: "Count", reason: String(describing: error)
                ).description)
            throw ExitCode.failure
        } catch {
            standardErrorWrite(
                TranscriptCommandError.queryFailed(
                    command: "Count", reason: String(describing: error)
                ).description)
            throw ExitCode.failure
        }
    }

    private func validateInputs() throws {
        guard !phrase.split(whereSeparator: { $0.isWhitespace }).isEmpty else {
            throw TranscriptCommandError.configuration(
                command: "Count", reason: "phrase must not be empty")
        }
    }

    private func standardErrorWrite(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

enum TranscriptCommandError: Error, CustomStringConvertible {
    case configuration(command: String, reason: String)
    case databaseOpenFailed(command: String)
    case queryFailed(command: String, reason: String)
    case outputFailed(command: String, reason: String)

    var description: String {
        switch self {
        case .configuration(let command, let reason):
            return
                "\(command) configuration failed: \(MonitorError.redactedSourceDescription(reason))."
        case .databaseOpenFailed(let command):
            return "\(command) database failed: could not open redacted database path."
        case .queryFailed(let command, let reason):
            return "\(command) query failed: \(MonitorError.redactedSourceDescription(reason))."
        case .outputFailed(let command, _):
            return "\(command) output failed: [redacted-output-error]."
        }
    }
}
