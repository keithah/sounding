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
    public var now: @Sendable () -> String

    public init(
        chunkDurationSeconds: Double = 10,
        segmentLoader: any HLSSegmentLoading = HLSSegmentLoader(),
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.chunkDurationSeconds = max(chunkDurationSeconds, 0.001)
        self.segmentLoader = segmentLoader
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

    private func decodeHLS(_ request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
        let manifest = try await loadManifestText(from: request.source)
        let segments = HLSManifestParser.parseMediaSegments(manifest)
        guard !segments.isEmpty else {
            throw AVFoundationAudioDecoderError.unsupportedMedia("HLS manifest has no media segments.")
        }

        var chunks: [DecodedAudioChunk] = []
        let limitedSegments = Array(segments.prefix(max(0, request.maxChunks ?? segments.count)))
        for (index, segment) in limitedSegments.enumerated() {
            let markers = try markersForSegment(segment, source: request.source)
            let data: Data
            do {
                data = try await segmentLoader.loadSegment(uri: segment.uri, relativeTo: request.source)
            } catch {
                throw AVFoundationAudioDecoderError.decodeFailed("HLS segment decode failed: \(sanitized(error)).")
            }

            let start = Double(index) * chunkDurationSeconds
            let duration = Double(segment.duration ?? "") ?? chunkDurationSeconds
            let end = start + max(duration, 0.001)
            chunks.append(DecodedAudioChunk(
                sequence: index,
                segmentURI: resolvedSegmentDescription(segment.uri, relativeTo: request.source),
                audio: data,
                byteCount: data.count,
                startSeconds: start,
                endSeconds: end,
                startedAt: now(),
                endedAt: now(),
                adMarkers: markers
            ))
        }
        return applyDurationBound(chunks, durationSeconds: request.durationSeconds)
    }

    private func decodeAsset(_ request: AudioDecodeRequest) async throws -> [DecodedAudioChunk] {
#if canImport(AVFoundation)
        let url = try mediaURL(from: request.source)
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

        let duration: Double
        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            throw AVFoundationAudioDecoderError.decodeFailed("Audio duration decode failed: \(sanitized(error)).")
        }
        guard duration.isFinite, duration > 0 else {
            throw AVFoundationAudioDecoderError.unsupportedMedia("Audio source has unsupported duration.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AVFoundationAudioDecoderError.sourceOpenFailed("Audio source read failed: \(sanitized(error)).")
        }

        let effectiveDuration = min(duration, request.durationSeconds ?? duration)
        let chunkCount = max(1, Int(ceil(effectiveDuration / chunkDurationSeconds)))
        let boundedCount = min(chunkCount, max(0, request.maxChunks ?? chunkCount))
        guard boundedCount > 0 else { return [] }

        return (0..<boundedCount).map { index in
            let start = Double(index) * chunkDurationSeconds
            let end = min(start + chunkDurationSeconds, effectiveDuration)
            return DecodedAudioChunk(
                sequence: index,
                segmentURI: MonitorError.redactedSourceDescription(request.source),
                audio: data,
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

    private func loadManifestText(from source: String) async throws -> String {
        let data: Data
        do {
            if let url = URL(string: source), url.scheme == "http" || url.scheme == "https" {
                let (remoteData, response) = try await HLSURLSessionDataLoader.data(from: url, using: .shared)
                guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                    throw AVFoundationAudioDecoderError.sourceOpenFailed("HLS manifest open failed: non-success HTTP response.")
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

    private func resolvedSegmentDescription(_ uri: String, relativeTo manifestSource: String) -> String {
        if let absoluteURL = URL(string: uri), absoluteURL.scheme != nil {
            return MonitorError.redactedSourceDescription(absoluteURL.absoluteString)
        }
        if let manifestURL = URL(string: manifestSource), manifestURL.scheme != nil,
           let resolved = URL(string: uri, relativeTo: manifestURL.deletingLastPathComponent())?.absoluteString {
            return MonitorError.redactedSourceDescription(resolved)
        }
        let manifestURL = URL(fileURLWithPath: manifestSource)
        return MonitorError.redactedSourceDescription(manifestURL.deletingLastPathComponent().appendingPathComponent(uri).path)
    }

    private func sanitized(_ error: Error) -> String {
        MonitorError.redactedSourceDescription(String(describing: error))
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
            return MonitorError.redactedSourceDescription(message)
        }
    }
}
