import Foundation

/// Thread-safe controller tracking active subprocess instances for graceful cancellation.
///
/// Ensures that cancellation targets only the exact Process instance launched by the
/// application, preventing accidental signals to unrelated processes or PIDs.
/// Serves as the shared cancellation foundation across LTXBridge, LTX2MLXBackend,
/// and future long-running workers (including Director Planning).
final class ProcessCancellationTracker: @unchecked Sendable {

    static let shared = ProcessCancellationTracker()

    private let lock = NSLock()
    private var process: Process?
    private var _isCancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    var hasActiveProcess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        self._isCancelled = false
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    /// Gracefully terminates the registered process using SIGTERM.
    /// Returns true if a running process was found and signaled.
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        _isCancelled = true
        let proc = self.process
        lock.unlock()

        guard let proc, proc.isRunning else { return false }
        proc.terminate()
        return true
    }

    func reset() {
        lock.lock()
        process = nil
        _isCancelled = false
        lock.unlock()
    }
}

/// Boundary between model descriptors and generation backends.
/// The official fast path stays inside OfficialMLXAudioAdapter, which is a thin
/// wrapper over the existing LTXBridge — the bridge itself is unchanged.
protocol VideoGenerationAdapter {
    func supports(model: ModelDescriptor) -> Bool

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?)

    func cancelActiveGeneration()
}

extension VideoGenerationAdapter {
    func cancelActiveGeneration() {}
}

/// Official catalog models → existing LTXBridge (protected fast path).
final class OfficialMLXAudioAdapter: VideoGenerationAdapter {
    private let bridge = LTXBridge.shared

    func supports(model: ModelDescriptor) -> Bool {
        model.isOfficial && model.runtime.backend == "mlx-video-with-audio"
    }

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) {
        try await bridge.generate(
            request: request,
            outputPath: outputPath,
            progressHandler: progressHandler
        )
    }

    func cancelActiveGeneration() {
        bridge.cancelActiveGeneration()
    }
}

/// Derived (non-official) models that have passed the Phase 2 verification
/// gate. Unverified models are rejected before reaching the backend.
final class DerivedModelAdapter: VideoGenerationAdapter {
    private let bridge = LTXBridge.shared

    func supports(model: ModelDescriptor) -> Bool {
        !model.isOfficial && model.runtime.backend == "mlx-video-with-audio"
    }

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) {
        guard model.runtime.verified else {
            throw LTXError.generationFailed(ModelPolicyError.modelUnverified(modelID: model.id).userMessage)
        }
        guard model.revision != nil || model.localPath != nil else {
            throw LTXError.generationFailed(
                "Derived model '\(model.id)' has no pinned revision or local snapshot; refusing to generate."
            )
        }
        // Derived models reuse the official bridge only because their catalog
        // repo resolves identically; anything needing a different backend goes
        // through its own adapter (e.g. LowRAMMLXAdapter).
        return try await bridge.generate(
            request: request,
            outputPath: outputPath,
            progressHandler: progressHandler
        )
    }

    func cancelActiveGeneration() {
        bridge.cancelActiveGeneration()
    }
}

/// Derived models packaged for the ltx-2-mlx backend. Enforces the
/// same verification and pinned-revision gate as DerivedModelAdapter — being
/// on a different backend doesn't relax that requirement.
final class LTX2MLXAdapter: VideoGenerationAdapter {
    private let backend = LTX2MLXBackend()

    func supports(model: ModelDescriptor) -> Bool {
        !model.isOfficial && model.runtime.backend == "ltx-2-mlx"
    }

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) {
        guard model.runtime.verified else {
            throw LTXError.generationFailed(ModelPolicyError.modelUnverified(modelID: model.id).userMessage)
        }
        guard model.revision != nil || model.localPath != nil else {
            throw LTXError.generationFailed(
                "Derived model '\(model.id)' has no pinned revision or local snapshot; refusing to generate."
            )
        }
        // LTX2MLXModelCatalog only names the small set of built-in ltx-2-mlx
        // models (the legacy single custom-model slot, LTX-2.5 Experimental).
        // A user-defined custom model profile (`custom_profile_<UUID>`) is not
        // in that catalog and never will be — its identity, display name, and
        // local path already live on `model` itself, resolved moments ago by
        // ModelRegistry.descriptor(for:). Falling back to that descriptor
        // instead of re-deriving from a catalog it was never registered in is
        // what makes every custom profile generate-able through this adapter,
        // not just the one legacy custom-model slot the catalog was written
        // for.
        let ltxModel = LTX2MLXModelCatalog.model(id: model.id) ?? LTXModel(
            id: model.id,
            repo: model.repository,
            displayName: model.displayName,
            downloadSize: model.estimatedModelSizeGB.map { "~\(Int($0))GB" } ?? "unknown",
            supportsBuiltInAudio: model.capabilities.synchronizedAudio,
            qualityWarning: nil,
            recommendedStepsLower: 8,
            recommendedStepsUpper: 30,
            tips: model.runtime.verificationNotes
        )
        return try await backend.generate(
            request: request,
            model: ltxModel,
            outputPath: outputPath,
            progressHandler: progressHandler
        )
    }

    func cancelActiveGeneration() {
        backend.cancelActiveGeneration()
    }
}

/// Picks the adapter for a descriptor. Order matters: first match wins.
final class AdapterRegistry {
    static let shared = AdapterRegistry()

    private(set) var adapters: [VideoGenerationAdapter]

    init(adapters: [VideoGenerationAdapter]? = nil) {
        self.adapters = adapters ?? [OfficialMLXAudioAdapter(), DerivedModelAdapter(), LTX2MLXAdapter()]
    }

    func register(_ adapter: VideoGenerationAdapter) {
        adapters.append(adapter)
    }

    func adapter(for model: ModelDescriptor) -> VideoGenerationAdapter? {
        adapters.first { $0.supports(model: model) }
    }

    func cancelActiveGeneration() {
        for adapter in adapters {
            adapter.cancelActiveGeneration()
        }
    }
}
