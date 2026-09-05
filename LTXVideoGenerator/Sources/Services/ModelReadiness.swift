import Foundation
import Combine
import SwiftUI

/// The user-facing preparation state of a registered generation model.
///
/// ModelRegistry answers "does the app know about this model?". This type
/// answers the separate question "can this exact model run here right now?".
/// A model is generation-selectable only in the `.ready` state. The state is
/// intentionally descriptive so Settings can tell a user what to fix without
/// making the generation picker a setup wizard.
enum ModelReadinessStatus: Equatable, Sendable {
    case checking
    case ready
    case notDownloaded
    case notConfigured
    case runtimeMissing
    case textEncoderMissing
    case vaeMissing
    case backendUnavailable
    case serverNotRunning
    case serverUnhealthy
    case serverModelMismatch
    case invalidModelPath
    case unsupported

    var canGenerate: Bool { self == .ready }

    var displayName: String {
        switch self {
        case .checking: return "Checking…"
        case .ready: return "Ready"
        case .notDownloaded: return "Not downloaded"
        case .notConfigured: return "Not configured"
        case .runtimeMissing: return "Runtime missing"
        case .textEncoderMissing: return "Text Encoder missing"
        case .vaeMissing: return "VAE missing"
        case .backendUnavailable: return "Backend unavailable"
        case .serverNotRunning: return "Server not running"
        case .serverUnhealthy: return "Server not healthy"
        case .serverModelMismatch: return "Server model mismatch"
        case .invalidModelPath: return "Invalid model path"
        case .unsupported: return "Unsupported"
        }
    }

    /// Compact labels used in Settings. Technical details stay in `reason`.
    var shortDisplayName: String {
        switch self {
        case .ready: return "Available"
        case .notDownloaded: return "Not downloaded"
        case .notConfigured, .runtimeMissing, .textEncoderMissing, .vaeMissing:
            return "Setup required"
        case .checking: return "Checking…"
        default: return "Needs attention"
        }
    }
}

struct ModelReadiness: Identifiable, Equatable, Sendable {
    let modelID: String
    let status: ModelReadinessStatus
    let reason: String?

    var id: String { modelID }
    var canGenerate: Bool { status.canGenerate }
}

/// Read-only checks for one registered model. This layer never downloads a
/// model, starts an H3 server, or changes a user's selection.
enum ModelReadinessResolver {

    static func evaluate(
        model: ModelDescriptor,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        hubDirectory: URL? = nil
    ) -> ModelReadiness {
        if MiniMaxH3Configuration.isMiniMaxH3(modelID: model.id) {
            return evaluateH3(model: model, userDefaults: userDefaults, fileManager: fileManager)
        }

        if GenerationBackendKind.ltx2MLX.matches(descriptorBackend: model.runtime.backend) {
            return evaluateLTX2MLX(model: model, userDefaults: userDefaults, fileManager: fileManager)
        }

        guard model.capabilities.textToVideo else {
            return result(model, .unsupported, "This model does not advertise text-to-video support.")
        }

        // Official mlx-video-with-audio models use the configured Python
        // environment and ffmpeg. We deliberately check only configuration
        // here; package validation remains the existing Settings/health path.
        guard let pythonPath = userDefaults.string(forKey: "pythonPath"),
              !pythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fileManager.fileExists(atPath: pythonPath) else {
            return result(model, .runtimeMissing, "Configure a Python environment in Settings.")
        }
        guard FFmpegDetector.isAvailable else {
            return result(model, .backendUnavailable, "FFmpeg is not available on this Mac.")
        }
        guard HuggingFaceCacheChecker.isCached(
            repository: model.repository,
            hubDirectory: hubDirectory ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub")
        ) else {
            return result(model, .notDownloaded, "The model weights are not cached locally.")
        }

        let encoderID = userDefaults.string(forKey: LTXTextEncoderCatalog.selectedTextEncoderIDKey)
            ?? LTXTextEncoderCatalog.defaultTextEncoderID
        let encoder: LTXTextEncoder
        if encoderID == "custom" {
            let repo = userDefaults.string(forKey: LTXTextEncoderCatalog.customTextEncoderRepoKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            encoder = LTXTextEncoder(
                id: "custom",
                repo: repo,
                displayName: repo.isEmpty ? "Custom (not set)" : "Custom (\(repo))",
                downloadSize: "varies",
                qualityWarning: nil,
                tips: nil
            )
        } else {
            encoder = LTXTextEncoderCatalog.textEncoder(id: encoderID)
                ?? LTXTextEncoderCatalog.defaultTextEncoder
        }
        guard !encoder.repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return result(model, .notConfigured, "Set a compatible Text Encoder repository in Settings.")
        }
        guard HuggingFaceCacheChecker.isCached(
            repository: encoder.repo,
            hubDirectory: hubDirectory ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub")
        ) else {
            return result(model, .textEncoderMissing, "The selected Text Encoder is not cached locally.")
        }
        return result(model, .ready, nil)
    }

