import Foundation
import XCTest

@testable import SoundingKit

final class InferenceQueueTests: XCTestCase {
    func testConcurrentOperationsNeverExceedOneActiveProviderCall() async throws {
        let queue = InferenceQueue()
        let probe = InferenceProbe()
        let firstGate = AsyncGate()

        let first = Task {
            try await queue.run("first") {
                await probe.run(label: "first", gate: firstGate)
            }
        }
        try await awaitCondition("first operation started") {
            await probe.startedLabels == ["first"]
        }

        let second = Task {
            try await queue.run("second") {
                await probe.run(label: "second")
            }
        }
        try await awaitCondition("second operation queued") {
            await queue.snapshot().currentDepth == 2
        }

        await firstGate.open()
        _ = try await first.value
        _ = try await second.value

        let summary = await probe.summary()
        XCTAssertEqual(summary.maxActive, 1)
        XCTAssertEqual(summary.startedLabels, ["first", "second"])
        XCTAssertEqual(summary.completedLabels, ["first", "second"])

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.submitted, 2)
        XCTAssertEqual(snapshot.started, 2)
        XCTAssertEqual(snapshot.completed, 2)
        XCTAssertEqual(snapshot.currentDepth, 0)
        XCTAssertFalse(snapshot.isBusy)
        XCTAssertEqual(snapshot.maxDepth, 2)
    }

    func testWaitingOperationsAreAdmittedFIFO() async throws {
        let queue = InferenceQueue()
        let probe = InferenceProbe()
        let firstGate = AsyncGate()

        let first = Task {
            try await queue.run("first") {
                await probe.run(label: "first", gate: firstGate)
            }
        }
        try await awaitCondition("first operation started") {
            await probe.startedLabels == ["first"]
        }

        let second = Task {
            try await queue.run("second") {
                await probe.run(label: "second")
            }
        }
        try await awaitCondition("second operation queued") {
            await queue.snapshot().currentDepth == 2
        }

        let third = Task {
            try await queue.run("third") {
                await probe.run(label: "third")
            }
        }
        try await awaitCondition("third operation queued") {
            await queue.snapshot().currentDepth == 3
        }

        await firstGate.open()
        _ = try await first.value
        _ = try await second.value
        _ = try await third.value

        let summary = await probe.summary()
        XCTAssertEqual(summary.startedLabels, ["first", "second", "third"])
        XCTAssertEqual(summary.completedLabels, ["first", "second", "third"])
        XCTAssertEqual(summary.maxActive, 1)
        let finalSnapshot = await queue.snapshot()
        XCTAssertEqual(finalSnapshot.maxDepth, 3)
    }

    func testCancelledWaiterDoesNotBlockNextOperation() async throws {
        let queue = InferenceQueue()
        let probe = InferenceProbe()
        let firstGate = AsyncGate()

        let first = Task {
            try await queue.run("first") {
                await probe.run(label: "first", gate: firstGate)
            }
        }
        try await awaitCondition("first operation started") {
            await probe.startedLabels == ["first"]
        }

        let cancelledWaiter = Task {
            try await queue.run("cancelled") {
                await probe.run(label: "cancelled")
            }
        }
        try await awaitCondition("waiter queued before cancellation") {
            await queue.snapshot().currentDepth == 2
        }
        cancelledWaiter.cancel()

        do {
            _ = try await cancelledWaiter.value
            XCTFail("Expected queued task cancellation to throw")
        } catch is CancellationError {
            // Expected.
        }

        try await awaitCondition("cancelled waiter removed") {
            await queue.snapshot().currentDepth == 1
        }

        let next = Task {
            try await queue.run("next") {
                await probe.run(label: "next")
            }
        }
        try await awaitCondition("next operation queued") {
            await queue.snapshot().currentDepth == 2
        }

        await firstGate.open()
        _ = try await first.value
        _ = try await next.value

        let summary = await probe.summary()
        XCTAssertEqual(summary.startedLabels, ["first", "next"])
        XCTAssertEqual(summary.completedLabels, ["first", "next"])
        XCTAssertEqual(summary.maxActive, 1)
        let finalSnapshot = await queue.snapshot()
        XCTAssertEqual(finalSnapshot.completed, 2)
    }

    func testQueuedTranscriberPassesThroughEmptySegmentsAndPreservesErrors() async throws {
        let queue = InferenceQueue()
        let empty = QueuedTranscriber(ProbeTranscriber(result: []), queue: queue)
        let emptySegments = try await empty.transcribe(Self.chunk())
        XCTAssertEqual(emptySegments, [])

        let failing = QueuedTranscriber(ProbeTranscriber(error: SentinelProviderError.transcribe), queue: queue)
        do {
            _ = try await failing.transcribe(Self.chunk(sequence: 1))
            XCTFail("Expected sentinel transcriber error")
        } catch let error as SentinelProviderError {
            XCTAssertEqual(error, .transcribe)
            XCTAssertEqual(error.description, "sentinel-transcribe")
        } catch {
            XCTFail("Expected SentinelProviderError, got \(error)")
        }
    }

    func testQueuedDiarizerPassesThroughEmptyTurnsAndPreservesErrors() async throws {
        let queue = InferenceQueue()
        let empty = QueuedDiarizer(ProbeDiarizer(result: []), queue: queue)
        let emptyTurns = try await empty.diarize(Self.chunk(), transcriptSegments: [])
        XCTAssertEqual(emptyTurns, [])

        let failing = QueuedDiarizer(ProbeDiarizer(error: SentinelProviderError.diarize), queue: queue)
        do {
            _ = try await failing.diarize(Self.chunk(sequence: 1), transcriptSegments: [])
            XCTFail("Expected sentinel diarizer error")
        } catch let error as SentinelProviderError {
            XCTAssertEqual(error, .diarize)
            XCTAssertEqual(error.description, "sentinel-diarize")
        } catch {
            XCTFail("Expected SentinelProviderError, got \(error)")
        }
    }

    private static func chunk(sequence: Int = 0) -> DecodedAudioChunk {
        DecodedAudioChunk(
            sequence: sequence,
            audio: Data("audio".utf8),
            startSeconds: Double(sequence),
            endSeconds: Double(sequence) + 1,
            startedAt: "2026-05-01T00:00:00Z"
        )
    }
}

