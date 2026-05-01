import Foundation
import SoundingKit

enum StreamsOutput {
    enum OutputError: Error, Equatable {
        case encodingFailed
    }

    struct Payload: Codable, Equatable {
        var streams: [Stream]
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

    static func formatListHuman(_ records: [StreamRecord]) -> String {
        guard !records.isEmpty else {
            return "No streams found.\n"
        }

        return records.map { record in
            "id=\(record.id) name=\(record.name) type=\(record.streamType) status=\(record.status.rawValue) created_at=\(record.createdAt) updated_at=\(record.updatedAt) paused_at=\(optionalTimestamp(record.pausedAt)) resumed_at=\(optionalTimestamp(record.resumedAt)) removed_at=\(optionalTimestamp(record.removedAt)) source=\(redactedSourceDescription(record.sourceDescription))"
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

    private static func optionalTimestamp(_ value: String?) -> String {
        value ?? "none"
    }

    private static func redactedSourceDescription(_ source: String) -> String {
        MonitorError.redactedSourceDescription(source)
    }
}
