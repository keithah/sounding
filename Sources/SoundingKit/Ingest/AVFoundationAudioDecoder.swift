import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Native SoundingKit decoder that validates media with AVFoundation and emits bounded chunks
/// for the ingest pipeline. HLS manifests also contribute manifest-level SCTE-35 markers so
/// marker extraction failures remain isolated from transcription persistence.
public final class AVFoundationAudioDecoder: AudioDecoding, @unchecked Sendable {
    public var chunkDurationSeconds: Double
    public var segmentLoader: any HLSSegmentLoading
    public var segmentID3Extractor: any HLSSegmentID3Extracting
    public var segmentSCTE35Extractor: any HLSSegmentSCTE35Extracting
    public var now: @Sendable () -> String

    private let icySessionLock = NSLock()
    private var icySessions: [String: ICYStreamingSession] = [:]

    public init(
        chunkDurationSeconds: Double = 10,
        segmentLoader: any HLSSegmentLoading = HLSSegmentLoader(),
        segmentID3Extractor: any HLSSegmentID3Extracting = HLSSegmentID3Extractor(),
        segmentSCTE35Extractor: any HLSSegmentSCTE35Extracting = HLSSegmentSCTE35Extractor(),
        now: @escaping @Sendable () -> String = { SoundingTimestampClock.timestamp() }
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
        case .icecast, .icy:
            // Local file fixtures fall through to the AVURLAsset path; only
            // live HTTP(S) sources benefit from the continuous streaming
            // session.
            if let url = try? mediaURL(from: request.source), !url.isFileURL {
                return try await decodeICYContinuous(request)
            }
            return try await decodeAsset(request)
        case .mpegts, .udp, .auto:
            return try await decodeAsset(request)
        }
    }

    private func icySession(for key: String) -> ICYStreamingSession? {
        icySessionLock.lock()
        defer { icySessionLock.unlock() }
        return icySessions[key]
    }

    private func storeICYSession(_ session: ICYStreamingSession, for key: String) {
        icySessionLock.lock()
        icySessions[key] = session
        icySessionLock.unlock()
    }

    private func dropICYSession(for key: String) -> ICYStreamingSession? {
        icySessionLock.lock()
        defer { icySessionLock.unlock() }
        return icySessions.removeValue(forKey: key)
    }

    private func invalidateICYSession(for key: String) async {
        if let droppedSession = dropICYSession(for: key) {
            await droppedSession.close()
        }
    }

    private struct ResolvedHLSManifest: Sendable {
        var text: String
        var source: String
    }

    private struct RemoteAudioSample: Sendable {
        var url: URL
        var markers: [AdMarker]
    }

    private struct ICYAudioExtraction: Sendable {
        var audio: Data
        var markers: [AdMarker]
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
            minimumMediaSequence: request.minimumHLSMediaSequence,
            excludedSegmentKeys: request.excludedHLSSegmentKeys,
            manifestSource: resolvedManifest.source
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
        minimumMediaSequence: Int?,
        excludedSegmentKeys: Set<HLSDecodedAudioSegmentKey>,
        manifestSource: String
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
            guard !excludedSegmentKeys.isEmpty else { return segments }
            return segments.filter { segment in
                let key = HLSDecodedAudioSegmentKey(
                    mediaSequence: Int(segment.mediaSequence) ?? 0,
                    segmentIdentity: resolvedSegmentDescription(segment.uri, relativeTo: manifestSource)
                )
                return !excludedSegmentKeys.contains(key)
            }
        }
        return []
    }

    private func decodeAsset(_ request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
#if canImport(AVFoundation)
        let originalURL = try mediaURL(from: request.source)
        let url: URL
        var temporaryURL: URL?
        var remoteMarkers: [AdMarker] = []
        if originalURL.isFileURL {
            url = originalURL
        } else {
            let downloaded = try await downloadRemoteAudioSample(from: originalURL, streamType: request.streamType)
            url = downloaded.url
            temporaryURL = downloaded.url
            remoteMarkers = downloaded.markers
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

        let decodedDuration = pcmDurationSeconds(data, format: decoded.format) ?? duration
        let effectiveDuration = min(decodedDuration, request.durationSeconds ?? decodedDuration)
        let chunkCount = max(1, Int(ceil(effectiveDuration / chunkDurationSeconds)))
        let boundedCount = min(chunkCount, max(0, request.maxChunks ?? chunkCount))
        guard boundedCount > 0 else { return [] }

        return (0..<boundedCount).map { index in
            let start = Double(index) * chunkDurationSeconds
            let end = min(start + chunkDurationSeconds, effectiveDuration)
            let chunkAudio = pcmSlice(data, format: decoded.format, startSeconds: start, endSeconds: end)
            let markers = markersOverlapping(remoteMarkers, startSeconds: start, endSeconds: max(end, start))
            return DecodedAudioChunk(
                sequence: index,
                segmentURI: IngestRedaction.sourceDescription(request.source),
                audio: chunkAudio,
                audioFormat: decoded.format,
                byteCount: chunkAudio.count,
                startSeconds: start,
                endSeconds: max(end, start),
                startedAt: now(),
                endedAt: now(),
                adMarkers: markers
            )
        }
#else
        throw AVFoundationAudioDecoderError.unsupportedMedia("AVFoundation is unavailable on this platform.")
#endif
    }

    private func decodeICYContinuous(_ request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
#if canImport(AVFoundation)
        let url = try mediaURL(from: request.source)
        // Keep one HTTP connection open per stream URL across decoder passes so
        // each pass reads the next bytes from the live stream instead of
        // re-opening (which makes some CDNs replay the same buffer).
        let session: ICYStreamingSession
        if let existing = icySession(for: request.source) {
            session = existing
        } else {
            do {
                session = try await ICYStreamingSession.open(url: url)
            } catch {
                throw error
            }
            storeICYSession(session, for: request.source)
        }

        // Target one chunk of MP3 bytes per pass. With chunkDurationSeconds=10,
        // aim for ~10s of audio. If the byte rate is unknown, fall back to
        // 128 kbps (16 KB/s).
        let targetByteCount: Int
        let byteRate: Double
        let readResult: ICYStreamingSession.ReadResult
        do {
            // Probe the current byte rate from the session (it may be nil until
            // the first read returns headers).
            let probe = try await session.read(byteCount: 4096)
            byteRate = probe.byteRate ?? 16_000
            targetByteCount = max(0, Int(byteRate * chunkDurationSeconds) - probe.audio.count)
            let remainder = targetByteCount > 0
                ? try await session.read(byteCount: targetByteCount)
                : ICYStreamingSession.ReadResult(
                    audio: Data(),
                    markers: [],
                    totalAudioBytes: probe.totalAudioBytes,
                    byteRate: probe.byteRate
                )
            var combined = probe.audio
            combined.append(remainder.audio)
            readResult = ICYStreamingSession.ReadResult(
                audio: combined,
                markers: probe.markers + remainder.markers,
                totalAudioBytes: remainder.totalAudioBytes,
                byteRate: remainder.byteRate
            )
        } catch {
            // Drop the session so the next call reopens a fresh connection.
            await invalidateICYSession(for: request.source)
            throw error
        }

        if readResult.audio.isEmpty {
            await invalidateICYSession(for: request.source)
            throw AVFoundationAudioDecoderError.sourceOpenFailed(
                "Audio source open failed: live ICY stream ended before audio bytes were available.")
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-icy-\(UUID().uuidString)")
            .appendingPathExtension("mp3")
        do {
            try readResult.audio.write(to: temporaryURL, options: .atomic)
        } catch {
            await invalidateICYSession(for: request.source)
            throw AVFoundationAudioDecoderError.decodeFailed("Audio decode failed: temporary audio staging failed.")
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let fallbackDuration = byteRate > 0 ? Double(readResult.audio.count) / byteRate : chunkDurationSeconds
        let timelineStartSeconds = Self.icyTimelineStartSeconds(
            totalAudioBytesAfterRead: readResult.totalAudioBytes,
            readAudioByteCount: readResult.audio.count,
            byteRate: byteRate
        )
        let decoded: (audio: Data, format: DecodedAudioFormat)
        do {
            decoded = try decodeLinearPCM(from: temporaryURL, fallbackDuration: fallbackDuration)
        } catch {
            await invalidateICYSession(for: request.source)
            throw AVFoundationAudioDecoderError.decodeFailed("Audio decode failed: \(sanitized(error)).")
        }
        let data = decoded.audio
        let decodedDuration = pcmDurationSeconds(data, format: decoded.format) ?? fallbackDuration
        let effectiveDuration = min(decodedDuration, request.durationSeconds ?? decodedDuration)
        let chunkCount = max(1, Int(ceil(effectiveDuration / chunkDurationSeconds)))
        let boundedCount = min(chunkCount, max(0, request.maxChunks ?? chunkCount))
        guard boundedCount > 0 else { return [] }

        return (0..<boundedCount).map { index in
            let localStart = Double(index) * chunkDurationSeconds
            let localEnd = min(localStart + chunkDurationSeconds, effectiveDuration)
            let start = timelineStartSeconds + localStart
            let end = timelineStartSeconds + localEnd
            let chunkAudio = pcmSlice(data, format: decoded.format, startSeconds: localStart, endSeconds: localEnd)
            let markers = markersOverlapping(readResult.markers, startSeconds: start, endSeconds: max(end, start))
            return DecodedAudioChunk(
                sequence: index,
                segmentURI: IngestRedaction.sourceDescription(request.source),
                audio: chunkAudio,
                audioFormat: decoded.format,
                byteCount: chunkAudio.count,
                startSeconds: start,
                endSeconds: max(end, start),
                startedAt: now(),
                endedAt: now(),
                adMarkers: markers
            )
        }
#else
        throw AVFoundationAudioDecoderError.unsupportedMedia("AVFoundation is unavailable on this platform.")
#endif
    }

    static func icyTimelineStartSeconds(
        totalAudioBytesAfterRead: Int,
        readAudioByteCount: Int,
        byteRate: Double
    ) -> Double {
        guard byteRate > 0 else { return 0 }
        let startByteOffset = max(0, totalAudioBytesAfterRead - readAudioByteCount)
        return Double(startByteOffset) / byteRate
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

    private func downloadRemoteAudioSample(from url: URL, streamType: StreamType) async throws -> RemoteAudioSample {
        var request = URLRequest(url: url)
        // For live ICY/Icecast streams, don't send a Range header: some CDNs
        // honor it and return cached bytes 0-N, which makes every pass play the
        // same audio loop. Without Range, the server streams from "now" and we
        // read until our byte target is reached.
        if streamType != .icecast && streamType != .icy {
            request.setValue("bytes=0-2097151", forHTTPHeaderField: "Range")
        }
        if streamType == .icecast || streamType == .icy {
            for (field, value) in ICYMetadataParser.requestHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        // The idle timeout has to cover the time between bytes from a live
        // stream. 30s covers slow startup and DNS-renegotiation hiccups; the
        // request itself terminates as soon as we have enough audio bytes.
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (response, data) = try await readRemoteAudioPrefix(
                for: request,
                byteLimit: 2_097_152,
                streamType: streamType
            )
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
        let headers = (response as? HTTPURLResponse)?.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        } ?? [:]
        let extraction = extractICYAudioIfPresent(data, headers: headers)

        let fileExtension = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sounding-remote-audio-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try extraction.audio.write(to: temporaryURL, options: .atomic)
            return RemoteAudioSample(url: temporaryURL, markers: extraction.markers)
        } catch {
            throw AVFoundationAudioDecoderError.decodeFailed("Audio decode failed: temporary audio staging failed.")
        }
    }

    private func extractICYAudioIfPresent(_ data: Data, headers: [String: String]) -> ICYAudioExtraction {
        guard let metaInt = icyMetaInt(from: headers), metaInt > 0 else {
            return ICYAudioExtraction(audio: data, markers: [])
        }
        var parser = ICYMetadataParser()
        var strippedAudio = Data()
        strippedAudio.reserveCapacity(data.count)
        var markers: [AdMarker] = []
        let byteRate = icyAudioBytesPerSecond(from: headers)
        var offset = data.startIndex

        while offset < data.endIndex {
            let audioEnd = min(offset + metaInt, data.endIndex)
            let audioChunk = data[offset..<audioEnd]
            strippedAudio.append(audioChunk)
            offset = audioEnd
            guard offset < data.endIndex else {
                break
            }

            let metadataLength = Int(data[offset]) * 16
            offset = data.index(after: offset)
            guard metadataLength > 0 else { continue }
            let metadataEnd = min(offset + metadataLength, data.endIndex)
            let metadata = Data(data[offset..<metadataEnd])
            offset = metadataEnd
            guard metadata.count == metadataLength,
                  var marker = parser.marker(fromMetadataBlock: metadata) else { continue }
            if let byteRate, byteRate > 0 {
                marker.pts = Double(strippedAudio.count) / byteRate
            }
            marker.segment = "icy-\(markers.count)"
            enrichICYProgramFields(&marker)
            markers.append(marker)
        }

        guard !strippedAudio.isEmpty else {
            return ICYAudioExtraction(audio: data, markers: markers)
        }
        return ICYAudioExtraction(audio: strippedAudio, markers: markers)
    }

    private func enrichICYProgramFields(_ marker: inout AdMarker) {
        guard case let .string(rawStreamTitle)? = marker.fields["StreamTitle"] else { return }
        let streamTitle = rawStreamTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streamTitle.isEmpty else { return }
        for separator in [" - ", " – ", " — "] {
            let parts = streamTitle.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }
            let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = parts.dropFirst().joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else { continue }
            marker.fields["Artist"] = marker.fields["Artist"] ?? .string(artist)
            marker.fields["Title"] = marker.fields["Title"] ?? .string(title)
            return
        }
        if marker.fields["Title"] == nil {
            marker.fields["Title"] = .string(streamTitle)
        }
    }

    private func icyMetaInt(from headers: [String: String]) -> Int? {
        guard let rawValue = caseInsensitiveValue(for: "icy-metaint", in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else { return nil }
        return Int(rawValue)
    }

    private func icyAudioBytesPerSecond(from headers: [String: String]) -> Double? {
        guard let rawValue = caseInsensitiveValue(for: "icy-br", in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let kilobitsPerSecond = Double(rawValue),
            kilobitsPerSecond > 0
        else { return nil }
        return kilobitsPerSecond * 1_000 / 8
    }

    private func caseInsensitiveValue(for key: String, in headers: [String: String]) -> String? {
        headers.first { candidate, _ in
            candidate.caseInsensitiveCompare(key) == .orderedSame
        }?.value
    }

    private func markersOverlapping(_ markers: [AdMarker], startSeconds: Double, endSeconds: Double) -> [AdMarker] {
        markers.filter { marker in
            guard let pts = marker.pts else { return startSeconds == 0 }
            if startSeconds == endSeconds {
                return pts == startSeconds
            }
            return pts >= startSeconds && pts < endSeconds
        }
    }

    private func pcmDurationSeconds(_ data: Data, format: DecodedAudioFormat) -> Double? {
        guard let bytesPerSecond = pcmBytesPerSecond(format), bytesPerSecond > 0 else { return nil }
        return Double(data.count) / bytesPerSecond
    }

    private func pcmSlice(
        _ data: Data,
        format: DecodedAudioFormat,
        startSeconds: Double,
        endSeconds: Double
    ) -> Data {
        guard let bytesPerSecond = pcmBytesPerSecond(format),
              let blockAlign = pcmBlockAlign(format),
              bytesPerSecond > 0,
              blockAlign > 0 else {
            return data
        }
        let lower = alignedPCMOffset(Double.maximum(0, startSeconds) * bytesPerSecond, blockAlign: blockAlign)
        let upper = alignedPCMOffset(Double.maximum(0, endSeconds) * bytesPerSecond, blockAlign: blockAlign)
        let start = min(max(0, lower), data.count)
        let end = min(max(start, upper), data.count)
        return Data(data[start..<end])
    }

    private func pcmBytesPerSecond(_ format: DecodedAudioFormat) -> Double? {
        guard format.payloadKind == .linearPCM,
              let sampleRate = format.sampleRate,
              let blockAlign = pcmBlockAlign(format)
        else { return nil }
        return sampleRate * Double(blockAlign)
    }

    private func pcmBlockAlign(_ format: DecodedAudioFormat) -> Int? {
        guard let channelCount = format.channelCount,
              let bitDepth = format.bitDepth,
              channelCount > 0,
              bitDepth > 0
        else { return nil }
        return channelCount * max(1, bitDepth / 8)
    }

    private func alignedPCMOffset(_ rawOffset: Double, blockAlign: Int) -> Int {
        let offset = Int(rawOffset.rounded(.down))
        return offset - (offset % blockAlign)
    }

    private func readRemoteAudioPrefix(
        for request: URLRequest,
        byteLimit: Int,
        streamType: StreamType
    ) async throws -> (URLResponse, Data) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let targetByteCount = remoteAudioPrefixTargetByteCount(
            response: response,
            byteLimit: byteLimit,
            streamType: streamType
        )
        var data = Data()
        data.reserveCapacity(min(byteLimit, targetByteCount))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= byteLimit || data.count >= targetByteCount {
                break
            }
        }
        return (response, data)
    }

    private func remoteAudioPrefixTargetByteCount(
        response: URLResponse,
        byteLimit: Int,
        streamType: StreamType
    ) -> Int {
        guard streamType == .icecast || streamType == .icy,
              let httpResponse = response as? HTTPURLResponse else {
            return min(byteLimit, 256 * 1024)
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        let metaInt = icyMetaInt(from: headers) ?? ICYMetadataParser.defaultMetaInt
        // Read enough framed ICY data to include metadata changes, but avoid turning a
        // continuous MP3 stream into a multi-minute pseudo-file.
        let metadataAwareTarget = max(64 * 1024, min(160 * 1024, metaInt * 12))
        return min(byteLimit, metadataAwareTarget)
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
