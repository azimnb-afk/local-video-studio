import Foundation
@testable import LTXVideoGeneratorCore

/// Storage-recovery + final real A/B acceptance harness for Auto Movie V2.
///
/// Drives shots through the REAL production path used by Auto Movie itself:
/// AutoMovieRunCoordinator.advance -> GenerationService.addBatch ->
/// ModelRegistry -> AdapterRegistry -> renderer, then records completion back
/// via TakeGenerationCoordinator.recordCompletion(result:) exactly as the app
/// does — GenerationService itself writes completion to FilmProjectStore
/// .shared (hardcoded), never to an isolated store, so this manual step is
/// required for an isolated store to ever see a finished take (see the
/// existing --probe-strict-continuity-acceptance probe below, which
/// established this pattern first).
///
/// Isolated store/history/output directories only — never touches Personal
/// or Dev app data.
enum V3AcceptanceHarness {

    struct Environment {
        let store: FilmProjectStore
        let historyManager: HistoryManager
        let generationService: GenerationService
        let coordinator: AutoMovieRunCoordinator
        let tmpDir: URL
        let originalOutputDir: String?
    }

    @MainActor
    static func makeEnvironment(label: String) -> Environment {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v3-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let originalOutputDir = UserDefaults.standard.string(forKey: "outputDirectory")
        let isolatedVideosDir = tmpDir.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedVideosDir, withIntermediateDirectories: true)
        UserDefaults.standard.set(isolatedVideosDir.path, forKey: "outputDirectory")

