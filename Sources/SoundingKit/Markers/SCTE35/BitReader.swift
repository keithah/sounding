import Foundation

/// Bounded MSB-first bit reader for SCTE-35 section fields.
public struct BitReader: Equatable, Sendable {
    private let bytes: [UInt8]
    private var bitOffset: Int

    public init(bytes: [UInt8]) {
        self.bytes = bytes
        self.bitOffset = 0
    }

    public init(data: Data) {
        self.init(bytes: [UInt8](data))
    }

    public var remainingBits: Int {
        (bytes.count * 8) - bitOffset
    }

    public mutating func readBits(_ bitCount: Int) throws -> UInt64 {
        guard bitCount >= 0, bitCount <= 64, bitCount <= remainingBits else {
            throw SCTE35DecodeError.boundedReadFailure
        }
        guard bitCount > 0 else {
            return 0
        }

        var value: UInt64 = 0
        for _ in 0..<bitCount {
            let byteIndex = bitOffset / 8
            let bitIndex = 7 - (bitOffset % 8)
            let bit = (bytes[byteIndex] >> UInt8(bitIndex)) & 1
            value = (value << 1) | UInt64(bit)
            bitOffset += 1
        }
        return value
    }
}
