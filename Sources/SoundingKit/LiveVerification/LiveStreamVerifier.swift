import Foundation

/// SoundingKit-owned executor for live stream verification.
public struct LiveStreamVerifier: Sendable {
    public init() {}

    /// Runs every stream sequentially to preserve deterministic evidence ordering.
    public func verify(config: LiveStreamVerificationConfig) async -> LiveStreamVerificationSummary {
        let results = await verify(streams: config.streams)
        return LiveStreamVerificationSummary(results: results)
    }

    /// Runs stream specs sequentially to preserve deterministic evidence ordering.
    public func verify(streams: [LiveStreamSpec]) async -> [LiveStreamVerificationResult] {
        var results = [LiveStreamVerificationResult]()
        results.reserveCapacity(streams.count)

        for stream in streams {
            results.append(await verify(stream: stream))
        }

        return results
    }

    /// Encodes evidence as one pretty-printed JSON summary document.
    public func encodeSummaryJSON(_ summary: LiveStreamVerificationSummary) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(summary)
        } catch {
            throw LiveStreamVerificationError.outputFailed(String(describing: error))
        }
    }

    /// Encodes evidence as newline-delimited JSON, one per-stream result per line.
    public func encodeResultsNDJSON(_ results: [LiveStreamVerificationResult]) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var lines = [String]()
            lines.reserveCapacity(results.count)

            for result in results {
                let data = try encoder.encode(result)
                guard let line = String(data: data, encoding: .utf8) else {
                    throw LiveStreamVerificationError.outputFailed("encoded live verification evidence was not valid UTF-8")
                }
                lines.append(line)
            }

            return Data((lines.joined(separator: "\n") + "\n").utf8)
        } catch let error as LiveStreamVerificationError {
            throw error
        } catch {
            throw LiveStreamVerificationError.outputFailed(String(describing: error))
        }
    }

    private func verify(stream: LiveStreamSpec) async -> LiveStreamVerificationResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let redactedSource = MonitorError.redactedSourceDescription(stream.source)
        let resolvedStreamType = MonitorPipeline.resolvedStreamType(
            for: stream.source,
            requested: stream.streamType
        )

        do {
            guard stream.minimumMarkers >= 0 else {
                throw LiveStreamVerificationError.configurationFailed("minimumMarkers must be non-negative for stream id '\(stream.id)'")
            }

            let options = try MonitorOptions(
                source: stream.source,
                streamType: stream.streamType,
                filter: stream.filter,
                timeoutSeconds: stream.timeoutSeconds
            )
            let markers = try await MonitorPipeline.run(options: options)
            let markerCount = markers.count
            let category: LiveStreamVerificationCategory = markerCount >= stream.minimumMarkers
                ? .passed
                : .noMarkersObserved

            return result(
                for: stream,
                redactedSource: redactedSource,
                resolvedStreamType: resolvedStreamType,
                category: category,
                markerCount: markerCount,
                started: started
            )
        } catch let error as MonitorError {
            return result(
                for: stream,
                redactedSource: redactedSource,
                resolvedStreamType: resolvedStreamType,
                category: category(for: error, stream: stream, resolvedStreamType: resolvedStreamType),
                markerCount: 0,
                started: started,
                diagnostic: diagnostic(for: error)
            )
        } catch let error as LiveStreamVerificationError {
            return result(
                for: stream,
                redactedSource: redactedSource,
                resolvedStreamType: resolvedStreamType,
                category: .configurationFailure,
                markerCount: 0,
                started: started,
                diagnostic: LiveStreamVerificationDiagnostic(message: error.description)
            )
        } catch {
            return result(
                for: stream,
                redactedSource: redactedSource,
                resolvedStreamType: resolvedStreamType,
                category: .parserAdapterRegression,
                markerCount: 0,
                started: started,
                diagnostic: LiveStreamVerificationDiagnostic(message: MonitorError.redactedSourceDescription(String(describing: error)))
            )
        }
    }

    private func result(
        for stream: LiveStreamSpec,
        redactedSource: String,
        resolvedStreamType: StreamType,
        category: LiveStreamVerificationCategory,
        markerCount: Int,
        started: UInt64,
        diagnostic: LiveStreamVerificationDiagnostic? = nil
    ) -> LiveStreamVerificationResult {
        LiveStreamVerificationResult(
            id: stream.id,
            redactedSource: redactedSource,
            streamType: stream.streamType,
            resolvedStreamType: resolvedStreamType,
            filter: stream.filter,
            timeoutSeconds: stream.timeoutSeconds,
            minimumMarkers: stream.minimumMarkers,
            required: stream.required,
            category: category,
            markerCount: markerCount,
            durationMilliseconds: durationMilliseconds(since: started),
            diagnostic: diagnostic
        )
    }

    private func durationMilliseconds(since started: UInt64) -> Int {
        let ended = DispatchTime.now().uptimeNanoseconds
        let elapsed = ended >= started ? ended - started : 0
        let milliseconds = elapsed / 1_000_000
        return Int(min(milliseconds, UInt64(Int.max)))
    }

    private func category(
        for error: MonitorError,
        stream: LiveStreamSpec,
        resolvedStreamType: StreamType
    ) -> LiveStreamVerificationCategory {
        switch error {
        case .invalidTimeout, .invalidFilter:
            return .configurationFailure
        case let .notImplemented(phase, _, streamType):
            if phase == .sourceOpen && streamType == .udp {
                return .unsupportedOrSkipped
            }
            return .parserAdapterRegression
        case let .operationFailed(phase, _, _, context, reason):
            if isTimeout(context: context, reason: reason) {
                return .timeout
            }
            if isUnsupportedLiveUDP(stream: stream, resolvedStreamType: resolvedStreamType, phase: phase, reason: reason) {
                return .unsupportedOrSkipped
            }
            switch phase {
            case .sourceOpen:
                return .streamUnavailable
            case .ingest, .decode:
                return .parserAdapterRegression
            case .configuration:
                return .configurationFailure
            case .output:
                return .parserAdapterRegression
            }
        }
    }

    private func isTimeout(context: [String: String], reason: String) -> Bool {
        context["timeoutSeconds"] != nil || reason.localizedCaseInsensitiveContains("timed out")
    }

    private func isUnsupportedLiveUDP(
        stream: LiveStreamSpec,
        resolvedStreamType: StreamType,
        phase: MonitorPhase,
        reason: String
    ) -> Bool {
        guard phase == .sourceOpen, resolvedStreamType == .udp || stream.streamType == .udp else {
            return false
        }
        guard URLComponents(string: stream.source)?.scheme?.lowercased() == "udp" else {
            return false
        }
        return reason.localizedCaseInsensitiveContains("unsupported")
    }

    private func diagnostic(for error: MonitorError) -> LiveStreamVerificationDiagnostic {
        switch error {
        case let .invalidTimeout(_, _, streamType):
            return LiveStreamVerificationDiagnostic(
                phase: MonitorPhase.configuration.rawValue,
                streamType: streamType.rawValue,
                message: error.description
            )
        case .invalidFilter:
            return LiveStreamVerificationDiagnostic(
                phase: MonitorPhase.configuration.rawValue,
                message: error.description
            )
        case let .notImplemented(phase, _, streamType):
            return LiveStreamVerificationDiagnostic(
                phase: phase.rawValue,
                streamType: streamType.rawValue,
                message: error.description
            )
        case let .operationFailed(phase, _, streamType, context, _):
            let sanitizedContext = sanitizedDiagnosticContext(context)
            return LiveStreamVerificationDiagnostic(
                phase: phase.rawValue,
                streamType: streamType.rawValue,
                sourceClass: sanitizedContext["sourceClass"],
                message: error.description,
                context: sanitizedContext
            )
        }
    }

    private func sanitizedDiagnosticContext(_ context: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: context.map { key, value in
            (key, sanitizedDiagnosticContextValue(value, forKey: key))
        })
    }

    private func sanitizedDiagnosticContextValue(_ value: String, forKey key: String) -> String {
        switch key {
        case "outputPath", "jsonOut", "path":
            return "[redacted]"
        case "source", "segmentURI", "manifestURI", "url", "uri":
            return MonitorError.redactedSourceDescription(value)
        default:
            return MonitorError.redactedSourceDescription(value)
        }
    }
}
