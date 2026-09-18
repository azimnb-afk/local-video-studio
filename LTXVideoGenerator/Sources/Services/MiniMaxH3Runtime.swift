import CryptoKit
import Darwin
import Foundation

/// Stable product identity and renderer-scoped configuration for the MiniMax
/// H3 experimental renderer. Filesystem locations are user configuration,
/// never model identity and never compiled-in machine-specific paths.
enum MiniMaxH3Configuration {
    static let standardModelID = "minimax_h3_fl2va_2bit_te"
    static let highQualityModelID = "minimax_h3_fl2va_8bit_dit"
    /// Reference-conditioned (REF2VA) partition, added 2026-09-17 for
    /// evaluation. Distinct conditioning contract from FL2VA: no
    /// first/last-frame keyframes, no chain_windows; instead up to 9 ordered
    /// reference images. Official `ddalcu/MiniMax-H3-REF2VA-MLX-Serve-8bit`,
    /// runs on the same mainline mlx-serve runtime already embedded by this
    /// app (REF2VA support present in mlx-serve since v26.8.3). Experimental
    /// and unverified: added so it can be evaluated, not because it is known
    /// to outperform FL2VA. See docs/MINIMAX_H3_MANAGED_RUNTIME.md.
    static let referenceModelID = "minimax_h3_ref2va_8bit"
    static var modelID: String { standardModelID }

    static let displayName = "MiniMax H3（実験的機能 / Experimental）"
    /// User-facing names, 2026-09-18. These name the *model/weights tier*
    /// only — never a generation-cost word ("Standard"/"High"/"Fast") that
    /// could be confused with `MiniMaxH3Preset.displayName` (the *quality/
    /// cost* choice within a model) or the Fast Mode toggle. The English
    /// parenthetical is a short tag for logs/screenshots, not a synonym to
    /// translate independently — keep both strings in lockstep by editing
    /// only here; every surface (Generate/One Shot picker, Settings, the
    /// active-model sidebar) reads through these three constants or the
    /// badges built from them in ActiveModelDisplayResolver, not a local
    /// copy. `standardModelID`/`highQualityModelID`/`referenceModelID` (the
    /// internal identifiers) are unrelated to this renaming and unchanged;
    /// when technical text needs to refer to a tier unambiguously, name the
    /// internal identifier explicitly rather than reusing a retired UI name
    /// like "Standard" or "High Quality".
    static let standardDisplayName = "MiniMax H3 軽量版 (Efficient)"
    static let highQualityDisplayName = "MiniMax H3 高画質版 (Quality)"
    static let referenceDisplayName = "MiniMax H3 参照画像版 (Reference)"

    static let standardExpectedServerModelID = "MiniMax-H3-FL2VA-MLX-Serve-2bit-text-encoder"
    static let highQualityExpectedServerModelID = "MiniMax-H3-FL2VA-MLX-Serve-8bit-DiT-2bit-TE"
    static let highQualityAlternativeServerModelID = "MiniMax-H3-FL2VA-MLX-Serve-8bit"
    static let referenceExpectedServerModelID = "MiniMax-H3-REF2VA-MLX-Serve-8bit"
    static var expectedServerModelID: String { standardExpectedServerModelID }

    static let standardModelDirectoryKey = "minimaxH3ModelDirectory"
    static let highQualityModelDirectoryKey = "minimaxH3HighQualityModelDirectory"
    static let referenceModelDirectoryKey = "minimaxH3ReferenceModelDirectory"
    static var modelDirectoryKey: String { standardModelDirectoryKey }

    static let runtimeExecutablePathKey = "minimaxH3RuntimeExecutablePath"
    static let endpointKey = "minimaxH3Endpoint"
    /// Readiness is recorded per model ID, never in one shared slot. All
    /// three H3 tiers can share one endpoint/runtime but load different
    /// weights, so a single global "last readiness" pair would let recording
    /// one model's result silently corrupt another tier's status label with
    /// a stale/mismatched read — see `ModelReadinessResolver.evaluateH3` and
    /// docs/MODEL_REGISTRY_GUIDE.md. Note this no longer risks a tier
    /// disappearing from the Generate picker at all (the picker shows every
    /// registered model regardless of readiness — see
    /// `ModelReadinessStore.pickerModels`), but a wrong status label would
    /// still be a real, user-visible bug, so the per-model keys remain load
    /// bearing. Every reader/writer of H3 readiness must go through these two
    /// functions; there is deliberately no bare, unparameterized key left to
    /// reach for by accident.
    static func lastReadinessStateKey(for modelID: String) -> String {
        "minimaxH3LastReadinessState.\(modelID)"
    }
    static func lastReadinessDetailKey(for modelID: String) -> String {
        "minimaxH3LastReadinessDetail.\(modelID)"
    }
    static let externalLegacyEndpoint = "http://127.0.0.1:11235"
    static let developmentManagedEndpoint = "http://127.0.0.1:11236"
    static let personalManagedEndpoint = "http://127.0.0.1:11237"

