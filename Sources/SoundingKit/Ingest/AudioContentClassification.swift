import Foundation

/// Context passed to audio content classifiers before expensive song fingerprinting.
public struct AudioContentClassificationRequest: Equatable, Sendable {
    public var source: String
    public var streamType: StreamType
    public var streamID: Int64
    public var runID: Int64

    public init(
        source: String,
        streamType: StreamType,
        streamID: Int64,
        runID: Int64
    ) {
        self.source = source
        self.streamType = streamType
        self.streamID = streamID
        self.runID = runID
    }
}

/// Coarse content classification for a decoded audio chunk.
public struct AudioContentClassification: Equatable, Sendable {
    public var musicProbability: Double?
    public var speechProbability: Double?
    public var label: String?

    public init(
        musicProbability: Double? = nil,
        speechProbability: Double? = nil,
        label: String? = nil
    ) {
        self.musicProbability = musicProbability
        self.speechProbability = speechProbability
        self.label = label
    }

    public func allowsFingerprinting(minimumMusicProbability: Double) -> Bool {
        guard let musicProbability else { return true }
        let normalizedLabel = label?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let speechProbability = speechProbability ?? 0
        if labelIndicatesSpeech(normalizedLabel), speechProbability >= 0.65 {
            return false
        }
        if labelIndicatesMusic(normalizedLabel),
           speechProbability < 0.65,
           musicProbability >= max(0, minimumMusicProbability - 0.30)
        {
            return true
        }
        return musicProbability >= minimumMusicProbability
    }

    private func labelIndicatesMusic(_ label: String?) -> Bool {
        guard let label else { return false }
        return label.contains("music")
            || label.contains("song")
            || label.contains("singing")
            || label.contains("rap")
            || label.contains("hip hop")
    }

    private func labelIndicatesSpeech(_ label: String?) -> Bool {
        guard let label else { return false }
        return label.contains("speech") || label.contains("conversation") || label.contains("narration")
    }
}

/// SoundingKit-owned seam for SoundAnalysis/Core ML music-vs-non-music classification.
public protocol AudioContentClassifying: Sendable {
    func classify(
        _ chunk: DecodedAudioChunk,
        request: AudioContentClassificationRequest
    ) async throws -> AudioContentClassification?
}
