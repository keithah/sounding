import ArgumentParser
import Foundation
import SoundingKit

struct MonitorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Monitor a media source for semantic ad markers."
    )

    @Argument(help: "Media source to monitor, such as a fixture path or stream URL.")
    var source: String

    @Option(name: .long, help: "Stream type hint: auto, hls, icecast, icy, mpegts, or udp.")
    var streamType: StreamTypeArgument = .auto

    @Option(name: .long, help: "Marker filter: all, ad, ad_start, ad_end, unknown, scte35, id3, or icy.")
    var filter = "all"

    @Flag(name: .long, help: "Emit marker JSON to standard output.")
    var json = false

    @Option(name: .long, help: "Write marker JSON lines to the provided path.")
    var jsonOut: String?

    @Flag(name: .long, help: "Suppress non-essential monitor output.")
    var quiet = false

    @Option(name: .long, help: "Stop monitoring after the provided number of seconds.")
    var timeout: Double?

    mutating func validate() throws {
        do {
            _ = try makeOptions()
        } catch let error as MonitorError {
            throw ValidationError(error.description)
        }
    }

    mutating func run() async throws {
        let options = try makeOptions()

        do {
            let markers = try await MonitorPipeline.run(options: options)
            try emit(markers)
        } catch let error as MonitorError {
            standardErrorWrite(error.description)
            throw ExitCode.failure
        }
    }

    private func makeOptions() throws -> MonitorOptions {
        try MonitorOptions(
            source: source,
            streamType: streamType.value,
            filter: filter,
            jsonOut: jsonOut,
            timeoutSeconds: timeout,
            quiet: quiet,
            emitJSON: json
        )
    }

    private func emit(_ markers: [AdMarker]) throws {
        guard json || jsonOut != nil else {
            return
        }

        let encoder = JSONEncoder()
        let lines = try markers.map { marker in
            String(decoding: try encoder.encode(marker), as: UTF8.self)
        }
        let payload = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")

        if json {
            print(payload, terminator: "")
        }

        if let jsonOut {
            try payload.write(toFile: jsonOut, atomically: true, encoding: .utf8)
        }
    }

    private func standardErrorWrite(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

struct StreamTypeArgument: ExpressibleByArgument, Equatable {
    static let auto = StreamTypeArgument(value: .auto)

    let value: StreamType

    init(value: StreamType) {
        self.value = value
    }

    init?(argument: String) {
        guard let value = StreamType(rawValue: argument.lowercased()) else {
            return nil
        }

        self.value = value
    }
}
