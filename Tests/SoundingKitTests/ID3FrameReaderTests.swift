import Foundation
import XCTest
@testable import SoundingKit

final class ID3FrameReaderTests: XCTestCase {
    func testReadsVersion24SynchsafeTextAndPrivateFrames() throws {
        let timestampTicks: UInt64 = 180_000
        let tag = try makeScannedTag(
            major: 4,
            frames: [
                makeFrame(id: "TIT2", payload: textPayload(encoding: 3, "Primary Cue"), versionMajor: 4),
                makeFrame(id: "TIT3", payload: textPayload(encoding: 0, "Subtitle Cue"), versionMajor: 4),
                makeFrame(id: "TXXX", payload: textPayload(encoding: 3, "SCTE35", "splice_insert"), versionMajor: 4),
                makeFrame(
                    id: "PRIV",
                    payload: privatePayload(
                        owner: "com.apple.streaming.transportStreamTimestamp",
                        data: timestampPayload(ticks: timestampTicks)
                    ),
                    versionMajor: 4
                )
            ]
        )

        let frames = try ID3FrameReader().readFrames(from: tag)

        XCTAssertEqual(frames, [
            .text(id: "TIT2", texts: ["Primary Cue"]),
            .text(id: "TIT3", texts: ["Subtitle Cue"]),
            .userText(description: "SCTE35", texts: ["splice_insert"]),
            .private(
                owner: "com.apple.streaming.transportStreamTimestamp",
                dataLength: 8,
                transportTimestamp: .init(ticks: timestampTicks, seconds: 2.0)
            )
        ])
    }

    func testReadsVersion23BigEndianFrameSizes() throws {
        let tag = try makeScannedTag(
            major: 3,
            frames: [
                makeFrame(id: "TIT2", payload: textPayload(encoding: 3, "v23 title"), versionMajor: 3),
                makeFrame(id: "WXXX", payload: Data([0x01, 0x02, 0x03]), versionMajor: 3)
            ]
        )

        let frames = try ID3FrameReader().readFrames(from: tag)

        XCTAssertEqual(frames, [
            .text(id: "TIT2", texts: ["v23 title"]),
            .unsupported(id: "WXXX", dataLength: 3)
        ])
    }

    func testStopsAtZeroPaddingAndAllowsDuplicateFrames() throws {
        let payload = makeFrame(id: "TXXX", payload: textPayload(encoding: 3, "first", "one"), versionMajor: 4)
            + makeFrame(id: "TXXX", payload: textPayload(encoding: 3, "second", "two"), versionMajor: 4)
            + Data(repeating: 0, count: 20)
            + makeFrame(id: "TIT2", payload: textPayload(encoding: 3, "ignored after padding"), versionMajor: 4)
        let tag = try makeScannedTag(major: 4, payload: payload)

        let frames = try ID3FrameReader().readFrames(from: tag)

        XCTAssertEqual(frames, [
            .userText(description: "first", texts: ["one"]),
            .userText(description: "second", texts: ["two"])
        ])
    }

    func testDecodesSupportedTextEncodings() throws {
        let utf16WithBOM = Data([0x01, 0xFF, 0xFE]) + utf16LEBytes("BOM text") + Data([0x00, 0x00])
        let utf16BE = Data([0x02]) + utf16BEBytes("Big text") + Data([0x00, 0x00])
        let latin1 = textPayload(encoding: 0, "Cafe\u{00E9}")
        let utf8 = textPayload(encoding: 3, "Snowman \u{2603}")
        let tag = try makeScannedTag(
            major: 4,
            frames: [
                makeFrame(id: "TIT2", payload: latin1, versionMajor: 4),
                makeFrame(id: "TIT2", payload: utf16WithBOM, versionMajor: 4),
                makeFrame(id: "TIT2", payload: utf16BE, versionMajor: 4),
                makeFrame(id: "TIT2", payload: utf8, versionMajor: 4)
            ]
        )

        let frames = try ID3FrameReader().readFrames(from: tag)

        XCTAssertEqual(frames, [
            .text(id: "TIT2", texts: ["Cafe\u{00E9}"]),
            .text(id: "TIT2", texts: ["BOM text"]),
            .text(id: "TIT2", texts: ["Big text"]),
            .text(id: "TIT2", texts: ["Snowman \u{2603}"])
        ])
    }

    func testFrameDeclaredBeyondTagPayloadThrowsSanitizedParseError() throws {
        let payload = frameHeader(id: "TIT2", payloadSize: 10, versionMajor: 4) + Data([0x03, 0x41])
        let tag = try makeScannedTag(major: 4, payload: payload)

        assertReaderThrows(tag, expected: .malformedFrame)
    }

    func testUnsupportedFrameFlagsThrowSanitizedParseError() throws {
        let tag = try makeScannedTag(
            major: 4,
            frames: [makeFrame(id: "TIT2", payload: textPayload(encoding: 3, "compressed"), versionMajor: 4, flags: [0x00, 0x08])]
        )

        assertReaderThrows(tag, expected: .unsupportedFrameFlags)
    }

