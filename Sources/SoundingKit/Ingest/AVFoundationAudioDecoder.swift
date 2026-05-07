import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Native SoundingKit decoder that validates media with AVFoundation and emits bounded chunks
/// for the ingest pipeline. HLS manifests also contribute manifest-level SCTE-35 markers so
/// marker extraction failures remain isolated from transcription persistence.
public struct AVFoundationAudioDecoder: AudioDecoding {
    public var chunkDurationSeconds: Double
    public var segmentLoader: any HLSSegmentLoading
    public var segmentID3Extractor: any HLSSegmentID3Extracting
    public var segmentSCTE35Extractor: any HLSSegmentSCTE35Extracting
    public var now: @Sendable () -> String

    public init(
        chunkDurationSeconds: Double = 10,
        segmentLoader: any HLSSegmentLoading = HLSSegmentLoader(),
        segmentID3Extractor: any HLSSegmentID3Extracting = HLSSegmentID3Extractor(),
        segmentSCTE35Extractor: any HLSSegmentSCTE35Extracting = HLSSegmentSCTE35Extractor(),
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.chunkDurationSeconds = max(chunkDurationSeconds, 0.001)
        self.segmentLoader = segmentLoader
        self.segmentID3Extractor = segmentID3Extractor
        self.segmentSCTE35Extractor = segmentSCTE35Extractor
        self.now = now
    }

    public func decodedChunks(for request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        switch request.streamType {
        case .hls:
            return try await decodeHLS(request)
        case .icecast, .icy, .mpegts, .udp, .auto:
            return try await decodeAsset(request)
        }
    }

    private struct ResolvedHLSManifest: Sendable {
        var text: String
        var source: String
    }

    private func decodeHLS(_ request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        let resolvedManifest = try await loadMediaManifest(from: request.source)
        let segments = HLSManifestParser.parseMediaSegments(resolvedManifest.text)
        guard !segments.isEmpty else {
            throw AVFoundationAudioDecoderError.unsupportedMedia("HLS manifest has no media segments.")
        }

        var chunks: [DecodedAudioChunk] = []
        let playableSegments = playableHLSSegments(
            segments,
            minimumMediaSequence: request.minimumHLSMediaSequence
        )
        let limitedSegments = Array(playableSegments.prefix(max(0, request.maxChunks ?? playableSegments.count)))
        var timelineCursor = max(0, request.hlsTimelineStartSeconds ?? 0)
        for (index, segment) in limitedSegments.enumerated() {
            var markers = try markersForSegment(segment, source: resolvedManifest.source)
            let data: Data
            do {
                data = try await segmentLoader.loadSegment(uri: segment.uri, relativeTo: resolvedManifest.source)
            } catch {
                throw AVFoundationAudioDecoderError.decodeFailed("HLS segment decode failed: \(sanitized(error)).")
            }

            let duration = Double(segment.duration ?? "") ?? chunkDurationSeconds
            let start = timelineCursor
            let end = start + max(duration, 0.001)
            timelineCursor = end
            let segmentDescription = resolvedSegmentDescription(segment.uri, relativeTo: resolvedManifest.source)
            markers.append(
                contentsOf: markersForSegmentBytes(
                    data,
                    mediaSequence: segment.mediaSequence,
                    segmentURI: segmentDescription
                )
            )
            let temporarySegmentURL = try writeTemporarySegment(data, sourceDescription: segmentDescription)
            defer { try? FileManager.default.removeItem(at: temporarySegmentURL) }
            let decoded: (audio: Data, format: DecodedAudioFormat)
            do {
                decoded = try decodeLinearPCM(from: temporarySegmentURL, fallbackDuration: end - start)
            } catch {
                decoded = (data, .containerBytes)
            }
            chunks.append(DecodedAudioChunk(
                sequence: index,
                segmentURI: segmentDescription,
                hlsIdentity: HLSDecodedAudioChunkIdentity(
                    mediaSequence: Int(segment.mediaSequence) ?? 0,
                    segmentIdentity: segmentDescription,
                    manifestPosition: index
                ),
                audio: decoded.audio,
                audioFormat: decoded.format,
                byteCount: decoded.audio.count,
                startSeconds: start,
                endSeconds: end,
                startedAt: now(),
                endedAt: now(),
                adMarkers: markers
            ))
        }
        return applyDurationBound(chunks, durationSeconds: request.durationSeconds)
    }

