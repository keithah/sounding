import Foundation

public struct TranscriptAdVerification: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Equatable, Sendable {
        case ad
        case dialogue
        case music
        case news
        case ambiguous
    }

    public enum AdType: String, Codable, Equatable, Sendable {
        case commercialSpot
        case hostReadAd
        case sponsorBillboard
        case stationPromo
        case psa
    }

    public enum Confidence: String, Codable, Equatable, Sendable {
        case low
        case medium
        case high
    }

    public var verdict: Verdict
    public var adType: AdType?
    public var brand: String?
    public var product: String?
    public var confidence: Confidence
    public var reason: String
    public var modelIdentifier: String
    public var classifiedAt: String

    public init(
        verdict: Verdict,
        adType: AdType?,
        brand: String?,
        product: String?,
        confidence: Confidence,
        reason: String,
        modelIdentifier: String,
        classifiedAt: String
    ) {
        self.verdict = verdict
        self.adType = adType
        self.brand = brand
        self.product = product
        self.confidence = confidence
        self.reason = reason
        self.modelIdentifier = modelIdentifier
        self.classifiedAt = classifiedAt
    }
}

public protocol TranscriptAdVerifier: Sendable {
    func verify(
        paragraph: StreamAppTranscriptParagraph,
        neighbors: [StreamAppTranscriptParagraph]
    ) async throws -> TranscriptAdVerification
}

public struct TranscriptAdScoringPipelineResult: Equatable, Sendable {
    public var isAd: Bool
    public var heuristic: TranscriptAdScorer.Score
    public var verification: TranscriptAdVerification?
    public var verifierError: String?

    public init(
        isAd: Bool,
        heuristic: TranscriptAdScorer.Score,
        verification: TranscriptAdVerification?,
        verifierError: String?
    ) {
        self.isAd = isAd
        self.heuristic = heuristic
        self.verification = verification
        self.verifierError = verifierError
    }
}

public struct TranscriptAdClassificationRefreshResult: Equatable, Sendable {
    public var consideredCount: Int
    public var skippedCachedCount: Int
    public var classifiedCount: Int

    public init(consideredCount: Int, skippedCachedCount: Int, classifiedCount: Int) {
        self.consideredCount = consideredCount
        self.skippedCachedCount = skippedCachedCount
        self.classifiedCount = classifiedCount
    }
}

public struct TranscriptAdClassificationRefresher: Sendable {
    private let database: SoundingDatabase
    private let pipeline: TranscriptAdScoringPipeline
    private let now: @Sendable () -> String

    public init(
        database: SoundingDatabase,
        pipeline: TranscriptAdScoringPipeline,
        now: @escaping @Sendable () -> String = { SoundingTimestampClock.timestamp() }
    ) {
        self.database = database
        self.pipeline = pipeline
        self.now = now
    }

    public func refresh(
        paragraphs: [StreamAppTranscriptParagraph]
    ) async throws -> TranscriptAdClassificationRefreshResult {
        let paragraphsByID = Dictionary(uniqueKeysWithValues: paragraphs.map { ($0.id, $0) })
        let orderedParagraphs = paragraphsByID.values.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        let segmentIDs = orderedParagraphs.map(\.id)
        let cached = try database.read { db in
            try TranscriptAdClassificationCache.fetch(segmentIDs: segmentIDs, db: db)
        }
        let cache = TranscriptAdClassificationCache(database: database)
        var classifiedCount = 0

        for paragraph in orderedParagraphs where cached[paragraph.id] == nil {
            let result = await pipeline.classify(
                paragraph: paragraph,
                neighbors: orderedParagraphs.filter { $0.id != paragraph.id }
            )
            try cache.upsert(result.cacheEntry(segmentID: paragraph.id, classifiedAt: now()))
            classifiedCount += 1
        }

        return TranscriptAdClassificationRefreshResult(
            consideredCount: orderedParagraphs.count,
            skippedCachedCount: cached.count,
            classifiedCount: classifiedCount
        )
    }
}

public struct TranscriptAdScoringPipeline: Sendable {
    private let verifier: (any TranscriptAdVerifier)?
    private let isVerifierEnabled: Bool
    private let adThreshold: Double
    private let verifierThreshold: Double
    private let brandExtractionThreshold: Double

    public init(
        verifier: (any TranscriptAdVerifier)? = nil,
        isVerifierEnabled: Bool = false,
        now: @escaping @Sendable () -> String,
        adThreshold: Double = 0.50,
        verifierThreshold: Double = 0.30,
        brandExtractionThreshold: Double = 0.65
    ) {
        self.verifier = verifier
        self.isVerifierEnabled = isVerifierEnabled
        _ = now
        self.adThreshold = adThreshold
        self.verifierThreshold = verifierThreshold
        self.brandExtractionThreshold = brandExtractionThreshold
    }

