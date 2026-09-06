import Foundation
import Combine

/// Which local runtime actually performs inference for a model.
///
/// Two runtimes exist because models may be packaged for different loaders.
/// LTX-2.3 ships weights `mlx-video-with-audio` understands; certain custom/fine-tuned
/// weights are packaged for `ltx-2-mlx`.
///
/// A new case is only justified by a runtime that is actually implemented.
enum GenerationBackendKind: String, Codable, Equatable, CaseIterable {
    /// The original backend. Runs LTX-2.3 and remains the default.
    case mlxVideoWithAudio
    /// Pure-MLX LTX-2 port (github.com/dgrauet/ltx-2-mlx). Runs custom MLX models.
    case ltx2MLX
    /// Local mlx-serve HTTP runtime for the MiniMax H3 FL2VA model pack.
    case minimaxH3

    var displayName: String {
        switch self {
        case .mlxVideoWithAudio: return "mlx-video-with-audio"
        case .ltx2MLX: return "ltx-2-mlx"
        case .minimaxH3: return "MiniMax H3 / mlx-serve"
        }
    }

    /// Model descriptors predate this enum and persist their backend as a
    /// human-readable runtime name (for example, `ltx-2-mlx`) while archived
    /// generation diagnostics use the enum raw value (`ltx2MLX`). Keep both
    /// spellings equivalent when a descriptor is routed through readiness or
    /// another registry boundary.
    func matches(descriptorBackend backend: String) -> Bool {
        let normalized = backend.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == rawValue.lowercased() || normalized == displayName.lowercased()
    }
}

/// Models that run on the `ltx-2-mlx` backend.
enum CustomLTX2MLXModelCatalog {
    public static let customModelID = "custom_ltx2_mlx"

    public static func customModel(userDefaults: UserDefaults = .standard) -> LTXModel {
        let repo = userDefaults.string(forKey: ModelRegistry.customRepositoryUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveRepo = repo.isEmpty ? "user-supplied/custom-model" : repo
        return LTXModel(
            id: customModelID,
            repo: effectiveRepo,
            displayName: "Custom LTX-2 MLX Model",
            downloadSize: "~23GB",
            supportsBuiltInAudio: true,
            qualityWarning: "User-configured model running on ltx-2-mlx.",
            recommendedStepsLower: 8,
            recommendedStepsUpper: 30,
            tips: "Runs on the ltx-2-mlx backend."
        )
    }

    static func model(id: String, userDefaults: UserDefaults = .standard) -> LTXModel? {
        if id == customModelID {
            return customModel(userDefaults: userDefaults)
        }
        if id == LTX25ModelCatalog.ltx25ExperimentalID {
            return LTX25ModelCatalog.ltx25Experimental
        }
        return nil
    }

    /// Component files the runtime resolves inside the model directory.
    static let requiredComponents = [
        "transformer-distilled.safetensors",
        "connector.safetensors",
        "vae_decoder.safetensors",
        "vae_encoder.safetensors",
    ]
}

// Backward-compatibility alias
typealias LTX2MLXModelCatalog = CustomLTX2MLXModelCatalog

/// Where the `ltx-2-mlx` runtime and its model live, and whether each is ready.
///
/// Runtime readiness and model readiness are tracked **separately** on purpose:
/// they fail independently and have different remedies (install the runtime vs
/// download 23 GB), so collapsing them into one "ready" flag would tell the
/// user to do the wrong thing.
enum LTX2MLXRuntime {
    /// User-configured path to the `ltx-2-mlx` executable. There is no default:
    /// the runtime lives outside the app bundle and its location is the user's
    /// choice, so no personal path is ever baked into the build.
    static let executablePathKey = "ltx2mlxExecutablePath"

    enum ComponentReadiness: Equatable {
        case ready(String)
        case missing(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        /// The resolved path when ready, or the reason when not.
        var detail: String {
            switch self {
            case .ready(let path): return path
            case .missing(let reason): return reason
            }
        }
    }

    struct Readiness: Equatable {
        var runtime: ComponentReadiness
        var model: ComponentReadiness