    private func playableHLSSegments(
        _ segments: [HLSManifestMediaSegment],
        minimumMediaSequence: Int?
    ) -> [HLSManifestMediaSegment] {
        guard let minimumMediaSequence else { return segments }
        let segmentsAtOrAboveMinimum = segments.filter { segment in
            (Int(segment.mediaSequence) ?? 0) >= minimumMediaSequence
        }
        if !segmentsAtOrAboveMinimum.isEmpty {
            return segmentsAtOrAboveMinimum
        }

        let mediaSequences = segments.compactMap { Int($0.mediaSequence) }
        guard let latestPlaylistSequence = mediaSequences.max() else { return segments }
        if latestPlaylistSequence < minimumMediaSequence {
            return segments
        }
        return []
    }

    private func decodeAsset(_ request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
#if canImport(AVFoundation)
        let originalURL = try mediaURL(from: request.source)
        let url: URL
        var temporaryURL: URL?
        if originalURL.isFileURL {
            url = originalURL
        } else {
            let downloaded = try await downloadRemoteAudioSample(from: originalURL)
            url = downloaded
            temporaryURL = downloaded
        }
        defer {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AVFoundationAudioDecoderError.sourceOpenFailed("Audio source open failed: \(sanitized(error)).")
        }
        guard !tracks.isEmpty else {
            throw AVFoundationAudioDecoderError.unsupportedMedia("Audio source has no audio tracks.")
        }

        let loadedDuration = (try? await asset.load(.duration).seconds) ?? 0
        let duration = loadedDuration.isFinite && loadedDuration > 0 ? loadedDuration : max(request.durationSeconds ?? chunkDurationSeconds, chunkDurationSeconds)

        let decoded = try decodeLinearPCM(from: url, fallbackDuration: duration)
        let data = decoded.audio

        let effectiveDuration = min(duration, request.durationSeconds ?? duration)
        let chunkCount = max(1, Int(ceil(effectiveDuration / chunkDurationSeconds)))
        let boundedCount = min(chunkCount, max(0, request.maxChunks ?? chunkCount))
        guard boundedCount > 0 else { return [] }

        return (0..<boundedCount).map { index in
            let start = Double(index) * chunkDurationSeconds
            let end = min(start + chunkDurationSeconds, effectiveDuration)
            return DecodedAudioChunk(
                sequence: index,
                segmentURI: IngestRedaction.sourceDescription(request.source),
                audio: data,
                audioFormat: decoded.format,
                byteCount: data.count,
                startSeconds: start,
                endSeconds: max(end, start),
                startedAt: now(),
                endedAt: now(),
                adMarkers: []
            )
        }
#else
        throw AVFoundationAudioDecoderError.unsupportedMedia("AVFoundation is unavailable on this platform.")
#endif
    }

    private func loadMediaManifest(from source: String) async throws -> ResolvedHLSManifest {
        try await loadMediaManifest(from: source, visited: [])
    }

    private func loadMediaManifest(from source: String, visited: Set<String>) async throws -> ResolvedHLSManifest {
        guard visited.count < 4 else {
            throw AVFoundationAudioDecoderError.unsupportedMedia("HLS manifest resolution exceeded variant playlist depth.")
        }
        let manifest = try await loadManifestText(from: source)
        let variants = HLSManifestParser.parseVariantPlaylists(manifest)
        guard let selected = selectVariant(from: variants) else {
            return ResolvedHLSManifest(text: manifest, source: source)
        }
        let nextSource = try resolveHLSURI(selected.uri, relativeTo: source)
        guard !visited.contains(nextSource) else {
            throw AVFoundationAudioDecoderError.unsupportedMedia("HLS manifest resolution encountered a variant playlist loop.")
        }
        var nextVisited = visited
        nextVisited.insert(source)
        return try await loadMediaManifest(from: nextSource, visited: nextVisited)
    }

    private func selectVariant(from variants: [HLSManifestVariantPlaylist]) -> HLSManifestVariantPlaylist? {
        variants.sorted { lhs, rhs in
            (lhs.bandwidth ?? Int.max) < (rhs.bandwidth ?? Int.max)
        }.first
    }

