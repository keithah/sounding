import Foundation

public final class SoundingTimestampClock: @unchecked Sendable {
    private static let shared = SoundingTimestampClock()

    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    public static func timestamp() -> String {
        shared.timestamp()
    }

    private func timestamp() -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: Date())
    }
}
