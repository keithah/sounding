import Foundation

public struct ID3TransportTimestamp: Equatable, Sendable {
    public let ticks: UInt64
    public let seconds: Double

    public init(ticks: UInt64, seconds: Double) {
        self.ticks = ticks
        self.seconds = seconds
    }
}

public enum ID3Frame: Equatable, Sendable {
    case text(id: String, texts: [String])
    case userText(description: String, texts: [String])
    case `private`(owner: String, dataLength: Int, transportTimestamp: ID3TransportTimestamp?)
    case unsupported(id: String, dataLength: Int)
}
