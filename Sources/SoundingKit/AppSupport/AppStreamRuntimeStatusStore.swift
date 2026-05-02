import Foundation
import GRDB

public enum AppStreamRuntimeStatusStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidStreamID
    case streamNotFound
    case databaseReadFailed(message: String)
    case databaseWriteFailed(message: String)

    public var description: String {
        switch self {
        case .invalidStreamID:
            return "Runtime status requires a valid stream identifier."
        case .streamNotFound:
            return "Runtime status stream was not found."
        case .databaseReadFailed(let message):
            return "Runtime status database read failed: \(IngestRedaction.redact(message))."
        case .databaseWriteFailed(let message):
            return "Runtime status database write failed: \(IngestRedaction.redact(message))."
        }
    }
}

/// CLI/app inspection projection that pairs every stream registry row with its current runtime status.
///
/// `hasRuntimeStatus == false` represents an absent status row. Callers should render that as an
/// idle/unknown runtime state instead of failing inspection for the whole database.
public struct AppStreamRuntimeStatusInspection: Equatable, Sendable {
    public var streamID: Int64
    public var name: String
    public var streamType: String
    public var streamStatus: String
    public var sourceDescription: String
    public var phase: String
    public var hasRuntimeStatus: Bool
    public var attempt: Int
    public var maxAttempts: Int
    public var nextRetrySeconds: Int?
    public var nextRetryAt: String?
    public var updatedAt: String?
    public var recentFailure: AppStreamRuntimeRecentFailure?

    public init(
        streamID: Int64,
        name: String,
        streamType: String,
        streamStatus: String,
        sourceDescription: String,
        phase: String,
        hasRuntimeStatus: Bool,
        attempt: Int,
        maxAttempts: Int,
        nextRetrySeconds: Int?,
        nextRetryAt: String?,
        updatedAt: String?,
        recentFailure: AppStreamRuntimeRecentFailure?
    ) {
        self.streamID = streamID
        self.name = IngestRedaction.redact(name)
        self.streamType = IngestRedaction.redact(streamType)
        self.streamStatus = IngestRedaction.redact(streamStatus)
        self.sourceDescription = IngestRedaction.sourceDescription(sourceDescription)
        self.phase = IngestRedaction.redact(phase)
        self.hasRuntimeStatus = hasRuntimeStatus
        self.attempt = max(0, attempt)
        self.maxAttempts = max(0, maxAttempts)
        self.nextRetrySeconds = nextRetrySeconds.map { max(0, $0) }
        self.nextRetryAt = nextRetryAt.map(IngestRedaction.redact)
        self.updatedAt = updatedAt.map(IngestRedaction.redact)
        self.recentFailure = recentFailure
    }
}

/// SQLite-backed current runtime status projection for app and CLI inspection surfaces.
///
/// The store intentionally persists one row per stream and no history. Runtime callers replace
/// the current row on every transition, while readers join through the redacted stream registry
/// columns so raw reconnect URLs and local paths never cross this boundary.
public struct AppStreamRuntimeStatusStore: Sendable {
    private static let malformedPhaseMessage =
        "Runtime status row contains an unsupported phase value. Clear or refresh the status row."

    private let database: SoundingDatabase

    public init(database: SoundingDatabase) {
        self.database = database
    }

