import XCTest
@testable import SoundingKit

final class HLSManifestParserTests: XCTestCase {
    private let base64Payload = "/DAvAAAAAAAA///wFAVIAACef+//yAAXoQAAAAA="

    func testParsesExtXSCTE35CueAttributePayload() throws {
        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine("#EXT-X-SCTE35:CUE=\(base64Payload)"))

        XCTAssertEqual(tag.kind, .scte35)
        XCTAssertEqual(tag.rawTagName, "#EXT-X-SCTE35")
        XCTAssertEqual(tag.payload, base64Payload)
        XCTAssertEqual(tag.payloadEncodingHint, .base64)
        XCTAssertEqual(tag.fields["CUE"], .string(base64Payload))
        XCTAssertEqual(tag.sanitizedTagIdentity, "#EXT-X-SCTE35[CUE]")
    }

    func testParsesBareExtXSCTE35PayloadPreservingPadding() throws {
        let paddedPayload = "AAECAwQFBgc="

        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine("#EXT-X-SCTE35:\(paddedPayload)"))

        XCTAssertEqual(tag.kind, .scte35)
        XCTAssertEqual(tag.payload, paddedPayload)
        XCTAssertEqual(tag.payloadEncodingHint, .base64)
        XCTAssertEqual(tag.fields, [:])
        XCTAssertEqual(tag.sanitizedTagIdentity, "#EXT-X-SCTE35")
    }

    func testParsesExtOatclsSCTE35Payload() throws {
        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine("#EXT-OATCLS-SCTE35:\(base64Payload)"))

        XCTAssertEqual(tag.kind, .oatclsSCTE35)
        XCTAssertEqual(tag.rawTagName, "#EXT-OATCLS-SCTE35")
        XCTAssertEqual(tag.payload, base64Payload)
        XCTAssertEqual(tag.payloadEncodingHint, .base64)
        XCTAssertEqual(tag.sanitizedTagIdentity, "#EXT-OATCLS-SCTE35")
    }

    func testParsesDateRangeSCTE35OutWithQuotedCommas() throws {
        let line = "#EXT-X-DATERANGE:ID=\"ad-1\",CLASS=\"Campaign, Spring\",START-DATE=\"2026-04-30T08:00:00Z\",SCTE35-OUT=0xFC302A"

        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine(line))

        XCTAssertEqual(tag.kind, .daterange)
        XCTAssertEqual(tag.rawTagName, "#EXT-X-DATERANGE")
        XCTAssertEqual(tag.payload, "0xFC302A")
        XCTAssertEqual(tag.payloadEncodingHint, .hex)
        XCTAssertEqual(tag.fields["ID"], .string("ad-1"))
        XCTAssertEqual(tag.fields["CLASS"], .string("Campaign, Spring"))
        XCTAssertEqual(tag.fields["START-DATE"], .string("2026-04-30T08:00:00Z"))
        XCTAssertEqual(tag.fields["SCTE35-OUT"], .string("0xFC302A"))
        XCTAssertEqual(tag.sanitizedTagIdentity, "#EXT-X-DATERANGE[SCTE35-OUT]")
    }

    func testParsesDateRangeSCTE35In() throws {
        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine("#EXT-X-DATERANGE:ID=\"ad-1\",SCTE35-IN=0xFC302B"))

        XCTAssertEqual(tag.kind, .daterange)
        XCTAssertEqual(tag.payload, "0xFC302B")
        XCTAssertEqual(tag.payloadEncodingHint, .hex)
        XCTAssertEqual(tag.fields["SCTE35-IN"], .string("0xFC302B"))
        XCTAssertEqual(tag.sanitizedTagIdentity, "#EXT-X-DATERANGE[SCTE35-IN]")
    }

    func testParsesCueOutContSCTE35Payload() throws {
        let line = "#EXT-X-CUE-OUT-CONT:ElapsedTime=10.5,Duration=30.0,SCTE35=\(base64Payload)"

        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine(line))

        XCTAssertEqual(tag.kind, .cueOutCont)
        XCTAssertEqual(tag.rawTagName, "#EXT-X-CUE-OUT-CONT")
        XCTAssertEqual(tag.payload, base64Payload)
        XCTAssertEqual(tag.payloadEncodingHint, .base64)
        XCTAssertEqual(tag.fields["ElapsedTime"], .string("10.5"))
        XCTAssertEqual(tag.fields["Duration"], .string("30.0"))
        XCTAssertEqual(tag.fields["SCTE35"], .string(base64Payload))
        XCTAssertEqual(tag.sanitizedTagIdentity, "#EXT-X-CUE-OUT-CONT[SCTE35]")
    }

    func testParsesDirectCueOutWithoutPayload() throws {
        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine("#EXT-X-CUE-OUT"))

        XCTAssertEqual(tag.kind, .cueOut)
        XCTAssertEqual(tag.rawTagName, "#EXT-X-CUE-OUT")
        XCTAssertNil(tag.payload)
        XCTAssertNil(tag.payloadEncodingHint)
        XCTAssertEqual(tag.fields["cue"], .string("out"))
        XCTAssertEqual(tag.sanitizedTagIdentity, "#EXT-X-CUE-OUT")
    }

    func testParsesDirectCueOutWithDuration() throws {
        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine("#EXT-X-CUE-OUT:30.5"))

        XCTAssertEqual(tag.kind, .cueOut)
        XCTAssertNil(tag.payload)
        XCTAssertEqual(tag.fields["cue"], .string("out"))
        XCTAssertEqual(tag.fields["duration"], .string("30.5"))
    }

    func testParsesDirectCueOutWithAttributes() throws {
        let line = "#EXT-X-CUE-OUT:DURATION=30.0,ID=\"break, 7\""

        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine(line))

        XCTAssertEqual(tag.kind, .cueOut)
        XCTAssertNil(tag.payload)
        XCTAssertEqual(tag.fields["cue"], .string("out"))
        XCTAssertEqual(tag.fields["DURATION"], .string("30.0"))
        XCTAssertEqual(tag.fields["ID"], .string("break, 7"))
    }

    func testParsesDirectCueInWithoutPayload() throws {
        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine("#EXT-X-CUE-IN"))

        XCTAssertEqual(tag.kind, .cueIn)
        XCTAssertEqual(tag.rawTagName, "#EXT-X-CUE-IN")
        XCTAssertNil(tag.payload)
        XCTAssertNil(tag.payloadEncodingHint)
        XCTAssertEqual(tag.fields["cue"], .string("in"))
        XCTAssertEqual(tag.sanitizedTagIdentity, "#EXT-X-CUE-IN")
    }

    func testParsesVariantPlaylistsFromMasterManifest() {
        let manifest = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=165000,CODECS=\"mp4a.40.2\"
            low/manifest.m3u8?suid=abc&playlist-id=low
            #EXT-X-STREAM-INF:BANDWIDTH=320000,CODECS=\"mp4a.40.2\"
            high/manifest.m3u8?suid=abc&playlist-id=high
            """

        let variants = HLSManifestParser.parseVariantPlaylists(manifest)

        XCTAssertEqual(variants, [
            HLSManifestVariantPlaylist(uri: "low/manifest.m3u8?suid=abc&playlist-id=low", bandwidth: 165000),
            HLSManifestVariantPlaylist(uri: "high/manifest.m3u8?suid=abc&playlist-id=high", bandwidth: 320000),
        ])
    }

    func testIgnoresUnsupportedAndEmptyMarkerLines() {
        XCTAssertNil(HLSManifestParser.parseTagLine(""))
        XCTAssertNil(HLSManifestParser.parseTagLine("#EXTINF:6.0,"))
        XCTAssertNil(HLSManifestParser.parseTagLine("#EXT-X-SCTE35:CUE="))
        XCTAssertNil(HLSManifestParser.parseTagLine("#EXT-X-SCTE35:   "))
        XCTAssertNil(HLSManifestParser.parseTagLine("#EXT-OATCLS-SCTE35:"))
        XCTAssertNil(HLSManifestParser.parseTagLine("#EXT-X-CUE-OUT-CONT:SCTE35="))
        XCTAssertNil(HLSManifestParser.parseTagLine("#EXT-X-DATERANGE:ID=\"ad-1\""))
    }

    func testMalformedAttributesDoNotCrashOrLeakWholeInput() throws {
        let line = "#EXT-X-DATERANGE:ID=\"ad-1\",BROKEN,SCTE35-OUT=0xFC302A"

        let tag = try XCTUnwrap(HLSManifestParser.parseTagLine(line))

        XCTAssertEqual(tag.fields["ID"], .string("ad-1"))
        XCTAssertNil(tag.fields["BROKEN"])
        XCTAssertEqual(tag.payload, "0xFC302A")
        XCTAssertFalse(tag.sanitizedTagIdentity.contains("ad-1"))
        XCTAssertFalse(tag.sanitizedTagIdentity.contains("0xFC302A"))
        XCTAssertFalse(tag.sanitizedTagIdentity.contains(line))
    }
}
