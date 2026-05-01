import Foundation
import XCTest
@testable import SoundingKit

final class ModelCacheTests: XCTestCase {
    func testPrepareDownloadsOnceThenReusesCacheWithRedactedProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            var events: [ModelCacheProgress] = []
            var downloads = 0

            func append(_ event: ModelCacheProgress) {
                lock.lock(); defer { lock.unlock() }
                events.append(event)
            }

            func incrementDownloads() {
                lock.lock(); defer { lock.unlock() }
                downloads += 1
            }
        }

        let recorder = Recorder()
        let cache = ModelCache(rootDirectory: root) { event in recorder.append(event) }
        let downloader: ModelCache.Downloader = { target, progress in
            recorder.incrementDownloads()
            progress(0.5)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return target
        }

        let first = try await cache.prepare(provider: "whisperkit", modelName: "tiny", downloader: downloader)
        let second = try await cache.prepare(provider: "whisperkit", modelName: "tiny", downloader: downloader)

        XCTAssertEqual(first, second)
        XCTAssertEqual(recorder.downloads, 1)
        XCTAssertEqual(recorder.events.map(\.event), [.downloadStarted, .downloadProgress, .downloadCompleted, .cacheHit])
        XCTAssertEqual(recorder.events.map(\.provider), ["whisperkit", "whisperkit", "whisperkit", "whisperkit"])
        XCTAssertEqual(recorder.events.map(\.model), ["tiny", "tiny", "tiny", "tiny"])
        let progressDescription = String(describing: recorder.events)
        XCTAssertFalse(progressDescription.contains(root.path), "progress must not expose raw cache paths")
    }

    func testInvalidModelNameThrowsModelSetupDiagnostic() async throws {
        let cache = ModelCache(rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))

        do {
            _ = try await cache.prepare(provider: "whisperkit", modelName: "../tiny", downloader: { target, _ in target })
            XCTFail("Expected invalid model name")
        } catch let error as ModelCacheError {
            XCTAssertEqual(error.ingestDiagnosticPhase, .modelSetup)
            XCTAssertEqual(error.ingestDiagnosticReason, "invalid-model-name")
            XCTAssertFalse(error.description.contains(".."), error.description)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloaderFailureIsRedactedAndClassifiedAsModelSetup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ModelCache(rootDirectory: root)

        do {
            _ = try await cache.prepare(provider: "fluidaudio", modelName: "offline-diarizer") { _, _ in
                throw NSError(
                    domain: "test",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey: "download failed token=secret at \(root.path)/model.bin password=hunter2"
                    ]
                )
            }
            XCTFail("Expected setup failure")
        } catch let error as ModelCacheError {
            XCTAssertEqual(error.ingestDiagnosticPhase, .modelSetup)
            XCTAssertEqual(error.ingestDiagnosticReason, "model-setup-failed")
            XCTAssertFalse(error.description.contains("secret"), error.description)
            XCTAssertFalse(error.description.contains("hunter2"), error.description)
            XCTAssertFalse(error.description.contains(root.path), error.description)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
