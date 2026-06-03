import CryptoKit
import Foundation
import GRDB

public struct AudioArchiveRow: Equatable, Sendable {
    public var id: Int64
    public var streamID: Int64
    public var runID: Int64
    public var chunkID: Int64
    public var sequence: Int
    public var startSeconds: Double
    public var endSeconds: Double
    public var sampleRate: Double
    public var channelCount: Int
    public var byteCount: Int
    public var sha256: String
    public var fileURL: URL
    public var createdAt: String
}

public struct ArchivedAudioFrame: Equatable, Sendable {
    public var row: AudioArchiveRow
    public var frame: SharedPCMFrame
}

public enum AudioArchiveStoreError: Error, Equatable, Sendable {
    case invalidLinearPCMFormat
    case invalidByteCount
    case archiveIdentityMismatch
    case unsafeRelativePath(String)
    case archivedRowNotFound
    case archiveFileCorrupt
}

public struct AudioArchiveStore: @unchecked Sendable {
    private let database: SoundingDatabase
    private let archiveDirectory: URL
    private let fileManager: FileManager
    private let maximumBytes: Int64?
    private let retentionSeconds: Double?

    public init(
        database: SoundingDatabase,
        archiveDirectory: URL,
        fileManager: FileManager = .default,
        maximumBytes: Int64? = nil,
        retentionSeconds: Double? = nil
    ) {
        self.database = database
        self.archiveDirectory = archiveDirectory
        self.fileManager = fileManager
        self.maximumBytes = maximumBytes.flatMap { $0 > 0 ? $0 : nil }
        self.retentionSeconds = retentionSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    @discardableResult
    public func archive(frame: SharedPCMFrame, runID: Int64, chunkID: Int64) throws
        -> AudioArchiveRow
    {
        let format = try validateLinearPCMFormat(frame.format)
        let audio = try validAudioData(frame)
        let hash = Self.sha256Hex(audio)
        let relativePath =
            "stream-\(frame.streamID)/run-\(runID)/chunk-\(chunkID)-frame-\(frame.sequence)-\(hash).pcm"
        let fileURL = try resolvedFileURL(relativePath: relativePath)

        guard try archiveIdentityMatches(streamID: frame.streamID, runID: runID, chunkID: chunkID)
        else {
            throw AudioArchiveStoreError.archiveIdentityMismatch
        }

        try fileManager.createDirectory(
            at: archiveDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: fileURL.path) {
            let existing = try Data(contentsOf: fileURL)
            if existing.count != audio.count || Self.sha256Hex(existing) != hash {
                try audio.write(to: fileURL, options: .atomic)
            }
        } else {
            try audio.write(to: fileURL, options: .atomic)
        }

        let createdAt = SoundingTimestampClock.timestamp()

        return try database.write { db in
            guard try archiveIdentityMatches(
                streamID: frame.streamID,
                runID: runID,
                chunkID: chunkID,
                db: db
            ) else {
                throw AudioArchiveStoreError.archiveIdentityMismatch
            }
            try db.execute(
                sql: """
                    INSERT INTO audio_archive_segments (
                        stream_id, run_id, chunk_id, sequence, start_seconds, end_seconds,
                        sample_rate, channel_count, byte_count, sha256, relative_path, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(stream_id, run_id, chunk_id, sequence) DO UPDATE SET
                        start_seconds = excluded.start_seconds,
                        end_seconds = excluded.end_seconds,
                        sample_rate = excluded.sample_rate,
                        channel_count = excluded.channel_count,
                        byte_count = excluded.byte_count,
                        sha256 = excluded.sha256,
                        relative_path = excluded.relative_path
                    """,
                arguments: [
                    frame.streamID,
                    runID,
                    chunkID,
                    frame.sequence,
                    frame.startSeconds,
                    frame.endSeconds,
                    format.sampleRate,
                    format.channelCount,
                    audio.count,
                    hash,
                    relativePath,
                    createdAt,
                ]
            )
            let id =
                try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM audio_archive_segments
                        WHERE stream_id = ? AND run_id = ? AND chunk_id = ? AND sequence = ?
                        """,
                    arguments: [frame.streamID, runID, chunkID, frame.sequence]
                ) ?? db.lastInsertedRowID
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM audio_archive_segments WHERE id = ?",
                    arguments: [id]
                )
            else { throw AudioArchiveStoreError.archivedRowNotFound }
            let archiveRow = try decode(row)
            try pruneIfNeeded(preservingRowID: archiveRow.id, db: db)
            return archiveRow
        }
    }

    public func frame(streamID: Int64, seconds: Double) throws -> ArchivedAudioFrame? {
        try database.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM audio_archive_segments
                        WHERE stream_id = ? AND start_seconds <= ? AND end_seconds >= ?
                        ORDER BY start_seconds DESC, id DESC
                        LIMIT 1
                        """,
                    arguments: [streamID, seconds, seconds]
                )
            else { return nil }

            let archiveRow = try decode(row)
            let data = try Data(contentsOf: archiveRow.fileURL)
            guard data.count == archiveRow.byteCount,
                Self.sha256Hex(data) == archiveRow.sha256
            else {
                throw AudioArchiveStoreError.archiveFileCorrupt
            }
            let frame = SharedPCMFrame(
                streamID: archiveRow.streamID,
                sequence: archiveRow.sequence,
                audio: data,
                byteCount: data.count,
                startSeconds: archiveRow.startSeconds,
                endSeconds: archiveRow.endSeconds,
                format: SharedPCMFormat.linearPCM(
                    sampleRate: archiveRow.sampleRate,
                    channelCount: archiveRow.channelCount
                ),
                hlsIdentity: nil
            )
            return ArchivedAudioFrame(row: archiveRow, frame: frame)
        }
    }

