import Foundation

/// Local, redacted diagnostic logs for app/runtime behavior that is hard to infer from screenshots.
///
/// Two JSONL files are written under `~/Library/Application Support/Sounding/` by default:
/// - `runtime-events.jsonl`: decision/state-change log for UI commands, runtime, decode, playback, volume, and stop/restart.
/// - `runtime-errors.jsonl`: failure-only compatibility log for quick inspection of broken streams.
///
/// Logging is best-effort and must never break runtime recovery or playback.
public struct AppRuntimeDiagnosticsLog: Sendable {
    private static let writerCache = AppRuntimeDiagnosticsWriterCache()

    public var eventLogURL: URL
    public var failureLogURL: URL
    public var now: @Sendable () -> String

    public init(
        eventLogURL: URL = AppRuntimeDiagnosticsLog.defaultEventLogURL(),
        failureLogURL: URL = AppRuntimeDiagnosticsLog.defaultFailureLogURL(),
        now: @escaping @Sendable () -> String = { AppRuntimeDiagnosticsLog.timestampNow() }
    ) {
        self.eventLogURL = eventLogURL
        self.failureLogURL = failureLogURL
        self.now = now
    }

    /// Compatibility initializer for older tests/callers that provided a single error log URL.
    public init(
        logURL: URL,
        now: @escaping @Sendable () -> String = { AppRuntimeDiagnosticsLog.timestampNow() }
    ) {
        self.eventLogURL = logURL.deletingLastPathComponent()
            .appendingPathComponent("runtime-events.jsonl")
        self.failureLogURL = logURL
        self.now = now
    }

    public static func defaultLogDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("SoundingTestDiagnostics", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sounding", isDirectory: true)
    }

    public static func defaultEventLogURL() -> URL {
        defaultLogDirectory().appendingPathComponent("runtime-events.jsonl")
    }

    public static func defaultFailureLogURL() -> URL {
        defaultLogDirectory().appendingPathComponent("runtime-errors.jsonl")
    }

    public static func defaultLogURL() -> URL {
        defaultFailureLogURL()
    }

    public static func timestampNow() -> String {
        SoundingTimestampClock.timestamp()
    }

    public static func closeCachedWriters() {
        writerCache.closeAll()
    }

    public func recordEvent(
        _ event: String,
        streamID: Int64? = nil,
        streamName: String? = nil,
        source: String? = nil,
        sourceDescription: String? = nil,
        phase: String? = nil,
        message: String? = nil,
        fields: [String: String] = [:]
    ) {
        let entry = Entry(
            timestamp: now(),
            level: "info",
            event: event,
            streamID: streamID,
            streamName: streamName.map(IngestRedaction.redact),
            source: redactedSource(source, fallback: sourceDescription),
            phase: phase.map(IngestRedaction.redact),
            errorType: nil,
            message: message.map(IngestRedaction.redact),
            fields: sanitize(fields)
        )
        append(entry, to: eventLogURL)
    }

    public func recordFailure(
        streamID: Int64,
        name: String,
        source: String,
        sourceDescription: String,
        phase: String,
        error: any Error,
        event: String = "runtime.failure",
        fields: [String: String] = [:]
    ) {
        let entry = Entry(
            timestamp: now(),
            level: "error",
            event: event,
            streamID: streamID,
            streamName: IngestRedaction.redact(name),
            source: redactedSource(source, fallback: sourceDescription),
            phase: IngestRedaction.redact(phase),
            errorType: String(describing: Swift.type(of: error)),
            message: IngestRedaction.redact(String(describing: error)),
            fields: sanitize(fields)
        )
        append(entry, to: eventLogURL)
        append(entry, to: failureLogURL)
    }

    private func redactedSource(_ source: String?, fallback: String?) -> String? {
        if let source {
            let redacted = IngestRedaction.sourceDescription(source)
            if !redacted.isEmpty { return redacted }
        }
        return fallback.map(IngestRedaction.redact)
    }

    private func sanitize(_ fields: [String: String]) -> [String: String] {
        fields.reduce(into: [:]) { partial, pair in
            partial[IngestRedaction.redact(pair.key)] = IngestRedaction.redact(pair.value)
        }
    }

    private func append(_ entry: Entry, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.sorted.encode(entry) + Data("\n".utf8)
            try Self.writerCache.write(data, to: url)
        } catch {
            // Logging must never break runtime recovery or user playback.
        }
    }

    private struct Entry: Codable, Sendable {
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
}

private final class AppRuntimeDiagnosticsWriterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var handlesByPath: [String: FileHandle] = [:]

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        let key = url.standardizedFileURL.path
        let handle: FileHandle
        if let cached = handlesByPath[key] {
            handle = cached
        } else {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: url)
            handlesByPath[key] = handle
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func closeAll() {
        lock.lock()
        let handles = Array(handlesByPath.values)
        handlesByPath.removeAll()
        lock.unlock()

        for handle in handles {
            try? handle.synchronize()
            try? handle.close()
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        SoundingJSONCoding.sortedEncoder()
    }
}
