import CryptoKit
import Foundation

/// Stable product identity and renderer-scoped configuration for the MiniMax
/// H3 experimental renderer. Filesystem locations are user configuration,
/// never model identity and never compiled-in machine-specific paths.
enum MiniMaxH3Configuration {
    static let modelID = "minimax_h3_fl2va_2bit_te"
    static let displayName = "MiniMax H3 (Experimental)"
    static let expectedServerModelID = "MiniMax-H3-FL2VA-MLX-Serve-2bit-text-encoder"

    static let modelDirectoryKey = "minimaxH3ModelDirectory"
    static let runtimeExecutablePathKey = "minimaxH3RuntimeExecutablePath"
    static let endpointKey = "minimaxH3Endpoint"
    static let lastReadinessStateKey = "minimaxH3LastReadinessState"
    static let lastReadinessDetailKey = "minimaxH3LastReadinessDetail"
    static let externalLegacyEndpoint = "http://127.0.0.1:11235"
    static let developmentManagedEndpoint = "http://127.0.0.1:11236"
    static let personalManagedEndpoint = "http://127.0.0.1:11237"

    /// A fresh installed app gets a profile-scoped managed port. Existing
    /// explicit endpoint preferences remain authoritative, including the
    /// advanced external-server endpoint on 11235.
    static var defaultEndpoint: String {
        defaultEndpoint(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func defaultEndpoint(bundleIdentifier: String?) -> String {
        switch AppStorageDirectory.profile(bundleIdentifier: bundleIdentifier) {
        case .personal: return personalManagedEndpoint
        case .development: return developmentManagedEndpoint
        case .bundleless: return externalLegacyEndpoint
        }
    }

    /// Shipping builds place the small execution runtime here after verifying
    /// its pinned source checksum and re-signing every Mach-O payload item.
    /// The H3 model is deliberately never part of this resource tree.
    static func bundledRuntimeDirectory(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?
            .appendingPathComponent("MiniMaxH3Runtime", isDirectory: true)
            .appendingPathComponent("mlx-serve", isDirectory: true)
    }

    struct Snapshot: Codable, Equatable {
        var modelDirectory: String?
        var runtimeExecutablePath: String?
        var endpoint: String

        static func current(userDefaults: UserDefaults = .standard) -> Snapshot {
            let configuredRuntime = nonEmpty(userDefaults.string(forKey: runtimeExecutablePathKey))
            return Snapshot(
                modelDirectory: nonEmpty(userDefaults.string(forKey: modelDirectoryKey)),
                runtimeExecutablePath: configuredRuntime
                    ?? MiniMaxH3ManagedRuntimeManager.shared.readyExecutablePath,
                endpoint: nonEmpty(userDefaults.string(forKey: endpointKey)) ?? defaultEndpoint
            )
        }

        private static func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// H3 must remain local-only. A configurable endpoint is accepted only
    /// when its host is an explicit loopback address.
    static func endpointURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme == "http",
              let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1",
              url.port != nil else {
            return nil
        }
        return url
    }
}

/// This is a packaging classification derived from the license files that are
/// physically present in the selected runtime bundle. It is an engineering
/// preflight, not legal advice or a replacement for release review.
enum MiniMaxH3RuntimeLicenseClassification: String, Codable, Equatable {
    case bundleAllowed = "BUNDLE_ALLOWED"
    case installAllowed = "INSTALL_ALLOWED"
    case userProvidedOnly = "USER_PROVIDED_ONLY"
    case unknown = "UNKNOWN"
}

struct MiniMaxH3ManagedRuntimeManifest: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let minimumRuntimeVersion = "26.8.9"

    var schemaVersion: Int
    var runtime: String
    var runtimeVersion: String
    var architecture: String
    var executableSHA256: String
    /// Full required-component snapshot for newly installed runtimes. Optional
    /// so the accepted schema-1 Dev manifest from before packaging still
    /// decodes and remains usable; every new Install/Repair writes the map.
    var componentSHA256: [String: String]?
    var licenseClassification: MiniMaxH3RuntimeLicenseClassification
    var installedAt: Date

    init(
        schemaVersion: Int = currentSchemaVersion,
        runtime: String = "mlx-serve",
        runtimeVersion: String,
        architecture: String = "arm64",
        executableSHA256: String,
        componentSHA256: [String: String]? = nil,
        licenseClassification: MiniMaxH3RuntimeLicenseClassification,
        installedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.runtime = runtime
        self.runtimeVersion = runtimeVersion
        self.architecture = architecture
        self.executableSHA256 = executableSHA256
        self.componentSHA256 = componentSHA256
        self.licenseClassification = licenseClassification
        self.installedAt = installedAt
    }
}

enum MiniMaxH3ManagedRuntimeStatus: Equatable {
    case notInstalled
    case installing(progress: Double, step: String)
    case ready(executablePath: String, manifest: MiniMaxH3ManagedRuntimeManifest)
    case updateRequired(reason: String)
    case broken(reason: String)

