import Foundation
@testable import LTXVideoGeneratorCore

/// Phase M / N / O: controlled H3 video experiments.
///
///   swift run LTXTests --h3-timing-matrix <source-image> [seed]
///   swift run LTXTests --h3-prompt-ab <source-image> [seed]
///
/// Both run through the production path
/// (GenerationService → ModelRegistry → AdapterRegistry → MiniMaxH3Adapter →
/// MiniMaxH3Backend) using isolated temporary store/history/output directories,
/// so no Dev or Personal project data is touched.
///
/// NOTHING here changes production default behavior. The pacing strategies below
/// live in the test layer on purpose: this experiment exists to decide whether
/// such a feature is worth building, not to ship one.
enum H3ShortClipTimingHarness {

    // MARK: - Pacing strategies (experiment only)

    /// Three ways to ask for the same action. Only the wording differs; every
    /// generation parameter is held identical within a comparison.
    enum PacingStrategy: String, CaseIterable {
        case current
        case immediate
        case timeline

        var label: String { rawValue.uppercased() }
    }

    /// Builds the prompt for one strategy. `durationSeconds` scales the timeline
    /// variant so the same code works for 90f and 107f clips.
    static func prompt(for strategy: PacingStrategy,
                       action: String,
                       durationSeconds: Double) -> String {
        switch strategy {
        case .current:
            return action

        case .immediate:
            return action + " From the very beginning of the video, the subject "
                + "immediately begins this action. There is no initial idle hold, "
                + "no preparatory pause, and no hesitation before the action starts."

        case .timeline:
            let start = 0.5
            let complete = max(start + 0.5, durationSeconds - 0.6)
            return action + String(
                format: " Timing: from 0.00 s to %.2f s the subject immediately begins the "
                    + "action. From %.2f s to %.2f s the main action continues without pausing. "
                    + "By approximately %.2f s the action is complete. For the remaining time "
                    + "the subject naturally holds the resulting position.",
                start, start, complete, complete)
        }
    }

    // MARK: - Shared generation

    struct Outcome {
        let label: String
        let ok: Bool
        let videoPath: String?
        let elapsedSeconds: Double
        let frames: Int
        let peakMemoryGB: Double
        let detail: String
    }

    /// Samples resident memory of the whole machine while a generation runs, so
    /// PEAK_MEMORY is an observation rather than an assumption.
    private final class MemorySampler {
        private var running = true
        private(set) var peakUsedGB: Double = 0
        private let queue = DispatchQueue(label: "h3-timing-memory-sampler")

        func start() {
            queue.async { [self] in
                while running {
                    peakUsedGB = max(peakUsedGB, Self.usedGB())
                    Thread.sleep(forTimeInterval: 2.0)
                }
            }
        }
        func stop() -> Double { running = false; return peakUsedGB }

        private static func usedGB() -> Double {
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
            let result = withUnsafeMutablePointer(to: &stats) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            let page = Double(vm_kernel_page_size)
            let used = (Double(stats.active_count) + Double(stats.wire_count)
                        + Double(stats.compressor_page_count)) * page
            return used / 1_073_741_824.0
        }
    }

