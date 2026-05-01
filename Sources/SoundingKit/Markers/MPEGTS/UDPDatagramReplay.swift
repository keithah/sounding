import Foundation

/// Replays UDP-style datagrams through the native MPEG-TS section extractor.
public enum UDPDatagramReplay {
    public static func extractSections(from datagrams: [Data]) throws -> [Data] {
        var extractor = MPEGTSSectionExtractor()
        var sections = [Data]()
        for datagram in datagrams {
            sections.append(contentsOf: try extractor.feed(datagram))
        }
        try extractor.finishDatagramReplay()
        return sections
    }
}