    var executablePath: String? {
        if case .ready(let path, _) = self { return path }
        return nil
    }
}

enum MiniMaxH3ManagedRuntimeError: Error, Equatable, LocalizedError {
    case invalidSource(String)
    case missingComponent(String)
    case unsupportedArchitecture
    case incompatibleVersion(String)
    case insufficientSpace
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource(let detail): return "The selected mlx-serve bundle is invalid. \(detail)"
        case .missingComponent(let name): return "The selected mlx-serve bundle is missing \(name)."
        case .unsupportedArchitecture: return "The selected mlx-serve executable is not a native arm64 Mach-O binary."
        case .incompatibleVersion(let version):
            return "mlx-serve \(version) is not compatible; version \(MiniMaxH3ManagedRuntimeManifest.minimumRuntimeVersion) or newer is required."
        case .insufficientSpace: return "There is not enough free space to install the local mlx-serve runtime."
        case .installationFailed(let detail): return "The mlx-serve runtime could not be installed. \(detail)"
        }
    }
}

/// Installs an already-present local mlx-serve distribution into the active
/// app profile's managed Runtime directory. The source is copied, never moved,
/// and installation is staged before the managed directory is replaced.
final class MiniMaxH3ManagedRuntimeManager: @unchecked Sendable {
    static let shared = MiniMaxH3ManagedRuntimeManager()

    private static let requiredFiles = [
        "mlx-serve",
        "LICENSE",
        "NOTICE",
        "LICENSE-APACHE-2.0",
        "lib/libmlx.dylib",
        "lib/libmlxc.dylib",
        "lib/libjaccl.dylib",
        "lib/libllama.dylib",
        "lib/libwebp.dylib",
        "lib/libsharpyuv.dylib",
        "lib/mlx.metallib",
    ]

    let runtimesDirectory: URL
    let bundledRuntimeDirectory: URL?
    private let fileManager: FileManager

    init(
        runtimesDirectory: URL = AppStorageDirectory.runtimesDirectory,
        bundledRuntimeDirectory: URL? = MiniMaxH3Configuration.bundledRuntimeDirectory(),
        fileManager: FileManager = .default
    ) {
        self.runtimesDirectory = runtimesDirectory
        self.bundledRuntimeDirectory = bundledRuntimeDirectory
        self.fileManager = fileManager
    }

    var managedRuntimeDirectory: URL {
        runtimesDirectory.appendingPathComponent("mlx-serve", isDirectory: true)
    }

    var managedExecutableURL: URL {
        managedRuntimeDirectory.appendingPathComponent("mlx-serve")
    }

    var manifestURL: URL {
        managedRuntimeDirectory.appendingPathComponent("runtime_manifest.json")
    }

    var readyExecutablePath: String? {
        evaluateStatus().executablePath
    }

