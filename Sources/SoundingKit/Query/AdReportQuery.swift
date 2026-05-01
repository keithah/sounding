import Foundation
import GRDB

/// Read-only ad marker report service over the persisted marker timeline.
public struct AdReportQuery {
    public typealias Filter = SongReportQuery.Filter
    public typealias QueryError = SongReportQuery.QueryError

    public struct EventIdentity: Codable, Equatable, Sendable {
        public var eventID: Int64
        public var streamID: Int64
        public var streamType: String
        public var streamSource: String
        public var runID: Int64
        public var chunkID: Int64?
        public var chunkSequence: Int?

        public init(
            eventID: Int64,
            streamID: Int64,
            streamType: String,
            streamSource: String,
            runID: Int64,
            chunkID: Int64?,
            chunkSequence: Int?
        ) {
            self.eventID = eventID
            self.streamID = streamID
            self.streamType = streamType
            self.streamSource = streamSource
            self.runID = runID
            self.chunkID = chunkID
            self.chunkSequence = chunkSequence
        }
    }

    public struct EventResult: Codable, Equatable, Sendable {
        public var identity: EventIdentity
        public var classification: MarkerClassification
        public var markerType: String
        public var source: String
        public var pts: Double?
        public var segment: String?
        public var observedAt: String

        public init(
            identity: EventIdentity,
            classification: MarkerClassification,
            markerType: String,
            source: String,
            pts: Double?,
            segment: String?,
            observedAt: String
        ) {
            self.identity = identity
            self.classification = classification
            self.markerType = markerType
            self.source = source
            self.pts = pts
            self.segment = segment
            self.observedAt = observedAt
        }
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var unknown: Int
        public var adStart: Int
        public var adEnd: Int

        public init(unknown: Int = 0, adStart: Int = 0, adEnd: Int = 0) {
            self.unknown = unknown
            self.adStart = adStart
            self.adEnd = adEnd
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public var events: [EventResult]
        public var summary: Summary

        public init(events: [EventResult], summary: Summary) {
            self.events = events
            self.summary = summary
        }
    }

    private let database: SoundingDatabase

    public init(database: SoundingDatabase) {
        self.database = database
    }

    public func events(filter: Filter = Filter()) throws -> Result {
        let normalized = try SongReportQuery.validate(filter)

        do {
            return try database.read { db in
                var clauses: [String] = []
                var arguments = StatementArguments()

                if let stream = normalized.stream {
                    SongReportQuery.appendStreamFilterClause(
                        stream, clauses: &clauses, arguments: &arguments)
                }
                if let startSeconds = normalized.startSeconds {
                    clauses.append("ad_events.pts IS NOT NULL")
                    clauses.append("ad_events.pts >= ?")
                    arguments += [startSeconds]
                }
                if let endSeconds = normalized.endSeconds {
                    if normalized.startSeconds == nil {
                        clauses.append("ad_events.pts IS NOT NULL")
                    }
                    clauses.append("ad_events.pts <= ?")
                    arguments += [endSeconds]
                }

                let whereClause =
                    clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT
                            ad_events.id AS event_id,
                            streams.id AS stream_id,
                            streams.stream_type,
                            streams.source AS stream_source,
                            ingest_runs.id AS run_id,
                            ingest_chunks.id AS chunk_id,
                            ingest_chunks.sequence AS chunk_sequence,
                            ad_events.classification,
                            ad_events.marker_type,
                            ad_events.source AS event_source,
                            ad_events.pts,
                            ad_events.segment,
                            ad_events.observed_at
                        FROM ad_events
                        JOIN ingest_runs ON ingest_runs.id = ad_events.run_id
                        JOIN streams ON streams.id = ingest_runs.stream_id
                        LEFT JOIN ingest_chunks ON ingest_chunks.id = ad_events.chunk_id
                        \(whereClause)
                        ORDER BY streams.id,
                                 ingest_runs.id,
                                 COALESCE(ad_events.pts, 0),
                                 ad_events.observed_at,
                                 ad_events.id
                        """,
                    arguments: arguments
                )

                let events = try rows.map(eventResult)
                return Result(events: events, summary: summary(for: events))
            }
        } catch let error as QueryError {
            throw error
        } catch {
            throw QueryError.databaseReadFailed
        }
    }

    private func eventResult(_ row: Row) throws -> EventResult {
        guard let eventID: Int64 = row["event_id"] else {
            throw QueryError.malformedRow("event_id")
        }
        guard let streamID: Int64 = row["stream_id"] else {
            throw QueryError.malformedRow("stream_id")
        }
        guard let streamType: String = row["stream_type"] else {
            throw QueryError.malformedRow("stream_type")
        }
        guard let streamSource: String = row["stream_source"] else {
            throw QueryError.malformedRow("stream_source")
        }
        guard let runID: Int64 = row["run_id"] else { throw QueryError.malformedRow("run_id") }
        guard let rawClassification: String = row["classification"] else {
            throw QueryError.malformedRow("classification")
        }
        guard let classification = MarkerClassification(rawValue: rawClassification) else {
            throw QueryError.malformedRow("classification")
        }
        guard let markerType: String = row["marker_type"] else {
            throw QueryError.malformedRow("marker_type")
        }
        guard let source: String = row["event_source"] else {
            throw QueryError.malformedRow("source")
        }
        guard let observedAt: String = row["observed_at"] else {
            throw QueryError.malformedRow("observed_at")
        }

        return EventResult(
            identity: EventIdentity(
                eventID: eventID,
                streamID: streamID,
                streamType: streamType,
                streamSource: streamSource,
                runID: runID,
                chunkID: row["chunk_id"],
                chunkSequence: row["chunk_sequence"]
            ),
            classification: classification,
            markerType: markerType,
            source: source,
            pts: row["pts"],
            segment: row["segment"],
            observedAt: observedAt
        )
    }

    private func summary(for events: [EventResult]) -> Summary {
        events.reduce(into: Summary()) { summary, event in
            switch event.classification {
            case .unknown:
                summary.unknown += 1
            case .adStart:
                summary.adStart += 1
            case .adEnd:
                summary.adEnd += 1
            }
        }
    }
}