    static func isMiniMaxH3(modelID: String?) -> Bool {
        guard let modelID else { return false }
        return modelID == standardModelID || modelID == highQualityModelID || modelID == referenceModelID
    }

    /// REF2VA is a distinct conditioning contract (reference images, not
    /// first/last-frame keyframes) — callers that build a keyframe/chain
    /// payload must branch on this before doing so.
    static func isReferenceConditioned(modelID: String?) -> Bool {
        modelID == referenceModelID
    }

    static func expectedServerModelIDs(for modelID: String?) -> [String] {
        if modelID == highQualityModelID {
            return [highQualityExpectedServerModelID, highQualityAlternativeServerModelID]
        }
        if modelID == referenceModelID {
            return [referenceExpectedServerModelID]
        }
        return [standardExpectedServerModelID]
    }

    static func modelDirectoryKey(for modelID: String?) -> String {
        if modelID == highQualityModelID { return highQualityModelDirectoryKey }
        if modelID == referenceModelID { return referenceModelDirectoryKey }
        return standardModelDirectoryKey
    }

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
        var targetModelID: String?

        static func current(forModelID modelID: String? = nil, userDefaults: UserDefaults = .standard) -> Snapshot {
            let effectiveModelID = modelID ?? standardModelID
            let dirKey = modelDirectoryKey(for: effectiveModelID)
            let configuredRuntime = nonEmpty(userDefaults.string(forKey: runtimeExecutablePathKey))
            return Snapshot(
                modelDirectory: nonEmpty(userDefaults.string(forKey: dirKey)),
                runtimeExecutablePath: configuredRuntime
                    ?? MiniMaxH3ManagedRuntimeManager.shared.readyExecutablePath,
                endpoint: nonEmpty(userDefaults.string(forKey: endpointKey)) ?? defaultEndpoint,
                targetModelID: effectiveModelID
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
    /// The endpoint this status actually describes. Populated by
    /// `MiniMaxH3RuntimeManager.ensureReady`'s return value so a caller never
    /// has to re-derive "which endpoint did this prepare" from static
    /// configuration after the fact — load-bearing when `ensureReady`
    /// silently redirected to an alternate, app-owned-only endpoint because
    /// the configured one has an external server holding a different model
    /// (see `MiniMaxH3AlternatePortAllocator`). Defaults to "" because most
    /// construction sites (inside `status(snapshot:)`, and every existing
    /// test) already know their endpoint from the snapshot they built and
    /// don't need it echoed back on this type.
    var endpoint: String = ""

    var isReady: Bool { state == .ready }
}

/// Finds a free loopback port for an app-owned H3 runtime that must never
/// collide with — or be confused with — the user's configured endpoint,
/// which may have an external server on it (see `MiniMaxH3ServerOwnership`).
///
/// No existing port-lease, scratch-port, or per-tier-port mechanism was
/// found anywhere in the runtime/backend/lease code when this was added
/// (audited 2026-09-18): H3's only prior port story is the three fixed,
/// profile-scoped defaults in `MiniMaxH3Configuration`
/// (`externalLegacyEndpoint`/`developmentManagedEndpoint`/
/// `personalManagedEndpoint` — 11235/11236/11237), none of which are meant
/// for "run a second, simultaneous H3 server alongside another one." This
/// is a new, minimal allocator, not a rediscovery of an existing one.
enum MiniMaxH3AlternatePortAllocator {
    /// Deliberately narrow, fixed range immediately after the app's own
    /// managed ports — easy to recognize in `lsof`/Activity Monitor as
    /// "Local Video Studio's own," and small enough that exhausting it (100
    /// candidates) is itself a strong signal something else is wrong, not a
    /// real capacity limit for this app's single-generation-at-a-time
    /// design (see `MiniMaxH3GenerationLease`).
    static let candidateRange = 11291...11390

    /// Pure: the first port in range that isn't excluded and that `isFree`
    /// accepts. Fully unit-testable with a fake `isFree` — no socket, no
    /// process, no real port ever touched.
    static func firstAvailablePort(
        excluding excludedPorts: Set<Int>,
        isFree: (Int) -> Bool
    ) -> Int? {
        for port in candidateRange where !excludedPorts.contains(port) {
            if isFree(port) { return port }
        }
        return nil
    }

    /// Real, side-effecting freedom check: binds a loopback-only TCP socket
    /// on the port and immediately releases it. A real listener there
    /// (including the configured endpoint's own external server, if it ever
    /// fell in this range) makes this false, so does any other process
    /// already using it. Never binds `0.0.0.0` — loopback only, matching
    /// every other H3 endpoint this app ever binds.
    static func isPortFreeOnLoopback(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    /// Finds a free port using the real bind-based check, excluding the
    /// given endpoint's own port (parsed from its URL) so the search can
    /// never recommend the exact port an external — or this app's own
    /// configured-endpoint — server holds.
    static func allocate(excludingEndpoint endpoint: String) -> Int? {
        var excluded = Set<Int>()
        if let url = URL(string: endpoint), let port = url.port {
            excluded.insert(port)
        }
        return firstAvailablePort(excluding: excluded, isFree: isPortFreeOnLoopback)
    }
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
    case generationBusy(String)
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
        case .generationBusy(let detail): return detail
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

/// What the app records about an `mlx-serve` it started, so a later session can
/// tell that server from one it did not start.
struct MiniMaxManagedServerRecord: Codable, Equatable {
    var pid: Int32
    var identity: ProcessIdentity
    var endpoint: String
    var modelDirectory: String
    var ownerAppInstanceID: UUID
    var launchedAt: Date
}

/// Owns only servers the app launched. A compatible server that was already
/// listening and that the app did not start is reused and is never terminated
/// by app cleanup.
///
/// "Launched by this app" used to mean "by this app process": the handle lived
/// only in memory, so after a crash the server the app had started was taken
/// for an external one — reused, never stopped by a later clean quit, and not
/// restarted when the wrong model was loaded. The launch is now recorded (PID
/// and the kernel's identity for it), and a later session that finds that
/// exact process still running reclaims it as its own.
final class MiniMaxH3RuntimeManager: @unchecked Sendable {
    static let shared = MiniMaxH3RuntimeManager()

    private let lock = NSLock()
    private var ownedProcess: Process?
    private var ownedEndpoint: String?
    private var ownedModelDirectory: String?
    private var ownedStderrTail: String = ""
    private var telemetryListeners: [UUID: @Sendable (String) -> Void] = [:]
    private let fileManager: FileManager
    private let managedRuntimeManager: MiniMaxH3ManagedRuntimeManager
    private let userDefaults: UserDefaults
    private let managedServerRecordURL: URL
    private let inspector: ProcessInspecting

    init(
        fileManager: FileManager = .default,
        managedRuntimeManager: MiniMaxH3ManagedRuntimeManager = .shared,
        userDefaults: UserDefaults = .standard,
        managedServerRecordURL: URL? = nil,
        inspector: ProcessInspecting = LiveProcessInspector()
    ) {
        self.fileManager = fileManager
        self.managedRuntimeManager = managedRuntimeManager
        self.userDefaults = userDefaults
        self.managedServerRecordURL = managedServerRecordURL
            ?? AppStorageDirectory.root.appendingPathComponent("minimax_managed_server.json")
        self.inspector = inspector
    }

    // MARK: Managed server record

    private func readManagedServerRecord() -> MiniMaxManagedServerRecord? {
        guard let data = try? Data(contentsOf: managedServerRecordURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MiniMaxManagedServerRecord.self, from: data)
    }

    private func writeManagedServerRecord(_ record: MiniMaxManagedServerRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? fileManager.createDirectory(
            at: managedServerRecordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: managedServerRecordURL, options: .atomic)
    }

    private func removeManagedServerRecord() {
        try? fileManager.removeItem(at: managedServerRecordURL)
    }

    /// The recorded server, if the process running under its PID is provably
    /// the one the app launched (and, when given, serves `endpoint`).
    func reclaimableManagedServer(for endpoint: String?) -> MiniMaxManagedServerRecord? {
        guard let record = readManagedServerRecord(),
              endpoint == nil || record.endpoint == endpoint,
              case .identity(let live) = inspector.inspect(pid: record.pid),
              live == record.identity, live.userID == getuid() else { return nil }
        return record
    }

    @discardableResult
    func registerTelemetryListener(_ listener: @escaping @Sendable (String) -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        telemetryListeners[id] = listener
        return id
    }

    func unregisterTelemetryListener(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        telemetryListeners.removeValue(forKey: id)
    }

    func broadcastTelemetryLine(_ line: String) {
        lock.lock()
        let listeners = Array(telemetryListeners.values)
        lock.unlock()
        for listener in listeners {
            listener(line)
        }
    }

    /// Keeps the sidebar's persisted snapshot (ActiveModelDisplayResolver)
    /// in sync with what a real generation attempt is actually doing.
    /// Settings' own checkReadiness() writes the same keys when the user
    /// opens Preferences; this is the generation-time counterpart so the
    /// user sees the real Stopped -> Starting -> Ready/Failed transition
    /// instead of a stale snapshot from the last time Settings was opened.
    func recordReadiness(state: MiniMaxH3RuntimeState, detail: String, modelID: String? = nil) {
        guard let effectiveModelID = modelID
            ?? userDefaults.string(forKey: LTXModelCatalog.selectedModelIDKey) else { return }
        userDefaults.set(state.rawValue, forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: effectiveModelID))
        userDefaults.set(detail, forKey: MiniMaxH3Configuration.lastReadinessDetailKey(for: effectiveModelID))
    }

    private func recordReadiness(_ status: MiniMaxH3RuntimeStatus, modelID: String? = nil) {
        recordReadiness(state: status.state, detail: status.detail, modelID: modelID)
    }

    /// If this manager owns the H3 server process and it has since exited,
    /// describes exactly why (exit code, or the specific signal — SIGKILL
    /// and SIGTERM are named explicitly rather than folded into a generic
    /// HTTP/network error) plus its recent stderr. Lets a generation-time
    /// HTTP failure that happens because the owned process died report the
    /// real cause instead of a bare "network connection was lost".
    func ownedProcessCrashDetail() -> String? {
        lock.lock()
        let process = ownedProcess
        let tail = ownedStderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        guard let process, !process.isRunning else { return nil }
        let status = process.terminationStatus
        let cause: String
        switch process.terminationReason {
        case .exit:
            cause = "exited with code \(status)"
        case .uncaughtSignal:
            let signalName: String
            switch status {
            case SIGKILL: signalName = "SIGKILL"
            case SIGTERM: signalName = "SIGTERM"
            case SIGABRT: signalName = "SIGABRT"
            default: signalName = "signal \(status)"
            }
            cause = "was terminated by \(signalName)"
        @unknown default:
            cause = "terminated unexpectedly (status \(status))"
        }
        let stderrSuffix = tail.isEmpty ? "" : ": \(tail)"
        return "The MiniMax H3 server process \(cause)\(stderrSuffix)"
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

            let expectedIDs = MiniMaxH3Configuration.expectedServerModelIDs(for: snapshot.targetModelID)
            let models = Self.modelEntries(from: object)
            if let exact = models.first(where: { expectedIDs.contains($0.id) }) {
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
            // "No server is listening" is a specific, verifiable claim (connection
            // refused / no listener at that socket) — never a stand-in for "the
            // probe failed for some other reason." A timeout, cancellation, or
            // other transport error means a process may well be running and just
            // not answering yet; collapsing all of those into "not running" (as
            // this used to) produces a false "no server listening" reading for a
            // server that is, in fact, up (observed 2026-09-18: a stale
            // `minimaxH3Endpoint` override pointed at a port nothing served,
            // while a real server answered on the correct default port — the
            // generic message gave no way to tell the two apart).
            guard configured else {
                return MiniMaxH3RuntimeStatus(
                    state: .notConfigured, ownership: nil,
                    detail: "Set the H3 model directory and mlx-serve executable, or start a compatible external server.",
                    loadedModelID: nil)
            }
            if Self.isConnectionRefused(error) {
                return MiniMaxH3RuntimeStatus(
                    state: .notRunning, ownership: nil,
                    detail: "No MiniMax H3 server is listening at \(snapshot.endpoint).",
                    loadedModelID: nil)
            }
            return MiniMaxH3RuntimeStatus(
                state: .failed, ownership: ownership(for: snapshot.endpoint),
                detail: "Health probe to \(snapshot.endpoint) failed: \(error.localizedDescription)",
                loadedModelID: nil)
        }
    }

    /// True only for the specific transport error that means "nothing is
    /// listening at that socket" (ECONNREFUSED, surfaced by URLSession as
    /// `.cannotConnectToHost`, plus `.cannotFindHost` as a defensive
    /// equivalent). Every other transport error (timeout, cancellation,
    /// connection loss mid-request, etc.) is a probe failure, not proof of
    /// absence, and must not be reported as "not running."
    private static func isConnectionRefused(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost
    }

    /// Entry point every H3 generation call goes through. The configured
    /// endpoint (`snapshot.endpoint` — a single user setting, `Configured
    /// endpoint` in product terms) is always tried first, unchanged from
    /// before. Only when it turns out to be a `.wrongModel` server this app
    /// does NOT own does this redirect to a separate, app-owned-only
    /// endpoint (`ensureReadyOnAlternateEndpoint`) — the external server is
    /// never touched, never restarted, never has its model reloaded. The
    /// returned status's `.endpoint` is always the one actually prepared
    /// (`Active generation endpoint`); callers (`MiniMaxH3Backend.generate`)
    /// must POST there, not to the configured endpoint, since the two can
    /// now legitimately differ for one generation call.
    func ensureReady(
        snapshot: MiniMaxH3Configuration.Snapshot,
        transport: MiniMaxH3HTTPTransport = MiniMaxH3URLSessionTransport(timeout: 8),
        progress: @escaping (Double, String) -> Void = { _, _ in }
    ) async throws -> MiniMaxH3RuntimeStatus {
        let initial = await status(snapshot: snapshot, transport: transport)
        recordReadiness(initial, modelID: snapshot.targetModelID)
        if initial.isReady { return Self.withEndpoint(initial, snapshot.endpoint) }
        if initial.state == .wrongModel {
            // Endpoint-specific, never assumed: only a server THIS manager
            // provably started (or can reclaim by kernel process identity —
            // see `reclaimableManagedServer`) at this exact endpoint counts
            // as ours to restart. "Some app-owned process is running
            // somewhere" is not enough — that process could be this app's
            // OWN alternate-endpoint server from an earlier generation,
            // which must never be assumed to be sitting at the configured
            // endpoint too.
            if ownership(for: snapshot.endpoint) == .appOwned {
                // Model switched between two tiers (e.g. Standard -> High
                // Quality): stop the previously owned server at this
                // endpoint and restart with the requested model.
                stopOwnedServer()
                return try await startAndPoll(snapshot: snapshot, transport: transport, progress: progress)
            }
            // The configured endpoint has a server this app doesn't own
            // (e.g. PID 94710, started outside the app) with a different
            // model loaded. Never touch it — prepare a separate, app-owned
            // endpoint for this generation instead.
            return try await ensureReadyOnAlternateEndpoint(
                configuredSnapshot: snapshot, transport: transport, progress: progress)
        }
        if initial.state == .failed || initial.state == .broken || initial.state == .starting {
            throw MiniMaxH3Error.serverUnhealthy(initial.detail)
        }
        return try await startAndPoll(snapshot: snapshot, transport: transport, progress: progress)
    }

    /// The configured endpoint is occupied by a server this app doesn't own
    /// and can't safely repurpose. Finds (or reuses) a separate, app-owned
    /// endpoint dedicated to this app instance, and prepares the requested
    /// model there — the configured endpoint's server is never touched by
    /// any step of this function.
    private func ensureReadyOnAlternateEndpoint(
        configuredSnapshot: MiniMaxH3Configuration.Snapshot,
        transport: MiniMaxH3HTTPTransport,
        progress: @escaping (Double, String) -> Void
    ) async throws -> MiniMaxH3RuntimeStatus {
        // Reuse the alternate-endpoint server this manager already owns
        // (e.g. a previous Quality generation's app-owned server) rather
        // than allocating a fresh port every time — the same "keep the
        // owned server, swap only the model" policy as the configured-
        // endpoint case, just anchored to a different port.
        lock.lock()
        let existingOwnedEndpoint = ownedEndpoint
        lock.unlock()

        if let existingOwnedEndpoint, existingOwnedEndpoint != configuredSnapshot.endpoint {
            var alternateSnapshot = configuredSnapshot
            alternateSnapshot.endpoint = existingOwnedEndpoint
            let alternateStatus = await status(snapshot: alternateSnapshot, transport: transport)
            if alternateStatus.isReady {
                recordReadiness(alternateStatus, modelID: configuredSnapshot.targetModelID)
                return Self.withEndpoint(alternateStatus, existingOwnedEndpoint)
            }
            if alternateStatus.state == .wrongModel {
                stopOwnedServer()
            }
            return try await startAndPoll(snapshot: alternateSnapshot, transport: transport, progress: progress)
        }

        // Allocating a fresh port has an inherent, small TOCTOU window: the
        // allocator's real bind-based check confirms a port is free, but
        // something else could claim it in the moment between that check and
        // `startOwnedServer`'s own bind. Bounded retry (never unbounded, and
        // never the same port twice) covers exactly that race without a
        // larger design change: if the process we just launched exits
        // immediately (`startAndPoll` reporting `.runtimeStartFailed`, its
        // "exited before becoming ready" signal — the closest proxy this
        // layer has to "the bind lost a race"), try one more freshly
        // allocated port before giving up.
        var excludedPorts = Set<Int>()
        if let configuredPort = MiniMaxH3Configuration.endpointURL(configuredSnapshot.endpoint)?.port {
            excludedPorts.insert(configuredPort)
        }
        var lastError: Error = MiniMaxH3Error.runtimeStartFailed(
            "No free local port was available to run MiniMax H3 alongside the existing server.")

        for _ in 0..<3 {
            guard let port = MiniMaxH3AlternatePortAllocator.firstAvailablePort(
                excluding: excludedPorts, isFree: MiniMaxH3AlternatePortAllocator.isPortFreeOnLoopback) else {
                throw lastError
            }
            excludedPorts.insert(port)
            let alternateEndpoint = "http://127.0.0.1:\(port)"
            var alternateSnapshot = configuredSnapshot
            alternateSnapshot.endpoint = alternateEndpoint

            let alternateStatus = await status(snapshot: alternateSnapshot, transport: transport)
            if alternateStatus.isReady {
                recordReadiness(alternateStatus, modelID: configuredSnapshot.targetModelID)
                return Self.withEndpoint(alternateStatus, alternateEndpoint)
            }
            if alternateStatus.state == .wrongModel {
                // Nothing but this manager can be listening on a port it
                // just allocated (freed-at-check-time) — safe to swap.
                stopOwnedServer()
            }
            do {
                return try await startAndPoll(snapshot: alternateSnapshot, transport: transport, progress: progress)
            } catch let error as MiniMaxH3Error {
                // Only the fast-fail "process exited before becoming ready"
                // shape is a plausible bind race — never retry a genuine
                // 900s timeout (a real, if slow, load in progress) or any
                // other failure; that would silently multiply a user's wait
                // instead of surfacing the real problem.
                guard case .runtimeStartFailed(let detail) = error,
                      detail.hasPrefix("The mlx-serve process exited before becoming ready") else {
                    throw error
                }
                lastError = error
                continue // plausible bind race on this port — try the next candidate
            }
        }
        throw lastError
    }

    /// Starts (or confirms) an app-owned mlx-serve at exactly `snapshot.
    /// endpoint` and polls until it reports the requested model ready. Used
    /// both for the configured endpoint (the original, unchanged behavior)
    /// and for an alternate endpoint (new) — the two are identical once a
    /// snapshot has been decided; only how that snapshot's endpoint was
    /// chosen differs.
    private func startAndPoll(
        snapshot: MiniMaxH3Configuration.Snapshot,
        transport: MiniMaxH3HTTPTransport,
        progress: @escaping (Double, String) -> Void
    ) async throws -> MiniMaxH3RuntimeStatus {
        guard MiniMaxH3Configuration.endpointURL(snapshot.endpoint) != nil else {
            throw MiniMaxH3Error.invalidEndpoint
        }
        let runtime = try resolveRuntimeExecutable(configuredPath: snapshot.runtimeExecutablePath)
        let model = try resolveModelDirectory(snapshot.modelDirectory)

        recordReadiness(state: .starting, detail: "Starting the MiniMax H3 local server…", modelID: snapshot.targetModelID)
        do {
            try startOwnedServer(runtime: runtime, model: model, endpoint: snapshot.endpoint)
        } catch let error as MiniMaxH3Error {
            recordReadiness(state: .failed, detail: error.localizedDescription, modelID: snapshot.targetModelID)
            throw error
        }
        progress(0.01, "Starting the MiniMax H3 local server…")

        do {
            // 900s (15 min), not 300s: measured real loads of the 8-bit
            // REF2VA pack (TE 26.55GB + DiT 20.07GB, one after the other,
            // per this pack's own staged-residency design) took ~350-480s
            // from this external drive alone, before sampling even starts.
            // A larger bound only changes how long a genuinely stuck load
            // waits before failing — it does not change the success path
            // for the smaller Standard/High Quality packs, which finish
            // well inside either bound.
            for _ in 0..<900 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let current = await status(snapshot: snapshot, transport: transport)
                if current.isReady {
                    recordReadiness(current, modelID: snapshot.targetModelID)
                    return Self.withEndpoint(current, snapshot.endpoint)
                }
                if current.state == .wrongModel {
                    stopOwnedServer()
                    recordReadiness(current, modelID: snapshot.targetModelID)
                    let expected = MiniMaxH3Configuration.expectedServerModelIDs(for: snapshot.targetModelID).first
                        ?? MiniMaxH3Configuration.expectedServerModelID
                    throw MiniMaxH3Error.wrongModel(
                        expected: expected,
                        actual: current.loadedModelID)
                }
                if !ownedServerIsRunning {
                    let tail = recentStderrTail
                    let detail = tail.isEmpty
                        ? "The mlx-serve process exited before becoming ready."
                        : "The mlx-serve process exited before becoming ready: \(tail)"
                    recordReadiness(state: .failed, detail: detail, modelID: snapshot.targetModelID)
                    throw MiniMaxH3Error.runtimeStartFailed(detail)
                }
            }
        } catch is CancellationError {
            stopOwnedServer()
            throw MiniMaxH3Error.cancelled
        }
        stopOwnedServer()
        recordReadiness(state: .failed, detail: "Timed out while loading the configured model.", modelID: snapshot.targetModelID)
        throw MiniMaxH3Error.runtimeStartFailed("Timed out while loading the configured model.")
    }

    private static func withEndpoint(_ status: MiniMaxH3RuntimeStatus, _ endpoint: String) -> MiniMaxH3RuntimeStatus {
        var copy = status
        copy.endpoint = endpoint
        return copy
    }

    /// Users pick a folder in a file picker, and the natural choice is often
    /// the *container* folder rather than the exact model pack inside it —
    /// exactly the folder layout every real H3 model download produces. If
    /// the configured directory itself isn't a valid pack, look one level
    /// deep for the single subdirectory that is, instead of silently
    /// reporting "Configured" and only failing once mlx-serve exits with
    /// FileNotFound at server start.
    func resolveModelDirectory(_ path: String?) throws -> String {
        guard let path, directoryExists(path) else {
            throw MiniMaxH3Error.runtimeNotConfigured("Select the local MiniMax H3 model directory.")
        }
        if Self.directoryHasModelFiles(path, fileManager: fileManager) {
            return path
        }
        if let entries = try? fileManager.contentsOfDirectory(atPath: path) {
            for entry in entries.sorted() {
                let candidate = (path as NSString).appendingPathComponent(entry)
                guard directoryExists(candidate),
                      Self.directoryHasModelFiles(candidate, fileManager: fileManager) else { continue }
                return candidate
            }
        }
        throw MiniMaxH3Error.runtimeNotConfigured(
            "The selected folder does not contain the MiniMax H3 model files (config.json). "
                + "Choose the exact \(MiniMaxH3Configuration.expectedServerModelID) folder.")
    }

    private static func directoryHasModelFiles(_ path: String, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("config.json"))
    }

    /// A configured/Advanced executable path is authoritative when present and
    /// valid. Otherwise this is the single place every H3 workflow (Normal
    /// Generate, One Shot, Auto Movie) falls back to the managed runtime
    /// installed via Settings → Models & Features → MiniMax H3, so none of
    /// them can drift onto a stale or workflow-specific readiness check.
    func resolveRuntimeExecutable(configuredPath: String?) throws -> String {
        if let configuredPath, fileManager.isExecutableFile(atPath: configuredPath) {
            return configuredPath
        }
        let managedStatus = managedRuntimeManager.evaluateStatus()
        if case .ready(let executablePath, _) = managedStatus,
           fileManager.isExecutableFile(atPath: executablePath) {
            return executablePath
        }
        let settingsPath = "Install it from Settings → Models & Features → MiniMax H3."
        switch managedStatus {
        case .notInstalled:
            throw MiniMaxH3Error.runtimeNotConfigured(
                "Its runtime is not installed. \(settingsPath)")
        case .installing:
            throw MiniMaxH3Error.runtimeNotConfigured(
                "Its runtime is still installing. Wait for it to finish in Settings → Models & Features → MiniMax H3.")
        case .updateRequired(let reason):
            throw MiniMaxH3Error.runtimeNotConfigured(
                "\(reason) Update it from Settings → Models & Features → MiniMax H3.")
        case .broken(let reason):
            throw MiniMaxH3Error.runtimeNotConfigured(
                "\(reason) Repair it from Settings → Models & Features → MiniMax H3.")
        case .ready:
            throw MiniMaxH3Error.runtimeNotConfigured(
                "Its runtime is unavailable. Repair it from Settings → Models & Features → MiniMax H3.")
        }
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
            // Bounded wait for the port to actually free up. SIGTERM alone
            // doesn't guarantee the listening socket is closed by the time
            // terminate() returns, and a caller restarting with a different
            // model (ensureReady's wrong-model switch) binds the same port
            // immediately after this call — without this, that bind can
            // race the still-exiting process.
            var waitedMicroseconds: UInt32 = 0
            while process.isRunning && waitedMicroseconds < 2_000_000 {
                usleep(100_000)
                waitedMicroseconds += 100_000
            }
        }
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        // A server an earlier session launched, reclaimed after a restart:
        // stopped only once it is proven to be that exact process.
        if process == nil, let reclaimed = reclaimableManagedServer(for: nil) {
            if getpgid(reclaimed.pid) == reclaimed.pid {
                _ = killpg(reclaimed.pid, SIGTERM)
            } else {
                _ = kill(reclaimed.pid, SIGTERM)
            }
        }
        removeManagedServerRecord()
    }