    var hasBundledRuntimePayload: Bool {
        guard let bundledRuntimeDirectory else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: bundledRuntimeDirectory.path, isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    func inspectBundledRuntime() throws -> MiniMaxH3ManagedRuntimeManifest {
        guard let bundledRuntimeDirectory, hasBundledRuntimePayload else {
            throw MiniMaxH3ManagedRuntimeError.missingComponent(
                "the app's MiniMax H3 runtime payload")
        }
        return try inspectBundle(at: bundledRuntimeDirectory)
    }

    func installBundled(
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> MiniMaxH3ManagedRuntimeManifest {
        guard let bundledRuntimeDirectory, hasBundledRuntimePayload else {
            throw MiniMaxH3ManagedRuntimeError.missingComponent(
                "the app's MiniMax H3 runtime payload")
        }
        return try await install(from: bundledRuntimeDirectory, progress: progress)
    }

    func evaluateStatus() -> MiniMaxH3ManagedRuntimeStatus {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: managedRuntimeDirectory.path, isDirectory: &isDirectory
        ) else { return .notInstalled }
        guard isDirectory.boolValue else {
            return .broken(reason: "The managed runtime path is not a directory.")
        }
        guard fileManager.fileExists(atPath: managedExecutableURL.path) else {
            return .broken(reason: "The managed mlx-serve executable is missing.")
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .updateRequired(reason: "The managed runtime predates the verified manifest format.")
        }
        let manifest: MiniMaxH3ManagedRuntimeManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(
                MiniMaxH3ManagedRuntimeManifest.self,
                from: Data(contentsOf: manifestURL))
        } catch {
            return .broken(reason: "The managed runtime manifest is unreadable.")
        }
        guard manifest.schemaVersion == MiniMaxH3ManagedRuntimeManifest.currentSchemaVersion else {
            return .updateRequired(reason: "The managed runtime manifest schema must be updated.")
        }
        guard Self.version(manifest.runtimeVersion, isAtLeast: MiniMaxH3ManagedRuntimeManifest.minimumRuntimeVersion) else {
            return .updateRequired(reason: "mlx-serve \(manifest.runtimeVersion) is older than the required runtime.")
        }
        do {
            let inspected = try inspectBundle(at: managedRuntimeDirectory)
            guard inspected.executableSHA256 == manifest.executableSHA256 else {
                return .broken(reason: "The managed mlx-serve executable no longer matches its installation manifest.")
            }
            if let expectedComponents = manifest.componentSHA256,
               inspected.componentSHA256 != expectedComponents {
                return .broken(reason: "A managed runtime component no longer matches its installation manifest.")
            }
            guard inspected.runtimeVersion == manifest.runtimeVersion else {
                return .broken(reason: "The managed mlx-serve version no longer matches its installation manifest.")
            }
            guard inspected.licenseClassification == manifest.licenseClassification else {
                return .broken(reason: "The managed runtime license files no longer match its installation manifest.")
            }
            return .ready(executablePath: managedExecutableURL.path, manifest: manifest)
        } catch {
            return .broken(reason: error.localizedDescription)
        }
    }

