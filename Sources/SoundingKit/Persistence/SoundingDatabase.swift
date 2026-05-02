import Foundation
import GRDB

/// SoundingKit-owned SQLite database handle.
///
/// Opening a `SoundingDatabase` creates a GRDB pool and runs all registered
/// migrations synchronously, so callers either receive a migrated database or a
/// thrown open/migration error with GRDB context.
public enum SoundingDatabaseCheckpointMode: String, Codable, Equatable, Sendable, CaseIterable, CustomStringConvertible {
    case passive
    case full
    case restart
    case truncate

    public var description: String { rawValue }

    fileprivate var pragmaValue: String { rawValue.uppercased() }
}

public final class SoundingDatabase: @unchecked Sendable {
    public let fileURL: URL

    private let pool: DatabasePool

    public init(fileURL: URL) throws {
        self.fileURL = fileURL

        var configuration = Configuration()
        configuration.defaultTransactionKind = .immediate
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        pool = try DatabasePool(path: fileURL.path, configuration: configuration)
        try SoundingDatabaseMigrator.migrate(pool)
    }

    public func read<Value>(_ value: (Database) throws -> Value) throws -> Value {
        try pool.read(value)
    }

    public func write<Value>(_ updates: (Database) throws -> Value) throws -> Value {
        try pool.write(updates)
    }

    public func health(includeIntegrityCheck: Bool = false) -> SoundingDatabaseHealth {
        do {
            return try pool.read { db in
                let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
                let walAutoCheckpointPages = try Int.fetchOne(db, sql: "PRAGMA wal_autocheckpoint") ?? 0
                let pageSizeBytes = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let files = Self.fileMetrics(fileURL: fileURL)
                let quickCheck = try Self.checkSummary(
                    name: "quick_check",
                    phase: .quickCheck,
                    db: db,
                    sql: "PRAGMA quick_check"
                )
                let foreignKeyCheck = try Self.foreignKeyCheckSummary(db: db)
                let integrityCheck = includeIntegrityCheck
                    ? try Self.checkSummary(
                        name: "integrity_check",
                        phase: .integrityCheck,
                        db: db,
                        sql: "PRAGMA integrity_check"
                    )
                    : nil
                let status = Self.healthStatus(
                    quickCheck: quickCheck,
                    foreignKeyCheck: foreignKeyCheck,
                    integrityCheck: integrityCheck
                )
                let guidance: SoundingDatabaseRecoveryGuidance? = status == .healthy ? nil : .healthCheck
                return SoundingDatabaseHealth(
                    status: status,
                    journalMode: journalMode,
                    walAutoCheckpointPages: walAutoCheckpointPages,
                    pageSizeBytes: pageSizeBytes,
                    pageCount: pageCount,
                    files: files,
                    quickCheck: quickCheck,
                    foreignKeyCheck: foreignKeyCheck,
                    integrityCheck: integrityCheck,
                    guidance: guidance
                )
            }
        } catch {
            let failure = SoundingDatabaseFailure.classified(phase: .health, error: error)
            return SoundingDatabaseHealth(
                status: .unhealthy,
                journalMode: "unknown",
                walAutoCheckpointPages: 0,
                pageSizeBytes: 0,
                pageCount: 0,
                files: Self.fileMetrics(fileURL: fileURL),
                quickCheck: SoundingDatabaseCheckSummary(name: "quick_check", status: .failed, issueCount: 1),
                foreignKeyCheck: SoundingDatabaseCheckSummary(name: "foreign_key_check", status: .failed, issueCount: 1),
                failure: failure,
                guidance: failure.guidance
            )
        }
    }

