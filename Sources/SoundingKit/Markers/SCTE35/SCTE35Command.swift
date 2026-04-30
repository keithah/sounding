import Foundation

/// Raw SCTE-35 descriptor bytes preserved inside the bounded descriptor loop.
public struct SCTE35Descriptor: Equatable, Sendable {
    public let tag: UInt8
    public let length: UInt8
    public let bytes: [UInt8]

    public init(tag: UInt8, length: UInt8, bytes: [UInt8]) {
        self.tag = tag
        self.length = length
        self.bytes = bytes
    }
}

/// Decoded SCTE-35 cue fields needed before marker mapping.
public struct SCTE35Cue: Equatable, Sendable {
    public let commandName: String
    public let spliceCommandType: UInt8
    public let sectionLength: Int
    public let ptsAdjustment: UInt64
    public let tier: UInt16
    public let rawBase64: String
    public let ptsTime: Double?
    public let breakDuration: Double?
    public let spliceEventID: UInt32?
    public let outOfNetworkIndicator: Bool?
    public let descriptors: [SCTE35Descriptor]

    public init(
        commandName: String,
        spliceCommandType: UInt8,
        sectionLength: Int,
        ptsAdjustment: UInt64,
        tier: UInt16,
        rawBase64: String,
        ptsTime: Double?,
        breakDuration: Double?,
        spliceEventID: UInt32?,
        outOfNetworkIndicator: Bool?,
        descriptors: [SCTE35Descriptor]
    ) {
        self.commandName = commandName
        self.spliceCommandType = spliceCommandType
        self.sectionLength = sectionLength
        self.ptsAdjustment = ptsAdjustment
        self.tier = tier
        self.rawBase64 = rawBase64
        self.ptsTime = ptsTime
        self.breakDuration = breakDuration
        self.spliceEventID = spliceEventID
        self.outOfNetworkIndicator = outOfNetworkIndicator
        self.descriptors = descriptors
    }
}
