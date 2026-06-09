import Foundation
import GRDB
import XCTest

@testable import SoundingKit

class AppStreamRuntimeTestCase: XCTestCase {
    func nextEvent(
        from iterator: inout AsyncStream<AppStreamRuntimeEvent>.Iterator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AppStreamRuntimeEvent {
        guard let event = await iterator.next() else {
            throw RuntimeTestError.missingEvent
        }
        return event
    }

    func nextEvent(
        matching predicate: (AppStreamRuntimeEvent) -> Bool,
        from iterator: inout AsyncStream<AppStreamRuntimeEvent>.Iterator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AppStreamRuntimeEvent {
        for _ in 0..<10 {
            let event = try await nextEvent(from: &iterator, file: file, line: line)
            if predicate(event) { return event }
        }
        throw RuntimeTestError.missingEvent
    }
}

enum RuntimeTestError: Error {
    case missingEvent
}

final class DeterministicDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]
    private let fallback: Date

    init(_ dates: [Date]) {
        self.dates = dates
        self.fallback = dates.last ?? Date(timeIntervalSince1970: 0)
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        if dates.isEmpty { return fallback }
        return dates.removeFirst()
    }
}

actor RecordingAppRuntimeIngester: AppStreamRuntimeIngesting {
    private let result: AppStreamRuntimeResult
    private var recorded: [AppStreamRuntimeRequest] = []

    init(result: AppStreamRuntimeResult) {
        self.result = result
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        recorded.append(request)
        return result
    }

    func requests() -> [AppStreamRuntimeRequest] {
        recorded
    }
}

actor RuntimeGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

