import Foundation
import GRDB

public enum StreamStatus: String, Equatable, Sendable, CaseIterable {
    case active
    case paused
    case removed
}

public enum StreamTranscriptionPolicy: String, Equatable, Sendable, CaseIterable {
    case always = "always"
    case nonSongs = "non_songs"
    case hidden = "hidden"

    public static let defaultValue: StreamTranscriptionPolicy = .nonSongs

    public init(databaseValue: String?) {
        let normalized = databaseValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = normalized.flatMap(StreamTranscriptionPolicy.init(rawValue:)) ?? Self.defaultValue
    }
}

public struct StreamRecord: Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var streamType: String
    public var sourceDescription: String
    public var status: StreamStatus
    public var diarizationEnabled: Bool
    public var audioArchiveEnabled: Bool
    public var transcriptionPolicy: StreamTranscriptionPolicy
    public var createdAt: String
    public var updatedAt: String
    public var pausedAt: String?
    public var resumedAt: String?
    public var removedAt: String?

    public init(
        id: Int64,
        name: String,
        streamType: String,
        sourceDescription: String,
        status: StreamStatus,
        diarizationEnabled: Bool = false,
        audioArchiveEnabled: Bool = false,
        transcriptionPolicy: StreamTranscriptionPolicy = .defaultValue,
        createdAt: String,
        updatedAt: String,
        pausedAt: String?,
        resumedAt: String?,
        removedAt: String?
    ) {
        self.id = id
        self.name = name
        self.streamType = streamType
        self.sourceDescription = sourceDescription
        self.status = status
        self.diarizationEnabled = diarizationEnabled
        self.audioArchiveEnabled = audioArchiveEnabled
        self.transcriptionPolicy = transcriptionPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pausedAt = pausedAt
        self.resumedAt = resumedAt
        self.removedAt = removedAt
    }

    public var resolvedStreamType: StreamType? {
        StreamType(rawValue: streamType)
    }
}

public struct StreamReconnectSource: Equatable, Sendable {
    public var streamID: Int64
    public var name: String
    public var streamType: String
    public var source: String
    public var sourceDescription: String
    public var diarizationEnabled: Bool
    public var audioArchiveEnabled: Bool
    public var transcriptionPolicy: StreamTranscriptionPolicy

    public init(
        streamID: Int64,
        name: String,
        streamType: String,
        source: String,
        sourceDescription: String,
        diarizationEnabled: Bool = false,
        audioArchiveEnabled: Bool = false,
        transcriptionPolicy: StreamTranscriptionPolicy = .defaultValue
    ) {
        self.streamID = streamID
        self.name = name
        self.streamType = streamType
        self.source = source
        self.sourceDescription = sourceDescription
        self.diarizationEnabled = diarizationEnabled
        self.audioArchiveEnabled = audioArchiveEnabled
        self.transcriptionPolicy = transcriptionPolicy
    }

    public var resolvedStreamType: StreamType? {
        StreamType(rawValue: streamType)
    }
}

public struct StreamMutationResult: Equatable, Sendable {
    public var record: StreamRecord
    public var changed: Bool
}

public enum StreamRegistryError: Error, Equatable, Sendable {
    case invalidID
    case invalidName
    case invalidSource
    case invalidStreamType
    case invalidStatus(String)
    case duplicateName
    case streamNotFound
    case streamRemoved
    case databaseReadFailed(message: String)
    case databaseWriteFailed(message: String)
}

/// SQLite-backed lifecycle registry for named streams.
///
/// The `streams.source` column remains the redacted compatibility/reporting value used by
/// existing CLI, ingest, and query surfaces. New registry-created rows also persist the
/// original reconnectable source in `streams.source_url`, which is exposed only through
/// `reconnectSource` so list/find records and diagnostics continue to carry redacted text.
public final class StreamRegistry {
    private let database: SoundingDatabase

    public init(database: SoundingDatabase) {
        self.database = database
    }

