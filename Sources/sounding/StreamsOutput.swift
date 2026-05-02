import Foundation
import SoundingKit

enum StreamsOutput {
    enum OutputError: Error, Equatable {
        case encodingFailed
    }

    struct Payload: Codable, Equatable {
        var streams: [Stream]
    }

    struct RuntimeStatusPayload: Codable, Equatable {
        var streams: [RuntimeStatus]
    }

    struct RuntimeStatus: Codable, Equatable {
        var id: Int64
        var name: String
        var streamType: String
        var streamStatus: String
        var source: String
        var phase: String
        var hasRuntimeStatus: Bool
        var attempt: Int
        var maxAttempts: Int
        var nextRetrySeconds: Int?
        var nextRetryAt: String?
        var updatedAt: String?
        var recentFailure: RecentFailure?
        var latestHLSDecision: HLSDecision?
    }

    struct HLSDecision: Codable, Equatable {
        var reason: String
        var severity: String
        var decision: String?
        var mediaSequence: Int?
        var expectedMediaSequence: Int?
        var observedMediaSequence: Int?
        var previousMediaSequence: Int?
        var segmentIdentity: String?
        var segmentIdentityHash: String?
        var existingSegmentIdentity: String?
        var existingSegmentIdentityHash: String?
        var currentRunID: Int64?
        var existingRunID: Int64?
        var existingChunkID: Int64?
        var createdAt: String
    }

    struct RecentFailure: Codable, Equatable {
        var message: String
        var occurredAt: String
    }

    struct Stream: Codable, Equatable {
        var id: Int64
        var name: String
        var streamType: String
        var status: String
        var source: String
        var createdAt: String
        var updatedAt: String
        var pausedAt: String?
        var resumedAt: String?
        var removedAt: String?
    }

