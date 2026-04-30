import ArgumentParser
import SoundingKit

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
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
