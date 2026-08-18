import Foundation
@testable import LTXVideoGeneratorCore

func runRegistryTests(_ t: TestKit) {
    // Isolated defaults so tests never touch the real app settings.
    let suiteName = "LTXTests.registry.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    t.suite("ModelRegistry seeding") {
        let registry = ModelRegistry(userDefaults: defaults)
        for legacy in LTXModelCatalog.all {
            t.check(registry.descriptor(id: legacy.id) != nil, "official \(legacy.id) registered")
            t.check(registry.descriptor(id: legacy.id)?.isOfficial == true, "official \(legacy.id) marked official")
            t.check(registry.descriptor(id: legacy.id)?.runtime.verified == true, "official \(legacy.id) verified")
        }
        let custom = registry.descriptor(id: ModelRegistry.customModelID)
        t.check(custom != nil, "custom LTX-2 MLX model registered")
        t.checkEqual(custom?.runtime.backend, "ltx-2-mlx", "custom model routes to ltx-2-mlx")
        t.checkEqual(custom?.isOfficial, false, "custom model is not official")
    }

    t.suite("Model Policy and Generation Validation") {
        let registry = ModelRegistry(userDefaults: defaults)
        // official model passes validation
        do {
            try registry.validatePolicy(modelID: LTXModelCatalog.defaultModelID)
            t.check(true, "official model policy allowed")
        } catch {
            t.check(false, "official model policy allowed (threw \(error))")
        }
        // unregistered model = reject
        t.checkThrows(ModelPolicyError.modelNotRegistered(modelID: "nonexistent"),
                      "unregistered model rejected") {
            try registry.validatePolicy(modelID: "nonexistent")
        }
        // official model passes generation gate
        do {
            let d = try registry.validateForGeneration(modelID: LTXModelCatalog.defaultModelID)
            t.checkEqual(d.id, LTXModelCatalog.defaultModelID, "official model passes generation gate")
        } catch {
            t.check(false, "official model passes generation gate (threw \(error))")
        }
    }

    t.suite("Generation model resolution / backend routing") {
        let registry = ModelRegistry(userDefaults: defaults)

        // 1. Official models resolve to themselves on the original backend.
        for official in LTXModelCatalog.all {
            switch GenerationModelResolver.resolve(modelID: official.id, registry: registry) {
            case .runnable(let runnable):
                t.checkEqual(runnable.model.id, official.id, "official \(official.id) resolves to itself")
                t.checkEqual(runnable.backend, .mlxVideoWithAudio,
                             "official \(official.id) stays on mlx-video-with-audio")
            case .unsupported:
                t.check(false, "official \(official.id) must be runnable")
            }
        }

        // 2. Custom LTX-2 MLX model resolves to itself on the ltx-2-mlx backend.
        switch GenerationModelResolver.resolve(modelID: ModelRegistry.customModelID, registry: registry) {
        case .runnable(let runnable):
            t.checkEqual(runnable.model.id, ModelRegistry.customModelID, "custom model resolves to itself")
            t.checkEqual(runnable.backend, .ltx2MLX, "custom model routes to ltx-2-mlx")
        case .unsupported:
            t.check(false, "custom model must be runnable")
        }

        // 4. Unknown model fails loudly.
        switch GenerationModelResolver.resolve(modelID: "no_such_model", registry: registry) {
        case .runnable(let runnable):
            t.check(false, "unknown ID must not resolve to \(runnable.model.id)")
        case .unsupported(let reason):
            t.checkEqual(reason, .unknownModel(modelID: "no_such_model"), "unknown ID reported as unknown")
        }
        t.checkEqual(GenerationModelResolver.backend(for: "no_such_model", registry: registry), nil,
                     "unknown ID has no backend — never the default one")

        // 5. nil / legacy selection keeps the existing LTX-2.3 default.
        for legacy in [nil, ""] as [String?] {
            switch GenerationModelResolver.resolve(modelID: legacy, registry: registry) {
            case .runnable(let runnable):
                t.checkEqual(runnable.model.id, LTXModelCatalog.defaultModel.id, "legacy selection → default")
                t.checkEqual(runnable.backend, .mlxVideoWithAudio, "legacy selection → original backend")
            case .unsupported:
                t.check(false, "legacy selection must stay runnable")
            }
        }
    }

    t.suite("Selectable models / flags") {
        let registry = ModelRegistry(userDefaults: defaults)
        FeatureFlags.disableAll(userDefaults: defaults)
        let defaultAvailable = registry.selectableModels(customModelsEnabled: false)
        t.checkEqual(defaultAvailable.count, LTXModelCatalog.all.count + 1, "flags OFF → official models + LTX-2.5 experimental")
        
        FeatureFlags.set(.customModelsV1, enabled: true, userDefaults: defaults)
        t.checkEqual(registry.selectableModels(customModelsEnabled: true).count, LTXModelCatalog.all.count + 2,
                     "customModels ON → custom model visible")
        FeatureFlags.disableAll(userDefaults: defaults)
    }

    t.suite("Adapter registry") {
        let registry = ModelRegistry(userDefaults: defaults)
        let adapters = AdapterRegistry()
        let official = registry.descriptor(id: LTXModelCatalog.defaultModelID)!
        t.check(adapters.adapter(for: official) is OfficialMLXAudioAdapter, "official model → OfficialMLXAudioAdapter")

        let customModel = registry.descriptor(id: ModelRegistry.customModelID)!
        t.check(adapters.adapter(for: customModel) is LTX2MLXAdapter, "custom model → LTX2MLXAdapter")

        // Invariant: every model the registry will actually offer for selection must resolve to an adapter.
        for offered in registry.selectableModels(customModelsEnabled: true) {
            t.check(adapters.adapter(for: offered) != nil, "offered model \(offered.id) resolves to an adapter")
        }
    }

    t.suite("LTX2MLXAdapter gating") {
        let adapter = LTX2MLXAdapter()
        let registry = ModelRegistry(userDefaults: defaults)
        var descriptor = registry.descriptor(id: ModelRegistry.customModelID)!
        t.check(adapter.supports(model: descriptor), "LTX2MLXAdapter supports generic custom model")
        descriptor.isOfficial = true
        t.check(!adapter.supports(model: descriptor), "LTX2MLXAdapter refuses official models even on this backend")
    }

    t.suite("AppStorageDirectory and Keychain isolation") {
        t.checkEqual(AppStorageDirectory.legacyFolderName, "LTXVideoGenerator", "legacy folder name preserved")
        t.checkEqual(AppStorageDirectory.personalFolderName, "LocalVideoStudio", "personal folder name defined")
        t.checkEqual(AppStorageDirectory.devFolderName, "LocalVideoStudioDev", "dev folder name defined")
        t.check(!AppStorageDirectory.root.path.isEmpty, "AppStorageDirectory root is valid")
        t.check(!AppStorageDirectory.keychainService.isEmpty, "keychain service name is valid")
    }

    t.suite("Codable migration") {
        // Legacy GenerationRequest JSON (pre-extension) must decode.
        let legacyRequest = """
        {"id":"11111111-1111-1111-1111-111111111111","prompt":"p","negativePrompt":"","voiceoverText":"","voiceoverSource":"mlx-audio","voiceoverVoice":"af_heart","musicEnabled":false,"disableAudio":false,"gemmaRepetitionPenalty":1.2,"gemmaTopP":0.9,"parameters":{"numInferenceSteps":30,"guidanceScale":3.0,"width":768,"height":512,"numFrames":121,"fps":24,"vaeTilingMode":"auto","imageStrength":1.0},"createdAt":700000000,"status":"pending"}
        """
        do {
            let decoded = try JSONDecoder().decode(GenerationRequest.self, from: Data(legacyRequest.utf8))
            t.checkEqual(decoded.modelId, LTXModelCatalog.defaultModelID, "legacy request: modelId defaults")
            t.checkEqual(decoded.customModelsEnabled, false, "legacy request: customModelsEnabled defaults false")
            t.check(decoded.modelRevision == nil && decoded.filmProjectID == nil && decoded.preset == nil, "legacy request: new fields nil")
        } catch {
            t.check(false, "legacy GenerationRequest decodes (threw \(error))")
        }

        // Legacy GenerationResult JSON must decode.
        let legacyResult = """
        {"id":"22222222-2222-2222-2222-222222222222","requestId":"11111111-1111-1111-1111-111111111111","prompt":"p","negativePrompt":"","voiceoverText":"","voiceoverSource":"mlx-audio","voiceoverVoice":"af_heart","modelId":"ltx23_distilled_q4","parameters":{"numInferenceSteps":30,"guidanceScale":3.0,"width":768,"height":512,"numFrames":121,"fps":24,"vaeTilingMode":"auto","imageStrength":1.0},"videoPath":"/tmp/x.mp4","createdAt":700000000,"completedAt":700000100,"duration":100,"seed":42}
        """
        do {
            let decoded = try JSONDecoder().decode(GenerationResult.self, from: Data(legacyResult.utf8))
            t.checkEqual(decoded.seed, 42, "legacy result decodes")
            t.check(decoded.actualWidth == nil && decoded.peakMemoryBytes == nil && decoded.preset == nil
                    && decoded.effectiveProfileID == nil, "legacy result: new fields nil")
        } catch {
            t.check(false, "legacy GenerationResult decodes (threw \(error))")
        }

        // Round-trip with new fields populated.
        var request = GenerationRequest(
            prompt: "x",
            qualityMode: "auto",
            preset: "standard",
            targetDurationSeconds: 5,
            generationSource: "oneShot",
            customModelsEnabled: false,
            filmProjectID: UUID()
        )
        request.modelRevision = "abc123"
        do {
            let data = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(GenerationRequest.self, from: data)
            t.checkEqual(decoded.modelRevision, "abc123", "new request fields round-trip")
            t.checkEqual(decoded.qualityMode, "auto", "qualityMode round-trips")
            t.checkEqual(decoded.preset, "standard", "preset round-trips")
            t.checkEqual(decoded.targetDurationSeconds, 5, "target duration round-trips")
            t.checkEqual(decoded.generationSource, "oneShot", "generation source round-trips")
        } catch {
            t.check(false, "new request fields round-trip (threw \(error))")
        }

        var result = GenerationResult.preview()
        result.effectiveProfileReason = "hardware prior"
        result.targetDurationSeconds = 5
        result.requestedDurationSeconds = 5.04
        result.audioEnabled = true
        result.generationSource = "storyboard"
        do {
            let data = try JSONEncoder().encode(result)
            let decoded = try JSONDecoder().decode(GenerationResult.self, from: data)
            t.checkEqual(decoded.effectiveProfileReason, "hardware prior", "profile reason round-trips")
            t.checkEqual(decoded.targetDurationSeconds, 5, "result target duration round-trips")
            t.checkEqual(decoded.requestedDurationSeconds, 5.04, "result requested duration round-trips")
            t.checkEqual(decoded.audioEnabled, true, "result audio state round-trips")
            t.checkEqual(decoded.generationSource, "storyboard", "result source round-trips")
        } catch {
            t.check(false, "new result fields round-trip (threw \(error))")
        }
    }

    t.suite("Feature flags") {
        // Untouched defaults: GUI features ON, sensitive features OFF.
        let freshSuite = "LTXTests.flags.\(UUID().uuidString)"
        let fresh = UserDefaults(suiteName: freshSuite)!
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        for flag in FeatureFlag.allCases {
            t.checkEqual(FeatureFlags.isEnabled(flag, userDefaults: fresh), flag.defaultEnabled,
                         "\(flag.rawValue) untouched default matches defaultEnabled")
        }
        t.check(!FeatureFlag.derivedModelsV1.defaultEnabled, "derived models default OFF")
        t.check(FeatureFlag.customModelsV1.defaultEnabled, "custom models default ON")
        t.check(!FeatureFlag.lowRAMAdapterV1.defaultEnabled, "low-RAM adapter default OFF")
        t.check(!FeatureFlag.localAPIv1.defaultEnabled, "local API default OFF")

        // Explicit rollback always restores the legacy path.
        FeatureFlags.disableAll(userDefaults: fresh)
        for flag in FeatureFlag.allCases {
            t.check(!FeatureFlags.isEnabled(flag, userDefaults: fresh), "\(flag.rawValue) OFF after disableAll")
        }
        FeatureFlags.set(.modelRegistryV1, enabled: true, userDefaults: fresh)
        t.check(FeatureFlags.isEnabled(.modelRegistryV1, userDefaults: fresh), "flag can be re-enabled")
    }

    t.suite("Custom profile execution boundary (adapter, not just resolver)") {
        // Regression coverage for a real bug: GenerationModelResolver already
        // resolved custom_profile_<UUID> correctly, but the actual execution
        // path used by Generate/One Shot/Storyboard/Auto Movie goes through
        // ModelRegistry -> AdapterRegistry -> LTX2MLXAdapter (gated by
        // modelRegistryV1, which defaults ON) — a completely separate
        // boundary that re-derived its LTXModel from LTX2MLXModelCatalog
        // instead of the already-resolved ModelDescriptor. That catalog only
        // ever knew the single legacy custom-model slot and LTX-2.5
        // Experimental, so every per-profile ID hit "is not a registered
        // ltx-2-mlx model" before it ever reached the backend. Fixture names
        // are neutral by design — this is purely a plumbing bug, never keyed
        // on any specific model name or path.
        let profileSuite = "LTXTests.customProfileBoundary.\(UUID().uuidString)"
        let profileDefaults = UserDefaults(suiteName: profileSuite)!
        defer { profileDefaults.removePersistentDomain(forName: profileSuite) }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-custom-profile-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let profileA = CustomModelProfile(displayName: "Custom Profile A", modelPath: tmpDir.appendingPathComponent("profile-a").path)
        let profileB = CustomModelProfile(displayName: "Custom Profile B", modelPath: tmpDir.appendingPathComponent("profile-b").path)
        try? CustomModelProfileStore.addProfile(profileA, userDefaults: profileDefaults)
        try? CustomModelProfileStore.addProfile(profileB, userDefaults: profileDefaults)

        let registry = ModelRegistry(userDefaults: profileDefaults)

        // 1 & 3. Descriptor resolves with the correct backend and its OWN local path.
        let descriptorA = registry.descriptor(id: profileA.modelID)
        t.checkEqual(descriptorA?.runtime.backend, "ltx-2-mlx", "custom profile A resolves to the ltx-2-mlx backend")
        t.checkEqual(descriptorA?.localPath, profileA.modelPath, "custom profile A descriptor carries its own local path")

        // 8. Multi-profile selection: each resolves to itself, never another profile.
        let descriptorB = registry.descriptor(id: profileB.modelID)
        t.checkEqual(descriptorB?.localPath, profileB.modelPath, "custom profile B descriptor carries its own local path, not A's")
        t.check(descriptorA?.localPath != descriptorB?.localPath, "two custom profiles resolve to distinct local paths")

        // 5. No default-backend fallback for a custom profile.
        switch GenerationModelResolver.resolve(modelID: profileA.modelID, registry: registry, userDefaults: profileDefaults) {
        case .runnable(let runnable):
            t.checkEqual(runnable.backend, .ltx2MLX, "custom profile routes to ltx2MLX, never the default backend")
        case .unsupported:
            t.check(false, "custom profile A must be runnable")
        }

        // 6. Missing/deleted custom profile still fails closed.
        let missingID = CustomModelProfile.idPrefix + UUID().uuidString
        t.check(registry.descriptor(id: missingID) == nil, "an unregistered custom profile ID has no descriptor")
        switch GenerationModelResolver.resolve(modelID: missingID, registry: registry, userDefaults: profileDefaults) {
        case .runnable:
            t.check(false, "an unregistered custom profile must not resolve as runnable")
        case .unsupported(let reason):
            t.checkEqual(reason, .unknownModel(modelID: missingID),
                         "an unregistered custom profile is reported unknown, never silently substituted")
        }

        // 7. Built-in models keep using the fast catalog path (unaffected by the fallback).
        let officialAdapter = AdapterRegistry()
        let officialDescriptor = registry.descriptor(id: LTXModelCatalog.defaultModelID)!
        t.check(officialAdapter.adapter(for: officialDescriptor) is OfficialMLXAudioAdapter,
                "built-in LTX-2.3 model still routes through the official adapter, unaffected by this fix")

        // THE CORE REGRESSION: LTX2MLXAdapter must not reject a real custom
        // profile with "is not a registered ltx-2-mlx model" — it must get
        // past the catalog lookup and fail (if at all) for an environment
        // reason (missing runtime/model components in this test sandbox),
        // never for an identity reason.
        guard let descriptor = descriptorA else {
            t.check(false, "custom profile A descriptor must exist for the adapter regression check")
            return
        }
        let adapter = LTX2MLXAdapter()
        t.check(adapter.supports(model: descriptor), "LTX2MLXAdapter supports a per-profile custom model, not just the legacy slot")

        let request = GenerationRequest(prompt: "test prompt", modelId: profileA.modelID, userDefaults: profileDefaults)
        // 9. Archive/project identity stays the stable profile ID even though
        // execution will use the resolved local path, never the ID itself.
        t.checkEqual(request.modelId, profileA.modelID, "request modelId stays the stable custom profile ID for Archive/history identity")
        t.checkEqual(request.customModelProfileID, profileA.id, "request binds to the correct profile UUID")
        t.checkEqual(request.customModelLocalPath, profileA.modelPath, "request carries the resolved local model path")

        let sem = DispatchSemaphore(value: 0)
        var caughtError: Error?
        Task {
            do {
                _ = try await adapter.generate(
                    request: request,
                    model: descriptor,
                    outputPath: tmpDir.appendingPathComponent("out.mp4").path,
                    progressHandler: { _, _ in }
                )
            } catch {
                caughtError = error
            }
            sem.signal()
        }
        sem.wait()
        let errorDescription = caughtError.map { String(describing: $0) } ?? ""
        t.check(!errorDescription.contains("is not a registered ltx-2-mlx model"),
                "custom profile is no longer rejected as an unregistered ltx-2-mlx model (got: \(errorDescription.isEmpty ? "no error" : errorDescription))")
    }

    t.suite("Custom Model seed configuration") {
        let customSuite = "LTXTests.customSeed.\(UUID().uuidString)"
        let customDefaults = UserDefaults(suiteName: customSuite)!
        defer { customDefaults.removePersistentDomain(forName: customSuite) }

        customDefaults.set("org/remote-custom-model", forKey: ModelRegistry.customRepositoryUserDefaultsKey)
        customDefaults.set("/local/path/to/custom-model", forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        customDefaults.set(CustomModelSourceMode.local.rawValue, forKey: ModelRegistry.customSourceModeUserDefaultsKey)

        let customRegistry = ModelRegistry(userDefaults: customDefaults)
        let desc = customRegistry.descriptor(id: ModelRegistry.customModelID)
        t.check(desc != nil, "custom descriptor present")
        t.checkEqual(desc?.repository, "org/remote-custom-model", "custom descriptor seeds configured repository")
        t.checkEqual(desc?.localPath, "/local/path/to/custom-model", "custom descriptor seeds configured local path")
    }
}
