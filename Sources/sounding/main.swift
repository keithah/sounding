import ArgumentParser
import SoundingKit

@main
struct SoundingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sounding",
        abstract: "Command line interface for \(SoundingKitVersion.current.name).",
        version: SoundingKitVersion.current.string,
        subcommands: [MonitorCommand.self]
    )

    mutating func run() async throws {
        print("\(SoundingKitVersion.current.name) \(SoundingKitVersion.current.string)")
    }
}
