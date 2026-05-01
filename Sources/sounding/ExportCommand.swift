import ArgumentParser
import Foundation
import SoundingKit

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export persisted Sounding timeline data.",
        subcommands: [Transcripts.self, Markers.self, Report.self]
    )

    struct Transcripts: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "transcripts",
            abstract: "Export transcript segments and words from a Sounding SQLite database."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to read.")
        var db: String

        @Option(name: .long, help: "Export format: text or json.")
        var format = "text"

        @Option(name: .long, help: "Write export bytes atomically to this file instead of stdout.")
        var output: String?

        @Option(
            name: .long,
            help: "Filter by stream id, managed stream name, stream type, or exact stream source.")
        var stream: String?

        @Option(name: .long, help: "Include segments whose end time is at or after this second.")
        var startSeconds: Double?

        @Option(name: .long, help: "Include segments whose start time is at or before this second.")
        var endSeconds: Double?

        mutating func validate() throws {
            do {
                _ = try validateInputs(format: format, stream: stream, startSeconds: startSeconds, endSeconds: endSeconds)
            } catch let error as ExportCommandError {
                throw ValidationError(error.description)
            }
        }

        mutating func run() async throws {
            let inputs: ValidatedInputs
            do {
                inputs = try validateInputs(format: format, stream: stream, startSeconds: startSeconds, endSeconds: endSeconds)
            } catch let error as ExportCommandError {
                ExportCommand.writeStandardError(error.description)
                throw ExitCode.failure
            }

            let database: SoundingDatabase
            do {
                database = try SoundingDatabase(fileURL: URL(fileURLWithPath: db))
            } catch {
                ExportCommand.writeStandardError(ExportCommandError.databaseOpenFailed.description)
                throw ExitCode.failure
            }

            do {
                let rows = try TranscriptExportQuery(database: database).segments(filter: inputs.filter)
                let payload: String
                switch inputs.format {
                case .text:
                    payload = try ExportOutput.formatTranscriptsHuman(rows)
                case .json:
                    payload = try ExportOutput.encodeTranscriptsJSON(rows)
                }
                try ExportCommand.write(payload, to: output)
            } catch let error as SongReportQuery.QueryError {
                ExportCommand.writeStandardError(
                    ExportCommandError.queryFailed(reason: error.localizedDescription).description)
                throw ExitCode.failure
            } catch let error as TranscriptQuery.QueryError {
                ExportCommand.writeStandardError(
                    ExportCommandError.queryFailed(reason: error.localizedDescription).description)
                throw ExitCode.failure
            } catch let error as ReportOutput.OutputError {
                ExportCommand.writeStandardError(
                    ExportCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch let error as EncodingError {
                ExportCommand.writeStandardError(
                    ExportCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch let error as ExportCommandError {
                ExportCommand.writeStandardError(error.description)
                throw ExitCode.failure
            } catch {
                ExportCommand.writeStandardError(
                    ExportCommandError.queryFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            }
        }
    }

    struct Markers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "markers",
            abstract: "Export ad marker events from a Sounding SQLite database."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to read.")
        var db: String

        @Option(name: .long, help: "Export format: text or json.")
        var format = "text"

        @Option(name: .long, help: "Write export bytes atomically to this file instead of stdout.")
        var output: String?

        @Option(
            name: .long,
            help: "Filter by stream id, managed stream name, stream type, or exact stream source.")
        var stream: String?

        @Option(name: .long, help: "Include ad events whose PTS is at or after this second.")
        var startSeconds: Double?

        @Option(name: .long, help: "Include ad events whose PTS is at or before this second.")
        var endSeconds: Double?

        mutating func validate() throws {
            do {
                _ = try validateInputs(format: format, stream: stream, startSeconds: startSeconds, endSeconds: endSeconds)
            } catch let error as ExportCommandError {
                throw ValidationError(error.description)
            }
        }

        mutating func run() async throws {
            let inputs: ValidatedInputs
            do {
                inputs = try validateInputs(format: format, stream: stream, startSeconds: startSeconds, endSeconds: endSeconds)
            } catch let error as ExportCommandError {
                ExportCommand.writeStandardError(error.description)
                throw ExitCode.failure
            }

            let database: SoundingDatabase
            do {
                database = try SoundingDatabase(fileURL: URL(fileURLWithPath: db))
            } catch {
                ExportCommand.writeStandardError(ExportCommandError.databaseOpenFailed.description)
                throw ExitCode.failure
            }

            do {
                let result = try AdReportQuery(database: database).events(filter: inputs.filter)
                let payload: String
                switch inputs.format {
                case .text:
                    payload = try ExportOutput.formatMarkersHuman(result)
                case .json:
                    payload = try ExportOutput.encodeMarkersJSON(result)
                }
                try ExportCommand.write(payload, to: output)
            } catch let error as AdReportQuery.QueryError {
                ExportCommand.writeStandardError(
                    ExportCommandError.queryFailed(reason: error.localizedDescription).description)
                throw ExitCode.failure
            } catch let error as ReportOutput.OutputError {
                ExportCommand.writeStandardError(
                    ExportCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch let error as EncodingError {
                ExportCommand.writeStandardError(
                    ExportCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch let error as ExportCommandError {
                ExportCommand.writeStandardError(error.description)
                throw ExitCode.failure
            } catch {
                ExportCommand.writeStandardError(
                    ExportCommandError.queryFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            }
        }
    }

    struct Report: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "report",
            abstract: "Export report data from a Sounding SQLite database."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to read.")
        var db: String

        @Option(name: .long, help: "Report kind: plays, repeats, or ads.")
        var kind = "plays"

        @Option(name: .long, help: "Export format: text or json.")
        var format = "text"

        @Option(name: .long, help: "Write export bytes atomically to this file instead of stdout.")
        var output: String?

        @Option(
            name: .long,
            help: "Filter by stream id, managed stream name, stream type, or exact stream source.")
        var stream: String?

        @Option(name: .long, help: "Include report rows whose end time/PTS is at or after this second.")
        var startSeconds: Double?

        @Option(name: .long, help: "Include report rows whose start time/PTS is at or before this second.")
        var endSeconds: Double?

        mutating func validate() throws {
            do {
                _ = try validateInputs(
                    format: format,
                    kind: kind,
                    stream: stream,
                    startSeconds: startSeconds,
                    endSeconds: endSeconds)
            } catch let error as ExportCommandError {
                throw ValidationError(error.description)
            }
        }

        mutating func run() async throws {
            let inputs: ValidatedInputs
            do {
                inputs = try validateInputs(
                    format: format,
                    kind: kind,
                    stream: stream,
                    startSeconds: startSeconds,
                    endSeconds: endSeconds)
            } catch let error as ExportCommandError {
                ExportCommand.writeStandardError(error.description)
                throw ExitCode.failure
            }

            let database: SoundingDatabase
            do {
                database = try SoundingDatabase(fileURL: URL(fileURLWithPath: db))
            } catch {
                ExportCommand.writeStandardError(ExportCommandError.databaseOpenFailed.description)
                throw ExitCode.failure
            }

            do {
                let payload: String
                switch inputs.kind {
                case .plays:
                    let results = try SongReportQuery(database: database).plays(filter: inputs.filter)
                    payload = inputs.format == .json
                        ? try ExportOutput.encodeReportPlaysJSON(results)
                        : ExportOutput.formatReportPlaysHuman(results)
                case .repeats:
                    let results = try SongReportQuery(database: database).repeats(filter: inputs.filter)
                    payload = inputs.format == .json
                        ? try ExportOutput.encodeReportRepeatsJSON(results)
                        : try ExportOutput.formatReportRepeatsHuman(results)
                case .ads:
                    let result = try AdReportQuery(database: database).events(filter: inputs.filter)
                    payload = inputs.format == .json
                        ? try ExportOutput.encodeReportAdsJSON(result)
                        : try ExportOutput.formatReportAdsHuman(result)
                }
                try ExportCommand.write(payload, to: output)
            } catch let error as SongReportQuery.QueryError {
                ExportCommand.writeStandardError(
                    ExportCommandError.queryFailed(reason: error.localizedDescription).description)
                throw ExitCode.failure
            } catch let error as ReportOutput.OutputError {
                ExportCommand.writeStandardError(
                    ExportCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch let error as EncodingError {
                ExportCommand.writeStandardError(
                    ExportCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch let error as ExportCommandError {
                ExportCommand.writeStandardError(error.description)
                throw ExitCode.failure
            } catch {
                ExportCommand.writeStandardError(
                    ExportCommandError.queryFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            }
        }
    }

    fileprivate enum Format {
        case text
        case json
    }

    fileprivate enum ReportKind {
        case plays
        case repeats
        case ads
    }

    fileprivate struct ValidatedInputs {
        var format: Format
        var kind: ReportKind
        var filter: SongReportQuery.Filter
    }

    fileprivate static func validateInputs(
        format rawFormat: String,
        kind rawKind: String = "plays",
        stream: String?,
        startSeconds: Double?,
        endSeconds: Double?
    ) throws -> ValidatedInputs {
        let format: Format
        switch rawFormat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "text": format = .text
        case "json": format = .json
        default:
            throw ExportCommandError.configuration(reason: "format must be text or json")
        }

        let kind: ReportKind
        switch rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "plays": kind = .plays
        case "repeats": kind = .repeats
        case "ads": kind = .ads
        default:
            throw ExportCommandError.configuration(reason: "kind must be plays, repeats, or ads")
        }

        let normalizedStream = stream?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedStream, normalizedStream.isEmpty {
            throw ExportCommandError.configuration(reason: "stream filter must not be empty")
        }
        if let startSeconds, !startSeconds.isFinite {
            throw ExportCommandError.configuration(reason: "start-seconds must be finite")
        }
        if let endSeconds, !endSeconds.isFinite {
            throw ExportCommandError.configuration(reason: "end-seconds must be finite")
        }
        if let startSeconds, let endSeconds, startSeconds > endSeconds {
            throw ExportCommandError.configuration(
                reason: "start-seconds must be less than or equal to end-seconds")
        }

        return ValidatedInputs(
            format: format,
            kind: kind,
            filter: SongReportQuery.Filter(
                stream: normalizedStream,
                startSeconds: startSeconds,
                endSeconds: endSeconds
            )
        )
    }

    fileprivate static func write(_ payload: String, to output: String?) throws {
        let data = Data(payload.utf8)
        guard let output else {
            FileHandle.standardOutput.write(data)
            return
        }

        do {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        } catch {
            throw ExportCommandError.outputFailed(reason: String(describing: error))
        }
    }

    fileprivate static func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private enum ExportCommandError: Error, CustomStringConvertible {
    case configuration(reason: String)
    case databaseOpenFailed
    case queryFailed(reason: String)
    case outputFailed(reason: String)

    var description: String {
        switch self {
        case .configuration(let reason):
            return "Export configuration failed: \(MonitorError.redactedSourceDescription(reason))."
        case .databaseOpenFailed:
            return "Export database failed: could not open redacted database path."
        case .queryFailed(let reason):
            return "Export query failed: \(MonitorError.redactedSourceDescription(reason))."
        case .outputFailed:
            return "Export output failed: [redacted-output-error]."
        }
    }
}