    public func upsert(_ update: AppStreamRuntimeStatusUpdate) throws {
        guard update.streamID > 0 else { throw AppStreamRuntimeStatusStoreError.invalidStreamID }

        do {
            try database.write { db in
                guard try streamExists(update.streamID, db: db) else {
                    throw AppStreamRuntimeStatusStoreError.streamNotFound
                }
                let failure = update.recentFailure.map {
                    AppStreamRuntimeRecentFailure(
                        message: $0.message,
                        occurredAt: IngestRedaction.redact($0.occurredAt)
                    )
                }
                try db.execute(
                    sql: """
                    INSERT INTO stream_runtime_status (
                        stream_id, phase, attempt, max_attempts, next_retry_seconds,
                        next_retry_at, recent_failure_message, recent_failure_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(stream_id) DO UPDATE SET
                        phase = excluded.phase,
                        attempt = excluded.attempt,
                        max_attempts = excluded.max_attempts,
                        next_retry_seconds = excluded.next_retry_seconds,
                        next_retry_at = excluded.next_retry_at,
                        recent_failure_message = excluded.recent_failure_message,
                        recent_failure_at = excluded.recent_failure_at,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        update.streamID,
                        update.phase.rawValue,
                        update.attempt,
                        update.maxAttempts,
                        update.nextRetrySeconds,
                        update.nextRetryAt.map(IngestRedaction.redact),
                        failure?.message,
                        failure?.occurredAt,
                        IngestRedaction.redact(update.updatedAt)
                    ]
                )
            }
        } catch let error as AppStreamRuntimeStatusStoreError {
            throw error
        } catch {
            throw AppStreamRuntimeStatusStoreError.databaseWriteFailed(
                message: Self.redactedDatabaseMessage(error)
            )
        }
    }

    public func delete(streamID: Int64) throws {
        guard streamID > 0 else { throw AppStreamRuntimeStatusStoreError.invalidStreamID }

        do {
            try database.write { db in
                try db.execute(
                    sql: "DELETE FROM stream_runtime_status WHERE stream_id = ?",
                    arguments: [streamID]
                )
            }
        } catch {
            throw AppStreamRuntimeStatusStoreError.databaseWriteFailed(
                message: Self.redactedDatabaseMessage(error)
            )
        }
    }

    public func status(streamID: Int64) throws -> AppStreamRuntimeStatusSnapshot? {
        guard streamID > 0 else { throw AppStreamRuntimeStatusStoreError.invalidStreamID }

        do {
            return try database.read { db in
                try fetchStatus(streamID: streamID, db: db)
            }
        } catch let error as AppStreamRuntimeStatusStoreError {
            throw error
        } catch {
            throw AppStreamRuntimeStatusStoreError.databaseReadFailed(
                message: Self.redactedDatabaseMessage(error)
            )
        }
    }

    public func statuses() throws -> [AppStreamRuntimeStatusSnapshot] {
        do {
            return try database.read { db in
                try Row.fetchAll(
                    db,
                    sql: Self.statusSelectSQL + """

                    ORDER BY streams.name COLLATE NOCASE, stream_runtime_status.stream_id
                    """
                ).map(Self.decodeStatus(row:))
            }
        } catch let error as AppStreamRuntimeStatusStoreError {
            throw error
        } catch {
            throw AppStreamRuntimeStatusStoreError.databaseReadFailed(
                message: Self.redactedDatabaseMessage(error)
            )
        }
    }

    public func inspections(includeRemoved: Bool = false) throws -> [AppStreamRuntimeStatusInspection] {
        do {
            return try database.read { db in
                let removedClause = includeRemoved ? "" : "AND streams.removed_at IS NULL"
                return try Row.fetchAll(
                    db,
                    sql: """
                    SELECT streams.id,
                           streams.name,
                           streams.stream_type,
                           streams.status,
                           streams.source,
                           stream_runtime_status.stream_id AS runtime_stream_id,
                           stream_runtime_status.phase,
                           stream_runtime_status.attempt,
                           stream_runtime_status.max_attempts,
                           stream_runtime_status.next_retry_seconds,
                           stream_runtime_status.next_retry_at,
                           stream_runtime_status.recent_failure_message,
                           stream_runtime_status.recent_failure_at,
                           stream_runtime_status.updated_at AS runtime_updated_at
                    FROM streams
                    LEFT JOIN stream_runtime_status
                      ON stream_runtime_status.stream_id = streams.id
                    WHERE streams.name IS NOT NULL
                      \(removedClause)
                    ORDER BY streams.name COLLATE NOCASE, streams.id
                    """
                ).map(Self.decodeInspection(row:))
            }
        } catch let error as AppStreamRuntimeStatusStoreError {
            throw error
        } catch {
            throw AppStreamRuntimeStatusStoreError.databaseReadFailed(
                message: Self.redactedDatabaseMessage(error)
            )
        }
    }

    private func fetchStatus(streamID: Int64, db: Database) throws -> AppStreamRuntimeStatusSnapshot? {
        try Row.fetchOne(
            db,
            sql: Self.statusSelectSQL + """

            AND stream_runtime_status.stream_id = ?
            LIMIT 1
            """,
            arguments: [streamID]
        ).map(Self.decodeStatus(row:))
    }

    private func streamExists(_ streamID: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM streams
                WHERE id = ?
                  AND name IS NOT NULL
                  AND removed_at IS NULL
            )
            """,
            arguments: [streamID]
        ) ?? false
    }

    private static let statusSelectSQL = """
        SELECT stream_runtime_status.stream_id,
               streams.name,
               streams.stream_type,
               streams.source,
               stream_runtime_status.phase,
               stream_runtime_status.attempt,
               stream_runtime_status.max_attempts,
               stream_runtime_status.next_retry_seconds,
               stream_runtime_status.next_retry_at,
               stream_runtime_status.recent_failure_message,
               stream_runtime_status.recent_failure_at,
               stream_runtime_status.updated_at
        FROM stream_runtime_status
        JOIN streams ON streams.id = stream_runtime_status.stream_id
        WHERE streams.name IS NOT NULL
          AND streams.removed_at IS NULL
        """

    private static func decodeStatus(row: Row) -> AppStreamRuntimeStatusSnapshot {
        let rawPhase: String = row["phase"]
        let phase = AppStreamRuntimeStatusPhase(rawValue: rawPhase) ?? .error
        let malformedFailure: AppStreamRuntimeRecentFailure? = phase == .error
            && AppStreamRuntimeStatusPhase(rawValue: rawPhase) == nil
            ? AppStreamRuntimeRecentFailure(
                message: malformedPhaseMessage,
                occurredAt: row["updated_at"]
            )
            : nil
        let persistedFailureMessage: String? = row["recent_failure_message"]
        let persistedFailureAt: String? = row["recent_failure_at"]
        let persistedFailure = persistedFailureMessage.map { message in
            AppStreamRuntimeRecentFailure(
                message: message,
                occurredAt: persistedFailureAt ?? row["updated_at"]
            )
        }

        return AppStreamRuntimeStatusSnapshot(
            streamID: row["stream_id"],
            name: row["name"],
            streamType: row["stream_type"],
            sourceDescription: row["source"],
            phase: phase,
            attempt: row["attempt"],
            maxAttempts: row["max_attempts"],
            nextRetrySeconds: row["next_retry_seconds"],
            nextRetryAt: row["next_retry_at"],
            updatedAt: row["updated_at"],
            recentFailure: malformedFailure ?? persistedFailure
        )
    }

    private static func decodeInspection(row: Row) -> AppStreamRuntimeStatusInspection {
        let rawPhase: String? = row["phase"]
        let runtimeUpdatedAt: String? = row["runtime_updated_at"]
        let phase: String
        let malformedFailure: AppStreamRuntimeRecentFailure?
        if let rawPhase, AppStreamRuntimeStatusPhase(rawValue: rawPhase) == nil {
            phase = AppStreamRuntimeStatusPhase.error.rawValue
            malformedFailure = AppStreamRuntimeRecentFailure(
                message: malformedPhaseMessage,
                occurredAt: runtimeUpdatedAt ?? "unknown"
            )
        } else {
            phase = rawPhase ?? "unknown"
            malformedFailure = nil
        }

        let persistedFailureMessage: String? = row["recent_failure_message"]
        let persistedFailureAt: String? = row["recent_failure_at"]
        let persistedFailure = persistedFailureMessage.map { message in
            AppStreamRuntimeRecentFailure(
                message: message,
                occurredAt: persistedFailureAt ?? runtimeUpdatedAt ?? "unknown"
            )
        }

        return AppStreamRuntimeStatusInspection(
            streamID: row["id"],
            name: row["name"],
            streamType: row["stream_type"],
            streamStatus: row["status"],
            sourceDescription: row["source"],
            phase: phase,
            hasRuntimeStatus: rawPhase != nil,
            attempt: (row["attempt"] as Int?) ?? 0,
            maxAttempts: (row["max_attempts"] as Int?) ?? 0,
            nextRetrySeconds: row["next_retry_seconds"],
            nextRetryAt: row["next_retry_at"],
            updatedAt: runtimeUpdatedAt,
            recentFailure: malformedFailure ?? persistedFailure
        )
    }

    private static func redactedDatabaseMessage(_ error: Error) -> String {
        IngestRedaction.redact(String(describing: error))
    }
}
