import ArgumentParser
import Foundation
import SoundingKit

enum DatabaseOutput {
    enum OutputError: Error, Equatable {
        case encodingFailed
    }

    struct Payload: Codable, Equatable {
        var checkDepth: String
        var checkpoint: Checkpoint?
        var command: String
        var health: Health
        var mode: String?
        var ok: Bool
    }

    struct Health: Codable, Equatable {
        var status: String
        var journalMode: String
        var walAutoCheckpointPages: Int
        var pageSizeBytes: Int
        var pageCount: Int
        var files: Files
        var quickCheck: CheckSummary
        var foreignKeyCheck: CheckSummary
        var integrityCheck: CheckSummary?
        var failure: Failure?
        var guidance: String?
    }

    struct Files: Codable, Equatable {
        var databaseBytes: Int64
        var walBytes: Int64?
        var shmBytes: Int64?
    }

    struct CheckSummary: Codable, Equatable {
        var name: String
        var status: String
        var issueCount: Int
        var details: [String]
    }

    struct Checkpoint: Codable, Equatable {
        var status: String
        var busyFrameCount: Int
        var logFrameCount: Int
        var checkpointedFrameCount: Int
        var guidance: String?
        var failure: Failure?
    }

    struct Failure: Codable, Equatable {
        var phase: String
        var message: String
        var guidance: String
    }

    static func encodeHealthJSON(
        health: SoundingDatabaseHealth,
        checkDepth: DatabaseCheckDepth
    ) throws -> String {
        try encode(
            Payload(
                checkDepth: checkDepth.rawValue,
                checkpoint: health.checkpoint.map(sanitizedCheckpoint),
                command: "health",
                health: sanitizedHealth(health),
                mode: nil,
                ok: health.status != .unhealthy
            )
        )
    }

    static func encodeCheckpointJSON(
        checkpoint: SoundingDatabaseCheckpointResult?,
        health: SoundingDatabaseHealth,
        mode: SoundingDatabaseCheckpointMode,
        checkDepth: DatabaseCheckDepth
    ) throws -> String {
        try encode(
            Payload(
                checkDepth: checkDepth.rawValue,
                checkpoint: checkpoint.map(sanitizedCheckpoint),
                command: "checkpoint",
                health: sanitizedHealth(health),
                mode: mode.rawValue,
                ok: checkpoint?.status != .unhealthy && health.status != .unhealthy
            )
        )
    }

