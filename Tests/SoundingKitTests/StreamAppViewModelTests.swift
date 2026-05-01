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


    func testRuntimeReconnectIssueProjectsLastRedactedMessageForVisibleStatus() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        var viewModel = StreamAppViewModel()
        viewModel.addDraft = StreamAppAddDraft(
            name: "Retry HLS",
            source: "https://user:pass@example.test/retry.m3u8?token=secret",
            transport: .hls
        )
        let item = try viewModel.addStream(using: registry)

        viewModel.applyRuntimeEvent(
            AppStreamRuntimeEvent(
                streamID: item.id,
                phase: .reconnecting(nextRetrySeconds: 5),
                message: "Runtime failed for Retry HLS at /tmp/token=secret.raw for https://user:pass@example.test/retry.m3u8?token=secret#frag. Reconnecting in 5 second(s)."
            )
        )

        let issue = try XCTUnwrap(viewModel.selectedStream?.runtimeIssue)
        XCTAssertEqual(issue.id, "runtime.reconnecting")
        XCTAssertEqual(issue.severity, .warning)
        XCTAssertTrue(issue.message.contains("Reconnecting in 5 second"), issue.message)
        XCTAssertFalse(issue.message.contains("user:pass"), issue.message)
        XCTAssertFalse(issue.message.contains("token=secret"), issue.message)
        XCTAssertFalse(issue.message.contains("/tmp/"), issue.message)
        XCTAssertTrue(issue.message.contains("[redacted-path]"), issue.message)
    }

    func testPlayerAndBufferIssuesProjectRedactedVisibleWarnings() {
        let item = StreamAppListItem(
            record: StreamRecord(
                id: 42,
                name: "Fixture HLS",
                streamType: "hls",
                sourceDescription: "https://example.test/live.m3u8",
                status: .active,
                createdAt: "2026-05-01T10:00:00Z",
                updatedAt: "2026-05-01T10:00:00Z",
                pausedAt: nil,
                resumedAt: nil,
                removedAt: nil
            )
        )
        let timeline = AppPlayerTimelineSnapshot(
            streamID: item.id,
            state: .failed(message: "Audio device failed at /Users/example/private/device.raw?token=secret"),
            rollingBuffer: RollingBufferSnapshot(
                streamID: item.id,
                bufferedRange: RollingBufferRange(startSeconds: 0, endSeconds: 12),
                liveEdgeSeconds: 12,
                frameCount: 2,
                memoryFrameCount: 2,
                spillAvailable: false,
                memoryOnlyFallback: true,
                lastMessage: "Rolling buffer spill failed at /Users/example/private/spill.pcm?token=secret"
            ),
            lastMessage: "Audio device failed at /Users/example/private/device.raw?token=secret"
        )

        let selected = StreamAppSelectedStream(item: item, timeline: timeline)

        let playerIssue = try! XCTUnwrap(selected.playerIssue)
        XCTAssertEqual(playerIssue.id, "player.failed")
        XCTAssertEqual(playerIssue.severity, .warning)
        XCTAssertFalse(playerIssue.message.contains("/Users/example"), playerIssue.message)
        XCTAssertFalse(playerIssue.message.contains("token=secret"), playerIssue.message)
        let bufferIssue = try! XCTUnwrap(selected.bufferIssue)
        XCTAssertEqual(bufferIssue.id, "buffer.memory-only-fallback")
        XCTAssertEqual(bufferIssue.severity, .warning)
        XCTAssertTrue(bufferIssue.message.contains("Rolling buffer"), bufferIssue.message)
        XCTAssertFalse(bufferIssue.message.contains("/Users/example"), bufferIssue.message)
        XCTAssertFalse(bufferIssue.message.contains("token=secret"), bufferIssue.message)
    }

    func testVisiblePlayerAndBufferIssuesClearAfterRecoverySnapshot() {
        let item = StreamAppListItem(
            record: StreamRecord(
                id: 43,
                name: "Recovered HLS",
                streamType: "hls",
                sourceDescription: "https://example.test/recovered.m3u8",
                status: .active,
                createdAt: "2026-05-01T10:00:00Z",
                updatedAt: "2026-05-01T10:00:00Z",
                pausedAt: nil,
                resumedAt: nil,
                removedAt: nil
            )
        )
        let recovered = AppPlayerTimelineSnapshot(
            streamID: item.id,
            state: .playing,
            positionSeconds: 5,
            liveEdgeSeconds: 10,
            rollingBuffer: RollingBufferSnapshot(
                streamID: item.id,
                bufferedRange: RollingBufferRange(startSeconds: 0, endSeconds: 10),
                liveEdgeSeconds: 10,
                frameCount: 2,
                memoryFrameCount: 1,
                spillFrameCount: 1,
                spillAvailable: true,
                memoryOnlyFallback: false,
                lastMessage: "Rolling buffer ready."
            ),
            lastMessage: "Playback resumed."
        )

        let selected = StreamAppSelectedStream(item: item, timeline: recovered)

        XCTAssertNil(selected.playerIssue)
        XCTAssertNil(selected.bufferIssue)
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

    func testConfigurationIssuesProjectRedactedBlockingStatusForSettingsAndRuntime() throws {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        var viewModel = StreamAppViewModel()
        try viewModel.reload(from: registry)
        let rawPath = "/Users/example/private/Sounding.sqlite"
        let rawSecretURL = "https://user:pass@example.test/config?token=secret#fragment"
        let issue = SoundingAppConfigurationIssue(
            id: "database.location-unavailable",
            severity: .blocking,
            phase: .startup,
            category: .database,
            message: "Database unavailable at \(rawPath)",
            detail: "Retry failed for \(rawSecretURL) and \(rawPath)",
            action: SoundingAppConfigurationAction(
                kind: .chooseDatabaseLocation,
                label: "Choose database location"
            )
        )
        let configuration = SoundingAppConfiguration(
            databaseURL: URL(fileURLWithPath: rawPath),
            whisperModelName: "tiny",
            rollingBuffer: .appDefault(),
            acoustIDKeyStatus: .present,
            issues: [issue]
        )

        viewModel.applyConfiguration(configuration)

        XCTAssertEqual(viewModel.configurationIssues, [issue])
        XCTAssertEqual(viewModel.blockingConfigurationIssues, [issue])
        XCTAssertEqual(viewModel.lastLifecycleMessage, issue.message)
        XCTAssertFalse(viewModel.lastLifecycleMessage.contains(rawPath), viewModel.lastLifecycleMessage)
        XCTAssertFalse(viewModel.configurationIssues[0].detail?.contains("user:pass") ?? true)
        XCTAssertFalse(viewModel.configurationIssues[0].detail?.contains("token=secret") ?? true)
        XCTAssertFalse(viewModel.configurationIssues[0].detail?.contains(rawPath) ?? true)
    }
}
