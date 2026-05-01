import Foundation

/// Public ID3 marker facade that exposes only safe metadata through the AdMarker contract.
public enum ID3MarkerDecoder {
    public static func decodeMarkers(
        fromSegmentBytes data: Data,
        source: String = "hls_segment",
        tag: String = "ID3",
        segment: String? = nil,
        timestamp: String? = nil
    ) throws -> [AdMarker] {
        let tags = try ID3TagScanner.scan(data)
        guard !tags.isEmpty else { return [] }

        let reader = ID3FrameReader()
        return try tags.map { tagBytes in
            let frames = try reader.readFrames(from: tagBytes)
            return map(
                frames,
                source: sanitizedSource(source),
                tag: tag,
                segment: segment,
                timestamp: timestamp
            )
        }
    }

    private static func map(
        _ frames: [ID3Frame],
        source: String,
        tag: String,
        segment: String?,
        timestamp: String?
    ) -> AdMarker {
        let indexedFrames = frames.enumerated().map { IndexedFrame(index: $0.offset, frame: $0.element) }
        let sortedFrames = indexedFrames.sorted { lhs, rhs in
            if lhs.id == rhs.id { return lhs.index < rhs.index }
            return lhs.id < rhs.id
        }

        var tags: [String: JSONValue] = [:]
        var frameIDs: [JSONValue] = []
        var frameObjects: [JSONValue] = []
        var privateOwners: [JSONValue] = []
        var privateFrameCount = 0
        var firstTimestamp: ID3TransportTimestamp?

        for indexedFrame in sortedFrames {
            frameIDs.append(.string(indexedFrame.id))
            frameObjects.append(frameJSON(for: indexedFrame))
            addTagSummary(for: indexedFrame.frame, to: &tags)

            if case let .private(owner, _, transportTimestamp) = indexedFrame.frame {
                privateFrameCount += 1
                privateOwners.append(.string(owner))
                if firstTimestamp == nil, let transportTimestamp {
                    firstTimestamp = transportTimestamp
                }
            }
        }

        var fields: [String: JSONValue] = [
            "FrameIDs": .array(frameIDs),
            "Frames": .array(frameObjects)
        ]

        if privateFrameCount > 0 {
            fields["PrivateOwners"] = .array(privateOwners)
            fields["PrivateFrameCount"] = .number(Double(privateFrameCount))
        }
        if let firstTimestamp {
            fields["TimestampTicks"] = .number(Double(firstTimestamp.ticks))
            fields["TimestampSeconds"] = .number(firstTimestamp.seconds)
        }

        return AdMarker(
            type: "ID3",
            classification: .unknown,
            source: source,
            tag: tag,
            pts: firstTimestamp?.seconds,
            segment: segment,
            rawBase64: nil,
            command: nil,
            descriptors: [],
            tags: tags,
            fields: fields,
            timestamp: timestamp
        )
    }

    private static func frameJSON(for indexedFrame: IndexedFrame) -> JSONValue {
        var object: [String: JSONValue] = [
            "ID": .string(indexedFrame.id),
            "Index": .number(Double(indexedFrame.index))
        ]

        switch indexedFrame.frame {
        case let .text(_, texts):
            object["Texts"] = textArray(texts)
        case let .userText(description, texts):
            object["Description"] = .string(description)
            object["Texts"] = textArray(texts)
        case let .private(owner, dataLength, transportTimestamp):
            object["Owner"] = .string(owner)
            object["DataLength"] = .number(Double(dataLength))
            if let transportTimestamp {
                object["TimestampTicks"] = .number(Double(transportTimestamp.ticks))
                object["TimestampSeconds"] = .number(transportTimestamp.seconds)
            }
        case let .unsupported(_, dataLength):
            object["DataLength"] = .number(Double(dataLength))
        }

        return .object(object)
    }

    private static func addTagSummary(for frame: ID3Frame, to tags: inout [String: JSONValue]) {
        switch frame {
        case let .text(id, texts):
            guard let summary = textSummary(texts) else { return }
            tags[id] = .string(summary)
        case let .userText(description, texts):
            guard let summary = textSummary(texts) else { return }
            tags["TXXX:\(description)"] = .string(summary)
        case .private, .unsupported:
            return
        }
    }

    private static func textArray(_ texts: [String]) -> JSONValue {
        .array(texts.map { .string($0) })
    }

    private static func textSummary(_ texts: [String]) -> String? {
        let nonEmpty = texts.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        return nonEmpty.joined(separator: "|")
    }

    private static func sanitizedSource(_ source: String) -> String {
        guard var components = URLComponents(string: source), components.scheme != nil else {
            return source
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? source
    }

    private struct IndexedFrame {
        let index: Int
        let frame: ID3Frame

        var id: String {
            switch frame {
            case let .text(id, _):
                return id
            case .userText:
                return "TXXX"
            case .private:
                return "PRIV"
            case let .unsupported(id, _):
                return id
            }
        }
    }
}
