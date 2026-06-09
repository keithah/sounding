import XCTest
@testable import SoundingKit

final class MarkerClassifierTests: XCTestCase {
    func testClassifiesHLSCueTagsBeforeMarkerTypeSpecificLogic() {
        var classifier = MarkerClassifier()
        let cueOut = AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: "hls_manifest",
            tag: "#EXT-X-CUE-OUT",
            fields: ["cue": "out"]
        )
        let cueIn = AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: "hls_manifest",
            tag: "#EXT-X-CUE-IN",
            fields: ["cue": "in"]
        )

        XCTAssertEqual(classifier.classify(cueOut).classification, .adStart)
        XCTAssertEqual(classifier.classify(cueIn).classification, .adEnd)
    }

    func testClassifiesSCTE35SpliceInsertOutOfNetworkTransitions() {
        var classifier = MarkerClassifier()
        let adStart = scte35Marker(commandName: "SPLICE_INSERT_OON_TRUE")
        let adEnd = scte35Marker(commandName: "SPLICE_INSERT_OON_FALSE")

        XCTAssertEqual(classifier.classify(adStart).classification, .adStart)
        XCTAssertEqual(classifier.classify(adEnd).classification, .adEnd)
    }

    func testClassifiesSCTE35CommandObjectPhraseShapes() {
        var classifier = MarkerClassifier()
        let phraseShapedStart = AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: "hls_segment",
            command: ["Name": "Splice Insert", "OutOfNetworkIndicator": true]
        )
        let phraseShapedEnd = AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: "hls_segment",
            command: ["Name": "Splice Insert", "OutOfNetworkIndicator": false]
        )

        XCTAssertEqual(classifier.classify(phraseShapedStart).classification, .adStart)
        XCTAssertEqual(classifier.classify(phraseShapedEnd).classification, .adEnd)
    }

    func testClassifiesSCTE35TimeSignalSegmentationTypeIDsFromFieldsAndDescriptors() {
        var classifier = MarkerClassifier()
        let fieldStart = scte35Marker(commandName: "TIME_SIGNAL", fields: ["SegmentationTypeID": "0x34"])
        let unscheduledStart = scte35Marker(commandName: "TIME_SIGNAL", fields: ["SegmentationTypeID": "0x40"])
        let descriptorEnd = AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: "hls_segment",
            command: ["Name": "Time Signal"],
            descriptors: [["Tag": "SegmentationDescriptor", "SegmentationTypeID": 0x35]]
        )
        let unscheduledEnd = AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: "hls_segment",
            command: ["Name": "Time Signal"],
            descriptors: [["Tag": "SegmentationDescriptor", "SegmentationTypeID": 0x43]]
        )

        XCTAssertEqual(classifier.classify(fieldStart).classification, .adStart)
        XCTAssertEqual(classifier.classify(unscheduledStart).classification, .adStart)
        XCTAssertEqual(classifier.classify(descriptorEnd).classification, .adEnd)
        XCTAssertEqual(classifier.classify(unscheduledEnd).classification, .adEnd)
    }

    func testClassifiesSCTE35SpliceNullAsUnknown() {
        var classifier = MarkerClassifier()

        XCTAssertEqual(classifier.classify(scte35Marker(commandName: "SPLICE_NULL")).classification, .unknown)
    }

    func testClassifiesID3TagsAndFramesFromSafeTextCandidates() {
        var classifier = MarkerClassifier()
        let tagStart = id3Marker(tags: ["TIT2": "Local ad break"])
        let swiftTextsEnd = id3Marker(fields: [
            "Frames": [
                ["ID": "TXXX", "Description": "marker", "Texts": ["content_start"]]
            ]
        ])
        let compatibleTextStart = id3Marker(fields: [
            "Frames": [
                ["ID": "TXXX", "Description": "marker", "Text": "commercial break"]
            ]
        ])

        XCTAssertEqual(classifier.classify(tagStart).classification, .adStart)
        XCTAssertEqual(classifier.classify(swiftTextsEnd).classification, .adEnd)
        XCTAssertEqual(classifier.classify(compatibleTextStart).classification, .adStart)
    }

    func testEndKeywordsWinBeforeStartWordsInTextCandidates() {
        var classifier = MarkerClassifier()
        let marker = id3Marker(tags: ["TXXX:marker": "ad_end promo commercial"])

        XCTAssertEqual(classifier.classify(marker).classification, .adEnd)
    }

    func testClassifiesID3AdvertisementFrameAsAdStart() {
        var classifier = MarkerClassifier()
        let marker = id3Marker(tags: ["TXXX:ADVERTISEMENT": "ADVERTISEMENT"])

        XCTAssertEqual(classifier.classify(marker).classification, .adStart)
    }

    func testFalsePositiveWordsDoNotMatchAdStartKeywords() {
        var classifier = MarkerClassifier()
        let falsePositiveTexts = ["Administrator", "shadow", "adolescent", "promoção"]

        let classifications = falsePositiveTexts.map { text in
            classifier.classify(id3Marker(tags: ["TIT2": .string(text)])).classification
        }

        XCTAssertEqual(classifications, [.unknown, .unknown, .unknown, .unknown])
    }

    func testMalformedSCTE35AndID3ShapesFailClosedToUnknown() {
        var classifier = MarkerClassifier()
        let malformedMarkers = [
            AdMarker(type: "SCTE35", classification: .unknown, source: "fixture", command: ["Name": true]),
            AdMarker(type: "SCTE35", classification: .unknown, source: "fixture", command: ["Name": "TIME_SIGNAL"], fields: ["SegmentationTypeID": "not-a-number"]),
            AdMarker(type: "SCTE35", classification: .unknown, source: "fixture", command: ["Name": "TIME_SIGNAL"], descriptors: [["SegmentationTypeID": true]]),
            id3Marker(tags: ["TIT2": .bool(true)]),
            id3Marker(fields: ["Frames": .object(["ID": "TXXX", "Texts": "ad"])]),
            id3Marker(fields: ["Frames": [["ID": "TXXX", "Text": false]]])
        ]

        let classifications = malformedMarkers.map { marker in
            classifier.classify(marker).classification
        }

        XCTAssertEqual(classifications, Array(repeating: .unknown, count: malformedMarkers.count))
    }

    func testClassifiesIcyAdStartAndAdEndTransitionsPerStream() {
        var classifier = MarkerClassifier()
        let titles = ["Morning Show", "Promo Spot", "Morning Show"]

        let classifications = titles.map { title in
            classifier.classify(icyMarker(title: title)).classification
        }

        XCTAssertEqual(classifications, [.unknown, .adStart, .adEnd])
    }

    func testClassifiesIcyBreakPhrasesAsAdTransitions() {
        var classifier = MarkerClassifier()
        let titles = ["Morning Show", "Will be right back", "Morning Show"]

        let classifications = titles.map { title in
            classifier.classify(icyMarker(title: title)).classification
        }

        XCTAssertEqual(classifications, [.unknown, .adStart, .adEnd])
    }

    func testClassifiesIcyAdFieldsWithoutStreamTitle() {
        var classifier = MarkerClassifier()
        let tiadMarker = AdMarker(
            type: "ICY",
            classification: .unknown,
            source: "icy_stream",
            fields: ["TIAD": .string("1"), "TIGENBUMPE": .string("Ad bumper")]
        )
        let repeatedAdMarker = AdMarker(
            type: "ICY",
            classification: .unknown,
            source: "icy_stream",
            fields: ["TIAD": .string("1"), "TIGENBUMPE": .string("Different ad bumper")]
        )

        XCTAssertEqual(classifier.classify(tiadMarker).classification, .adStart)
        XCTAssertEqual(classifier.classify(repeatedAdMarker).classification, .unknown)
        XCTAssertEqual(classifier.classify(icyMarker(title: "Morning Show")).classification, .adEnd)
    }

    func testClassifiesRawIcyAdStartAndEndNames() {
        var classifier = MarkerClassifier()

        let start = AdMarker(
            type: "ICY",
            classification: .unknown,
            source: "icy_stream",
            fields: ["StreamTitle": .string("TIADSTART")]
        )
        let end = AdMarker(
            type: "ICY",
            classification: .unknown,
            source: "icy_stream",
            fields: ["StreamTitle": .string("TIADEND")]
        )

        XCTAssertEqual(classifier.classify(start).classification, .adStart)
        XCTAssertEqual(classifier.classify(end).classification, .adEnd)
    }

    func testRepeatedAdLikeTitlesOnlyStartOnce() {
        var classifier = MarkerClassifier()

        let first = classifier.classify(icyMarker(title: "Promo Spot")).classification
        let repeated = classifier.classify(icyMarker(title: "Commercial Break")).classification

        XCTAssertEqual([first, repeated], [.adStart, .unknown])
    }

    func testFreshClassifierStartsAdStateIndependently() {
        var firstClassifier = MarkerClassifier()
        var secondClassifier = MarkerClassifier()

        _ = firstClassifier.classify(icyMarker(title: "Promo Spot"))
        let secondClassification = secondClassifier.classify(icyMarker(title: "Spot Break")).classification

        XCTAssertEqual(secondClassification, .adStart)
    }

    func testExplicitEndSubstringsEndActiveAdStateCaseInsensitively() {
        var classifier = MarkerClassifier()

        _ = classifier.classify(icyMarker(title: "AD: Local Spot"))
        let adEnd = classifier.classify(icyMarker(title: "station AD_END marker")).classification
        _ = classifier.classify(icyMarker(title: "commercial break"))
        let contentStart = classifier.classify(icyMarker(title: "CONTENT_START Morning Show")).classification

        XCTAssertEqual(adEnd, .adEnd)
        XCTAssertEqual(contentStart, .adEnd)
    }

    func testMalformedOrNonIcyMarkersStayUnknown() {
        var classifier = MarkerClassifier()
        let missingTitle = AdMarker(type: "ICY", classification: .unknown, source: "icy_stream")
        let emptyTitle = icyMarker(title: "   ")
        let nonStringTitle = AdMarker(
            type: "ICY",
            classification: .unknown,
            source: "icy_stream",
            fields: ["StreamTitle": .number(12)]
        )
        let nonIcy = AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: "manifest",
            fields: ["StreamTitle": .string("Promo Spot")]
        )

        let classifications = [missingTitle, emptyTitle, nonStringTitle, nonIcy].map { marker in
            classifier.classify(marker).classification
        }

        XCTAssertEqual(classifications, [.unknown, .unknown, .unknown, .unknown])
    }

    func testClassifyReturnsCopyWithoutMutatingOriginalMarkerPayload() {
        var classifier = MarkerClassifier()
        let marker = icyMarker(title: "Promo Spot", streamURL: "https://example.test/spot")

        let classified = classifier.classify(marker)

        XCTAssertEqual(marker.classification, .unknown)
        XCTAssertEqual(classified.classification, .adStart)
        XCTAssertEqual(classified.type, marker.type)
        XCTAssertEqual(classified.source, marker.source)
        XCTAssertEqual(classified.fields, marker.fields)
    }

    private func icyMarker(title: String, streamURL: String? = nil) -> AdMarker {
        var fields: [String: JSONValue] = ["StreamTitle": .string(title)]
        if let streamURL {
            fields["StreamUrl"] = .string(streamURL)
        }

        return AdMarker(
            type: "ICY",
            classification: .unknown,
            source: "icy_stream",
            fields: fields
        )
    }

    private func scte35Marker(commandName: String, fields extraFields: [String: JSONValue] = [:]) -> AdMarker {
        var fields: [String: JSONValue] = ["CommandName": .string(commandName)]
        fields.merge(extraFields) { _, new in new }
        return AdMarker(
            type: "SCTE35",
            classification: .unknown,
            source: "hls_segment",
            fields: fields
        )
    }

    private func id3Marker(
        tags: [String: JSONValue] = [:],
        fields: [String: JSONValue] = [:]
    ) -> AdMarker {
        AdMarker(
            type: "ID3",
            classification: .unknown,
            source: "hls_segment",
            tag: "ID3",
            tags: tags,
            fields: fields
        )
    }
}
