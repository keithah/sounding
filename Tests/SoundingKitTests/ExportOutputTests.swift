import XCTest

@testable import SoundingKit
@testable import sounding

final class ExportOutputTests: XCTestCase {
    func testTranscriptJsonUsesStableSegmentsShapeAndRedactsSources() throws {
        let segment = transcriptSegment(
            streamSource: "https://user:pass@example.test/live/main.m3u8?token=fixture-secret#frag",
            text: "Host says hello"
        )

        let json = try ExportOutput.encodeTranscriptsJSON([segment])

        XCTAssertTrue(json.hasPrefix("{\"segments\":[{"), json)
        XCTAssertTrue(json.hasSuffix("\n"), json)
        XCTAssertTrue(json.contains("\"streamSource\":\"https:\\/\\/example.test\\/live\\/main.m3u8\""), json)
        XCTAssertTrue(json.contains("\"words\":[{"), json)
        XCTAssertTrue(json.contains("\"text\":\"Host says hello\""), json)
        assertNoSecretLeak(json)

        let decoded = try JSONDecoder().decode(ExportOutput.TranscriptPayload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.segments.count, 1)
        XCTAssertEqual(decoded.segments.first?.identity.streamSource, "https://example.test/live/main.m3u8")
        XCTAssertEqual(decoded.segments.first?.words.map(\.text), ["Host", "says", "hello"])
    }

    func testTranscriptHumanOutputIsDeterministicAndRedacted() throws {
        let segments = [
            transcriptSegment(
                sequence: 0,
                streamSource: "https://viewer:letmein@example.test/live.m3u8?api_key=fixture-secret#private-fragment",
                text: "Opening words"
            ),
            transcriptSegment(
                sequence: 1,
                streamSource: "relative/user:pass-token=fixture-secret/segment.ts?password=fixture-secret",
                text: "Second words",
                speakerLabel: nil,
                confidence: nil,
                createdAt: nil
            ),
        ]

        let human = try ExportOutput.formatTranscriptsHuman(segments)

        XCTAssertTrue(human.contains("Segment 1: stream=101(hls source=https://example.test/live.m3u8) run=201 chunk=301 segment=401 sequence=0"), human)
        XCTAssertTrue(human.contains("  time=00:00.000-00:10.000 speaker=host confidence=0.920 created_at=2026-05-01T17:00:00Z"), human)
        XCTAssertTrue(human.contains("  text: Opening words"), human)
        XCTAssertTrue(human.contains("    - id=501 sequence=0 time=00:00.000-00:05.000 speaker=host confidence=0.880 text=Opening"), human)
        XCTAssertTrue(human.contains("Segment 2:"), human)
        XCTAssertTrue(human.contains("speaker=unknown confidence=unknown created_at=unknown"), human)
        assertNoSecretLeak(human)
    }

    func testTranscriptEmptyPayloadShapes() throws {
        XCTAssertEqual(try ExportOutput.encodeTranscriptsJSON([]), "{\"segments\":[]}\n")
        XCTAssertEqual(try ExportOutput.formatTranscriptsHuman([]), "No transcript segments found.\n")
    }

    func testTranscriptOutputRejectsNonFiniteTimesBeforeEncoding() throws {
        var segment = transcriptSegment()
        segment.startSeconds = .infinity
        XCTAssertThrowsError(try ExportOutput.encodeTranscriptsJSON([segment])) { error in
            XCTAssertEqual(error as? ExportOutput.OutputError, .invalidTime("startSeconds"))
        }
        XCTAssertThrowsError(try ExportOutput.formatTranscriptsHuman([segment])) { error in
            XCTAssertEqual(error as? ExportOutput.OutputError, .invalidTime("startSeconds"))
        }

        var wordSegment = transcriptSegment()
        wordSegment.words[0].endSeconds = .nan
        XCTAssertThrowsError(try ExportOutput.encodeTranscriptsJSON([wordSegment])) { error in
            XCTAssertEqual(error as? ExportOutput.OutputError, .invalidTime("word.endSeconds"))
        }
        XCTAssertThrowsError(try ExportOutput.formatTranscriptsHuman([wordSegment])) { error in
            XCTAssertEqual(error as? ExportOutput.OutputError, .invalidTime("word.endSeconds"))
        }
    }

    func testMarkerExportDelegatesToReportOutputAndRedactsSourcesAndSegments() throws {
        let result = AdReportQuery.Result(
            events: [markerEvent()],
            summary: .init(unknown: 0, adStart: 1, adEnd: 0)
        )

        let markerJSON = try ExportOutput.encodeMarkersJSON(result)
        let reportJSON = try ReportOutput.encodeAdsJSON(result)
        XCTAssertEqual(markerJSON, reportJSON)
        XCTAssertTrue(markerJSON.contains("\"streamSource\":\"https:\\/\\/example.test\\/live.m3u8\""), markerJSON)
        assertNoSecretLeak(markerJSON)

        let markerHuman = try ExportOutput.formatMarkersHuman(result)
        let reportHuman = try ReportOutput.formatAdsHuman(result)
        XCTAssertEqual(markerHuman, reportHuman)
        XCTAssertTrue(markerHuman.contains("source=https://ads.example.test/start segment=/private/ad.ts"), markerHuman)
        assertNoSecretLeak(markerHuman)
    }

