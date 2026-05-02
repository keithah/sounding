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
                message:
                    "Runtime failed for Retry HLS at /tmp/token=secret.raw for https://user:pass@example.test/retry.m3u8?token=secret#frag. Reconnecting in 5 second(s)."
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

    func testRuntimeLifecycleStatusProjectsSuspendedRecoveringAndRecoveredDetails() throws {
        let (first, _, viewModel) = try makeTwoStreamViewModel()
        var model = viewModel
        let secretReason =
            "system sleep for https://user:pass@example.test/private/live.m3u8?token=secret#frag at /Users/example/private/sleep.raw"

        model.applyRuntimeStatus(
            AppStreamRuntimeStatusSnapshot(
                streamID: first.id,
                name: first.name,
                streamType: "hls",
                sourceDescription: first.sourceDescription,
                phase: .suspended,
                attempt: 0,
                maxAttempts: 0,
                nextRetrySeconds: nil,
                nextRetryAt: nil,
                updatedAt: "2026-05-01T20:00:00Z",
                recentFailure: nil,
                lifecycleEvidence: AppStreamRuntimeLifecycleEvidence(
                    reason: secretReason,
                    suspendedAt: "2026-05-01T20:00:00Z"
                )
            )
        )

        var selected = try XCTUnwrap(model.selectedStream)
        XCTAssertEqual(selected.item.status, .suspended)
        XCTAssertEqual(selected.playerStateTitle, "Runtime suspended")
        XCTAssertTrue(selected.runtimeStatusDetail.contains("suspended for system sleep"))
        XCTAssertTrue(selected.runtimeStatusDetail.contains("reason:"), selected.runtimeStatusDetail)
        XCTAssertTrue(selected.runtimeStatusDetail.contains("suspended at 2026-05-01T20:00:00Z"))
        XCTAssertEqual(selected.runtimeIssue?.id, "runtime.suspended")
        XCTAssertEqual(selected.runtimeIssue?.severity, .info)
        XCTAssertEqual(selected.canStopRuntime, true)
        XCTAssertEqual(selected.canStartRuntime, false)
        assertNoRuntimeSecrets(String(describing: selected))

        model.applyRuntimeStatus(
            AppStreamRuntimeStatusSnapshot(
                streamID: first.id,
                name: first.name,
                streamType: "hls",
                sourceDescription: first.sourceDescription,
                phase: .recovering,
                attempt: 0,
                maxAttempts: 0,
                nextRetrySeconds: nil,
                nextRetryAt: nil,
                updatedAt: "2026-05-01T20:00:03Z",
                recentFailure: nil,
                lifecycleEvidence: AppStreamRuntimeLifecycleEvidence(
                    reason: secretReason,
                    suspendedAt: "2026-05-01T20:00:00Z",
                    recoveryStartedAt: "2026-05-01T20:00:03Z"
                )
            )
        )

        selected = try XCTUnwrap(model.selectedStream)
        XCTAssertEqual(selected.item.status, .recovering)
        XCTAssertEqual(selected.playerStateTitle, "Runtime recovering")
        XCTAssertTrue(selected.runtimeStatusDetail.contains("recovering after system wake"))
        XCTAssertTrue(
            selected.runtimeStatusDetail.contains("recovery started at 2026-05-01T20:00:03Z"),
            selected.runtimeStatusDetail)
        XCTAssertEqual(selected.runtimeIssue?.id, "runtime.recovering")
        XCTAssertEqual(selected.runtimeIssue?.severity, .warning)
        assertNoRuntimeSecrets(String(describing: selected))

        model.applyRuntimeStatus(
            AppStreamRuntimeStatusSnapshot(
                streamID: first.id,
                name: first.name,
                streamType: "hls",
                sourceDescription: first.sourceDescription,
                phase: .running,
                attempt: 0,
                maxAttempts: 0,
                nextRetrySeconds: nil,
                nextRetryAt: nil,
                updatedAt: "2026-05-01T20:00:05Z",
                recentFailure: nil,
                lifecycleEvidence: AppStreamRuntimeLifecycleEvidence(
                    reason: secretReason,
                    suspendedAt: "2026-05-01T20:00:00Z",
                    recoveryStartedAt: "2026-05-01T20:00:03Z",
                    recoveredAt: "2026-05-01T20:00:05Z",
                    recoveryLatencySeconds: 2.25
                )
            )
        )

        selected = try XCTUnwrap(model.selectedStream)
        XCTAssertEqual(selected.item.status, .running)
        XCTAssertEqual(selected.playerStateTitle, "Runtime running")
        XCTAssertTrue(selected.runtimeStatusDetail.contains("Live ingest and playback are active."))
        XCTAssertTrue(selected.runtimeStatusDetail.contains("recovered at 2026-05-01T20:00:05Z"))
        XCTAssertTrue(selected.runtimeStatusDetail.contains("recovery latency 2.250s"))
        XCTAssertNil(selected.runtimeIssue)
        assertNoRuntimeSecrets(String(describing: selected))
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
            state: .failed(
                message: "Audio device failed at /Users/example/private/device.raw?token=secret"),
            rollingBuffer: RollingBufferSnapshot(
                streamID: item.id,
                bufferedRange: RollingBufferRange(startSeconds: 0, endSeconds: 12),
                liveEdgeSeconds: 12,
                frameCount: 2,
                memoryFrameCount: 2,
                spillAvailable: false,
                memoryOnlyFallback: true,
                lastMessage:
                    "Rolling buffer spill failed at /Users/example/private/spill.pcm?token=secret"
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

    func testRuntimeStatusSnapshotProjectsReconnectBackoffAndUpdatedAt() throws {
        let (first, _, viewModel) = try makeTwoStreamViewModel()
        var model = viewModel

        model.applyRuntimeStatus(
            AppStreamRuntimeStatusSnapshot(
                streamID: first.id,
                name: first.name,
                streamType: "hls",
                sourceDescription: first.sourceDescription,
                phase: .reconnecting,
                attempt: 2,
                maxAttempts: 4,
                nextRetrySeconds: 8,
                nextRetryAt: "2026-05-01T20:00:08Z",
                updatedAt: "2026-05-01T20:00:00Z",
                recentFailure: AppStreamRuntimeRecentFailure(
                    message:
                        "Decoder failed for https://user:pass@example.test/live.m3u8?token=secret at /Users/example/private/chunk.ts",
                    occurredAt: "2026-05-01T19:59:59Z"
                )
            )
        )

        let selected = try XCTUnwrap(model.selectedStream)
        XCTAssertEqual(selected.item.status, .reconnecting(nextRetrySeconds: 8))
        XCTAssertEqual(
            selected.runtimeStatusDetail,
            "Retrying attempt 2 of 4 in 8 seconds (next retry 2026-05-01T20:00:08Z).")
        XCTAssertEqual(
            selected.runtimeRetryDetail,
            "Attempt 2 of 4 • next retry in 8s • at 2026-05-01T20:00:08Z")
        XCTAssertEqual(selected.runtimeUpdatedAtDetail, "Updated 2026-05-01T20:00:00Z")
        XCTAssertTrue(try XCTUnwrap(selected.runtimeRecentFailureDetail).contains("Recent failure"))
        XCTAssertEqual(selected.runtimeIssue?.id, "runtime.reconnecting")
        XCTAssertEqual(
            model.streams.first(where: { $0.id == first.id })?.runtimeStatusDetail,
            selected.runtimeStatusDetail)
        assertNoRuntimeSecrets(String(describing: selected))
    }

    func testRuntimeStatusSnapshotProjectsTerminalRedactedFailure() throws {
        let (first, _, viewModel) = try makeTwoStreamViewModel()
        var model = viewModel

        model.applyRuntimeStatus(
            AppStreamRuntimeStatusSnapshot(
                streamID: first.id,
                name: first.name,
                streamType: "hls",
                sourceDescription: first.sourceDescription,
                phase: .error,
                attempt: 3,
                maxAttempts: 3,
                nextRetrySeconds: nil,
                nextRetryAt: nil,
                updatedAt: "2026-05-01T20:00:03Z",
                recentFailure: AppStreamRuntimeRecentFailure(
                    message:
                        "Max retries hit for https://user:pass@example.test/live.m3u8?token=secret#frag in /tmp/private-output.wav",
                    occurredAt: "2026-05-01T20:00:03Z"
                )
            )
        )

        let selected = try XCTUnwrap(model.selectedStream)
        XCTAssertEqual(selected.item.status.title, "Error")
        XCTAssertEqual(selected.runtimeRetryDetail, "Attempt 3 of 3")
        XCTAssertEqual(selected.runtimeIssue?.severity, .blocking)
        XCTAssertTrue(
            selected.runtimeStatusDetail.contains("Max retries"), selected.runtimeStatusDetail)
        assertNoRuntimeSecrets(String(describing: selected))
    }

    func testRuntimeStatusSnapshotsRemainIsolatedAcrossSiblingStreams() throws {
        let (first, second, viewModel) = try makeTwoStreamViewModel()
        var model = viewModel

        model.applyRuntimeStatus(
            AppStreamRuntimeStatusSnapshot(
                streamID: first.id,
                name: first.name,
                streamType: "hls",
                sourceDescription: first.sourceDescription,
                phase: .running,
                attempt: 0,
                maxAttempts: 3,
                nextRetrySeconds: nil,
                nextRetryAt: nil,
                updatedAt: "2026-05-01T20:00:00Z",
                recentFailure: nil
            )
        )
        model.applyRuntimeStatus(
            AppStreamRuntimeStatusSnapshot(
                streamID: second.id,
                name: second.name,
                streamType: "icy",
                sourceDescription: second.sourceDescription,
                phase: .reconnecting,
                attempt: 1,
                maxAttempts: 3,
                nextRetrySeconds: 5,
                nextRetryAt: "2026-05-01T20:00:05Z",
                updatedAt: "2026-05-01T20:00:01Z",
                recentFailure: AppStreamRuntimeRecentFailure(
                    message: "Network timeout", occurredAt: "2026-05-01T20:00:01Z")
            )
        )

        XCTAssertEqual(model.streams.first(where: { $0.id == first.id })?.status, .running)
        XCTAssertEqual(
            model.streams.first(where: { $0.id == second.id })?.status,
            .reconnecting(nextRetrySeconds: 5))
        XCTAssertEqual(model.selectedStreamID, first.id)
        XCTAssertEqual(model.selectedStream?.item.status, .running)

        model.selectedStreamID = second.id
        XCTAssertEqual(
            model.selectedStream?.runtimeRetryDetail,
            "Attempt 1 of 3 • next retry in 5s • at 2026-05-01T20:00:05Z")
    }

    func testRuntimeStatusForRemovedOrUnselectedStreamDoesNotCrashAndIsCleared() throws {
        let (first, second, viewModel) = try makeTwoStreamViewModel()
        var model = viewModel

        model.applyRuntimeStatus(
            AppStreamRuntimeStatusSnapshot(
                streamID: 9_999,
                name: "Removed secret stream",
                streamType: "hls",
                sourceDescription: "https://user:pass@example.test/removed.m3u8?token=secret",
                phase: .error,
                attempt: 1,
                maxAttempts: 1,
                nextRetrySeconds: nil,
                nextRetryAt: nil,
                updatedAt: "2026-05-01T20:00:00Z",
                recentFailure: AppStreamRuntimeRecentFailure(
                    message: "Removed stream at /Users/example/private/db.sqlite",
                    occurredAt: "2026-05-01T20:00:00Z")
            )
        )
        XCTAssertNil(model.runtimeStatuses[9_999])
        XCTAssertEqual(model.selectedStreamID, first.id)
        XCTAssertNotNil(model.selectedStream)

        model.applyRuntimeStatuses([
            AppStreamRuntimeStatusSnapshot(
                streamID: second.id,
                name: second.name,
                streamType: "icy",
                sourceDescription: second.sourceDescription,
                phase: .paused,
                attempt: 0,
                maxAttempts: 3,
                nextRetrySeconds: nil,
                nextRetryAt: nil,
                updatedAt: "2026-05-01T20:00:02Z",
                recentFailure: nil
            )
        ])
        XCTAssertNil(model.runtimeStatuses[first.id])
        XCTAssertEqual(model.streams.first(where: { $0.id == second.id })?.status, .paused)
    }

    func testMalformedRuntimeStatusRendersRedactedIssueState() throws {
        let (first, _, viewModel) = try makeTwoStreamViewModel()
        var model = viewModel

        model.applyRuntimeStatus(
            AppStreamRuntimeStatusSnapshot(
                streamID: first.id,
                name: first.name,
                streamType: "hls",
                sourceDescription: first.sourceDescription,
                phase: .error,
                attempt: 0,
                maxAttempts: 0,
                nextRetrySeconds: nil,
                nextRetryAt: nil,
                updatedAt: "2026-05-01T20:00:00Z",
                recentFailure: AppStreamRuntimeRecentFailure(
                    message:
                        "Runtime status row contains an unsupported phase value. Clear or refresh the status row.",
                    occurredAt: "2026-05-01T20:00:00Z"
                )
            )
        )

        let selected = try XCTUnwrap(model.selectedStream)
        XCTAssertEqual(selected.item.status.title, "Error")
        XCTAssertEqual(selected.runtimeIssue?.id, "runtime.error")
        XCTAssertTrue(
            selected.runtimeStatusDetail.contains("unsupported phase"), selected.runtimeStatusDetail
        )
        assertNoRuntimeSecrets(String(describing: selected))
    }

    private func makeTwoStreamViewModel() throws -> (
        StreamAppListItem, StreamAppListItem, StreamAppViewModel
    ) {
        let temporary = try TemporarySoundingDatabase()
        let registry = StreamRegistry(database: temporary.database)
        var viewModel = StreamAppViewModel()
        viewModel.addDraft = StreamAppAddDraft(
            name: "Primary HLS",
            source: "https://user:pass@example.test/primary.m3u8?token=secret",
            transport: .hls
        )
        let first = try viewModel.addStream(using: registry)
        viewModel.addDraft = StreamAppAddDraft(
            name: "Sibling ICY",
            source: "https://listener:pass@example.test/sibling?api_key=secret",
            transport: .icecast
        )
        let second = try viewModel.addStream(using: registry)
        viewModel.selectedStreamID = first.id
        return (first, second, viewModel)
    }

    private func assertNoRuntimeSecrets(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for forbidden in [
            "user:pass",
            "listener:pass",
            "token=secret",
            "api_key=secret",
            "#frag",
            "/Users/example",
            "/tmp/private-output.wav",
        ] {
            XCTAssertFalse(
                text.contains(forbidden), "Expected redaction of \(forbidden), got: \(text)",
                file: file, line: line)
        }
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
        XCTAssertFalse(
            viewModel.lastLifecycleMessage.contains(rawPath), viewModel.lastLifecycleMessage)
        XCTAssertFalse(viewModel.configurationIssues[0].detail?.contains("user:pass") ?? true)
        XCTAssertFalse(viewModel.configurationIssues[0].detail?.contains("token=secret") ?? true)
        XCTAssertFalse(viewModel.configurationIssues[0].detail?.contains(rawPath) ?? true)
    }
}
