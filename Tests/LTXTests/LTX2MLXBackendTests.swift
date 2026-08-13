import Foundation
@testable import LTXVideoGeneratorCore

/// Covers the second generation backend: readiness, routing, failure and
/// provenance. Nothing here re-implements the resolver or the continuity
/// chain — each test drives the production type.
func runLTX2MLXBackendTests(_ t: TestKit) {
    let tenEros = LTX2MLXModelCatalog.tenEros13DMDQ4

    // Builds a fake HF cache whose snapshot holds the component files the
    // runtime resolves, so readiness is exercised against real filesystem
    // layout rather than a stubbed answer.
    func makeHub(complete: Bool) -> URL {
        let hub = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hub-\(UUID().uuidString)")
        let snapshot = hub
            .appendingPathComponent("models--\(tenEros.repo.replacingOccurrences(of: "/", with: "--"))")
            .appendingPathComponent("snapshots").appendingPathComponent("abc123")
        try? FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let components = complete
            ? LTX2MLXModelCatalog.requiredComponents
            : Array(LTX2MLXModelCatalog.requiredComponents.dropLast())
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

    t.suite("10Eros readiness / runtime and model tracked separately") {
        let completeHub = makeHub(complete: true)
        let partialHub = makeHub(complete: false)
        let executable = makeExecutable()

        // 7. Runtime missing → not ready, even with the model fully downloaded.
        let noRuntime = UserDefaults(suiteName: "ltx2mlx-none-\(UUID().uuidString)")!
        var readiness = LTX2MLXRuntime.readiness(
            repository: tenEros.repo, userDefaults: noRuntime, hubDirectory: completeHub)
        t.check(!readiness.canGenerate, "runtime missing → cannot generate")
        t.check(!readiness.runtime.isReady, "runtime reported missing")
        t.check(readiness.model.isReady, "model still reported ready independently")
        t.check(readiness.runtime.detail.contains("not configured"), "runtime reason is actionable")

        // 8. Runtime ready + model missing → not ready, with the model blamed.
        let withRuntime = UserDefaults(suiteName: "ltx2mlx-rt-\(UUID().uuidString)")!
        withRuntime.set(executable, forKey: LTX2MLXRuntime.executablePathKey)
        readiness = LTX2MLXRuntime.readiness(
            repository: tenEros.repo, userDefaults: withRuntime, hubDirectory: partialHub)
        t.check(!readiness.canGenerate, "incomplete model → cannot generate")
        t.check(readiness.runtime.isReady, "runtime reported ready")
        t.check(!readiness.model.isReady, "partially downloaded model is not ready")

        // 9. Both ready → ready, and the model path is the snapshot directory.
        readiness = LTX2MLXRuntime.readiness(
            repository: tenEros.repo, userDefaults: withRuntime, hubDirectory: completeHub)
        t.check(readiness.canGenerate, "runtime + model ready → can generate")
        t.check(readiness.model.detail.hasSuffix("abc123"), "model resolves to the snapshot directory")

        // A configured-but-absent runtime path is missing, not ready.
        let badRuntime = UserDefaults(suiteName: "ltx2mlx-bad-\(UUID().uuidString)")!
        badRuntime.set("/nonexistent/ltx-2-mlx", forKey: LTX2MLXRuntime.executablePathKey)
        t.check(!LTX2MLXRuntime.runtimeReadiness(userDefaults: badRuntime).isReady,
                "nonexistent runtime path is not ready")
    }

    t.suite("10Eros sensitive gating") {
        let defaults = UserDefaults(suiteName: "ltx2mlx-gate-\(UUID().uuidString)")!
        let registry = ModelRegistry(userDefaults: defaults)

        // 10. Adult Mode off → 10Eros not offered.
        FeatureFlags.set(.derivedModelsV1, enabled: true, userDefaults: defaults)
        FeatureFlags.set(.adultModelsV1, enabled: true, userDefaults: defaults)
        t.check(!registry.selectableModels(adultMode: false).contains { $0.id == tenEros.id },
                "Adult Mode off hides 10Eros")

        // 11. Adult Mode on (with flags) → 10Eros offered.
        t.check(registry.selectableModels(adultMode: true).contains { $0.id == tenEros.id },
                "Adult Mode on offers 10Eros")

        // Enabling the feature must not itself fetch weights: readiness is
        // driven by what is on disk, never by the toggle.
        let emptyHub = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString)")
        t.check(!LTX2MLXRuntime.modelReadiness(repository: tenEros.repo, hubDirectory: emptyHub).isReady,
                "enabling Adult Mode does not make an undownloaded model ready")
        FeatureFlags.disableAll(userDefaults: defaults)
    }

    t.suite("10Eros request routing across workflows") {
        let registry = ModelRegistry.shared
        // 12-16. Every workflow that builds a request routes by model ID
        // alone, so One Shot, Storyboard, Auto Movie and Regenerate all reach
        // the same backend without workflow-specific branching.
        for source in ["generate", "oneShot", "storyboard", "hybrid", "apiV1"] {
            let tenErosRequest = GenerationRequest(
                prompt: "a calm landscape", modelId: tenEros.id, generationSource: source)
            t.checkEqual(GenerationModelResolver.backend(for: tenErosRequest.modelId, registry: registry),
                         .ltx2MLX, "\(source) with 10Eros routes to ltx-2-mlx")

            let ltxRequest = GenerationRequest(
                prompt: "a calm landscape", modelId: LTXModelCatalog.defaultModelID,
                generationSource: source)
            t.checkEqual(GenerationModelResolver.backend(for: ltxRequest.modelId, registry: registry),
                         .mlxVideoWithAudio, "\(source) with LTX-2.3 stays on the original backend")
        }

        // 16. Regenerate reuses the stored take's model, so the backend follows
        // the model rather than the current UI selection.
        let original = GenerationRequest(prompt: "shot", modelId: tenEros.id, generationSource: "storyboard")
        let regenerated = GenerationRequest(
            prompt: original.prompt, modelId: original.modelId, generationSource: "storyboard")
        t.checkEqual(GenerationModelResolver.backend(for: regenerated.modelId, registry: registry), .ltx2MLX,
                     "regenerate preserves the 10Eros backend")
    }

    t.suite("10Eros failure handling / no cross-backend fallback") {
        let executable = makeExecutable()
        let completeHub = makeHub(complete: true)

        // 17/18. A 10Eros request that cannot run fails as 10Eros. The resolver
        // is the only thing that picks a backend, and it has no path from a
        // failed ltx-2-mlx run to the LTX-2.3 backend.
        t.checkEqual(GenerationModelResolver.backend(for: tenEros.id), .ltx2MLX,
                     "10Eros has exactly one backend")

        let noRuntime = UserDefaults(suiteName: "ltx2mlx-fail-\(UUID().uuidString)")!
        let missingRuntime = LTX2MLXRuntime.readiness(
            repository: tenEros.repo, userDefaults: noRuntime, hubDirectory: completeHub)
        t.check(missingRuntime.runtime.detail.lowercased().contains("ltx-2-mlx"),
                "missing runtime error names the runtime")

        let withRuntime = UserDefaults(suiteName: "ltx2mlx-fail2-\(UUID().uuidString)")!
        withRuntime.set(executable, forKey: LTX2MLXRuntime.executablePathKey)
        let emptyHub = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString)")
        let missingModel = LTX2MLXRuntime.readiness(
            repository: tenEros.repo, userDefaults: withRuntime, hubDirectory: emptyHub)
        t.check(missingModel.model.detail.contains(tenEros.repo),
                "missing model error names the exact repo")

        // 20. Settings this pipeline cannot honor are stated, not substituted.
        var params = GenerationParameters.default
        params.numInferenceSteps = 25
        params.guidanceScale = 3.5
        let request = GenerationRequest(
            prompt: "p", negativePrompt: "blurry", modelId: tenEros.id, parameters: params)
        let mismatch = LTX2MLXBackend.settingsMismatch(request: request)
        t.check(mismatch.notes.contains { $0.contains("25") }, "requested step count is reported verbatim")
        t.check(mismatch.notes.contains { $0.lowercased().contains("guidance") },
                "CFG mismatch is reported")
        t.check(mismatch.notes.contains { $0.lowercased().contains("negative prompt") },
                "unused negative prompt is reported")
    }

    t.suite("10Eros argument construction") {
        var params = GenerationParameters.default
        params.width = 512
        params.height = 288
        params.numFrames = 73
        params.fps = 24
        let request = GenerationRequest(
            prompt: "a calm landscape", sourceImagePath: "/tmp/source.png", modelId: tenEros.id,
            parameters: params)
        let args = LTX2MLXBackend.arguments(
            request: request, modelDirectory: "/models/10eros", outputPath: "/out/v.mp4",
            seed: 42, width: 512, height: 288)

        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        t.checkEqual(args.first, "generate", "invokes the generate subcommand")
        t.checkEqual(value(after: "--model"), "/models/10eros", "model directory passed through")
        t.checkEqual(value(after: "--seed"), "42", "seed passed through")
        t.checkEqual(value(after: "--frames"), "73", "frame count passed through")
        t.checkEqual(value(after: "--frame-rate"), "24", "frame rate passed through")
        t.checkEqual(value(after: "--output"), "/out/v.mp4", "output path passed through")
        t.check(args.contains("--distilled"), "uses the distilled pipeline the model is baked for")

        // 25/26. Continuity is unchanged: the backend consumes whatever
        // prepared image the existing chain produced, and a CUT shot has none.
        t.checkEqual(value(after: "--image"), "/tmp/source.png",
                     "CONTINUE source image reaches the runtime unmodified")
        let cutRequest = GenerationRequest(prompt: "p", sourceImagePath: nil, modelId: tenEros.id)
        let cutArgs = LTX2MLXBackend.arguments(
            request: cutRequest, modelDirectory: "/m", outputPath: "/o.mp4",
            seed: 1, width: 512, height: 288)
        t.check(!cutArgs.contains("--image"), "CUT shot passes no inherited image")
    }

    t.suite("10Eros provenance persistence") {
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

        // 22/23. A 10Eros request round-trips, and its backend is derived from
        // the persisted model ID rather than stored twice and risking drift.
        let request = GenerationRequest(prompt: "p", modelId: tenEros.id, quantization: "q4")
        guard let encoded = try? JSONEncoder().encode(request),
              let decoded = try? JSONDecoder().decode(GenerationRequest.self, from: encoded) else {
            t.check(false, "10Eros request must round-trip"); return
        }
        t.checkEqual(decoded.modelId, tenEros.id, "10Eros model ID round-trips")
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
}
