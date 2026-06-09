import Foundation
import GRDB

public struct TranscriptAdClassificationCacheIdentity: Equatable, Sendable {
    public var segmentID: Int64
    public var classifier: String
    public var classifierVersion: String

    public init(segmentID: Int64, classifier: String, classifierVersion: String) {
        self.segmentID = segmentID
        self.classifier = classifier
        self.classifierVersion = classifierVersion
    }
}

public struct TranscriptAdClassificationCacheEntry: Equatable, Sendable {
    public var identity: TranscriptAdClassificationCacheIdentity
    public var isAd: Bool
    public var confidence: Double
    public var signals: [String]
    public var classifiedAt: String

    public init(
        identity: TranscriptAdClassificationCacheIdentity,
        isAd: Bool,
        confidence: Double,
        signals: [String],
        classifiedAt: String
    ) {
        self.identity = identity
        self.isAd = isAd
        self.confidence = confidence
        self.signals = signals
        self.classifiedAt = classifiedAt
    }
}

public struct TranscriptAdClassificationCacheRow: Equatable, Sendable {
    public var id: Int64
    public var identity: TranscriptAdClassificationCacheIdentity
    public var isAd: Bool
    public var confidence: Double
    public var signals: [String]
    public var createdAt: String
    public var updatedAt: String
}

public enum TranscriptAdClassificationCacheError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidConfidence
    case invalidSignals
    case databaseReadFailed(message: String)
    case databaseWriteFailed(message: String)
}

public final class TranscriptAdClassificationCache {
    private let database: SoundingDatabase

    public init(database: SoundingDatabase) {
        self.database = database
    }

    public func fetch(identity: TranscriptAdClassificationCacheIdentity) throws -> TranscriptAdClassificationCacheRow? {
        let identity = try validated(identity: identity)
        do {
            return try database.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id, segment_id, classifier, classifier_version, is_ad, confidence,
                           signals_json, created_at, updated_at
                    FROM transcript_ad_classification_cache
                    WHERE segment_id = ?
                      AND classifier = ?
                      AND classifier_version = ?
                    LIMIT 1
                    """,
                    arguments: [identity.segmentID, identity.classifier, identity.classifierVersion]
                ).map(Self.decode(row:))
            }
        } catch let error as TranscriptAdClassificationCacheError {
            throw error
        } catch {
            throw TranscriptAdClassificationCacheError.databaseReadFailed(message: String(describing: error))
        }
    }

    static func fetch(
        segmentIDs: [Int64],
        classifier: String = TranscriptAdScorer.classifier,
        classifierVersion: String = TranscriptAdScorer.classifierVersion,
        db: Database
    ) throws -> [Int64: TranscriptAdClassificationCacheRow] {
        let segmentIDs = Array(Set(segmentIDs.filter { $0 > 0 })).sorted()
        let classifier = classifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let classifierVersion = classifierVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segmentIDs.isEmpty else { return [:] }
        guard !classifier.isEmpty, !classifierVersion.isEmpty else {
            throw TranscriptAdClassificationCacheError.invalidIdentity
        }

        let placeholders = Array(repeating: "?", count: segmentIDs.count).joined(separator: ", ")
        var arguments = StatementArguments()
        segmentIDs.forEach { arguments += [$0] }
        arguments += [classifier, classifierVersion]
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, segment_id, classifier, classifier_version, is_ad, confidence,
                   signals_json, created_at, updated_at
            FROM transcript_ad_classification_cache
            WHERE segment_id IN (\(placeholders))
              AND classifier = ?
              AND classifier_version = ?
            """,
            arguments: arguments
        )
        return try Dictionary(uniqueKeysWithValues: rows.map { row in
            let decoded = try Self.decode(row: row)
            return (decoded.identity.segmentID, decoded)
        })
    }

    public func upsert(_ entry: TranscriptAdClassificationCacheEntry) throws {
        let identity = try validated(identity: entry.identity)
        let confidence = try validated(confidence: entry.confidence)
        let signalsJSON = try encodedSignals(entry.signals)

        do {
            try database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO transcript_ad_classification_cache (
                        segment_id, classifier, classifier_version, is_ad, confidence,
                        signals_json, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(segment_id, classifier, classifier_version) DO UPDATE SET
                        is_ad = excluded.is_ad,
                        confidence = excluded.confidence,
                        signals_json = excluded.signals_json,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        identity.segmentID,
                        identity.classifier,
                        identity.classifierVersion,
                        entry.isAd,
                        confidence,
                        signalsJSON,
                        entry.classifiedAt,
                        entry.classifiedAt,
                    ]
                )
            }
        } catch let error as TranscriptAdClassificationCacheError {
            throw error
        } catch {
            throw TranscriptAdClassificationCacheError.databaseWriteFailed(message: String(describing: error))
        }
    }

    private func validated(
        identity: TranscriptAdClassificationCacheIdentity
    ) throws -> TranscriptAdClassificationCacheIdentity {
        let classifier = identity.classifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let classifierVersion = identity.classifierVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identity.segmentID > 0, !classifier.isEmpty, !classifierVersion.isEmpty else {
            throw TranscriptAdClassificationCacheError.invalidIdentity
        }
        return TranscriptAdClassificationCacheIdentity(
            segmentID: identity.segmentID,
            classifier: classifier,
            classifierVersion: classifierVersion
        )
    }

    private func validated(confidence: Double) throws -> Double {
        guard confidence.isFinite, confidence >= 0, confidence <= 1 else {
            throw TranscriptAdClassificationCacheError.invalidConfidence
        }
        return confidence
    }

    private func encodedSignals(_ signals: [String]) throws -> String {
        let trimmed = signals.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.allSatisfy({ !$0.isEmpty }) else {
            throw TranscriptAdClassificationCacheError.invalidSignals
        }
        guard let data = try? JSONSerialization.data(withJSONObject: trimmed, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            throw TranscriptAdClassificationCacheError.invalidSignals
        }
        return json
    }

    private static func decode(row: Row) throws -> TranscriptAdClassificationCacheRow {
        let signalsJSON: String = row["signals_json"]
        guard let data = signalsJSON.data(using: .utf8),
              let signals = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw TranscriptAdClassificationCacheError.invalidSignals
        }
        return TranscriptAdClassificationCacheRow(
            id: row["id"],
            identity: TranscriptAdClassificationCacheIdentity(
                segmentID: row["segment_id"],
                classifier: row["classifier"],
                classifierVersion: row["classifier_version"]
            ),
            isAd: row["is_ad"],
            confidence: row["confidence"],
            signals: signals,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}

extension TranscriptAdClassificationCache: @unchecked Sendable {}