    static func evaluateAll(
        models: [ModelDescriptor],
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        hubDirectory: URL? = nil
    ) -> [ModelReadiness] {
        models.map {
            evaluate(model: $0, userDefaults: userDefaults, fileManager: fileManager, hubDirectory: hubDirectory)
        }
    }

    private static func evaluateLTX2MLX(
        model: ModelDescriptor,
        userDefaults: UserDefaults,
        fileManager: FileManager
    ) -> ModelReadiness {
        let runtimeReadiness = LTX2MLXRuntime.runtimeReadiness(
            userDefaults: userDefaults,
            fileManager: fileManager
        )
        guard runtimeReadiness.isReady else {
            return result(model, .runtimeMissing, runtimeReadiness.detail)
        }

        if let profile = CustomModelProfileStore.profile(forModelID: model.id, userDefaults: userDefaults) {
            guard directoryExists(profile.modelPath, fileManager: fileManager) else {
                return result(model, .invalidModelPath, "The configured model folder no longer exists.")
            }
            let modelStatus = CustomModelProfileStore.readiness(
                for: profile, userDefaults: userDefaults, fileManager: fileManager)
            guard modelStatus.isReady else {
                return result(model, .invalidModelPath, modelStatus.detail)
            }
            return result(model, .ready, nil)
        }

        // The built-in LTX-2.5 entry uses the same explicit local/Hugging Face
        // source settings that its backend uses. No implicit download is
        // considered ready here.
        let sourceMode = LTX2MLXRuntime.customModelSourceMode(userDefaults: userDefaults)
        let modelStatus = LTX2MLXRuntime.modelReadiness(
            repository: model.repository,
            sourceMode: sourceMode,
            userDefaults: userDefaults,
            fileManager: fileManager
        )
        guard modelStatus.isReady else {
            switch sourceMode {
            case .huggingFace:
                return result(model, .notDownloaded, modelStatus.detail)
            case .local:
                let path = LTX2MLXRuntime.localModelPath(userDefaults: userDefaults)
                return result(
                    model,
                    path == nil ? .notConfigured : .invalidModelPath,
                    modelStatus.detail)
            }
        }
        return result(model, .ready, nil)
    }

    private static func evaluateH3(
        model: ModelDescriptor,
        userDefaults: UserDefaults,
        fileManager: FileManager
    ) -> ModelReadiness {
        let snapshot = MiniMaxH3Configuration.Snapshot.current(
            forModelID: model.id, userDefaults: userDefaults)
        guard let modelDirectory = snapshot.modelDirectory,
              directoryExists(modelDirectory, fileManager: fileManager) else {
            return result(model, .notConfigured, "Choose the local H3 model folder in Settings.")
        }
        guard let runtimePath = snapshot.runtimeExecutablePath,
              fileManager.isExecutableFile(atPath: runtimePath) else {
            return result(model, .runtimeMissing, "Install or configure the local mlx-serve runtime.")
        }

        // Settings and the H3 generation path persist this exact server
        // result. Reading it is intentionally side-effect free: a picker must
        // never start a 33–49 GB model server just to populate a menu.
        let state = userDefaults.string(forKey: MiniMaxH3Configuration.lastReadinessStateKey)
            .flatMap(MiniMaxH3RuntimeState.init(rawValue:)) ?? .notRunning
        let recordedModelID = userDefaults.string(forKey: MiniMaxH3Configuration.lastReadinessModelIDKey)
        if let recordedModelID, recordedModelID != model.id {
            return result(model, .serverModelMismatch, "Readiness was recorded for a different H3 model.")
        }
        // A legacy readiness flag without a model ID cannot distinguish
        // Standard from High Quality. Never treat that ambiguous snapshot as
        // Ready; Settings can record a model-specific result on re-check.
        if state == .ready && recordedModelID == nil {
            return result(model, .serverModelMismatch, "Re-check H3 readiness to verify the selected model.")
        }
        switch state {
        case .ready:
            return result(model, .ready, nil)
        case .notConfigured:
            return result(model, .notConfigured, "Configure the H3 runtime and model folder in Settings.")
        case .notRunning:
            return result(model, .serverNotRunning, "Start the configured H3 server from Settings or Generate.")
        case .starting:
            return result(model, .serverUnhealthy, "The H3 server is still starting.")
        case .wrongModel:
            return result(model, .serverModelMismatch, "The running H3 server has a different model loaded.")
        case .failed, .broken:
            let detail = userDefaults.string(forKey: MiniMaxH3Configuration.lastReadinessDetailKey)
            return result(model, .serverUnhealthy, detail ?? "The H3 server is not healthy.")
        }
    }

