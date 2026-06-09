import Foundation
import XCTest
@testable import SoundingKit

final class ICYMetadataTests: XCTestCase {
    func testRequestHeadersAskServerForIcyMetadata() {
        XCTAssertEqual(ICYMetadataParser.requestHeaders, ["Icy-MetaData": "1"])
        XCTAssertEqual(ICYMetadataParser.defaultMetaInt, 16_000)
    }

    func testParsesSemicolonFieldsAndTrimsNullPadding() throws {
        let metadata = Data("StreamTitle='Artist - Title';StreamUrl='https://example.test/ad';\0\0\0".utf8)

        let fields = ICYMetadataParser.parseFields(from: metadata)

        XCTAssertEqual(fields["StreamTitle"], "Artist - Title")
        XCTAssertEqual(fields["StreamUrl"], "https://example.test/ad")
    }

    func testInvalidUTF8ProducesNoFieldsWithoutLeakingBytes() {
        let fields = ICYMetadataParser.parseFields(from: Data([0xFF, 0xFE, 0xFD]))

        XCTAssertEqual(fields, [:])
    }

    func testMissingOrEmptyMetadataDoesNotCreateMarker() {
        XCTAssertNil(ICYMetadataParser.marker(from: [:]))
        XCTAssertNil(ICYMetadataParser.marker(from: ["StreamTitle": "   "]))
    }

    func testCreatesMarkerFromNonTitleIcyFields() throws {
        let marker = try XCTUnwrap(ICYMetadataParser.marker(from: [
            "TIAD": "1",
            "TIGENBUMPE": "Ad bumper"
        ]))

        XCTAssertEqual(marker.type, "ICY")
        XCTAssertEqual(marker.source, "icy_stream")
        XCTAssertEqual(marker.fields["TIAD"], .string("1"))
        XCTAssertEqual(marker.fields["TIGENBUMPE"], .string("Ad bumper"))
        XCTAssertNil(marker.fields["StreamTitle"])
    }

    func testCreatesUnknownIcyMarkerFromNonEmptyStreamTitle() throws {
        let marker = try XCTUnwrap(ICYMetadataParser.marker(from: [
            "StreamTitle": "Agency - Spot",
            "StreamUrl": "https://example.test/tracker?secret=value"
        ]))

        XCTAssertEqual(marker.type, "ICY")
        XCTAssertEqual(marker.source, "icy_stream")
        XCTAssertEqual(marker.classification, .unknown)
        XCTAssertNil(marker.rawBase64)
        XCTAssertEqual(marker.fields["StreamTitle"], .string("Agency - Spot"))
        XCTAssertEqual(marker.fields["Artist"], .string("Agency"))
        XCTAssertEqual(marker.fields["Title"], .string("Spot"))
        XCTAssertEqual(marker.fields["StreamUrl"], .string("https://example.test/tracker?secret=value"))
    }

    func testParserSkipsZeroLengthMissingEmptyAndDuplicateMetadata() throws {
        var parser = ICYMetadataParser()

        XCTAssertNil(parser.marker(fromMetadataBlock: Data()))
        XCTAssertNil(parser.marker(fromMetadataBlock: Data("StreamTitle='';".utf8)))

        let first = try XCTUnwrap(parser.marker(fromMetadataBlock: Data("StreamTitle='Same Title';".utf8)))
        XCTAssertEqual(first.fields["StreamTitle"], .string("Same Title"))
        XCTAssertNil(parser.marker(fromMetadataBlock: Data("StreamTitle='Same Title';".utf8)))

        let second = try XCTUnwrap(parser.marker(fromMetadataBlock: Data("StreamTitle='Different Title';".utf8)))
        XCTAssertEqual(second.fields["StreamTitle"], .string("Different Title"))

        let ad = try XCTUnwrap(parser.marker(fromMetadataBlock: Data("TIAD='1';TIGENBUMPE='Ad bumper';".utf8)))
        XCTAssertEqual(ad.fields["TIAD"], .string("1"))
        XCTAssertNil(parser.marker(fromMetadataBlock: Data("TIGENBUMPE='Ad bumper';TIAD='1';".utf8)))
    }

    func testStreamReaderReadsAudioLengthAndMetadataFrame() throws {
        var chunks = [Data("abcd".utf8), Data([1]), paddedMetadata("StreamTitle='A';", blockCount: 1)]
        let reader = ICYMetadataStreamReader { requestedCount in
            XCTAssertFalse(chunks.isEmpty)
            let next = chunks.removeFirst()
            XCTAssertLessThanOrEqual(next.count, requestedCount)
            return next
        }

        let frame = try reader.readFrame(metaInt: 4)

        XCTAssertEqual(frame.audioByteCount, 4)
        XCTAssertEqual(frame.metadataLengthByte, 1)
        XCTAssertEqual(frame.metadata, paddedMetadata("StreamTitle='A';", blockCount: 1))
        XCTAssertTrue(chunks.isEmpty)
    }

