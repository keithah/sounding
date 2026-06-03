import Foundation
import XCTest

@testable import SoundingKit

final class AppRuntimeDiagnosticsLogTests: XCTestCase {
    override func tearDown() {
        AppRuntimeDiagnosticsLog.closeCachedWriters()
        super.tearDown()
    }

    func testSharedCachedWritersFlushAndCloseDeterministicJSONLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-diagnostics-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventLogURL = directory.appendingPathComponent("runtime-events.jsonl")
        let failureLogURL = directory.appendingPathComponent("runtime-errors.jsonl")
        let first = AppRuntimeDiagnosticsLog(
            eventLogURL: eventLogURL,
            failureLogURL: failureLogURL,
            now: { "2026-05-01T18:00:00Z" }
        )
        let second = AppRuntimeDiagnosticsLog(
            eventLogURL: eventLogURL,
            failureLogURL: failureLogURL,
            now: { "2026-05-01T18:00:01Z" }
        )

        first.recordEvent(
            "runtime.started",
            streamID: 1,
            streamName: "Main",
            source: "https://user:pass@example.test/live.m3u8?token=secret#frag",
            phase: "runtime"
        )
        second.recordEvent("runtime.buffered", streamID: 1, phase: "runtime")
        first.recordFailure(
            streamID: 1,
            name: "Main",
            source: "https://user:pass@example.test/live.m3u8?token=secret#frag",
            sourceDescription: "https://example.test/live.m3u8",
            phase: "playback",
            error: DiagnosticsLogTestError()
        )

        AppRuntimeDiagnosticsLog.closeCachedWriters()

        let eventLines = try decodedJSONLines(at: eventLogURL)
        let failureLines = try decodedJSONLines(at: failureLogURL)
        XCTAssertEqual(eventLines.compactMap { $0["event"] as? String }, [
            "runtime.started",
            "runtime.buffered",
            "runtime.failure",
        ])
        XCTAssertEqual(failureLines.compactMap { $0["event"] as? String }, ["runtime.failure"])
        let joined = try String(contentsOf: eventLogURL) + String(contentsOf: failureLogURL)
        XCTAssertFalse(joined.contains("user:pass"), joined)
        XCTAssertFalse(joined.contains("token=secret"), joined)
        XCTAssertFalse(joined.contains("#frag"), joined)
    }

    private func decodedJSONLines(at url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url)
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                )
            }
    }
}

private struct DiagnosticsLogTestError: Error, CustomStringConvertible {
    var description: String { "diagnostic failure" }
}