    private static func directoryExists(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func result(
        _ model: ModelDescriptor,
        _ status: ModelReadinessStatus,
        _ reason: String?
    ) -> ModelReadiness {
        ModelReadiness(modelID: model.id, status: status, reason: reason)
    }
}

/// Observable cache shared by all generation workflows and the Model Manager.
/// Refresh is explicit/read-only and can safely be called after setup changes.
@MainActor
final class ModelReadinessStore: ObservableObject {
    static let shared = ModelReadinessStore()

    @Published private(set) var states: [String: ModelReadiness] = [:]
    @Published private(set) var isRefreshing = false
    private var refreshInFlight = false

    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        isRefreshing = true
        let models = ModelRegistry.shared.selectableModels()
        // The checks are filesystem/configuration reads. Keep them off the
        // main actor so a runtime probe or an external volume cannot freeze a
        // generation form. No network or download is performed here.
        let evaluated = await Task.detached(priority: .utility) {
            ModelReadinessResolver.evaluateAll(models: models)
        }.value
        states = Dictionary(uniqueKeysWithValues: evaluated.map { ($0.modelID, $0) })
        isRefreshing = false
        refreshInFlight = false
    }

    func refreshIfNeeded() async {
        if states.isEmpty { await refresh() }
    }

    func readiness(for modelID: String) -> ModelReadiness? {
        states[modelID]
    }

    func readyModels() -> [ModelDescriptor] {
        ModelRegistry.shared.selectableModels().filter { states[$0.id]?.canGenerate == true }
    }

    /// Keeps an unavailable persisted selection visible but disabled, so the
    /// app never silently switches a project to another model. Ready entries
    /// remain the only selectable choices.
    func pickerModels(selectedID: String) -> [(model: ModelDescriptor, readiness: ModelReadiness)] {
        var models = readyModels().compactMap { model -> (model: ModelDescriptor, readiness: ModelReadiness)? in
            guard let state = states[model.id] else { return nil }
            return (model, state)
        }
        if !models.contains(where: { $0.model.id == selectedID }),
           let selected = ModelRegistry.shared.descriptor(id: selectedID),
           let state = states[selectedID] {
            models.insert((selected, state), at: 0)
        }
        return models
    }
}

/// Explicit setup action for registry models backed by Hugging Face. This is
/// intentionally separate from generation and is never called by a picker or
/// a queue. Local/runtime-backed models continue to use their existing folder
/// and runtime setup controls in Settings.
@MainActor
final class ModelDownloadCoordinator: ObservableObject {
    static let shared = ModelDownloadCoordinator()

    @Published private(set) var state: TextEncoderDownloadState = .idle
    private let downloader: TextEncoderDownloading
    private let storageChecker: StorageHealthService

    init(
        downloader: TextEncoderDownloading? = nil,
        storageChecker: StorageHealthService = .shared
    ) {
        self.downloader = downloader ?? DefaultTextEncoderDownloader()
        self.storageChecker = storageChecker
    }

    func startDownload(repository: String, estimatedSizeGB: Double?) async {
        guard !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("No model repository is configured.")
            return
        }
        if case .downloading = state { return }
        if HuggingFaceCacheChecker.isCached(repository: repository) {
            state = .succeeded
            return
        }
        let expectedBytes = estimatedSizeGB.map { Int64($0 * 1_000_000_000) }
        let hub = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        let storage = storageChecker.check(
            url: hub,
            for: .modelDownload(expectedBytes: expectedBytes)
        )
        if storage.isBlocked {
            state = .failed(storage.message ?? "Not enough disk space for model download.")
            return
        }
        state = .downloading(progress: nil, message: "Starting download of \(repository)…")
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
            state = .failed(error.message)
        }
    }

    func reset() {
        if case .downloading = state { return }
        state = .idle
    }
}

/// Shared picker used by every generation workflow. Settings deliberately
/// uses the full registry instead; this view is the boundary that keeps an
/// unprepared model out of a generation request without silently changing a
/// persisted selection.
struct ReadyModelPicker: View {
    let label: String
    @Binding var selection: String
    @ObservedObject private var readinessStore = ModelReadinessStore.shared

    init(_ label: String = "Model", selection: Binding<String>) {
        self.label = label
        self._selection = selection
    }

    var body: some View {
        Picker(label, selection: $selection) {
            let entries = readinessStore.pickerModels(selectedID: selection)
            if entries.isEmpty {
                Text(readinessStore.isRefreshing ? "Checking models…" : "No ready models — open Settings")
                    .tag(selection)
                    .disabled(true)
            } else {
                ForEach(entries, id: \.model.id) { entry in
                    Text(entry.readiness.canGenerate
                         ? entry.model.selectionDisplayName
                         : "\(entry.model.selectionDisplayName) (Unavailable)")
                        .tag(entry.model.id)
                        .disabled(!entry.readiness.canGenerate)
                }
            }
        }
        .task { await readinessStore.refresh() }
    }
}
