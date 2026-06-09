import Darwin
import Foundation
#if canImport(AppKit)
import AppKit
#endif

public struct SoundingAppRuntimeStartupState: Sendable {
    public var registry: StreamRegistry?
    public var runtime: (any AppStreamRuntimeControlling)?
    public var timelineStore: StreamAppTimelineStore?
    public var searchStore: StreamAppSearchStore?
    public var statusStore: AppStreamRuntimeStatusStore?
    public var viewModel: StreamAppViewModel
    public var persistenceError: String?
    public var configuration: SoundingAppConfiguration

    public init(
        registry: StreamRegistry?,
        runtime: (any AppStreamRuntimeControlling)?,
        timelineStore: StreamAppTimelineStore?,
        searchStore: StreamAppSearchStore?,
        statusStore: AppStreamRuntimeStatusStore?,
        viewModel: StreamAppViewModel,
        persistenceError: String?,
        configuration: SoundingAppConfiguration
    ) {
        self.registry = registry
        self.runtime = runtime
        self.timelineStore = timelineStore
        self.searchStore = searchStore
        self.statusStore = statusStore
        self.viewModel = viewModel
        self.persistenceError = persistenceError.map(IngestRedaction.redact)
        self.configuration = configuration
    }
}

public struct SoundingAppRuntimeFactory {
    public static let defaultHLSLivePlaybackLookaheadChunks = 6
    public static let defaultHLSLiveEmptyPollIntervalNanoseconds: UInt64 = 500_000_000

    public typealias DatabaseFactory = @Sendable (URL) throws -> SoundingDatabase
    public typealias IngesterFactory =
        @Sendable (
            SoundingDatabase,
            SoundingAppConfiguration,
            AppPlayerTimelineClock,
            RollingPCMBuffer,
            AudioArchiveStore,
            AppPlaybackVolumeStore,
            any AppPCMPlaybackAdapting,
            AppPlaybackStreamSelection
        ) throws -> any AppStreamRuntimeIngesting
    public typealias RuntimeFactory =
        @Sendable (
            StreamRegistry,
            any AppStreamRuntimeIngesting,
            AppPlayerTimelineClock,
            RollingPCMBuffer,
            AudioArchiveStore,
            AppStreamRuntimeStatusStore,
            AppPlaybackVolumeStore,
            any AppPCMPlaybackAdapting,
            AppPlaybackStreamSelection
        ) -> any AppStreamRuntimeControlling
    public typealias RuntimeStatusResetPolicy = @Sendable () -> Bool

    private let fileManager: FileManager
    private let databaseFactory: DatabaseFactory
    private let ingesterFactory: IngesterFactory
    private let runtimeFactory: RuntimeFactory
    private let runtimeStatusResetPolicy: RuntimeStatusResetPolicy

    public init(
        fileManager: FileManager = .default,
        databaseFactory: @escaping DatabaseFactory = { try SoundingDatabase(fileURL: $0) },
        ingesterFactory: @escaping IngesterFactory = {
            database, configuration, timeline, rollingBuffer, audioArchiveStore, volumeStore, player, playbackSelection in
            try SoundingAppRuntimeFactory.defaultIngesterFactory(
                database: database,
                configuration: configuration,
                timeline: timeline,
                rollingBuffer: rollingBuffer,
                audioArchiveStore: audioArchiveStore,
                volumeStore: volumeStore,
                player: player,
                playbackSelection: playbackSelection
            )
        },
        runtimeFactory: @escaping RuntimeFactory = {
            registry, ingester, timeline, rollingBuffer, audioArchiveStore, statusStore, volumeStore, player, playbackSelection in
            AppStreamRuntimeService(
                registry: registry,
                ingester: ingester,
                statusStore: statusStore,
                volumeStore: volumeStore,
                playbackTimeline: timeline,
                rollingBuffer: rollingBuffer,
                audioArchiveStore: audioArchiveStore,
                playbackController: player,
                playbackSelection: playbackSelection
            )
        },
        runtimeStatusResetPolicy: @escaping RuntimeStatusResetPolicy = {
            SoundingAppRuntimeFactory.shouldResetTransientStatusesOnStartup()
        }
    ) {
        self.fileManager = fileManager
        self.databaseFactory = databaseFactory
        self.ingesterFactory = ingesterFactory
        self.runtimeFactory = runtimeFactory
        self.runtimeStatusResetPolicy = runtimeStatusResetPolicy
    }

