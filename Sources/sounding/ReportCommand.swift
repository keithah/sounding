import ArgumentParser
import Foundation
import SoundingKit

struct ReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Report persisted Sounding database state.",
        subcommands: [PlaysCommand.self]
    )

    struct PlaysCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "plays",
            abstract: "Report persisted song plays from a Sounding SQLite database."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to read.")
        var db: String

        @Flag(name: .long, help: "Emit song play results as stable JSON.")
        var json = false

        @Option(name: .long, help: "Filter by stream id, stream type, or exact stream source.")
        var stream: String?

        @Option(name: .long, help: "Include plays whose end time is at or after this second.")
        var startSeconds: Double?

        @Option(name: .long, help: "Include plays whose start time is at or before this second.")
        var endSeconds: Double?

        mutating func validate() throws {
            do {
                _ = try validateInputs()
            } catch let error as ReportCommandError {
                throw ValidationError(error.description)
            }
        }

        mutating func run() async throws {
            let filter: SongReportQuery.Filter
            do {
                filter = try validateInputs()
            } catch let error as ReportCommandError {
                standardErrorWrite(error.description)
                throw ExitCode.failure
            }

            let database: SoundingDatabase
            do {
                database = try SoundingDatabase(fileURL: URL(fileURLWithPath: db))
            } catch {
                standardErrorWrite(ReportCommandError.databaseOpenFailed.description)
                throw ExitCode.failure
            }

            do {
                let results = try SongReportQuery(database: database).plays(filter: filter)
                if json {
                    print(try ReportOutput.encodePlaysJSON(results), terminator: "")
                } else {
                    print(ReportOutput.formatPlaysHuman(results), terminator: "")
                }
            } catch let error as SongReportQuery.QueryError {
                standardErrorWrite(
                    ReportCommandError.queryFailed(reason: error.localizedDescription).description)
                throw ExitCode.failure
            } catch let error as ReportOutput.OutputError {
                standardErrorWrite(
                    ReportCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch let error as EncodingError {
                standardErrorWrite(
                    ReportCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch {
                standardErrorWrite(
                    ReportCommandError.queryFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            }
        }

        private func validateInputs() throws -> SongReportQuery.Filter {
            let normalizedStream = stream?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedStream, normalizedStream.isEmpty {
                throw ReportCommandError.configuration(reason: "stream filter must not be empty")
            }
            if let startSeconds, !startSeconds.isFinite {
                throw ReportCommandError.configuration(reason: "start-seconds must be finite")
            }
            if let endSeconds, !endSeconds.isFinite {
                throw ReportCommandError.configuration(reason: "end-seconds must be finite")
            }
            if let startSeconds, let endSeconds, startSeconds > endSeconds {
                throw ReportCommandError.configuration(
                    reason: "start-seconds must be less than or equal to end-seconds")
            }
            return SongReportQuery.Filter(
                stream: normalizedStream,
                startSeconds: startSeconds,
                endSeconds: endSeconds
            )
        }

        private func standardErrorWrite(_ message: String) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }
}

private enum ReportCommandError: Error, CustomStringConvertible {
    case configuration(reason: String)
    case databaseOpenFailed
    case queryFailed(reason: String)
    case outputFailed(reason: String)

    var description: String {
        switch self {
        case .configuration(let reason):
            return "Report configuration failed: \(MonitorError.redactedSourceDescription(reason))."
        case .databaseOpenFailed:
            return "Report database failed: could not open redacted database path."
        case .queryFailed(let reason):
            return "Report query failed: \(MonitorError.redactedSourceDescription(reason))."
        case .outputFailed:
            return "Report output failed: [redacted-output-error]."
        }
    }
}