    public func add(
        name: String,
        streamType: String,
        source: String,
        createdAt: String? = nil
    ) throws -> StreamRecord {
        let name = try validatedName(name)
        let streamType = try validatedStreamType(streamType)
        let source = try validatedReconnectSource(source)
        let sourceDescription = IngestRedaction.sourceDescription(source)
        let createdAt = createdAt ?? Self.nowString()

        do {
            return try database.write { db in
                if try activeStreamExists(named: name, db: db) {
                    throw StreamRegistryError.duplicateName
                }

                try db.execute(
                    sql: """
                    INSERT INTO streams (
                        name, stream_type, source, source_url, status, created_at, updated_at,
                        diarization_enabled, audio_archive_enabled, transcription_policy,
                        paused_at, resumed_at, removed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL)
                    """,
                    arguments: [
                        name,
                        streamType,
                        sourceDescription,
                        source,
                        StreamStatus.active.rawValue,
                        createdAt,
                        createdAt,
                        false,
                        false,
                        StreamTranscriptionPolicy.defaultValue.rawValue
                    ]
                )
                return try fetchStream(id: db.lastInsertedRowID, includeRemoved: true, db: db) ?? {
                    throw StreamRegistryError.streamNotFound
                }()
            }
        } catch let error as StreamRegistryError {
            throw error
        } catch {
            throw StreamRegistryError.databaseWriteFailed(message: Self.redactedDatabaseMessage(error))
        }
    }

    public func add(
        name: String,
        streamType: StreamType,
        source: String,
        createdAt: String? = nil
    ) throws -> StreamRecord {
        try add(
            name: name,
            streamType: streamType.rawValue,
            source: source,
            createdAt: createdAt
        )
    }

