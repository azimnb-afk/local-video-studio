import Foundation
@testable import LTXVideoGeneratorCore

/// Covers the second generation backend: readiness, routing, failure and
/// provenance. Nothing here re-implements the resolver or the continuity
/// chain — each test drives the production type.
func runLTX2MLXBackendTests(_ t: TestKit) {
    let customModel = CustomLTX2MLXModelCatalog.customModel()

    // Builds a fake HF cache whose snapshot holds the component files the
    // runtime resolves, so readiness is exercised against real filesystem
    // layout rather than a stubbed answer.
    func makeHub(complete: Bool) -> URL {
        let hub = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hub-\(UUID().uuidString)")
        let snapshot = hub
            .appendingPathComponent("models--\(customModel.repo.replacingOccurrences(of: "/", with: "--"))")
            .appendingPathComponent("snapshots").appendingPathComponent("abc123")
        try? FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let components = complete
            ? CustomLTX2MLXModelCatalog.requiredComponents
            : Array(CustomLTX2MLXModelCatalog.requiredComponents.dropLast())
        for name in components {
            try? Data("weights".utf8).write(to: snapshot.appendingPathComponent(name))
        }
        return hub
    }

    func makeExecutable() -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ltx-2-mlx-\(UUID().uuidString)")
        try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    t.suite("Custom LTX-2 MLX readiness / runtime and model tracked separately") {
        let completeHub = makeHub(complete: true)
        let partialHub = makeHub(complete: false)
        let executable = makeExecutable()

        // 7. Runtime missing → not ready, even with the model fully downloaded.
        let noRuntime = UserDefaults(suiteName: "ltx2mlx-none-\(UUID().uuidString)")!
        var readiness = LTX2MLXRuntime.readiness(
            repository: customModel.repo, userDefaults: noRuntime, hubDirectory: completeHub)
        t.check(!readiness.canGenerate, "runtime missing → cannot generate")
        t.check(!readiness.runtime.isReady, "runtime reported missing")
        t.check(readiness.model.isReady, "model still reported ready independently")
        t.check(readiness.runtime.detail.contains("not configured"), "runtime reason is actionable")

        // 8. Runtime ready + model missing → not ready, with the model blamed.
        let withRuntime = UserDefaults(suiteName: "ltx2mlx-rt-\(UUID().uuidString)")!
        withRuntime.set(executable, forKey: LTX2MLXRuntime.executablePathKey)
        readiness = LTX2MLXRuntime.readiness(
            repository: customModel.repo, userDefaults: withRuntime, hubDirectory: partialHub)
        t.check(!readiness.canGenerate, "incomplete model → cannot generate")
        t.check(readiness.runtime.isReady, "runtime reported ready")
        t.check(!readiness.model.isReady, "partially downloaded model is not ready")

        // 9. Both ready → ready, and the model path is the snapshot directory.
        readiness = LTX2MLXRuntime.readiness(
            repository: customModel.repo, userDefaults: withRuntime, hubDirectory: completeHub)
        t.check(readiness.canGenerate, "runtime + model ready → can generate")
        t.check(readiness.model.detail.hasSuffix("abc123"), "model resolves to the snapshot directory")

        // A configured-but-absent runtime path is missing, not ready.
        let badRuntime = UserDefaults(suiteName: "ltx2mlx-bad-\(UUID().uuidString)")!
        badRuntime.set("/nonexistent/ltx-2-mlx", forKey: LTX2MLXRuntime.executablePathKey)
        t.check(!LTX2MLXRuntime.runtimeReadiness(userDefaults: badRuntime).isReady,
                "nonexistent runtime path is not ready")
    }

    t.suite("Custom LTX-2 MLX local model path resolution & source mode persistence") {
        let executable = makeExecutable()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())

        // Helper to build a standalone local model directory with required safetensors
        func makeLocalModelDir(complete: Bool) -> URL {
            let modelDir = tempDir.appendingPathComponent("local-model-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            let components = complete
                ? CustomLTX2MLXModelCatalog.requiredComponents
                : Array(CustomLTX2MLXModelCatalog.requiredComponents.dropLast())
            for name in components {
                try? Data("local-weights".utf8).write(to: modelDir.appendingPathComponent(name))
            }
            return modelDir
        }

        let validLocalDir = makeLocalModelDir(complete: true)
        let incompleteLocalDir = makeLocalModelDir(complete: false)
        let defaults = UserDefaults(suiteName: "ltx2mlx-local-\(UUID().uuidString)")!
        defaults.set(executable, forKey: LTX2MLXRuntime.executablePathKey)

        // 1. Default source mode is huggingFace
        t.checkEqual(LTX2MLXRuntime.customModelSourceMode(userDefaults: defaults), .huggingFace,
                     "default custom model source mode is huggingFace")

        // 2. Local mode with valid directory resolves directly to local path without download
        defaults.set(CustomModelSourceMode.local.rawValue, forKey: ModelRegistry.customSourceModeUserDefaultsKey)
        defaults.set(validLocalDir.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        t.checkEqual(LTX2MLXRuntime.customModelSourceMode(userDefaults: defaults), .local,
                     "source mode persists as local")
        t.checkEqual(LTX2MLXRuntime.localModelPath(userDefaults: defaults), validLocalDir.path,
                     "local model path persists")

        var readiness = LTX2MLXRuntime.readiness(userDefaults: defaults)
        t.check(readiness.canGenerate, "local mode with valid model directory can generate")
        t.check(readiness.model.isReady, "local model reported ready")
        t.checkEqual(readiness.model.detail, validLocalDir.path, "local model resolves to direct local path")

        // 3. Local mode with incomplete directory reports actionable missing error
        defaults.set(incompleteLocalDir.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        readiness = LTX2MLXRuntime.readiness(userDefaults: defaults)
        t.check(!readiness.canGenerate, "incomplete local directory cannot generate")
        t.check(!readiness.model.isReady, "incomplete local model reported not ready")
        t.check(readiness.model.detail.contains("missing required .safetensors components"),
                "incomplete local model detail is actionable")

        // 4. Local mode with nonexistent path reports not found
        defaults.set("/path/does/not/exist/model", forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        readiness = LTX2MLXRuntime.readiness(userDefaults: defaults)
        t.check(!readiness.canGenerate, "nonexistent local directory cannot generate")
        t.check(!readiness.model.isReady, "nonexistent local path reported not ready")
        t.check(readiness.model.detail.contains("does not exist"), "nonexistent local model detail explains missing path")

        // 5. Local mode with empty path reports no directory selected
        defaults.removeObject(forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        readiness = LTX2MLXRuntime.readiness(userDefaults: defaults)
        t.check(!readiness.canGenerate, "empty local path cannot generate")
        t.check(readiness.model.detail.contains("No local model directory selected"),
                "empty local path detail instructs user to choose in Preferences")

        // 6. Switching source modes preserves inactive stored values
        defaults.set("my-org/my-custom-model", forKey: ModelRegistry.customRepositoryUserDefaultsKey)
        defaults.set(validLocalDir.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)

        defaults.set(CustomModelSourceMode.huggingFace.rawValue, forKey: ModelRegistry.customSourceModeUserDefaultsKey)
        t.checkEqual(defaults.string(forKey: ModelRegistry.customLocalPathUserDefaultsKey), validLocalDir.path,
                     "switching to HF mode preserves stored local path")

        defaults.set(CustomModelSourceMode.local.rawValue, forKey: ModelRegistry.customSourceModeUserDefaultsKey)
        t.checkEqual(defaults.string(forKey: ModelRegistry.customRepositoryUserDefaultsKey), "my-org/my-custom-model",
                     "switching to local mode preserves stored HF repository ID")

        // 7. Local mode does NOT trigger model download
        let coordinator = CustomModelDownloadCoordinator.shared
        Task { @MainActor in
            await coordinator.startDownload(repository: "dummy/repo", userDefaults: defaults)
            t.checkEqual(coordinator.state, .idle, "local mode download coordinator remains idle without network action")
        }

        // 8. Runtime path remains completely independent from model path
        t.checkEqual(LTX2MLXRuntime.executablePath(userDefaults: defaults), executable,
                     "runtime executable path is independent from local model path")

        // 9. Compatible alternate layout with transformer.safetensors (e.g. notapalindrome) is accepted
        let altDir = tempDir.appendingPathComponent("local-alt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: altDir, withIntermediateDirectories: true)
        for name in ["transformer.safetensors", "connector.safetensors", "vae_decoder.safetensors", "vae_encoder.safetensors"] {
            try? Data("weights".utf8).write(to: altDir.appendingPathComponent(name))
        }
        defaults.set(altDir.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        readiness = LTX2MLXRuntime.readiness(userDefaults: defaults)
        t.check(readiness.canGenerate, "alternate layout with transformer.safetensors is accepted without false rejection")
        t.check(readiness.model.isReady, "alternate transformer model reported ready")

        // 10. Compatible layout with versioned transformer-distilled-1.1.safetensors is accepted
        let versionedDir = tempDir.appendingPathComponent("local-versioned-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: versionedDir, withIntermediateDirectories: true)
        for name in ["transformer-distilled-1.1.safetensors", "connector.safetensors", "vae_decoder.safetensors", "vae_encoder.safetensors"] {
            try? Data("weights".utf8).write(to: versionedDir.appendingPathComponent(name))
        }
        defaults.set(versionedDir.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        readiness = LTX2MLXRuntime.readiness(userDefaults: defaults)
        t.check(readiness.canGenerate, "versioned transformer-distilled-1.1 model is accepted")
        t.check(readiness.model.isReady, "versioned model reported ready")

        // 11. Missing connector is rejected
        let missingConnectorDir = tempDir.appendingPathComponent("local-no-conn-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: missingConnectorDir, withIntermediateDirectories: true)
        for name in ["transformer.safetensors", "vae_decoder.safetensors"] {
            try? Data("weights".utf8).write(to: missingConnectorDir.appendingPathComponent(name))
        }
        defaults.set(missingConnectorDir.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        readiness = LTX2MLXRuntime.readiness(userDefaults: defaults)
        t.check(!readiness.canGenerate, "missing connector is rejected")
        t.check(!readiness.model.isReady, "missing connector reported not ready")

        // 12. Missing VAE decoder is rejected
        let missingVaeDir = tempDir.appendingPathComponent("local-no-vae-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: missingVaeDir, withIntermediateDirectories: true)
        for name in ["transformer.safetensors", "connector.safetensors"] {
            try? Data("weights".utf8).write(to: missingVaeDir.appendingPathComponent(name))
        }
        defaults.set(missingVaeDir.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        readiness = LTX2MLXRuntime.readiness(userDefaults: defaults)
        t.check(!readiness.canGenerate, "missing VAE decoder is rejected")
        t.check(!readiness.model.isReady, "missing VAE decoder reported not ready")
    }

    t.suite("Custom model gating") {
        let defaults = UserDefaults(suiteName: "ltx2mlx-gate-\(UUID().uuidString)")!
        let registry = ModelRegistry(userDefaults: defaults)

        FeatureFlags.set(.customModelsV1, enabled: false, userDefaults: defaults)
        t.check(!registry.selectableModels(customModelsEnabled: false).contains { $0.id == customModel.id },
                "customModels flag off hides custom model")

        FeatureFlags.set(.customModelsV1, enabled: true, userDefaults: defaults)
        t.check(registry.selectableModels(customModelsEnabled: true).contains { $0.id == customModel.id },
                "customModels flag on offers custom model")

        FeatureFlags.disableAll(userDefaults: defaults)
    }

    t.suite("Custom LTX-2 MLX request routing across workflows") {
        let registry = ModelRegistry.shared
        // 12-16. Every workflow that builds a request routes by model ID
        // alone, so One Shot, Storyboard, Auto Movie and Regenerate all reach
        // the same backend without workflow-specific branching.
        for source in ["generate", "oneShot", "storyboard", "hybrid", "apiV1"] {
            let customRequest = GenerationRequest(
                prompt: "a calm landscape", modelId: customModel.id, generationSource: source)
            t.checkEqual(GenerationModelResolver.backend(for: customRequest.modelId, registry: registry),
                         .ltx2MLX, "\(source) with custom model routes to ltx-2-mlx")

            let ltxRequest = GenerationRequest(
                prompt: "a calm landscape", modelId: LTXModelCatalog.defaultModelID,
                generationSource: source)
            t.checkEqual(GenerationModelResolver.backend(for: ltxRequest.modelId, registry: registry),
                         .mlxVideoWithAudio, "\(source) with LTX-2.3 stays on the original backend")
        }

        // 16. Regenerate reuses the stored take's model, so the backend follows
        // the model rather than the current UI selection.
        let original = GenerationRequest(prompt: "shot", modelId: customModel.id, generationSource: "storyboard")
        let regenerated = GenerationRequest(
            prompt: original.prompt, modelId: original.modelId, generationSource: "storyboard")
        t.checkEqual(GenerationModelResolver.backend(for: regenerated.modelId, registry: registry), .ltx2MLX,
                     "regenerate preserves the custom model backend")
    }

    t.suite("Custom LTX-2 MLX failure handling / no cross-backend fallback") {
        let executable = makeExecutable()
        let completeHub = makeHub(complete: true)

        t.checkEqual(GenerationModelResolver.backend(for: customModel.id), .ltx2MLX,
                     "custom model has exactly one backend")

        let noRuntime = UserDefaults(suiteName: "ltx2mlx-fail-\(UUID().uuidString)")!
        let missingRuntime = LTX2MLXRuntime.readiness(
            repository: customModel.repo, userDefaults: noRuntime, hubDirectory: completeHub)
        t.check(missingRuntime.runtime.detail.lowercased().contains("ltx-2-mlx"),
                "missing runtime error names the runtime")

        let withRuntime = UserDefaults(suiteName: "ltx2mlx-fail2-\(UUID().uuidString)")!
        withRuntime.set(executable, forKey: LTX2MLXRuntime.executablePathKey)
        let emptyHub = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString)")
        let missingModel = LTX2MLXRuntime.readiness(
            repository: customModel.repo, userDefaults: withRuntime, hubDirectory: emptyHub)
        t.check(missingModel.model.detail.contains(customModel.repo),
                "missing model error names the exact repo")

        // 20. Settings this pipeline cannot honor are stated, not substituted.
        var params = GenerationParameters.default
        params.numInferenceSteps = 25
        params.guidanceScale = 3.5
        let request = GenerationRequest(
            prompt: "p", negativePrompt: "blurry", modelId: customModel.id, parameters: params)
        let mismatch = LTX2MLXBackend.settingsMismatch(request: request)
        t.check(mismatch.notes.contains { $0.contains("25") }, "requested step count is reported verbatim")
        t.check(mismatch.notes.contains { $0.lowercased().contains("guidance") },
                "CFG mismatch is reported")
        t.check(mismatch.notes.contains { $0.lowercased().contains("negative prompt") },
                "unused negative prompt is reported")
    }

    t.suite("Custom LTX-2 MLX argument construction") {
        var params = GenerationParameters.default
        params.width = 512
        params.height = 288
        params.numFrames = 73
        params.fps = 24
        let request = GenerationRequest(
            prompt: "a calm landscape", sourceImagePath: "/tmp/source.png", modelId: CustomLTX2MLXModelCatalog.customModelID,
            parameters: params)
        let args = LTX2MLXBackend.arguments(
            request: request, modelDirectory: "/models/custom", outputPath: "/out/v.mp4",
            seed: 42, width: 512, height: 288)

        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        t.checkEqual(args.first, "generate", "invokes the generate subcommand")
        t.checkEqual(value(after: "--model"), "/models/custom", "model directory passed through")
        t.checkEqual(value(after: "--seed"), "42", "seed passed through")
        t.checkEqual(value(after: "--frames"), "73", "frame count passed through")
        t.checkEqual(value(after: "--frame-rate"), "24", "frame rate passed through")
        t.checkEqual(value(after: "--output"), "/out/v.mp4", "output path passed through")
        t.check(args.contains("--distilled"), "uses the distilled pipeline the model is baked for")

        // 25/26. Continuity is unchanged: the backend consumes whatever
        // prepared image the existing chain produced, and a CUT shot has none.
        t.checkEqual(value(after: "--image"), "/tmp/source.png",
                     "CONTINUE source image reaches the runtime unmodified")
        let cutRequest = GenerationRequest(prompt: "p", sourceImagePath: nil, modelId: customModel.id)
        let cutArgs = LTX2MLXBackend.arguments(
            request: cutRequest, modelDirectory: "/m", outputPath: "/o.mp4",
            seed: 1, width: 512, height: 288)
        t.check(!cutArgs.contains("--image"), "CUT shot passes no inherited image")
    }

    t.suite("Custom model provenance persistence") {
        // 21/24. A project written before this backend existed still decodes,
        // and keeps the original LTX-2.3 behaviour. Built by stripping the
        // later-added optional keys from a real encoded request, so the test
        // tracks the actual schema instead of a hand-copied snapshot of it.
        let baseline = GenerationRequest(prompt: "p", modelId: "ltx23_distilled_q4")
        if let encoded = try? JSONEncoder().encode(baseline),
           var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] {
            for laterKey in ["modelRevision", "quantization", "qualityMode", "preset",
                             "targetDurationSeconds", "generationSource", "filmProjectID",
                             "shotID", "takeID"] {
                object.removeValue(forKey: laterKey)
            }
            if let legacyData = try? JSONSerialization.data(withJSONObject: object),
               let decoded = try? JSONDecoder().decode(GenerationRequest.self, from: legacyData) {
                t.checkEqual(decoded.modelId, "ltx23_distilled_q4", "legacy request decodes")
                t.checkEqual(decoded.generationSource, nil, "legacy request has no backend-era metadata")
                t.checkEqual(GenerationModelResolver.backend(for: decoded.modelId), .mlxVideoWithAudio,
                             "legacy request keeps the original backend")
            } else {
                t.check(false, "legacy request must still decode")
            }
        } else {
            t.check(false, "baseline request must encode")
        }

        // 22/23. A custom model request round-trips, and its backend is derived from
        // the persisted model ID rather than stored twice and risking drift.
        let request = GenerationRequest(prompt: "p", modelId: customModel.id, quantization: "q4")
        guard let encoded = try? JSONEncoder().encode(request),
              let decoded = try? JSONDecoder().decode(GenerationRequest.self, from: encoded) else {
            t.check(false, "custom model request must round-trip"); return
        }
        t.checkEqual(decoded.modelId, customModel.id, "custom model ID round-trips")
        t.checkEqual(decoded.quantization, "q4", "quantization round-trips")
        t.checkEqual(GenerationModelResolver.backend(for: decoded.modelId), .ltx2MLX,
                     "backend provenance survives the round-trip")

        // 23. Diagnostics carry the runtime that produced a take, and takes
        // written before a second backend existed still decode without it.
        var diagnostics = GenerationRuntimeDiagnostics(
            status: .succeeded, startedAt: Date(), requestedWidth: 512, requestedHeight: 288,
            backendResult: .succeeded, backendKind: GenerationBackendKind.ltx2MLX.rawValue,
            outputExists: true)
        if let encodedDiagnostics = try? JSONEncoder().encode(diagnostics),
           let decodedDiagnostics = try? JSONDecoder().decode(
               GenerationRuntimeDiagnostics.self, from: encodedDiagnostics) {
            t.checkEqual(decodedDiagnostics.backendKind, GenerationBackendKind.ltx2MLX.rawValue,
                         "backend kind round-trips in take diagnostics")
        } else {
            t.check(false, "diagnostics must round-trip")
        }
        diagnostics.backendKind = nil
        if let encodedLegacy = try? JSONEncoder().encode(diagnostics),
           var object = (try? JSONSerialization.jsonObject(with: encodedLegacy)) as? [String: Any] {
            object.removeValue(forKey: "backendKind")
            if let legacyData = try? JSONSerialization.data(withJSONObject: object),
               let decodedLegacy = try? JSONDecoder().decode(
                   GenerationRuntimeDiagnostics.self, from: legacyData) {
                t.checkEqual(decodedLegacy.backendKind, nil,
                             "take without a backend field decodes as the original backend")
            } else {
                t.check(false, "legacy diagnostics must still decode")
            }
        }
    }

    t.suite("Custom MLX process environment / FFmpeg propagation") {
        // Test 1: Prepends resolved FFmpeg directory to PATH
        let baseEnv = ["PATH": "/usr/bin:/bin", "USER": "testuser"]
        let envWithFFmpeg = LTX2MLXBackend.runtimeEnvironment(
            base: baseEnv,
            ffmpegPath: "/opt/homebrew/bin/ffmpeg"
        )
        let path = envWithFFmpeg["PATH"] ?? ""
        let parts = path.components(separatedBy: ":")

        t.checkEqual(envWithFFmpeg["USER"], "testuser", "base environment preserved")
        t.check(parts.contains("/opt/homebrew/bin"), "PATH contains /opt/homebrew/bin")
        t.check(parts.contains("/usr/bin"), "PATH contains /usr/bin")
        t.check(parts.contains("/bin"), "PATH contains /bin")
        t.check(parts.first == "/opt/homebrew/bin", "/opt/homebrew/bin prepended to front")

        // Test 2: No duplicates when already in PATH
        let duplicateBase = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        let deduplicatedEnv = LTX2MLXBackend.runtimeEnvironment(
            base: duplicateBase,
            ffmpegPath: "/opt/homebrew/bin/ffmpeg"
        )
        let dedupPath = deduplicatedEnv["PATH"] ?? ""
        let dedupParts = dedupPath.components(separatedBy: ":")
        let homebrewCount = dedupParts.filter { $0 == "/opt/homebrew/bin" }.count
        t.checkEqual(homebrewCount, 1, "No duplicate /opt/homebrew/bin in PATH")

        // Test 3: Standard candidates are all represented
        t.check(dedupParts.contains("/usr/local/bin"), "PATH contains /usr/local/bin")
        t.check(dedupParts.contains("/usr/bin"), "PATH contains /usr/bin")
    }

    t.suite("Custom Local Model Snapshot Propagation & Queue Immutability") {
        let defaults = UserDefaults(suiteName: "ltx2mlx-prop-\(UUID().uuidString)")!
        FeatureFlags.set(.customModelsV1, enabled: true, userDefaults: defaults)
        let registry = ModelRegistry(userDefaults: defaults)
        let tempDir = FileManager.default.temporaryDirectory

        // Setup mock local model A
        let localDirA = tempDir.appendingPathComponent("model-a-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: localDirA, withIntermediateDirectories: true)
        for name in ["transformer.safetensors", "connector.safetensors", "vae_decoder.safetensors", "vae_encoder.safetensors"] {
            try? Data("weights-a".utf8).write(to: localDirA.appendingPathComponent(name))
        }

        // Setup mock local model B
        let localDirB = tempDir.appendingPathComponent("model-b-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: localDirB, withIntermediateDirectories: true)
        for name in ["transformer.safetensors", "connector.safetensors", "vae_decoder.safetensors", "vae_encoder.safetensors"] {
            try? Data("weights-b".utf8).write(to: localDirB.appendingPathComponent(name))
        }

        // Configure defaults to local mode pointing to model A
        defaults.set(CustomModelSourceMode.local.rawValue, forKey: ModelRegistry.customSourceModeUserDefaultsKey)
        defaults.set(localDirA.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)

        // 1. One Shot / Direct Generate freezes local snapshot path at request creation time
        let requestOneShot = GenerationRequest(
            prompt: "a majestic mountain",
            modelId: ModelRegistry.customModelID,
            generationSource: "oneShot",
            userDefaults: defaults
        )
        t.checkEqual(requestOneShot.customModelSourceMode, "local", "One Shot request source mode is frozen as local")
        t.checkEqual(requestOneShot.customModelLocalPath, localDirA.path, "One Shot request freezes local snapshot path A")

        // 2. Validate descriptor for frozen request passes without "no pinned revision or local snapshot" error
        let descriptor = try? registry.validateForGeneration(request: requestOneShot)
        t.check(descriptor != nil, "validateForGeneration succeeds for request with frozen local path")
        t.checkEqual(descriptor?.localPath, localDirA.path, "descriptor has frozen local path")

        let issues = ManifestValidator.validateDescriptor(descriptor!)
        t.check(!ManifestValidator.hasBlockingIssues(issues), "ManifestValidator passes descriptor with local path")

        // 3. Adapter check succeeds (does NOT throw "has no pinned revision or local snapshot")
        let adapter = LTX2MLXAdapter()
        t.check(adapter.supports(model: descriptor!), "LTX2MLXAdapter supports custom model descriptor")

        // 4. Queue Immutability: Change preferences to model B, original request must still use model A
        defaults.set(localDirB.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        let descAfterPrefChange = registry.descriptor(for: requestOneShot)
        t.checkEqual(descAfterPrefChange?.localPath, localDirA.path, "Queued request descriptor retains original model A after preferences change to B")

        // Backend readiness for frozen request uses model A
        let readinessA = LTX2MLXRuntime.readiness(
            repository: customModel.repo,
            localPath: requestOneShot.customModelLocalPath,
            sourceMode: .local,
            userDefaults: defaults
        )
        t.check(readinessA.model.isReady, "Backend readiness succeeds with frozen path A")
        if case .ready(let dir) = readinessA.model {
            t.checkEqual(dir, localDirA.path, "Backend resolves exact frozen path A, not current preferences path B")
        }

        // 5. Source Mode Immutability: Switch preferences to HF mode, queued local request remains local
        defaults.set(CustomModelSourceMode.huggingFace.rawValue, forKey: ModelRegistry.customSourceModeUserDefaultsKey)
        t.checkEqual(requestOneShot.customModelSourceMode, "local", "Request maintains local mode after preferences switched to HF")
        let readinessStayedLocal = LTX2MLXRuntime.readiness(
            repository: customModel.repo,
            localPath: requestOneShot.customModelLocalPath,
            sourceMode: requestOneShot.customModelSourceMode.flatMap { CustomModelSourceMode(rawValue: $0) },
            userDefaults: defaults
        )
        t.check(readinessStayedLocal.model.isReady, "Readiness of frozen local request succeeds in local mode even when preferences is HF")

        // 6. Other workflows propagate local path
        for source in ["generate", "storyboard", "hybrid", "autoMovie", "regenerate"] {
            let req = GenerationRequest(
                prompt: "scene",
                modelId: ModelRegistry.customModelID,
                generationSource: source,
                customModelLocalPath: localDirA.path,
                customModelSourceMode: "local",
                userDefaults: defaults
            )
            t.checkEqual(req.customModelLocalPath, localDirA.path, "\(source) propagates frozen local path")
            let desc = registry.descriptor(for: req)
            t.checkEqual(desc?.localPath, localDirA.path, "\(source) descriptor reflects frozen local path")
        }

        // 7. Missing local path is rejected
        let missingDefaults = UserDefaults(suiteName: "ltx2mlx-missing-\(UUID().uuidString)")!
        missingDefaults.set(CustomModelSourceMode.local.rawValue, forKey: ModelRegistry.customSourceModeUserDefaultsKey)
        let missingPathReq = GenerationRequest(
            prompt: "scene",
            modelId: ModelRegistry.customModelID,
            generationSource: "generate",
            userDefaults: missingDefaults
        )
        t.checkEqual(missingPathReq.customModelLocalPath, nil, "Unconfigured local path resolves to nil")
        let missingReadiness = LTX2MLXRuntime.readiness(
            repository: customModel.repo,
            localPath: missingPathReq.customModelLocalPath,
            sourceMode: .local,
            userDefaults: missingDefaults
        )
        t.check(!missingReadiness.model.isReady, "Missing local path is rejected by readiness")
        FeatureFlags.disableAll(userDefaults: defaults)
    }
}
