import Foundation
import GRDB

public struct AcoustIDLookupCacheIdentity: Equatable, Sendable {
    public var algorithm: String
    public var algorithmVersion: String
    public var fingerprintHash: String

    public init(algorithm: String, algorithmVersion: String, fingerprintHash: String) {
        self.algorithm = algorithm
        self.algorithmVersion = algorithmVersion
        self.fingerprintHash = fingerprintHash
    }
}

public struct AcoustIDLookupCacheEntry: Equatable, Sendable {
    public var identity: AcoustIDLookupCacheIdentity
    public var acoustID: String?
    public var recordingID: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var isrc: String?
    public var durationSeconds: Double?
    public var score: Double?
    public var responseJSON: String?
    public var fetchedAt: String

    public init(
        identity: AcoustIDLookupCacheIdentity,
        acoustID: String? = nil,
        recordingID: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        isrc: String? = nil,
        durationSeconds: Double? = nil,
        score: Double? = nil,
        responseJSON: String? = nil,
        fetchedAt: String
    ) {
        self.identity = identity
        self.acoustID = acoustID
        self.recordingID = recordingID
        self.title = title
        self.artist = artist
        self.album = album
        self.isrc = isrc
        self.durationSeconds = durationSeconds
        self.score = score
        self.responseJSON = responseJSON
        self.fetchedAt = fetchedAt
    }
}

public struct AcoustIDLookupCacheRow: Equatable, Sendable {
    public var id: Int64
    public var identity: AcoustIDLookupCacheIdentity
    public var acoustID: String?
    public var recordingID: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var isrc: String?
    public var durationSeconds: Double?
    public var score: Double?
    public var responseJSON: String?
    public var createdAt: String
    public var updatedAt: String
}

public enum AcoustIDLookupCacheError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidResponseJSON
    case responseJSONTooLarge(maxBytes: Int)
    case databaseReadFailed(message: String)
    case databaseWriteFailed(message: String)
}

public final class AcoustIDLookupCache {
    public static let maximumResponseJSONBytes = 8_192

    private let database: SoundingDatabase

    public init(database: SoundingDatabase) {
        self.database = database
    }

    public func fetch(identity: AcoustIDLookupCacheIdentity) throws -> AcoustIDLookupCacheRow? {
        let identity = try validated(identity: identity)
        do {
            return try database.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id, algorithm, algorithm_version, fingerprint_hash, acoustid_id, recording_id,
                           title, artist, album, isrc, duration_seconds, score, response_json,
                           created_at, updated_at
                    FROM acoustid_lookup_cache
                    WHERE algorithm = ?
                      AND algorithm_version = ?
                      AND fingerprint_hash = ?
                    LIMIT 1
                    """,
                    arguments: [identity.algorithm, identity.algorithmVersion, identity.fingerprintHash]
                ).map(Self.decode(row:))
            }
        } catch let error as AcoustIDLookupCacheError {
            throw error
        } catch {
            throw AcoustIDLookupCacheError.databaseReadFailed(message: String(describing: error))
        }
    }

    public func upsert(_ entry: AcoustIDLookupCacheEntry) throws {
        let identity = try validated(identity: entry.identity)
        let responseJSON = try validated(responseJSON: entry.responseJSON)

        do {
            try database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO acoustid_lookup_cache (
                        algorithm, algorithm_version, fingerprint_hash,
                        acoustid_id, recording_id, title, artist, album, isrc,
                        duration_seconds, score, response_json, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(algorithm, algorithm_version, fingerprint_hash) DO UPDATE SET
                        acoustid_id = excluded.acoustid_id,
                        recording_id = excluded.recording_id,
                        title = excluded.title,
                        artist = excluded.artist,
                        album = excluded.album,
                        isrc = excluded.isrc,
                        duration_seconds = excluded.duration_seconds,
                        score = excluded.score,
                        response_json = excluded.response_json,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        identity.algorithm,
                        identity.algorithmVersion,
                        identity.fingerprintHash,
                        entry.acoustID,
                        entry.recordingID,
                        entry.title,
                        entry.artist,
                        entry.album,
                        entry.isrc,
                        entry.durationSeconds,
                        entry.score,
                        responseJSON,
                        entry.fetchedAt,
                        entry.fetchedAt
                    ]
                )
            }
        } catch let error as AcoustIDLookupCacheError {
            throw error
        } catch {
            throw AcoustIDLookupCacheError.databaseWriteFailed(message: String(describing: error))
        }
    }

    private func validated(identity: AcoustIDLookupCacheIdentity) throws -> AcoustIDLookupCacheIdentity {
        let algorithm = identity.algorithm.trimmingCharacters(in: .whitespacesAndNewlines)
        let algorithmVersion = identity.algorithmVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprintHash = identity.fingerprintHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !algorithm.isEmpty, !algorithmVersion.isEmpty, !fingerprintHash.isEmpty else {
            throw AcoustIDLookupCacheError.invalidIdentity
        }
        return AcoustIDLookupCacheIdentity(
            algorithm: algorithm,
            algorithmVersion: algorithmVersion,
            fingerprintHash: fingerprintHash
        )
    }

    private func validated(responseJSON: String?) throws -> String? {
        guard let responseJSON else { return nil }
        guard responseJSON.utf8.count <= Self.maximumResponseJSONBytes else {
            throw AcoustIDLookupCacheError.responseJSONTooLarge(maxBytes: Self.maximumResponseJSONBytes)
        }
        guard !responseJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = responseJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw AcoustIDLookupCacheError.invalidResponseJSON
        }
        return responseJSON
    }

    private static func decode(row: Row) -> AcoustIDLookupCacheRow {
        AcoustIDLookupCacheRow(
            id: row["id"],
            identity: AcoustIDLookupCacheIdentity(
                algorithm: row["algorithm"],
                algorithmVersion: row["algorithm_version"],
                fingerprintHash: row["fingerprint_hash"]
            ),
            acoustID: row["acoustid_id"],
            recordingID: row["recording_id"],
            title: row["title"],
            artist: row["artist"],
            album: row["album"],
            isrc: row["isrc"],
            durationSeconds: row["duration_seconds"],
            score: row["score"],
            responseJSON: row["response_json"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}

extension AcoustIDLookupCache: @unchecked Sendable {}