    func testStreamReaderSkipsZeroLengthMetadataBlock() throws {
        var chunks = [Data("abcd".utf8), Data([0])]
        let reader = ICYMetadataStreamReader { _ in chunks.removeFirst() }

        let frame = try reader.readFrame(metaInt: 4)

        XCTAssertEqual(frame.audioByteCount, 4)
        XCTAssertEqual(frame.metadataLengthByte, 0)
        XCTAssertEqual(frame.metadata, Data())
        XCTAssertTrue(chunks.isEmpty)
    }

    func testStreamReaderAllowsMaxLegalMetadataLength() throws {
        let metadata = Data(repeating: 0x41, count: 255 * 16)
        var chunks = [Data("ab".utf8), Data([255]), metadata]
        let reader = ICYMetadataStreamReader { _ in chunks.removeFirst() }

        let frame = try reader.readFrame(metaInt: 2)

        XCTAssertEqual(frame.metadataLengthByte, 255)
        XCTAssertEqual(frame.metadata.count, 255 * 16)
    }

    func testStreamReaderRejectsInvalidMetaIntWithStructuralError() {
        let reader = ICYMetadataStreamReader { _ in Data() }

        XCTAssertThrowsError(try reader.readFrame(metaInt: 0)) { error in
            guard case let ICYMetadataError.invalidMetaInt(value) = error else {
                return XCTFail("Expected invalidMetaInt, got \(error)")
            }
            XCTAssertEqual(value, 0)
            assertDoesNotExposeForbiddenLiterals(error)
        }
    }

    func testStreamReaderReportsIncompleteAudioLengthAndMetadataStructurally() {
        XCTAssertThrowsError(try ICYMetadataStreamReader { _ in Data("ab".utf8) }.readFrame(metaInt: 4)) { error in
            XCTAssertEqual(error as? ICYMetadataError, .incompleteRead(phase: .audio, expectedByteCount: 4, actualByteCount: 2))
            assertDoesNotExposeForbiddenLiterals(error)
        }

        var lengthChunks = [Data("abcd".utf8), Data()]
        XCTAssertThrowsError(try ICYMetadataStreamReader { _ in lengthChunks.removeFirst() }.readFrame(metaInt: 4)) { error in
            XCTAssertEqual(error as? ICYMetadataError, .incompleteRead(phase: .metadataLength, expectedByteCount: 1, actualByteCount: 0))
            assertDoesNotExposeForbiddenLiterals(error)
        }

        var metadataChunks = [Data("abcd".utf8), Data([2]), Data("secret-token".utf8)]
        XCTAssertThrowsError(try ICYMetadataStreamReader { _ in metadataChunks.removeFirst() }.readFrame(metaInt: 4)) { error in
            XCTAssertEqual(error as? ICYMetadataError, .incompleteRead(phase: .metadata, expectedByteCount: 32, actualByteCount: 12))
            assertDoesNotExposeForbiddenLiterals(error)
        }
    }

    func testStructuralErrorDiagnosticsExposeSafeCountsAndMonitorContextOnly() {
        let error = ICYMetadataError.incompleteRead(phase: .metadata, expectedByteCount: 32, actualByteCount: 12)

        XCTAssertEqual(error.context["sourceClass"], "icy_stream")
        XCTAssertEqual(error.context["phase"], "metadata")
        XCTAssertEqual(error.context["expectedByteCount"], "32")
        XCTAssertEqual(error.context["actualByteCount"], "12")
        assertDoesNotExposeForbiddenLiterals(error)

        let monitorError = MonitorError.operationFailed(
            phase: .decode,
            source: "https://user:password@example.test/live?token=secret#frag",
            streamType: .icy,
            context: error.context.merging(["url": "https://user:password@example.test/live?token=secret#frag"]) { _, new in new },
            reason: error.description
        )

        let description = monitorError.description
        XCTAssertTrue(description.contains("sourceClass=icy_stream"))
        XCTAssertTrue(description.contains("expectedByteCount=32"))
        XCTAssertTrue(description.contains("https://example.test/live"))
        XCTAssertFalse(description.contains("user"))
        XCTAssertFalse(description.contains("password"))
        XCTAssertFalse(description.contains("token=secret"))
        XCTAssertFalse(description.contains("frag"))
    }

    private func paddedMetadata(_ text: String, blockCount: UInt8) -> Data {
        var data = Data(text.utf8)
        let targetCount = Int(blockCount) * 16
        if data.count < targetCount {
            data.append(contentsOf: repeatElement(0, count: targetCount - data.count))
        }
        return data
    }

    private func assertDoesNotExposeForbiddenLiterals(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let description = String(describing: error)
        XCTAssertFalse(description.contains("secret-token"), file: file, line: line)
        XCTAssertFalse(description.contains("U3RyZWFt"), file: file, line: line)
        XCTAssertFalse(description.contains("StreamTitle"), file: file, line: line)
    }
}
