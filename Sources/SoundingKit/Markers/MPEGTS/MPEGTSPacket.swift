import Foundation

/// A single bounded 188-byte MPEG-TS packet with safe header-derived metadata.
public struct MPEGTSPacket: Equatable, Sendable {
    public static let size = 188
    public static let syncByte: UInt8 = 0x47

    public let pid: UInt16
    public let payloadUnitStartIndicator: Bool
    public let continuityCounter: UInt8
    public let adaptationFieldControl: UInt8
    public let payload: Data

    public init(_ data: Data) throws {
        guard data.count == Self.size else {
            throw MPEGTSExtractionError.malformedHeader
        }

        let bytes = [UInt8](data)
        guard bytes[0] == Self.syncByte else {
            throw MPEGTSExtractionError.invalidSync
        }

        let control = (bytes[3] >> 4) & 0x03
        guard control != 0 else {
            throw MPEGTSExtractionError.malformedHeader
        }

        self.pid = (UInt16(bytes[1] & 0x1F) << 8) | UInt16(bytes[2])
        self.payloadUnitStartIndicator = (bytes[1] & 0x40) != 0
        self.continuityCounter = bytes[3] & 0x0F
        self.adaptationFieldControl = control

        var payloadOffset = 4
        let hasAdaptationField = (control & 0x02) != 0
        let hasPayload = (control & 0x01) != 0

        if hasAdaptationField {
            guard payloadOffset < Self.size else {
                throw MPEGTSExtractionError.adaptationFieldOverrun
            }
            let adaptationLength = Int(bytes[payloadOffset])
            payloadOffset += 1
            guard payloadOffset + adaptationLength <= Self.size else {
                throw MPEGTSExtractionError.adaptationFieldOverrun
            }
            payloadOffset += adaptationLength
        }

        if hasPayload, payloadOffset <= Self.size {
            self.payload = data.subdata(in: payloadOffset..<Self.size)
        } else {
            self.payload = Data()
        }
    }
}
