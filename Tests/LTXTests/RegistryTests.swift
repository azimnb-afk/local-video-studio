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
        t.check(registry.descriptor(id: "10eros_v12_q8")?.runtime.verified == false, "10eros v1.2 lab model unverified")
        t.check(registry.descriptor(id: "10eros_v13_dmd_q4")?.runtime.verified == false, "10eros v1.3 lab model unverified")
        t.check(registry.descriptor(id: "10eros_v12_q8")?.policy.contentClassification == .adultVerified, "10eros classified adultVerified")
    }

    t.suite("Adult policy matrix") {
        let registry = ModelRegistry(userDefaults: defaults)
        // adultMode=false + general = allowed
        do {
            try registry.validatePolicy(modelID: LTXModelCatalog.defaultModelID, adultMode: false)
            t.check(true, "adult OFF + general allowed")
        } catch {
            t.check(false, "adult OFF + general allowed (threw \(error))")
        }
        // adultMode=false + adultVerified = reject
        t.checkThrows(ModelPolicyError.adultModelRequiresAdultMode(modelID: "10eros_v12_q8"),
                      "adult OFF + adultVerified rejected") {
            try registry.validatePolicy(modelID: "10eros_v12_q8", adultMode: false)
        }
        // adultMode=true + adultVerified = allowed (policy level)
        do {
            try registry.validatePolicy(modelID: "10eros_v12_q8", adultMode: true)
            t.check(true, "adult ON + adultVerified allowed at policy layer")
        } catch {
            t.check(false, "adult ON + adultVerified allowed (threw \(error))")
        }
        // unregistered model = reject
        t.checkThrows(ModelPolicyError.modelNotRegistered(modelID: "nonexistent"),
                      "unregistered model rejected") {
            try registry.validatePolicy(modelID: "nonexistent", adultMode: true)
        }
        // unverified model may never generate even with adult ON
        t.checkThrows(ModelPolicyError.modelUnverified(modelID: "10eros_v12_q8"),
                      "unverified model rejected for generation") {
            _ = try registry.validateForGeneration(modelID: "10eros_v12_q8", adultMode: true)
        }
        // official model passes generation gate
        do {
            let d = try registry.validateForGeneration(modelID: LTXModelCatalog.defaultModelID, adultMode: false)
            t.checkEqual(d.id, LTXModelCatalog.defaultModelID, "official model passes generation gate")
        } catch {
            t.check(false, "official model passes generation gate (threw \(error))")
        }
    }

    t.suite("Generation model resolution / no silent fallback") {
        let registry = ModelRegistry(userDefaults: defaults)

        // Official models resolve to themselves.
        for official in LTXModelCatalog.all {
            switch GenerationModelResolver.resolve(modelID: official.id, registry: registry) {
            case .runnable(let model):
                t.checkEqual(model.id, official.id, "official \(official.id) resolves to itself")
            case .unsupported:
                t.check(false, "official \(official.id) must be runnable")
            }
        }

        // No selection keeps the historical default for pre-selection projects.
        switch GenerationModelResolver.resolve(modelID: nil, registry: registry) {
        case .runnable(let model):
            t.checkEqual(model.id, LTXModelCatalog.defaultModel.id, "nil model ID → default")
        case .unsupported:
            t.check(false, "nil model ID must stay runnable")
        }
        t.check(GenerationModelResolver.isRunnable(modelID: "", registry: registry),
                "empty model ID → default, still runnable")

        // The regression this boundary exists for: a model the pickers can
        // offer, that the backend cannot run, must NOT resolve to a different
        // checkpoint. Before the fix these returned LTX-2.3 Distilled Q4.
        for labID in ["10eros_v12_q8", "10eros_v13_dmd_q4"] {
            t.check(registry.descriptor(id: labID) != nil, "\(labID) is a registered model")
            switch GenerationModelResolver.resolve(modelID: labID, registry: registry) {
            case .runnable(let model):
                t.check(false, "\(labID) must not silently resolve to \(model.id)")
            case .unsupported(let reason):
                guard case .notRunnableOnInstalledBackend(_, _, let detail) = reason else {
                    t.check(false, "\(labID) should report a backend reason"); break
                }
                t.check(!detail.isEmpty, "\(labID) carries a concrete reason")
                t.check(reason.userMessage.contains("cannot be generated"),
                        "\(labID) message states it cannot generate")
            }
            t.check(!GenerationModelResolver.isRunnable(modelID: labID, registry: registry),
                    "\(labID) is not runnable")
        }

        // A completely unknown ID also fails loudly rather than substituting.
        switch GenerationModelResolver.resolve(modelID: "no_such_model", registry: registry) {
        case .runnable(let model):
            t.check(false, "unknown ID must not resolve to \(model.id)")
        case .unsupported(let reason):
            t.checkEqual(reason, .unknownModel(modelID: "no_such_model"), "unknown ID reported as unknown")
        }

        // Gating is independent of runnability: a model being hidden must not
        // change how a stored selection resolves.
        FeatureFlags.disableAll(userDefaults: defaults)
        t.check(!GenerationModelResolver.isRunnable(modelID: "10eros_v13_dmd_q4", registry: registry),
                "not runnable with flags off")
        FeatureFlags.set(.derivedModelsV1, enabled: true, userDefaults: defaults)
        FeatureFlags.set(.adultModelsV1, enabled: true, userDefaults: defaults)
        t.check(!GenerationModelResolver.isRunnable(modelID: "10eros_v13_dmd_q4", registry: registry),
                "still not runnable with flags on — visibility is not capability")
        FeatureFlags.disableAll(userDefaults: defaults)

        // Every model the pickers can offer must resolve to itself or fail
        // loudly. This is the invariant that broke: it guards future additions.
        FeatureFlags.set(.derivedModelsV1, enabled: true, userDefaults: defaults)
        FeatureFlags.set(.adultModelsV1, enabled: true, userDefaults: defaults)
        for offered in registry.selectableModels(adultMode: true) {
            switch GenerationModelResolver.resolve(modelID: offered.id, registry: registry) {
            case .runnable(let model):
                t.checkEqual(model.id, offered.id, "offered \(offered.id) resolves to itself")
            case .unsupported(let reason):
                t.check(!reason.userMessage.isEmpty, "offered \(offered.id) explains why not")
            }
        }
        FeatureFlags.disableAll(userDefaults: defaults)
    }

    t.suite("Selectable models / flags") {
        let registry = ModelRegistry(userDefaults: defaults)
        // All flags OFF: only official models visible.
        FeatureFlags.disableAll(userDefaults: defaults)
        let officialOnly = registry.selectableModels(adultMode: true)
        t.checkEqual(officialOnly.count, LTXModelCatalog.all.count, "flags OFF → official models only")
        // derivedModelsV1 ON but adultModelsV1 OFF: adult lab models still hidden.
        FeatureFlags.set(.derivedModelsV1, enabled: true, userDefaults: defaults)
        t.checkEqual(registry.selectableModels(adultMode: true).count, LTXModelCatalog.all.count,
                     "derived ON, adultModels OFF → adult lab models hidden")
        // Both flags ON + adult mode ON: lab models appear.
        FeatureFlags.set(.adultModelsV1, enabled: true, userDefaults: defaults)
        t.checkEqual(registry.selectableModels(adultMode: true).count, LTXModelCatalog.all.count + 2,
                     "derived+adult ON + adultMode ON → lab models visible")
        // Adult mode OFF hides them regardless of flags.
        t.checkEqual(registry.selectableModels(adultMode: false).count, LTXModelCatalog.all.count,
                     "adultMode OFF hides adult models despite flags")
        FeatureFlags.disableAll(userDefaults: defaults)
    }

    t.suite("Adapter registry") {
        let registry = ModelRegistry(userDefaults: defaults)
        let adapters = AdapterRegistry()
        let official = registry.descriptor(id: LTXModelCatalog.defaultModelID)!
        t.check(adapters.adapter(for: official) is OfficialMLXAudioAdapter, "official model → OfficialMLXAudioAdapter")
        let lab = registry.descriptor(id: "10eros_v12_q8")!
        t.check(adapters.adapter(for: lab) is DerivedModelAdapter, "lab model → DerivedModelAdapter")
    }

    t.suite("Codable migration") {
        // Legacy GenerationRequest JSON (pre-extension) must decode.
        let legacyRequest = """
        {"id":"11111111-1111-1111-1111-111111111111","prompt":"p","negativePrompt":"","voiceoverText":"","voiceoverSource":"mlx-audio","voiceoverVoice":"af_heart","musicEnabled":false,"disableAudio":false,"gemmaRepetitionPenalty":1.2,"gemmaTopP":0.9,"parameters":{"numInferenceSteps":30,"guidanceScale":3.0,"width":768,"height":512,"numFrames":121,"fps":24,"vaeTilingMode":"auto","imageStrength":1.0},"createdAt":700000000,"status":"pending"}
        """
        do {
            let decoded = try JSONDecoder().decode(GenerationRequest.self, from: Data(legacyRequest.utf8))
            t.checkEqual(decoded.modelId, LTXModelCatalog.defaultModelID, "legacy request: modelId defaults")
            t.checkEqual(decoded.adultMode, false, "legacy request: adultMode defaults false")
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
            adultMode: false,
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
        t.check(!FeatureFlag.adultModelsV1.defaultEnabled, "adult models default OFF")
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
}
