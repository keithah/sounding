import XCTest
@testable import SoundingKit

final class SoundingKitTests: XCTestCase {
    func testSoundingKitVersionIdentifiesTheLibrary() throws {
        XCTAssertEqual(SoundingKitVersion.current.name, "Sounding")
        XCTAssertFalse(SoundingKitVersion.current.string.isEmpty)
    }
}
