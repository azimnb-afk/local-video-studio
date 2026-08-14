import Foundation

/// Centralized directory and namespace resolver ensuring Personal and Development
/// apps have isolated Application Support and Keychain domains.
public enum AppStorageDirectory {
    public static let legacyFolderName = "LTXVideoGenerator"
    public static let personalFolderName = "LocalVideoStudio"
    public static let devFolderName = "LocalVideoStudioDev"

    /// The appropriate folder name based on the current bundle identifier.
    public static var folderName: String {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if bundleID.contains(".dev") {
            return devFolderName
        } else {
            return personalFolderName
        }
    }

    /// Root Application Support directory for the current application profile.
    public static var root: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let targetURL = appSupport.appendingPathComponent(folderName, isDirectory: true)

        // Perform one-time migration from legacy LTXVideoGenerator to LocalVideoStudio for Personal profile
        if folderName == personalFolderName && !FileManager.default.fileExists(atPath: targetURL.path) {
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

    public static var isDev: Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        return bundleID.contains(".dev")
    }

    public static let personalServiceName = "com.localvideostudio.personal.credentials"
    public static let devServiceName = "com.localvideostudio.dev.credentials"

    /// Keychain service identifier isolated by bundle identity.
    public static var keychainService: String {
        isDev ? devServiceName : personalServiceName
    }
}
