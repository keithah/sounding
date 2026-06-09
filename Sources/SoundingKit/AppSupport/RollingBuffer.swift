import Foundation

public struct RollingBufferConfiguration: Equatable, Sendable {
    public var targetDurationSeconds: Double
    public var hotMemoryDurationSeconds: Double
    public var maximumSpillBytes: Int
    public var spillSegmentDurationSeconds: Double
    public var spillDirectory: URL?

    public init(
        targetDurationSeconds: Double = 60 * 60,
        hotMemoryDurationSeconds: Double = 30,
        maximumSpillBytes: Int = 512 * 1024 * 1024,
        spillSegmentDurationSeconds: Double = 30,
        spillDirectory: URL? = nil
    ) {
        self.targetDurationSeconds = max(1, targetDurationSeconds)
        self.hotMemoryDurationSeconds = max(1, min(hotMemoryDurationSeconds, targetDurationSeconds))
        self.maximumSpillBytes = max(0, maximumSpillBytes)
        self.spillSegmentDurationSeconds = max(1, spillSegmentDurationSeconds)
        self.spillDirectory = spillDirectory
    }

    public static func appDefault(spillDirectory: URL? = nil) -> RollingBufferConfiguration {
        RollingBufferConfiguration(spillDirectory: spillDirectory)
    }
}

public struct RollingBufferRange: Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var durationSeconds: Double { max(0, endSeconds - startSeconds) }

    public func contains(_ seconds: Double) -> Bool {
        seconds >= startSeconds && seconds <= endSeconds
    }
}

public struct RollingBufferSnapshot: Equatable, Sendable {
    public var streamID: Int64?
    public var bufferedRange: RollingBufferRange?
    public var liveEdgeSeconds: Double
    public var frameCount: Int
    public var memoryFrameCount: Int
    public var spillFrameCount: Int
    public var spillBytes: Int
    public var spillAvailable: Bool
    public var memoryOnlyFallback: Bool
    public var evictionCount: Int
    public var cleanupCount: Int
    public var lastMessage: String

    public init(
        streamID: Int64? = nil,
        bufferedRange: RollingBufferRange? = nil,
        liveEdgeSeconds: Double = 0,
        frameCount: Int = 0,
        memoryFrameCount: Int = 0,
        spillFrameCount: Int = 0,
        spillBytes: Int = 0,
        spillAvailable: Bool = false,
        memoryOnlyFallback: Bool = false,
        evictionCount: Int = 0,
        cleanupCount: Int = 0,
        lastMessage: String = "Rolling buffer idle."
    ) {
        self.streamID = streamID
        self.bufferedRange = bufferedRange
        self.liveEdgeSeconds = liveEdgeSeconds
        self.frameCount = frameCount
        self.memoryFrameCount = memoryFrameCount
        self.spillFrameCount = spillFrameCount
        self.spillBytes = spillBytes
        self.spillAvailable = spillAvailable
        self.memoryOnlyFallback = memoryOnlyFallback
        self.evictionCount = evictionCount
        self.cleanupCount = cleanupCount
        self.lastMessage = IngestRedaction.redact(lastMessage)
    }
}

public enum RollingBufferSeekResult: Equatable, Sendable {
    case available(SharedPCMFrame)
    case unavailable(requestedSeconds: Double, bufferedRange: RollingBufferRange?)

    var availableStreamID: Int64? {
        switch self {
        case .available(let frame):
            return frame.streamID
        case .unavailable:
            return nil
        }
    }
}

private enum RollingBufferStorage: Equatable, Sendable {
    case memory(Data)
    case spill(URL, bytes: Int)
}

private struct RollingBufferEntry: Equatable, Sendable {
    var frame: SharedPCMFrame
    var storage: RollingBufferStorage

    var byteCount: Int {
        switch storage {
        case .memory(let data): return data.count
        case .spill(_, let bytes): return bytes
        }
    }

    var isSpilled: Bool {
        if case .spill = storage { return true }
        return false
    }
}

private enum RollingBufferFrameKey: Hashable, Sendable {
    case hls(streamID: Int64, mediaSequence: Int, segmentIdentity: String)
    case pcm(streamID: Int64, sequence: Int, startMilliseconds: Int64, endMilliseconds: Int64)

