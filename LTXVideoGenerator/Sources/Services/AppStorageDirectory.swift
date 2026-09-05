import Foundation

/// Centralized directory and namespace resolver ensuring Personal and Development
/// apps have isolated Application Support and Keychain domains.
public enum AppStorageDirectory {
    enum Profile: Equatable {
        case personal
        case development
        case bundleless
    }

    public static let legacyFolderName = "LTXVideoGenerator"
    public static let personalFolderName = "LocalVideoStudio"
    public static let devFolderName = "LocalVideoStudioDev"
    static let bundlelessFolderPrefix = "LocalVideoStudio-Bundleless"
    static let testRootEnvironmentKey = "LOCAL_VIDEO_STUDIO_TEST_STORAGE_ROOT"

    static func profile(bundleIdentifier: String?) -> Profile {
        guard let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .bundleless
        }
        return bundleIdentifier.contains(".dev") ? .development : .personal
    }

    private static var currentProfile: Profile {
        profile(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// The appropriate folder name based on the current bundle identifier.
    public static var folderName: String {
        switch currentProfile {
        case .personal: return personalFolderName
        case .development: return devFolderName
        case .bundleless: return bundlelessFolderPrefix
        }
    }

    /// Pure resolver used by tests to pin the three storage profiles without
    /// mutating a real app bundle. A command-line process can never resolve to
    /// the Personal tree: an explicit test root wins, otherwise a PID-scoped
    /// temporary directory is the fail-safe destination.
    static func resolvedRootURL(
        bundleIdentifier: String?,
        environment: [String: String],
        applicationSupportDirectory: URL,
        temporaryDirectory: URL,
        processIdentifier: Int32
    ) -> URL {
        switch profile(bundleIdentifier: bundleIdentifier) {
        case .personal:
            return applicationSupportDirectory
                .appendingPathComponent(personalFolderName, isDirectory: true)
        case .development:
            return applicationSupportDirectory
                .appendingPathComponent(devFolderName, isDirectory: true)
        case .bundleless:
            if let override = environment[testRootEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return temporaryDirectory.appendingPathComponent(
                "\(bundlelessFolderPrefix)-\(processIdentifier)",
                isDirectory: true)
        }
    }

    /// Root Application Support directory for the current application profile.
    public static var root: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let targetURL = resolvedRootURL(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment,
            applicationSupportDirectory: appSupport,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            processIdentifier: ProcessInfo.processInfo.processIdentifier)

        // Perform one-time migration from legacy LTXVideoGenerator to LocalVideoStudio for Personal profile
        if currentProfile == .personal && !FileManager.default.fileExists(atPath: targetURL.path) {
            let legacyURL = appSupport.appendingPathComponent(legacyFolderName, isDirectory: true)
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                try? FileManager.default.copyItem(at: legacyURL, to: targetURL)
            }
        }

        if !FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        }
        return targetURL
    }

    /// Subdirectory for projects.
    public static var projectsDirectory: URL {
        let url = root.appendingPathComponent("Projects", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Subdirectory for generated videos.
    public static var videosDirectory: URL {
        let url = root.appendingPathComponent("Videos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Subdirectory for conditioning and temporary frame caches.
    public static var cacheDirectory: URL {
        let url = root.appendingPathComponent("ConditioningCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Subdirectory for app-managed runtime environments (e.g. ltx-2-mlx).
    public static var runtimesDirectory: URL {
        let url = root.appendingPathComponent("Runtimes", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    public static var isDev: Bool {
        currentProfile == .development
    }

    public static let personalServiceName = "com.localvideostudio.personal.credentials"
    public static let devServiceName = "com.localvideostudio.dev.credentials"
    static let bundlelessServiceNamePrefix = "com.localvideostudio.bundleless.credentials"

    static func keychainServiceName(
        bundleIdentifier: String?,
        processIdentifier: Int32
    ) -> String {
        switch profile(bundleIdentifier: bundleIdentifier) {
        case .personal: return personalServiceName
        case .development: return devServiceName
        case .bundleless: return "\(bundlelessServiceNamePrefix).\(processIdentifier)"
        }
    }

    /// Keychain service identifier isolated by bundle identity.
    public static var keychainService: String {
        keychainServiceName(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            processIdentifier: ProcessInfo.processInfo.processIdentifier)
    }
}