    static func encodeJSON(_ records: [StreamRecord]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(Payload(streams: records.map(sanitizedStream)))
            return String(decoding: data, as: UTF8.self) + "\n"
        } catch {
            throw OutputError.encodingFailed
        }
    }

    static func encodeRuntimeStatusJSON(_ records: [AppStreamRuntimeStatusInspection]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(
                RuntimeStatusPayload(streams: records.map(sanitizedRuntimeStatus)))
            return String(decoding: data, as: UTF8.self) + "\n"
        } catch {
            throw OutputError.encodingFailed
        }
    }

    static func formatListHuman(_ records: [StreamRecord]) -> String {
        guard !records.isEmpty else {
            return "No streams found.\n"
        }

        return records.map { record in
            "id=\(record.id) name=\(record.name) type=\(record.streamType) status=\(record.status.rawValue) created_at=\(record.createdAt) updated_at=\(record.updatedAt) paused_at=\(optionalTimestamp(record.pausedAt)) resumed_at=\(optionalTimestamp(record.resumedAt)) removed_at=\(optionalTimestamp(record.removedAt)) source=\(redactedSourceDescription(record.sourceDescription))"
        }.joined(separator: "\n") + "\n"
    }

    static func formatRuntimeStatusHuman(_ records: [AppStreamRuntimeStatusInspection]) -> String {
        guard !records.isEmpty else {
            return "No streams found.\n"
        }

        return records.map { record in
            "id=\(record.streamID) name=\(record.name) type=\(record.streamType) stream_status=\(record.streamStatus) source=\(redactedSourceDescription(record.sourceDescription)) phase=\(record.phase) has_runtime_status=\(record.hasRuntimeStatus) attempt=\(record.attempt) max_attempts=\(record.maxAttempts) next_retry_seconds=\(optionalInt(record.nextRetrySeconds)) next_retry_at=\(optionalTimestamp(record.nextRetryAt)) updated_at=\(optionalTimestamp(record.updatedAt)) recent_failure=\(optionalFailure(record.recentFailure)) latest_hls_decision=\(optionalHLSDecision(record.latestHLSDecision))"
        }.joined(separator: "\n") + "\n"
    }

    static func formatMutationHuman(action: String, result: StreamMutationResult) -> String {
        let changed = result.changed ? "changed" : "unchanged"
        return
            "stream \(action): id=\(result.record.id) name=\(result.record.name) status=\(result.record.status.rawValue) result=\(changed)\n"
    }

    static func formatAddHuman(_ record: StreamRecord) -> String {
        "stream added: id=\(record.id) name=\(record.name) type=\(record.streamType) status=\(record.status.rawValue) source=\(redactedSourceDescription(record.sourceDescription))\n"
    }

    private static func sanitizedStream(_ record: StreamRecord) -> Stream {
        Stream(
            id: record.id,
            name: record.name,
            streamType: record.streamType,
            status: record.status.rawValue,
            source: redactedSourceDescription(record.sourceDescription),
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            pausedAt: record.pausedAt,
            resumedAt: record.resumedAt,
            removedAt: record.removedAt
        )
    }

    private static func sanitizedRuntimeStatus(_ record: AppStreamRuntimeStatusInspection)
        -> RuntimeStatus
    {
        RuntimeStatus(
            id: record.streamID,
            name: record.name,
            streamType: record.streamType,
            streamStatus: record.streamStatus,
            source: redactedSourceDescription(record.sourceDescription),
            phase: record.phase,
            hasRuntimeStatus: record.hasRuntimeStatus,
            attempt: record.attempt,
            maxAttempts: record.maxAttempts,
            nextRetrySeconds: record.nextRetrySeconds,
            nextRetryAt: record.nextRetryAt,
            updatedAt: record.updatedAt,
            recentFailure: record.recentFailure.map {
                RecentFailure(message: redactedSourceDescription($0.message), occurredAt: $0.occurredAt)
            },
            latestHLSDecision: record.latestHLSDecision.map(sanitizedHLSDecision)
        )
    }

    private static func sanitizedHLSDecision(_ decision: AppStreamRuntimeHLSDecision) -> HLSDecision {
        HLSDecision(
            reason: redactedSourceDescription(decision.reason),
            severity: redactedSourceDescription(decision.severity),
            decision: decision.decision.map(redactedSourceDescription),
            mediaSequence: decision.mediaSequence,
            expectedMediaSequence: decision.expectedMediaSequence,
            observedMediaSequence: decision.observedMediaSequence,
            previousMediaSequence: decision.previousMediaSequence,
            segmentIdentity: decision.segmentIdentity.map(redactedSourceDescription),
            segmentIdentityHash: decision.segmentIdentityHash.map(redactedSourceDescription),
            existingSegmentIdentity: decision.existingSegmentIdentity.map(redactedSourceDescription),
            existingSegmentIdentityHash: decision.existingSegmentIdentityHash.map(redactedSourceDescription),
            currentRunID: decision.currentRunID,
            existingRunID: decision.existingRunID,
            existingChunkID: decision.existingChunkID,
            createdAt: redactedSourceDescription(decision.createdAt)
        )
    }

    private static func optionalTimestamp(_ value: String?) -> String {
        value ?? "none"
    }

    private static func optionalInt(_ value: Int?) -> String {
        value.map(String.init) ?? "none"
    }

    private static func optionalFailure(_ failure: AppStreamRuntimeRecentFailure?) -> String {
        guard let failure else { return "none" }
        return "\(redactedSourceDescription(failure.message)) at \(failure.occurredAt)"
    }

    private static func optionalHLSDecision(_ decision: AppStreamRuntimeHLSDecision?) -> String {
        guard let decision else { return "none" }
        var fields = [
            "reason=\(redactedSourceDescription(decision.reason))",
            "severity=\(redactedSourceDescription(decision.severity))",
            "created_at=\(redactedSourceDescription(decision.createdAt))",
        ]
        if let value = decision.decision { fields.append("decision=\(redactedSourceDescription(value))") }
        if let value = decision.mediaSequence { fields.append("media_sequence=\(value)") }
        if let value = decision.expectedMediaSequence { fields.append("expected_media_sequence=\(value)") }
        if let value = decision.observedMediaSequence { fields.append("observed_media_sequence=\(value)") }
        if let value = decision.previousMediaSequence { fields.append("previous_media_sequence=\(value)") }
        if let value = decision.segmentIdentity { fields.append("segment_identity=\(redactedSourceDescription(value))") }
        if let value = decision.existingRunID { fields.append("existing_run=\(value)") }
        if let value = decision.existingChunkID { fields.append("existing_chunk=\(value)") }
        if let value = decision.currentRunID { fields.append("current_run=\(value)") }
        return fields.joined(separator: ",")
    }

    private static func redactedSourceDescription(_ source: String) -> String {
        MonitorError.redactedSourceDescription(source)
    }
}
