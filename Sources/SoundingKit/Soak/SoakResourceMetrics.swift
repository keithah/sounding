import Foundation

public struct SoakResourceMetrics: Equatable, Sendable {
    public var memoryBytes: Int64?
    public var cpuPercent: Double?
    public var openFileDescriptorCount: Int?
    public var note: String?

    public init(
        memoryBytes: Int64? = nil,
        cpuPercent: Double? = nil,
        openFileDescriptorCount: Int? = nil,
        note: String? = nil
    ) {
        self.memoryBytes = memoryBytes.map { max(0, $0) }
        self.cpuPercent = cpuPercent.map(SoakEvidenceSanitizer.nonNegative)
        self.openFileDescriptorCount = openFileDescriptorCount.map { max(0, $0) }
        self.note = note
    }
}

public protocol SoakResourceMetricsProvider: Sendable {
    func sample(at: String) async throws -> SoakResourceMetrics
}

public struct ProcessSoakResourceMetricsProvider: SoakResourceMetricsProvider {
    public init() {}

    public func sample(at _: String) async throws -> SoakResourceMetrics {
        SoakResourceMetrics(
            memoryBytes: Self.residentMemoryBytes(),
            cpuPercent: nil,
            openFileDescriptorCount: Self.openFileDescriptorCount(),
            note: "process resource counters"
        )
    }

    private static func residentMemoryBytes() -> Int64? {
        #if os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.resident_size)
        #else
        return nil
        #endif
    }

    private static func openFileDescriptorCount() -> Int? {
        #if os(macOS) || os(Linux)
        let path = "/dev/fd"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return entries.count
        #else
        return nil
        #endif
    }
}

public struct ClosureSoakResourceMetricsProvider: SoakResourceMetricsProvider {
    private let body: @Sendable (String) async throws -> SoakResourceMetrics

    public init(_ body: @escaping @Sendable (String) async throws -> SoakResourceMetrics) {
        self.body = body
    }

    public func sample(at: String) async throws -> SoakResourceMetrics {
        try await body(at)
    }
}
