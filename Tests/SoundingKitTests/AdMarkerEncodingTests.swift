import Foundation
import XCTest
@testable import SoundingKit

final class AdMarkerEncodingTests: XCTestCase {
    private let publicMarkerKeys: Set<String> = [
        "Type",
        "Classification",
        "Source",
        "Tag",
        "PTS",
        "Segment",
        "RawBase64",
        "Command",
        "Descriptors",
        "Tags",
        "Fields",
        "Timestamp"
    ]

    func testFullyPopulatedMarkerEncodesSemanticContract() throws {
        let marker = AdMarker(
            type: "SCTE35",
            classification: .adStart,
            source: "fixture.ts",
            tag: "#EXT-X-DATERANGE",
            pts: 12.345,
            segment: "segment-0001.ts",
            rawBase64: "AAAAAQ==",
            command: [
                "Name": "splice_insert",
                "EventID": 42,
                "OutOfNetwork": true,
                "Nested": ["Value": "ok"]
            ],
            descriptors: [
                ["Tag": "SegmentationDescriptor", "Identifier": "CUEI"],
                ["Tag": "AvailDescriptor", "Provider": JSONValue.null]
            ],
            tags: [
                "EXT-X-CUE-OUT": "30.0",
                "EXT-OATCLS-SCTE35": "AAAAAQ=="
            ],
            fields: [
                "BreakDuration": 30.0,
                "AutoReturn": true,
                "Provider": JSONValue.null
            ],
            timestamp: "2026-04-30T08:00:00Z",
            breakDuration: 30.0
        )

        let data = try JSONEncoder().encode(marker)
        let object = try semanticJSONObject(from: data)

        assertJSONKeys(object, equal: publicMarkerKeys)
        XCTAssertEqual(object["Type"] as? String, "SCTE35")
        XCTAssertEqual(object["Classification"] as? String, "AD_START")
        XCTAssertEqual(object["Source"] as? String, "fixture.ts")
        XCTAssertEqual(object["Tag"] as? String, "#EXT-X-DATERANGE")
        XCTAssertEqual(object["PTS"] as? Double, 12.345)
        XCTAssertEqual(object["Segment"] as? String, "segment-0001.ts")
        XCTAssertEqual(object["RawBase64"] as? String, "AAAAAQ==")
        XCTAssertEqual(object["Timestamp"] as? String, "2026-04-30T08:00:00Z")

        let command = try XCTUnwrap(object["Command"] as? [String: Any])
        XCTAssertEqual(command["Name"] as? String, "splice_insert")
        XCTAssertEqual(command["EventID"] as? Int, 42)
        XCTAssertEqual(command["OutOfNetwork"] as? Bool, true)
        XCTAssertEqual((command["Nested"] as? [String: Any])?["Value"] as? String, "ok")

        let descriptors = try XCTUnwrap(object["Descriptors"] as? [[String: Any]])
        XCTAssertEqual(descriptors.count, 2)
        XCTAssertEqual(descriptors[0]["Tag"] as? String, "SegmentationDescriptor")
        XCTAssertTrue(descriptors[1]["Provider"] is NSNull)

        let tags = try XCTUnwrap(object["Tags"] as? [String: Any])
        XCTAssertEqual(tags["EXT-X-CUE-OUT"] as? String, "30.0")

        let fields = try XCTUnwrap(object["Fields"] as? [String: Any])
        XCTAssertEqual(fields["BreakDuration"] as? Double, 30.0)
        XCTAssertEqual(fields["AutoReturn"] as? Bool, true)
        XCTAssertTrue(fields["Provider"] is NSNull)
    }

    func testNilOptionalsEncodeAsExplicitNulls() throws {
        let marker = AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: "fixture.ts"
        )

        let object = try semanticJSONObject(from: JSONEncoder().encode(marker))

        assertJSONKeys(object, equal: publicMarkerKeys)
        for key in ["Tag", "PTS", "Segment", "RawBase64", "Command", "Timestamp"] {
            assertJSONNull(key, in: object)
        }
        XCTAssertEqual((object["Descriptors"] as? [Any])?.isEmpty, true)
        XCTAssertEqual((object["Tags"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual((object["Fields"] as? [String: Any])?.isEmpty, true)
    }

    func testSnakeCaseKeysAreAbsent() throws {
        let marker = AdMarker(type: "SCTE35", classification: .adEnd, source: "fixture.ts")
        let object = try semanticJSONObject(from: JSONEncoder().encode(marker))

        for key in ["type", "classification", "source", "raw_base64", "break_duration"] {
            assertJSONKeyAbsent(key, in: object)
        }
    }

    func testDefaultContainersAreIndependentAcrossInstances() throws {
        var first = AdMarker(type: "SCTE35", classification: .unknown, source: "first.ts")
        let second = AdMarker(type: "SCTE35", classification: .unknown, source: "second.ts")

        first.descriptors.append(["Tag": "OnlyFirst"])
        first.tags["OnlyFirst"] = true
        first.fields["OnlyFirst"] = "value"

        let firstObject = try semanticJSONObject(from: JSONEncoder().encode(first))
        let secondObject = try semanticJSONObject(from: JSONEncoder().encode(second))

        XCTAssertEqual((firstObject["Descriptors"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((secondObject["Descriptors"] as? [Any])?.isEmpty, true)
        XCTAssertEqual((secondObject["Tags"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual((secondObject["Fields"] as? [String: Any])?.isEmpty, true)
    }

    func testBreakDurationIsExcludedFromTopLevelJSONButAllowedInFields() throws {
        let marker = AdMarker(
            type: "SCTE35",
            classification: .adStart,
            source: "fixture.ts",
            fields: ["BreakDuration": 45.5],
            breakDuration: 45.5
        )

        let object = try semanticJSONObject(from: JSONEncoder().encode(marker))

        assertJSONKeyAbsent("BreakDuration", in: object)
        assertJSONKeyAbsent("breakDuration", in: object)
        let fields = try XCTUnwrap(object["Fields"] as? [String: Any])
        XCTAssertEqual(fields["BreakDuration"] as? Double, 45.5)
    }
}
