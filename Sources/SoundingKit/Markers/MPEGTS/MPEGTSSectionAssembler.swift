import Foundation

/// Stateful PSI section assembler for one MPEG-TS PID.
///
/// The assembler buffers at most one bounded PSI section. It handles
/// payload-unit-start pointer fields, split sections, continuity resets, and
/// malformed payload resets without exposing raw bytes in errors.
public struct MPEGTSSectionAssembler: Sendable {
    public static let maximumSectionLength = 4096

    private var buffer = Data()
    private var expectedLength: Int?
    private var lastContinuityCounter: UInt8?

    public init() {}

    public mutating func feed(_ packet: MPEGTSPacket) throws -> [Data] {
        if let lastContinuityCounter, !packet.payload.isEmpty {
            let expected = (lastContinuityCounter + 1) & 0x0F
            if packet.continuityCounter != expected {
                reset()
            }
        }
        if !packet.payload.isEmpty {
            lastContinuityCounter = packet.continuityCounter
        }

        guard !packet.payload.isEmpty else { return [] }

        var payload = packet.payload
        var sections = [Data]()

        if packet.payloadUnitStartIndicator {
            guard let pointer = payload.first else {
                reset()
                throw MPEGTSExtractionError.pointerFieldOverrun
            }
            payload.removeFirst()

            let pointerLength = Int(pointer)
            guard pointerLength <= payload.count else {
                reset()
                throw MPEGTSExtractionError.pointerFieldOverrun
            }

            if pointerLength > 0, !buffer.isEmpty {
                let prefix = payload.prefix(pointerLength)
                try appendSectionBytes(prefix, sections: &sections)
            }

            payload.removeFirst(pointerLength)
            resetSectionBuffer(keepingContinuity: true)
        }

        try appendSectionBytes(payload, sections: &sections)
        return sections
    }

    private mutating func appendSectionBytes(_ bytes: Data, sections: inout [Data]) throws {
        guard !bytes.isEmpty else { return }

        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            if buffer.isEmpty, bytes[offset] == 0xFF {
                break
            }

            if expectedLength == nil, buffer.count < 3 {
                let neededHeaderBytes = 3 - buffer.count
                let take = min(neededHeaderBytes, bytes.distance(from: offset, to: bytes.endIndex))
                buffer.append(bytes[offset..<bytes.index(offset, offsetBy: take)])
                offset = bytes.index(offset, offsetBy: take)

                if buffer.count == 3 {
                    expectedLength = try sectionTotalLength(from: buffer)
                }
                continue
            }

            guard let expectedLength else { continue }
            let remaining = expectedLength - buffer.count
            guard remaining >= 0 else {
                resetSectionBuffer(keepingContinuity: true)
                throw MPEGTSExtractionError.invalidSectionLength
            }

            let availableEnd = trailingStuffingStart(in: bytes, from: offset) ?? bytes.endIndex
            let available = bytes.distance(from: offset, to: availableEnd)
            if available == 0 {
                break
            }

            let take = min(remaining, available)
            if take > 0 {
                buffer.append(bytes[offset..<bytes.index(offset, offsetBy: take)])
                offset = bytes.index(offset, offsetBy: take)
            }

            if buffer.count == expectedLength {
                sections.append(buffer)
                resetSectionBuffer(keepingContinuity: true)
            }

            if take == 0 { break }
        }
    }

    private func sectionTotalLength(from header: Data) throws -> Int {
        precondition(header.count >= 3)
        let bytes = [UInt8](header.prefix(3))
        let sectionLength = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        let totalLength = 3 + sectionLength

        guard sectionLength > 0, totalLength <= Self.maximumSectionLength else {
            throw MPEGTSExtractionError.invalidSectionLength
        }
        return totalLength
    }

    private func trailingStuffingStart(in bytes: Data, from offset: Data.Index) -> Data.Index? {
        var candidate = offset
        while candidate < bytes.endIndex {
            if bytes[candidate] == 0xFF, bytes[candidate..<bytes.endIndex].allSatisfy({ $0 == 0xFF }) {
                return candidate
            }
            candidate = bytes.index(after: candidate)
        }
        return nil
    }

    private mutating func reset() {
        resetSectionBuffer(keepingContinuity: false)
    }

    private mutating func resetSectionBuffer(keepingContinuity: Bool) {
        buffer.removeAll(keepingCapacity: true)
        expectedLength = nil
        if !keepingContinuity {
            lastContinuityCounter = nil
        }
    }
}
