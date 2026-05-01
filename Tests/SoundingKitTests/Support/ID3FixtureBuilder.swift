import Foundation

enum ID3FixtureBuilder {
    static let appleTransportTimestampOwner = "com.apple.streaming.transportStreamTimestamp"

    static func tag(major: UInt8 = 4, frames: [Data]) -> Data {
        let payload = frames.reduce(Data(), +)
        return Data([0x49, 0x44, 0x33, major, 0x00, 0x00]) + synchsafe(payload.count) + payload
    }

    static func frame(id: String, payload: Data, versionMajor: UInt8 = 4, flags: [UInt8] = [0x00, 0x00]) -> Data {
        frameHeader(id: id, payloadSize: payload.count, versionMajor: versionMajor, flags: flags) + payload
    }

    static func textFrame(id: String, values: [String], encoding: UInt8 = 3, versionMajor: UInt8 = 4) -> Data {
        frame(id: id, payload: textPayload(encoding: encoding, values), versionMajor: versionMajor)
    }

    static func userTextFrame(description: String, values: [String], encoding: UInt8 = 3, versionMajor: UInt8 = 4) -> Data {
        frame(id: "TXXX", payload: textPayload(encoding: encoding, [description] + values), versionMajor: versionMajor)
    }

    static func privateFrame(owner: String, data: Data, versionMajor: UInt8 = 4) -> Data {
        frame(id: "PRIV", payload: Data(owner.utf8) + Data([0x00]) + data, versionMajor: versionMajor)
    }

    static func appleTransportTimestampFrame(ticks: UInt64, versionMajor: UInt8 = 4) -> Data {
        privateFrame(owner: appleTransportTimestampOwner, data: timestampPayload(ticks: ticks), versionMajor: versionMajor)
    }

    static func timestampPayload(ticks: UInt64) -> Data {
        bigEndian64(ticks & 0x1FFFFFFFF)
    }

    static func synchsafe(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }

    static func bigEndian32(_ value: Int) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private static func frameHeader(id: String, payloadSize: Int, versionMajor: UInt8, flags: [UInt8]) -> Data {
        precondition(id.utf8.count == 4)
        precondition(flags.count == 2)
        let size = versionMajor == 4 ? synchsafe(payloadSize) : bigEndian32(payloadSize)
        return Data(id.utf8) + size + Data(flags)
    }

    private static func textPayload(encoding: UInt8, _ values: [String]) -> Data {
        var data = Data([encoding])
        switch encoding {
        case 0:
            data.append(values.joined(separator: "\0").data(using: .isoLatin1)!)
        case 3:
            data.append(values.joined(separator: "\0").data(using: .utf8)!)
        default:
            preconditionFailure("test helper supports Latin-1 and UTF-8 only")
        }
        return data
    }

    private static func bigEndian64(_ value: UInt64) -> Data {
        Data([
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}
