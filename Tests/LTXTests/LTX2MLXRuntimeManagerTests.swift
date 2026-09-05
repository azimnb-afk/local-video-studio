import Foundation
@testable import LTXVideoGeneratorCore

func runLTX2MLXRuntimeManagerTests(_ t: TestKit) {
    t.suite("LTX2MLXRuntimeManager & Capability Contracts") {
        // MARK: - A. Manifest & Capability validation
        let validManifest = LTX2MLXRuntimeManifest(
            schemaVersion: 1,
            runtime: "ltx-2-mlx",
            runtimeVersion: "0.2.0-preview4",
            sourceRevision: "11a0d33",
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "audio_decode_v2", "video_decoder_weights_v2", "ltx25_official_video_vae_v1", "ltx25_audio_toggle_v1", "ltx25_official_video_vae_encoder_v1"]
        )
        t.check(validManifest.isCompatible, "Complete manifest must be compatible")
        t.checkEqual(LTX2MLXRuntimeManifest.pinnedSourceRevision, "b30079e", "Pinned revision matches the legacy checkpoint config fallback fix")
        t.checkEqual(LTX2MLXRuntimeManifest.pinnedRepoURL, "https://github.com/azimnb-afk/ltx-2-mlx.git", "Runtime source points at the user-owned public fork")
        t.checkEqual(validManifest.missingCapabilities, [], "No missing capabilities on full manifest")

        // Missing audio_decode_v2
        let missingAudio = LTX2MLXRuntimeManifest(
            schemaVersion: 1,
            runtime: "ltx-2-mlx",
            runtimeVersion: "0.2.0-preview4",
            sourceRevision: "a0bb232",
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "video_decoder_weights_v2", "ltx25_official_video_vae_v1", "ltx25_audio_toggle_v1", "ltx25_official_video_vae_encoder_v1"]
        )
        t.check(!missingAudio.isCompatible, "Manifest missing audio_decode_v2 must not be compatible")
        t.checkEqual(missingAudio.missingCapabilities, ["audio_decode_v2"], "Missing audio_decode_v2 correctly identified")

        // Missing streaming capability
        let missingStreaming = LTX2MLXRuntimeManifest(
            schemaVersion: 1,
            runtime: "ltx-2-mlx",
            runtimeVersion: "0.1.0",
            sourceRevision: "1111111",
            capabilities: ["ltx25_gguf", "audio_decode_v2", "video_decoder_weights_v2", "ltx25_official_video_vae_v1", "ltx25_audio_toggle_v1", "ltx25_official_video_vae_encoder_v1"]
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
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "audio_decode_v2", "ltx25_official_video_vae_v1", "ltx25_audio_toggle_v1", "ltx25_official_video_vae_encoder_v1"]
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
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "audio_decode_v2", "video_decoder_weights_v2", "ltx25_audio_toggle_v1", "ltx25_official_video_vae_encoder_v1"]
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
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "audio_decode_v2", "video_decoder_weights_v2", "ltx25_official_video_vae_v1", "ltx25_official_video_vae_encoder_v1"]
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
        let managedRoot = AppStorageDirectory.runtimesDirectory.standardizedFileURL.path + "/"
        t.check(
            URL(fileURLWithPath: managedExec).standardizedFileURL.path.hasPrefix(managedRoot),
            "Managed executable must reside inside AppStorageDirectory")
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

        // MARK: - G. Official Video VAE *encoder* capability (Preview.5 gate)
        //
        // A runtime without the encoder fix loads the official combined VAE's
        // encoder half with a prefix matching none of its keys, under
        // strict=False, leaving a randomly-initialized encoder — so every
        // image-conditioned generation decodes to noise while text-to-video
        // stays fine. That is exactly the failure a capability gate exists to
        // catch, so it must fail closed rather than silently corrupt output.
        t.check(LTX2MLXRuntimeManifest.requiredCapabilities.contains("ltx25_official_video_vae_encoder_v1"),
                "Runtime requires ltx25_official_video_vae_encoder_v1 capability")

        let missingEncoderFix = LTX2MLXRuntimeManifest(
            schemaVersion: 1,
            runtime: "ltx-2-mlx",
            runtimeVersion: "0.2.0-preview4",
            sourceRevision: "ead83e2",
            capabilities: ["ltx25_gguf", "gguf_block_streaming_v1", "audio_decode_v2",
                           "video_decoder_weights_v2", "ltx25_official_video_vae_v1",
                           "ltx25_audio_toggle_v1"]
        )
        t.check(!missingEncoderFix.isCompatible,
                "A runtime without the official VAE encoder fix must not be compatible")
        t.checkEqual(missingEncoderFix.missingCapabilities, ["ltx25_official_video_vae_encoder_v1"],
                     "Missing ltx25_official_video_vae_encoder_v1 correctly identified")
    }

    t.suite("LTX-2-MLX Canonical Runtime Resolution — Update Runtime persistence") {
        // Reproduces the reported bug: a historical "Path to the ltx-2-mlx
        // executable" (General Settings, the legacy key) shadowed a freshly
        // installed/updated managed runtime forever, because evaluateStatus()
        // gave it permanent priority over the managed runtime. Every check
        // here uses only local stub files under the process-isolated
        // AppStorageDirectory.runtimesDirectory (bundleless test profile) —
        // no real ltx-2-mlx, no network, no Personal mutation.
        func writeExecutableStub(at url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let testSuiteName = "test.ltx2mlx.migration.\(UUID().uuidString)"
        let tempDefaults = UserDefaults(suiteName: testSuiteName)!
        defer { tempDefaults.removePersistentDomain(forName: testSuiteName) }

        let manager = LTX2MLXRuntimeManager(fileManager: .default, userDefaults: tempDefaults)
        // The managed runtime directory is a real (process-isolated) path;
        // make sure this suite starts and ends without an installed runtime
        // there, regardless of other suites or a prior failed run.
        try? FileManager.default.removeItem(at: manager.managedRuntimeDirectory)
        defer { try? FileManager.default.removeItem(at: manager.managedRuntimeDirectory) }

        let legacyStub = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx2mlx-legacy-\(UUID().uuidString)/bin/ltx-2-mlx")
        try writeExecutableStub(at: legacyStub)
        defer { try? FileManager.default.removeItem(at: legacyStub.deletingLastPathComponent().deletingLastPathComponent()) }

        // BEFORE: only the legacy General Settings path is configured, no
        // managed runtime installed yet — the legacy path is genuinely the
        // only thing to resolve to, exactly like a pre-managed-runtime setup.
        tempDefaults.set(legacyStub.path, forKey: LTX2MLXRuntimeManager.legacyExecutableKey)
        let beforeStatus = manager.evaluateStatus()
        t.checkEqual(beforeStatus.executablePath, legacyStub.path,
                     "with no managed runtime installed, the legacy path is still honored")

        // "Update Runtime" (installManagedRuntime, exercised here via its
        // on-disk effect) installs into the managed directory. The legacy
        // key is deliberately left untouched — Do NOT delete the old runtime
        // or its stored preference.
        try writeExecutableStub(at: manager.managedExecutableURL)
        let compatibleManifest = LTX2MLXRuntimeManifest()
        let encoder = JSONEncoder()
        try encoder.encode(compatibleManifest).write(to: manager.manifestURL)

        // AFTER_UPDATE: the managed runtime must now be the resolved runtime,
        // not the still-configured legacy path.
        let afterUpdateStatus = manager.evaluateStatus()
        t.checkEqual(afterUpdateStatus.executablePath, manager.managedExecutableURL.path,
                     "a freshly installed managed runtime outranks the dormant legacy path")
        t.check(afterUpdateStatus.isReady, "managed runtime install reports Ready")
        t.checkEqual(
            tempDefaults.string(forKey: LTX2MLXRuntimeManager.legacyExecutableKey), legacyStub.path,
            "the legacy preference itself is never deleted or cleared")
        t.check(
            FileManager.default.fileExists(atPath: legacyStub.path),
            "the old runtime's files on disk are never deleted")

        // AFTER_TAB_RELOAD: a second, independent evaluateStatus() call (as a
        // SwiftUI view recomputing on redraw would trigger) must agree.
        let afterTabReloadStatus = manager.evaluateStatus()
        t.checkEqual(afterTabReloadStatus.executablePath, manager.managedExecutableURL.path,
                     "tab reload must not resurrect the legacy path")
        t.check(afterTabReloadStatus.isReady, "tab reload keeps the runtime Ready")

        // AFTER_APP_RESTART: a brand new manager instance (same UserDefaults,
        // same on-disk managed runtime) must agree, both for the fast
        // non-probing init() guess and for a fresh evaluateStatus().
        let restarted = LTX2MLXRuntimeManager(fileManager: .default, userDefaults: tempDefaults)
        t.checkEqual(restarted.status.executablePath, manager.managedExecutableURL.path,
                     "app restart's initial status guess resolves the managed runtime, not the legacy path")
        let restartedStatus = restarted.evaluateStatus()
        t.checkEqual(restartedStatus.executablePath, manager.managedExecutableURL.path,
                     "app restart's evaluateStatus agrees with the managed runtime")

        // GENERATION: the exact resolver GenerationService/LTX2MLXBackend use
        // for Normal Generate, One Shot, Storyboard/Director, Auto Movie, and
        // the Custom LTX profile must resolve identically — no silent
        // fallback to the old runtime.
        let generationPath = LTX2MLXRuntime.executablePath(userDefaults: tempDefaults, manager: manager)
        t.checkEqual(generationPath, manager.managedExecutableURL.path,
                     "generation resolves the same managed runtime the Settings UI reports Ready")
        let generationReadiness = LTX2MLXRuntime.runtimeReadiness(userDefaults: tempDefaults, manager: manager)
        t.check(generationReadiness.isReady, "generation readiness agrees with the Settings UI")

        // Explicit Advanced override remains authoritative even with a Ready
        // managed runtime and a still-configured legacy path present.
        let overrideStub = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx2mlx-override-\(UUID().uuidString)/bin/ltx-2-mlx")
        try writeExecutableStub(at: overrideStub)
        defer { try? FileManager.default.removeItem(at: overrideStub.deletingLastPathComponent().deletingLastPathComponent()) }
        manager.setOverrideExecutablePath(overrideStub.path)
        let overrideStatus = manager.evaluateStatus()
        t.checkEqual(overrideStatus.executablePath, overrideStub.path,
                     "an explicit Advanced override outranks both the managed runtime and the legacy path")

        // Clearing the override falls back to the managed runtime — never
        // back to the dormant legacy path, since the managed runtime is
        // still installed and Ready.
        manager.setOverrideExecutablePath(nil)
        let afterClearStatus = manager.evaluateStatus()
        t.checkEqual(afterClearStatus.executablePath, manager.managedExecutableURL.path,
                     "clearing the Advanced override falls back to the managed runtime, not the legacy path")
    }
}