    var ownedServerPID: Int32? {
        lock.lock(); defer { lock.unlock() }
        return ownedProcess?.isRunning == true ? ownedProcess?.processIdentifier : nil
    }

    private var ownedServerIsRunning: Bool {
        lock.lock()
        let running = ownedProcess?.isRunning == true
        lock.unlock()
        return running || reclaimableManagedServer(for: nil) != nil
    }

    /// The most recent stderr output from the owned server, bounded so a
    /// long-running successful server never accumulates unbounded memory —
    /// only enough to explain a startup failure (Phase 9: preserve enough to
    /// be actionable, never dump giant raw logs into the normal UI).
    private var recentStderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        return ownedStderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func ownership(for endpoint: String) -> MiniMaxH3ServerOwnership {
        lock.lock()
        let owned = ownedEndpoint == endpoint && ownedProcess?.isRunning == true
        lock.unlock()
        if owned { return .appOwned }
        return reclaimableManagedServer(for: endpoint) != nil ? .appOwned : .externallyRunning
    }

    /// True when a currently-reported `.wrongModel` runtime state is one
    /// `ensureReady` can resolve itself, so the Generate-button preflight
    /// gate (`DefaultModelChecker.checkVideoModel()`) should let the request
    /// through rather than blocking on it. This is true for BOTH ownership
    /// cases, because `ensureReady` has a working strategy for each:
    ///  - `.appOwned` — stop and restart the server this app already owns at
    ///    the configured endpoint (`ownership(for:)`-gated branch).
    ///  - `.externallyRunning` — never touch that server; prepare a
    ///    separate, app-owned-only alternate endpoint instead
    ///    (`ensureReadyOnAlternateEndpoint` /
    ///    `MiniMaxH3AlternatePortAllocator`).
    /// The only thing that still blocks either strategy is a MiniMax H3
    /// generation already in flight — this profile's own job, or another
    /// Local Video Studio process's (`MiniMaxH3GenerationLease.
    /// activeOwner()`) — since neither strategy may disrupt a running job's
    /// runtime. If `ensureReady` later hits a genuine failure it couldn't
    /// have known about here (no free alternate port, a broken runtime
    /// executable, a real startup crash), that surfaces as its own explicit
    /// error at generation time — this predicate only decides whether
    /// attempting preparation is worth it, never whether it will succeed.
    ///
    /// `ownership` is kept as an explicit parameter (rather than dropped
    /// now that it no longer changes the answer) so call sites stay
    /// self-documenting about which case they're asking about, and so a
    /// future case that legitimately needs to distinguish them again does
    /// not have to rediscover this from scratch.
    ///
    /// Extracted as a pure, dependency-free predicate (see
    /// `DefaultModelChecker.checkVideoModel()`, the only production caller)
    /// so the decision itself is directly unit-testable without a live
    /// process, network probe, or `UserDefaults.standard`.
    static func canSafelyPrepareWrongModel(
        ownership: MiniMaxH3ServerOwnership,
        activeGenerationOwner: MiniMaxH3GenerationLease.Owner?
    ) -> Bool {
        activeGenerationOwner == nil
    }

