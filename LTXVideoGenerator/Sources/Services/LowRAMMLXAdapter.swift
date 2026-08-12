import Foundation

/// Low-RAM adapter boundary, isolated from the official fast path.
///
/// Targets the block-streaming backend family (dgrauet/ltx-2-mlx `--low-ram`)
/// which is the credible 16GB candidate per Deep Research — quantization alone
/// does not make 16GB safe. The backend is invoked as its own subprocess so
/// process exit remains a hard memory-reclamation boundary.
///
/// STATUS: Runtime Verification Pending. The adapter refuses to run until a
/// low-RAM backend has been configured AND verified on real hardware; it never
/// silently substitutes the official path.
final class LowRAMMLXAdapter: VideoGenerationAdapter {

    static let backendPathKey = "lowRAMBackendPath"        // checkout of dgrauet/ltx-2-mlx
    static let backendVerifiedKey = "lowRAMBackendVerified" // set true only after compat_lab-style verification

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var configuredBackendPath: String? {
        guard let path = userDefaults.string(forKey: Self.backendPathKey), !path.isEmpty else { return nil }
        return path
    }

    var backendVerified: Bool {
        userDefaults.bool(forKey: Self.backendVerifiedKey)
    }

    func supports(model: ModelDescriptor) -> Bool {
        guard FeatureFlags.isEnabled(.lowRAMAdapterV1, userDefaults: userDefaults) else { return false }
        // Only models explicitly packaged for the low-RAM backend.
        return model.runtime.backend == "ltx-2-mlx"
    }

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) {
        guard let backendPath = configuredBackendPath else {
            throw LTXError.generationFailed(
                "Low-RAM backend not configured. Set a local ltx-2-mlx checkout path in Preferences (key: \(Self.backendPathKey))."
            )
        }
        guard FileManager.default.fileExists(atPath: backendPath) else {
            throw LTXError.generationFailed("Low-RAM backend path does not exist: \(backendPath)")
        }
        guard backendVerified else {
            throw LTXError.generationFailed(
                "Low-RAM backend is present but not verified on this hardware yet (Runtime Verification Pending). "
                + "Run scripts/lowram_bench.sh and record results before enabling."
            )
        }
        // Verified backends would be invoked here as a subprocess mirroring
        // scripts/lowram_bench.sh. Until a verification pass exists on real
        // low-RAM hardware this path is intentionally unreachable — no fake
        // implementation is shipped as working.
        throw LTXError.generationFailed(
            "Low-RAM adapter runtime integration is gated on hardware verification."
        )
    }
}