    static func formatHealthHuman(
        health: SoundingDatabaseHealth,
        checkDepth: DatabaseCheckDepth
    ) -> String {
        var lines = [
            "Database health: status=\(health.status.rawValue) check_depth=\(checkDepth.rawValue)",
            "WAL: journal_mode=\(safeText(health.journalMode)) wal_autocheckpoint_pages=\(health.walAutoCheckpointPages)",
            "Files: database_bytes=\(health.files.databaseBytes) wal_bytes=\(optionalInt64(health.files.walBytes)) shm_bytes=\(optionalInt64(health.files.shmBytes))",
            "Pages: page_size_bytes=\(health.pageSizeBytes) page_count=\(health.pageCount)",
            checkLine(health.quickCheck),
            checkLine(health.foreignKeyCheck),
        ]
        if let integrityCheck = health.integrityCheck {
            lines.append(checkLine(integrityCheck))
        }
        appendFailureAndGuidance(health.failure, guidance: health.guidance, to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    static func formatCheckpointHuman(
        checkpoint: SoundingDatabaseCheckpointResult?,
        health: SoundingDatabaseHealth,
        mode: SoundingDatabaseCheckpointMode,
        checkDepth: DatabaseCheckDepth
    ) -> String {
        var lines: [String] = [
            "Database checkpoint: mode=\(mode.rawValue) status=\(checkpoint?.status.rawValue ?? health.status.rawValue)",
        ]
        if let checkpoint {
            lines.append(
                "Checkpoint frames: busy=\(checkpoint.busyFrameCount) log=\(checkpoint.logFrameCount) checkpointed=\(checkpoint.checkpointedFrameCount)"
            )
            appendFailureAndGuidance(checkpoint.failure, guidance: checkpoint.guidance, to: &lines)
        }
        lines.append("Post-checkpoint health: status=\(health.status.rawValue) check_depth=\(checkDepth.rawValue)")
        lines.append("WAL: journal_mode=\(safeText(health.journalMode)) wal_autocheckpoint_pages=\(health.walAutoCheckpointPages)")
        lines.append("Files: database_bytes=\(health.files.databaseBytes) wal_bytes=\(optionalInt64(health.files.walBytes)) shm_bytes=\(optionalInt64(health.files.shmBytes))")
        lines.append(checkLine(health.quickCheck))
        lines.append(checkLine(health.foreignKeyCheck))
        if let integrityCheck = health.integrityCheck {
            lines.append(checkLine(integrityCheck))
        }
        appendFailureAndGuidance(health.failure, guidance: health.guidance, to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    static func formatHealthFailurePrefix(command: String) -> String {
        "Database \(command) failed: redacted database path."
    }

    private static func encode<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(payload)
            return String(decoding: data, as: UTF8.self) + "\n"
        } catch {
            throw OutputError.encodingFailed
        }
    }

    private static func sanitizedHealth(_ health: SoundingDatabaseHealth) -> Health {
        Health(
            status: health.status.rawValue,
            journalMode: safeText(health.journalMode),
            walAutoCheckpointPages: health.walAutoCheckpointPages,
            pageSizeBytes: health.pageSizeBytes,
            pageCount: health.pageCount,
            files: Files(
                databaseBytes: health.files.databaseBytes,
                walBytes: health.files.walBytes,
                shmBytes: health.files.shmBytes
            ),
            quickCheck: sanitizedCheck(health.quickCheck),
            foreignKeyCheck: sanitizedCheck(health.foreignKeyCheck),
            integrityCheck: health.integrityCheck.map(sanitizedCheck),
            failure: health.failure.map(sanitizedFailure),
            guidance: health.guidance.map { safeText($0.description) }
        )
    }

    private static func sanitizedCheckpoint(_ checkpoint: SoundingDatabaseCheckpointResult) -> Checkpoint {
        Checkpoint(
            status: checkpoint.status.rawValue,
            busyFrameCount: checkpoint.busyFrameCount,
            logFrameCount: checkpoint.logFrameCount,
            checkpointedFrameCount: checkpoint.checkpointedFrameCount,
            guidance: checkpoint.guidance.map { safeText($0.description) },
            failure: checkpoint.failure.map(sanitizedFailure)
        )
    }

    private static func sanitizedCheck(_ summary: SoundingDatabaseCheckSummary) -> CheckSummary {
        CheckSummary(
            name: safeText(summary.name),
            status: summary.status.rawValue,
            issueCount: summary.issueCount,
            details: summary.details.map(safeText)
        )
    }

    private static func sanitizedFailure(_ failure: SoundingDatabaseFailure) -> Failure {
        Failure(
            phase: failure.phase.rawValue,
            message: safeText(failure.message),
            guidance: safeText(failure.guidance.description)
        )
    }

    private static func checkLine(_ summary: SoundingDatabaseCheckSummary) -> String {
        var line = "Check \(safeText(summary.name)): status=\(summary.status.rawValue) issue_count=\(summary.issueCount)"
        if !summary.details.isEmpty {
            line += " details=\(summary.details.map(safeText).joined(separator: ";"))"
        }
        return line
    }

    private static func appendFailureAndGuidance(
        _ failure: SoundingDatabaseFailure?,
        guidance: SoundingDatabaseRecoveryGuidance?,
        to lines: inout [String]
    ) {
        if let failure {
            lines.append(
                "Failure: phase=\(failure.phase.rawValue) message=\(safeText(failure.message))"
            )
            lines.append("Recovery: \(safeText(failure.guidance.description))")
        } else if let guidance {
            lines.append("Recovery: \(safeText(guidance.description))")
        }
    }

    private static func optionalInt64(_ value: Int64?) -> String {
        value.map(String.init) ?? "none"
    }

    private static func safeText(_ value: String) -> String {
        IngestRedaction.redact(value)
    }
}

enum DatabaseCheckDepth: String, CaseIterable, ExpressibleByArgument {
    case quick
    case integrity

    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}