    func inspectBundle(at sourceDirectory: URL) throws -> MiniMaxH3ManagedRuntimeManifest {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MiniMaxH3ManagedRuntimeError.invalidSource("Select the folder containing mlx-serve and its lib directory.")
        }
        for relativePath in Self.requiredFiles {
            let item = sourceDirectory.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: item.path) else {
                throw MiniMaxH3ManagedRuntimeError.missingComponent(relativePath)
            }
        }
        guard fileManager.isExecutableFile(atPath: sourceDirectory.appendingPathComponent("mlx-serve").path) else {
            throw MiniMaxH3ManagedRuntimeError.invalidSource("mlx-serve is not executable.")
        }
        guard try containsNoSymbolicLinks(in: sourceDirectory) else {
            throw MiniMaxH3ManagedRuntimeError.invalidSource("Symbolic links are not accepted in a managed runtime bundle.")
        }

        for relativePath in Self.requiredNativeFiles {
            let nativeData = try Data(
                contentsOf: sourceDirectory.appendingPathComponent(relativePath),
                options: .mappedIfSafe)
            guard Self.isArm64MachO(nativeData) else {
                throw MiniMaxH3ManagedRuntimeError.invalidSource(
                    "\(relativePath) is not a native arm64 Mach-O file.")
            }
        }

        let executableURL = sourceDirectory.appendingPathComponent("mlx-serve")
        let executableData = try Data(contentsOf: executableURL, options: .mappedIfSafe)
        guard let version = Self.embeddedVersion(in: executableData) else {
            throw MiniMaxH3ManagedRuntimeError.invalidSource("The embedded mlx-serve version could not be read.")
        }
        guard Self.version(version, isAtLeast: MiniMaxH3ManagedRuntimeManifest.minimumRuntimeVersion) else {
            throw MiniMaxH3ManagedRuntimeError.incompatibleVersion(version)
        }

        let license = try String(
            contentsOf: sourceDirectory.appendingPathComponent("LICENSE"), encoding: .utf8)
        let notice = try String(
            contentsOf: sourceDirectory.appendingPathComponent("NOTICE"), encoding: .utf8)
        let apache = try String(
            contentsOf: sourceDirectory.appendingPathComponent("LICENSE-APACHE-2.0"), encoding: .utf8)
        let classification = Self.classifyLicense(
            license: license, notice: notice, apacheLicense: apache)
        guard classification != .unknown else {
            throw MiniMaxH3ManagedRuntimeError.invalidSource("License and attribution files could not be classified.")
        }

        var componentSHA256: [String: String] = [:]
        for relativePath in Self.requiredFiles {
            let data = try Data(
                contentsOf: sourceDirectory.appendingPathComponent(relativePath),
                options: .mappedIfSafe)
            componentSHA256[relativePath] = Self.sha256(data)
        }

        return MiniMaxH3ManagedRuntimeManifest(
            runtimeVersion: version,
            executableSHA256: Self.sha256(executableData),
            componentSHA256: componentSHA256,
            licenseClassification: classification)
    }

    func install(
        from sourceDirectory: URL,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> MiniMaxH3ManagedRuntimeManifest {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.installSynchronously(
                        from: sourceDirectory, progress: progress))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func installSynchronously(
        from sourceDirectory: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) throws -> MiniMaxH3ManagedRuntimeManifest {
        progress(0.05, "Validating local runtime bundle")
        let sourceManifest = try inspectBundle(at: sourceDirectory)
        let requiredBytes = try Self.directorySize(sourceDirectory, fileManager: fileManager) + 64 * 1_024 * 1_024
        let capacity = try? runtimesDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < Int64(requiredBytes) {
            throw MiniMaxH3ManagedRuntimeError.insufficientSpace
        }

        try fileManager.createDirectory(at: runtimesDirectory, withIntermediateDirectories: true)
        let staging = runtimesDirectory.appendingPathComponent(
            ".mlx-serve-install-\(UUID().uuidString)", isDirectory: true)
        let backup = runtimesDirectory.appendingPathComponent(
            ".mlx-serve-backup-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backup)
        }

        do {
            progress(0.20, "Copying runtime into this app profile")
            try fileManager.copyItem(at: sourceDirectory, to: staging)
            guard try requiredComponentsMatch(source: sourceDirectory, copy: staging) else {
                throw MiniMaxH3ManagedRuntimeError.installationFailed(
                    "A required runtime component changed size during the managed copy.")
            }
            var installedManifest = try inspectBundle(at: staging)
            installedManifest.installedAt = Date()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let manifestData = try encoder.encode(installedManifest)
            try manifestData.write(
                to: staging.appendingPathComponent("runtime_manifest.json"), options: .atomic)
            progress(0.80, "Verifying the managed runtime copy")
            let stagedCheck = try inspectBundle(at: staging)
            guard stagedCheck.executableSHA256 == sourceManifest.executableSHA256,
                  stagedCheck.componentSHA256 == sourceManifest.componentSHA256 else {
                throw MiniMaxH3ManagedRuntimeError.installationFailed("A copied runtime component checksum changed.")
            }

            if fileManager.fileExists(atPath: managedRuntimeDirectory.path) {
                try fileManager.moveItem(at: managedRuntimeDirectory, to: backup)
            }
            do {
                try fileManager.moveItem(at: staging, to: managedRuntimeDirectory)
            } catch {
                if fileManager.fileExists(atPath: backup.path),
                   !fileManager.fileExists(atPath: managedRuntimeDirectory.path) {
                    try? fileManager.moveItem(at: backup, to: managedRuntimeDirectory)
                }
                throw error
            }
            try? fileManager.removeItem(at: backup)
            progress(1.0, "Managed runtime ready")
            return installedManifest
        } catch let error as MiniMaxH3ManagedRuntimeError {
            throw error
        } catch {
            throw MiniMaxH3ManagedRuntimeError.installationFailed(error.localizedDescription)
        }
    }

    private func requiredComponentsMatch(source: URL, copy: URL) throws -> Bool {
        for relativePath in Self.requiredFiles {
            let sourceAttributes = try fileManager.attributesOfItem(
                atPath: source.appendingPathComponent(relativePath).path)
            let copyAttributes = try fileManager.attributesOfItem(
                atPath: copy.appendingPathComponent(relativePath).path)
            guard let sourceSize = sourceAttributes[.size] as? NSNumber,
                  let copySize = copyAttributes[.size] as? NSNumber,
                  sourceSize.uint64Value > 0,
                  sourceSize.uint64Value == copySize.uint64Value else {
                return false
            }
        }
        return true
    }

    private func containsNoSymbolicLinks(in directory: URL) throws -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return false }
        for case let item as URL in enumerator {
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                return false
            }
        }
        return true
    }

    static func classifyLicense(
        license: String,
        notice: String,
        apacheLicense: String
    ) -> MiniMaxH3RuntimeLicenseClassification {
        let normalizedLicense = license.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normalizedNotice = notice.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normalizedApache = apacheLicense.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let hasMITGrant = normalizedLicense.contains("MIT License")
            && normalizedLicense.contains("Permission is hereby granted, free of charge")
            && normalizedLicense.contains("included in all copies or substantial portions")
        let hasAttributions = normalizedNotice.contains("mlx-serve")
            && normalizedNotice.contains("third-party")
        let hasApacheText = normalizedApache.contains("Apache License")
            && normalizedApache.contains("Version 2.0")
        return hasMITGrant && hasAttributions && hasApacheText ? .bundleAllowed : .unknown
    }

    private static func embeddedVersion(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let expression = try? NSRegularExpression(pattern: #"\b([0-9]{2}\.[0-9]{1,2}\.[0-9]{1,2})\b"#)
        guard let match = expression?.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func isArm64MachO(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        return Array(data.prefix(8)) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func version(_ version: String, isAtLeast minimum: String) -> Bool {
        let lhs = version.split(separator: ".").compactMap { Int($0) }
        let rhs = minimum.split(separator: ".").compactMap { Int($0) }
        guard lhs.count == 3, rhs.count == 3 else { return false }
        return lhs.lexicographicallyPrecedes(rhs) == false
    }

    private static func directorySize(_ directory: URL, fileManager: FileManager) throws -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw MiniMaxH3ManagedRuntimeError.invalidSource("The selected folder is unreadable.") }
        var total: UInt64 = 0
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += UInt64(values.fileSize ?? 0) }
        }
        return total
    }

    private static let requiredNativeFiles = [
        "mlx-serve",
        "lib/libmlx.dylib",
        "lib/libmlxc.dylib",
        "lib/libjaccl.dylib",
        "lib/libllama.dylib",
        "lib/libwebp.dylib",
        "lib/libsharpyuv.dylib",
    ]
}

