import XCTest
@testable import SoundingKit

final class ProgramMetadataTests: XCTestCase {
    func testNormalizesTimedMetadataSources() {
        XCTAssertEqual(ProgramMetadataSource(raw: "ID3"), .timedID3)
        XCTAssertEqual(ProgramMetadataSource(raw: "hls_timed_id3"), .timedID3)
        XCTAssertEqual(ProgramMetadataSource(raw: "SCTE-35"), .scte35)
        XCTAssertEqual(ProgramMetadataSource(raw: "SCTE35"), .scte35)
    }

    func testDoesNotTreatGenericTimedStringsAsID3() {
        XCTAssertEqual(ProgramMetadataSource(raw: "timed_metadata"), .other)
        XCTAssertEqual(ProgramMetadataSource(raw: "runtime_status"), .other)
    }

    func testMarkerSourcePrefersKnownFieldsIndependently() {
        let marker = AdMarker(
            type: "ID3",
            classification: .unknown,
            source: "hls_segment",
            tag: "runtime_status"
        )

        XCTAssertEqual(ProgramMetadataSource(marker: marker), .timedID3)
    }

    func testNormalizesFingerprintSources() {
        XCTAssertEqual(ProgramMetadataSource(raw: "chromaprint"), .chromaprint)
        XCTAssertEqual(ProgramMetadataSource(raw: "AcoustID"), .acoustID)
        XCTAssertEqual(ProgramMetadataSource(raw: "deterministic_fingerprint"), .deterministicFingerprint)
        XCTAssertEqual(ProgramMetadataSource(raw: "test_fingerprint"), .deterministicFingerprint)
    }

    func testClassifiesRealTimedID3SongsAsMusic() {
        XCTAssertEqual(
            ProgramMetadataClassifier.classify(
                title: "Bad Dreams",
                artist: "Teddy Swims",
                album: "ID3",
                source: .timedID3,
                isUnknown: false
            ),
            .music
        )
    }

    func testClassifiesStationCodesAsNonMusic() {
        XCTAssertEqual(
            ProgramMetadataClassifier.classify(
                title: "PADULTH21",
                artist: "Stingray",
                album: nil,
                source: .timedID3,
                isUnknown: false
            ),
            .nonMusic
        )
    }

    func testExtractsCanonicalTimedID3Metadata() throws {
        let marker = AdMarker(
            type: "ID3",
            classification: .unknown,
            source: "hls_segment",
            tags: [
                "TIT2": "Bad Dreams",
                "TPE1": "Teddy Swims",
                "TALB": "I've Tried Everything But Therapy (Part 1)"
            ]
        )

        let metadata = try XCTUnwrap(ProgramMetadataExtractor.metadata(from: marker))
        XCTAssertEqual(metadata.title, "Bad Dreams")
        XCTAssertEqual(metadata.artist, "Teddy Swims")
        XCTAssertEqual(metadata.album, "I've Tried Everything But Therapy (Part 1)")
        XCTAssertEqual(metadata.source, .timedID3)
        XCTAssertEqual(metadata.classification, .music)
        XCTAssertEqual(
            metadata.songKey,
            "timed_id3:teddy swims:bad dreams:i've tried everything but therapy (part 1)"
        )
    }

    func testExtractorIgnoresNonTimedMarkers() {
        let marker = AdMarker(
            type: "ICY",
            classification: .unknown,
            source: "icy",
            fields: ["Title": "Bad Dreams", "Artist": "Teddy Swims"]
        )

        XCTAssertNil(ProgramMetadataExtractor.metadata(from: marker))
    }
}