        /// Generation needs both. Neither implies the other.
        var canGenerate: Bool { runtime.isReady && model.isReady }
    }

    // MARK: Runtime

    static func executablePath(
        userDefaults: UserDefaults = .standard,
        manager: LTX2MLXRuntimeManager = .shared
    ) -> String? {
        let status = manager.evaluateStatus(userDefaults: userDefaults)
        return status.executablePath
    }

    static func runtimeReadiness(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        manager: LTX2MLXRuntimeManager = .shared
    ) -> ComponentReadiness {
        let status = manager.evaluateStatus(userDefaults: userDefaults)
        switch status {
        case .ready(let path, _):
            return .ready(path)
        case .notInstalled:
            return .missing("The ltx-2-mlx runtime is not configured or installed. Set its path or install in Preferences → Models & Features.")
        case .outdated(_, let current, let req, let missing):
            return .missing("The ltx-2-mlx runtime is outdated (v\(current) -> v\(req), missing \(missing.joined(separator: ", "))). Update it in Preferences → Models & Features.")
        case .broken(let reason):
            return .missing("The ltx-2-mlx runtime has an issue: \(reason)")
        case .installing(_, let step):
            return .missing("The ltx-2-mlx runtime is currently installing (\(step))…")
        }
    }

    // MARK: Model

    static func customModelSourceMode(userDefaults: UserDefaults = .standard) -> CustomModelSourceMode {
        let raw = userDefaults.string(forKey: ModelRegistry.customSourceModeUserDefaultsKey) ?? ""
        return CustomModelSourceMode(rawValue: raw) ?? .huggingFace
    }

    static func localModelPath(userDefaults: UserDefaults = .standard) -> String? {
        guard let path = userDefaults.string(forKey: ModelRegistry.customLocalPathUserDefaultsKey),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return path
    }

    /// Resolves whether a given directory path contains the required ltx-2-mlx model components,
    /// checking both the direct folder and any nested `snapshots/` folder.
    static func localModelDirectory(at path: String, fileManager: FileManager = .default) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        if hasRequiredComponents(in: url, fileManager: fileManager) {
            return url.path
        }
        let snapshotsDir = url.appendingPathComponent("snapshots")
        if let entries = try? fileManager.contentsOfDirectory(atPath: snapshotsDir.path) {
            for entry in entries.sorted() {
                let snap = snapshotsDir.appendingPathComponent(entry)
                if hasRequiredComponents(in: snap, fileManager: fileManager) {
                    return snap.path
                }
            }
        }
        return nil
    }

    /// Resolves the cached snapshot directory for a repo, which is what
    /// `ltx-2-mlx --model` expects — it takes a directory, not a repo ID, when
    /// the weights are already local.
    static func cachedModelDirectory(
        repository: String,
        hubDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        let hub = hubDirectory
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        let snapshots = hub
            .appendingPathComponent("models--\(repository.replacingOccurrences(of: "/", with: "--"))")
            .appendingPathComponent("snapshots")
        guard let entries = try? fileManager.contentsOfDirectory(atPath: snapshots.path) else { return nil }
        // A repo can hold several revisions; accept the first snapshot that is
        // actually complete rather than the newest-but-truncated one.
        for entry in entries.sorted() {
            let directory = snapshots.appendingPathComponent(entry)
            if hasRequiredComponents(in: directory, fileManager: fileManager) {
                return directory.path
            }
        }
        return nil
    }

    static func hasRequiredComponents(in directory: URL, fileManager: FileManager = .default) -> Bool {
        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }

        // GGUF model files (e.g. LTX-2.5-Distilled-Q4_K_M.gguf) resolve most components dynamically,
        // but the runtime's Video VAE decoder never falls back to an external cache (weights differ
        // between model versions and a wrong cross-version match would load silently — see
        // VideoDecoder.load()'s allow_external_cache_fallback=False in the runtime). It must be
        // present directly in this folder, matching the same filename patterns the runtime accepts.
        let hasGGUF = files.contains { name in
            name.hasSuffix(".gguf") && fileSize(of: directory.appendingPathComponent(name)) > 0
        }
        if hasGGUF {
            let hasVideoVAE = files.contains { name in
                (name == "vae_decoder.safetensors" ||
                 name.contains("video-vae-conv") ||
                 name.contains("vae_decoder")) &&
                fileSize(of: directory.appendingPathComponent(name)) > 0
            }
            return hasVideoVAE
        }

