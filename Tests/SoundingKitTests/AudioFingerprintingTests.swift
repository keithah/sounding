import Foundation
import XCTest

@testable import SoundingKit

final class AudioFingerprintingTests: XCTestCase {
    func testChromaSwiftFingerprinterProducesAcoustIDCompatibleFingerprintForLinearPCM()
        async throws
    {
        let chunk = Self.sineChunk(sequence: 0, seconds: 12)
        let result = try await ChromaSwiftAudioFingerprinter().fingerprint(
            chunk,
            request: AudioFingerprintRequest(
                source: "https://example.test/live.m3u8",
                streamType: .hls,
                streamID: 11,
                runID: 22
            )
        )

        XCTAssertEqual(result.fingerprints.count, 1)
        XCTAssertEqual(result.songPlays.count, 1)
        let fingerprint = try XCTUnwrap(result.fingerprints.first)
        XCTAssertEqual(fingerprint.algorithm, "chromaprint")
        XCTAssertEqual(fingerprint.algorithmVersion, "test2")
        XCTAssertFalse(fingerprint.fingerprint.isEmpty)
        XCTAssertFalse(fingerprint.fingerprintHash.isEmpty)
        XCTAssertEqual(fingerprint.startSeconds, 30)
        XCTAssertEqual(fingerprint.endSeconds, 42)
        let songPlay = try XCTUnwrap(result.songPlays.first)
        XCTAssertEqual(songPlay.song.songKey, "fingerprint:\(fingerprint.fingerprintHash)")
        XCTAssertEqual(songPlay.song.displayName, "Unknown song (\(fingerprint.fingerprintHash.prefix(8)))")
        XCTAssertEqual(songPlay.source, "chromaprint")
    }

    func testChromaSwiftFingerprinterDoesNotFabricateRowsForEmptyOrNonPCMChunks()
        async throws
    {
        let fingerprinter = ChromaSwiftAudioFingerprinter()
        let request = AudioFingerprintRequest(
            source: "https://example.test/live.m3u8",
            streamType: .hls,
            streamID: 11,
            runID: 22
        )

        let emptyResult = try await fingerprinter.fingerprint(
            DecodedAudioChunk(
                sequence: 1,
                audio: Data(),
                audioFormat: .linearPCM(sampleRate: 44_100, channelCount: 1, bitDepth: 16),
                startSeconds: 0,
                endSeconds: 0,
                startedAt: "2026-05-01T12:00:00Z"
            ),
            request: request
        )
        XCTAssertEqual(emptyResult, AudioFingerprintResult())

        let containerResult = try await fingerprinter.fingerprint(
            DecodedAudioChunk(
                sequence: 2,
                audio: Data([0x00, 0x01, 0x02]),
                audioFormat: .containerBytes,
                startSeconds: 0,
                endSeconds: 1,
                startedAt: "2026-05-01T12:00:00Z"
            ),
            request: request
        )
        XCTAssertEqual(containerResult, AudioFingerprintResult())
    }

    private static func sineChunk(sequence: Int, seconds: Double) -> DecodedAudioChunk {
        let sampleRate = 44_100
        let frameCount = Int(Double(sampleRate) * seconds)
        var data = Data()
        data.reserveCapacity(frameCount * MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let phase = 2.0 * Double.pi * 440.0 * Double(frame) / Double(sampleRate)
            let sample = Int16((sin(phase) * 16_000).rounded())
            var littleEndian = sample.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return DecodedAudioChunk(
            sequence: sequence,
            audio: data,
            audioFormat: .linearPCM(sampleRate: Double(sampleRate), channelCount: 1, bitDepth: 16),
            startSeconds: 30,
            endSeconds: 30 + seconds,
            startedAt: "2026-05-01T12:00:30Z",
            endedAt: "2026-05-01T12:00:42Z"
        )
    }
}
