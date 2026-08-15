import Foundation

/// Provider protocol for volume available capacity, enabling deterministic test injection.
public protocol DiskCapacityProviding: Sendable {
    func availableCapacity(for url: URL) -> Int64?
}

/// macOS native capacity provider using URLResourceValues and volumeAvailableCapacityForImportantUsage.
public struct SystemDiskCapacityProvider: DiskCapacityProviding {
    public init() {}

    public func availableCapacity(for url: URL) -> Int64? {
        let checkURL = StorageHealthService.resolveVolumeURL(for: url)

        // Primary: volumeAvailableCapacityForImportantUsage (macOS 10.13+)
        if let values = try? checkURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            if let regular = values.volumeAvailableCapacity, regular > 0 {
                return Int64(regular)
            }
        }

        // Fallback: attributesOfFileSystem
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: checkURL.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }

        return nil
    }
}

/// Status result of a storage preflight health check.
public enum StorageHealthStatus: Equatable, Sendable {
    case healthy(availableBytes: Int64)
    case warning(availableBytes: Int64, requiredBytes: Int64?, message: String)
    case critical(availableBytes: Int64, requiredBytes: Int64?, message: String)
    case unknown

    public var isBlocked: Bool {
        if case .critical = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .healthy, .unknown:
            return nil
        case .warning(_, _, let msg), .critical(_, _, let msg):
            return msg
        }
    }
}

/// Kind of operation requiring storage space.
public enum StorageOperationKind: Equatable, Sendable {
    case videoGeneration(expectedTakes: Int)
    case modelDownload(expectedBytes: Int64?)
    case finalAssembly(sourceFileBytes: Int64?)
    case generic
}

/// Centralized preflight storage health checker.
/// Verifies destination volume capacity before heavy operations (rendering, model downloading, assembly)
/// to prevent out-of-disk failures without deleting any user data.
public final class StorageHealthService: Sendable {
    public static let shared = StorageHealthService()

    private let capacityProvider: any DiskCapacityProviding

    // Thresholds
    public static let genericWarningThreshold: Int64 = 10 * 1024 * 1024 * 1024 // 10 GB
    public static let genericCriticalThreshold: Int64 = 500 * 1024 * 1024       // 500 MB
    public static let defaultSafetyReserve: Int64 = 300 * 1024 * 1024           // 300 MB

    // Per-take video estimate (output MP4 + temp frames + metadata overhead)
    public static let estimatedBytesPerTake: Int64 = 150 * 1024 * 1024          // 150 MB

    public init(capacityProvider: (any DiskCapacityProviding)? = nil) {
        self.capacityProvider = capacityProvider ?? SystemDiskCapacityProvider()
    }