    func startOwnedServer(runtime: String, model: String, endpoint: String) throws {
        guard let url = MiniMaxH3Configuration.endpointURL(endpoint), let port = url.port else {
            throw MiniMaxH3Error.invalidEndpoint
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime)
        process.arguments = Self.serverArguments(modelDirectory: model, port: port)
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        lock.lock()
        if let existing = ownedProcess, existing.isRunning {
            let sameConfiguration = ownedEndpoint == endpoint && ownedModelDirectory == model
            lock.unlock()
            if sameConfiguration { return }
            throw MiniMaxH3Error.runtimeStartFailed(
                "Another app-owned H3 server is already running with a different endpoint or model.")
        }
        ownedStderrTail = ""
        // Drain continuously (never leave the pipe unread — a verbose
        // subprocess would otherwise block on write() once the OS pipe
        // buffer fills) while keeping only a bounded tail in memory.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let self else { return }
            self.lock.lock()
            self.ownedStderrTail += text
            if self.ownedStderrTail.utf8.count > 4_096 {
                self.ownedStderrTail = String(self.ownedStderrTail.suffix(4_096))
            }
            self.lock.unlock()
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self.broadcastTelemetryLine(trimmed)
                }
            }
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw MiniMaxH3Error.runtimeStartFailed(error.localizedDescription)
        }
        ownedProcess = process
        ownedEndpoint = endpoint
        ownedModelDirectory = model
        lock.unlock()
        if case .identity(let identity) = inspector.inspect(pid: process.processIdentifier) {
            writeManagedServerRecord(MiniMaxManagedServerRecord(
                pid: process.processIdentifier, identity: identity, endpoint: endpoint,
                modelDirectory: model, ownerAppInstanceID: AssemblyProcessLedger.currentAppInstanceID,
                launchedAt: Date()))
        }
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
