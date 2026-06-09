import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum FoundationModelsAdVerifierError: Error, Equatable, Sendable {
    case unavailable
    case invalidResponse
}

public enum FoundationModelsAdVerifierAvailabilityStatus: Equatable, Sendable {
    case available
    case unavailable(message: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .available:
            return "Available"
        case .unavailable(let message):
            return message
        }
    }
}

public enum FoundationModelsAdVerifierFactory {
    public static func availability() -> FoundationModelsAdVerifierAvailabilityStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(message: unavailableMessage(for: reason))
            }
        }
        return .unavailable(message: "Requires macOS 26 or later.")
        #else
        return .unavailable(message: "Foundation Models is unavailable in this build.")
        #endif
    }

    public static func makeIfAvailable(
        now: @escaping @Sendable () -> String = { SoundingTimestampClock.timestamp() }
    ) -> (any TranscriptAdVerifier)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsAdVerifier.makeIfAvailable(now: now)
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func unavailableMessage(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac is not eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence to use on-device ad verification."
        case .modelNotReady:
            return "Apple Intelligence is still preparing the local model."
        @unknown default:
            return "Foundation Models is currently unavailable."
        }
    }
    #endif
}

enum FoundationModelsAdVerifierResponseParser {
    static func parse(
        _ response: String,
        classifiedAt: String,
        modelIdentifier: String
    ) throws -> TranscriptAdVerification {
        let body = strippedJSONBody(from: response)
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdict = parseVerdict(object["verdict"]),
              let confidence = parseConfidence(object["confidence"]),
              let reason = normalizedString(object["reason"])
        else {
            throw FoundationModelsAdVerifierError.invalidResponse
        }

        return TranscriptAdVerification(
            verdict: verdict,
            adType: parseAdType(object["ad_type"] ?? object["adType"]),
            brand: normalizedString(object["brand"]),
            product: normalizedString(object["product"]),
            confidence: confidence,
            reason: reason,
            modelIdentifier: modelIdentifier,
            classifiedAt: classifiedAt
        )
    }

    private static func strippedJSONBody(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseVerdict(_ value: Any?) -> TranscriptAdVerification.Verdict? {
        guard let raw = normalizedString(value) else { return nil }
        return TranscriptAdVerification.Verdict(rawValue: normalizedToken(raw))
    }

    private static func parseConfidence(_ value: Any?) -> TranscriptAdVerification.Confidence? {
        guard let raw = normalizedString(value) else { return nil }
        return TranscriptAdVerification.Confidence(rawValue: normalizedToken(raw))
    }

    private static func parseAdType(_ value: Any?) -> TranscriptAdVerification.AdType? {
        guard let raw = normalizedString(value) else { return nil }
        switch normalizedToken(raw) {
        case "commercialspot":
            return .commercialSpot
        case "hostreadad":
            return .hostReadAd
        case "sponsorbillboard":
            return .sponsorBillboard
        case "stationpromo":
            return .stationPromo
        case "psa":
            return .psa
        default:
            return nil
        }
    }

    private static func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
public struct FoundationModelsAdVerifier: TranscriptAdVerifier {
    public static let modelIdentifier = "foundationmodels.system.default"

    private let session: LanguageModelSession
    private let now: @Sendable () -> String

    public init(
        model: SystemLanguageModel = .default,
        now: @escaping @Sendable () -> String = { SoundingTimestampClock.timestamp() }
    ) {
        self.session = LanguageModelSession(
            model: model,
            instructions: Self.instructions
        )
        self.now = now
    }

    public static func makeIfAvailable(
        model: SystemLanguageModel = .default,
        now: @escaping @Sendable () -> String = { SoundingTimestampClock.timestamp() }
    ) -> FoundationModelsAdVerifier? {
        guard model.availability == .available else { return nil }
        return FoundationModelsAdVerifier(model: model, now: now)
    }

    public func verify(
        paragraph: StreamAppTranscriptParagraph,
        neighbors: [StreamAppTranscriptParagraph]
    ) async throws -> TranscriptAdVerification {
        guard SystemLanguageModel.default.availability == .available else {
            throw FoundationModelsAdVerifierError.unavailable
        }
        let response = try await session.respond(
            to: Self.prompt(paragraph: paragraph, neighbors: neighbors),
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 240)
        )
        return try FoundationModelsAdVerifierResponseParser.parse(
            response.content,
            classifiedAt: now(),
            modelIdentifier: Self.modelIdentifier
        )
    }

    private static var instructions: String {
        """
        You classify radio transcript excerpts for ad detection.
        Return only a JSON object with keys: verdict, ad_type, brand, product, confidence, reason.
        verdict must be one of: ad, dialogue, music, news, ambiguous.
        ad_type must be one of: commercial_spot, host_read_ad, sponsor_billboard, station_promo, psa, or null.
        confidence must be one of: low, medium, high.
        brand and product may be null when unknown.
        Treat song lyrics, music descriptions, and DJ chatter as non-ad unless there is a clear commercial, sponsor, promo, PSA, URL, offer, or disclaimer.
        """
    }

    private static func prompt(
        paragraph: StreamAppTranscriptParagraph,
        neighbors: [StreamAppTranscriptParagraph]
    ) -> String {
        let context = neighbors
            .sorted {
                if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
                return $0.id < $1.id
            }
            .map { "[- context \($0.startSeconds)-\($0.endSeconds)] \($0.text)" }
            .joined(separator: "\n")
        let contextBlock = context.isEmpty ? "No neighboring transcript context." : context
        return """
        Neighboring context:
        \(contextBlock)

        Target paragraph:
        [\(paragraph.startSeconds)-\(paragraph.endSeconds)] \(paragraph.text)
        """
    }
}
#endif