        // 1. Must contain at least one valid transformer safetensors file (e.g. transformer.safetensors,
        // transformer-distilled.safetensors, transformer-distilled-1.1.safetensors).
        let hasTransformer = files.contains { name in
            (name == "transformer.safetensors" ||
             name.hasPrefix("transformer-distilled") ||
             (name.contains("transformer") && name.hasSuffix(".safetensors"))) &&
            fileSize(of: directory.appendingPathComponent(name)) > 0
        }
        guard hasTransformer else { return false }

        // 2. Must contain connector for prompt embedding projection
        let hasConnector = files.contains { name in
            name == "connector.safetensors" && fileSize(of: directory.appendingPathComponent(name)) > 0
        }
        guard hasConnector else { return false }

        // 3. Must contain VAE decoder for video generation output
        let hasVaeDecoder = files.contains { name in
            name == "vae_decoder.safetensors" && fileSize(of: directory.appendingPathComponent(name)) > 0
        }
        guard hasVaeDecoder else { return false }

        // 4. Must contain VAE encoder for image/frame conditioning
        let hasVaeEncoder = files.contains { name in
            name == "vae_encoder.safetensors" && fileSize(of: directory.appendingPathComponent(name)) > 0
        }
        guard hasVaeEncoder else { return false }

        return true
    }

