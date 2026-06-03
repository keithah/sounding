import Foundation
import XCTest

@testable import SoundingKit

final class SoundingTimestampClockTests: XCTestCase {
    func testTimestampReturnsISO8601StringUsingSharedClock() {
        let timestamp = SoundingTimestampClock.timestamp()

        XCTAssertNotNil(ISO8601DateFormatter().date(from: timestamp))
    }
}
