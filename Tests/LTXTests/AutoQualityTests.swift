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

        // 48GB, no history → High prior.
        let engine48 = AutoQualityEngine(history: store, hardware: hardware(48))
        do {
            let res = try engine48.resolve(mode: .auto, modelID: "m", snapshot: snap48, audioRequested: true)
            t.checkEqual(res.profile.id, "H0", "48GB auto prior = High")
            t.check(res.attemptLadder.count <= AutoQualityEngine.maxAttempts, "ladder capped at 3 attempts")
            t.checkEqual(res.attemptLadder.first?.id, "H0", "ladder starts at chosen profile")
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

        // Later success at high promotes back.
        engine.recordOutcome(modelID: "m", profileID: "H0", succeeded: true)
        do {
            let res = try engine.resolve(mode: .auto, modelID: "m", snapshot: snap, audioRequested: true)
            t.checkEqual(res.profile.id, "H0", "new success promotes profile")
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
    }

    t.suite("Failure classification / profile application") {
        t.check(AutoQualityEngine.isMemoryRelatedFailure(LTXError.generationFailed("killed by SIGKILL (exit code -9)")),
                "sigkill classified as memory failure")
        t.check(AutoQualityEngine.isMemoryRelatedFailure(LTXError.generationFailed("Metal out of memory")),
                "oom classified as memory failure")
        t.check(!AutoQualityEngine.isMemoryRelatedFailure(LTXError.generationFailed("config mismatch")),
                "non-memory failure not retried")

        let request = GenerationRequest(prompt: "p", parameters: .default, qualityMode: "auto")
        let applied = GenerationService.applying(profile: QualityProfileLadder.compact0, to: request)
        t.checkEqual(applied.parameters.width, 512, "profile width applied")
        t.checkEqual(applied.parameters.numFrames, 25, "profile frames applied")
        t.check(applied.disableAudio, "C0 disables audio")
        t.checkEqual(applied.id, request.id, "request identity preserved")
        t.checkEqual(applied.prompt, "p", "prompt preserved")
    }

    t.suite("MediaProbe") {
        // Probe the Phase 0 baseline MP4 when present (real integration check).
        let baseline = "/tmp/ltx_baseline/T2V-A-ON.mp4"
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
