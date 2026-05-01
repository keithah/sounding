import ArgumentParser
import Foundation
import SoundingKit

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search persisted transcript segments in a Sounding SQLite database."
    )

    @Argument(help: "Literal phrase to search for in persisted transcript text.")
    var phrase: String

    @Option(name: .long, help: "Path to the Sounding SQLite database to read.")
    var db: String

    @Flag(name: .long, help: "Emit search results as stable JSON.")
    var json = false

    @Option(name: .long, help: "Maximum matching transcript segments to print.")
    var limit = 20

    @Option(
        name: .long,
        help: "Number of neighboring transcript segments to include before and after each match.")
    var context = 0

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
                TranscriptCommandError.databaseOpenFailed(command: "Search").description)
            throw ExitCode.failure
        }

        do {
            let results = try TranscriptQuery(database: database).search(
                phrase: phrase,
                limit: limit,
                contextSegments: context
            )
            if json {
                print(try TranscriptOutput.encodeSearchJSON(results), terminator: "")
            } else {
                print(TranscriptOutput.formatSearchHuman(results), terminator: "")
            }
        } catch let error as TranscriptQuery.QueryError {
            standardErrorWrite(
                TranscriptCommandError.queryFailed(
                    command: "Search", reason: error.localizedDescription
                ).description)
            throw ExitCode.failure
        } catch let error as EncodingError {
            standardErrorWrite(
                TranscriptCommandError.outputFailed(
                    command: "Search", reason: String(describing: error)
                ).description)
            throw ExitCode.failure
        } catch {
            standardErrorWrite(
                TranscriptCommandError.queryFailed(
                    command: "Search", reason: String(describing: error)
                ).description)
            throw ExitCode.failure
        }
    }

    private func validateInputs() throws {
        guard !phrase.split(whereSeparator: { $0.isWhitespace }).isEmpty else {
            throw TranscriptCommandError.configuration(
                command: "Search", reason: "phrase must not be empty")
        }
        guard limit > 0 else {
            throw TranscriptCommandError.configuration(
                command: "Search", reason: "limit must be greater than zero")
        }
        guard context >= 0 else {
            throw TranscriptCommandError.configuration(
                command: "Search", reason: "context must not be negative")
        }
    }

    private func standardErrorWrite(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
