import Foundation

/// Sanitized MPEG-TS extraction failures.
///
/// Descriptions intentionally name only safe structural failure classes. They
/// never include raw packet bytes, section bytes, datagram contents, source URLs,
/// request headers, or caller-provided source strings.
public enum MPEGTSExtractionError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidSync
    case malformedHeader
    case adaptationFieldOverrun
    case pointerFieldOverrun
    case invalidSectionLength
    case packetTooLarge
    case truncatedDatagram

    public var description: String {
        switch self {
        case .invalidSync:
            return ingestDescription("transport packet sync byte is invalid")
        case .malformedHeader:
            return ingestDescription("transport packet header is malformed")
        case .adaptationFieldOverrun:
            return ingestDescription("adaptation field exceeds transport packet bounds")
        case .pointerFieldOverrun:
            return ingestDescription("PSI pointer field exceeds payload bounds")
        case .invalidSectionLength:
            return ingestDescription("PSI section length is invalid or exceeds bounds")
        case .packetTooLarge:
            return ingestDescription("transport packet buffer exceeded bounded packet size")
        case .truncatedDatagram:
            return ingestDescription("datagram replay ended with a truncated transport packet")
        }
    }

    private func ingestDescription(_ reason: String) -> String {
        "MPEGTS ingest failed: \(reason)."
    }
}
