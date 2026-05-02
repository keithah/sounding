import Foundation

public enum SoundingDatabaseOperationalStatus: String, Codable, Equatable, Sendable, CustomStringConvertible {
    case healthy
    case degraded
    case unhealthy

    public var description: String { rawValue }
}

public enum SoundingDatabaseCheckStatus: String, Codable, Equatable, Sendable, CustomStringConvertible {
    case ok
    case warning
    case failed

    public var description: String { rawValue }
}

public enum SoundingDatabaseFailurePhase: String, Codable, Equatable, Sendable, CustomStringConvertible {
    case open
    case health
    case checkpoint
    case quickCheck
    case integrityCheck
    case foreignKeyCheck

    public var description: String { rawValue }
}

public enum SoundingDatabaseRecoveryGuidance: String, Codable, Equatable, Sendable, CustomStringConvertible {
    case openDatabase = "Verify database availability and permissions, then restart the app or retry the command."
    case locked = "Another process is using the database. Wait for active readers or writers to finish, then retry."
    case corruption = "Stop writers, preserve the database and companion files for investigation, then restore from a known-good copy if available."
    case checkpoint = "Retry a passive checkpoint when readers are idle; do not force truncate while the app is active."
    case healthCheck = "Run database health again after writers are idle; inspect check summaries for the failing phase."

    public var description: String { rawValue }
}

public struct SoundingDatabaseFailure: Codable, Equatable, Sendable, CustomStringConvertible {
    public var phase: SoundingDatabaseFailurePhase
    public var guidance: SoundingDatabaseRecoveryGuidance
    public var message: String

    public init(
        phase: SoundingDatabaseFailurePhase,
        guidance: SoundingDatabaseRecoveryGuidance,
        message: String
    ) {
        self.phase = phase
        self.guidance = guidance
        self.message = Self.safeMessage(message)
    }

    public var description: String {
        "SoundingDatabaseFailure(phase: \(phase), guidance: \(guidance), message: \(message))"
    }

    static func classified(phase: SoundingDatabaseFailurePhase, error: Error) -> SoundingDatabaseFailure {
        let raw = String(describing: error)
        let guidance = guidance(for: raw, phase: phase)
        return SoundingDatabaseFailure(
            phase: phase,
            guidance: guidance,
            message: publicMessage(for: guidance, phase: phase)
        )
    }

    private static func guidance(for raw: String, phase: SoundingDatabaseFailurePhase) -> SoundingDatabaseRecoveryGuidance {
        let lowercased = raw.lowercased()
        if lowercased.contains("busy") || lowercased.contains("locked") {
            return .locked
        }
        if lowercased.contains("corrupt")
            || lowercased.contains("not a database")
            || lowercased.contains("database disk image")
            || lowercased.contains("malformed")
        {
            return .corruption
        }
        if phase == .checkpoint {
            return .checkpoint
        }
        if phase == .open {
            return .openDatabase
        }
        return .healthCheck
    }

    private static func publicMessage(
        for guidance: SoundingDatabaseRecoveryGuidance,
        phase: SoundingDatabaseFailurePhase
    ) -> String {
        switch guidance {
        case .openDatabase:
            return "Database could not be opened."
        case .locked:
            return "Database operation was blocked by an active reader or writer."
        case .corruption:
            return "Database contents failed SQLite validation."
        case .checkpoint:
            return "Database checkpoint did not complete cleanly."
        case .healthCheck:
            return "Database health collection did not complete cleanly during \(phase)."
        }
    }

    private static func safeMessage(_ value: String) -> String {
        var redacted = IngestRedaction.redact(value)
        redacted = redacted.replacingOccurrences(of: "GRDB", with: "database")
        redacted = redacted.replacingOccurrences(of: "SQLite error", with: "database error")
        return redacted
    }
}

public struct SoundingDatabaseFileMetrics: Codable, Equatable, Sendable, CustomStringConvertible {
    public var databaseBytes: Int64
    public var walBytes: Int64?
    public var shmBytes: Int64?

    public init(databaseBytes: Int64, walBytes: Int64?, shmBytes: Int64?) {
        self.databaseBytes = max(0, databaseBytes)
        self.walBytes = walBytes.map { max(0, $0) }
        self.shmBytes = shmBytes.map { max(0, $0) }
    }

    public var description: String {
        "SoundingDatabaseFileMetrics(databaseBytes: \(databaseBytes), walBytes: \(String(describing: walBytes)), shmBytes: \(String(describing: shmBytes)))"
    }
}