enum MiniMaxH3RuntimeState: String, Codable, Equatable {
    case notConfigured
    case notRunning
    case starting
    case ready
    case wrongModel
    case failed
    /// Legacy value retained so older UserDefaults decode safely. New runtime
    /// failures are recorded as `.failed`.
    case broken
}

enum MiniMaxH3ServerOwnership: String, Codable, Equatable {
    case externallyRunning
    case appOwned
}

struct MiniMaxH3RuntimeStatus: Equatable {
    var state: MiniMaxH3RuntimeState
    var ownership: MiniMaxH3ServerOwnership?
    var detail: String
    var loadedModelID: String?

    var isReady: Bool { state == .ready }
}

protocol MiniMaxH3HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class MiniMaxH3URLSessionTransport: MiniMaxH3HTTPTransport {
    private let session: URLSession

    init(timeout: TimeInterval = 3_600) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxH3Error.invalidHTTPResponse
        }
        return (data, http)
    }
}

enum MiniMaxH3Error: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case runtimeNotConfigured(String)
    case runtimeNotRunning(String)
    case runtimeStartFailed(String)
    case serverUnhealthy(String)
    case wrongModel(expected: String, actual: String?)
    case requestRejected(status: Int, message: String)
    case invalidHTTPResponse
    case malformedResponse(String)
    case invalidBase64(String)
    case invalidFramePayload(expected: Int, actual: Int)
    case invalidAudioPayload(String)
    case invalidSourceImage(String)
    case unsupportedCapability(String)
    case ffmpegUnavailable
    case muxFailed(exitCode: Int, message: String)
    case outputMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The MiniMax H3 endpoint must be an explicit localhost HTTP URL with a port."
        case .runtimeNotConfigured(let detail): return "MiniMax H3 is not configured. \(detail)"
        case .runtimeNotRunning(let detail): return "MiniMax H3 is not running. \(detail)"
        case .runtimeStartFailed(let detail): return "MiniMax H3 runtime could not start. \(detail)"
        case .serverUnhealthy(let detail): return "MiniMax H3 server is unhealthy. \(detail)"
        case .wrongModel(let expected, let actual):
            let found = actual ?? "none"
            return "MiniMax H3 server has the wrong model loaded (expected \(expected), found \(found))."
        case .requestRejected(let status, let message):
            return "MiniMax H3 request failed with HTTP \(status): \(message)"
        case .invalidHTTPResponse: return "MiniMax H3 returned an invalid HTTP response."
        case .malformedResponse(let detail): return "MiniMax H3 returned malformed JSON. \(detail)"
        case .invalidBase64(let field): return "MiniMax H3 returned invalid base64 data for \(field)."
        case .invalidFramePayload(let expected, let actual):
            return "MiniMax H3 returned an invalid RGB frame payload (expected \(expected) bytes, received \(actual))."
        case .invalidAudioPayload(let detail): return "MiniMax H3 returned invalid PCM audio. \(detail)"
        case .invalidSourceImage(let detail): return "MiniMax H3 could not prepare the starting image. \(detail)"
        case .unsupportedCapability(let detail): return "MiniMax H3 does not support \(detail) in this model pack."
        case .ffmpegUnavailable: return "FFmpeg is required to mux MiniMax H3 video and audio but was not found."
        case .muxFailed(let exitCode, let message): return "MiniMax H3 mux failed with exit code \(exitCode): \(message)"
        case .outputMissing: return "MiniMax H3 completed but no playable MP4 was created."
        case .cancelled: return "MiniMax H3 generation was cancelled."
        }
    }
}

