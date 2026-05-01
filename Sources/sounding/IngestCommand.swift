import ArgumentParser
import Foundation
import SoundingKit

struct IngestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Run bounded stream ingest into a Sounding SQLite database."
    )

    @Argument(help: "Media source URL or local fixture path to ingest.")
    var source: String

    @Option(name: .long, help: "Path to the Sounding SQLite database to open or create.")
    var db: String

    @Option(name: .long, help: "Stream type hint: auto, hls, icecast, icy, mpegts, or udp.")
    var streamType: StreamTypeArgument = .auto

    @Option(name: .long, help: "Stop ingest after this many seconds of decoded media.")
    var duration: Double?

    @Option(name: .long, help: "Stop ingest after this many decoded chunks.")
    var maxChunks: Int?

    mutating func validate() throws {
        do {
            try validateBounds()
        } catch let error as IngestCommandError {
            throw ValidationError(error.description)
        }
    }

    mutating func run() async throws {
        do {
            try validateBounds()
        } catch let error as IngestCommandError {
            standardErrorWrite(error.description)
            throw ExitCode.failure
        }

        let database: SoundingDatabase
        do {
            database = try SoundingDatabase(fileURL: URL(fileURLWithPath: db))
        } catch {
            standardErrorWrite(IngestCommandError.databaseOpenFailed.description)
            throw ExitCode.failure
        }

        let progressSink = CLIModelProgressSink()
        let cache = ModelCache(progressHandler: { progress in
            progressSink.emit(progress)
        })
        let pipeline = StreamIngestPipeline(
            database: database,
            decoder: AVFoundationAudioDecoder(),
            transcriber: WhisperKitTranscriber(cache: cache),
            diarizer: FluidAudioDiarizer(cache: cache)
        )

        do {
            let result = try await pipeline.run(
                source: source,
                streamType: streamType.value,
                durationSeconds: duration,
                maxChunks: maxChunks
            )
            if let setupDiagnostic = result.diagnostics.first(where: {
                $0.phase == .modelSetup && $0.severity == .error
            }) {
                standardErrorWrite(
                    "Ingest modelSetup failed: \(setupDiagnostic.reason). See persisted ingest_diagnostics for redacted run details."
                )
                throw ExitCode.failure
            }
            print(
                "ingest completed: stream=\(result.streamID) run=\(result.runID) chunks=\(result.processedChunks) diagnostics=\(result.diagnostics.count)"
            )
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            standardErrorWrite(diagnosticMessage(for: error))
            throw ExitCode.failure
        }
    }

    private func validateBounds() throws {
        guard duration != nil || maxChunks != nil else {
            throw IngestCommandError.configuration(
                "provide either duration or max-chunks before ingest can start")
        }
        if let duration, duration <= 0 || !duration.isFinite {
            throw IngestCommandError.configuration("duration must be greater than zero")
        }
        if let maxChunks, maxChunks <= 0 {
            throw IngestCommandError.configuration("max-chunks must be greater than zero")
        }
    }

    private func diagnosticMessage(for error: Error) -> String {
        if let diagnostic = error as? IngestDiagnosticError {
            return
                "Ingest \(diagnostic.ingestDiagnosticPhase.rawValue) failed: \(diagnostic.ingestDiagnosticReason). \(sanitize(String(describing: error)))"
        }
        return "Ingest failed: \(sanitize(String(describing: error)))"
    }

    private func sanitize(_ value: String) -> String {
        IngestRedaction.redact(value)
    }

    private func standardErrorWrite(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private enum IngestCommandError: Error, CustomStringConvertible {
    case configuration(String)
    case databaseOpenFailed

    var description: String {
        switch self {
        case .configuration(let reason):
            return "Ingest configuration failed: \(IngestRedaction.redact(reason))."
        case .databaseOpenFailed:
            return "Ingest database failed: could not open redacted database path."
        }
    }
}

private final class CLIModelProgressSink: @unchecked Sendable {
    private let lock = NSLock()

    func emit(_ progress: ModelCacheProgress) {
        lock.lock()
        defer { lock.unlock() }

        let suffix: String
        if let fraction = progress.fractionCompleted {
            let percent = max(0, min(100, Int((fraction * 100).rounded())))
            suffix = " \(percent)%"
        } else {
            suffix = ""
        }
        let line =
            "model \(progress.event.rawValue): provider=\(IngestRedaction.component(progress.provider)) model=\(IngestRedaction.component(progress.model))\(suffix)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
