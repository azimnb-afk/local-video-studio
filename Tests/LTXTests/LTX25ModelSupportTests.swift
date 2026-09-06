import Foundation
@testable import LTXVideoGeneratorCore

func runLTX25ModelSupportTests(_ t: TestKit) {
    t.suite("LTX-2.5 Model Support & Capabilities") {
        // MARK: - A. LTX-2.3 default stability
        t.checkEqual(LTXModelCatalog.defaultModelID, "ltx23_distilled_q4", "default model must be ltx23_distilled_q4")
        let resolvedDefault = GenerationModelResolver.resolve(modelID: nil)
        if case .runnable(let runnable) = resolvedDefault {
            t.checkEqual(runnable.model.id, "ltx23_distilled_q4", "default runnable must be ltx23_distilled_q4")
            t.checkEqual(runnable.backend, .mlxVideoWithAudio, "default backend must be mlxVideoWithAudio")
        } else {
            t.check(false, "nil modelID must resolve to runnable default model")
        }

        // MARK: - B. LTX-2.5 registration & capabilities
        let ltx25Opt = LTX25ModelCatalog.model(id: LTX25ModelCatalog.ltx25ExperimentalID)
        t.check(ltx25Opt != nil, "LTX25ModelCatalog must contain ltx25_experimental")
        if let ltx25 = ltx25Opt {
            t.checkEqual(ltx25.displayName, "LTX-2.5 (Experimental)", "display name must be LTX-2.5 (Experimental)")
            t.checkEqual(ltx25.repo, "Lightricks/LTX-2.5", "repo must be Lightricks/LTX-2.5")
            t.check(!ltx25.supportsBuiltInAudio, "initial audio capability must be false")
        }

        let registry = ModelRegistry.shared
        let descOpt = registry.descriptor(id: LTX25ModelCatalog.ltx25ExperimentalID)
        t.check(descOpt != nil, "ModelRegistry must contain ltx25_experimental descriptor")
        if let desc = descOpt {
            t.checkEqual(desc.architecture.modelVersion, "2.5", "architecture version must be 2.5")
            t.checkEqual(desc.architecture.modelFamily, "LTX", "architecture family must be LTX")
            t.check(desc.capabilities.textToVideo, "must support T2V")
            t.check(desc.capabilities.imageToVideo, "must support I2V")
            t.check(desc.capabilities.keyframes, "must support keyframes")
            t.check(desc.capabilities.continuation, "must support continuation")
            t.checkEqual(desc.runtime.backend, "ltx-2-mlx", "backend must be ltx-2-mlx")
        }

        // MARK: - C. GenerationModelResolver no silent fallback
        let resolved25 = GenerationModelResolver.resolve(modelID: LTX25ModelCatalog.ltx25ExperimentalID)
        if case .runnable(let runnable) = resolved25 {
            t.checkEqual(runnable.model.id, LTX25ModelCatalog.ltx25ExperimentalID, "must resolve exact 2.5 model")
            t.checkEqual(runnable.backend, .ltx2MLX, "must route to ltx2MLX backend")
            t.check(runnable.model.id != LTXModelCatalog.defaultModelID, "must never silently fallback to 2.3")
        } else {
            t.check(false, "ltx25_experimental must resolve to runnable")
        }

        // MARK: - D. LTX2MLXBackend argument generation
        var params = GenerationParameters.default
        params.width = 768
        params.height = 512
        params.numFrames = 73
        params.fps = 24
        params.seed = 42

        let requestT2V = GenerationRequest(
            prompt: "A cinematic shot of a sunset over the ocean",
            modelId: LTX25ModelCatalog.ltx25ExperimentalID,
            parameters: params
        )
        let argsT2V = LTX2MLXBackend.arguments(
            request: requestT2V,
            modelDirectory: "/path/to/ltx25",
            outputPath: "/path/to/out.mp4",
            seed: 42,
            width: 768,
            height: 512
        )
        t.check(argsT2V.contains("--model") && argsT2V.contains("/path/to/ltx25"), "args must contain model path")
        t.check(argsT2V.contains("--width") && argsT2V.contains("768"), "args must contain width")
        t.check(argsT2V.contains("--height") && argsT2V.contains("512"), "args must contain height")
        t.check(argsT2V.contains("--frames") && argsT2V.contains("73"), "args must contain frames")
        t.check(argsT2V.contains("--distilled"), "args must contain --distilled")
        t.check(!argsT2V.contains("--image"), "T2V must not contain --image")

        let requestI2V = GenerationRequest(
            prompt: "A cinematic shot of a sunset over the ocean",
            sourceImagePath: "/path/to/frame.png",
            modelId: LTX25ModelCatalog.ltx25ExperimentalID,
            parameters: params
        )
        let argsI2V = LTX2MLXBackend.arguments(
            request: requestI2V,
            modelDirectory: "/path/to/ltx25",
            outputPath: "/path/to/out.mp4",
            seed: 42,
            width: 768,
            height: 512
        )
        t.check(argsI2V.contains("--image") && argsI2V.contains("/path/to/frame.png"), "I2V must contain --image")

        // MARK: - E. ActiveModelDisplayResolver
        let display = ActiveModelDisplayResolver.resolve(modelID: LTX25ModelCatalog.ltx25ExperimentalID)
        t.checkEqual(display.displayName, "LTX-2.5 (Experimental)", "display name must match")
        t.checkEqual(display.backendBadge, "ltx-2-mlx", "backend badge must be ltx-2-mlx")
        t.checkEqual(display.modelID, LTX25ModelCatalog.ltx25ExperimentalID, "model ID must match")

        // MARK: - F. Auto Movie strict previous-take continuity
        let store = FilmProjectStore.shared
        let projectID = UUID()
        var project = FilmProject(id: projectID, title: "LTX-2.5 Continuity Test")
        project.workflowMode = "hybrid"

        var shot1 = Shot(index: 0, title: "Shot 1")
        shot1.summary = "Elena enters the room."
        shot1.continuityMode = .cut

        var shot2 = Shot(index: 1, title: "Shot 2")
        shot2.summary = "Elena walks to the window."
        shot2.continuityMode = .continueFromPrevious

        project.shots = [shot1, shot2]
        store.save(project)
        defer { store.delete(projectID) }

        let coordinator = AutoMovieRunCoordinator(store: store)
        let mode1 = coordinator.autoMovieContinuityMode(forShotAt: 0, in: project)
        let mode2 = coordinator.autoMovieContinuityMode(forShotAt: 1, in: project)

        t.checkEqual(mode1, .cut, "Shot 1 in Auto Movie must be cut (or opening)")
        t.checkEqual(mode2, .continueFromPrevious, "Shot 2+ in Auto Movie must strictly be continueFromPrevious")

        // MARK: - G. StorageHealthService with LTX-2.5 download estimate
        struct MockDiskProvider: DiskCapacityProviding {
            let capacity: Int64
            func availableCapacity(for url: URL) -> Int64? { capacity }
        }

        // 30 GB available: healthy for a 25 GB download
        let serviceHealthy = StorageHealthService(capacityProvider: MockDiskProvider(capacity: 30 * 1024 * 1024 * 1024))
        let statusHealthy = serviceHealthy.check(url: URL(fileURLWithPath: "/tmp"), for: .modelDownload(expectedBytes: 25 * 1024 * 1024 * 1024))
        t.check(!statusHealthy.isBlocked, "30GB should be healthy for 25GB download")

        // 20 GB available: critical for a 25 GB download
        // MARK: - H. GenerationResult modelDisplayName resolution & backward compatibility
        let result25 = GenerationResult(
            id: UUID(),
            requestId: UUID(),
            prompt: "A cute dog",
            enhancedPrompt: nil,
            negativePrompt: "",
            voiceoverText: "",
            voiceoverSource: "none",
            voiceoverVoice: "default",
            modelId: LTX25ModelCatalog.ltx25ExperimentalID,
            parameters: params,
            videoPath: "/path/to/v.mp4",
            thumbnailPath: nil,
            audioPath: nil,
            musicPath: nil,
            musicGenre: nil,
            createdAt: Date(),
            completedAt: Date(),
            duration: 10.0,
            seed: 42
        )
        t.checkEqual(result25.modelDisplayName, "LTX-2.5 (Experimental)", "LTX-2.5 result must display LTX-2.5 (Experimental)")

        let resultCustom = GenerationResult(
            id: UUID(),
            requestId: UUID(),
            prompt: "A custom shot",
            enhancedPrompt: nil,
            negativePrompt: "",
            voiceoverText: "",
            voiceoverSource: "none",
            voiceoverVoice: "default",
            modelId: "custom_profile_123",
            parameters: params,
            videoPath: "/path/to/v.mp4",
            thumbnailPath: nil,
            audioPath: nil,
            musicPath: nil,
            musicGenre: nil,
            createdAt: Date(),
            completedAt: Date(),
            duration: 10.0,
            seed: 42,
            effectiveProfileName: "My Custom Studio Model"
        )
        t.checkEqual(resultCustom.modelDisplayName, "My Custom Studio Model", "Custom profile result must display profile name")

        let result23 = GenerationResult(
            id: UUID(),
            requestId: UUID(),
            prompt: "An old 2.3 shot",
            enhancedPrompt: nil,
            negativePrompt: "",
            voiceoverText: "",
            voiceoverSource: "none",
            voiceoverVoice: "default",
            modelId: "ltx23_distilled_q4",
            parameters: params,
            videoPath: "/path/to/v.mp4",
            thumbnailPath: nil,
            audioPath: nil,
            musicPath: nil,
            musicGenre: nil,
            createdAt: Date(),
            completedAt: Date(),
            duration: 10.0,
            seed: 42
        )
        t.checkEqual(result23.modelDisplayName, "LTX-2.3 Distilled Q4 (Beta)", "Legacy 2.3 result must display LTX-2.3 Distilled Q4 (Beta)")

        // MARK: - I. LTX-2.5 model-directory persistence and cache recovery
        func makeLTX25Hub(
            complete: Bool = true,
            revisions: [String] = ["revision-a"]
        ) -> URL {
            let hub = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ltx25-hub-\(UUID().uuidString)", isDirectory: true)
            for revision in revisions {
                let snapshot = hub
                    .appendingPathComponent("models--community--ltx-2.5-mlx", isDirectory: true)
                    .appendingPathComponent("snapshots", isDirectory: true)
                    .appendingPathComponent(revision, isDirectory: true)
                try? FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
                let config = #"{"model_version":"2.5.0","model_type":"AudioVideo"}"#
                try? Data(config.utf8).write(to: snapshot.appendingPathComponent("config.json"))
                if complete {
                    for name in [
                        "transformer.safetensors",
                        "connector.safetensors",
                        "vae_decoder.safetensors",
                        "vae_encoder.safetensors"
                    ] {
                        try? Data("weights".utf8).write(to: snapshot.appendingPathComponent(name))
                    }
                }
            }
            return hub
        }

        func makeLTX25LocalModel() -> URL {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ltx25-local-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let config = #"{"model_version":"2.5.0","model_type":"AudioVideo"}"#
            try? Data(config.utf8).write(to: root.appendingPathComponent("config.json"))
            for name in [
                "transformer.safetensors",
                "connector.safetensors",
                "vae_decoder.safetensors",
                "vae_encoder.safetensors"
            ] {
                try? Data("weights".utf8).write(to: root.appendingPathComponent(name))
            }
            return root
        }

        func makeLTX25GGUFModel() -> URL {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ltx25-gguf-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? Data("gguf weights".utf8).write(to: root.appendingPathComponent("LTX-2.5-Distilled-Q4_K_M.gguf"))
            try? Data("vae weights".utf8).write(to: root.appendingPathComponent("ltx-2.5-video-vae-conv-bf16.safetensors"))
            return root
        }

        func makeExecutable() -> String {
            let path = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ltx25-runtime-\(UUID().uuidString)")
            try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            return path.path
        }

        func freshDefaults(_ label: String) -> UserDefaults {
            UserDefaults(suiteName: "ltx25.\(label).\(UUID().uuidString)")!
        }

        let recoveredDefaults = freshDefaults("recovery")
        let recoveredHub = makeLTX25Hub()
        let recovered = LTX25ModelLocationResolver.resolve(
            userDefaults: recoveredDefaults, hubDirectory: recoveredHub)
        t.check(recovered.isReady, "unique complete HF snapshot is recovered")
        t.checkEqual(recovered.source, .hfCacheRecovered, "recovery provenance is recorded")
        t.check(recoveredDefaults.string(forKey: LTX25ModelLocationResolver.modelDirectoryKey) == recovered.effectivePath,
                "recovered path is persisted in the dedicated LTX-2.5 key")
        t.checkEqual(
            recoveredDefaults.string(forKey: LTX25ModelLocationResolver.repositoryKey),
            LTX25ModelCatalog.ltx25Experimental.repo,
            "recovery records the built-in model repository")

        let recoveredAgain = LTX25ModelLocationResolver.resolve(
            userDefaults: recoveredDefaults, hubDirectory: recoveredHub)
        t.checkEqual(recoveredAgain.effectivePath, recovered.effectivePath,
                     "recovery is idempotent on the next readiness check")

        let invalidDefaults = freshDefaults("invalid-cache")
        let invalidHub = makeLTX25Hub(complete: false)
        let invalid = LTX25ModelLocationResolver.resolve(
            userDefaults: invalidDefaults, hubDirectory: invalidHub)
        t.check(!invalid.isReady, "incomplete cache is never marked Ready")
        t.check(invalidDefaults.string(forKey: LTX25ModelLocationResolver.modelDirectoryKey) == nil,
                "incomplete cache is not persisted as a usable model")

        let ambiguousDefaults = freshDefaults("ambiguous")
        let ambiguousHub = makeLTX25Hub(revisions: ["revision-a", "revision-b"])
        let ambiguous = LTX25ModelLocationResolver.resolve(
            userDefaults: ambiguousDefaults, hubDirectory: ambiguousHub)
        t.check(!ambiguous.isReady, "multiple complete snapshots are not auto-selected")
        t.check(ambiguous.reason?.contains("Multiple") == true,
                "ambiguous cache reports an actionable reason")

        let savedDefaults = freshDefaults("saved")
        let savedModel = makeLTX25LocalModel()
        savedDefaults.set(savedModel.path, forKey: LTX25ModelLocationResolver.modelDirectoryKey)
        let saved = LTX25ModelLocationResolver.resolve(
            userDefaults: savedDefaults,
            hubDirectory: makeLTX25Hub(revisions: ["unused"]))
        t.check(saved.isReady, "valid saved path is authoritative")
        t.check(saved.source == .explicitSavedPath, "explicit saved path provenance is retained")

        let unavailableDefaults = freshDefaults("saved-unavailable")
        let unavailablePath = "/tmp/ltx25-removed-\(UUID().uuidString)"
        unavailableDefaults.set(unavailablePath, forKey: LTX25ModelLocationResolver.modelDirectoryKey)
        let unavailable = LTX25ModelLocationResolver.resolve(
            userDefaults: unavailableDefaults,
            hubDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("empty-\(UUID())"))
        t.check(!unavailable.isReady, "unavailable saved path without fallback remains not ready")
        t.checkEqual(unavailableDefaults.string(forKey: LTX25ModelLocationResolver.modelDirectoryKey), unavailablePath,
                     "unavailable saved path is preserved when no valid cache exists")

        let recoverUnavailableDefaults = freshDefaults("saved-recovery")
        recoverUnavailableDefaults.set(unavailablePath, forKey: LTX25ModelLocationResolver.modelDirectoryKey)
        let recoveredUnavailable = LTX25ModelLocationResolver.resolve(
            userDefaults: recoverUnavailableDefaults, hubDirectory: makeLTX25Hub())
        t.check(recoveredUnavailable.isReady,
                "an unavailable saved path recovers when exactly one valid cache exists")
        t.checkEqual(recoveredUnavailable.source, .hfCacheRecovered,
                     "recovered unavailable path records cache provenance")

        let legacyDefaults = freshDefaults("legacy")
        legacyDefaults.set(savedModel.path, forKey: "ltx25ModelPath")
        let migrated = LTX25ModelLocationResolver.resolve(
            userDefaults: legacyDefaults,
            hubDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("empty-\(UUID())"))
        t.check(migrated.isReady, "valid legacy LTX-2.5 path migrates")
        t.checkEqual(migrated.source, .legacyMigratedPath, "legacy migration provenance is recorded")
        t.check(legacyDefaults.string(forKey: LTX25ModelLocationResolver.modelDirectoryKey) == savedModel.path,
                "legacy migration writes the canonical key")

        let customOnlyDefaults = freshDefaults("custom-isolation")
        let customDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("generic-custom-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        for name in CustomLTX2MLXModelCatalog.requiredComponents {
            try? Data("weights".utf8).write(to: customDir.appendingPathComponent(name))
        }
        customOnlyDefaults.set(customDir.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        let customIsolation = LTX25ModelLocationResolver.resolve(
            userDefaults: customOnlyDefaults,
            hubDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("empty-\(UUID())"))
        t.check(!customIsolation.isReady,
                "generic custom LTX-2.3 path is never mistaken for LTX-2.5")

        let legacyCustomDefaults = freshDefaults("legacy-custom-key")
        let legacyGGUF = makeLTX25GGUFModel()
        legacyCustomDefaults.set(legacyGGUF.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        let migratedCustom = LTX25ModelLocationResolver.resolve(
            userDefaults: legacyCustomDefaults,
            hubDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("empty-\(UUID())"))
        t.check(migratedCustom.isReady,
                "a legacy generic path is migrated only when it is a valid LTX-2.5 GGUF package")
        t.checkEqual(migratedCustom.source, .legacyMigratedPath,
                     "validated legacy generic path records migration provenance")

        let runtimeDefaults = freshDefaults("runtime")
        runtimeDefaults.set(makeExecutable(), forKey: LTX2MLXRuntime.executablePathKey)
        let runtimeHub = makeLTX25Hub()
        let runtimeReadiness = LTX2MLXRuntime.readiness(
            modelID: LTX25ModelCatalog.ltx25ExperimentalID,
            repository: LTX25ModelCatalog.ltx25Experimental.repo,
            userDefaults: runtimeDefaults,
            hubDirectory: runtimeHub)
        t.check(runtimeReadiness.canGenerate,
                "runtime plus recovered LTX-2.5 model can generate")
        if let ltx25Descriptor = ModelRegistry(userDefaults: runtimeDefaults)
            .descriptor(id: LTX25ModelCatalog.ltx25ExperimentalID) {
            let readiness = ModelReadinessResolver.evaluate(
                model: ltx25Descriptor,
                userDefaults: runtimeDefaults,
                hubDirectory: runtimeHub)
            t.checkEqual(readiness.status, .ready,
                         "ModelReadinessResolver uses the same recovered LTX-2.5 source")
        } else {
            t.check(false, "LTX-2.5 descriptor exists for readiness evaluation")
        }

        let requestDefaults = freshDefaults("request-freeze")
        let requestHub = makeLTX25Hub()
        let requestPath = LTX25ModelLocationResolver.resolve(
            userDefaults: requestDefaults, hubDirectory: requestHub).effectivePath
        let request = GenerationRequest(
            prompt: "test",
            modelId: LTX25ModelCatalog.ltx25ExperimentalID,
            userDefaults: requestDefaults)
        t.checkEqual(request.customModelLocalPath, requestPath,
                     "GenerationRequest freezes the recovered LTX-2.5 snapshot")
        if let descriptor = ModelRegistry(userDefaults: requestDefaults).descriptor(for: request) {
            t.checkEqual(descriptor.localPath, requestPath,
                         "request descriptor carries the frozen LTX-2.5 snapshot")
        } else {
            t.check(false, "LTX-2.5 request descriptor remains registered")
        }
    }
}
