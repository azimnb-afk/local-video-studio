import Foundation
import Combine
import SwiftUI

/// The user-facing preparation state of a registered generation model.
///
/// ModelRegistry answers "does the app know about this model?". This type
/// answers the separate question "can this exact model run here right now?".
/// Ready models and configured H3 models awaiting startup are selectable. The state is
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

    var canGenerate: Bool { self == .ready || self == .serverNotRunning }

    /// Whether this model has enough local configuration (weights, model
    /// directory, required runtime/environment) to be offered as a
    /// selectable picker row — independent of `canGenerate`, the exact
    /// right-now runtime state.
    ///
    /// VISIBLE / SELECTABLE / GENERATABLE_NOW are three separate questions
    /// (docs/MODEL_REGISTRY_GUIDE.md): every registered user-facing model is
    /// always VISIBLE; this property answers SELECTABLE; `canGenerate`
    /// answers GENERATABLE_NOW. An H3 tier whose shared server currently has
    /// a *different* tier loaded (`.serverModelMismatch`), or is simply idle
    /// (`.serverNotRunning`), is fully configured and must stay selectable —
    /// picking it is what triggers the existing runtime start/switch at
    /// Generate time. Only a genuine setup gap (no model directory, no
    /// runtime, no cached weights, etc.) makes a model unselectable.
    var isConfigured: Bool {
        switch self {
        case .notConfigured, .runtimeMissing, .textEncoderMissing, .vaeMissing,
             .backendUnavailable, .invalidModelPath, .unsupported, .notDownloaded:
            return false
        case .checking, .ready, .serverNotRunning, .serverUnhealthy, .serverModelMismatch:
            return true
        }
    }

    /// Short bilingual status shown next to a picker row's name. `nil` for
    /// `.ready` so the common case stays a clean, unadorned name. This never
    /// controls whether the row exists — only its label and (via
    /// `isConfigured`) whether it's selectable.
    var pickerStatusLabel: String? {
        switch self {
        case .ready: return nil
        case .checking: return "確認中 (Checking)"
        case .notDownloaded: return "未ダウンロード (Not Downloaded)"
        case .notConfigured: return "未設定 (Not Configured)"
        case .runtimeMissing: return "ランタイム未設定 (Runtime Missing)"
        case .textEncoderMissing: return "Text Encoder未設定 (Text Encoder Missing)"
        case .vaeMissing: return "VAE未設定 (VAE Missing)"
        case .backendUnavailable: return "バックエンド利用不可 (Backend Unavailable)"
        case .serverNotRunning: return "停止中 (Stopped)"
        case .serverUnhealthy: return "読み込み中 (Loading)"
        case .serverModelMismatch: return "別モデル稼働中 (Wrong Model)"
        case .invalidModelPath: return "モデルパス不正 (Invalid Path)"
        case .unsupported: return "非対応 (Unsupported)"
        }
    }

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
        case .serverNotRunning: return "Ready to start"
        case .serverUnhealthy: return "Server not healthy"
        case .serverModelMismatch: return "Server model mismatch"
        case .invalidModelPath: return "Invalid model path"
        case .unsupported: return "Unsupported"
        }
    }

    /// Compact labels used in Settings. Technical details stay in `reason`.
    var shortDisplayName: String {
        switch self {
        case .ready, .serverNotRunning: return "Available"
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

    /// The label a picker row shows: the model's own name, plus — unless
    /// it's Ready — a short bilingual status suffix. Readiness only ever
    /// affects this text and whether the row is selectable; it never
    /// controls whether the row exists (see `ModelReadinessStore.pickerModels`).
    func pickerRowLabel(_ baseName: String) -> String {
        guard let suffix = status.pickerStatusLabel else { return baseName }
        return "\(baseName) · \(suffix)"
    }
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
            return evaluateLTX2MLX(
                model: model,
                userDefaults: userDefaults,
                fileManager: fileManager,
                hubDirectory: hubDirectory
            )
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
        fileManager: FileManager,
        hubDirectory: URL?
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

        // The built-in LTX-2.5 entry has a dedicated persisted location and
        // safe HF-cache recovery path. Generic custom-model preferences remain
        // reserved for the user's LTX-2.3/10eros profile.
        let sourceMode = LTX2MLXRuntime.customModelSourceMode(userDefaults: userDefaults)
        let modelStatus = LTX2MLXRuntime.modelReadiness(
            modelID: model.id,
            repository: model.repository,
            sourceMode: sourceMode,
            userDefaults: userDefaults,
            hubDirectory: hubDirectory,
            fileManager: fileManager
        )
        guard modelStatus.isReady else {
            if model.id == LTX25ModelCatalog.ltx25ExperimentalID {
                let resolution = LTX25ModelLocationResolver.resolve(
                    userDefaults: userDefaults,
                    hubDirectory: hubDirectory,
                    fileManager: fileManager
                )
                return result(
                    model,
                    resolution.savedPath == nil ? .notConfigured : .invalidModelPath,
                    resolution.reason ?? modelStatus.detail
                )
            }
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
        if model.id == LTX25ModelCatalog.ltx25ExperimentalID {
            let resolution = LTX25ModelLocationResolver.resolve(
                userDefaults: userDefaults,
                hubDirectory: hubDirectory,
                fileManager: fileManager
            )
            let reason: String?
            switch resolution.source {
            case .hfCacheRecovered:
                reason = "Existing local LTX-2.5 cache recovered."
            case .legacyMigratedPath:
                reason = "Existing LTX-2.5 model preference migrated."
            default:
                reason = nil
            }
            return result(model, .ready, reason)
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

        guard fileManager.fileExists(atPath: (modelDirectory as NSString).appendingPathComponent("config.json")) else {
            return result(model, .invalidModelPath, "Choose the H3 model pack containing config.json.")
        }

        // Settings and the H3 generation path persist this exact server
        // result, keyed by this model's own ID. Reading it is intentionally
        // side-effect free: a picker must never start a 33–69 GB model
        // server just to populate a menu. Because the key is per-model,
        // recording a result for one H3 tier can never be misread as this
        // tier's result — see docs/MODEL_REGISTRY_GUIDE.md.
        let state = userDefaults.string(forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: model.id))
            .flatMap(MiniMaxH3RuntimeState.init(rawValue:)) ?? .notRunning
        // An idle server has no loaded identity to compare. Generation uses
        // ensureReady with this model's frozen configuration to start it.
        if state == .notRunning || state == .notConfigured {
            return result(model, .serverNotRunning, "The configured local H3 server starts when generation begins.")
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
            let detail = userDefaults.string(forKey: MiniMaxH3Configuration.lastReadinessDetailKey(for: model.id))
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

    /// Models whose exact right-now runtime state allows starting a
    /// generation immediately, with no extra step. NOT the picker's
    /// population source — see `pickerModels`. Kept for callers that
    /// genuinely need "generatable this instant" (e.g. a future "Quick
    /// Generate with whatever's ready" action), distinct from what the
    /// picker shows.
    func readyModels() -> [ModelDescriptor] {
        ModelRegistry.shared.selectableModels().filter { states[$0.id]?.canGenerate == true }
    }

    /// Every registered, user-facing model — always, regardless of runtime
    /// readiness. This is `ModelRegistry.selectableModels()`, not
    /// `readyModels()`: the absolute product rule this exists to satisfy is
    /// "Generate画面から選択できないユーザー向けモデルは、ユーザーにとって
    /// 存在しない" (docs/MODEL_REGISTRY_GUIDE.md), so a registered model must
    /// never vanish from the picker just because its runtime happens to be
    /// busy, stopped, or mid-load of a sibling tier — a model's *visibility*
    /// and its *current generatability* are different questions. Readiness
    /// controls only two things a row-consumer should read: the status label
    /// (`ModelReadiness.pickerRowLabel`) and whether the row is selectable
    /// right now (`ModelReadinessStatus.isConfigured`) — never whether the
    /// row exists.
    ///
    /// The persisted selection is still guaranteed a row even if it somehow
    /// fell out of the registered set (e.g. a deleted custom profile).
    func pickerModels(selectedID: String) -> [(model: ModelDescriptor, readiness: ModelReadiness)] {
        Self.composePickerRows(
            registered: ModelRegistry.shared.selectableModels(),
            states: states,
            selectedID: selectedID,
            descriptor: { ModelRegistry.shared.descriptor(id: $0) }
        )
    }

    /// Pure composition of `pickerModels`, extracted so tests can drive the
    /// *exact* production algorithm against fixture data instead of a
    /// hand-reimplemented mirror. A mirror is exactly how the 2026-09-18
    /// ready-only-filter regression (H3 tiers silently vanishing from the
    /// picker) went uncaught by the existing test suite — see the
    /// PICKER_VISIBILITY tests in OneShotModelPickerTests.swift.
    nonisolated static func composePickerRows(
        registered: [ModelDescriptor],
        states: [String: ModelReadiness],
        selectedID: String,
        descriptor: (String) -> ModelDescriptor?
    ) -> [(model: ModelDescriptor, readiness: ModelReadiness)] {
        var rows = registered.map { model -> (model: ModelDescriptor, readiness: ModelReadiness) in
            let readiness = states[model.id] ?? ModelReadiness(modelID: model.id, status: .checking, reason: nil)
            return (model, readiness)
        }
        if !rows.contains(where: { $0.model.id == selectedID }),
           let selected = descriptor(selectedID) {
            let readiness = states[selectedID] ?? ModelReadiness(modelID: selectedID, status: .checking, reason: nil)
            rows.insert((selected, readiness), at: 0)
        }
        return rows
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

/// Shared picker used by every generation workflow. Every registered,
/// user-facing model is always shown (see `ModelReadinessStore.pickerModels`)
/// — readiness only changes a row's status label and whether it's currently
/// selectable, never whether it appears. This never silently changes a
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
                Text(readinessStore.isRefreshing ? "Checking models…" : "No models registered — open Settings")
                    .tag(selection)
                    .disabled(true)
            } else {
                ForEach(entries, id: \.model.id) { entry in
                    Text(entry.readiness.pickerRowLabel(entry.model.selectionDisplayName))
                        .tag(entry.model.id)
                        .disabled(!entry.readiness.status.isConfigured)
                }
            }
        }
        .task { await readinessStore.refresh() }
    }
}