    init(_ frame: SharedPCMFrame) {
        if let hlsIdentity = frame.hlsIdentity {
            self = .hls(
                streamID: frame.streamID,
                mediaSequence: hlsIdentity.mediaSequence,
                segmentIdentity: hlsIdentity.segmentIdentity
            )
            return
        }

        self = .pcm(
            streamID: frame.streamID,
            sequence: frame.sequence,
            startMilliseconds: Self.milliseconds(frame.startSeconds),
            endMilliseconds: Self.milliseconds(frame.endSeconds)
        )
    }

    private static func milliseconds(_ seconds: Double) -> Int64 {
        Int64((seconds * 1_000).rounded())
    }
}

public actor RollingPCMBuffer {
    private let configuration: RollingBufferConfiguration
    private let fileManager: FileManager
    private let runID: UUID
    private var entries: [RollingBufferEntry] = []
    private var retainedFrameKeys: Set<RollingBufferFrameKey> = []
    private var spillRoot: URL?
    private var spillAvailable = false
    private var memoryOnlyFallback = false
    private var spillBytes = 0
    private var evictionCount = 0
    private var cleanupCount = 0
    private var lastMessage = "Rolling buffer idle."

    public init(
        configuration: RollingBufferConfiguration = .appDefault(),
        fileManager: FileManager = .default,
        runID: UUID = UUID()
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.runID = runID
    }

    public func start(streamID: Int64? = nil) {
        entries.removeAll()
        retainedFrameKeys.removeAll(keepingCapacity: true)
        spillBytes = 0
        evictionCount = 0
        cleanupCount = 0
        memoryOnlyFallback = false
        spillAvailable = prepareSpillRoot()
        if spillAvailable {
            lastMessage = "Rolling buffer started with spill storage available."
        } else {
            memoryOnlyFallback = true
            lastMessage = "Rolling buffer started in memory-only fallback; spill storage unavailable."
        }
    }

    public func append(_ frames: [SharedPCMFrame]) async -> RollingBufferSnapshot {
        guard !frames.isEmpty else { return snapshot() }
        if entries.isEmpty && !spillAvailable && !memoryOnlyFallback {
            start(streamID: frames.first?.streamID)
        }

        var retainedFrameCount = 0
        for frame in frames.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            let key = RollingBufferFrameKey(frame)
            guard retainedFrameKeys.insert(key).inserted else { continue }
            entries.append(RollingBufferEntry(frame: frame, storage: .memory(frame.audio)))
            retainedFrameCount += 1
        }

        spillColdFramesIfPossible()
        evictExpiredFrames()
        if memoryOnlyFallback && !spillAvailable {
            lastMessage = "Rolling buffer stored \(retainedFrameCount) frame(s) in memory-only fallback; \(entries.count) retained."
        } else {
            lastMessage = "Rolling buffer stored \(retainedFrameCount) frame(s); \(entries.count) retained."
        }
        if let streamID = frames.first?.streamID {
            return snapshot(streamID: streamID)
        }
        return snapshot()
    }

    public func seek(to seconds: Double) -> RollingBufferSeekResult {
        guard let range = bufferedRange(), range.contains(seconds), !entries.isEmpty else {
            lastMessage = "Requested rewind position is outside the rolling buffer."
            return .unavailable(requestedSeconds: seconds, bufferedRange: bufferedRange())
        }
        let frameIndex = entries.indices.first { index in
            let frame = entries[index].frame
            let isLastFrame = index == entries.index(before: entries.endIndex)
            return seconds >= frame.startSeconds && (seconds < frame.endSeconds || (isLastFrame && seconds <= frame.endSeconds))
        } ?? entries.indices.first(where: { entries[$0].frame.startSeconds >= seconds })
        guard let index = frameIndex else {
            lastMessage = "Requested rewind position is not retained in the rolling buffer."
            return .unavailable(requestedSeconds: seconds, bufferedRange: range)
        }

        do {
            let frame = try materialize(entries[index])
            lastMessage = "Seeked rolling buffer to \(seconds) second(s)."
            return .available(frame)
        } catch {
            lastMessage = "Rolling buffer spill segment unavailable during seek: \(error)."
            return .unavailable(requestedSeconds: seconds, bufferedRange: range)
        }
    }

    public func seek(to seconds: Double, streamID: Int64) -> RollingBufferSeekResult {
        guard let range = bufferedRange(streamID: streamID), range.contains(seconds) else {
            lastMessage = "Requested rewind position is outside the rolling buffer for stream \(streamID)."
            return .unavailable(requestedSeconds: seconds, bufferedRange: bufferedRange(streamID: streamID))
        }
        let matchingIndices = entries.indices.filter { entries[$0].frame.streamID == streamID }
        let frameIndex = matchingIndices.first { index in
            let frame = entries[index].frame
            let isLastFrame = index == matchingIndices.last
            return seconds >= frame.startSeconds && (seconds < frame.endSeconds || (isLastFrame && seconds <= frame.endSeconds))
        } ?? matchingIndices.first(where: { entries[$0].frame.startSeconds >= seconds })
        guard let index = frameIndex else {
            lastMessage = "Requested rewind position is not retained for stream \(streamID)."
            return .unavailable(requestedSeconds: seconds, bufferedRange: range)
        }

        do {
            let frame = try materialize(entries[index])
            lastMessage = "Seeked stream \(streamID) rolling buffer to \(seconds) second(s)."
            return .available(frame)
        } catch {
            lastMessage = "Rolling buffer spill segment unavailable during seek: \(error)."
            return .unavailable(requestedSeconds: seconds, bufferedRange: range)
        }
    }

    public func seekToLive() -> RollingBufferSeekResult {
        guard let latest = entries.last else {
            return .unavailable(requestedSeconds: 0, bufferedRange: nil)
        }
        do {
            let frame = try materialize(latest)
            lastMessage = "Returned playback to live edge."
            return .available(frame)
        } catch {
            lastMessage = "Rolling buffer live edge unavailable: \(error)."
            return .unavailable(requestedSeconds: latest.frame.endSeconds, bufferedRange: bufferedRange())
        }
    }

    public func seekToLive(streamID: Int64) -> RollingBufferSeekResult {
        guard let latest = entries.last(where: { $0.frame.streamID == streamID }) else {
            return .unavailable(requestedSeconds: 0, bufferedRange: bufferedRange(streamID: streamID))
        }
        do {
            let frame = try materialize(latest)
            lastMessage = "Returned stream \(streamID) playback to live edge."
            return .available(frame)
        } catch {
            lastMessage = "Rolling buffer live edge unavailable: \(error)."
            return .unavailable(requestedSeconds: latest.frame.endSeconds, bufferedRange: bufferedRange(streamID: streamID))
        }
    }

    @discardableResult
    public func cleanup() -> RollingBufferSnapshot {
        let urls = entries.compactMap { entry -> URL? in
            if case .spill(let url, _) = entry.storage { return url }
            return nil
        }
        var removed = 0
        for url in urls {
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                // Cleanup should be best-effort and observable, not fatal.
            }
        }
        if let spillRoot {
            try? fileManager.removeItem(at: spillRoot)
        }
        entries.removeAll()
        retainedFrameKeys.removeAll(keepingCapacity: true)
        spillBytes = 0
        spillAvailable = false
        cleanupCount += removed
        lastMessage = "Rolling buffer cleanup removed \(removed) spill segment(s)."
        return snapshot()
    }

    public func snapshot() -> RollingBufferSnapshot {
        let memoryCount = entries.filter { !$0.isSpilled }.count
        let spillCount = entries.count - memoryCount
        return RollingBufferSnapshot(
            streamID: entries.last?.frame.streamID,
            bufferedRange: bufferedRange(),
            liveEdgeSeconds: entries.last?.frame.endSeconds ?? 0,
            frameCount: entries.count,
            memoryFrameCount: memoryCount,
            spillFrameCount: spillCount,
            spillBytes: spillBytes,
            spillAvailable: spillAvailable,
            memoryOnlyFallback: memoryOnlyFallback,
            evictionCount: evictionCount,
            cleanupCount: cleanupCount,
            lastMessage: lastMessage
        )
    }

    public func snapshot(streamID: Int64) -> RollingBufferSnapshot {
        let streamEntries = entries.filter { $0.frame.streamID == streamID }
        let memoryCount = streamEntries.filter { !$0.isSpilled }.count
        let spillCount = streamEntries.count - memoryCount
        let streamSpillBytes = streamEntries.reduce(into: 0) { total, entry in
            if case .spill(_, let bytes) = entry.storage {
                total += bytes
            }
        }
        return RollingBufferSnapshot(
            streamID: streamEntries.last?.frame.streamID,
            bufferedRange: bufferedRange(streamID: streamID),
            liveEdgeSeconds: streamEntries.last?.frame.endSeconds ?? 0,
            frameCount: streamEntries.count,
            memoryFrameCount: memoryCount,
            spillFrameCount: spillCount,
            spillBytes: streamSpillBytes,
            spillAvailable: spillAvailable,
            memoryOnlyFallback: memoryOnlyFallback,
            evictionCount: evictionCount,
            cleanupCount: cleanupCount,
            lastMessage: lastMessage
        )
    }

    private func prepareSpillRoot() -> Bool {
        guard configuration.maximumSpillBytes > 0 else { return false }
        let root: URL
        if let configured = configuration.spillDirectory {
            root = configured
        } else {
            root = fileManager.temporaryDirectory
                .appendingPathComponent("SoundingRollingBuffer", isDirectory: true)
                .appendingPathComponent(runID.uuidString, isDirectory: true)
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            spillRoot = root
            return true
        } catch {
            spillRoot = nil
            return false
        }
    }

    private func spillColdFramesIfPossible() {
        guard spillAvailable, let spillRoot, let liveEdge = entries.last?.frame.endSeconds else { return }
        let hotStart = liveEdge - configuration.hotMemoryDurationSeconds
        for index in entries.indices {
            guard entries[index].frame.endSeconds < hotStart else { continue }
            guard case .memory(let data) = entries[index].storage else { continue }
            let url = spillRoot.appendingPathComponent(
                "frame-\(entries[index].frame.streamID)-\(entries[index].frame.sequence).pcm",
                isDirectory: false
            )
            do {
                try data.write(to: url, options: .atomic)
                entries[index].storage = .spill(url, bytes: data.count)
                spillBytes += data.count
            } catch {
                spillAvailable = false
                memoryOnlyFallback = true
                lastMessage = "Rolling buffer spill write failed; using memory-only fallback."
                return
            }
        }
    }

    private func evictExpiredFrames() {
        guard let liveEdge = entries.last?.frame.endSeconds else { return }
        let earliestAllowed = liveEdge - configuration.targetDurationSeconds
        while let first = entries.first,
            first.frame.endSeconds <= earliestAllowed || spillBytes > configuration.maximumSpillBytes
        {
            removeFirstEntry()
        }
    }

    private func removeFirstEntry() {
        guard !entries.isEmpty else { return }
        let removed = entries.removeFirst()
        retainedFrameKeys.remove(RollingBufferFrameKey(removed.frame))
        if case .spill(let url, let bytes) = removed.storage {
            try? fileManager.removeItem(at: url)
            spillBytes = max(0, spillBytes - bytes)
        }
        evictionCount += 1
    }

    private func bufferedRange() -> RollingBufferRange? {
        guard let first = entries.first, let last = entries.last else { return nil }
        return RollingBufferRange(startSeconds: first.frame.startSeconds, endSeconds: last.frame.endSeconds)
    }

    private func bufferedRange(streamID: Int64) -> RollingBufferRange? {
        var firstFrame: SharedPCMFrame?
        var lastFrame: SharedPCMFrame?
        for entry in entries where entry.frame.streamID == streamID {
            if firstFrame == nil {
                firstFrame = entry.frame
            }
            lastFrame = entry.frame
        }
        guard let firstFrame, let lastFrame else { return nil }
        return RollingBufferRange(startSeconds: firstFrame.startSeconds, endSeconds: lastFrame.endSeconds)
    }

    private func materialize(_ entry: RollingBufferEntry) throws -> SharedPCMFrame {
        var frame = entry.frame
        switch entry.storage {
        case .memory(let data):
            frame.audio = data
            frame.byteCount = data.count
        case .spill(let url, let bytes):
            let data = try Data(contentsOf: url)
            frame.audio = data
            frame.byteCount = bytes
        }
        return frame
    }
}