    public static func defaultAppStoragePreferences(
        fileManager: FileManager = .default
    ) -> SoundingAppPreferences {
        do {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = base.appendingPathComponent("Sounding", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return SoundingAppPreferences(
                databaseURL: directory.appendingPathComponent(
                    SoundingAppPreferences.defaultDatabaseFilename,
                    isDirectory: false
                )
            )
        } catch {
            return SoundingAppPreferences()
        }
    }

    public func makeStartupState(
        preferences: SoundingAppPreferences =
            SoundingAppRuntimeFactory.defaultAppStoragePreferences()
    ) -> SoundingAppRuntimeStartupState {
        var configuration = SoundingAppConfiguration.validated(
            preferences: preferences,
            fileManager: fileManager
        )
        if configuration.hasBlockingIssues {
            var viewModel = StreamAppViewModel()
            viewModel.applyConfiguration(configuration)
            return SoundingAppRuntimeStartupState(
                registry: nil,
                runtime: nil,
                timelineStore: nil,
                searchStore: nil,
                statusStore: nil,
                viewModel: viewModel,
                persistenceError: configuration.issues.first(where: { $0.blocksRuntime })?.message,
                configuration: configuration
            )
        }

        let database: SoundingDatabase
        do {
            database = try databaseFactory(configuration.databaseURL)
        } catch {
            configuration.issues.append(Self.databaseOpenIssue(error: error))
            var viewModel = StreamAppViewModel()
            viewModel.applyConfiguration(configuration)
            return SoundingAppRuntimeStartupState(
                registry: nil,
                runtime: nil,
                timelineStore: nil,
                searchStore: nil,
                statusStore: nil,
                viewModel: viewModel,
                persistenceError: configuration.issues.last?.message,
                configuration: configuration
            )
        }

        let registry = StreamRegistry(database: database)
        let timelineStore = StreamAppTimelineStore(database: database)
        let searchStore = StreamAppSearchStore(database: database)
        let statusStore = AppStreamRuntimeStatusStore(database: database)
        if runtimeStatusResetPolicy() {
            do {
                try statusStore.resetTransientStatuses(
                    updatedAt: SoundingTimestampClock.timestamp())
            } catch {
                configuration.issues.append(Self.databaseOpenIssue(error: error))
            }
        }
        let timeline = AppPlayerTimelineClock()
        let rollingBuffer = RollingPCMBuffer(configuration: configuration.rollingBuffer)
        let audioArchiveStore = AudioArchiveStore(
            database: database,
            archiveDirectory: configuration.audioArchiveDirectory,
            maximumBytes: configuration.audioArchiveMaximumBytes,
            retentionSeconds: configuration.audioArchiveDefaultRetentionSeconds
        )
        let volumeStore = AppPlaybackVolumeStore()
        let diagnosticsLog = AppRuntimeDiagnosticsLog()
        let playbackSelection = AppPlaybackStreamSelection()
        let player = AVFoundationAppPCMPlayerAdapter(
            volumeStore: volumeStore,
            diagnosticsLog: diagnosticsLog
        )

        let ingester: any AppStreamRuntimeIngesting
        do {
            ingester = try ingesterFactory(
                database, configuration, timeline, rollingBuffer, audioArchiveStore, volumeStore, player,
                playbackSelection)
        } catch {
            configuration.issues.append(Self.modelSetupIssue(error: error))
            var viewModel = StreamAppViewModel()
            viewModel.applyConfiguration(configuration)
            return SoundingAppRuntimeStartupState(
                registry: registry,
                runtime: nil,
                timelineStore: timelineStore,
                searchStore: searchStore,
                statusStore: statusStore,
                viewModel: viewModel,
                persistenceError: configuration.issues.last?.message,
                configuration: configuration
            )
        }

        let runtime = runtimeFactory(
            registry, ingester, timeline, rollingBuffer, audioArchiveStore, statusStore, volumeStore, player,
            playbackSelection)
        var viewModel = StreamAppViewModel(configurationIssues: configuration.issues)
        do {
            try viewModel.reload(from: registry)
            if configuration.issues.isEmpty == false {
                viewModel.applyConfiguration(configuration)
            }
            return SoundingAppRuntimeStartupState(
                registry: registry,
                runtime: runtime,
                timelineStore: timelineStore,
                searchStore: searchStore,
                statusStore: statusStore,
                viewModel: viewModel,
                persistenceError: nil,
                configuration: configuration
            )
        } catch {
            configuration.issues.append(Self.databaseOpenIssue(error: error))
            var failedViewModel = StreamAppViewModel(configurationIssues: configuration.issues)
            failedViewModel.applyConfiguration(configuration)
            return SoundingAppRuntimeStartupState(
                registry: nil,
                runtime: nil,
                timelineStore: nil,
                searchStore: nil,
                statusStore: nil,
                viewModel: failedViewModel,
                persistenceError: configuration.issues.last?.message,
                configuration: configuration
            )
        }
    }

    public static func defaultIngesterFactory(
        database: SoundingDatabase,
        configuration: SoundingAppConfiguration,
        timeline: AppPlayerTimelineClock,
        rollingBuffer: RollingPCMBuffer,
        audioArchiveStore: AudioArchiveStore,
        volumeStore: AppPlaybackVolumeStore,
        player: any AppPCMPlaybackAdapting,
        playbackSelection: AppPlaybackStreamSelection? = nil
    ) throws -> any AppStreamRuntimeIngesting {
        let queue = InferenceQueue()
        let cache = ModelCache()
        return StreamIngestAppRuntimeRunner(
            database: database,
            decoder: AVFoundationAudioDecoder(),
            transcriber: QueuedTranscriber(
                WhisperKitTranscriber(modelName: configuration.whisperModelName, cache: cache),
                queue: queue
            ),
            diarizer: NoOpSpeakerDiarizer(),
            fingerprinter: defaultAudioFingerprinter(),
            fingerprintEnricher: defaultFingerprintEnricher(database: database),
            player: player,
            timeline: timeline,
            rollingBuffer: rollingBuffer,
            playbackSelection: playbackSelection,
            audioArchiveStore: audioArchiveStore,
            ingestMode: .livePolling(maxChunksPerPass: defaultHLSLivePlaybackLookaheadChunks),
            hlsEmptyPollIntervalNanoseconds: defaultHLSLiveEmptyPollIntervalNanoseconds,
            diarizerFactory: { isEnabled in
                QueuedDiarizer(
                    isEnabled || ProcessInfo.processInfo.environment["SOUNDING_ENABLE_FLUIDAUDIO"] == "1"
                        ? FluidAudioDiarizer(cache: cache)
                        : NoOpSpeakerDiarizer(),
                    queue: queue
                )
            }
        )
    }

    static func defaultAudioFingerprinter(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any AudioFingerprinting {
        environment["SOUNDING_DETERMINISTIC_FINGERPRINT"] == "1"
            ? DeterministicAudioFingerprinter()
            : ChromaSwiftAudioFingerprinter()
    }

    static func defaultFingerprintEnricher(
        database: SoundingDatabase,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any AudioFingerprintEnriching {
        let key = environment["SOUNDING_ACOUSTID_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            return NoOpAudioFingerprintEnricher()
        }
        return AcoustIDAudioFingerprintEnricher(
            cache: AcoustIDLookupCache(database: database),
            lookup: AcoustIDHTTPClientLookup(clientKey: key)
        )
    }

    public static func shouldResetTransientStatusesOnStartup(
        processList: String? = nil,
        currentProcessID: Int32 = getpid()
    ) -> Bool {
        guard let processList else {
            return shouldResetTransientStatusesForRunningApplications(
                currentProcessID: currentProcessID)
        }
        let listing = processList
        let appExecutableSuffix = "/Sounding.app/Contents/MacOS/Sounding"
        let otherAppProcessExists = listing.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains(appExecutableSuffix) else { return false }
            let pidText = trimmed.split(separator: " ", maxSplits: 1).first ?? ""
            return Int32(pidText) != currentProcessID
        }
        return !otherAppProcessExists
    }

    private static func shouldResetTransientStatusesForRunningApplications(
        currentProcessID: Int32
    ) -> Bool {
        #if canImport(AppKit)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.sounding.Sounding"
        let matchingApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier)
        let siblingAppExists = matchingApps.contains { application in
            application.processIdentifier != currentProcessID
        }
        return !siblingAppExists
        #else
        return true
        #endif
    }

    private static func databaseOpenIssue(error: any Error) -> SoundingAppConfigurationIssue {
        SoundingAppConfigurationIssue(
            id: "database.open-failed",
            severity: .blocking,
            phase: .startup,
            category: .database,
            message:
                "Choose a writable Sounding database location before starting the app runtime.",
            detail: "Database open or migration failed: \(String(describing: error))",
            action: SoundingAppConfigurationAction(
                kind: .chooseDatabaseLocation,
                label: "Choose database location"
            )
        )
    }

    private static func modelSetupIssue(error: any Error) -> SoundingAppConfigurationIssue {
        SoundingAppConfigurationIssue(
            id: "model.setup-failed",
            severity: .blocking,
            phase: .startup,
            category: .model,
            message: "Choose a valid Whisper model before starting transcription.",
            detail: "Model setup failed: \(String(describing: error))",
            action: SoundingAppConfigurationAction(
                kind: .chooseWhisperModel,
                label: "Choose Whisper model"
            )
        )
    }
}
