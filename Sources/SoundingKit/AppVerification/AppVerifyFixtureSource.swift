import Foundation

public struct AppVerifyFixtureSource: Codable, Equatable, Sendable {
    public var url: URL
    public var sourceDescription: String
    public var sampleRate: Int
    public var channelCount: Int
    public var bitDepth: Int
    public var durationSeconds: Double
    public var byteCount: Int

    public init(
        url: URL,
        sourceDescription: String,
        sampleRate: Int,
        channelCount: Int,
        bitDepth: Int,
        durationSeconds: Double,
        byteCount: Int
    ) {
        self.url = url
        self.sourceDescription = AppVerifyEvidenceSanitizer.sourceDescription(sourceDescription)
        self.sampleRate = max(1, sampleRate)
        self.channelCount = max(1, channelCount)
        self.bitDepth = max(1, bitDepth)
        self.durationSeconds = durationSeconds.isFinite ? max(0, durationSeconds) : 0
        self.byteCount = max(0, byteCount)
    }
}

public enum AppVerifyFixtureSourceError: Error, Equatable, Sendable, CustomStringConvertible {
    case fixtureSourceCreated(String)

    public var check: AppVerifyCheckRecord {
        switch self {
        case let .fixtureSourceCreated(reason):
            return .fail(.fixtureSourceCreated, phase: .fixture, reason: reason)
        }
    }

    public var description: String {
        switch self {
        case let .fixtureSourceCreated(reason):
            return AppVerifyEvidenceSanitizer.redact(reason)
        }
    }
}

public enum AppVerifyFixtureSourceWriter {
    public static let fileName = "app-verify-fixture.wav"

    public static func writeDeterministicWAV(
        in runDirectory: URL,
        fileName: String = AppVerifyFixtureSourceWriter.fileName,
        durationSeconds: Double = 0.25,
        sampleRate: Int = 44_100,
        channelCount: Int = 2,
        frequencyHz: Double = 440,
        amplitude: Double = 0.2,
        fileManager: FileManager = .default
    ) throws -> AppVerifyFixtureSource {
        guard runDirectory.isFileURL else {
            throw AppVerifyFixtureSourceError.fixtureSourceCreated("Fixture run directory must be a local file URL.")
        }
        guard !fileName.isEmpty, !fileName.contains("/") else {
            throw AppVerifyFixtureSourceError.fixtureSourceCreated("Fixture WAV file name is malformed.")
        }

        let safeSampleRate = max(8_000, sampleRate)
        let safeChannelCount = min(max(1, channelCount), 2)
        let safeDuration = durationSeconds.isFinite ? max(0.05, min(durationSeconds, 5.0)) : 0.25
        let frameCount = max(1, Int((Double(safeSampleRate) * safeDuration).rounded()))
        let url = runDirectory.appendingPathComponent(fileName)

        do {
            try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            let data = makePCM16WAV(
                frameCount: frameCount,
                sampleRate: safeSampleRate,
                channelCount: safeChannelCount,
                frequencyHz: frequencyHz,
                amplitude: amplitude
            )
            try data.write(to: url, options: .atomic)
            return AppVerifyFixtureSource(
                url: url,
                sourceDescription: url.path,
                sampleRate: safeSampleRate,
                channelCount: safeChannelCount,
                bitDepth: 16,
                durationSeconds: Double(frameCount) / Double(safeSampleRate),
                byteCount: data.count
            )
        } catch let error as AppVerifyFixtureSourceError {
            throw error
        } catch {
            throw AppVerifyFixtureSourceError.fixtureSourceCreated(
                "Fixture WAV creation failed: \(AppVerifyEvidenceSanitizer.redact(String(describing: error)))."
            )
        }
    }

    private static func makePCM16WAV(
        frameCount: Int,
        sampleRate: Int,
        channelCount: Int,
        frequencyHz: Double,
        amplitude: Double
    ) -> Data {
        let bitsPerSample = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataByteCount = frameCount * blockAlign
        let clampedAmplitude = max(0, min(amplitude, 0.8))

        var data = Data()
        data.reserveCapacity(44 + dataByteCount)
        data.appendASCII("RIFF")
        data.appendLittleEndianUInt32(UInt32(36 + dataByteCount))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndianUInt32(16)
        data.appendLittleEndianUInt16(1)
        data.appendLittleEndianUInt16(UInt16(channelCount))
        data.appendLittleEndianUInt32(UInt32(sampleRate))
        data.appendLittleEndianUInt32(UInt32(byteRate))
        data.appendLittleEndianUInt16(UInt16(blockAlign))
        data.appendLittleEndianUInt16(UInt16(bitsPerSample))
        data.appendASCII("data")
        data.appendLittleEndianUInt32(UInt32(dataByteCount))

        for frame in 0..<frameCount {
            let t = Double(frame) / Double(sampleRate)
            let envelope = frame < frameCount / 2 ? 1.0 : 0.0
            let sample = Int16((sin(2.0 * .pi * frequencyHz * t) * clampedAmplitude * envelope * Double(Int16.max)).rounded())
            for _ in 0..<channelCount {
                data.appendLittleEndianInt16(sample)
            }
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndianUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndianInt16(_ value: Int16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