    private static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func modelReadiness(
        modelID: String? = nil,
        repository: String? = nil,
        localPath: String? = nil,
        sourceMode: CustomModelSourceMode? = nil,
        userDefaults: UserDefaults = .standard,
        hubDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> ComponentReadiness {
        if modelID == LTX25ModelCatalog.ltx25ExperimentalID {
            // LTX-2.5 has its own persisted location. Never read the generic
            // custom-model path here; that path may point at an LTX-2.3/10eros
            // profile and is a different model contract.
            if let localPath, !localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let resolved = LTX25ModelLocationResolver.validatedModelDirectory(
                    at: localPath, fileManager: fileManager
                ) else {
                    return .missing("The selected LTX-2.5 model directory is missing or incomplete.")
                }
                return .ready(resolved)
            }
            let resolution = LTX25ModelLocationResolver.resolve(
                userDefaults: userDefaults,
                hubDirectory: hubDirectory,
                fileManager: fileManager
            )
            if let effectivePath = resolution.effectivePath {
                return .ready(effectivePath)
            }
            return .missing(resolution.reason ?? "No complete LTX-2.5 model directory is available.")
        }

        let mode = sourceMode ?? (localPath != nil ? .local : customModelSourceMode(userDefaults: userDefaults))
        switch mode {
        case .local:
            let path: String?
            if let localPath = localPath {
                path = localPath.isEmpty ? nil : localPath
            } else if sourceMode != nil {
                // If sourceMode was explicitly frozen on the request without a valid localPath,
                // do NOT fallback to live mutable preferences.
                path = nil
            } else {
                path = self.localModelPath(userDefaults: userDefaults)
            }
            guard let path = path else {
                return .missing("No local model directory selected. Choose a local model in Preferences.")
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return .missing("The selected local model path does not exist at \(path).")
            }
            guard isDirectory.boolValue else {
                return .missing("The selected local model path is a file, but a model directory is required.")
            }
            guard let resolved = localModelDirectory(at: path, fileManager: fileManager) else {
                return .missing("The directory at \(path) does not appear to contain a complete ltx-2-mlx model (missing required .safetensors components).")
            }
            return .ready(resolved)

        case .huggingFace:
            let repo = repository
                ?? userDefaults.string(forKey: ModelRegistry.customRepositoryUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            let effectiveRepo = repo.isEmpty ? "user-supplied/custom-model" : repo
            guard let directory = cachedModelDirectory(
                repository: effectiveRepo, hubDirectory: hubDirectory, fileManager: fileManager
            ) else {
                return .missing("The \(effectiveRepo) weights are not downloaded yet.")
            }
            return .ready(directory)
        }
    }

    static func readiness(
        modelID: String? = nil,
        repository: String? = nil,
        localPath: String? = nil,
        sourceMode: CustomModelSourceMode? = nil,
        userDefaults: UserDefaults = .standard,
        hubDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Readiness {
        Readiness(
            runtime: runtimeReadiness(userDefaults: userDefaults, fileManager: fileManager),
            model: modelReadiness(
                modelID: modelID,
                repository: repository,
                localPath: localPath,
                sourceMode: sourceMode,
                userDefaults: userDefaults,
                hubDirectory: hubDirectory,
                fileManager: fileManager
            )
        )
    }
}

/// The provenance of the local LTX-2.5 model directory used by the app.
///
/// This is deliberately separate from the generic custom-model settings. A
/// user's LTX-2.3/10eros profile must never be mistaken for an LTX-2.5 model.
enum LTX25ModelLocationSource: String, Codable, Equatable, Sendable {
    case explicitSavedPath = "EXPLICIT_SAVED_PATH"
    case legacyMigratedPath = "LEGACY_MIGRATED_PATH"
    case hfCacheRecovered = "HF_CACHE_RECOVERED"
    case userSelected = "USER_SELECTED"
    case none = "NONE"
}

struct LTX25ModelLocationResolution: Equatable, Sendable {
    let savedPath: String?
    let discoveredPaths: [String]
    let effectivePath: String?
    let source: LTX25ModelLocationSource
    let reason: String?

    var isReady: Bool { effectivePath != nil }
}

/// Read-only-first persistence and recovery for the built-in LTX-2.5 model.
///
/// The resolver never downloads or deletes. A saved invalid path is preserved
/// when no safe replacement exists; if exactly one complete, LTX-2.5-compatible
/// HF snapshot exists, the missing path is recovered and the canonical key is
/// updated only after validation.
enum LTX25ModelLocationResolver {
    static let modelDirectoryKey = "ltx25ModelDirectory"
    static let locationSourceKey = "ltx25ModelLocationSource"
    static let repositoryKey = "ltx25ModelRepository"

    /// Historical keys observed in development builds. The generic custom
    /// model key is included as a *candidate* only because older builds used
    /// it for a user-selected LTX-2.5 GGUF folder. It is migrated only after
    /// strict LTX-2.5 validation; an unrelated LTX-2.3/10eros folder fails
    /// validation and is never adopted.
    static let legacyPathKeys = [
        "ltx25ModelPath",
        "ltx25LocalPath",
        "ltx25ModelLocalPath",
        "ltx2mlxLTX25ModelDirectory",
        ModelRegistry.customLocalPathUserDefaultsKey
    ]

    static func resolve(
        userDefaults: UserDefaults = .standard,
        hubDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> LTX25ModelLocationResolution {
        let saved = nonEmpty(userDefaults.string(forKey: modelDirectoryKey))

        // A valid explicit preference is authoritative. If the saved folder
        // disappeared after an upgrade, a unique validated cache candidate may
        // safely recover it; ambiguous or absent candidates leave the saved
        // value untouched for an actionable Settings error.
        if let saved {
            if let resolved = validatedModelDirectory(at: saved, fileManager: fileManager) {
                return LTX25ModelLocationResolution(
                    savedPath: saved,
                    discoveredPaths: [resolved],
                    effectivePath: resolved,
                    source: source(for: userDefaults, fallback: .explicitSavedPath),
                    reason: nil
                )
            }
            let candidates = discoverHFCacheCandidates(
                hubDirectory: hubDirectory,
                fileManager: fileManager
            )
            if candidates.count == 1, let candidate = candidates.first {
                persistResolvedPath(candidate, source: .hfCacheRecovered, userDefaults: userDefaults)
                return LTX25ModelLocationResolution(
                    savedPath: saved,
                    discoveredPaths: candidates,
                    effectivePath: candidate,
                    source: .hfCacheRecovered,
                    reason: "The previous LTX-2.5 folder was unavailable; a unique local cache was recovered."
                )
            }
            return LTX25ModelLocationResolution(
                savedPath: saved,
                discoveredPaths: candidates,
                effectivePath: nil,
                source: source(for: userDefaults, fallback: .explicitSavedPath),
                reason: candidates.count > 1
                    ? "The saved LTX-2.5 folder is unavailable and multiple caches were found; choose one in Preferences."
                    : "The saved LTX-2.5 model directory is missing or incomplete."
            )
        }

        // Migrate only a path that has been authoritatively validated. A bad
        // legacy value is ignored rather than copied into the canonical key.
        for key in legacyPathKeys {
            guard let legacy = nonEmpty(userDefaults.string(forKey: key)),
                  let resolved = validatedModelDirectory(at: legacy, fileManager: fileManager)
            else { continue }
            persistResolvedPath(resolved, source: .legacyMigratedPath, userDefaults: userDefaults)
            return LTX25ModelLocationResolution(
                savedPath: resolved,
                discoveredPaths: [resolved],
                effectivePath: resolved,
                source: .legacyMigratedPath,
                reason: nil
            )
        }

        let candidates = discoverHFCacheCandidates(
            hubDirectory: hubDirectory,
            fileManager: fileManager
        )
        if candidates.count == 1, let candidate = candidates.first {
            persistResolvedPath(candidate, source: .hfCacheRecovered, userDefaults: userDefaults)
            return LTX25ModelLocationResolution(
                savedPath: candidate,
                discoveredPaths: candidates,
                effectivePath: candidate,
                source: .hfCacheRecovered,
                reason: nil
            )
        }
        let reason: String?
        if candidates.count > 1 {
            reason = "Multiple complete LTX-2.5 model snapshots were found; choose one in Preferences."
        } else {
            reason = "No complete LTX-2.5 model directory was found in the local HF cache."
        }
        return LTX25ModelLocationResolution(
            savedPath: nil,
            discoveredPaths: candidates,
            effectivePath: nil,
            source: .none,
            reason: reason
        )
    }

    /// Validates and persists a user-selected folder. The returned path is the
    /// actual snapshot passed to the runtime, not an unvalidated parent folder.
    static func persistUserSelectedPath(
        _ path: String,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> String? {
        guard let resolved = validatedModelDirectory(at: path, fileManager: fileManager) else {
            return nil
        }
        persistResolvedPath(resolved, source: .userSelected, userDefaults: userDefaults)
        return resolved
    }

    static func validatedModelDirectory(
        at path: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard let resolved = LTX2MLXRuntime.localModelDirectory(at: path, fileManager: fileManager),
              isLTX25Configuration(in: URL(fileURLWithPath: resolved), fileManager: fileManager)
        else { return nil }
        return resolved
    }

    private static func discoverHFCacheCandidates(
        hubDirectory: URL?,
        fileManager: FileManager
    ) -> [String] {
        let hub = hubDirectory
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        guard let repositories = try? fileManager.contentsOfDirectory(
            at: hub,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: Set<String> = []
        for repository in repositories where repository.lastPathComponent.hasPrefix("models--") {
            let snapshots = repository.appendingPathComponent("snapshots", isDirectory: true)
            guard let revisions = try? fileManager.contentsOfDirectory(
                at: snapshots,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for revision in revisions {
                if let candidate = validatedModelDirectory(at: revision.path, fileManager: fileManager) {
                    candidates.insert(candidate)
                }
            }
        }
        return candidates.sorted()
    }

    private static func isLTX25Configuration(in directory: URL, fileManager: FileManager) -> Bool {
        // The installed runtime also supports the LTX-2.5 distilled GGUF
        // contract. GGUF packages do not carry the MLX `config.json`; use the
        // existing component check plus an explicit LTX-2.5 marker in the
        // package metadata/name instead of trusting a generic `.gguf` file.
        if let files = try? fileManager.contentsOfDirectory(atPath: directory.path),
           files.contains(where: { $0.lowercased().hasSuffix(".gguf") }),
           LTX25ModelLocationResolver.hasLTX25Marker(
               in: directory, files: files, fileManager: fileManager
           ) {
            return LTX2MLXRuntime.hasRequiredComponents(in: directory, fileManager: fileManager)
        }

        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let version = (object["model_version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let type = (object["model_type"] as? String)?.lowercased() ?? ""
        return version.hasPrefix("2.5") && type.contains("audiovideo")
    }

    private static func hasLTX25Marker(
        in directory: URL,
        files: [String],
        fileManager: FileManager
    ) -> Bool {
        let filenameMarker = files.contains {
            let lower = $0.lowercased()
            return lower.contains("ltx-2.5") || lower.contains("ltx2.5") || lower.contains("ltx25")
        }
        if filenameMarker { return true }
        for name in files where name.lowercased().hasSuffix(".md") || name.lowercased().hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), data.count <= 2_000_000,
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            let lower = text.lowercased()
            if lower.contains("ltx-2.5") || lower.contains("ltx2.5") || lower.contains("ltx25") {
                return true
            }
        }
        return false
    }

    private static func persistResolvedPath(
        _ path: String,
        source: LTX25ModelLocationSource,
        userDefaults: UserDefaults
    ) {
        userDefaults.set(path, forKey: modelDirectoryKey)
        userDefaults.set(source.rawValue, forKey: locationSourceKey)
        userDefaults.set(LTX25ModelCatalog.ltx25Experimental.repo, forKey: repositoryKey)
    }

    private static func source(
        for userDefaults: UserDefaults,
        fallback: LTX25ModelLocationSource
    ) -> LTX25ModelLocationSource {
        guard let raw = userDefaults.string(forKey: locationSourceKey),
              let value = LTX25ModelLocationSource(rawValue: raw)
        else { return fallback }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Explicit download flow for user-configured custom model weights.
@MainActor
final class CustomModelDownloadCoordinator: ObservableObject {
    static let shared = CustomModelDownloadCoordinator()

    enum State: Equatable {
        case idle
        case downloading(progress: Double?, message: String)
        case succeeded
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let downloader: TextEncoderDownloading
    private let isCached: (String) -> Bool
    public var storageChecker: StorageHealthService

    init(
        downloader: TextEncoderDownloading? = nil,
        isCached: ((String) -> Bool)? = nil,
        storageChecker: StorageHealthService = .shared
    ) {
        self.downloader = downloader ?? DefaultTextEncoderDownloader()
        self.isCached = isCached ?? { repository in
            LTX2MLXRuntime.cachedModelDirectory(repository: repository) != nil
        }
        self.storageChecker = storageChecker
    }

    /// Only ever called from an explicit user action.
    func startDownload(repository: String, userDefaults: UserDefaults = .standard) async {
        guard LTX2MLXRuntime.customModelSourceMode(userDefaults: userDefaults) == .huggingFace else {
            return
        }
        guard !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if case .downloading = state { return }
        if isCached(repository) {
            state = .succeeded
            return
        }

        // Authoritative storage preflight check on model cache destination volume
        let hfCacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        let storageStatus = storageChecker.check(url: hfCacheURL, for: .modelDownload(expectedBytes: nil))
        if storageStatus.isBlocked {
            state = .failed(storageStatus.message ?? "Not enough disk space for model download.")
            return
        }

        state = .downloading(progress: nil, message: "Starting download…")
        let result = await downloader.download(repository: repository) { [weak self] progress, message in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(progress: progress, message: message)
            }
        }
        switch result {
        case .success:
            state = .succeeded
        case .failure(let error):
            state = .failed(error.localizedDescription)
        }
    }

    func retry(repository: String, userDefaults: UserDefaults = .standard) async {
        guard case .failed = state else { return }
        state = .idle
        await startDownload(repository: repository, userDefaults: userDefaults)
    }
}

// Backward-compatibility alias
typealias TenErosModelDownloadCoordinator = CustomModelDownloadCoordinator