/// Owns only servers launched by this app instance. A compatible server that
/// was already listening is reused and is never terminated by app cleanup.
final class MiniMaxH3RuntimeManager: @unchecked Sendable {
    static let shared = MiniMaxH3RuntimeManager()

    private let lock = NSLock()
    private var ownedProcess: Process?
    private var ownedEndpoint: String?
    private var ownedModelDirectory: String?
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func status(
        snapshot: MiniMaxH3Configuration.Snapshot,
        transport: MiniMaxH3HTTPTransport = MiniMaxH3URLSessionTransport(timeout: 8)
    ) async -> MiniMaxH3RuntimeStatus {
        guard let baseURL = MiniMaxH3Configuration.endpointURL(snapshot.endpoint) else {
            return MiniMaxH3RuntimeStatus(
                state: .failed, ownership: nil,
                detail: MiniMaxH3Error.invalidEndpoint.localizedDescription,
                loadedModelID: nil)
        }

        do {
            var healthRequest = URLRequest(url: baseURL.appendingPathComponent("health"))
            healthRequest.httpMethod = "GET"
            let (healthData, healthResponse) = try await transport.data(for: healthRequest)
            guard (200..<300).contains(healthResponse.statusCode),
                  let health = try? JSONSerialization.jsonObject(with: healthData) as? [String: Any],
                  (health["status"] as? String)?.lowercased() == "ok" else {
                return MiniMaxH3RuntimeStatus(
                    state: .failed, ownership: ownership(for: snapshot.endpoint),
                    detail: "The /health check did not report ok.", loadedModelID: nil)
            }

            var modelsRequest = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
            modelsRequest.httpMethod = "GET"
            let (modelsData, modelsResponse) = try await transport.data(for: modelsRequest)
            guard (200..<300).contains(modelsResponse.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: modelsData) else {
                return MiniMaxH3RuntimeStatus(
                    state: .failed, ownership: ownership(for: snapshot.endpoint),
                    detail: "The /v1/models response was unreadable.", loadedModelID: nil)
            }

            let models = Self.modelEntries(from: object)
            if let exact = models.first(where: { $0.id == MiniMaxH3Configuration.expectedServerModelID }) {
                if exact.isReady {
                    return MiniMaxH3RuntimeStatus(
                        state: .ready, ownership: ownership(for: snapshot.endpoint),
                        detail: "Ready", loadedModelID: exact.id)
                }
                return MiniMaxH3RuntimeStatus(
                    state: .starting, ownership: ownership(for: snapshot.endpoint),
                    detail: "The expected model is still loading.", loadedModelID: exact.id)
            }
            return MiniMaxH3RuntimeStatus(
                state: .wrongModel, ownership: ownership(for: snapshot.endpoint),
                detail: "A server is healthy, but the expected H3 model is not ready.",
                loadedModelID: models.first?.id)
        } catch {
            let configured = snapshot.modelDirectory != nil && snapshot.runtimeExecutablePath != nil
            return MiniMaxH3RuntimeStatus(
                state: configured ? .notRunning : .notConfigured,
                ownership: nil,
                detail: configured
                    ? "No MiniMax H3 server is listening at the configured endpoint."
                    : "Set the H3 model directory and mlx-serve executable, or start a compatible external server.",
                loadedModelID: nil)
        }
    }

