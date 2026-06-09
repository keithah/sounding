import Foundation

public enum TranscriptAdScorer {
    public static let classifier = "transcript-ad-heuristic"
    public static let classifierVersion = "3"

    public struct Score: Equatable, Sendable {
        public let confidence: Double
        public let signals: [String]

        public init(confidence: Double, signals: [String]) {
            self.confidence = min(max(confidence, 0), 1)
            self.signals = signals
        }
    }

    public static func score(
        paragraph: StreamAppTranscriptParagraph,
        neighbors: [StreamAppTranscriptParagraph]
    ) -> Score {
        let raw = rawScore(paragraph.text, duration: paragraph.endSeconds - paragraph.startSeconds)
        let neighborScores = neighbors.map {
            (
                paragraph: $0,
                score: rawScore($0.text, duration: $0.endSeconds - $0.startSeconds)
            )
        }
        return reinforcedScore(for: paragraph, raw: raw, neighborScores: neighborScores)
    }

    public static func scores(
        for paragraphs: [StreamAppTranscriptParagraph]
    ) -> [Int64: Score] {
        let ordered = paragraphs.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.id < $1.id
        }
        let rawScores = ordered.map {
            (
                paragraph: $0,
                score: rawScore($0.text, duration: $0.endSeconds - $0.startSeconds)
            )
        }
        var result: [Int64: Score] = [:]
        for index in rawScores.indices {
            let entry = rawScores[index]
            var neighbors: [(paragraph: StreamAppTranscriptParagraph, score: Score)] = []
            let paragraphMidpoint = midpoint(entry.paragraph)

            if index > rawScores.startIndex {
                var previous = rawScores.index(before: index)
                while previous >= rawScores.startIndex {
                    let candidate = rawScores[previous]
                    guard paragraphMidpoint - midpoint(candidate.paragraph) <= 60 else { break }
                    neighbors.append(candidate)
                    guard previous > rawScores.startIndex else { break }
                    previous = rawScores.index(before: previous)
                }
            }

            var next = rawScores.index(after: index)
            while next < rawScores.endIndex {
                let candidate = rawScores[next]
                guard midpoint(candidate.paragraph) - paragraphMidpoint <= 60 else { break }
                neighbors.append(candidate)
                next = rawScores.index(after: next)
            }

            result[entry.paragraph.id] = reinforcedScore(
                for: entry.paragraph,
                raw: entry.score,
                neighborScores: neighbors
            )
        }
        return result
    }

    private static func reinforcedScore(
        for paragraph: StreamAppTranscriptParagraph,
        raw: Score,
        neighborScores: [(paragraph: StreamAppTranscriptParagraph, score: Score)]
    ) -> Score {
        var score = raw
        guard score.confidence > 0 else { return score }

        let reinforcingNeighbors = neighborScores.filter { entry in
            abs(midpoint(entry.paragraph) - midpoint(paragraph)) <= 60
                && entry.score.confidence >= 0.40
        }
        var reinforcement = min(Double(reinforcingNeighbors.count) * 0.10, 0.20)
        var reinforcementSignal: String?

        let clusteredNeighbors = neighborScores.filter { entry in
            abs(midpoint(entry.paragraph) - midpoint(paragraph)) <= 60
                && entry.score.confidence >= 0.25
        }
        if raw.confidence >= 0.25, clusteredNeighbors.count >= 2 {
            reinforcement = max(reinforcement, 0.20)
            reinforcementSignal = "ad-cluster+0.20"
        } else if reinforcement > 0 {
            reinforcementSignal = String(format: "neighbor-reinforced+%.2f", reinforcement)
        }

        if reinforcement > 0 {
            score = Score(
                confidence: score.confidence + reinforcement,
                signals: score.signals + [reinforcementSignal ?? String(format: "neighbor-reinforced+%.2f", reinforcement)]
            )
        }
        return score
    }

    private static func rawScore(_ text: String, duration: Double) -> Score {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return Score(confidence: 0, signals: []) }

        var signals: [String] = []

        var strong = 0.0
        if let urlSignal = urlSignal(in: normalized) {
            strong += 0.40
            signals.append(urlSignal)
        }
        let disclaimerCount = legalDisclaimers.filter { normalized.contains($0) }.count
        if disclaimerCount > 0 {
            strong += min(Double(disclaimerCount) * 0.40, 0.80)
            signals.append("disclaimerx\(disclaimerCount)")
        }
        if musicOrSFXTags.contains(where: { normalized.contains($0) }) {
            strong += 0.15
            signals.append("music-sfx")
        }
        strong = min(strong, 0.80)

        var medium = 0.0
        if let phrase = sponsorPhrases.first(where: { normalized.contains($0) }) {
            medium += 0.35
            signals.append("sponsor:\(phrase)")
        }
        let ctaCount = ctaVerbs.filter { containsWord($0, in: normalized) }.count
        if ctaCount > 0 {
            medium += min(Double(ctaCount) * 0.10, 0.30)
            signals.append("ctax\(ctaCount)")
        }
        if normalized.contains("for your business") || normalized.contains("for your home") {
            medium += 0.30
            signals.append("commercial-pitch")
        }
        if containsAppCTA(in: normalized) {
            medium += 0.25
            signals.append("app-cta")
        }
        if containsPlatformPitch(in: normalized) {
            medium += 0.25
            signals.append("platform-pitch")
        }
        if normalized.contains("find a doctor") || normalized.contains("eye doctor") {
            medium += 0.25
            signals.append("service-pitch")
        }
        if containsTuneInPromo(in: normalized) {
            medium += 0.25
            signals.append("tunein-promo")
        }
        if containsBankingPitch(in: normalized) {
            medium += 0.25
            signals.append("banking-pitch")
        }
        medium = min(medium, 0.45)

        var weak = 0.0
        let keywordCount = adKeywords.filter { containsWord($0, in: normalized) }.count
        if keywordCount > 0 {
            weak += min(Double(keywordCount) * 0.15, 0.25)
            signals.append("keywordx\(keywordCount)")
        }
        if containsKnownCommercialBrand(in: normalized) {
            weak += 0.15
            signals.append("known-brand")
        }
        if duration >= 20 {
            weak += 0.05
            signals.append("length>=20s")
        }
        weak = min(weak, 0.25)

        return Score(confidence: strong + medium + weak, signals: signals)
    }

    private static func midpoint(_ paragraph: StreamAppTranscriptParagraph) -> Double {
        (paragraph.startSeconds + paragraph.endSeconds) / 2
    }

    private static func urlSignal(in text: String) -> String? {
        if text.contains(" dot com") { return "url:dot-com" }
        if text.contains(" dot net") { return "url:dot-net" }
        if text.range(of: #"[a-z0-9][a-z0-9.-]*\.(com|net|org|io|app)(/[a-z0-9][a-z0-9/_-]*)?"#, options: .regularExpression) != nil {
            return "url:domain"
        }
        if text.range(of: #"\b[a-z]{3,}/[a-z]{3,}\b"#, options: .regularExpression) != nil {
            return "url:path"
        }
        return nil
    }

    private static func containsAppCTA(in text: String) -> Bool {
        text.contains("app")
            && ["download", "find", "search", "ask"].contains { containsWord($0, in: text) }
    }

    private static func containsPlatformPitch(in text: String) -> Bool {
        text.contains("audio platform")
            || text.contains("one simple app")
            || text.contains("stream stations")
            || text.contains("podcasts")
    }

    private static func containsTuneInPromo(in text: String) -> Bool {
        text.contains("tune in")
            && (
                text.contains("listening")
                    || text.contains("audio platform")
                    || text.contains("one simple app")
                    || text.contains("podcast")
                    || text.contains("stations")
            )
    }

    private static func containsBankingPitch(in text: String) -> Bool {
        text.contains("no fees")
            || text.contains("no fee")
            || text.contains("minimums")
            || text.contains("checking")
            || text.contains("bank guy")
            || text.contains("banking")
            || text.contains("what's in your wallet")
            || text.contains("capital one cafe")
    }

    private static func containsKnownCommercialBrand(in text: String) -> Bool {
        knownCommercialBrands.contains { text.contains($0) }
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: word, options: [], range: searchRange) {
            if isBoundary(before: range.lowerBound, in: text),
               isBoundary(after: range.upperBound, in: text) {
                return true
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }

    private static func isBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex, let previous = text[..<index].unicodeScalars.last else {
            return true
        }
        return !isWordScalar(previous)
    }

    private static func isBoundary(after index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex, let next = text[index...].unicodeScalars.first else {
            return true
        }
        return !isWordScalar(next)
    }

    private static func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static let legalDisclaimers = [
        "rates may apply",
        "terms apply",
        "terms and conditions",
        "member fdic",
        "see store for details",
        "void where prohibited",
        "your money back",
        "results not typical",
    ]

    private static let musicOrSFXTags = [
        "[music]",
        "[music playing]",
        "(whooshing)",
    ]

    private static let sponsorPhrases = [
        "brought to you by",
        "sponsored by",
        "presented by",
        "support for this",
        "where we come in",
        "we'll be right back",
        "we will be right back",
        "more after the break",
        "stay tuned",
        "is bringing people together",
    ]

    private static let ctaVerbs = [
        "search",
        "download",
        "visit",
        "call",
        "start",
        "try",
        "ask",
        "bring",
        "discover",
        "tune in",
    ]

    private static let adKeywords = [
        "ad",
        "advertisement",
        "sponsor",
        "commercial",
        "promo",
    ]

    private static let knownCommercialBrands = [
        "zocdoc",
        "zokdok",
        "zok-dok",
        "zock dock",
        "zokta",
        "capital one",
        "legalzoom",
        "legal zoom",
        "wells fargo",
        "tune in",
        "tunein",
    ]
}
