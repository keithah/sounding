import ArgumentParser
import Foundation
import SoundingKit

struct AppDiagnosticsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-diagnostics",
        abstract: "Summarize Sounding.app local runtime event and failure logs."
    )

    @Option(name: .long, help: "Directory containing runtime-events.jsonl and runtime-errors.jsonl.")
    var logDirectory: String?

    @Option(name: .long, help: "Number of recent entries to print from each log.")
    var tail: Int = 40

    @Flag(name: .long, help: "Print raw JSONL entries instead of a compact summary.")
    var raw = false

    mutating func run() throws {
        let directory = resolvedLogDirectory()
        let eventURL = directory.appendingPathComponent("runtime-events.jsonl")
        let failureURL = directory.appendingPathComponent("runtime-errors.jsonl")
        let events = readEntries(from: eventURL)
        let failures = readEntries(from: failureURL)

        print("app-diagnostics logDirectory=\(directory.path)")
        print("app-diagnostics events=\(events.count) failures=\(failures.count)")
        printEventCounts(events)
        printPhaseCounts(events)
        print("app-diagnostics recent-events")
        printRecent(events, limit: tail)
        print("app-diagnostics recent-failures")
        printRecent(failures, limit: tail)
    }

    private func resolvedLogDirectory() -> URL {
        if let logDirectory, !logDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: logDirectory, isDirectory: true)
        }
        return AppRuntimeDiagnosticsLog.defaultLogDirectory()
    }

    private func readEntries(from url: URL) -> [RuntimeLogEntry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RuntimeLogEntry.self, from: lineData)
        }
    }

    private func printEventCounts(_ entries: [RuntimeLogEntry]) {
        print("app-diagnostics event-counts")
        for (event, count) in counted(entries.map(\.event)).prefix(20) {
            print("  \(event)=\(count)")
        }
    }

    private func printPhaseCounts(_ entries: [RuntimeLogEntry]) {
        print("app-diagnostics phase-counts")
        for (phase, count) in counted(entries.compactMap(\.phase)).prefix(20) {
            print("  \(phase)=\(count)")
        }
    }

    private func counted(_ values: [String]) -> [(String, Int)] {
        Dictionary(grouping: values, by: { $0 })
            .map { ($0.key, $0.value.count) }
            .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1 }
    }

    private func printRecent(_ entries: [RuntimeLogEntry], limit: Int) {
        let boundedLimit = min(max(limit, 0), 500)
        for entry in entries.suffix(boundedLimit) {
            if raw {
                if let data = try? JSONEncoder.sorted.encode(entry),
                   let json = String(data: data, encoding: .utf8)
                {
                    print(json)
                }
            } else {
                let stream = entry.streamID.map { " stream=\($0)" } ?? ""
                let phase = entry.phase.map { " phase=\($0)" } ?? ""
                let message = entry.message.map { " message=\($0)" } ?? ""
                let fields = entry.fields.isEmpty
                    ? ""
                    : " fields=" + entry.fields.sorted { $0.key < $1.key }
                        .map { "\($0.key):\($0.value)" }
                        .joined(separator: ",")
                print("  \(entry.timestamp) level=\(entry.level) event=\(entry.event)\(stream)\(phase)\(message)\(fields)")
            }
        }
    }
}

private struct RuntimeLogEntry: Codable {
    var timestamp: String
    var level: String
    var event: String
    var streamID: Int64?
    var streamName: String?
    var source: String?
    var phase: String?
    var errorType: String?
    var message: String?
    var fields: [String: String]
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