actor RuntimeStopGate {
    private var stopCallCount = 0
    private var stopWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func recordStopAndWait() async {
        stopCallCount += 1
        resumeReadyStopWaiters()
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForStopCallCount(_ count: Int) async {
        if stopCallCount >= count { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append((count, continuation))
        }
    }

    func callCount() -> Int {
        stopCallCount
    }

    func release() {
        isReleased = true
        let current = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    private func resumeReadyStopWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in stopWaiters {
            if stopCallCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        stopWaiters = remaining
    }
}

struct BlockingAppRuntimeIngester: AppStreamRuntimeIngesting {
    let gate: RuntimeGate

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        await gate.wait()
        try Task.checkCancellation()
        return AppStreamRuntimeResult(streamID: request.streamID)
    }
}

actor RecordingBlockingAppRuntimeIngester: AppStreamRuntimeIngesting {
    private let gate: RuntimeGate
    private var requests: [AppStreamRuntimeRequest] = []

    init(gate: RuntimeGate) {
        self.gate = gate
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        requests.append(request)
        await gate.wait()
        try Task.checkCancellation()
        return AppStreamRuntimeResult(streamID: request.streamID)
    }

    func callCount() -> Int {
        requests.count
    }
}

struct GatedStopRuntimePlaybackAdapter: AppPCMPlaybackAdapting {
    let gate: RuntimeStopGate

    func prepare(streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock) async throws {}

    func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws {}

    func playReplacingScheduledBuffers(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws {}

    func pause(timeline: AppPlayerTimelineClock) async {}

    func resume(timeline: AppPlayerTimelineClock) async {}

    func stop(timeline: AppPlayerTimelineClock) async {
        await gate.recordStopAndWait()
    }
}

actor RecordingRuntimePlaybackAdapter: AppPCMPlaybackAdapting {
    private var recordedActions: [String] = []
    private var preparedStreamIDs: [Int64] = []

    func prepare(streamID: Int64, sourceDescription: String, timeline: AppPlayerTimelineClock) async throws {
        preparedStreamIDs.append(streamID)
    }

    func play(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws {
        recordedActions.append(contentsOf: frames.map { "play:\($0.sequence)" })
    }

    func playReplacingScheduledBuffers(_ frames: [SharedPCMFrame], timeline: AppPlayerTimelineClock) async throws {
        recordedActions.append(contentsOf: frames.map { "replace:\($0.sequence)" })
    }

    func pause(timeline: AppPlayerTimelineClock) async {
        recordedActions.append("pause")
    }

    func resume(timeline: AppPlayerTimelineClock) async {
        recordedActions.append("resume")
    }

    func stop(timeline: AppPlayerTimelineClock) async {
        recordedActions.append("stop")
    }

    func actions() -> [String] {
        recordedActions
    }

    func preparedStreams() -> [Int64] {
        preparedStreamIDs
    }
}

actor LifecycleRecordingIngester: AppStreamRuntimeIngesting {
    private let gate: RuntimeGate
    private var requests: [AppStreamRuntimeRequest] = []

    init(gate: RuntimeGate) {
        self.gate = gate
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        requests.append(request)
        await gate.wait()
        try Task.checkCancellation()
        return AppStreamRuntimeResult(streamID: request.streamID)
    }

    func requestStreamIDs() -> [Int64] {
        requests.map(\.streamID)
    }
}

actor RetrySleepGate {
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep(seconds: Int) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.releaseAll() }
        }
        try Task.checkCancellation()
    }

    func releaseAll() {
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

actor PerStreamRuntimeIngester: AppStreamRuntimeIngesting {
    private let flakyStreamID: Int64
    private let blockingStreamID: Int64
    private let blockingGate: RuntimeGate
    private var flakyCalls = 0

    init(flakyStreamID: Int64, blockingStreamID: Int64, blockingGate: RuntimeGate) {
        self.flakyStreamID = flakyStreamID
        self.blockingStreamID = blockingStreamID
        self.blockingGate = blockingGate
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        if request.streamID == flakyStreamID {
            flakyCalls += 1
            if flakyCalls == 1 {
                throw RuntimeFailure(
                    message:
                        "decode failed at /tmp/token=secret.raw for https://user:pass@example.test/retry.m3u8?token=secret"
                )
            }
            return AppStreamRuntimeResult(streamID: request.streamID, processedChunks: 1)
        }
        if request.streamID == blockingStreamID {
            await blockingGate.wait()
            try Task.checkCancellation()
            return AppStreamRuntimeResult(streamID: request.streamID)
        }
        return AppStreamRuntimeResult(streamID: request.streamID)
    }
}

actor AlwaysFailingAppRuntimeIngester: AppStreamRuntimeIngesting {
    private let message: String

    init(message: String) {
        self.message = message
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        throw RuntimeFailure(message: message)
    }
}

actor RestartingAppRuntimeIngester: AppStreamRuntimeIngesting {
    private let firstGate: RuntimeGate
    private let secondGate: RuntimeGate
    private var calls = 0

    init(firstGate: RuntimeGate, secondGate: RuntimeGate) {
        self.firstGate = firstGate
        self.secondGate = secondGate
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        calls += 1
        if calls == 1 {
            await firstGate.wait()
        } else {
            await secondGate.wait()
        }
        try Task.checkCancellation()
        return AppStreamRuntimeResult(streamID: request.streamID, processedChunks: calls)
    }
}

actor FlakyAppRuntimeIngester: AppStreamRuntimeIngesting {
    private let streamID: Int64
    private var calls = 0

    init(streamID: Int64) {
        self.streamID = streamID
    }

    func run(_ request: AppStreamRuntimeRequest) async throws -> AppStreamRuntimeResult {
        calls += 1
        if calls == 1 {
            throw RuntimeFailure(
                message:
                    "decode failed at /tmp/token=secret.raw for https://user:pass@example.test/retry.m3u8?token=secret"
            )
        }
        return AppStreamRuntimeResult(streamID: streamID, processedChunks: 1)
    }

    func callCount() -> Int { calls }
}

func makeRuntimeFactoryTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SoundingAppRuntimeFactoryTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class RuntimeFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _databaseOpenCount = 0
    private var _ingesterConfigurations: [SoundingAppConfiguration] = []
    private var _runtimeConstructed = false

    var databaseOpenCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _databaseOpenCount
    }

    var ingesterConfigurations: [SoundingAppConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return _ingesterConfigurations
    }

    var runtimeConstructed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _runtimeConstructed
    }

    func recordDatabaseOpen() {
        lock.lock()
        defer { lock.unlock() }
        _databaseOpenCount += 1
    }

    func recordIngesterConfiguration(_ configuration: SoundingAppConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        _ingesterConfigurations.append(configuration)
    }

    func recordRuntimeConstructed() {
        lock.lock()
        defer { lock.unlock() }
        _runtimeConstructed = true
    }
}