    /// Evaluates storage health for a specific target URL and operation.
    public func check(url: URL, for kind: StorageOperationKind = .generic) -> StorageHealthStatus {
        guard let available = capacityProvider.availableCapacity(for: url) else {
            return .unknown
        }

        switch kind {
        case .videoGeneration(let expectedTakes):
            let count = max(1, expectedTakes)
            let estimatedRequired = Int64(count) * Self.estimatedBytesPerTake
            let needed = estimatedRequired + Self.defaultSafetyReserve

            if available < needed || available < Self.genericCriticalThreshold {
                let availStr = Self.formatBytes(available)
                let reqStr = Self.formatBytes(estimatedRequired)
                let message = "Not enough disk space for video generation. Available: \(availStr), estimated needed: \(reqStr)."
                return .critical(availableBytes: available, requiredBytes: estimatedRequired, message: message)
            }

            if available < Self.genericWarningThreshold {
                let availStr = Self.formatBytes(available)
                let message = "Low disk space on output drive (\(availStr) available). Generation may fail if disk space runs out."
                return .warning(availableBytes: available, requiredBytes: estimatedRequired, message: message)
            }

            return .healthy(availableBytes: available)

        case .modelDownload(let expectedBytes):
            if let expected = expectedBytes, expected > 0 {
                let safetyReserve: Int64 = 500 * 1024 * 1024 // 500 MB
                let needed = expected + safetyReserve

                if available < needed {
                    let availStr = Self.formatBytes(available)
                    let reqStr = Self.formatBytes(expected)
                    let message = "Not enough disk space for model download. Available: \(availStr), required: \(reqStr)."
                    return .critical(availableBytes: available, requiredBytes: expected, message: message)
                }

                if available < needed + (2 * 1024 * 1024 * 1024) {
                    let availStr = Self.formatBytes(available)
                    let message = "Low disk space on model cache drive (\(availStr) available)."
                    return .warning(availableBytes: available, requiredBytes: expected, message: message)
                }

                return .healthy(availableBytes: available)
            } else {
                // Unknown model download size
                if available < 1 * 1024 * 1024 * 1024 { // 1 GB
                    let availStr = Self.formatBytes(available)
                    let message = "Critically low disk space on model drive (\(availStr) available)."
                    return .critical(availableBytes: available, requiredBytes: nil, message: message)
                }

                if available < 10 * 1024 * 1024 * 1024 { // 10 GB
                    let availStr = Self.formatBytes(available)
                    let message = "Low disk space on model drive (\(availStr) available)."
                    return .warning(availableBytes: available, requiredBytes: nil, message: message)
                }

                return .healthy(availableBytes: available)
            }

        case .finalAssembly(let sourceFileBytes):
            if let sourceBytes = sourceFileBytes, sourceBytes > 0 {
                // Assembly needs working space for temp re-encoded takes + concatenated output
                let estimatedWorking = max(10 * 1024 * 1024, sourceBytes * 2)
                let safetyReserve: Int64 = 200 * 1024 * 1024 // 200 MB
                let needed = estimatedWorking + safetyReserve

                if available < needed || available < 300 * 1024 * 1024 {
                    let availStr = Self.formatBytes(available)
                    let reqStr = Self.formatBytes(estimatedWorking)
                    let message = "Not enough disk space for final assembly. Available: \(availStr), estimated needed: \(reqStr)."
                    return .critical(availableBytes: available, requiredBytes: estimatedWorking, message: message)
                }

                if available < Self.genericWarningThreshold {
                    let availStr = Self.formatBytes(available)
                    let message = "Low disk space on assembly drive (\(availStr) available)."
                    return .warning(availableBytes: available, requiredBytes: estimatedWorking, message: message)
                }

                return .healthy(availableBytes: available)
            } else {
                if available < 300 * 1024 * 1024 { // 300 MB
                    let availStr = Self.formatBytes(available)
                    let message = "Critically low disk space for assembly (\(availStr) available)."
                    return .critical(availableBytes: available, requiredBytes: nil, message: message)
                }

                if available < 5 * 1024 * 1024 * 1024 { // 5 GB
                    let availStr = Self.formatBytes(available)
                    let message = "Low disk space for assembly (\(availStr) available)."
                    return .warning(availableBytes: available, requiredBytes: nil, message: message)
                }

                return .healthy(availableBytes: available)
            }

        case .generic:
            if available < Self.genericCriticalThreshold {
                let availStr = Self.formatBytes(available)
                let message = "Critically low disk space on drive (\(availStr) available)."
                return .critical(availableBytes: available, requiredBytes: nil, message: message)
            }

            if available < Self.genericWarningThreshold {
                let availStr = Self.formatBytes(available)
                let message = "Low disk space on drive (\(availStr) available)."
                return .warning(availableBytes: available, requiredBytes: nil, message: message)
            }

            return .healthy(availableBytes: available)
        }
    }

    /// Resolves the nearest existing ancestor directory for volume evaluation.
    public static func resolveVolumeURL(for url: URL) -> URL {
        var checkURL = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: checkURL.path) && checkURL.path != "/" {
            let parent = checkURL.deletingLastPathComponent()
            if parent.path == checkURL.path { break }
            checkURL = parent
        }
        return checkURL
    }

    /// Formats raw byte counts into clean, human-readable strings (e.g. "6.4 GB", "850 MB").
    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}