    @MainActor
    private static func generate(
        label: String,
        prompt: String,
        sourceImagePath: String?,
        numFrames: Int,
        seed: Int,
        steps: Int,
        audioEnabled: Bool,
        modelDirectory: String?,
        endpoint: String,
        outputDirectory: URL
    ) async -> Outcome {
        let env = V3AcceptanceHarness.makeEnvironment(label: "h3-timing-\(label)")
        defer { V3AcceptanceHarness.restoreOutputDir(env) }

        var parameters = GenerationParameters.default
        parameters.width = 640
        parameters.height = 384
        parameters.fps = 24
        parameters.numFrames = numFrames
        parameters.numInferenceSteps = steps
        parameters.seed = seed

        let request = GenerationRequest(
            prompt: prompt,
            sourceImagePath: sourceImagePath,
            disableAudio: !audioEnabled,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            qualityMode: GenerationPreset.custom.qualityMode.rawValue,
            preset: MiniMaxH3Preset.custom.rawValue,
            targetDurationSeconds: Double(numFrames) / 24.0,
            generationSource: "generate",
            minimaxH3ModelDirectory: modelDirectory,
            minimaxH3Endpoint: endpoint,
            minimaxH3RequestedDurationSeconds: Double(numFrames) / 24.0)

        print("  [\(label)] frames=\(numFrames) seed=\(seed) steps=\(steps) "
              + "audio=\(audioEnabled ? "on" : "off")")
        print("  [\(label)] prompt: \(prompt)")

        let sampler = MemorySampler()
        sampler.start()
        let started = Date()
        env.generationService.addToQueue(request)

        let timeout: Double = 3_600
        while Date().timeIntervalSince(started) < timeout {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !env.generationService.isProcessing, env.generationService.queue.isEmpty { break }
        }
        let elapsed = Date().timeIntervalSince(started)
        let peak = sampler.stop()

        guard let result = env.historyManager.results.first(where: { $0.requestId == request.id }),
              let videoPath = result.videoPath as String?,
              FileManager.default.fileExists(atPath: videoPath) else {
            let detail = env.generationService.error.map { "\($0)" } ?? "no result recorded"
            print("  [\(label)] FAILED: \(detail)")
            return Outcome(label: label, ok: false, videoPath: nil, elapsedSeconds: elapsed,
                           frames: numFrames, peakMemoryGB: peak, detail: detail)
        }

        // Copy out of the isolated tmp tree so evidence survives cleanup.
        let destination = outputDirectory.appendingPathComponent("\(label).mp4")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: videoPath), to: destination)

        print(String(format: "  [%@] OK in %.1fs, peak %.1f GB → %@",
                     label, elapsed, peak, destination.lastPathComponent))
        return Outcome(label: label, ok: true, videoPath: destination.path,
                       elapsedSeconds: elapsed, frames: numFrames,
                       peakMemoryGB: peak, detail: "ok")
    }

    // MARK: - Preflight

    /// Read-only readiness check. Never starts or stops anything itself; the
    /// managed runtime is started by the production path when the first request
    /// runs, exactly as it would be for a user.
    private static func preflight(endpoint: String) async -> (ok: Bool, detail: String) {
        if let blocking = DefaultH3EnhancerHeavyTaskGuard().blockingReason() {
            return (false, "generation lease busy: \(blocking)")
        }
        let status = await MiniMaxH3RuntimeManager.shared.status(
            snapshot: MiniMaxH3Configuration.Snapshot(
                modelDirectory: nil, runtimeExecutablePath: nil, endpoint: endpoint))
        return (true, "state=\(status.state.rawValue) ownership=\(status.ownership?.rawValue ?? "none") "
                + "loaded=\(status.loadedModelID ?? "none") detail=\(status.detail)")
    }

    /// The Dev profile's already-installed managed runtime. This harness never
    /// installs, downloads or removes a runtime — it uses what is already there.
    static var devManagedRuntimeExecutable: String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/LocalVideoStudioDev/Runtimes/mlx-serve/mlx-serve")
            .path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Read-only: the H3 model directory the Dev app already has configured.
    /// This harness never writes any preference.
    static var devModelDirectory: String? {
        guard let raw = UserDefaults(suiteName: "com.localvideostudio.dev")?
            .string(forKey: "minimaxH3ModelDirectory")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return UserDefaults.standard.string(forKey: "minimaxH3ModelDirectory")
        }
        return raw
    }

    /// The Dev managed endpoint (11236), not the legacy external 11235. Using a
    /// dedicated port means the server this harness starts is app-owned and can
    /// be stopped afterwards without touching anything another process runs.
    static let devEndpoint = "http://127.0.0.1:11236"

    /// Starts the app-owned Dev server if it is not already up.
    @MainActor
    static func ensureServer(modelDirectory: String?, runtime: String)
        async -> (ok: Bool, detail: String) {
        let snapshot = MiniMaxH3Configuration.Snapshot(
            modelDirectory: modelDirectory,
            runtimeExecutablePath: runtime,
            endpoint: devEndpoint)
        do {
            let ready = try await MiniMaxH3RuntimeManager.shared.ensureReady(snapshot: snapshot) {
                progress, step in
                print("  SERVER_PROGRESS=\(String(format: "%.2f", progress)) \(step)")
            }
            let detail = "state=\(ready.state.rawValue) ownership=\(ready.ownership?.rawValue ?? "none") "
                + "loaded=\(ready.loadedModelID ?? "none")"
            return (ready.isReady, detail)
        } catch {
            return (false, "ensureReady failed: \(error.localizedDescription)")
        }
    }

    /// Stops ONLY a server this process owns. Never stops a server another app
    /// or another user process started.
    @MainActor
    static func stopOwnedServerIfAny() async {
        MiniMaxH3RuntimeManager.shared.stopOwnedServer()
        let status = await MiniMaxH3RuntimeManager.shared.status(
            snapshot: MiniMaxH3Configuration.Snapshot(
                modelDirectory: nil, runtimeExecutablePath: nil, endpoint: devEndpoint))
        print("APP_OWNED_STOP_STATE=\(status.state.rawValue)  STOP_POLICY=APP_OWNED_ONLY")
    }

    private static func evidenceDirectory(_ name: String) -> URL {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Reports/H3_Prompt_Enhancer_Overnight_2026-09-09/\(name)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Phase N/O: timing matrix

    /// The action under test. Chosen for an unambiguous onset and a clear
    /// completion, so "did it start early" and "did it finish" are both legible.
    static let timingAction =
        "A woman stands in a plain room and raises one hand high above her head."

    @MainActor
    static func runTimingMatrix(sourceImagePath: String?, seeds: [Int],
                               frameCounts: [Int]) async -> Int32 {
        let endpoint = devEndpoint
        print("H3 SHORT-CLIP ACTION-ONSET MATRIX")
        print("started: \(ISO8601DateFormatter().string(from: Date()))")
        let (ok, detail) = await preflight(endpoint: endpoint)
        print("preflight: \(detail)")
        guard ok else { print("BLOCKED: \(detail)"); return 2 }

        let modelDirectory = devModelDirectory
        guard let runtime = devManagedRuntimeExecutable else {
            print("BLOCKED: the Dev managed mlx-serve runtime is not installed. "
                  + "This harness never installs or downloads one.")
            return 2
        }
        print("runtime: \(runtime)")
        print("model directory: \(modelDirectory ?? "(default)")")
        let (serverOK, serverDetail) = await ensureServer(
            modelDirectory: modelDirectory, runtime: runtime)
        print("server: \(serverDetail)")
        guard serverOK else {
            print("BLOCKED: managed server did not reach Ready.")
            await stopOwnedServerIfAny()
            return 2
        }
        print("action: \(timingAction)")
        print("seeds: \(seeds.map(String.init).joined(separator: ", "))")
        print("frame counts: \(frameCounts.map(String.init).joined(separator: ", "))")
        print("source: \(sourceImagePath ?? "(T2V, none)")")
        print("generations planned: \(seeds.count * frameCounts.count * 2)")
        print("")

        let outputDir = evidenceDirectory("videos-timing-v2")
        var outcomes: [Outcome] = []

        // Repeat-aware paired design. The first run showed run-to-run variance
        // between two nominally identical CURRENT generations that was LARGER
        // than the gap between strategies, so a single sample per cell cannot
        // support any claim. Each strategy is therefore run across the same set
        // of seeds, and conditions are compared as distributions.
        //
        // TIMELINE is dropped: at seed 4242 it was indistinguishable from
        // IMMEDIATE (centroid 1.73 vs 1.69, identical onset and q25) while
        // costing a much longer prompt. Two conditions x more seeds buys more
        // information than three conditions x one seed.
        for frames in frameCounts {
            for strategy in [PacingStrategy.current, .immediate] {
                let duration = Double(frames) / 24.0
                for seed in seeds {
                let label = "\(frames)f-\(strategy.rawValue)-seed\(seed)"
                let outcome = await generate(
                    label: label,
                    prompt: prompt(for: strategy, action: timingAction, durationSeconds: duration),
                    sourceImagePath: sourceImagePath,
                    numFrames: frames, seed: seed, steps: 16, audioEnabled: false,
                    modelDirectory: modelDirectory, endpoint: endpoint,
                    outputDirectory: outputDir)
                outcomes.append(outcome)
                // Two attempts maximum per condition, and only for a transient
                // failure — never an unbounded retry loop.
                if !outcome.ok {
                    print("  retrying \(label) once (single bounded retry)")
                    let retry = await generate(
                        label: label + "-retry",
                        prompt: prompt(for: strategy, action: timingAction, durationSeconds: duration),
                        sourceImagePath: sourceImagePath,
                        numFrames: frames, seed: seed, steps: 16, audioEnabled: false,
                        modelDirectory: modelDirectory, endpoint: endpoint,
                        outputDirectory: outputDir)
                    outcomes.append(retry)
                    if !retry.ok {
                        print("  condition failed twice — stopping the heavyweight matrix.")
                        summarize(outcomes, title: "TIMING MATRIX (incomplete)")
                        await stopOwnedServerIfAny()
                        return 1
                    }
                }
                }
            }
        }

        summarize(outcomes, title: "TIMING MATRIX")
        await stopOwnedServerIfAny()
        print("videos: \(outputDir.path)")
        print("finished: \(ISO8601DateFormatter().string(from: Date()))")
        return 0
    }

    /// Reproduction probe. Two clips at the SAME seed from DIFFERENT prompts, to
    /// settle whether the prompt actually reaches the model: an A/B clip and a
    /// timing clip with unrelated prompts came back byte-identical, which would
    /// void every video conclusion if it were the norm.
    @MainActor
    static func runPromptSensitivityProbe(seed: Int) async -> Int32 {
        let endpoint = devEndpoint
        print("H3 PROMPT-SENSITIVITY PROBE")
        print("started: \(ISO8601DateFormatter().string(from: Date()))")
        let (ok, detail) = await preflight(endpoint: endpoint)
        print("preflight: \(detail)")
        guard ok else { print("BLOCKED: \(detail)"); return 2 }
        guard let runtime = devManagedRuntimeExecutable else {
            print("BLOCKED: Dev managed runtime not installed."); return 2
        }
        let modelDirectory = devModelDirectory
        let (serverOK, serverDetail) = await ensureServer(
            modelDirectory: modelDirectory, runtime: runtime)
        print("server: \(serverDetail)")
        guard serverOK else { await stopOwnedServerIfAny(); return 2 }

        let outputDir = evidenceDirectory("videos-probe")
        // The two exact prompts that previously produced identical bytes.
        let prompts = [
            ("probeA-woman-hand",
             "A woman stands in a plain room and raises one hand high above her head."),
            ("probeB-man-corridor",
             "a man standing in a corridor turns to the left and looks at the wall. "
                + "The camera movement remains smooth and consistent with the described shot."),
        ]
        var outcomes: [Outcome] = []
        for (label, prompt) in prompts {
            outcomes.append(await generate(
                label: "\(label)-seed\(seed)", prompt: prompt, sourceImagePath: nil,
                numFrames: 90, seed: seed, steps: 16, audioEnabled: false,
                modelDirectory: modelDirectory, endpoint: endpoint,
                outputDirectory: outputDir))
        }
        summarize(outcomes, title: "PROMPT-SENSITIVITY PROBE")
        await stopOwnedServerIfAny()
        print("videos: \(outputDir.path)")
        print("Compare the two files: identical bytes would mean the prompt does not")
        print("reach the model at this seed; different bytes mean it does.")
        print("finished: \(ISO8601DateFormatter().string(from: Date()))")
        return 0
    }

    // MARK: - Phase M: prompt A/B

    /// Six distinct shots covering the case types the A/B is meant to separate.
    /// `a` is the current pipeline's prompt, `b` the conservatively enhanced one.
    struct ABCase {
        let id: String
        let kind: String
        let original: String
    }

    static let abCases: [ABCase] = [
        .init(id: "AB1-simple", kind: "simple action",
              original: "a woman stands in a plain room and raises one hand above her head"),
        .init(id: "AB2-direction", kind: "direction-sensitive",
              original: "a man standing in a corridor turns to the left and looks at the wall"),
        .init(id: "AB3-pacing", kind: "pacing-sensitive",
              original: "the person slowly raises one hand above their head"),
        .init(id: "AB4-camera", kind: "camera-sensitive",
              original: "static medium shot of a woman who turns toward the camera"),
        .init(id: "AB5-japanese", kind: "Japanese source",
              original: "女性が部屋に立ち、ゆっくり片手を頭の上まで上げる"),
        .init(id: "AB6-environment", kind: "non-human motion",
              original: "rain falls onto a stone step and water runs down its edge"),
    ]

    @MainActor
    static func runPromptAB(sourceImagePath: String?, seed: Int, model: String?,
                           maxCases: Int = Int.max) async -> Int32 {
        let endpoint = devEndpoint
        print("H3 PROMPT A/B — current pipeline vs conservative enhancement")
        print("started: \(ISO8601DateFormatter().string(from: Date()))")
        let (ok, detail) = await preflight(endpoint: endpoint)
        print("preflight: \(detail)")
        guard ok else { print("BLOCKED: \(detail)"); return 2 }

        // Resolve the local model for enhancement, read-only.
        let environment = DirectorEnvironmentService()
        let snapshot = await environment.refresh(mode: .localAI)
        let chosen = model ?? DirectorEnvironmentService
            .compatibleCandidates(from: snapshot.installedModels).first
        guard let enhancerModel = chosen, snapshot.installedModels.contains(enhancerModel) else {
            print("BLOCKED: no installed local model for enhancement. No download attempted.")
            return 2
        }
        print("enhancer model: \(enhancerModel)")

        let modelDirectory = devModelDirectory
        let outputDir = evidenceDirectory("videos-ab")
        var outcomes: [Outcome] = []
        var pairs: [(id: String, kind: String, a: String, b: String, note: String)] = []

        // Enhance every case FIRST, so the local LLM is fully unloaded before any
        // H3 generation starts. Interleaving would put a 24 GB LLM and the H3
        // model in memory at the same time.
        print("\n--- enhancement pass (LLM), before any H3 work ---")
        let selectedCases = Array(abCases.prefix(maxCases))
        print("cases: \(selectedCases.count) of \(abCases.count) "
              + "(\(selectedCases.count * 2) generations)")
        for testCase in selectedCases {
            let enhancer = H3PromptEnhancer(
                provider: OllamaDirectorProvider(model: enhancerModel),
                residencyInspector: OllamaResidencyInspector(),
                timeoutSeconds: 180)
            let input = H3EnhancementInput(originalPrompt: testCase.original,
                                           isImageToVideo: sourceImagePath != nil)
            let result = await enhancer.enhance(input: input)

            // A: what the current pipeline sends for a direct prompt.
            let a = MiniMaxH3PromptCompiler.compile(
                rendererNeutralPrompt: testCase.original,
                isImageToVideo: sourceImagePath != nil)
            // B: the enhanced prompt, or a safe fallback to A when rejected.
            let b = result.rendererPrompt ?? a
            let note = result.status.isSuccess
                ? "enhanced"
                : "SAFE FALLBACK (\(result.status.label)) — B equals A"
            pairs.append((testCase.id, testCase.kind, a, b, note))
            print("\(testCase.id) [\(testCase.kind)] \(note)")
            print("   A: \(a)")
            print("   B: \(b)")
        }

        print("\n--- ollama residency after enhancement pass ---")
        let residency = OllamaResidencyInspector()
        print("model still resident: \(await residency.isModelResident(enhancerModel))")

        print("\n--- H3 generation pass ---")
        guard let runtime = devManagedRuntimeExecutable else {
            print("BLOCKED: the Dev managed mlx-serve runtime is not installed.")
            return 2
        }
        let (serverOK, serverDetail) = await ensureServer(
            modelDirectory: modelDirectory, runtime: runtime)
        print("server: \(serverDetail)")
        guard serverOK else {
            print("BLOCKED: managed server did not reach Ready.")
            await stopOwnedServerIfAny()
            return 2
        }
        for pair in pairs {
            for (variant, prompt) in [("A", pair.a), ("B", pair.b)] {
                let label = "\(pair.id)-\(variant)-seed\(seed)"
                let outcome = await generate(
                    label: label, prompt: prompt, sourceImagePath: sourceImagePath,
                    numFrames: 90, seed: seed, steps: 16, audioEnabled: false,
                    modelDirectory: modelDirectory, endpoint: endpoint,
                    outputDirectory: outputDir)
                outcomes.append(outcome)
                if !outcome.ok {
                    print("  \(label) failed; continuing with remaining cases.")
                }
            }
            // Identical A/B prompts carry no information; say so rather than
            // silently reporting a tie.
            if pair.a == pair.b {
                print("  NOTE: \(pair.id) A and B prompts are identical — no signal from this pair.")
            }
        }

        summarize(outcomes, title: "PROMPT A/B")
        await stopOwnedServerIfAny()
        print("videos: \(outputDir.path)")
        print("finished: \(ISO8601DateFormatter().string(from: Date()))")
        return 0
    }

    private static func summarize(_ outcomes: [Outcome], title: String) {
        print("")
        print("══════════════════════════════════════════════")
        print(title)
        print("label | ok | elapsed | frames | peakGB")
        for outcome in outcomes {
            print(String(format: "  %@ | %@ | %.1fs | %d | %.1f",
                         outcome.label, outcome.ok ? "ok" : "FAIL",
                         outcome.elapsedSeconds, outcome.frames, outcome.peakMemoryGB))
            if !outcome.ok { print("      detail: \(outcome.detail)") }
        }
        let ok = outcomes.filter(\.ok).count
        print("completed: \(ok)/\(outcomes.count)")
    }
}
