import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cross-platform async bridge for URLSession byte loads.
///
/// Swift's async `URLSession.data(from:)` availability differs between Darwin and
/// Linux FoundationNetworking versions. Keeping the bridge in one place lets HLS
/// manifest and segment loading use the same URLSession-backed path in tests and
/// production without platform-specific call sites.
enum HLSURLSessionDataLoader {
    static func data(from url: URL, using session: URLSession) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url), using: session)
    }

    static func data(for request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        let state = HLSURLSessionDataLoadState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        state.finish(.failure(error))
                        return
                    }

                    guard let data, let response else {
                        state.finish(.failure(HLSSessionDataLoaderError.missingResponse))
                        return
                    }

                    state.finish(.success((data, response)))
                }
                state.setTask(task)
                task.resume()
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class HLSURLSessionDataLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionDataTask?
    private var isFinished = false
    private var isCancelled = false

    func install(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        if isFinished || isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        lock.unlock()
    }

    func setTask(_ task: URLSessionDataTask) {
        lock.lock()
        if isFinished {
            lock.unlock()
            task.cancel()
            return
        }

        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func finish(_ result: Result<(Data, URLResponse), Error>) {
        let continuation = takeContinuation(markCancelled: false)
        guard let continuation else { return }

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        let task: URLSessionDataTask?
        let continuation: CheckedContinuation<(Data, URLResponse), Error>?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }

        isCancelled = true
        task = self.task
        if let installedContinuation = self.continuation {
            isFinished = true
            self.continuation = nil
            self.task = nil
            continuation = installedContinuation
        } else {
            continuation = nil
        }
        lock.unlock()

        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func takeContinuation(markCancelled: Bool) -> CheckedContinuation<(Data, URLResponse), Error>? {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return nil
        }

        isFinished = true
        if markCancelled {
            isCancelled = true
        }
        let continuation = self.continuation
        self.continuation = nil
        task = nil
        lock.unlock()
        return continuation
    }
}

private enum HLSSessionDataLoaderError: Error, CustomStringConvertible, Sendable {
    case missingResponse

    var description: String {
        "URLSession data load completed without response bytes."
    }
}