struct RuntimeFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

struct FixtureDecoder: AudioDecoding {
    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        XCTAssertNil(request.durationSeconds)
        XCTAssertNil(request.maxChunks)
        return [
            DecodedAudioChunk(
                sequence: 0,
                segmentURI: "https://user:pass@example.test/pipeline-0.ts?token=secret",
                hlsIdentity: HLSDecodedAudioChunkIdentity(
                    mediaSequence: 0,
                    segmentIdentity: IngestRedaction.sourceDescription(
                        "https://user:pass@example.test/pipeline-0.ts?token=secret"),
                    manifestPosition: 0
                ),
                audio: Data([0x01, 0x02, 0x03]),
                startSeconds: 0,
                endSeconds: 1,
                startedAt: "2026-05-01T00:00:00Z",
                endedAt: "2026-05-01T00:00:01Z"
            )
        ]
    }
}

struct ThrowingAudioDecoder: AudioDecoding {
    var message: String

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        throw RuntimeFailure(message: message)
    }
}

actor PollingFixtureDecoder: AudioDecoding {
    private var calls = 0
    private var waiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        XCTAssertNil(request.durationSeconds)
        XCTAssertEqual(request.maxChunks, 1)
        calls += 1
        releaseSatisfiedWaiters()
        let sequence = calls - 1
        let segmentURI = "https://example.test/continuous-\(sequence).ts"
        return [
            DecodedAudioChunk(
                sequence: 0,
                segmentURI: segmentURI,
                hlsIdentity: HLSDecodedAudioChunkIdentity(
                    mediaSequence: sequence,
                    segmentIdentity: IngestRedaction.sourceDescription(segmentURI),
                    manifestPosition: 0
                ),
                audio: Data([0x01, 0x00, 0x02, 0x00]),
                audioFormat: .linearPCM(sampleRate: 44_100, channelCount: 1, bitDepth: 16),
                startSeconds: Double(sequence),
                endSeconds: Double(sequence + 1),
                startedAt: "2026-05-01T00:00:00Z",
                endedAt: "2026-05-01T00:00:01Z"
            )
        ]
    }

    func waitForCalls(_ minimum: Int) async {
        if calls >= minimum { return }
        await withCheckedContinuation { continuation in
            waiters.append((minimum, continuation))
        }
    }

    private func releaseSatisfiedWaiters() {
        var remaining: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if calls >= waiter.minimum {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

actor HangingPollingFixtureDecoder: AudioDecoding {
    private var calls = 0
    private var waiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        XCTAssertNil(request.durationSeconds)
        XCTAssertEqual(request.maxChunks, 1)
        calls += 1
        releaseSatisfiedWaiters()
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return []
    }

    func waitForCalls(_ minimum: Int) async {
        if calls >= minimum { return }
        await withCheckedContinuation { continuation in
            waiters.append((minimum, continuation))
        }
    }

    private func releaseSatisfiedWaiters() {
        var remaining: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if calls >= waiter.minimum {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

struct FixtureTranscriber: MLTranscription {
    func transcribe(_ chunk: DecodedAudioChunk) async throws -> [TranscriptSegmentDraft] {
        [
            TranscriptSegmentDraft(
                sequence: 0,
                speakerLabel: "fixture-speaker",
                startSeconds: chunk.startSeconds,
                endSeconds: chunk.endSeconds,
                text: "fixture transcript",
                confidence: 0.9,
                words: [
                    TranscriptWordDraft(
                        sequence: 0,
                        speakerLabel: "fixture-speaker",
                        startSeconds: chunk.startSeconds,
                        endSeconds: chunk.endSeconds,
                        text: "fixture",
                        confidence: 0.9
                    )
                ]
            )
        ]
    }
}

struct FixtureDiarizer: SpeakerDiarization {
    func diarize(
        _ chunk: DecodedAudioChunk,
        transcriptSegments: [TranscriptSegmentDraft]
    ) async throws -> [SpeakerTurnDraft] {
        transcriptSegments.map { segment in
            SpeakerTurnDraft(
                speakerLabel: segment.speakerLabel ?? "fixture-speaker",
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                confidence: 0.8
            )
        }
    }
}
