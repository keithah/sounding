import Foundation

public protocol UDPDatagramLoading: Sendable {
    func loadDatagrams(from source: String) async throws -> [Data]
}

public struct UDPReplayDatagramLoader: UDPDatagramLoading {
    private static let datagramSize = MPEGTSPacket.size * 7

    public init() {}

    public func loadDatagrams(from source: String) async throws -> [Data] {
        if let components = URLComponents(string: source), components.scheme?.lowercased() == "udp" {
            throw UDPMonitorAdapterError.unsupportedLiveUDP
        }

        let data: Data
        if let url = URL(string: source), url.scheme != nil {
            data = try Data(contentsOf: url)
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: source))
        }
        return Self.datagrams(from: data)
    }

    private static func datagrams(from data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var datagrams = [Data]()
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: min(datagramSize, data.distance(from: offset, to: data.endIndex)))
            datagrams.append(data[offset..<end])
            offset = end
        }
        return datagrams
    }
}

public struct UDPMonitorAdapter: Sendable {
    private static let sourceClass = "udp_datagram_replay"
    private static let markerSource = "udp"
    private static let markerTag = "mpegts_scte35_section"

    private let source: String
    private let datagramLoader: UDPDatagramLoading

    public init(
        source: String,
        datagramLoader: UDPDatagramLoading = UDPReplayDatagramLoader()
    ) {
        self.source = source
        self.datagramLoader = datagramLoader
    }

    public func markers() async throws -> [AdMarker] {
        let datagrams: [Data]
        do {
            try rejectUnsupportedUDPSource(source)
            datagrams = try await datagramLoader.loadDatagrams(from: source)
        } catch {
            if isTransportExtractionError(error) {
                throw ingestError(error: error, datagramCount: 0)
            }
            throw operationError(
                phase: .sourceOpen,
                context: baseContext(),
                reason: sanitizedReason(for: error)
            )
        }

        let sections: [Data]
        do {
            sections = try UDPDatagramReplay.extractSections(from: datagrams)
        } catch {
            throw ingestError(error: error, datagramCount: datagrams.count)
        }

        return try decodeMarkers(from: sections, datagramCount: datagrams.count)
    }

    private func decodeMarkers(from sections: [Data], datagramCount: Int) throws -> [AdMarker] {
        var markers = [AdMarker]()
        for (index, section) in sections.enumerated() {
            do {
                var marker = try SCTE35Decoder.decodeMarker(
                    .data(section),
                    source: Self.markerSource,
                    tag: Self.markerTag
                )
                marker.tags.merge([
                    "SourceClass": .string(Self.sourceClass),
                    "StreamType": .string("udp"),
                    "SectionIndex": .string(String(index))
                ]) { _, new in new }
                markers.append(marker)
            } catch {
                throw operationError(
                    phase: .decode,
                    context: baseContext().merging([
                        "datagramCount": String(datagramCount),
                        "sectionCount": String(sections.count),
                        "sectionIndex": String(index),
                        "tag": Self.markerTag
                    ]) { _, new in new },
                    reason: sanitizedReason(for: error)
                )
            }
        }
        return markers
    }

    private func rejectUnsupportedUDPSource(_ source: String) throws {
        guard let components = URLComponents(string: source), components.scheme?.lowercased() == "udp" else {
            return
        }

        if components.query != nil || components.user != nil || components.password != nil {
            throw UDPMonitorAdapterError.unsupportedLiveUDP
        }
    }

    private func ingestError(error: Error, datagramCount: Int) -> MonitorError {
        operationError(
            phase: .ingest,
            context: baseContext().merging(["datagramCount": String(datagramCount)]) { _, new in new },
            reason: sanitizedReason(for: error)
        )
    }

    private func baseContext() -> [String: String] {
        [
            "sourceClass": Self.sourceClass,
            "streamType": "udp"
        ]
    }

    private func operationError(phase: MonitorPhase, context: [String: String], reason: String) -> MonitorError {
        MonitorError.operationFailed(
            phase: phase,
            source: source,
            streamType: .udp,
            context: context,
            reason: reason
        )
    }

    private func isTransportExtractionError(_ error: Error) -> Bool {
        error is MPEGTSExtractionError
    }

    private func sanitizedReason(for error: Error) -> String {
        let description: String
        if let localized = error as? LocalizedError, let errorDescription = localized.errorDescription {
            description = errorDescription
        } else {
            description = String(describing: error)
        }
        return MonitorError.redactedSourceDescription(description)
    }
}

private enum UDPMonitorAdapterError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    case unsupportedLiveUDP

    var description: String {
        switch self {
        case .unsupportedLiveUDP:
            return "UDP datagram replay source open failed: unsupported live UDP URL; provide a bounded replay fixture."
        }
    }

    var errorDescription: String? {
        description
    }
}