    func testReportExportWrappersHaveShapeParityWithReportOutput() throws {
        let play = playResult()
        let repeatResult = SongReportQuery.RepeatResult(
            groupKey: "artist-title:fixture artist:fixture song",
            song: play.song,
            repeatCount: 1,
            totalDurationSeconds: 10,
            firstStartSeconds: 0,
            lastEndSeconds: 10,
            plays: [play]
        )
        let ads = AdReportQuery.Result(events: [markerEvent()], summary: .init(unknown: 0, adStart: 1, adEnd: 0))

        XCTAssertEqual(try ExportOutput.encodeReportPlaysJSON([play]), try ReportOutput.encodePlaysJSON([play]))
        XCTAssertEqual(ExportOutput.formatReportPlaysHuman([play]), ReportOutput.formatPlaysHuman([play]))
        XCTAssertEqual(try ExportOutput.encodeReportRepeatsJSON([repeatResult]), try ReportOutput.encodeRepeatsJSON([repeatResult]))
        XCTAssertEqual(try ExportOutput.formatReportRepeatsHuman([repeatResult]), try ReportOutput.formatRepeatsHuman([repeatResult]))
        XCTAssertEqual(try ExportOutput.encodeReportAdsJSON(ads), try ReportOutput.encodeAdsJSON(ads))
        XCTAssertEqual(try ExportOutput.formatReportAdsHuman(ads), try ReportOutput.formatAdsHuman(ads))
    }

    private func transcriptSegment(
        sequence: Int = 0,
        streamSource: String = "https://example.test/live.m3u8?token=fixture-secret",
        text: String = "Host says hello",
        speakerLabel: String? = "host",
        confidence: Double? = 0.92,
        createdAt: String? = "2026-05-01T17:00:00Z"
    ) -> TranscriptExportQuery.SegmentExportRow {
        let words = text.split(separator: " ").enumerated().map { index, word in
            TranscriptQuery.TranscriptWord(
                id: Int64(501 + index + (sequence * 10)),
                sequence: index,
                speakerLabel: speakerLabel,
                startSeconds: Double(sequence * 10) + Double(index) * 5,
                endSeconds: Double(sequence * 10) + Double(index + 1) * 5,
                text: String(word),
                confidence: 0.88
            )
        }
        return TranscriptExportQuery.SegmentExportRow(
            identity: .init(
                streamID: 101,
                streamType: "hls",
                streamSource: streamSource,
                runID: 201,
                chunkID: 301,
                segmentID: Int64(401 + sequence),
                sequence: sequence,
                speakerLabel: speakerLabel
            ),
            startSeconds: Double(sequence * 10),
            endSeconds: Double(sequence * 10 + 10),
            text: text,
            confidence: confidence,
            createdAt: createdAt,
            words: words
        )
    }

    private func markerEvent() -> AdReportQuery.EventResult {
        AdReportQuery.EventResult(
            identity: .init(
                eventID: 701,
                streamID: 101,
                streamType: "hls",
                streamSource: "https://user:pass@example.test/live.m3u8?token=fixture-secret#frag",
                runID: 201,
                chunkID: 301,
                chunkSequence: 0
            ),
            classification: .adStart,
            markerType: "EXT-X-CUE-OUT",
            source: "https://ads.example.test/start?access_token=fixture-secret#frag",
            pts: 10,
            segment: "/private/ad.ts?password=fixture-secret#frag",
            observedAt: "2026-05-01T17:00:01Z"
        )
    }

    private func playResult() -> SongReportQuery.PlayResult {
        let song = SongReportQuery.SongDisplay(
            songID: 601,
            songKey: "artist-title:fixture artist:fixture song",
            title: "Fixture Song",
            artist: "Fixture Artist",
            album: "Fixture Album",
            isrc: "US-S05-26-00001",
            displayName: "Fixture Artist — Fixture Song",
            isUnknown: false
        )
        return SongReportQuery.PlayResult(
            identity: .init(
                playID: 701,
                streamID: 101,
                streamType: "hls",
                streamSource: "https://user:pass@example.test/live.m3u8?token=fixture-secret#frag",
                runID: 201,
                firstChunkID: 301,
                firstChunkSequence: 0,
                lastChunkID: 302,
                lastChunkSequence: 1
            ),
            song: song,
            startSeconds: 0,
            endSeconds: 10,
            durationSeconds: 10,
            confidence: 0.91,
            source: "/private/song-source?password=fixture-secret#frag",
            createdAt: "2026-05-01T17:00:00Z",
            updatedAt: "2026-05-01T17:00:02Z"
        )
    }

    private func assertNoSecretLeak(_ output: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(output.contains("user:pass"), output, file: file, line: line)
        XCTAssertFalse(output.contains("letmein"), output, file: file, line: line)
        XCTAssertFalse(output.contains("fixture-secret"), output, file: file, line: line)
        XCTAssertFalse(output.contains("token="), output, file: file, line: line)
        XCTAssertFalse(output.contains("api_key="), output, file: file, line: line)
        XCTAssertFalse(output.contains("access_token="), output, file: file, line: line)
        XCTAssertFalse(output.contains("password="), output, file: file, line: line)
        XCTAssertFalse(output.contains("#frag"), output, file: file, line: line)
        XCTAssertFalse(output.contains("#private-fragment"), output, file: file, line: line)
    }
}
