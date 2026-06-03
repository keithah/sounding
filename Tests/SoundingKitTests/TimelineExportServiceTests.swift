import Foundation
import XCTest

@testable import SoundingKit

final class TimelineExportServiceTests: XCTestCase {
    func testExportsTranscriptTextWithTimestamps() throws {
        let items = [
            StreamAppTimelineItem(
                id: "song:1",
                kind: .song,
                startSeconds: 0,
                title: "Song",
                subtitle: "Artist",
                isSeekable: true
            ),
            StreamAppTimelineItem(
                id: "transcript:1",
                kind: .transcript,
                startSeconds: 10,
                endSeconds: 22,
                startTimestamp: "2026-06-02T12:00:10Z",
                endTimestamp: "2026-06-02T12:00:22Z",
                title: "Host",
                subtitle: "This is the transcript.",
                isSeekable: true
            ),
        ]

        let text = TimelineExportService.transcriptText(items: items)

        XCTAssertEqual(
            text,
            "[2026-06-02T12:00:10Z - 2026-06-02T12:00:22Z] This is the transcript.\n"
        )
    }

    func testExportsTranscriptTextSortedByTimelineWithSecondsFallback() throws {
        let items = [
            StreamAppTimelineItem(
                id: "transcript:2",
                kind: .transcript,
                startSeconds: 12,
                endSeconds: nil,
                title: "Second line",
                isSeekable: false
            ),
            StreamAppTimelineItem(
                id: "transcript:1",
                kind: .transcript,
                startSeconds: 1.25,
                endSeconds: 3.75,
                title: "Speaker",
                subtitle: "First line",
                isSeekable: true
            ),
        ]

        let text = TimelineExportService.transcriptText(items: items)

        XCTAssertEqual(
            text,
            """
            [1.2s - 3.8s] First line
            [12.0s - 12.0s] Second line

            """
        )
    }

    func testExportsTimelineJSONInChronologicalOrder() throws {
        let items = [
            StreamAppTimelineItem(
                id: "song:2",
                kind: .song,
                startSeconds: 20,
                endSeconds: 30,
                startTimestamp: "2026-06-02T12:00:20Z",
                title: "Later Song",
                subtitle: "Artist",
                isSeekable: true
            ),
            StreamAppTimelineItem(
                id: "event:1",
                kind: .event,
                startSeconds: 5,
                endSeconds: nil,
                title: "Marker",
                subtitle: nil,
                isSeekable: false
            ),
        ]

        let data = try TimelineExportService.timelineJSON(items: items)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )

        XCTAssertEqual(rows.map { $0["id"] as? String }, ["event:1", "song:2"])
        XCTAssertEqual(rows.first?["kind"] as? String, "event")
        XCTAssertEqual(rows.first?["startSeconds"] as? Double, 5)
        XCTAssertEqual(rows.first?["isSeekable"] as? Bool, false)
        XCTAssertEqual(rows.last?["subtitle"] as? String, "Artist")
    }

    func testCopyWithTimeIncludesKindAndTimestamp() {
        let item = StreamAppTimelineItem(
            id: "song:1",
            kind: .song,
            startSeconds: 10,
            endSeconds: 70,
            startTimestamp: "2026-06-02T12:00:10Z",
            title: "ONE-LINERS",
            subtitle: "HEIDI FOSS",
            isSeekable: true
        )

        XCTAssertEqual(
            TimelineExportService.copyText(item: item, includesTime: true),
            "[2026-06-02T12:00:10Z] Song: ONE-LINERS - HEIDI FOSS"
        )
    }

    func testExportReportsMissingAudioRanges() throws {
        let result = TimelineExportService.audioManifest(
            requestedStartSeconds: 10,
            requestedEndSeconds: 20,
            retainedRanges: [
                TimelineExportAudioRange(
                    startSeconds: 10,
                    endSeconds: 14,
                    fileName: "clip-1.pcm"
                )
            ]
        )

        XCTAssertEqual(
            result.missingRanges,
            [TimelineExportMissingRange(startSeconds: 14, endSeconds: 20)]
        )
    }

    func testAudioManifestClipsAndMergesRetainedRangesBeforeFindingGaps() {
        let result = TimelineExportService.audioManifest(
            requestedStartSeconds: 10,
            requestedEndSeconds: 30,
            retainedRanges: [
                TimelineExportAudioRange(startSeconds: 18, endSeconds: 26, fileName: "b.pcm"),
                TimelineExportAudioRange(startSeconds: 8, endSeconds: 14, fileName: "a.pcm"),
                TimelineExportAudioRange(startSeconds: 14, endSeconds: 20, fileName: "c.pcm"),
                TimelineExportAudioRange(startSeconds: 35, endSeconds: 40, fileName: "ignored.pcm"),
            ]
        )

        XCTAssertEqual(
            result.retainedRanges.map(\.fileName),
            ["a.pcm", "c.pcm", "b.pcm"]
        )
        XCTAssertEqual(
            result.retainedRanges.map { TimelineExportMissingRange(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) },
            [
                TimelineExportMissingRange(startSeconds: 10, endSeconds: 14),
                TimelineExportMissingRange(startSeconds: 14, endSeconds: 20),
                TimelineExportMissingRange(startSeconds: 20, endSeconds: 26),
            ]
        )
        XCTAssertEqual(
            result.missingRanges,
            [TimelineExportMissingRange(startSeconds: 26, endSeconds: 30)]
        )
    }
}