    private func resolveHLSURI(_ uri: String, relativeTo source: String) throws -> String {
        if let absolute = URL(string: uri), absolute.scheme != nil {
            return absolute.absoluteString
        }
        if let base = URL(string: source), base.scheme != nil,
           let resolved = URL(string: uri, relativeTo: base.deletingLastPathComponent())?.absoluteURL {
            return resolved.absoluteString
        }
        let base = URL(fileURLWithPath: source).deletingLastPathComponent()
        let pathOnly = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? uri
        return base.appendingPathComponent(pathOnly).path
    }

    private func loadManifestText(from source: String) async throws -> String {
        let data: Data
        do {
            if let url = URL(string: source), url.scheme == "http" || url.scheme == "https" {
                let (remoteData, response) = try await HLSURLSessionDataLoader.data(from: url, using: .shared)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AVFoundationAudioDecoderError.sourceOpenFailed("HLS manifest open failed: missing HTTP response.")
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                    throw AVFoundationAudioDecoderError.sourceOpenFailed(
                        "HLS manifest open failed: HTTP \(httpResponse.statusCode), content-type \(contentType)."
                    )
                }
                data = remoteData
            } else if let url = URL(string: source), url.scheme != nil {
                data = try Data(contentsOf: url)
            } else {
                data = try Data(contentsOf: URL(fileURLWithPath: source))
            }
        } catch let error as AVFoundationAudioDecoderError {
            throw error
        } catch {
            throw AVFoundationAudioDecoderError.sourceOpenFailed("HLS manifest open failed: \(sanitized(error)).")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw AVFoundationAudioDecoderError.sourceOpenFailed("HLS manifest open failed: manifest bytes are not UTF-8.")
        }
        return text
    }

    private func markersForSegment(_ segment: HLSManifestMediaSegment, source: String) throws -> [AdMarker] {
        do {
            return try HLSManifestMarkerExtractor.extractMarkers(from: [segment], source: source)
        } catch {
            throw AVFoundationAudioDecoderError.decodeFailed("HLS marker extraction failed: \(sanitized(error)).")
        }
    }

    private func markersForSegmentBytes(
        _ data: Data,
        mediaSequence: String,
        segmentURI: String
    ) -> [AdMarker] {
        let id3Markers = (try? segmentID3Extractor.extractMarkers(
            from: data,
            mediaSequence: mediaSequence,
            segmentURI: segmentURI
        )) ?? []
        let scte35Markers = (try? segmentSCTE35Extractor.extractMarkers(
            from: data,
            mediaSequence: mediaSequence,
            segmentURI: segmentURI
        )) ?? []
        return id3Markers + scte35Markers
    }

    private func applyDurationBound(_ chunks: [DecodedAudioChunk], durationSeconds: Double?) -> [DecodedAudioChunk] {
        guard let durationSeconds else { return chunks }
        return chunks.filter { $0.startSeconds < durationSeconds }
    }

    private func mediaURL(from source: String) throws -> URL {
        if let url = URL(string: source), url.scheme != nil {
            guard url.isFileURL else {
                return url
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AVFoundationAudioDecoderError.sourceOpenFailed("Audio source open failed: file does not exist.")
            }
            return url
        }

        guard FileManager.default.fileExists(atPath: source) else {
            throw AVFoundationAudioDecoderError.sourceOpenFailed("Audio source open failed: file does not exist.")
        }
        return URL(fileURLWithPath: source)
    }

