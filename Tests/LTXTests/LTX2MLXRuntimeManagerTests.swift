import Foundation
@testable import LTXVideoGeneratorCore

func runLTX2MLXRuntimeManagerTests(_ t: TestKit) {
    t.suite("LTX2MLXRuntimeManager & Capability Contracts") {
        // MARK: - A. Manifest & Capability validation
        let validManifest = LTX2MLXRuntimeManifest(
            schemaVersion: 1,
            runtime: "ltx-2-mlx",
            runtimeVersion: "0.2.0-preview4",
            sourceRevision: "ead83e2",
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "audio_decode_v2", "video_decoder_weights_v2", "ltx25_official_video_vae_v1", "ltx25_audio_toggle_v1"]
        )
        t.check(validManifest.isCompatible, "Complete manifest must be compatible")
        t.checkEqual(LTX2MLXRuntimeManifest.pinnedSourceRevision, "ead83e2", "Pinned revision matches the clean public runtime export (privacy-sanitized history)")
        t.checkEqual(LTX2MLXRuntimeManifest.pinnedRepoURL, "https://github.com/azimnb-afk/ltx-2-mlx.git", "Runtime source points at the user-owned public fork")
        t.checkEqual(validManifest.missingCapabilities, [], "No missing capabilities on full manifest")

        // Missing audio_decode_v2
        let missingAudio = LTX2MLXRuntimeManifest(
            schemaVersion: 1,
            runtime: "ltx-2-mlx",
            runtimeVersion: "0.2.0-preview4",
            sourceRevision: "a0bb232",
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "video_decoder_weights_v2", "ltx25_official_video_vae_v1", "ltx25_audio_toggle_v1"]
        )
        t.check(!missingAudio.isCompatible, "Manifest missing audio_decode_v2 must not be compatible")
        t.checkEqual(missingAudio.missingCapabilities, ["audio_decode_v2"], "Missing audio_decode_v2 correctly identified")

        // Missing streaming capability
        let missingStreaming = LTX2MLXRuntimeManifest(
            schemaVersion: 1,
            runtime: "ltx-2-mlx",
            runtimeVersion: "0.1.0",
            sourceRevision: "1111111",
            capabilities: ["ltx25_gguf", "audio_decode_v2", "video_decoder_weights_v2", "ltx25_official_video_vae_v1", "ltx25_audio_toggle_v1"]
        )
        t.check(!missingStreaming.isCompatible, "Manifest missing gguf_block_streaming_v1 must not be compatible")
        t.checkEqual(missingStreaming.missingCapabilities, ["gguf_block_streaming_v1"], "Missing gguf_block_streaming_v1 correctly identified")

        // Missing the VideoDecoder strict-loading fix: an older runtime (e.g.
        // pinned at c49bcc1) that can produce full-screen noise video must
        // never be classified as compatible/Ready.
        let missingVideoDecoderFix = LTX2MLXRuntimeManifest(
            schemaVersion: 1,
            runtime: "ltx-2-mlx",
            runtimeVersion: "0.2.0-preview4",
            sourceRevision: "c49bcc1",
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "audio_decode_v2", "ltx25_official_video_vae_v1", "ltx25_audio_toggle_v1"]
        )
        t.check(!missingVideoDecoderFix.isCompatible,
                "A runtime without the VideoDecoder strict-loading fix must not be compatible")
        t.checkEqual(missingVideoDecoderFix.missingCapabilities, ["video_decoder_weights_v2"],
                     "Missing video_decoder_weights_v2 correctly identified")

        // Missing the official LTX-2.5 Video VAE loader (decoder./encoder.
        // prefix + Conv3D layout remap): a runtime pinned at 9c5819b already
        // has the strict=True fix but cannot load the official raw
        // Lightricks/LTX-2.5 combined VAE checkpoint at all.
        let missingOfficialVAESupport = LTX2MLXRuntimeManifest(
            schemaVersion: 1,
            runtime: "ltx-2-mlx",
            runtimeVersion: "0.2.0-preview4",
            sourceRevision: "9c5819b",
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "audio_decode_v2", "video_decoder_weights_v2", "ltx25_audio_toggle_v1"]
        )
        t.check(!missingOfficialVAESupport.isCompatible,
                "A runtime without official LTX-2.5 Video VAE support must not be compatible")
        t.checkEqual(missingOfficialVAESupport.missingCapabilities, ["ltx25_official_video_vae_v1"],
                     "Missing ltx25_official_video_vae_v1 correctly identified")

        // Missing the Generate Audio toggle fix: a runtime that doesn't
        // recognize --no-audio at all must not be considered Ready, since
        // passing --no-audio to it would be a hard CLI parse error rather
        // than either honoring or gracefully ignoring the request.
        let missingAudioToggleSupport = LTX2MLXRuntimeManifest(
            schemaVersion: 1,
            runtime: "ltx-2-mlx",
            runtimeVersion: "0.2.0-preview4",
            sourceRevision: "a99a9c7",
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "audio_decode_v2", "video_decoder_weights_v2", "ltx25_official_video_vae_v1"]
        )
        t.check(!missingAudioToggleSupport.isCompatible,
                "A runtime without the Generate Audio toggle fix must not be compatible")
        t.checkEqual(missingAudioToggleSupport.missingCapabilities, ["ltx25_audio_toggle_v1"],
                     "Missing ltx25_audio_toggle_v1 correctly identified")

        // MARK: - B. Isolation of Personal vs Dev AppStorageDirectory
        let runtimesURL = AppStorageDirectory.runtimesDirectory
        t.check(runtimesURL.path.contains("Runtimes"), "Runtimes directory must contain 'Runtimes'")
        t.check(FileManager.default.fileExists(atPath: runtimesURL.path), "Runtimes directory must exist on disk")

        // MARK: - C. Fresh user simulation with clean UserDefaults suite
        let testSuiteName = "test.ltx2mlx.runtime.\(UUID().uuidString)"
        let tempDefaults = UserDefaults(suiteName: testSuiteName)!
        defer { tempDefaults.removePersistentDomain(forName: testSuiteName) }

        let manager = LTX2MLXRuntimeManager(fileManager: .default, userDefaults: tempDefaults)

        // Set non-existent override -> should be broken
        let dummyPath = "/tmp/nonexistent_ltx2mlx_binary_\(UUID().uuidString)"
        manager.setOverrideExecutablePath(dummyPath)
        t.checkEqual(manager.overrideExecutablePath(), dummyPath, "Override path must be set")

        let brokenStatus = manager.evaluateStatus()
        if case .broken = brokenStatus {
            t.check(true, "Nonexistent override must evaluate to .broken")
        } else {
            t.check(false, "Expected .broken for nonexistent override path")
        }

        // Clear override -> should return to managed evaluation
        manager.setOverrideExecutablePath(nil)
        t.check(manager.overrideExecutablePath() == nil, "Override path must be nil after clear")

        // MARK: - D. Readiness fails closed when runtime is missing
        let readiness = LTX2MLXRuntime.runtimeReadiness(userDefaults: tempDefaults, manager: manager)
        if !FileManager.default.fileExists(atPath: manager.managedExecutableURL.path) {
            t.check(!readiness.isReady, "Readiness must fail closed when runtime is not installed")
            t.check(
                readiness.detail.contains("not installed") || readiness.detail.contains("not configured") || readiness.detail.contains("issue"),
                "Detail must explain not installed, not configured, or issue"
            )
        }

        // MARK: - E. Managed runtime path isolation & self-containment contracts
        let managedExec = manager.managedExecutableURL.path
        t.check(managedExec.contains("LocalVideoStudio"), "Managed executable must reside inside AppStorageDirectory")
        t.check(!managedExec.contains("ltx23appdev"), "Managed executable must never point to developer checkout")
        t.check(!managedExec.contains("ltx-2-mlx-ltx25-poc"), "Managed executable must never point to PoC repository")

        // MARK: - F. GGUF precedence contract
        let modelDirURL = URL(fileURLWithPath: "/tmp/mock_model_dir")
        t.check(LTX2MLXRuntimeManifest.requiredCapabilities.contains("ltx25_gguf"), "Runtime requires ltx25_gguf capability")
        t.check(LTX2MLXRuntimeManifest.requiredCapabilities.contains("gguf_block_streaming_v1"), "Runtime requires gguf_block_streaming_v1 capability")
        t.check(LTX2MLXRuntimeManifest.requiredCapabilities.contains("audio_decode_v2"), "Runtime requires audio_decode_v2 capability")
        t.check(LTX2MLXRuntimeManifest.requiredCapabilities.contains("video_decoder_weights_v2"), "Runtime requires video_decoder_weights_v2 capability")
        t.check(LTX2MLXRuntimeManifest.requiredCapabilities.contains("ltx25_official_video_vae_v1"), "Runtime requires ltx25_official_video_vae_v1 capability")
        t.check(LTX2MLXRuntimeManifest.requiredCapabilities.contains("ltx25_audio_toggle_v1"), "Runtime requires ltx25_audio_toggle_v1 capability")
    }
}
