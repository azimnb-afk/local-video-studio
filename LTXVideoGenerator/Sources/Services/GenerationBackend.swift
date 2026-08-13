import Foundation
import Combine

/// Which local runtime actually performs inference for a model.
///
/// Two runtimes exist because the two model families are packaged for two
/// different loaders, not because the app wants a plugin system. LTX-2.3 ships
/// weights `mlx-video-with-audio` understands; 10Eros ships weights packaged
/// for `ltx-2-mlx` (its model card says so, and its transformer carries gated
/// attention and a group-size-32 quantization the other loader cannot read).
///
/// A new case is only justified by a runtime that is actually implemented.
enum GenerationBackendKind: String, Codable, Equatable, CaseIterable {
    /// The original backend. Runs LTX-2.3 and remains the default.
    case mlxVideoWithAudio
    /// Pure-MLX LTX-2 port (github.com/dgrauet/ltx-2-mlx). Runs 10Eros.
    case ltx2MLX

    var displayName: String {
        switch self {
        case .mlxVideoWithAudio: return "mlx-video-with-audio"
        case .ltx2MLX: return "ltx-2-mlx"
        }
    }
}

/// Models that run on the `ltx-2-mlx` backend.
///
/// Deliberately separate from `LTXModelCatalog`: that catalog is also the
/// ungated model picker in Preferences, and 10Eros must only ever appear
/// through `ModelRegistry`'s adult-content gate. Keeping the tables apart is
/// what stops a sensitive model from leaking into a general-purpose list.
enum LTX2MLXModelCatalog {
    /// The one 10Eros variant verified against this backend. Its ID matches the
    /// `ModelRegistry` descriptor so policy, licensing and gating line up.
    static let tenEros13DMDQ4 = LTXModel(
        id: "10eros_v13_dmd_q4",
        repo: "MLXBits/ltx-2.3-10eros-v1.3-dmd-mlx-q4",
        displayName: "10Eros v1.3 DMD (MLX int4)",
        downloadSize: "~23GB",
        // The package ships audio_vae + vocoder, so the pipeline produces a
        // synchronized audio track like the LTX-2.3 unified models do.
        supportsBuiltInAudio: true,
        qualityWarning: "Quantized int4: smaller footprint with some loss of fine detail versus int8.",
        recommendedStepsLower: 8,
        recommendedStepsUpper: 30,
        tips: "Distilled (DMD) — the distillation is baked into the transformer, so few steps are expected."
    )

    static let all: [LTXModel] = [tenEros13DMDQ4]

    static func model(id: String) -> LTXModel? {
        all.first { $0.id == id }
    }

    /// Component files the runtime resolves inside the model directory. Used to
    /// tell a complete download from a directory an interrupted one left behind.
    static let requiredComponents = [
        "transformer-distilled.safetensors",
        "connector.safetensors",
        "vae_decoder.safetensors",
        "vae_encoder.safetensors",
    ]
}

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

/// Explicit download flow for the 10Eros weights.
///
/// Reuses the existing Hugging Face downloader rather than adding a second
/// download engine — that service is already repository-generic. The state
/// machine mirrors the Text Encoder flow (Missing → Download → Downloading →
/// Ready → Retry) and, critically, never starts on its own: turning on Adult
/// Content Mode must not trigger a 23 GB transfer.
@MainActor
final class TenErosModelDownloadCoordinator: ObservableObject {
    static let shared = TenErosModelDownloadCoordinator()

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
    func startDownload(repository: String = LTX2MLXModelCatalog.tenEros13DMDQ4.repo) async {
        if case .downloading = state { return }
        if isCached(repository) {
            state = .succeeded
            return
        }
        state = .downloading(progress: nil, message: "Starting download…")
        let result = await downloader.download(repository: repository) { [weak self] progress, message in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                // A nil progress stays nil: the underlying tool not reporting a
                // percentage is not a reason to invent one.
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

    func retry(repository: String = LTX2MLXModelCatalog.tenEros13DMDQ4.repo) async {
        guard case .failed = state else { return }
        state = .idle
        await startDownload(repository: repository)
    }
}
