import Foundation
@testable import SoundingKit

final class TemporarySoundingDatabase {
    let fileURL: URL
    let database: SoundingDatabase

    init(file: StaticString = #filePath, line: UInt = #line) throws {
        let filename = "sounding-\(UUID().uuidString).sqlite"
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename, isDirectory: false)
        database = try SoundingDatabase(fileURL: fileURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("shm"))
    }
}
