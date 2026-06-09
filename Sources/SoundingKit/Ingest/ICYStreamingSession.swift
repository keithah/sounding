import Foundation

/// A long-lived HTTP connection to a live ICY/Icecast stream. The session
/// reads bytes continuously into an in-memory buffer; the decoder pulls
/// fixed-size byte ranges per pass rather than re-opening the connection.
///
/// CDNs for live audio often serve the same buffered window when the same URL
/// is reopened — that is the root cause of "every pass plays the same loop."
/// Holding one connection open across decoder passes gives us a continuous,
/// monotonic byte stream of live audio with embedded ICY metadata.
public actor ICYStreamingSession {
    public struct ReadResult: Sendable {
        public let audio: Data
        public let markers: [AdMarker]
        public let totalAudioBytes: Int
        public let byteRate: Double?
    }

    struct PendingMarker: Equatable, Sendable {
        var marker: AdMarker
        var audioByteOffset: Int?
    }

    private let url: URL
    private let metaInt: Int?
    private let byteRate: Double?
    private var byteIterator: URLSession.AsyncBytes.AsyncIterator?
    private var parser: ICYMetadataParser
    private var pendingAudio: Data
    private var pendingMarkers: [PendingMarker]
    private var totalAudioBytes: Int
    private var bytesUntilNextMetadata: Int
    private var readerTask: Task<Void, Never>?
    private var streamClosed: Bool
    private var streamError: Error?
    private var bytesAvailableContinuations: [UUID: CheckedContinuation<Void, Error>]
    private let diagnosticsLog: AppRuntimeDiagnosticsLog

    /// Hard cap on the pending audio buffer. Prevents unbounded growth if a
    /// consumer stops reading. 4 MB ≈ 5.5 minutes at 96 kbps mp3.
    private static let maxPendingAudioBytes = 4 * 1024 * 1024

    public static func open(url: URL) async throws -> ICYStreamingSession {
        var request = URLRequest(url: url)
        for (field, value) in ICYMetadataParser.requestHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.timeoutInterval = 60
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw AVFoundationAudioDecoderError.sourceOpenFailed(
                "Audio source open failed: \(IngestRedaction.redact(String(describing: error))).")
        }
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw AVFoundationAudioDecoderError.sourceOpenFailed(
                "Audio source open failed: non-success HTTP response.")
        }
        let headers = (response as? HTTPURLResponse)?.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        } ?? [:]
        let metaInt = Self.icyMetaInt(from: headers)
        let byteRate = Self.icyAudioBytesPerSecond(from: headers)
        let session = ICYStreamingSession(
            url: url,
            metaInt: metaInt,
            byteRate: byteRate,
            iterator: bytes.makeAsyncIterator()
        )
        await session.startReader()
        return session
    }

    private init(
        url: URL,
        metaInt: Int?,
        byteRate: Double?,
        iterator: URLSession.AsyncBytes.AsyncIterator
    ) {
        self.url = url
        self.metaInt = metaInt
        self.byteRate = byteRate
        self.byteIterator = iterator
        self.parser = ICYMetadataParser()
        self.pendingAudio = Data()
        self.pendingMarkers = []
        self.totalAudioBytes = 0
        self.bytesUntilNextMetadata = metaInt ?? Int.max
        self.streamClosed = false
        self.streamError = nil
        self.bytesAvailableContinuations = [:]
        self.diagnosticsLog = AppRuntimeDiagnosticsLog()
    }

    /// Reads up to `byteCount` audio bytes from the buffered stream. Waits if
    /// fewer bytes are available, until either the buffer fills or the
    /// connection ends.
    public func read(byteCount: Int) async throws -> ReadResult {
        precondition(byteCount > 0)
        while pendingAudio.count < byteCount {
            try Task.checkCancellation()
            if let error = streamError { throw error }
            if streamClosed { break }
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    bytesAvailableContinuations[waiterID] = cont
                }
            } onCancel: { [weak self] in
                Task { await self?.cancelReadWaiter(waiterID) }
            }
        }
        try Task.checkCancellation()
        let take = min(byteCount, pendingAudio.count)
        let pendingAudioStartOffset = max(0, totalAudioBytes - pendingAudio.count)
        let readEndAudioByteOffset = pendingAudioStartOffset + take
        let audio = Data(pendingAudio.prefix(take))
        pendingAudio.removeFirst(take)
        let splitMarkers = Self.splitPendingMarkersForRead(
            pendingMarkers,
            readEndAudioByteOffset: readEndAudioByteOffset
        )
        pendingMarkers = splitMarkers.remaining
        return ReadResult(
            audio: audio,
            markers: splitMarkers.ready.map(\.marker),
            totalAudioBytes: totalAudioBytes,
            byteRate: byteRate
        )
    }

    static func splitPendingMarkersForRead(
        _ markers: [PendingMarker],
        readEndAudioByteOffset: Int
    ) -> (ready: [PendingMarker], remaining: [PendingMarker]) {
        var ready: [PendingMarker] = []
        var remaining: [PendingMarker] = []
        ready.reserveCapacity(markers.count)
        remaining.reserveCapacity(markers.count)

        for marker in markers {
            guard let audioByteOffset = marker.audioByteOffset else {
                ready.append(marker)
                continue
            }
            if audioByteOffset <= readEndAudioByteOffset {
                ready.append(marker)
            } else {
                remaining.append(marker)
            }
        }
        return (ready, remaining)
    }

    public func close() {
        streamClosed = true
        readerTask?.cancel()
        readerTask = nil
        resumeWaiters()
    }

    private func resumeWaiters() {
        let waiters = bytesAvailableContinuations
        bytesAvailableContinuations = [:]
        for waiter in waiters.values {
            waiter.resume(returning: ())
        }
    }

    private func cancelReadWaiter(_ waiterID: UUID) {
        guard let waiter = bytesAvailableContinuations.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
    }

    private func startReader() {
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    private func readLoop() async {
        // The iterator was captured at open() time. We pull bytes one at a time
        // and partition into audio vs. ICY metadata blocks. URLSession's async
        // byte stream itself buffers internally; this loop is cheap.
        var iterator = byteIterator
        defer { byteIterator = iterator }
        while !Task.isCancelled, !streamClosed {
            // Backpressure: if our pending buffer is full, wait until a reader
            // drains some bytes before continuing to read from the network.
            if pendingAudio.count >= Self.maxPendingAudioBytes {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            do {
                if let metaInt, bytesUntilNextMetadata == 0 {
                    try await readMetadataBlock(iterator: &iterator, metaInt: metaInt)
                } else {
                    try await readAudioBytes(iterator: &iterator)
                }
            } catch {
                streamError = error
                streamClosed = true
                resumeWaiters()
                return
            }
        }
        streamClosed = true
        resumeWaiters()
    }

    private func readAudioBytes(iterator: inout URLSession.AsyncBytes.AsyncIterator?) async throws {
        guard iterator != nil else {
            streamClosed = true
            return
        }
        // Read in batches to amortize iterator overhead. Cap by metaInt so we
        // know when to flip to metadata parsing.
        let maxBatch = min(4096, bytesUntilNextMetadata == Int.max ? 4096 : bytesUntilNextMetadata)
        var batch = Data()
        batch.reserveCapacity(maxBatch)
        for _ in 0..<maxBatch {
            guard let byte = try await iterator?.next() else {
                streamClosed = true
                break
            }
            batch.append(byte)
        }
        if batch.isEmpty { return }
        pendingAudio.append(batch)
        totalAudioBytes += batch.count
        if bytesUntilNextMetadata != Int.max {
            bytesUntilNextMetadata -= batch.count
        }
        resumeWaiters()
    }

    private func readMetadataBlock(
        iterator: inout URLSession.AsyncBytes.AsyncIterator?,
        metaInt: Int
    ) async throws {
        guard iterator != nil else {
            streamClosed = true
            return
        }
        guard let lengthByte = try await iterator?.next() else {
            streamClosed = true
            return
        }
        bytesUntilNextMetadata = metaInt
        let metadataLength = Int(lengthByte) * 16
        guard metadataLength > 0 else { return }
        var metadata = Data()
        metadata.reserveCapacity(metadataLength)
        for _ in 0..<metadataLength {
            guard let byte = try await iterator?.next() else {
                streamClosed = true
                return
            }
            metadata.append(byte)
        }
        let fields = ICYMetadataParser.parseFields(from: metadata)
        recordMetadataBlock(fields)
        guard var marker = parser.marker(fromMetadataBlock: metadata) else { return }
        if let byteRate, byteRate > 0 {
            marker.pts = Double(totalAudioBytes) / byteRate
        }
        marker.segment = "icy-\(pendingMarkers.count)"
        pendingMarkers.append(
            PendingMarker(
                marker: marker,
                audioByteOffset: byteRate.map { _ in totalAudioBytes }
            )
        )
    }

    private func recordMetadataBlock(_ fields: [String: String]) {
        guard !fields.isEmpty else { return }
        var diagnosticFields = fields.reduce(into: [String: String]()) { partial, pair in
            partial["icy.\(pair.key)"] = Self.boundedDiagnosticValue(pair.value)
        }
        diagnosticFields["fieldNames"] = fields.keys.sorted().joined(separator: ",")
        diagnosticFields["containsAD"] = Self.metadataContainsAD(fields) ? "true" : "false"
        diagnosticsLog.recordEvent(
            "icy.metadata.block",
            source: url.absoluteString,
            phase: "icy.metadata",
            message: Self.metadataContainsAD(fields) ? "ICY metadata block contains AD signal." : "ICY metadata block received.",
            fields: diagnosticFields
        )
    }

    private static func metadataContainsAD(_ fields: [String: String]) -> Bool {
        fields.contains { key, value in
            key.range(of: "AD", options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || value.range(of: "AD", options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func boundedDiagnosticValue(_ value: String) -> String {
        let redacted = IngestRedaction.redact(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard redacted.count > 240 else { return redacted }
        return String(redacted.prefix(240)) + "..."
    }

    private static func icyMetaInt(from headers: [String: String]) -> Int? {
        guard let rawValue = caseInsensitiveValue(for: "icy-metaint", in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else { return nil }
        return Int(rawValue)
    }

    private static func icyAudioBytesPerSecond(from headers: [String: String]) -> Double? {
        guard let rawValue = caseInsensitiveValue(for: "icy-br", in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let kilobitsPerSecond = Double(rawValue),
            kilobitsPerSecond > 0
        else { return nil }
        return kilobitsPerSecond * 1_000 / 8
    }

    private static func caseInsensitiveValue(for key: String, in headers: [String: String]) -> String? {
        headers.first { candidate, _ in
            candidate.caseInsensitiveCompare(key) == .orderedSame
        }?.value
    }
}
