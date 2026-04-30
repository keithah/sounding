import Foundation

/// A parsed HLS manifest tag that can carry SCTE-35 payload text or direct cue metadata.
///
/// The model intentionally stores only the tag name and sanitized marker identity rather than
/// the full manifest line so error surfaces can identify the marker family without retaining
/// payloads, credentials, query strings, fragments, or whole manifests.
public struct HLSManifestSCTE35Tag: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case scte35
        case oatclsSCTE35
        case daterange
        case cueOutCont
        case cueOut
        case cueIn
    }

    public enum PayloadEncodingHint: String, Equatable, Sendable {
        case base64
        case hex
    }

    public let kind: Kind
    public let rawTagName: String
    public let payload: String?
    public let payloadEncodingHint: PayloadEncodingHint?
    public let fields: [String: JSONValue]
    public let sanitizedTagIdentity: String

    public init(
        kind: Kind,
        rawTagName: String,
        payload: String? = nil,
        payloadEncodingHint: PayloadEncodingHint? = nil,
        fields: [String: JSONValue] = [:],
        sanitizedTagIdentity: String
    ) {
        self.kind = kind
        self.rawTagName = rawTagName
        self.payload = payload
        self.payloadEncodingHint = payloadEncodingHint
        self.fields = fields
        self.sanitizedTagIdentity = sanitizedTagIdentity
    }
}
