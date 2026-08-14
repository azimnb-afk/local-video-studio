import Foundation
@testable import LTXVideoGeneratorCore

func runAutoQualityTests(_ t: TestKit) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-aq-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    func snapshot(physicalGB: Double, availableGB: Double) -> MemorySnapshot {
        MemorySnapshot(
            physicalBytes: UInt64(physicalGB * 1_073_741_824),
            approximateAvailableBytes: UInt64(availableGB * 1_073_741_824),
            swapUsedBytes: 0, swapTotalBytes: 0,
            thermalState: "nominal", capturedAt: Date()
        )
    }
    func hardware(_ gb: Int) -> HardwareProfile {
        HardwareProfile(modelIdentifier: "TestMac1,1", chipDescription: "Test", physicalMemoryGB: gb)
    }

    t.suite("User-facing preset mapping") {
        t.checkEqual(GenerationPreset.quickPreview.qualityMode, .compact, "Quick Preview → Compact")
        t.checkEqual(GenerationPreset.standard.qualityMode, .auto, "Standard → Auto")
        t.checkEqual(GenerationPreset.highQuality.qualityMode, .high, "High Quality → High")
        t.checkEqual(GenerationPreset.custom.qualityMode, .advanced, "Custom → Advanced")
        t.checkEqual(GenerationPreset.resolving(presetRaw: nil, qualityModeRaw: "compact"), .quickPreview,
                     "legacy Compact resolves to Quick Preview")
        var settings = ProjectSettings()
        settings.applyPreset(.highQuality)
        t.checkEqual(settings.qualityMode, QualityMode.high.rawValue, "Project Settings uses shared mapping")
        settings.width = 1024
        settings.markCustom()
        t.checkEqual(settings.resolvedPreset, .custom, "manual setting marks Custom")
        t.checkEqual(settings.qualityMode, QualityMode.advanced.rawValue, "manual setting marks Advanced")
        settings.audioEnabled = false
        settings.applyPreset(.standard)
        t.checkEqual(settings.audioEnabled, true, "reapplying Standard clears conflicting manual audio")
        t.checkEqual(settings.width, GenerationParameters.default.width, "reapplying Standard clears conflicting manual size")

        settings.applyPreset(.custom)
        settings.width = 1024
        settings.height = 768
        settings.numFrames = 121
        settings.numInferenceSteps = 30
        settings.audioEnabled = false
        settings.applyPreset(.quickPreview)
        t.checkEqual(settings.resolvedPreset, .quickPreview, "Custom → Quick records Quick preset")
        t.checkEqual(settings.width, 512, "Custom → Quick clears stale width")
        t.checkEqual(settings.height, 320, "Custom → Quick clears stale height")
        t.checkEqual(settings.numFrames, 49, "Custom → Quick clears stale frame count")
        t.checkEqual(settings.numInferenceSteps, 15, "Custom → Quick clears stale step count")
        settings.applyPreset(.custom)
        t.checkEqual(settings.resolvedPreset, .custom, "Quick → Custom enters manual mode")
        t.checkEqual(settings.width, 512, "Quick → Custom retains the editable Quick baseline")
    }

    t.suite("Memory monitor") {
        let snap = MemoryMonitor.shared.snapshot()
        t.check(snap.physicalBytes > 0, "physical memory read")
        t.check(snap.approximateAvailableBytes > 0, "available memory read")
        t.check(["nominal", "fair", "serious", "critical", "unknown"].contains(snap.thermalState), "thermal state valid")
        t.check(MemoryMonitor.currentProcessFootprint() > 0, "process footprint read")
        let hw = HardwareProfiler.current()
        t.check(hw.physicalMemoryGB >= 8, "hardware profiler reads memory")
        t.check(!hw.modelIdentifier.isEmpty, "model identifier read")
    }

    t.suite("Hardware tiers") {
        t.checkEqual(hardware(16).memoryTier, .tier16, "16GB tier")
        t.checkEqual(hardware(24).memoryTier, .tier24, "24GB tier")
        t.checkEqual(hardware(32).memoryTier, .tier32, "32GB tier")
        t.checkEqual(hardware(48).memoryTier, .tier48, "48GB tier")
        t.checkEqual(hardware(128).memoryTier, .tier64plus, "128GB tier")
    }

    t.suite("Auto resolution priors") {
        let store = HistoricalSuccessStore(storeURL: tmpDir.appendingPathComponent("h1.json"))
        let snap48 = snapshot(physicalGB: 48, availableGB: 30)

        // 48GB, no history → Standard profile. High remains a distinct,
        // explicit preset on this hardware.
        let engine48 = AutoQualityEngine(history: store, hardware: hardware(48))
        do {
            let res = try engine48.resolve(mode: .auto, modelID: "m", snapshot: snap48, audioRequested: true)
            t.checkEqual(res.profile.id, "S0", "48GB auto prior = Standard")
            t.check(res.attemptLadder.count <= AutoQualityEngine.maxAttempts, "ladder capped at 3 attempts")
            t.checkEqual(res.attemptLadder.first?.id, "S0", "ladder starts at chosen profile")
        } catch { t.check(false, "48GB auto resolve threw \(error)") }

        // 16GB → Compact C0 prior; ladder must not contain anything above C0.
        let engine16 = AutoQualityEngine(history: store, hardware: hardware(16))
        do {
            let res = try engine16.resolve(mode: .auto, modelID: "m", snapshot: snapshot(physicalGB: 16, availableGB: 8), audioRequested: false)
            t.checkEqual(res.profile.id, "C0", "16GB auto prior = C0")
        } catch { t.check(false, "16GB auto resolve threw \(error)") }

        // Advanced mode is refused (never modified by Auto Quality).
        t.checkThrows(AutoQualityEngine.ResolutionError.unsupported("Advanced mode is user-controlled; Auto Quality must not modify it."),
                      "advanced mode refused") {
            _ = try engine48.resolve(mode: .advanced, modelID: "m", snapshot: snap48, audioRequested: true)
        }

        // Compact mode honors audio request.
        do {
            let resAudio = try engine48.resolve(mode: .compact, modelID: "m", snapshot: snap48, audioRequested: true)
            t.checkEqual(resAudio.profile.id, "C3", "compact + audio → C3")
            let resNoAudio = try engine48.resolve(mode: .compact, modelID: "m", snapshot: snap48, audioRequested: false)
            t.checkEqual(resNoAudio.profile.id, "C2", "compact no audio → C2")
        } catch { t.check(false, "compact resolve threw \(error)") }
    }

    t.suite("Historical success") {
        let store = HistoricalSuccessStore(storeURL: tmpDir.appendingPathComponent("h2.json"))
        let engine = AutoQualityEngine(history: store, hardware: hardware(48))
        let snap = snapshot(physicalGB: 48, availableGB: 30)

        // Record: standard succeeded, high failed.
        engine.recordOutcome(modelID: "m", profileID: "S0", succeeded: true)
        engine.recordOutcome(modelID: "m", profileID: "H0", succeeded: false)
        do {
            let res = try engine.resolve(mode: .auto, modelID: "m", snapshot: snap, audioRequested: true)
            t.checkEqual(res.profile.id, "S0", "known-safe profile preferred over failed higher profile")
        } catch { t.check(false, "history resolve threw \(error)") }

        // A later High success confirms Standard's hardware prior but does not
        // collapse the explicit Standard and High presets.
        engine.recordOutcome(modelID: "m", profileID: "H0", succeeded: true)
        do {
            let res = try engine.resolve(mode: .auto, modelID: "m", snapshot: snap, audioRequested: true)
            t.checkEqual(res.profile.id, "S0", "high success does not promote Standard past its prior")
        } catch { t.check(false, "promotion resolve threw \(error)") }

        // History is per hardware signature.
        let other = AutoQualityEngine(history: store, hardware: hardware(16))
        do {
            let res = try other.resolve(mode: .auto, modelID: "m", snapshot: snapshot(physicalGB: 16, availableGB: 8), audioRequested: false)
            t.checkEqual(res.profile.id, "C0", "other hardware unaffected by 48GB history")
        } catch { t.check(false, "per-hardware resolve threw \(error)") }

        // Persistence.
        let store2 = HistoricalSuccessStore(storeURL: tmpDir.appendingPathComponent("h2.json"))
        t.check(store2.highestKnownSafeProfile(hardwareSignature: "TestMac1,1/48GB", modelID: "m")?.id == "H0",
                "history persists")

        // A Compact success without a Standard failure must not pin Auto to
        // Compact (the production regression that made Quick == Standard).
        let lowerOnlyStore = HistoricalSuccessStore(storeURL: tmpDir.appendingPathComponent("h-lower-only.json"))
        let lowerOnly = AutoQualityEngine(history: lowerOnlyStore, hardware: hardware(48))
        lowerOnly.recordOutcome(modelID: "m", profileID: "C2", succeeded: true)
        do {
            let res = try lowerOnly.resolve(mode: .auto, modelID: "m", snapshot: snap, audioRequested: true)
            t.checkEqual(res.profile.id, "S0", "lower success alone does not cap Standard")
            t.check(res.reason.contains("lower-profile successes do not cap"), "uncapped reason is explicit")
        } catch { t.check(false, "lower-only history resolve threw \(error)") }

        // An actual failure at Standard plus a known Compact success does cap
        // Auto, and the reason is persisted for diagnostics.
        lowerOnly.recordOutcome(modelID: "m", profileID: "S0", succeeded: false)
        do {
            let res = try lowerOnly.resolve(mode: .auto, modelID: "m", snapshot: snap, audioRequested: true)
            t.checkEqual(res.profile.id, "C2", "failed Standard falls back to known-safe Compact")
            t.check(res.reason.contains("History fallback"), "history fallback reason is explicit")
        } catch { t.check(false, "history fallback resolve threw \(error)") }
    }

    t.suite("Failure classification / profile application") {
        t.check(AutoQualityEngine.isMemoryRelatedFailure(LTXError.generationFailed("killed by SIGKILL (exit code -9)")),
                "sigkill classified as memory failure")
        t.check(AutoQualityEngine.isMemoryRelatedFailure(LTXError.generationFailed("Metal out of memory")),
                "oom classified as memory failure")
        t.check(!AutoQualityEngine.isMemoryRelatedFailure(LTXError.generationFailed("config mismatch")),
                "non-memory failure not retried")

        let request = GenerationRequest(prompt: "p", parameters: .default, qualityMode: "auto", preset: "standard")
        let applied = GenerationService.applying(profile: QualityProfileLadder.compact0, to: request)
        t.checkEqual(applied.parameters.width, 512, "profile width applied")
        t.checkEqual(applied.parameters.numFrames, 25, "profile frames applied")
        t.check(applied.disableAudio, "C0 disables audio")
        t.checkEqual(applied.id, request.id, "request identity preserved")
        t.checkEqual(applied.prompt, "p", "prompt preserved")
        t.checkEqual(applied.preset, "standard", "preset snapshot preserved")
    }

    t.suite("Resolved Quick / Standard / High requests") {
        let store = HistoricalSuccessStore(storeURL: tmpDir.appendingPathComponent("comparison.json"))
        let engine = AutoQualityEngine(history: store, hardware: hardware(48))
        let snap = snapshot(physicalGB: 48, availableGB: 30)
        let seed = 4242
        let target = 5.0

        func request(_ preset: GenerationPreset, source: String = "oneShot") -> GenerationRequest {
            var p = GenerationParameters.default
            p.seed = seed
            return GenerationRequest(
                prompt: "same cinematic brief",
                modelId: LTXModelCatalog.defaultModelID,
                parameters: p,
                qualityMode: preset.qualityMode.rawValue,
                preset: preset.rawValue,
                targetDurationSeconds: target,
                generationSource: source
            )
        }

        do {
            let quick = try GenerationSettingsResolver.resolve(request: request(.quickPreview), engine: engine, snapshot: snap)
            let standard = try GenerationSettingsResolver.resolve(request: request(.standard), engine: engine, snapshot: snap)
            let high = try GenerationSettingsResolver.resolve(request: request(.highQuality), engine: engine, snapshot: snap)

            t.checkEqual(quick.profile?.id, "C3", "Quick resolves to C3")
            t.checkEqual(standard.profile?.id, "S0", "Standard resolves to S0")
            t.checkEqual(high.profile?.id, "H0", "High resolves to H0")
            t.checkEqual(quick.request.parameters.width, 512, "Quick final width")
            t.checkEqual(standard.request.parameters.width, 768, "Standard final width")
            t.checkEqual(high.request.parameters.numInferenceSteps, 30, "High final steps")
            t.check(quick.request.parameters.numInferenceSteps < standard.request.parameters.numInferenceSteps,
                    "Quick steps lower than Standard")
            t.check(standard.request.parameters.numInferenceSteps < high.request.parameters.numInferenceSteps,
                    "Standard steps lower than High")
            let expectedFrames = PromptCompiler.frameCount(forSeconds: target, fps: 24)
            t.checkEqual(quick.request.parameters.numFrames, expectedFrames, "Quick honors target duration")
            t.checkEqual(standard.request.parameters.numFrames, expectedFrames, "Standard honors target duration")
            t.checkEqual(high.request.parameters.numFrames, expectedFrames, "High honors target duration")
            t.checkEqual(quick.request.parameters.seed, seed, "Quick seed preserved")
            t.checkEqual(standard.request.parameters.seed, seed, "Standard seed preserved")
            t.checkEqual(high.request.parameters.seed, seed, "High seed preserved")
            t.check(!quick.request.disableAudio && !standard.request.disableAudio && !high.request.disableAudio,
                    "audio is explicit in all resolved requests")
        } catch { t.check(false, "request comparison threw \(error)") }

        // Every producer may carry stale Custom parameters, but the shared
        // resolver—not a view-local mapping—must make non-Custom presets win.
        var staleCustom = GenerationParameters.highQuality
        staleCustom.width = 1024
        staleCustom.height = 768
        staleCustom.numFrames = 121
        staleCustom.numInferenceSteps = 30
        for source in ["generate", "oneShot", "storyboard", "hybrid"] {
            let rawQuick = GenerationRequest(
                prompt: "same cinematic brief",
                disableAudio: false,
                modelId: LTXModelCatalog.defaultModelID,
                parameters: staleCustom,
                qualityMode: GenerationPreset.quickPreview.qualityMode.rawValue,
                preset: GenerationPreset.quickPreview.rawValue,
                generationSource: source
            )
            do {
                let resolved = try GenerationSettingsResolver.resolve(request: rawQuick, engine: engine, snapshot: snap)
                t.checkEqual(resolved.profile?.id, "C3", "\(source) Quick selects audio profile")
                t.checkEqual(resolved.request.parameters.width, 512, "\(source) Quick overrides stale width")
                t.checkEqual(resolved.request.parameters.height, 320, "\(source) Quick overrides stale height")
                t.checkEqual(resolved.request.parameters.numFrames, 49, "\(source) Quick overrides stale frames")
                t.checkEqual(resolved.request.parameters.numInferenceSteps, 15, "\(source) Quick overrides stale steps")
            } catch {
                t.check(false, "\(source) Quick resolution threw \(error)")
            }
        }

        let noAudioQuick = GenerationRequest(
            prompt: "same cinematic brief",
            disableAudio: true,
            modelId: LTXModelCatalog.defaultModelID,
            parameters: staleCustom,
            qualityMode: GenerationPreset.quickPreview.qualityMode.rawValue,
            preset: GenerationPreset.quickPreview.rawValue,
            generationSource: "generate"
        )
        do {
            let resolved = try GenerationSettingsResolver.resolve(request: noAudioQuick, engine: engine, snapshot: snap)
            t.checkEqual(resolved.profile?.id, "C2", "Quick without audio selects C2")
            t.checkEqual(resolved.request.parameters.width, 512, "Quick without audio retains compact width")
            t.checkEqual(resolved.request.parameters.numFrames, 65, "Quick without audio uses C2 frames")
            t.check(resolved.request.disableAudio, "Quick without audio remains disabled")
        } catch { t.check(false, "no-audio Quick resolution threw \(error)") }

        var customParams = GenerationParameters.default
        customParams.numFrames = 81
        let custom = GenerationRequest(
            prompt: "same cinematic brief",
            parameters: customParams,
            qualityMode: QualityMode.advanced.rawValue,
            preset: GenerationPreset.custom.rawValue,
            targetDurationSeconds: 2,
            generationSource: "oneShot"
        )
        do {
            let resolved = try GenerationSettingsResolver.resolve(request: custom, engine: engine, snapshot: snap)
            t.checkEqual(resolved.request.parameters.numFrames, 81, "Custom manual frames win over target duration")
            t.checkEqual(resolved.request.parameters.width, customParams.width, "Custom preserves manual width")
            t.check(resolved.profile == nil, "Custom has no automatic profile")
        } catch { t.check(false, "custom resolution threw \(error)") }
    }

    t.suite("MediaProbe") {
        // Probe a repository-owned synthetic MP4 (real integration check).
        let baseline = TestFixtures.videoWithAudioA
        if FileManager.default.fileExists(atPath: baseline), MediaProbe.ffprobePath() != nil {
            if let info = MediaProbe.probe(path: baseline) {
                t.checkEqual(info.width, 512, "baseline mp4 width")
                t.checkEqual(info.height, 320, "baseline mp4 height")
                t.checkEqual(info.videoCodec, "h264", "baseline codec")
                t.check(info.hasAudio, "baseline has audio stream")
                t.check((info.durationSeconds ?? 0) > 0.9, "baseline duration read")
            } else {
                t.check(false, "probe of baseline mp4 returned nil")
            }
        } else {
            t.check(true, "baseline mp4 unavailable — probe smoke skipped")
        }
        t.check(MediaProbe.probe(path: "/tmp/does-not-exist.mp4") == nil, "missing file probes nil")
    }

    t.suite("LowRAM adapter gating") {
        let suiteName = "LTXTests.lowram.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let adapter = LowRAMMLXAdapter(userDefaults: defaults)
        let registry = ModelRegistry(userDefaults: defaults)
        let official = registry.descriptor(id: LTXModelCatalog.defaultModelID)!

        t.check(!adapter.supports(model: official), "official model not claimed by low-RAM adapter")
        var lowRamModel = official
        lowRamModel.runtime.backend = "ltx-2-mlx"
        t.check(!adapter.supports(model: lowRamModel), "flag OFF → adapter inert")
        FeatureFlags.set(.lowRAMAdapterV1, enabled: true, userDefaults: defaults)
        t.check(adapter.supports(model: lowRamModel), "flag ON + ltx-2-mlx backend → supported")
        t.check(!adapter.backendVerified, "backend unverified by default (Runtime Verification Pending)")
    }
}
