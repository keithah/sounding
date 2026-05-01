import Foundation

public struct SoundingAppRuntimeStartupState: Sendable {
    public var registry: StreamRegistry?
    public var runtime: (any AppStreamRuntimeControlling)?
    public var timelineStore: StreamAppTimelineStore?
    public var searchStore: StreamAppSearchStore?
    public var viewModel: StreamAppViewModel
    public var persistenceError: String?
    public var configuration: SoundingAppConfiguration

    public init(
        registry: StreamRegistry?,
        runtime: (any AppStreamRuntimeControlling)?,
        timelineStore: StreamAppTimelineStore?,
        searchStore: StreamAppSearchStore?,
        viewModel: StreamAppViewModel,
        persistenceError: String?,
        configuration: SoundingAppConfiguration
    ) {
        self.registry = registry
        self.runtime = runtime
        self.timelineStore = timelineStore
        self.searchStore = searchStore
        self.viewModel = viewModel
        self.persistenceError = persistenceError.map(IngestRedaction.redact)
        self.configuration = configuration
    }
}

public struct SoundingAppRuntimeFactory {
    public typealias DatabaseFactory = @Sendable (URL) throws -> SoundingDatabase
    public typealias IngesterFactory = @Sendable (
        SoundingDatabase,
        SoundingAppConfiguration,
        AppPlayerTimelineClock,
        RollingPCMBuffer
    ) throws -> any AppStreamRuntimeIngesting
    public typealias RuntimeFactory = @Sendable (
        StreamRegistry,
        any AppStreamRuntimeIngesting,
        AppPlayerTimelineClock,
        RollingPCMBuffer
    ) -> any AppStreamRuntimeControlling

    private let fileManager: FileManager
    private let databaseFactory: DatabaseFactory
    private let ingesterFactory: IngesterFactory
    private let runtimeFactory: RuntimeFactory

    public init(
        fileManager: FileManager = .default,
        databaseFactory: @escaping DatabaseFactory = { try SoundingDatabase(fileURL: $0) },
        ingesterFactory: @escaping IngesterFactory = { database, configuration, timeline, rollingBuffer in
            try SoundingAppRuntimeFactory.defaultIngesterFactory(
                database: database,
                configuration: configuration,
                timeline: timeline,
                rollingBuffer: rollingBuffer
            )
        },
        runtimeFactory: @escaping RuntimeFactory = { registry, ingester, timeline, rollingBuffer in
            AppStreamRuntimeService(
                registry: registry,
                ingester: ingester,
                playbackTimeline: timeline,
                rollingBuffer: rollingBuffer
            )
        }
    ) {
        self.fileManager = fileManager
        self.databaseFactory = databaseFactory
        self.ingesterFactory = ingesterFactory
        self.runtimeFactory = runtimeFactory
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
        preferences: SoundingAppPreferences = SoundingAppRuntimeFactory.defaultAppStoragePreferences()
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
                viewModel: viewModel,
                persistenceError: configuration.issues.last?.message,
                configuration: configuration
            )
        }

        let registry = StreamRegistry(database: database)
        let timelineStore = StreamAppTimelineStore(database: database)
        let searchStore = StreamAppSearchStore(database: database)
        let timeline = AppPlayerTimelineClock()
        let rollingBuffer = RollingPCMBuffer(configuration: configuration.rollingBuffer)

        let ingester: any AppStreamRuntimeIngesting
        do {
            ingester = try ingesterFactory(database, configuration, timeline, rollingBuffer)
        } catch {
            configuration.issues.append(Self.modelSetupIssue(error: error))
            var viewModel = StreamAppViewModel()
            viewModel.applyConfiguration(configuration)
            return SoundingAppRuntimeStartupState(
                registry: registry,
                runtime: nil,
                timelineStore: timelineStore,
                searchStore: searchStore,
                viewModel: viewModel,
                persistenceError: configuration.issues.last?.message,
                configuration: configuration
            )
        }

        let runtime = runtimeFactory(registry, ingester, timeline, rollingBuffer)
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
        rollingBuffer: RollingPCMBuffer
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
            diarizer: QueuedDiarizer(
                FluidAudioDiarizer(cache: cache),
                queue: queue
            ),
            fingerprinter: NoOpAudioFingerprinter(),
            fingerprintEnricher: NoOpAudioFingerprintEnricher(),
            player: AVFoundationAppPCMPlayerAdapter(),
            timeline: timeline,
            rollingBuffer: rollingBuffer
        )
    }

    private static func databaseOpenIssue(error: any Error) -> SoundingAppConfigurationIssue {
        SoundingAppConfigurationIssue(
            id: "database.open-failed",
            severity: .blocking,
            phase: .startup,
            category: .database,
            message: "Choose a writable Sounding database location before starting the app runtime.",
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
