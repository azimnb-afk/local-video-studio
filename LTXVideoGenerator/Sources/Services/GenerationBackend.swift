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

    var displayName: String {
        switch self {
        case .mlxVideoWithAudio: return "mlx-video-with-audio"
        case .ltx2MLX: return "ltx-2-mlx"
        }
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

    static func executablePath(userDefaults: UserDefaults = .standard) -> String? {
        guard let path = userDefaults.string(forKey: executablePathKey),
              !path.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return path
    }

    static func runtimeReadiness(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> ComponentReadiness {
        guard let path = executablePath(userDefaults: userDefaults) else {
            return .missing("The ltx-2-mlx runtime is not configured. Set its path in Preferences → General.")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .missing("The configured ltx-2-mlx runtime was not found at \(path).")
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            return .missing("The configured ltx-2-mlx runtime at \(path) is not executable.")
        }
        return .ready(path)
    }

    // MARK: Model

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

    private static func hasRequiredComponents(in directory: URL, fileManager: FileManager) -> Bool {
        for component in LTX2MLXModelCatalog.requiredComponents {
            let file = directory.appendingPathComponent(component)
            // Follows the cache's symlinks into blobs/, and a zero-byte or
            // still-downloading blob does not count as present.
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size <= 0 { return false }
        }
        return true
    }

    static func modelReadiness(
        repository: String,
        hubDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> ComponentReadiness {
        guard let directory = cachedModelDirectory(
            repository: repository, hubDirectory: hubDirectory, fileManager: fileManager
        ) else {
            return .missing("The \(repository) weights are not downloaded yet.")
        }
        return .ready(directory)
    }

    static func readiness(
        repository: String,
        userDefaults: UserDefaults = .standard,
        hubDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Readiness {
        Readiness(
            runtime: runtimeReadiness(userDefaults: userDefaults, fileManager: fileManager),
            model: modelReadiness(repository: repository, hubDirectory: hubDirectory, fileManager: fileManager)
        )
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

    init(
        downloader: TextEncoderDownloading? = nil,
        isCached: ((String) -> Bool)? = nil
    ) {
        self.downloader = downloader ?? DefaultTextEncoderDownloader()
        self.isCached = isCached ?? { repository in
            LTX2MLXRuntime.cachedModelDirectory(repository: repository) != nil
        }
    }

    /// Only ever called from an explicit user action.
    func startDownload(repository: String) async {
        guard !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if case .downloading = state { return }
        if isCached(repository) {
            state = .succeeded
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

    func retry(repository: String) async {
        guard case .failed = state else { return }
        state = .idle
        await startDownload(repository: repository)
    }
}

// Backward-compatibility alias
typealias TenErosModelDownloadCoordinator = CustomModelDownloadCoordinator
