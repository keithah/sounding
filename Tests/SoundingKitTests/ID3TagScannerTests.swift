import Foundation
import XCTest
@testable import SoundingKit

final class ID3TagScannerTests: XCTestCase {
    func testEmptyAndNoID3BytesReturnNoTags() throws {
        XCTAssertEqual(try ID3TagScanner.scan(Data()), [])
        XCTAssertEqual(try ID3TagScanner.scan(Data([0x00, 0x49, 0x44, 0x00, 0x33])), [])
    }

    func testTagAtOffsetZeroReturnsCompleteTag() throws {
        let tag = makeTag(payload: [0x01, 0x02, 0x03])

        let tags = try ID3TagScanner.scan(tag)

        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].version.major, 4)
        XCTAssertEqual(tags[0].version.revision, 0)
        XCTAssertEqual(tags[0].flags, 0)
        XCTAssertEqual(tags[0].payloadRange, 10..<13)
        XCTAssertEqual(tags[0].byteRange, 0..<13)
        XCTAssertEqual(tags[0].data, tag)
        XCTAssertFalse(tags[0].hasFooter)
    }

    func testPrefixAndSuffixBytesAreExcludedFromReturnedTagRange() throws {
        let prefix = Data([0xAA, 0xBB, 0xCC])
        let tag = makeTag(payload: [0x11, 0x22])
        let suffix = Data([0xDD, 0xEE])
        let segment = prefix + tag + suffix

        let tags = try ID3TagScanner.scan(segment)

        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].payloadRange, 13..<15)
        XCTAssertEqual(tags[0].byteRange, 3..<15)
        XCTAssertEqual(tags[0].data, tag)
    }

    func testMultipleCompleteTagsAreReturnedInByteOrder() throws {
        let first = makeTag(payload: [0x01])
        let second = makeTag(major: 3, revision: 1, payload: [0x02, 0x03])
        let segment = Data([0x00]) + first + Data([0xFE, 0xED]) + second

        let tags = try ID3TagScanner.scan(segment)

        XCTAssertEqual(tags.map(\.byteRange), [1..<12, 14..<26])
        XCTAssertEqual(tags.map(\.data), [first, second])
        XCTAssertEqual(tags.map(\.version.major), [4, 3])
    }

    func testUnsupportedMajorVersionThrowsSanitizedScanError() throws {
        let tag = makeTag(major: 2, payload: [0x01])

        assertScanThrows(tag, expected: .unsupportedVersion(major: 2))
    }

    func testNonSynchsafeTagSizeByteThrowsSanitizedScanError() throws {
        let tag = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00])

        assertScanThrows(tag, expected: .malformedSynchsafeSize)
    }

    func testTruncatedHeaderThrowsWhenID3CandidateStartsNearEnd() throws {
        let segment = Data([0x00, 0x49, 0x44, 0x33, 0x04])

        assertScanThrows(segment, expected: .truncatedHeader)
    }

    func testTruncatedDeclaredTagBodyThrowsSanitizedScanError() throws {
        let header = makeHeader(payloadSize: 5)
        let segment = header + Data([0x01, 0x02])

        assertScanThrows(segment, expected: .truncatedTag)
    }

    func testFooterFlagAddsTenBytesToFullTagRange() throws {
        let payload = Data([0x01, 0x02, 0x03])
        let footer = Data(repeating: 0x00, count: 10)
        let tag = makeTag(flags: 0x10, payload: [UInt8](payload), footer: footer)

        let tags = try ID3TagScanner.scan(tag)

        XCTAssertEqual(tags.count, 1)
        XCTAssertTrue(tags[0].hasFooter)
        XCTAssertEqual(tags[0].payloadRange, 10..<13)
        XCTAssertEqual(tags[0].byteRange, 0..<23)
        XCTAssertEqual(tags[0].data, tag)
    }

    func testFooterFlagWithoutFooterBytesThrowsTruncatedTag() throws {
        let segment = makeHeader(flags: 0x10, payloadSize: 1) + Data([0x01])

        assertScanThrows(segment, expected: .truncatedTag)
    }

    func testMaxSizeRejectionThrowsSanitizedScanError() throws {
        let scanner = ID3TagScanner(maximumTagSize: 12)
        let tag = makeTag(payload: [0x01, 0x02, 0x03])

        XCTAssertThrowsError(try scanner.scan(tag)) { error in
            guard let decodeError = error as? ID3DecodeError else {
                return XCTFail("Expected ID3DecodeError, got \(error)")
            }
            XCTAssertEqual(decodeError, .tagTooLarge(maximum: 12))
            assertSanitizedScanDescription(decodeError.description)
        }
    }

    func testExactEndOfInputTagIsAccepted() throws {
        let tag = makeTag(payload: [])

        let tags = try ID3TagScanner.scan(tag)

        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].byteRange, 0..<10)
        XCTAssertEqual(tags[0].payloadRange, 10..<10)
    }

    func testRepeatedFakeMagicAdvancesDeterministicallyToLaterValidTag() throws {
        let fakeMagic = Data([0x49, 0x44, 0x33, 0xFF, 0x49, 0x44, 0x33])
        let validTag = makeTag(payload: [0x42])

        assertScanThrows(fakeMagic + validTag, expected: .unsupportedVersion(major: 255))
    }

    func testDescriptionsContainOnlySanitizedFailureClassAndContext() {
        let errors: [ID3DecodeError] = [
            .unsupportedVersion(major: 2, context: "mediaSequence=7 segment=redacted"),
            .malformedSynchsafeSize,
            .truncatedHeader,
            .truncatedTag,
            .tagTooLarge(maximum: 1024),
            .malformedFrame,
            .unsupportedFrameEncoding,
            .unsupportedFrameFlags
        ]

        for error in errors {
            let description = error.description
            XCTAssertTrue(
                description.contains("ID3 scan failed") || description.contains("ID3 parse failed"),
                "Description should expose only the phase: \(description)"
            )
            assertSanitizedScanDescription(description)
        }
    }

    private func assertScanThrows(
        _ data: Data,
        expected: ID3DecodeError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ID3TagScanner.scan(data), file: file, line: line) { error in
            guard let decodeError = error as? ID3DecodeError else {
                return XCTFail("Expected ID3DecodeError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(decodeError, expected, file: file, line: line)
            assertSanitizedScanDescription(decodeError.description, file: file, line: line)
        }
    }

    private func makeTag(
        major: UInt8 = 4,
        revision: UInt8 = 0,
        flags: UInt8 = 0,
        payload: [UInt8],
        footer: Data = Data()
    ) -> Data {
        makeHeader(major: major, revision: revision, flags: flags, payloadSize: payload.count) + Data(payload) + footer
    }

    private func makeHeader(
        major: UInt8 = 4,
        revision: UInt8 = 0,
        flags: UInt8 = 0,
        payloadSize: Int
    ) -> Data {
        Data([0x49, 0x44, 0x33, major, revision, flags]) + synchsafe(payloadSize)
    }

    private func synchsafe(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }

    private func assertSanitizedScanDescription(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(description.contains("base64"), file: file, line: line)
        XCTAssertFalse(description.contains("http://"), file: file, line: line)
        XCTAssertFalse(description.contains("https://"), file: file, line: line)
        XCTAssertFalse(description.contains("?token="), file: file, line: line)
        XCTAssertFalse(description.contains("@example"), file: file, line: line)
        XCTAssertFalse(description.contains("494433"), file: file, line: line)
        XCTAssertFalse(description.contains("SUQz"), file: file, line: line)
    }
}
