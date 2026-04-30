import Foundation
import XCTest
@testable import SoundingKit

final class SCTE35PayloadTests: XCTestCase {
    private let spliceNull = "/DARAAAAAAAAAP/wAAAAAHpPGuQ="
    private let spliceNullHex = "0xFC301100000000000000FFF0000000007A4F1AE4"
    private let spliceNullRawHex = "FC301100000000000000FFF0000000007A4F1AE4"

    func testBase64InputNormalizesToCanonicalBytesAndRawBase64() throws {
        let payload = try SCTE35Payload(input: .base64(spliceNull))

        XCTAssertEqual(payload.rawBase64, spliceNull)
        XCTAssertEqual(payload.bytes.count, 20)
        XCTAssertEqual(payload.bytes.first, 0xFC)
    }

    func testHexInputsNormalizeToSameCanonicalBase64AsBase64() throws {
        let fromBase64 = try SCTE35Payload(input: .base64(spliceNull))
        let fromPrefixedHex = try SCTE35Payload(input: .hex(spliceNullHex))
        let fromRawHex = try SCTE35Payload(input: .hex(spliceNullRawHex))

        XCTAssertEqual(fromPrefixedHex.bytes, fromBase64.bytes)
        XCTAssertEqual(fromPrefixedHex.rawBase64, spliceNull)
        XCTAssertEqual(fromRawHex.bytes, fromBase64.bytes)
        XCTAssertEqual(fromRawHex.rawBase64, spliceNull)
    }

    func testDataInputNormalizesToCanonicalRawBase64() throws {
        let data = try XCTUnwrap(Data(base64Encoded: spliceNull))

        let payload = try SCTE35Payload(input: .data(data))

        XCTAssertEqual(payload.bytes, [UInt8](data))
        XCTAssertEqual(payload.rawBase64, spliceNull)
    }

    func testMalformedInputsThrowSanitizedErrors() throws {
        let invalidInputs: [(SCTE35PayloadInput, String)] = [
            (.base64(""), ""),
            (.base64("not base64 payload"), "not base64 payload"),
            (.base64("☃"), "☃"),
            (.hex("0x123"), "0x123"),
            (.hex("0xGG"), "0xGG"),
            (.hex("0xFC30"), "0xFC30"),
            (.hex(""), "")
        ]

        for (input, literal) in invalidInputs {
            do {
                _ = try SCTE35Payload(input: input)
                XCTFail("Expected sanitized decode error for \(input)")
            } catch let error as SCTE35DecodeError {
                assertSanitized(error.description, forbiddenLiteral: literal)
                assertSanitized(error.description, forbiddenLiteral: spliceNull)
                assertSanitized(error.description, forbiddenLiteral: spliceNullHex)
            }
        }
    }

    func testEmptyDataThrowsSanitizedError() throws {
        do {
            _ = try SCTE35Payload(input: .data(Data()))
            XCTFail("Expected empty data to be rejected")
        } catch let error as SCTE35DecodeError {
            XCTAssertEqual(error, .emptyPayload)
            assertSanitized(error.description, forbiddenLiteral: spliceNull)
        }
    }

    func testBitReaderReadsAcrossByteBoundaries() throws {
        var reader = BitReader(bytes: [0b1011_0010, 0b0110_0001])

        XCTAssertEqual(try reader.readBits(3), 0b101)
        XCTAssertEqual(try reader.readBits(5), 0b10010)
        XCTAssertEqual(try reader.readBits(4), 0b0110)
        XCTAssertEqual(reader.remainingBits, 4)
    }

    func testBitReaderSupportsWideReadsAndZeroWidthReads() throws {
        var reader = BitReader(bytes: [0xFF, 0x00, 0xAA, 0x55, 0x80])

        XCTAssertEqual(try reader.readBits(0), 0)
        XCTAssertEqual(try reader.readBits(33), 0x1FE0154AB)
        XCTAssertEqual(reader.remainingBits, 7)
    }

    func testBitReaderUnderrunThrowsSanitizedError() throws {
        var reader = BitReader(bytes: [0x80])

        XCTAssertEqual(try reader.readBits(1), 1)
        XCTAssertThrowsError(try reader.readBits(8)) { error in
            guard let decodeError = error as? SCTE35DecodeError else {
                return XCTFail("Expected SCTE35DecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError, .boundedReadFailure)
            assertSanitized(decodeError.description, forbiddenLiteral: "0x80")
            assertSanitized(decodeError.description, forbiddenLiteral: spliceNull)
        }
    }

    private func assertSanitized(_ description: String, forbiddenLiteral: String, file: StaticString = #filePath, line: UInt = #line) {
        guard !forbiddenLiteral.isEmpty else { return }
        XCTAssertFalse(
            description.contains(forbiddenLiteral),
            "Error description leaked forbidden literal: \(description)",
            file: file,
            line: line
        )
    }
}
