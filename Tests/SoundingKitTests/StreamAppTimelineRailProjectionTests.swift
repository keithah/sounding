import XCTest
@testable import SoundingKit

final class StreamAppTimelineRailProjectionTests: XCTestCase {
    func testBuildsSongAndMarkerRailItemsInWindow() throws {
        let items = [
            timeline("song:1", kind: .song, start: 10, end: 70, title: "ONE-LINERS", subtitle: "HEIDI FOSS"),
            timeline("event:id3:1", kind: .event, start: 24, end: 25, title: "Timed ID3 ad start", subtitle: "ID3"),
            timeline("event:scte35:1", kind: .event, start: 52, end: 55, title: "SCTE-35 break start", subtitle: "SCTE-35"),
            timeline("transcript:1", kind: .transcript, start: 20, end: 30, title: "Speaker", subtitle: "Words")
        ]

        let rail = StreamAppTimelineRailProjection.project(
            items: items,
            visibleStartSeconds: 0,
            visibleEndSeconds: 100
        )

        XCTAssertEqual(rail.visibleStartSeconds, 0)
        XCTAssertEqual(rail.visibleEndSeconds, 100)
        XCTAssertEqual(rail.spans.map(\.id), ["song:1"])
        XCTAssertEqual(rail.markers.map(\.source), [.timedID3, .scte35])
        let span = try XCTUnwrap(rail.spans.first)
        XCTAssertEqual(span.normalizedStart, 0.10, accuracy: 0.001)
        XCTAssertEqual(span.normalizedEnd, 0.70, accuracy: 0.001)
    }

    func testClampsRailItemsToVisibleWindow() throws {
        let rail = StreamAppTimelineRailProjection.project(
            items: [
                timeline("song:1", kind: .song, start: 90, end: 130, title: "Song", subtitle: "Artist")
            ],
            visibleStartSeconds: 100,
            visibleEndSeconds: 120
        )

        let span = try XCTUnwrap(rail.spans.first)
        XCTAssertEqual(span.normalizedStart, 0.0, accuracy: 0.001)
        XCTAssertEqual(span.normalizedEnd, 1.0, accuracy: 0.001)
    }

    private func timeline(
        _ id: String,
        kind: StreamAppTimelineItemKind,
        start: Double,
        end: Double,
        title: String,
        subtitle: String?
    ) -> StreamAppTimelineItem {
        StreamAppTimelineItem(
            id: id,
            kind: kind,
            startSeconds: start,
            endSeconds: end,
            title: title,
            subtitle: subtitle,
            isSeekable: true
        )
    }
}
