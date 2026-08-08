import Foundation

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
}

/// Picks the adapter for a descriptor. Order matters: first match wins.
final class AdapterRegistry {
    static let shared = AdapterRegistry()

    private(set) var adapters: [VideoGenerationAdapter]

    init(adapters: [VideoGenerationAdapter]? = nil) {
        self.adapters = adapters ?? [OfficialMLXAudioAdapter(), DerivedModelAdapter()]
    }

    func register(_ adapter: VideoGenerationAdapter) {
        adapters.append(adapter)
    }

    func adapter(for model: ModelDescriptor) -> VideoGenerationAdapter? {
        adapters.first { $0.supports(model: model) }
    }
}