public struct SoundingDatabaseCheckSummary: Codable, Equatable, Sendable, CustomStringConvertible {
    public var name: String
    public var status: SoundingDatabaseCheckStatus
    public var issueCount: Int
    public var details: [String]

    public init(name: String, status: SoundingDatabaseCheckStatus, issueCount: Int, details: [String] = []) {
        self.name = IngestRedaction.redact(name)
        self.status = status
        self.issueCount = max(0, issueCount)
        self.details = details.prefix(5).map(IngestRedaction.redact)
    }

    public var description: String {
        "SoundingDatabaseCheckSummary(name: \(name), status: \(status), issueCount: \(issueCount), details: \(details))"
    }
}

public struct SoundingDatabaseCheckpointResult: Codable, Equatable, Sendable, CustomStringConvertible {
    public var status: SoundingDatabaseOperationalStatus
    public var busyFrameCount: Int
    public var logFrameCount: Int
    public var checkpointedFrameCount: Int
    public var guidance: SoundingDatabaseRecoveryGuidance?
    public var failure: SoundingDatabaseFailure?

    public init(
        status: SoundingDatabaseOperationalStatus,
        busyFrameCount: Int,
        logFrameCount: Int,
        checkpointedFrameCount: Int,
        guidance: SoundingDatabaseRecoveryGuidance? = nil,
        failure: SoundingDatabaseFailure? = nil
    ) {
        self.status = status
        self.busyFrameCount = max(0, busyFrameCount)
        self.logFrameCount = max(0, logFrameCount)
        self.checkpointedFrameCount = max(0, checkpointedFrameCount)
        self.guidance = guidance
        self.failure = failure
    }

    public var description: String {
        "SoundingDatabaseCheckpointResult(status: \(status), busyFrameCount: \(busyFrameCount), logFrameCount: \(logFrameCount), checkpointedFrameCount: \(checkpointedFrameCount), guidance: \(String(describing: guidance)), failure: \(String(describing: failure)))"
    }
}

public struct SoundingDatabaseHealth: Codable, Equatable, Sendable, CustomStringConvertible {
    public var status: SoundingDatabaseOperationalStatus
    public var journalMode: String
    public var walAutoCheckpointPages: Int
    public var pageSizeBytes: Int
    public var pageCount: Int
    public var files: SoundingDatabaseFileMetrics
    public var quickCheck: SoundingDatabaseCheckSummary
    public var foreignKeyCheck: SoundingDatabaseCheckSummary
    public var integrityCheck: SoundingDatabaseCheckSummary?
    public var checkpoint: SoundingDatabaseCheckpointResult?
    public var failure: SoundingDatabaseFailure?
    public var guidance: SoundingDatabaseRecoveryGuidance?

    public init(
        status: SoundingDatabaseOperationalStatus,
        journalMode: String,
        walAutoCheckpointPages: Int,
        pageSizeBytes: Int,
        pageCount: Int,
        files: SoundingDatabaseFileMetrics,
        quickCheck: SoundingDatabaseCheckSummary,
        foreignKeyCheck: SoundingDatabaseCheckSummary,
        integrityCheck: SoundingDatabaseCheckSummary? = nil,
        checkpoint: SoundingDatabaseCheckpointResult? = nil,
        failure: SoundingDatabaseFailure? = nil,
        guidance: SoundingDatabaseRecoveryGuidance? = nil
    ) {
        self.status = status
        self.journalMode = IngestRedaction.redact(journalMode)
        self.walAutoCheckpointPages = max(0, walAutoCheckpointPages)
        self.pageSizeBytes = max(0, pageSizeBytes)
        self.pageCount = max(0, pageCount)
        self.files = files
        self.quickCheck = quickCheck
        self.foreignKeyCheck = foreignKeyCheck
        self.integrityCheck = integrityCheck
        self.checkpoint = checkpoint
        self.failure = failure
        self.guidance = guidance
    }

    public var description: String {
        "SoundingDatabaseHealth(status: \(status), journalMode: \(journalMode), walAutoCheckpointPages: \(walAutoCheckpointPages), pageSizeBytes: \(pageSizeBytes), pageCount: \(pageCount), files: \(files), quickCheck: \(quickCheck), foreignKeyCheck: \(foreignKeyCheck), integrityCheck: \(String(describing: integrityCheck)), checkpoint: \(String(describing: checkpoint)), failure: \(String(describing: failure)), guidance: \(String(describing: guidance)))"
    }
}