    public func classify(
        paragraph: StreamAppTranscriptParagraph,
        neighbors: [StreamAppTranscriptParagraph],
        cachedVerification: TranscriptAdVerification? = nil
    ) async -> TranscriptAdScoringPipelineResult {
        let boundedNeighbors = Self.boundedNeighbors(around: paragraph, in: neighbors)
        let heuristic = TranscriptAdScorer.score(paragraph: paragraph, neighbors: boundedNeighbors)
        if let cachedVerification, cachedVerification.verdict != .ad {
            return TranscriptAdScoringPipelineResult(
                isAd: false,
                heuristic: heuristic,
                verification: cachedVerification,
                verifierError: nil
            )
        }
        if let cachedVerification,
           cachedVerification.verdict == .ad,
           Self.hasBrand(cachedVerification) {
            return TranscriptAdScoringPipelineResult(
                isAd: true,
                heuristic: heuristic,
                verification: cachedVerification,
                verifierError: nil
            )
        }

        guard shouldVerify(heuristic: heuristic, cachedVerification: cachedVerification),
            let verifier
        else {
            return TranscriptAdScoringPipelineResult(
                isAd: cachedVerification?.verdict == .ad || heuristic.confidence >= adThreshold,
                heuristic: heuristic,
                verification: cachedVerification,
                verifierError: nil
            )
        }

        do {
            let verification = try await verifier.verify(
                paragraph: paragraph,
                neighbors: boundedNeighbors
            )
            return TranscriptAdScoringPipelineResult(
                isAd: finalAdVerdict(heuristic: heuristic, verification: verification),
                heuristic: heuristic,
                verification: verification,
                verifierError: nil
            )
        } catch {
            return TranscriptAdScoringPipelineResult(
                isAd: heuristic.confidence >= adThreshold,
                heuristic: heuristic,
                verification: nil,
                verifierError: String(describing: error)
            )
        }
    }

    private func shouldVerify(
        heuristic: TranscriptAdScorer.Score,
        cachedVerification: TranscriptAdVerification?
    ) -> Bool {
        guard isVerifierEnabled else { return false }
        if let cachedVerification, cachedVerification.verdict != .ad { return false }
        if heuristic.confidence >= brandExtractionThreshold {
            return cachedVerification.map { !Self.hasBrand($0) } ?? true
        }
        return heuristic.confidence >= verifierThreshold
    }

    private func finalAdVerdict(
        heuristic: TranscriptAdScorer.Score,
        verification: TranscriptAdVerification
    ) -> Bool {
        if heuristic.confidence >= brandExtractionThreshold {
            return heuristic.confidence >= adThreshold
        }
        return verification.verdict == .ad
    }

    private static func hasBrand(_ verification: TranscriptAdVerification) -> Bool {
        guard let brand = verification.brand?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !brand.isEmpty
    }

    private static func boundedNeighbors(
        around paragraph: StreamAppTranscriptParagraph,
        in neighbors: [StreamAppTranscriptParagraph]
    ) -> [StreamAppTranscriptParagraph] {
        let previous = neighbors
            .filter { $0.startSeconds < paragraph.startSeconds }
            .sorted { lhs, rhs in
                if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds > rhs.startSeconds }
                return lhs.id > rhs.id
            }
            .prefix(3)
        let next = neighbors
            .filter { $0.startSeconds > paragraph.startSeconds }
            .sorted { lhs, rhs in
                if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
                return lhs.id < rhs.id
            }
            .prefix(3)
        return Array(previous.reversed()) + Array(next)
    }
}

private extension TranscriptAdScoringPipelineResult {
    func cacheEntry(segmentID: Int64, classifiedAt: String) -> TranscriptAdClassificationCacheEntry {
        TranscriptAdClassificationCacheEntry(
            identity: TranscriptAdClassificationCacheIdentity(
                segmentID: segmentID,
                classifier: TranscriptAdScorer.classifier,
                classifierVersion: TranscriptAdScorer.classifierVersion
            ),
            isAd: isAd,
            confidence: cacheConfidence,
            signals: cacheSignals,
            classifiedAt: classifiedAt
        )
    }

    var cacheConfidence: Double {
        guard let verification else { return heuristic.confidence }
        return max(heuristic.confidence, verification.confidence.cacheConfidence)
    }

    var cacheSignals: [String] {
        var signals = heuristic.signals
        if let verification {
            signals.append("verified:\(verification.verdict.rawValue)")
            if let brand = verification.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
               !brand.isEmpty {
                signals.append("verified-brand")
            }
        }
        if let verifierError, !verifierError.isEmpty {
            signals.append("verifier-error")
        }
        if signals.isEmpty {
            signals.append("heuristic:no-signals")
        }
        return Array(Set(signals)).sorted()
    }
}

private extension TranscriptAdVerification.Confidence {
    var cacheConfidence: Double {
        switch self {
        case .low:
            return 0.45
        case .medium:
            return 0.70
        case .high:
            return 0.90
        }
    }
}
