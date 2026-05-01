import Foundation

public struct ICYMetadataFrame: Equatable, Sendable {
    public let audioByteCount: Int
    public let metadataLengthByte: UInt8
    public let metadata: Data

    public init(audioByteCount: Int, metadataLengthByte: UInt8, metadata: Data) {
        self.audioByteCount = audioByteCount
        self.metadataLengthByte = metadataLengthByte
        self.metadata = metadata
    }
}

/// Reads one framed ICY metadata interval from an abstract byte source.
///
/// The seam is intentionally a small `(Int) throws -> Data` closure so tests and future
/// adapters can supply URLSession-independent sources. The reader validates exact byte
/// counts and retains only the current frame's metadata block.
public struct ICYMetadataStreamReader {
    public typealias ReadBytes = (Int) throws -> Data

    private let readBytes: ReadBytes

    public init(_ readBytes: @escaping ReadBytes) {
        self.readBytes = readBytes
    }

    public func readFrame(metaInt: Int) throws -> ICYMetadataFrame {
        guard metaInt > 0 else {
            throw ICYMetadataError.invalidMetaInt(metaInt)
        }

        let audio = try readExactByteCount(metaInt, phase: .audio)
        let length = try readExactByteCount(1, phase: .metadataLength)
        let metadataLengthByte = length.first ?? 0
        let metadataByteCount = Int(metadataLengthByte) * 16

        guard metadataByteCount > 0 else {
            return ICYMetadataFrame(audioByteCount: audio.count, metadataLengthByte: metadataLengthByte, metadata: Data())
        }

        let metadata = try readExactByteCount(metadataByteCount, phase: .metadata)
        return ICYMetadataFrame(audioByteCount: audio.count, metadataLengthByte: metadataLengthByte, metadata: metadata)
    }

    private func readExactByteCount(_ count: Int, phase: ICYMetadataReadPhase) throws -> Data {
        let data = try readBytes(count)
        guard data.count == count else {
            throw ICYMetadataError.incompleteRead(
                phase: phase,
                expectedByteCount: count,
                actualByteCount: data.count
            )
        }
        return data
    }
}
