import Foundation
import XCTest

@testable import SoundingKit

final class StreamAppSearchSnapshotTests: XCTestCase {
    func testDefaultRefreshTimestampUsesReusableISO8601ClockAndExplicitValueStillWins() {
        let generated = StreamAppSearchRequest.defaultRefreshTimestamp()
        XCTAssertNotNil(ISO8601DateFormatter().date(from: generated))

        let request = StreamAppSearchRequest(
            phrase: "alpha",
            refreshedAt: "2026-05-01T18:20:00Z"
        )

        XCTAssertEqual(request.refreshedAt, "2026-05-01T18:20:00Z")
    }
}