    private func decode(_ row: Row) throws -> AudioArchiveRow {
        let relativePath: String = row["relative_path"]
        let fileURL = try resolvedFileURL(relativePath: relativePath)
        return AudioArchiveRow(
            id: row["id"],
            streamID: row["stream_id"],
            runID: row["run_id"],
            chunkID: row["chunk_id"],
            sequence: row["sequence"],
            startSeconds: row["start_seconds"],
            endSeconds: row["end_seconds"],
            sampleRate: row["sample_rate"],
            channelCount: row["channel_count"],
            byteCount: row["byte_count"],
            sha256: row["sha256"],
            fileURL: fileURL,
            createdAt: row["created_at"]
        )
    }

    private func validateLinearPCMFormat(_ format: SharedPCMFormat) throws
        -> (sampleRate: Double, channelCount: Int)
    {
        guard format.payloadKind == .linearPCM,
            let sampleRate = format.sampleRate,
            sampleRate.isFinite,
            sampleRate > 0,
            let channelCount = format.channelCount,
            channelCount > 0
        else {
            throw AudioArchiveStoreError.invalidLinearPCMFormat
        }
        return (sampleRate, channelCount)
    }

    private func archiveIdentityMatches(
        streamID: Int64,
        runID: Int64,
        chunkID: Int64,
        db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM ingest_chunks
                    JOIN ingest_runs ON ingest_runs.id = ingest_chunks.run_id
                    WHERE ingest_runs.stream_id = ?
                      AND ingest_runs.id = ?
                      AND ingest_chunks.id = ?
                )
                """,
            arguments: [streamID, runID, chunkID]
        ) ?? false
    }

    private func archiveIdentityMatches(streamID: Int64, runID: Int64, chunkID: Int64) throws
        -> Bool
    {
        try database.read { db in
            try archiveIdentityMatches(streamID: streamID, runID: runID, chunkID: chunkID, db: db)
        }
    }

    private func validAudioData(_ frame: SharedPCMFrame) throws -> Data {
        guard frame.byteCount >= 0, frame.byteCount <= frame.audio.count else {
            throw AudioArchiveStoreError.invalidByteCount
        }
        guard frame.byteCount != frame.audio.count else { return frame.audio }
        return frame.audio.prefix(frame.byteCount)
    }

    private func pruneIfNeeded(preservingRowID preservedID: Int64, db: Database) throws {
        if let retentionSeconds {
            let cutoff = Date().addingTimeInterval(-retentionSeconds)
            try pruneRows(
                matching: { row in
                    guard row.id != preservedID else { return false }
                    guard let createdAt = Self.date(from: row.createdAt) else { return false }
                    return createdAt < cutoff
                },
                db: db
            )
        }

        if let maximumBytes {
            var rows = try archiveRows(db: db).sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
            var totalBytes = rows.reduce(Int64(0)) { total, row in
                total + Int64(max(0, row.byteCount))
            }
            while totalBytes > maximumBytes, let row = rows.first {
                rows.removeFirst()
                guard row.id != preservedID else { continue }
                try deleteArchiveRow(row, db: db)
                totalBytes -= Int64(max(0, row.byteCount))
            }
        }
    }

    private func pruneRows(matching shouldDelete: (AudioArchiveRow) -> Bool, db: Database) throws {
        for row in try archiveRows(db: db) where shouldDelete(row) {
            try deleteArchiveRow(row, db: db)
        }
    }

    private func archiveRows(db: Database) throws -> [AudioArchiveRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT *
                FROM audio_archive_segments
                ORDER BY created_at, id
                """
        ).map(decode)
    }

    private func deleteArchiveRow(_ row: AudioArchiveRow, db: Database) throws {
        try? fileManager.removeItem(at: row.fileURL)
        try db.execute(
            sql: "DELETE FROM audio_archive_segments WHERE id = ?",
            arguments: [row.id]
        )
    }

    private func resolvedFileURL(relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"),
            !relativePath.contains("//"),
            !relativePath.split(separator: "/").contains("..")
        else {
            throw AudioArchiveStoreError.unsafeRelativePath(relativePath)
        }

        let url = archiveDirectory.appendingPathComponent(relativePath, isDirectory: false)
        let basePath = archiveDirectory.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard candidatePath.hasPrefix(basePrefix) else {
            throw AudioArchiveStoreError.unsafeRelativePath(relativePath)
        }
        return url
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func date(from timestamp: String) -> Date? {
        ISO8601DateFormatter().date(from: timestamp)
    }
}