    public func checkpoint(mode: SoundingDatabaseCheckpointMode = .passive) -> SoundingDatabaseCheckpointResult {
        do {
            return try pool.barrierWriteWithoutTransaction { db in
                guard let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(\(mode.pragmaValue))") else {
                    return SoundingDatabaseCheckpointResult(
                        status: .degraded,
                        busyFrameCount: 0,
                        logFrameCount: 0,
                        checkpointedFrameCount: 0,
                        guidance: .checkpoint
                    )
                }
                let busy: Int = row["busy"] ?? 0
                let log: Int = row["log"] ?? 0
                let checkpointed: Int = row["checkpointed"] ?? 0
                let status: SoundingDatabaseOperationalStatus = busy > 0 ? .degraded : .healthy
                return SoundingDatabaseCheckpointResult(
                    status: status,
                    busyFrameCount: busy,
                    logFrameCount: log,
                    checkpointedFrameCount: checkpointed,
                    guidance: status == .healthy ? nil : .locked
                )
            }
        } catch {
            let failure = SoundingDatabaseFailure.classified(phase: .checkpoint, error: error)
            return SoundingDatabaseCheckpointResult(
                status: failure.guidance == .locked ? .degraded : .unhealthy,
                busyFrameCount: 0,
                logFrameCount: 0,
                checkpointedFrameCount: 0,
                guidance: failure.guidance,
                failure: failure
            )
        }
    }

    public static func health(fileURL: URL, includeIntegrityCheck: Bool = false) -> SoundingDatabaseHealth {
        do {
            return try SoundingDatabase(fileURL: fileURL).health(includeIntegrityCheck: includeIntegrityCheck)
        } catch {
            let failure = SoundingDatabaseFailure.classified(phase: .open, error: error)
            return SoundingDatabaseHealth(
                status: .unhealthy,
                journalMode: "unknown",
                walAutoCheckpointPages: 0,
                pageSizeBytes: 0,
                pageCount: 0,
                files: fileMetrics(fileURL: fileURL),
                quickCheck: SoundingDatabaseCheckSummary(name: "quick_check", status: .failed, issueCount: 1),
                foreignKeyCheck: SoundingDatabaseCheckSummary(name: "foreign_key_check", status: .failed, issueCount: 1),
                failure: failure,
                guidance: failure.guidance
            )
        }
    }

    private static func healthStatus(
        quickCheck: SoundingDatabaseCheckSummary,
        foreignKeyCheck: SoundingDatabaseCheckSummary,
        integrityCheck: SoundingDatabaseCheckSummary?
    ) -> SoundingDatabaseOperationalStatus {
        var checks = [quickCheck, foreignKeyCheck]
        if let integrityCheck {
            checks.append(integrityCheck)
        }
        if checks.contains(where: { $0.status == .failed }) {
            return .unhealthy
        }
        if checks.contains(where: { $0.status == .warning }) {
            return .degraded
        }
        return .healthy
    }

    private static func checkSummary(
        name: String,
        phase: SoundingDatabaseFailurePhase,
        db: Database,
        sql: String
    ) throws -> SoundingDatabaseCheckSummary {
        do {
            let results = try String.fetchAll(db, sql: sql)
            let issues = results.filter { $0.lowercased() != "ok" }
            return SoundingDatabaseCheckSummary(
                name: name,
                status: issues.isEmpty ? .ok : .failed,
                issueCount: issues.count,
                details: issues
            )
        } catch {
            let failure = SoundingDatabaseFailure.classified(phase: phase, error: error)
            return SoundingDatabaseCheckSummary(
                name: name,
                status: .failed,
                issueCount: 1,
                details: [failure.message]
            )
        }
    }

    private static func foreignKeyCheckSummary(db: Database) throws -> SoundingDatabaseCheckSummary {
        do {
            let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            let details = rows.prefix(5).map { row -> String in
                let table: String = row["table"] ?? "unknown"
                let rowID: Int64 = row["rowid"] ?? 0
                return "foreign key violation in table \(table) row \(rowID)"
            }
            return SoundingDatabaseCheckSummary(
                name: "foreign_key_check",
                status: rows.isEmpty ? .ok : .failed,
                issueCount: rows.count,
                details: details
            )
        } catch {
            let failure = SoundingDatabaseFailure.classified(phase: .foreignKeyCheck, error: error)
            return SoundingDatabaseCheckSummary(
                name: "foreign_key_check",
                status: .failed,
                issueCount: 1,
                details: [failure.message]
            )
        }
    }

    private static func fileMetrics(fileURL: URL) -> SoundingDatabaseFileMetrics {
        SoundingDatabaseFileMetrics(
            databaseBytes: fileSize(atPath: fileURL.path) ?? 0,
            walBytes: fileSize(atPath: fileURL.path + "-wal"),
            shmBytes: fileSize(atPath: fileURL.path + "-shm")
        )
    }

    private static func fileSize(atPath path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }
}

