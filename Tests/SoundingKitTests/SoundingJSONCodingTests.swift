import Foundation
import XCTest

@testable import SoundingKit

final class SoundingJSONCodingTests: XCTestCase {
    func testStableEncoderSortsKeysAndDoesNotEscapeSlashes() throws {
        let data = try SoundingJSONCoding.stableEncoder().encode([
            "url": "https://example.test/live.m3u8",
            "alpha": "first",
        ])
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(text, #"{"alpha":"first","url":"https://example.test/live.m3u8"}"#)
    }

    func testPrettySortedEncoderSortsKeysAndPrettyPrints() throws {
        let data = try SoundingJSONCoding.prettySortedEncoder().encode([
            "url": "https://example.test/live.m3u8",
            "alpha": "first",
        ])
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\n"))
        XCTAssertTrue(text.contains(#""alpha" : "first""#), text)
        XCTAssertTrue(text.contains(#""url" : "https:\/\/example.test\/live.m3u8""#), text)
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: #""alpha""#)?.lowerBound),
            try XCTUnwrap(text.range(of: #""url""#)?.lowerBound)
        )
    }
}