    func testUnknownTextEncodingThrowsSanitizedParseError() throws {
        let tag = try makeScannedTag(
            major: 4,
            frames: [makeFrame(id: "TIT2", payload: Data([0x04, 0x41, 0x42]), versionMajor: 4)]
        )

        assertReaderThrows(tag, expected: .unsupportedFrameEncoding)
    }

    func testPrivateFrameWithoutOwnerTerminatorThrowsSanitizedParseError() throws {
        let tag = try makeScannedTag(
            major: 4,
            frames: [makeFrame(id: "PRIV", payload: Data("unterminated-owner".utf8), versionMajor: 4)]
        )

        assertReaderThrows(tag, expected: .malformedFrame)
    }

    func testAppleTimestampRequiresEightPrivateBytes() throws {
        let tag = try makeScannedTag(
            major: 4,
            frames: [
                makeFrame(
                    id: "PRIV",
                    payload: privatePayload(owner: "com.apple.streaming.transportStreamTimestamp", data: Data([0x01, 0x02, 0x03])),
                    versionMajor: 4
                )
            ]
        )

        assertReaderThrows(tag, expected: .malformedFrame)
    }

    func testAppleTimestampRejectsNonzeroUpper31Bits() throws {
        var badPayload = timestampPayload(ticks: 42)
        badPayload[0] = 0x01
        let tag = try makeScannedTag(
            major: 4,
            frames: [
                makeFrame(
                    id: "PRIV",
                    payload: privatePayload(owner: "com.apple.streaming.transportStreamTimestamp", data: badPayload),
                    versionMajor: 4
                )
            ]
        )

        assertReaderThrows(tag, expected: .malformedFrame)
    }

    func testDescriptionsDoNotExposePrivatePayloadsOrParserDetails() throws {
        let errors: [ID3DecodeError] = [
            .malformedFrame,
            .unsupportedFrameEncoding,
            .unsupportedFrameFlags
        ]

        for error in errors {
            let description = error.description
            XCTAssertTrue(description.contains("ID3 parse failed"))
            XCTAssertFalse(description.contains("secret-owner"))
            XCTAssertFalse(description.contains("494433"))
            XCTAssertFalse(description.contains("SUQz"))
            XCTAssertFalse(description.contains("base64"))
            XCTAssertFalse(description.contains("Data("))
            XCTAssertFalse(description.contains("Stack"))
        }
    }

    private func assertReaderThrows(
        _ tag: ID3TagBytes,
        expected: ID3DecodeError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ID3FrameReader().readFrames(from: tag), file: file, line: line) { error in
            guard let decodeError = error as? ID3DecodeError else {
                return XCTFail("Expected ID3DecodeError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(decodeError, expected, file: file, line: line)
            XCTAssertTrue(decodeError.description.contains("ID3 parse failed"), file: file, line: line)
        }
    }

    private func makeScannedTag(major: UInt8, frames: [Data]) throws -> ID3TagBytes {
        try makeScannedTag(major: major, payload: frames.reduce(Data(), +))
    }

    private func makeScannedTag(major: UInt8, payload: Data) throws -> ID3TagBytes {
        let tag = Data([0x49, 0x44, 0x33, major, 0x00, 0x00]) + synchsafe(payload.count) + payload
        return try XCTUnwrap(ID3TagScanner.scan(tag).first)
    }

    private func makeFrame(id: String, payload: Data, versionMajor: UInt8, flags: [UInt8] = [0x00, 0x00]) -> Data {
        frameHeader(id: id, payloadSize: payload.count, versionMajor: versionMajor, flags: flags) + payload
    }

    private func frameHeader(id: String, payloadSize: Int, versionMajor: UInt8, flags: [UInt8] = [0x00, 0x00]) -> Data {
        precondition(id.utf8.count == 4)
        precondition(flags.count == 2)
        let size = versionMajor == 4 ? synchsafe(payloadSize) : bigEndian32(payloadSize)
        return Data(id.utf8) + size + Data(flags)
    }

    private func textPayload(encoding: UInt8, _ values: String...) -> Data {
        var data = Data([encoding])
        switch encoding {
        case 0:
            data.append(values.joined(separator: "\0").data(using: .isoLatin1)!)
        case 3:
            data.append(values.joined(separator: "\0").data(using: .utf8)!)
        default:
            preconditionFailure("test helper supports Latin-1 and UTF-8 only")
        }
        return data
    }

    private func privatePayload(owner: String, data: Data) -> Data {
        Data(owner.utf8) + Data([0x00]) + data
    }

    private func timestampPayload(ticks: UInt64) -> Data {
        bigEndian64(ticks & 0x1FFFFFFFF)
    }

    private func synchsafe(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }

    private func bigEndian32(_ value: Int) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func bigEndian64(_ value: UInt64) -> Data {
        Data([
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func utf16LEBytes(_ string: String) -> Data {
        var data = Data()
        for unit in string.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8((unit >> 8) & 0xFF))
        }
        return data
    }

    private func utf16BEBytes(_ string: String) -> Data {
        var data = Data()
        for unit in string.utf16 {
            data.append(UInt8((unit >> 8) & 0xFF))
            data.append(UInt8(unit & 0xFF))
        }
        return data
    }
}
