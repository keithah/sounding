/// Semantic classification assigned to an ad marker after parsing.
///
/// S02 defines only the stable wire values; parser/classifier behavior lands in later slices.
public enum MarkerClassification: String, Codable, Equatable, Sendable {
    case unknown = "UNKNOWN"
    case adStart = "AD_START"
    case adEnd = "AD_END"
}
