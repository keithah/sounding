/// Public package identity exposed so app and CLI targets can prove they consume SoundingKit.
public struct SoundingKitVersion: Equatable, Sendable {
    public let name: String
    public let string: String

    public static let current = SoundingKitVersion(name: "Sounding", string: "0.1.0")

    public init(name: String, string: String) {
        self.name = name
        self.string = string
    }
}
