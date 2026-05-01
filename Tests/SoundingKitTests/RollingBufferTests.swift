import Foundation
import XCTest

@testable import SoundingKit

final class RollingBufferTests: XCTestCase {
    func testSpillsColdFramesAndEvictsByTargetDurationAndSize() async throws {
        let spillDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: spillDirectory) }
        let buffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 6,
                hotMemoryDurationSeconds: 2,
                maximumSpillBytes: 6,
                spillSegmentDurationSeconds: 2,
                spillDirectory: spillDirectory
            )
        )
        await buffer.start(streamID: 11)

        let snapshot = await buffer.append([
            frame(sequence: 0, start: 0, end: 2, bytes: [0, 0, 0]),
            frame(sequence: 1, start: 2, end: 4, bytes: [1, 1, 1]),
            frame(sequence: 2, start: 4, end: 6, bytes: [2, 2, 2]),
            frame(sequence: 3, start: 6, end: 8, bytes: [3, 3, 3]),
            frame(sequence: 4, start: 8, end: 10, bytes: [4, 4, 4]),
        ])

        XCTAssertEqual(snapshot.bufferedRange, RollingBufferRange(startSeconds: 4, endSeconds: 10))
        XCTAssertEqual(snapshot.frameCount, 3)
        XCTAssertEqual(snapshot.memoryFrameCount, 2)
        XCTAssertEqual(snapshot.spillFrameCount, 1)
        XCTAssertEqual(snapshot.spillBytes, 3)
        XCTAssertEqual(snapshot.evictionCount, 2)
        XCTAssertTrue(snapshot.spillAvailable)
        XCTAssertFalse(snapshot.memoryOnlyFallback)

        let spilled = await buffer.seek(to: 4.5)
        guard case .available(let spilledFrame) = spilled else {
            return XCTFail("Expected spilled frame to be seekable")
        }
        XCTAssertEqual(spilledFrame.sequence, 2)
        XCTAssertEqual(spilledFrame.audio, Data([2, 2, 2]))
    }

    func testSeekBoundariesReportUnavailableRanges() async throws {
        let buffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 60,
                hotMemoryDurationSeconds: 60,
                maximumSpillBytes: 0
            )
        )
        await buffer.start(streamID: 12)
        _ = await buffer.append([
            frame(streamID: 12, sequence: 0, start: 10, end: 12, bytes: [10]),
            frame(streamID: 12, sequence: 1, start: 12, end: 14, bytes: [12]),
        ])

        guard case .available(let live) = await buffer.seekToLive() else {
            return XCTFail("Expected live edge frame")
        }
        XCTAssertEqual(live.sequence, 1)

        guard case .unavailable(let requested, let range) = await buffer.seek(to: 9.5) else {
            return XCTFail("Expected unavailable seek before retained range")
        }
        XCTAssertEqual(requested, 9.5)
        XCTAssertEqual(range, RollingBufferRange(startSeconds: 10, endSeconds: 14))
    }

    func testCleanupRemovesSpillSegmentsAndReportsResult() async throws {
        let spillDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: spillDirectory) }
        let buffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 60,
                hotMemoryDurationSeconds: 1,
                maximumSpillBytes: 100,
                spillDirectory: spillDirectory
            )
        )
        await buffer.start(streamID: 13)
        _ = await buffer.append([
            frame(streamID: 13, sequence: 0, start: 0, end: 2, bytes: [0, 0]),
            frame(streamID: 13, sequence: 1, start: 2, end: 4, bytes: [1, 1]),
        ])
        let beforeCleanup = await buffer.snapshot()
        XCTAssertGreaterThan(beforeCleanup.spillFrameCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spillDirectory.path))

        let afterCleanup = await buffer.cleanup()

        XCTAssertEqual(afterCleanup.frameCount, 0)
        XCTAssertEqual(afterCleanup.spillBytes, 0)
        XCTAssertGreaterThanOrEqual(afterCleanup.cleanupCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spillDirectory.path))
    }

    func testSpillFailureFallsBackToMemoryOnlyWithoutDroppingFrames() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SoundingRollingBuffer-file-\(UUID().uuidString)",
            isDirectory: false
        )
        try Data([0xff]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let unavailableChild = fileURL.appendingPathComponent("child", isDirectory: true)
        let buffer = RollingPCMBuffer(
            configuration: RollingBufferConfiguration(
                targetDurationSeconds: 60,
                hotMemoryDurationSeconds: 1,
                maximumSpillBytes: 100,
                spillDirectory: unavailableChild
            )
        )

        await buffer.start(streamID: 14)
        let snapshot = await buffer.append([
            frame(streamID: 14, sequence: 0, start: 0, end: 2, bytes: [0]),
            frame(streamID: 14, sequence: 1, start: 2, end: 4, bytes: [1]),
        ])

        XCTAssertFalse(snapshot.spillAvailable)
        XCTAssertTrue(snapshot.memoryOnlyFallback)
        XCTAssertEqual(snapshot.frameCount, 2)
        XCTAssertEqual(snapshot.memoryFrameCount, 2)
        XCTAssertEqual(snapshot.spillFrameCount, 0)
        XCTAssertTrue(snapshot.lastMessage.contains("memory-only fallback"), snapshot.lastMessage)
    }

    func testTimelineAppliesRollingBufferSeekUnavailableFeedback() async throws {
        let timeline = AppPlayerTimelineClock()
        await timeline.reset(streamID: 15)
        let bufferSnapshot = RollingBufferSnapshot(
            streamID: 15,
            bufferedRange: RollingBufferRange(startSeconds: 20, endSeconds: 30),
            liveEdgeSeconds: 30,
            frameCount: 2,
            memoryFrameCount: 2,
            spillAvailable: true,
            lastMessage: "Rolling buffer ready."
        )
        await timeline.updateRollingBuffer(bufferSnapshot)
        await timeline.applySeekResult(
            .unavailable(
                requestedSeconds: 10,
                bufferedRange: RollingBufferRange(startSeconds: 20, endSeconds: 30)
            )
        )

        let snapshot = await timeline.snapshot()
        XCTAssertEqual(snapshot.bufferedStartSeconds, 20)
        XCTAssertEqual(snapshot.bufferedEndSeconds, 30)
        XCTAssertEqual(snapshot.unavailableRangeMessage, "Requested 10.0s is unavailable (available range 20.0-30.0s).")
    }


    func testPlayerTimelineSnapshotRedactsFailureStateAndMessages() async throws {
        let timeline = AppPlayerTimelineSnapshot(
            streamID: 16,
            state: .failed(message: "Audio failed at /Users/example/private/device.raw?token=secret"),
            unavailableRangeMessage: "Requested file:///Users/example/private/audio.raw?token=secret",
            lastMessage: "Audio failed at /Users/example/private/device.raw?token=secret"
        )

        if case .failed(let message) = timeline.state {
            XCTAssertFalse(message.contains("/Users/example"), message)
            XCTAssertFalse(message.contains("token=secret"), message)
            XCTAssertTrue(message.contains("[redacted-path]"), message)
        } else {
            XCTFail("Expected failed player state")
        }
        XCTAssertFalse(timeline.lastMessage.contains("/Users/example"), timeline.lastMessage)
        XCTAssertFalse(timeline.lastMessage.contains("token=secret"), timeline.lastMessage)
        XCTAssertFalse(timeline.unavailableRangeMessage?.contains("/Users/example") ?? true)
        XCTAssertFalse(timeline.unavailableRangeMessage?.contains("token=secret") ?? true)
    }

    private func frame(
        streamID: Int64 = 11,
        sequence: Int,
        start: Double,
        end: Double,
        bytes: [UInt8]
    ) -> SharedPCMFrame {
        SharedPCMFrame(
            streamID: streamID,
            sequence: sequence,
            audio: Data(bytes),
            startSeconds: start,
            endSeconds: end
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SoundingRollingBufferTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
