import XCTest

@testable import SoundingKit

final class StreamAppViewModelTests: XCTestCase {
    func testValidateAddDraftAcceptsHLSAndRedactsSource() throws {
        let request = try StreamAppViewModel.validateAddDraft(
            StreamAppAddDraft(
                name: "  Morning News  ",
                source: "https://user:pass@example.test/private/live.m3u8?token=secret#frag",
                transport: .hls
            )
        )

        XCTAssertEqual(request.name, "Morning News")
        XCTAssertEqual(request.transport, .hls)
        XCTAssertEqual(request.registryStreamType, "hls")
        XCTAssertEqual(request.redactedSourceDescription, "https://example.test/private/live.m3u8")
        XCTAssertFalse(request.redactedSourceDescription.contains("user:pass"))
        XCTAssertFalse(request.redactedSourceDescription.contains("token=secret"))
    }

    func testValidateAddDraftAcceptsIcecastHTTPURL() throws {
        let request = try StreamAppViewModel.validateAddDraft(
            StreamAppAddDraft(
                name: "Community Radio",
                source: "http://radio.example.test:8000/live",
                transport: .icecast
            )
        )

        XCTAssertEqual(request.transport, .icecast)
        XCTAssertEqual(request.registryStreamType, "icy")
        XCTAssertEqual(request.redactedSourceDescription, "http://radio.example.test:8000/live")
    }

    func testValidateAddDraftRejectsEmptyMalformedAndDeferredTransports() throws {
        XCTAssertThrowsError(
            try StreamAppViewModel.validateAddDraft(
                StreamAppAddDraft(name: " ", source: "https://example.test/live.m3u8"))
        ) { error in
            XCTAssertEqual(error as? StreamAppValidationError, .emptyName)
        }

        XCTAssertThrowsError(
            try StreamAppViewModel.validateAddDraft(
                StreamAppAddDraft(name: "Main", source: "not a url"))
        ) { error in
            XCTAssertEqual(error as? StreamAppValidationError, .invalidURL)
        }

        XCTAssertThrowsError(
            try StreamAppViewModel.validateAddDraft(
                StreamAppAddDraft(name: "UDP", source: "udp://239.0.0.1:5000"))
        ) { error in
            XCTAssertEqual(error as? StreamAppValidationError, .unsupportedScheme("udp"))
        }

        XCTAssertThrowsError(try StreamAppViewModel.validateRegistryStreamType("udp")) { error in
            XCTAssertEqual(error as? StreamAppValidationError, .unsupportedTransport("udp"))
        }
    }

    func testStatusMappingProvidesUserFacingVocabulary() {
        XCTAssertEqual(StreamAppStatus.fromRegistryStatus(.active), .ready)
        XCTAssertEqual(StreamAppStatus.fromRegistryStatus(.paused), .paused)
        XCTAssertEqual(StreamAppStatus.fromRegistryStatus(.removed), .removed)

        XCTAssertEqual(StreamAppStatus.connecting.title, "Connecting")
        XCTAssertEqual(StreamAppStatus.running.detail, "Live ingest and playback are active.")
        XCTAssertEqual(
            StreamAppStatus.reconnecting(nextRetrySeconds: 12).detail, "Retrying in 12 seconds.")
        XCTAssertEqual(
            StreamAppStatus.reconnecting(nextRetrySeconds: nil).detail, "Retrying with backoff.")
        XCTAssertTrue(StreamAppStatus.ready.canStart)
        XCTAssertFalse(StreamAppStatus.running.canStart)
    }

    func testReloadAndAddStreamUseRegistryRowsForListAndSelection() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        var viewModel = StreamAppViewModel()

        try viewModel.reload(from: registry)
        XCTAssertEqual(viewModel.streams, [])
        XCTAssertNil(viewModel.selectedStreamID)
        XCTAssertEqual(viewModel.emptyStateTitle, "No streams yet")

        viewModel.addDraft = StreamAppAddDraft(
            name: "Fixture HLS",
            source: "https://example.test/live.m3u8?token=secret",
            transport: .hls
        )
        let item = try viewModel.addStream(using: registry)

        XCTAssertEqual(item.name, "Fixture HLS")
        XCTAssertEqual(item.transportLabel, "HLS")
        XCTAssertEqual(item.sourceDescription, "https://example.test/live.m3u8")
        XCTAssertEqual(item.status, .ready)
        XCTAssertEqual(viewModel.streams, [item])
        XCTAssertEqual(viewModel.selectedStreamID, item.id)
        XCTAssertEqual(viewModel.selectedStream?.controlsEnabled, true)
        XCTAssertEqual(viewModel.selectedStream?.canStartRuntime, true)
        XCTAssertEqual(viewModel.selectedStream?.playerStateTitle, "Runtime ready")

        let stored = try registry.list()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].streamType, "hls")
        XCTAssertEqual(stored[0].sourceDescription, "https://example.test/live.m3u8")
    }

    func testRuntimeEventsUpdateSelectedStatusAndControls() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        var viewModel = StreamAppViewModel()
        viewModel.addDraft = StreamAppAddDraft(
            name: "Fixture HLS",
            source: "https://user:pass@example.test/live.m3u8?token=secret",
            transport: .hls
        )
        let item = try viewModel.addStream(using: registry)

        viewModel.applyRuntimeEvent(
            AppStreamRuntimeEvent(
                streamID: item.id,
                phase: .running,
                message: "Running https://user:pass@example.test/live.m3u8?token=secret"
            )
        )

        XCTAssertEqual(viewModel.streams.first?.status, .running)
        XCTAssertEqual(viewModel.selectedStream?.playerStateTitle, "Runtime running")
        XCTAssertEqual(viewModel.selectedStream?.canPauseRuntime, true)
        XCTAssertEqual(viewModel.selectedStream?.canStopRuntime, true)
        XCTAssertFalse(viewModel.lastLifecycleMessage.contains("user:pass"))
        XCTAssertFalse(viewModel.lastLifecycleMessage.contains("token=secret"))
    }

    func testDuplicateNamesMapToActionableAddError() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        var viewModel = StreamAppViewModel()

        viewModel.addDraft = StreamAppAddDraft(
            name: "Main",
            source: "https://example.test/one.m3u8",
            transport: .hls
        )
        _ = try viewModel.addStream(using: registry)

        viewModel.addDraft = StreamAppAddDraft(
            name: "Main",
            source: "https://example.test/two.m3u8",
            transport: .hls
        )
        XCTAssertThrowsError(try viewModel.addStream(using: registry)) { error in
            XCTAssertEqual(error as? StreamAppValidationError, .duplicateName)
        }
        XCTAssertEqual(viewModel.addError, .duplicateName)
        XCTAssertEqual(viewModel.lastLifecycleMessage, "A stream with this name already exists.")
    }
}