private func awaitCondition(
    _ description: String,
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(description)")
}

private actor InferenceProbe {
    struct Summary: Equatable {
        var startedLabels: [String]
        var completedLabels: [String]
        var maxActive: Int
    }

    private var active = 0
    private var maxActive = 0
    private(set) var startedLabels: [String] = []
    private var completedLabels: [String] = []

    func run(label: String, gate: AsyncGate? = nil) async {
        active += 1
        maxActive = max(maxActive, active)
        startedLabels.append(label)
        if let gate {
            await gate.wait()
        }
        completedLabels.append(label)
        active -= 1
    }

    func summary() -> Summary {
        Summary(startedLabels: startedLabels, completedLabels: completedLabels, maxActive: maxActive)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct ProbeTranscriber: MLTranscription {
    var result: [TranscriptSegmentDraft] = []
    var error: Error?

    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        if let error { throw error }
        return result
    }
}

private struct ProbeDiarizer: SpeakerDiarization {
    var result: [SpeakerTurnDraft] = []
    var error: Error?

    func diarize(
        _ chunk: DecodedAudioChunk,
        transcriptSegments: [TranscriptSegmentDraft]
    ) async throws -> [SpeakerTurnDraft] {
        if let error { throw error }
        return result
    }
}

private enum SentinelProviderError: Error, Equatable, CustomStringConvertible {
    case transcribe
    case diarize

    var description: String {
        switch self {
        case .transcribe:
            return "sentinel-transcribe"
        case .diarize:
            return "sentinel-diarize"
        }
    }
}