#if canImport(FoundationNetworking)
#endif

    private func downloadRemoteAudioSample(from url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-2097151", forHTTPHeaderField: "Range")
        request.timeoutInterval = 12

        let data: Data
        let response: URLResponse
        do {
            (response, data) = try await readRemoteAudioPrefix(for: request, byteLimit: 2_097_152)
        } catch {
            throw AVFoundationAudioDecoderError.sourceOpenFailed("Audio source open failed: \(sanitized(error)).")
        }
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw AVFoundationAudioDecoderError.sourceOpenFailed("Audio source open failed: non-success HTTP response.")
        }
        guard !data.isEmpty else {
            throw AVFoundationAudioDecoderError.unsupportedMedia("Audio source produced no bytes.")
        }

        let fileExtension = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-remote-audio-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: temporaryURL, options: .atomic)
            return temporaryURL
        } catch {
            throw AVFoundationAudioDecoderError.decodeFailed("Audio decode failed: temporary audio staging failed.")
        }
    }

    private func readRemoteAudioPrefix(for request: URLRequest, byteLimit: Int) async throws -> (URLResponse, Data) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        var data = Data()
        data.reserveCapacity(min(byteLimit, 256 * 1024))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= byteLimit || data.count >= 256 * 1024 {
                break
            }
        }
        return (response, data)
    }

    private func resolvedSegmentDescription(_ uri: String, relativeTo manifestSource: String) -> String {
        if let absoluteURL = URL(string: uri), absoluteURL.scheme != nil {
            return IngestRedaction.sourceDescription(absoluteURL.absoluteString)
        }
        if let manifestURL = URL(string: manifestSource), manifestURL.scheme != nil,
           let resolved = URL(string: uri, relativeTo: manifestURL.deletingLastPathComponent())?.absoluteString {
            return IngestRedaction.sourceDescription(resolved)
        }
        let manifestURL = URL(fileURLWithPath: manifestSource)
        return IngestRedaction.sourceDescription(manifestURL.deletingLastPathComponent().appendingPathComponent(uri).path)
    }

    private func writeTemporarySegment(_ data: Data, sourceDescription: String) throws -> URL {
        let extensionHint = URL(string: sourceDescription)?.pathExtension
        let fileExtension = (extensionHint?.isEmpty == false ? extensionHint : "aac") ?? "aac"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-segment-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw AVFoundationAudioDecoderError.decodeFailed("HLS segment decode failed: temporary segment staging failed.")
        }
    }

#if canImport(AVFoundation)
    private func decodeLinearPCM(from url: URL, fallbackDuration: Double) throws -> (audio: Data, format: DecodedAudioFormat) {
        let asset = AVURLAsset(url: url)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AVFoundationAudioDecoderError.decodeFailed("Audio decode failed: \(sanitized(error)).")
        }
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AVFoundationAudioDecoderError.unsupportedMedia("Audio source has no audio tracks.")
        }

        let sampleRate = 44_100.0
        let channelCount = 2
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AVFoundationAudioDecoderError.unsupportedMedia("Audio source cannot be converted to PCM.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AVFoundationAudioDecoderError.decodeFailed("Audio decode failed: reader could not start.")
        }

        var pcm = Data()
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            var chunk = Data(count: length)
            let status = chunk.withUnsafeMutableBytes { destination -> OSStatus in
                guard let baseAddress = destination.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
            }
            guard status == kCMBlockBufferNoErr else {
                throw AVFoundationAudioDecoderError.decodeFailed("Audio decode failed: PCM copy failed.")
            }
            pcm.append(chunk)
        }

        guard reader.status == .completed else {
            let message = reader.error.map { sanitized($0) } ?? "reader did not complete"
            throw AVFoundationAudioDecoderError.decodeFailed("Audio decode failed: \(message).")
        }
        guard !pcm.isEmpty else {
            throw AVFoundationAudioDecoderError.unsupportedMedia("Audio source produced no PCM samples.")
        }

        return (
            pcm,
            .linearPCM(sampleRate: sampleRate, channelCount: channelCount, bitDepth: 16)
        )
    }
#endif

    private func sanitized(_ error: Error) -> String {
        IngestRedaction.redact(String(describing: error))
    }
}

public enum AVFoundationAudioDecoderError: Error, Equatable, CustomStringConvertible, AudioDecodingDiagnosticError, Sendable {
    case sourceOpenFailed(String)
    case decodeFailed(String)
    case unsupportedMedia(String)

    public var ingestDiagnosticPhase: IngestDiagnosticPhase {
        switch self {
        case .sourceOpenFailed:
            return .sourceOpen
        case .decodeFailed, .unsupportedMedia:
            return .decode
        }
    }

    public var ingestDiagnosticReason: String {
        switch self {
        case .sourceOpenFailed:
            return "source-open-failed"
        case .decodeFailed:
            return "decode-failed"
        case .unsupportedMedia:
            return "unsupported-media"
        }
    }

    public var description: String {
        switch self {
        case let .sourceOpenFailed(message), let .decodeFailed(message), let .unsupportedMedia(message):
            return IngestRedaction.redact(message)
        }
    }
}
