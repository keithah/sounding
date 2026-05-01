import Foundation
import GRDB

/// SoundingKit-owned SQLite database handle.
///
/// Opening a `SoundingDatabase` creates a GRDB pool and runs all registered
/// migrations synchronously, so callers either receive a migrated database or a
/// thrown open/migration error with GRDB context.
public final class SoundingDatabase: @unchecked Sendable {
    public let fileURL: URL

    private let pool: DatabasePool

    public init(fileURL: URL) throws {
        self.fileURL = fileURL

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        pool = try DatabasePool(path: fileURL.path, configuration: configuration)
        try SoundingDatabaseMigrator.migrate(pool)
    }

    public func read<Value>(_ value: (Database) throws -> Value) throws -> Value {
        try pool.read(value)
    }

    public func write<Value>(_ updates: (Database) throws -> Value) throws -> Value {
        try pool.write(updates)
    }
}