        let store = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("Projects"))
        let historyManager = HistoryManager(rootDirectory: tmpDir.appendingPathComponent("History"))
        let generationService = GenerationService(historyManager: historyManager)
        let coordinator = AutoMovieRunCoordinator(store: store)
        return Environment(
            store: store, historyManager: historyManager, generationService: generationService,
            coordinator: coordinator, tmpDir: tmpDir, originalOutputDir: originalOutputDir)
    }

    static func restoreOutputDir(_ env: Environment) {
        if let dir = env.originalOutputDir {
            UserDefaults.standard.set(dir, forKey: "outputDirectory")
        } else {
            UserDefaults.standard.removeObject(forKey: "outputDirectory")
        }
    }

    /// Drives ONE shot to completion via the real Auto Movie enqueue path,
    /// blocks until GenerationService drains, then records completion into
    /// the isolated store and returns the archived take's output path.
    @MainActor
    static func generateNextShot(
        env: Environment, projectID: UUID, label: String, timeoutSeconds: Double = 1800
    ) async -> (videoPath: String?, seconds: Double) {
        var pendingRequests: [GenerationRequest] = []
        let step = env.coordinator.advance(projectID: projectID) { pendingRequests = $0 }
        guard case .enqueued = step, let request = pendingRequests.first else {
            print("\(label): FAILED to enqueue — advance() returned \(step)")
            return (nil, 0)
        }
        let start = Date()
        env.generationService.addBatch([request])
        while Date().timeIntervalSince(start) < timeoutSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !env.generationService.isProcessing && env.generationService.queue.isEmpty { break }
        }
        let elapsed = Date().timeIntervalSince(start)
        guard let result = env.historyManager.results.first(where: { $0.requestId == request.id }) else {
            print("\(label): FAILED after \(String(format: "%.1f", elapsed))s — no history result " +
                  "(error=\(String(describing: env.generationService.error)))")
            return (nil, elapsed)
        }
        TakeGenerationCoordinator(store: env.store).recordCompletion(result: result)
        guard let project = env.store.project(id: projectID),
              let shot = project.shots.first(where: { $0.takes.contains { $0.id == result.takeID } }),
              let take = shot.takes.first(where: { $0.id == result.takeID }),
              take.status == .completed else {
            print("\(label): FAILED after \(String(format: "%.1f", elapsed))s — completion not recorded as .completed")
            return (nil, elapsed)
        }
        print("\(label): OK in \(String(format: "%.1f", elapsed))s -> \(take.outputPath ?? "?") " +
              "(archived: FilmProjectStore take status=.completed)")
        return (take.outputPath, elapsed)
    }

    /// Reconstructs the pre-V2 ("legacy") materialization behavior from a
    /// Director draft, WITHOUT touching any working-tree source file: the old
    /// 6s duration clamp (repairSemantics before this session's widen to
    /// 10s), no purpose/endState (the old schema never had them), no
    /// purpose-based camera nudging, and even-division duration allocation
    /// (AutoMovieDurationPlanner.normalize before this session's weighting).
    /// Reproduced here as a data transformation over a real Director draft,
    /// reading the exact old logic from `git show
    /// ff88dc3:.../StoryboardDirector.swift` — never by reverting real files.
    static func makeLegacyProject(
        draft: StoryboardDirector.StoryboardDraft,
        modelID: String,
        targetDurationSeconds: Double,
        fps: Int = 24
    ) -> FilmProject {
        var project = FilmProject(title: "Legacy A/B")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        project.settings = ProjectSettings(
            modelID: modelID, textEncoderID: "gemma3_12b_4bit",
            width: 768, height: 512, fps: fps,
            targetDurationSeconds: targetDurationSeconds)
        project.storyBible = StoryBible(
            logline: draft.logline, synopsis: draft.synopsis ?? "",
            setting: draft.setting ?? "", tone: draft.tone ?? "")

        var shots: [Shot] = []
        var state = draft.initialState ?? ContinuitySnapshot()
        for (index, shotDraft) in draft.shots.enumerated() {
            var shot = Shot(index: index, title: shotDraft.title, summary: shotDraft.summary)
            shot.durationSeconds = min(6, max(1, shotDraft.durationSeconds ?? 5))
            shot.continuityMode = index == 0
                ? .cut
                : (ShotContinuityMode(rawValue: (shotDraft.continuity ?? "").lowercased()) ?? .auto)
            shot.camera = CameraPlan(
                shotScale: shotDraft.shotScale ?? "medium",
                angle: shotDraft.angle ?? "eye-level",
                movement: shotDraft.movement ?? "static"
            )
            shot.continuityBefore = state
            let plan = OneShotPlan(
                camera: "\(shot.camera.shotScale) shot, \(shot.camera.angle) angle, \(shot.camera.movement) camera",
                action: shot.summary,
                motion: "natural, continuous motion",
                lighting: shotDraft.lighting ?? state.lighting,
                dialogue: shotDraft.dialogue ?? [],
                audioCues: shotDraft.audioCues ?? [],
                durationIntentSeconds: shot.durationSeconds
            )
            let compiled = PromptCompiler.compile(
                plan: plan, options: .init(perShotAudioPolicy: .naturalProductionSoundNoMusic))
            let context = ContinuityEngine.promptContext(for: state, bible: project.characterBible)
            shot.baseCompiledPrompt = context.isEmpty ? compiled : context + " " + compiled
            shot.compiledPrompt = shot.baseCompiledPrompt ?? compiled
            shots.append(shot)
            if let next = try? ContinuityEngine.apply(changes: shotDraft.explicitChanges ?? [], to: state) {
                state = next
            }
        }

        let frameStride = 8
        let minimumFrameCount = 25, maximumFrameCount = 241
        let targetUnits = max(
            (minimumFrameCount - 1) / frameStride,
            Int((targetDurationSeconds * Double(fps) / Double(frameStride)).rounded()))
        if !shots.isEmpty {
            let baseUnits = targetUnits / shots.count
            let remainder = targetUnits % shots.count
            for index in shots.indices {
                let units = baseUnits + (index < remainder ? 1 : 0)
                let frameCount = min(maximumFrameCount, max(minimumFrameCount, units * frameStride + 1))
                shots[index].durationSeconds = Double(frameCount - 1) / Double(fps)
            }
        }
        project.shots = shots
        return project
    }

    static func summarize(_ project: FilmProject, label: String) -> String {
        var lines = ["\(label): \(project.shots.count) shots"]
        var total = 0.0
        var cuts = 0, continues = 0
        for (i, s) in project.shots.enumerated() {
            total += s.durationSeconds
            if s.continuityMode == .cut { cuts += 1 } else if s.continuityMode == .continueFromPrevious { continues += 1 }
            lines.append("  shot \(i + 1): \(String(format: "%.1f", s.durationSeconds))s  purpose=\(s.shotPurpose?.shortLabel ?? "-")  continuity=\(s.continuityMode?.rawValue ?? "-")")
        }
        lines.append("  TOTAL=\(String(format: "%.1f", total))s  AVG=\(String(format: "%.1f", total / Double(max(1, project.shots.count))))s  CUTS=\(cuts)  CONTINUES=\(continues)  HANDOFFS=\(max(0, project.shots.count - 1))")
        return lines.joined(separator: "\n")
    }
}
