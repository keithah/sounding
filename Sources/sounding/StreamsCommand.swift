import ArgumentParser
import Foundation
import SoundingKit

struct StreamsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "streams",
        abstract: "Manage named streams in a Sounding SQLite database.",
        subcommands: [Add.self, List.self, Status.self, Pause.self, Resume.self, Remove.self]
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a named stream to the Sounding SQLite database."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to open or create.")
        var db: String

        @Argument(help: "Unique stream name.")
        var name: String

        @Argument(help: "Stream source URL or local path. CLI output and reports use a redacted description; registry persistence keeps reconnect data.")
        var source: String

        @Option(
            name: .long, help: "Stream type hint, such as hls, icecast, icy, mpegts, udp, or file.")
        var streamType = "hls"

        mutating func validate() throws {
            do {
                try StreamsCommand.validateNonEmpty(name, label: "name")
                try StreamsCommand.validateNonEmpty(source, label: "source")
                try StreamsCommand.validateNonEmpty(streamType, label: "stream-type")
            } catch let error as StreamsCommandError {
                throw ValidationError(error.description)
            }
        }

        mutating func run() async throws {
            do {
                try StreamsCommand.validateNonEmpty(name, label: "name")
                try StreamsCommand.validateNonEmpty(source, label: "source")
                try StreamsCommand.validateNonEmpty(streamType, label: "stream-type")
                let registry = try StreamsCommand.registry(dbPath: db)
                let record = try registry.add(name: name, streamType: streamType, source: source)
                try StreamsCommand.writeStandardOutput(StreamsOutput.formatAddHuman(record))
            } catch let error as StreamsCommandError {
                StreamsCommand.writeStandardError(error.description)
                throw ExitCode.failure
            } catch let error as StreamRegistryError {
                StreamsCommand.writeStandardError(StreamsCommandError.registry(error).description)
                throw ExitCode.failure
            } catch let error as StreamsOutput.OutputError {
                StreamsCommand.writeStandardError(
                    StreamsCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch {
                StreamsCommand.writeStandardError(
                    StreamsCommandError.operationFailed(reason: String(describing: error))
                        .description)
                throw ExitCode.failure
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List named streams from the Sounding SQLite database."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to read.")
        var db: String

        @Flag(name: .long, help: "Emit stream lifecycle records as stable JSON.")
        var json = false

        @Flag(name: .long, help: "Include soft-removed streams in results.")
        var includeRemoved = false

        mutating func run() async throws {
            do {
                let registry = try StreamsCommand.registry(dbPath: db)
                let records = try registry.list(includeRemoved: includeRemoved)
                if json {
                    try StreamsCommand.writeStandardOutput(try StreamsOutput.encodeJSON(records))
                } else {
                    try StreamsCommand.writeStandardOutput(StreamsOutput.formatListHuman(records))
                }
            } catch let error as StreamsCommandError {
                StreamsCommand.writeStandardError(error.description)
                throw ExitCode.failure
            } catch let error as StreamRegistryError {
                StreamsCommand.writeStandardError(StreamsCommandError.registry(error).description)
                throw ExitCode.failure
            } catch let error as StreamsOutput.OutputError {
                StreamsCommand.writeStandardError(
                    StreamsCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch let error as EncodingError {
                StreamsCommand.writeStandardError(
                    StreamsCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch {
                StreamsCommand.writeStandardError(
                    StreamsCommandError.operationFailed(reason: String(describing: error))
                        .description)
                throw ExitCode.failure
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Inspect per-stream runtime reconnect and backoff status from the Sounding SQLite database."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to read.")
        var db: String

        @Flag(name: .long, help: "Emit stream runtime status records as stable JSON.")
        var json = false

        @Flag(name: .long, help: "Include soft-removed streams in results.")
        var includeRemoved = false

        mutating func run() async throws {
            do {
                let database = try StreamsCommand.database(dbPath: db)
                let records = try AppStreamRuntimeStatusStore(database: database)
                    .inspections(includeRemoved: includeRemoved)
                if json {
                    try StreamsCommand.writeStandardOutput(try StreamsOutput.encodeRuntimeStatusJSON(records))
                } else {
                    try StreamsCommand.writeStandardOutput(StreamsOutput.formatRuntimeStatusHuman(records))
                }
            } catch let error as StreamsCommandError {
                StreamsCommand.writeStandardError(error.description)
                throw ExitCode.failure
            } catch let error as AppStreamRuntimeStatusStoreError {
                StreamsCommand.writeStandardError(StreamsCommandError.runtimeStatus(error).description)
                throw ExitCode.failure
            } catch let error as StreamsOutput.OutputError {
                StreamsCommand.writeStandardError(
                    StreamsCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch let error as EncodingError {
                StreamsCommand.writeStandardError(
                    StreamsCommandError.outputFailed(reason: String(describing: error)).description)
                throw ExitCode.failure
            } catch {
                StreamsCommand.writeStandardError(
                    StreamsCommandError.operationFailed(reason: String(describing: error))
                        .description)
                throw ExitCode.failure
            }
        }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pause",
            abstract: "Pause a named stream by id. Pausing an already-paused stream is a no-op."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to update.")
        var db: String

        @Argument(help: "Stream id to pause.")
        var id: Int64

        mutating func validate() throws {
            do {
                try StreamsCommand.validateID(id)
            } catch let error as StreamsCommandError {
                throw ValidationError(error.description)
            }
        }

        mutating func run() async throws {
            try await StreamsCommand.runMutation(
                dbPath: db,
                id: id,
                action: "paused",
                mutate: { try $0.pause(id: $1) }
            )
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resume",
            abstract: "Resume a named stream by id. Resuming an already-active stream is a no-op."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to update.")
        var db: String

        @Argument(help: "Stream id to resume.")
        var id: Int64

        mutating func validate() throws {
            do {
                try StreamsCommand.validateID(id)
            } catch let error as StreamsCommandError {
                throw ValidationError(error.description)
            }
        }

        mutating func run() async throws {
            try await StreamsCommand.runMutation(
                dbPath: db,
                id: id,
                action: "resumed",
                mutate: { try $0.resume(id: $1) }
            )
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract:
                "Soft-remove a named stream by id. Removing an already-removed stream is a no-op."
        )

        @Option(name: .long, help: "Path to the Sounding SQLite database to update.")
        var db: String

        @Argument(help: "Stream id to remove.")
        var id: Int64

        mutating func validate() throws {
            do {
                try StreamsCommand.validateID(id)
            } catch let error as StreamsCommandError {
                throw ValidationError(error.description)
            }
        }

        mutating func run() async throws {
            try await StreamsCommand.runMutation(
                dbPath: db,
                id: id,
                action: "removed",
                mutate: { try $0.remove(id: $1) }
            )
        }
    }

    private static func runMutation(
        dbPath: String,
        id: Int64,
        action: String,
        mutate: (StreamRegistry, Int64) throws -> StreamMutationResult
    ) async throws {
        do {
            try validateID(id)
            let registry = try registry(dbPath: dbPath)
            let result = try mutate(registry, id)
            try writeStandardOutput(
                StreamsOutput.formatMutationHuman(action: action, result: result))
        } catch let error as StreamsCommandError {
            writeStandardError(error.description)
            throw ExitCode.failure
        } catch let error as StreamRegistryError {
            writeStandardError(StreamsCommandError.registry(error).description)
            throw ExitCode.failure
        } catch let error as StreamsOutput.OutputError {
            writeStandardError(
                StreamsCommandError.outputFailed(reason: String(describing: error)).description)
            throw ExitCode.failure
        } catch {
            writeStandardError(
                StreamsCommandError.operationFailed(reason: String(describing: error)).description)
            throw ExitCode.failure
        }
    }

    private static func registry(dbPath: String) throws -> StreamRegistry {
        StreamRegistry(database: try database(dbPath: dbPath))
    }

    private static func database(dbPath: String) throws -> SoundingDatabase {
        do {
            return try SoundingDatabase(fileURL: URL(fileURLWithPath: dbPath))
        } catch {
            throw StreamsCommandError.databaseOpenFailed
        }
    }

    private static func validateNonEmpty(_ value: String, label: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StreamsCommandError.configuration(reason: "\(label) must not be empty")
        }
    }

    private static func validateID(_ id: Int64) throws {
        if id <= 0 {
            throw StreamsCommandError.configuration(reason: "stream id must be greater than zero")
        }
    }

    private static func writeStandardOutput(_ text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw StreamsOutput.OutputError.encodingFailed
        }
        FileHandle.standardOutput.write(data)
    }

    private static func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private enum StreamsCommandError: Error, CustomStringConvertible {
    case configuration(reason: String)
    case databaseOpenFailed
    case registry(StreamRegistryError)
    case runtimeStatus(AppStreamRuntimeStatusStoreError)
    case operationFailed(reason: String)
    case outputFailed(reason: String)

    var description: String {
        switch self {
        case .configuration(let reason):
            return "Streams configuration failed: \(redact(reason))."
        case .databaseOpenFailed:
            return "Streams database failed: could not open redacted database path."
        case .registry(let error):
            return registryDescription(error)
        case .runtimeStatus(let error):
            return runtimeStatusDescription(error)
        case .operationFailed(let reason):
            return "Streams operation failed: \(redact(reason))."
        case .outputFailed:
            return "Streams output failed: [redacted-output-error]."
        }
    }

    private func registryDescription(_ error: StreamRegistryError) -> String {
        switch error {
        case .invalidID:
            return "Streams configuration failed: stream id must be greater than zero."
        case .invalidName:
            return "Streams configuration failed: name must not be empty."
        case .invalidSource:
            return "Streams configuration failed: source must not be empty."
        case .invalidStreamType:
            return "Streams configuration failed: stream-type must not be empty."
        case .invalidStatus(let status):
            return "Streams database failed: invalid stream status \(redact(status))."
        case .duplicateName:
            return "Streams state failed: duplicate active stream name."
        case .streamNotFound:
            return "Streams state failed: stream reference was not found."
        case .streamRemoved:
            return "Streams state failed: removed streams cannot be resumed or paused."
        case .databaseReadFailed(let message):
            return "Streams database failed: \(redact(message))."
        case .databaseWriteFailed(let message):
            return "Streams database failed: \(redact(message))."
        }
    }

    private func runtimeStatusDescription(_ error: AppStreamRuntimeStatusStoreError) -> String {
        switch error {
        case .invalidStreamID:
            return "Streams runtime status failed: stream id must be greater than zero."
        case .streamNotFound:
            return "Streams runtime status failed: stream reference was not found."
        case .databaseReadFailed(let message):
            return "Streams runtime status database failed: \(redact(message))."
        case .databaseWriteFailed(let message):
            return "Streams runtime status database failed: \(redact(message))."
        }
    }

    private func redact(_ value: String) -> String {
        MonitorError.redactedSourceDescription(value)
    }
}