    public func list(includeRemoved: Bool = false) throws -> [StreamRecord] {
        do {
            return try database.read { db in
                let rows: [Row]
                if includeRemoved {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, name, stream_type, source, status,
                               COALESCE(diarization_enabled, 0) AS diarization_enabled,
                               COALESCE(audio_archive_enabled, 0) AS audio_archive_enabled,
                               transcription_policy,
                               created_at, updated_at, paused_at, resumed_at, removed_at
                        FROM streams
                        WHERE name IS NOT NULL
                        ORDER BY name COLLATE NOCASE, id
                        """
                    )
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, name, stream_type, source, status,
                               COALESCE(diarization_enabled, 0) AS diarization_enabled,
                               COALESCE(audio_archive_enabled, 0) AS audio_archive_enabled,
                               transcription_policy,
                               created_at, updated_at, paused_at, resumed_at, removed_at
                        FROM streams
                        WHERE name IS NOT NULL
                          AND removed_at IS NULL
                        ORDER BY name COLLATE NOCASE, id
                        """
                    )
                }
                return try rows.map(Self.decode(row:))
            }
        } catch let error as StreamRegistryError {
            throw error
        } catch {
            throw StreamRegistryError.databaseReadFailed(message: Self.redactedDatabaseMessage(error))
        }
    }

    public func find(id: Int64, includeRemoved: Bool = false) throws -> StreamRecord? {
        let id = try validatedID(id)
        do {
            return try database.read { db in
                try fetchStream(id: id, includeRemoved: includeRemoved, db: db)
            }
        } catch let error as StreamRegistryError {
            throw error
        } catch {
            throw StreamRegistryError.databaseReadFailed(message: Self.redactedDatabaseMessage(error))
        }
    }

    public func find(name: String, includeRemoved: Bool = false) throws -> StreamRecord? {
        let name = try validatedName(name)
        do {
            return try database.read { db in
                try fetchStream(name: name, includeRemoved: includeRemoved, db: db)
            }
        } catch let error as StreamRegistryError {
            throw error
        } catch {
            throw StreamRegistryError.databaseReadFailed(message: Self.redactedDatabaseMessage(error))
        }
    }

    public func reconnectSource(id: Int64, includeRemoved: Bool = false) throws -> StreamReconnectSource? {
        let id = try validatedID(id)
        do {
            return try database.read { db in
                try fetchReconnectSource(id: id, includeRemoved: includeRemoved, db: db)
            }
        } catch let error as StreamRegistryError {
            throw error
        } catch {
            throw StreamRegistryError.databaseReadFailed(message: Self.redactedDatabaseMessage(error))
        }
    }

    public func pause(id: Int64, pausedAt: String? = nil) throws -> StreamMutationResult {
        let pausedAt = pausedAt ?? Self.nowString()
        return try transition(id: id, at: pausedAt, includeRemoved: true) { record, db in
            guard record.status != .removed else { throw StreamRegistryError.streamRemoved }
            guard record.status != .paused else { return false }
            try db.execute(
                sql: """
                UPDATE streams
                SET status = ?, paused_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [StreamStatus.paused.rawValue, pausedAt, pausedAt, record.id]
            )
            return true
        }
    }

    public func resume(id: Int64, resumedAt: String? = nil) throws -> StreamMutationResult {
        let resumedAt = resumedAt ?? Self.nowString()
        return try transition(id: id, at: resumedAt, includeRemoved: true) { record, db in
            guard record.status != .removed else { throw StreamRegistryError.streamRemoved }
            guard record.status != .active else { return false }
            try db.execute(
                sql: """
                UPDATE streams
                SET status = ?, resumed_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [StreamStatus.active.rawValue, resumedAt, resumedAt, record.id]
            )
            return true
        }
    }

    public func remove(id: Int64, removedAt: String? = nil) throws -> StreamMutationResult {
        let removedAt = removedAt ?? Self.nowString()
        return try transition(id: id, at: removedAt, includeRemoved: true) { record, db in
            guard record.status != .removed else { return false }
            try db.execute(
                sql: """
                UPDATE streams
                SET status = ?, removed_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [StreamStatus.removed.rawValue, removedAt, removedAt, record.id]
            )
            return true
        }
    }

    public func update(
        id: Int64,
        name: String,
        streamType: String,
        source: String,
        updatedAt: String? = nil
    ) throws -> StreamMutationResult {
        let id = try validatedID(id)
        let name = try validatedName(name)
        let streamType = try validatedStreamType(streamType)
        let source = try validatedReconnectSource(source)
        let sourceDescription = IngestRedaction.sourceDescription(source)
        let updatedAt = updatedAt ?? Self.nowString()

        do {
            return try database.write { db in
                guard let before = try fetchStream(id: id, includeRemoved: false, db: db) else {
                    throw StreamRegistryError.streamNotFound
                }
                if try activeStreamExists(named: name, excluding: id, db: db) {
                    throw StreamRegistryError.duplicateName
                }
                let reconnect = try fetchReconnectSource(id: id, includeRemoved: false, db: db)
                let changed =
                    before.name != name
                    || before.streamType != streamType
                    || before.sourceDescription != sourceDescription
                    || reconnect?.source != source
                guard changed else {
                    return StreamMutationResult(record: before, changed: false)
                }
                try db.execute(
                    sql: """
                    UPDATE streams
                    SET name = ?, stream_type = ?, source = ?, source_url = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [name, streamType, sourceDescription, source, updatedAt, id]
                )
                let after = try fetchStream(id: id, includeRemoved: false, db: db) ?? before
                return StreamMutationResult(record: after, changed: true)
            }
        } catch let error as StreamRegistryError {
            throw error
        } catch {
            throw StreamRegistryError.databaseWriteFailed(message: Self.redactedDatabaseMessage(error))
        }
    }

    public func update(
        id: Int64,
        name: String,
        streamType: StreamType,
        source: String,
        updatedAt: String? = nil
    ) throws -> StreamMutationResult {
        try update(
            id: id,
            name: name,
            streamType: streamType.rawValue,
            source: source,
            updatedAt: updatedAt
        )
    }

    public func setDiarizationEnabled(
        id: Int64,
        isEnabled: Bool,
        updatedAt: String? = nil
    ) throws -> StreamMutationResult {
        let updatedAt = updatedAt ?? Self.nowString()
        return try transition(id: id, at: updatedAt, includeRemoved: false) { record, db in
            guard record.diarizationEnabled != isEnabled else { return false }
            try db.execute(
                sql: """
                UPDATE streams
                SET diarization_enabled = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [isEnabled, updatedAt, record.id]
            )
            return true
        }
    }

    public func updateAudioArchive(
        streamID: Int64,
        isEnabled: Bool,
        updatedAt: String? = nil
    ) throws -> StreamMutationResult {
        let updatedAt = updatedAt ?? Self.nowString()
        return try transition(id: streamID, at: updatedAt, includeRemoved: false) { record, db in
            guard record.audioArchiveEnabled != isEnabled else { return false }
            try db.execute(
                sql: """
                UPDATE streams
                SET audio_archive_enabled = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [isEnabled, updatedAt, record.id]
            )
            return true
        }
    }

    public func updateTranscriptionPolicy(
        streamID: Int64,
        policy: StreamTranscriptionPolicy,
        updatedAt: String? = nil
    ) throws -> StreamMutationResult {
        let updatedAt = updatedAt ?? Self.nowString()
        return try transition(id: streamID, at: updatedAt, includeRemoved: false) { record, db in
            guard record.transcriptionPolicy != policy else { return false }
            try db.execute(
                sql: """
                UPDATE streams
                SET transcription_policy = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [policy.rawValue, updatedAt, record.id]
            )
            return true
        }
    }

    private func transition(
        id: Int64,
        at _: String,
        includeRemoved: Bool = false,
        apply: (StreamRecord, Database) throws -> Bool
    ) throws -> StreamMutationResult {
        let id = try validatedID(id)
        do {
            return try database.write { db in
                guard let before = try fetchStream(id: id, includeRemoved: includeRemoved, db: db) else {
                    throw StreamRegistryError.streamNotFound
                }
                let changed = try apply(before, db)
                let after = try fetchStream(id: id, includeRemoved: true, db: db) ?? before
                return StreamMutationResult(record: after, changed: changed)
            }
        } catch let error as StreamRegistryError {
            throw error
        } catch {
            throw StreamRegistryError.databaseWriteFailed(message: Self.redactedDatabaseMessage(error))
        }
    }

    private func validatedID(_ id: Int64) throws -> Int64 {
        guard id > 0 else { throw StreamRegistryError.invalidID }
        return id
    }

    private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StreamRegistryError.invalidName }
        return trimmed
    }

    private func validatedStreamType(_ streamType: String) throws -> String {
        let trimmed = streamType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StreamRegistryError.invalidStreamType }
        return trimmed
    }

    private func validatedReconnectSource(_ source: String) throws -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StreamRegistryError.invalidSource }
        return trimmed
    }

    private func activeStreamExists(named name: String, db: Database) throws -> Bool {
        try activeStreamExists(named: name, excluding: nil, db: db)
    }

    private func activeStreamExists(named name: String, excluding excludedID: Int64?, db: Database) throws -> Bool {
        var arguments: StatementArguments = [name]
        var excludedClause = ""
        if let excludedID {
            excludedClause = "AND id <> ?"
            arguments += [excludedID]
        }
        return try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM streams
                WHERE name = ?
                  AND removed_at IS NULL
                  \(excludedClause)
            )
            """,
            arguments: arguments
        ) ?? false
    }

    private func fetchStream(id: Int64, includeRemoved: Bool, db: Database) throws -> StreamRecord? {
        let removedClause = includeRemoved ? "" : "AND removed_at IS NULL"
        return try Row.fetchOne(
            db,
            sql: """
            SELECT id, name, stream_type, source, status,
                   COALESCE(diarization_enabled, 0) AS diarization_enabled,
                   COALESCE(audio_archive_enabled, 0) AS audio_archive_enabled,
                   transcription_policy,
                   created_at, updated_at, paused_at, resumed_at, removed_at
            FROM streams
            WHERE id = ?
              AND name IS NOT NULL
              \(removedClause)
            LIMIT 1
            """,
            arguments: [id]
        ).map(Self.decode(row:))
    }

    private func fetchStream(name: String, includeRemoved: Bool, db: Database) throws -> StreamRecord? {
        let removedClause = includeRemoved ? "" : "AND removed_at IS NULL"
        return try Row.fetchOne(
            db,
            sql: """
            SELECT id, name, stream_type, source, status,
                   COALESCE(diarization_enabled, 0) AS diarization_enabled,
                   COALESCE(audio_archive_enabled, 0) AS audio_archive_enabled,
                   transcription_policy,
                   created_at, updated_at, paused_at, resumed_at, removed_at
            FROM streams
            WHERE name = ?
              \(removedClause)
            ORDER BY id DESC
            LIMIT 1
            """,
            arguments: [name]
        ).map(Self.decode(row:))
    }

    private func fetchReconnectSource(id: Int64, includeRemoved: Bool, db: Database) throws -> StreamReconnectSource? {
        let removedClause = includeRemoved ? "" : "AND removed_at IS NULL"
        return try Row.fetchOne(
            db,
            sql: """
            SELECT id, name, stream_type, source, source_url, status,
                   COALESCE(diarization_enabled, 0) AS diarization_enabled,
                   COALESCE(audio_archive_enabled, 0) AS audio_archive_enabled,
                   transcription_policy
            FROM streams
            WHERE id = ?
              AND name IS NOT NULL
              \(removedClause)
            LIMIT 1
            """,
            arguments: [id]
        ).map(Self.decodeReconnectSource(row:))
    }

    private static func decode(row: Row) throws -> StreamRecord {
        let statusValue: String = row["status"]
        guard let status = StreamStatus(rawValue: statusValue) else {
            throw StreamRegistryError.invalidStatus(statusValue)
        }
        return StreamRecord(
            id: row["id"],
            name: row["name"],
            streamType: row["stream_type"],
            sourceDescription: row["source"],
            status: status,
            diarizationEnabled: row["diarization_enabled"],
            audioArchiveEnabled: row["audio_archive_enabled"],
            transcriptionPolicy: StreamTranscriptionPolicy(databaseValue: row["transcription_policy"]),
            createdAt: row["created_at"],
            updatedAt: row["updated_at"],
            pausedAt: row["paused_at"],
            resumedAt: row["resumed_at"],
            removedAt: row["removed_at"]
        )
    }

    private static func decodeReconnectSource(row: Row) throws -> StreamReconnectSource {
        let statusValue: String = row["status"]
        guard StreamStatus(rawValue: statusValue) != nil else {
            throw StreamRegistryError.invalidStatus(statusValue)
        }
        let sourceDescription: String = row["source"]
        let sourceURL: String? = row["source_url"]
        return StreamReconnectSource(
            streamID: row["id"],
            name: row["name"],
            streamType: row["stream_type"],
            source: sourceURL ?? sourceDescription,
            sourceDescription: sourceDescription,
            diarizationEnabled: row["diarization_enabled"],
            audioArchiveEnabled: row["audio_archive_enabled"],
            transcriptionPolicy: StreamTranscriptionPolicy(databaseValue: row["transcription_policy"])
        )
    }

    private static func redactedDatabaseMessage(_ error: Error) -> String {
        IngestRedaction.redact(String(describing: error))
    }

    private static func nowString() -> String {
        SoundingTimestampClock.timestamp()
    }
}

extension StreamRegistry: @unchecked Sendable {}