    func ensureReady(
        snapshot: MiniMaxH3Configuration.Snapshot,
        progress: @escaping (Double, String) -> Void = { _, _ in }
    ) async throws -> MiniMaxH3RuntimeStatus {
        let initial = await status(snapshot: snapshot)
        if initial.isReady { return initial }
        if initial.state == .wrongModel {
            throw MiniMaxH3Error.wrongModel(
                expected: MiniMaxH3Configuration.expectedServerModelID,
                actual: initial.loadedModelID)
        }
        if initial.state == .failed || initial.state == .broken || initial.state == .starting {
            throw MiniMaxH3Error.serverUnhealthy(initial.detail)
        }
        guard MiniMaxH3Configuration.endpointURL(snapshot.endpoint) != nil else {
            throw MiniMaxH3Error.invalidEndpoint
        }
        guard let runtime = snapshot.runtimeExecutablePath,
              fileManager.isExecutableFile(atPath: runtime) else {
            throw MiniMaxH3Error.runtimeNotConfigured("Select an executable mlx-serve runtime.")
        }
        guard let model = snapshot.modelDirectory,
              directoryExists(model) else {
            throw MiniMaxH3Error.runtimeNotConfigured("Select the local MiniMax H3 model directory.")
        }

        try startOwnedServer(runtime: runtime, model: model, endpoint: snapshot.endpoint)
        progress(0.01, "Starting the MiniMax H3 local server…")

        do {
            for _ in 0..<300 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let current = await status(snapshot: snapshot)
                if current.isReady { return current }
                if current.state == .wrongModel {
                    stopOwnedServer()
                    throw MiniMaxH3Error.wrongModel(
                        expected: MiniMaxH3Configuration.expectedServerModelID,
                        actual: current.loadedModelID)
                }
                if !ownedServerIsRunning {
                    throw MiniMaxH3Error.runtimeStartFailed("The mlx-serve process exited before becoming ready.")
                }
            }
        } catch is CancellationError {
            stopOwnedServer()
            throw MiniMaxH3Error.cancelled
        }
        stopOwnedServer()
        throw MiniMaxH3Error.runtimeStartFailed("Timed out while loading the configured model.")
    }

    func stopOwnedServer() {
        lock.lock()
        let process = ownedProcess
        ownedProcess = nil
        ownedEndpoint = nil
        ownedModelDirectory = nil
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    private var ownedServerIsRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownedProcess?.isRunning == true
    }

    private func ownership(for endpoint: String) -> MiniMaxH3ServerOwnership {
        lock.lock()
        defer { lock.unlock() }
        if ownedEndpoint == endpoint, ownedProcess?.isRunning == true { return .appOwned }
        return .externallyRunning
    }

    private func startOwnedServer(runtime: String, model: String, endpoint: String) throws {
        guard let url = MiniMaxH3Configuration.endpointURL(endpoint), let port = url.port else {
            throw MiniMaxH3Error.invalidEndpoint
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime)
        process.arguments = Self.serverArguments(modelDirectory: model, port: port)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        lock.lock()
        if let existing = ownedProcess, existing.isRunning {
            let sameConfiguration = ownedEndpoint == endpoint && ownedModelDirectory == model
            lock.unlock()
            if sameConfiguration { return }
            throw MiniMaxH3Error.runtimeStartFailed(
                "Another app-owned H3 server is already running with a different endpoint or model.")
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            throw MiniMaxH3Error.runtimeStartFailed(error.localizedDescription)
        }
        ownedProcess = process
        ownedEndpoint = endpoint
        ownedModelDirectory = model
        lock.unlock()
    }

    static func serverArguments(modelDirectory: String, port: Int) -> [String] {
        [
            "--model", modelDirectory,
            "--serve",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--timeout", "0",
            // The exact 2-bit-text-encoder pack has already passed real 48GB
            // generation acceptance. mlx-serve's generic aggregate preflight
            // double-counts staged components that this video path unloads
            // between phases, so the accepted local launch uses this flag.
            "--skip-mem-preflight",
        ]
    }

    private func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private struct ModelEntry {
        var id: String
        var isReady: Bool
    }

    private static func modelEntries(from object: Any) -> [ModelEntry] {
        let dictionaries: [[String: Any]]
        if let root = object as? [String: Any], let data = root["data"] as? [[String: Any]] {
            dictionaries = data
        } else if let array = object as? [[String: Any]] {
            dictionaries = array
        } else if let root = object as? [String: Any] {
            dictionaries = [root]
        } else {
            dictionaries = []
        }
        return dictionaries.compactMap { entry in
            guard let id = (entry["id"] ?? entry["model"] ?? entry["name"]) as? String else { return nil }
            let loaded = entry["loaded"] as? Bool ?? true
            let state = (entry["state"] as? String)?.lowercased()
            let ready = entry["ready"] as? Bool ?? (state == nil || state == "ready")
            return ModelEntry(id: id, isReady: loaded && ready)
        }
    }
}
