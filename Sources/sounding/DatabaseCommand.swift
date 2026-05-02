import ArgumentParser
import Foundation
import SoundingKit

struct DatabaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "database",
        abstract: "Inspect and maintain the Sounding SQLite database.",
        subcommands: [Health.self, Checkpoint.self]
    )

    struct Health: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "health",
            abstract: "Inspect WAL, file, and SQLite check health for the Sounding database."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to inspect.")
        var db: String

        @Flag(name: .long, help: "Emit stable redacted JSON.")
        var json = false

        @Option(name: .long, help: "SQLite check depth: quick or integrity.")
        var checkDepth: DatabaseCheckDepth = .quick

        mutating func run() async throws {
            let health = SoundingDatabase.health(
                fileURL: URL(fileURLWithPath: db),
                includeIntegrityCheck: checkDepth == .integrity
            )
            let body = try DatabaseOutput.formatOrEncodeHealth(
                health: health,
                checkDepth: checkDepth,
                json: json
            )
            if health.status == .unhealthy {
                if json {
                    DatabaseCommand.writeStandardError(body, terminator: "")
                } else {
                    DatabaseCommand.writeStandardError(DatabaseOutput.formatHealthFailurePrefix(command: "health"))
                    DatabaseCommand.writeStandardError(body, terminator: "")
                }
                throw ExitCode.failure
            }
            try DatabaseCommand.writeStandardOutput(body)
        }
    }

    struct Checkpoint: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "checkpoint",
            abstract: "Run a constrained WAL checkpoint and print redacted database diagnostics."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to checkpoint.")
        var db: String

        @Flag(name: .long, help: "Emit stable redacted JSON.")
        var json = false

        @Option(name: .long, help: "Checkpoint mode: passive, full, restart, or truncate.")
        var mode: DatabaseCheckpointModeArgument = .passive

        @Option(name: .long, help: "Post-checkpoint SQLite check depth: quick or integrity.")
        var checkDepth: DatabaseCheckDepth = .quick

        mutating func run() async throws {
            let fileURL = URL(fileURLWithPath: db)
            do {
                let database = try SoundingDatabase(fileURL: fileURL)
                let checkpoint = database.checkpoint(mode: mode.value)
                let health = database.health(includeIntegrityCheck: checkDepth == .integrity)
                let body = try DatabaseOutput.formatOrEncodeCheckpoint(
                    checkpoint: checkpoint,
                    health: health,
                    mode: mode.value,
                    checkDepth: checkDepth,
                    json: json
                )
                if checkpoint.status == .unhealthy || health.status == .unhealthy {
                    if json {
                        DatabaseCommand.writeStandardError(body, terminator: "")
                    } else {
                        DatabaseCommand.writeStandardError(DatabaseOutput.formatHealthFailurePrefix(command: "checkpoint"))
                        DatabaseCommand.writeStandardError(body, terminator: "")
                    }
                    throw ExitCode.failure
                }
                try DatabaseCommand.writeStandardOutput(body)
            } catch let error as DatabaseOutput.OutputError {
                DatabaseCommand.writeStandardError(DatabaseCommandError.outputFailed(error).description)
                throw ExitCode.failure
            } catch let error as ExitCode {
                throw error
            } catch {
                let health = SoundingDatabase.health(
                    fileURL: fileURL,
                    includeIntegrityCheck: checkDepth == .integrity
                )
                let body = try DatabaseOutput.formatOrEncodeCheckpoint(
                    checkpoint: nil,
                    health: health,
                    mode: mode.value,
                    checkDepth: checkDepth,
                    json: json
                )
                if json {
                    DatabaseCommand.writeStandardError(body, terminator: "")
                } else {
                    DatabaseCommand.writeStandardError(DatabaseOutput.formatHealthFailurePrefix(command: "checkpoint"))
                    DatabaseCommand.writeStandardError(body, terminator: "")
                }
                throw ExitCode.failure
            }
        }
    }

    fileprivate static func writeStandardOutput(_ text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw DatabaseOutput.OutputError.encodingFailed
        }
        FileHandle.standardOutput.write(data)
    }

    fileprivate static func writeStandardError(_ message: String, terminator: String = "\n") {
        FileHandle.standardError.write(Data((message + terminator).utf8))
    }
}

struct DatabaseCheckpointModeArgument: ExpressibleByArgument, Equatable {
    static let passive = DatabaseCheckpointModeArgument(value: .passive)

    let value: SoundingDatabaseCheckpointMode

    init(value: SoundingDatabaseCheckpointMode) {
        self.value = value
    }

    init?(argument: String) {
        guard let value = SoundingDatabaseCheckpointMode(rawValue: argument.lowercased()) else {
            return nil
        }
        self.value = value
    }
}

private enum DatabaseCommandError: Error, CustomStringConvertible {
    case outputFailed(DatabaseOutput.OutputError)

    var description: String {
        switch self {
        case .outputFailed:
            return "Database output failed: [redacted-output-error]."
        }
    }
}

extension DatabaseOutput {
    static func formatOrEncodeHealth(
        health: SoundingDatabaseHealth,
        checkDepth: DatabaseCheckDepth,
        json: Bool
    ) throws -> String {
        if json {
            return try encodeHealthJSON(health: health, checkDepth: checkDepth)
        }
        return formatHealthHuman(health: health, checkDepth: checkDepth)
    }

    static func formatOrEncodeCheckpoint(
        checkpoint: SoundingDatabaseCheckpointResult?,
        health: SoundingDatabaseHealth,
        mode: SoundingDatabaseCheckpointMode,
        checkDepth: DatabaseCheckDepth,
        json: Bool
    ) throws -> String {
        if json {
            return try encodeCheckpointJSON(
                checkpoint: checkpoint,
                health: health,
                mode: mode,
                checkDepth: checkDepth
            )
        }
        return formatCheckpointHuman(
            checkpoint: checkpoint,
            health: health,
            mode: mode,
            checkDepth: checkDepth
        )
    }
}
