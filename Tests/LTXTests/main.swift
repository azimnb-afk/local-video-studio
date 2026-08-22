import Foundation
@testable import LTXVideoGeneratorCore

// The SPM executable has no bundle ID and would otherwise resolve the
// Personal profile. Isolate every CLI acceptance/unit-test singleton that
// consults AppStorageDirectory (quality history, Director diagnostics, etc.).
let ltxTestsStorageRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent(
        "LTXTests-AppStorage-\(ProcessInfo.processInfo.processIdentifier)",
        isDirectory: true)
setenv(AppStorageDirectory.testRootEnvironmentKey, ltxTestsStorageRoot.path, 1)

// Shipping-equivalent Personal first-run acceptance. Discovers the runtime
// inside a built Personal app, installs it into an isolated Personal-shaped
// Application Support tree, starts an app-owned server on 11237, and performs
// one short real I2V without using the pre-existing external 11235 server:
//   swift run LTXTests --h3-packaged-personal-acceptance <app> <model-dir> <source-image> [endpoint]
if CommandLine.arguments.count >= 5,
   CommandLine.arguments[1] == "--h3-packaged-personal-acceptance" {
    let endpoint = CommandLine.arguments.count >= 6
        ? CommandLine.arguments[5]
        : MiniMaxH3Configuration.personalManagedEndpoint
    Task { @MainActor in
        exit(await MiniMaxH3AcceptanceHarness.runPackagedPersonalAcceptance(
            appPath: CommandLine.arguments[2],
            modelDirectory: CommandLine.arguments[3],
            sourceImagePath: CommandLine.arguments[4],
            endpoint: endpoint))
    }
    RunLoop.main.run()
}

// Fresh Dev-profile managed-runtime acceptance. This intentionally requires
// explicit existing local paths and performs no download:
//   swift run LTXTests --h3-managed-acceptance <runtime-bundle> <model-dir> <source-image> [endpoint]
if CommandLine.arguments.count >= 5,
   CommandLine.arguments[1] == "--h3-managed-acceptance" {
    let endpoint = CommandLine.arguments.count >= 6
        ? CommandLine.arguments[5]
        : "http://127.0.0.1:11236"
    Task { @MainActor in
        exit(await MiniMaxH3AcceptanceHarness.runManagedRuntimeAcceptance(
            sourceBundlePath: CommandLine.arguments[2],
            modelDirectory: CommandLine.arguments[3],
            sourceImagePath: CommandLine.arguments[4],
            endpoint: endpoint))
    }
    RunLoop.main.run()
}

// Starts the installed managed runtime once, performs the controlled chain=4
// continuation and corrected Opening Reference Auto Movie, then stops only
// that app-owned process:
//   swift run LTXTests --h3-managed-stabilization-suite <model-dir> <take-a-last-frame> <opening-image>
if CommandLine.arguments.count == 5,
   CommandLine.arguments[1] == "--h3-managed-stabilization-suite" {
    Task { @MainActor in
        exit(await MiniMaxH3AcceptanceHarness.runManagedStabilizationSuite(
            modelDirectory: CommandLine.arguments[2],
            continuationSourcePath: CommandLine.arguments[3],
            openingSourcePath: CommandLine.arguments[4]))
    }
    RunLoop.main.run()
}

// Fixed source/seed quality root-cause matrix. Six short real generations:
// P1/P2/P3 for T2V and I2V, all 512x288, 56 frames, 8 steps, seed 42.
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--h3-quality-matrix" {
    Task { @MainActor in
        exit(await MiniMaxH3AcceptanceHarness.runQualityMatrix(
            sourceImagePath: CommandLine.arguments[2]))
    }
    RunLoop.main.run()
}

// One exact direct-HTTP parity request using the complete prompt emitted by
// the production H3 compiler for Matrix P3-I2V.
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--h3-standalone-parity" {
    Task { @MainActor in
        exit(await MiniMaxH3AcceptanceHarness.runStandaloneParity(
            sourceImagePath: CommandLine.arguments[2]))
    }
    RunLoop.main.run()
}

// Real MiniMax H3 acceptance through the production service/registry/adapter
// path. All evidence is isolated under /tmp; no Personal or Dev app data.
//   swift run LTXTests --h3-acceptance normal
//   swift run LTXTests --h3-acceptance i2v /absolute/source.png
//   swift run LTXTests --h3-acceptance oneshot
//   swift run LTXTests --h3-acceptance automovie /absolute/source.png
//   swift run LTXTests --h3-acceptance long /absolute/source.png
if CommandLine.arguments.count >= 3,
   CommandLine.arguments[1] == "--h3-acceptance" {
    let mode = CommandLine.arguments[2]
    let source = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : nil
    Task { @MainActor in
        exit(await MiniMaxH3AcceptanceHarness.run(mode: mode, sourceImagePath: source))
    }
    RunLoop.main.run()
}

// CLI probe for real local Director model
//   swift run LTXTests --probe-director-model <model-name>
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--probe-director-model" {
    let model = CommandLine.arguments[2]
    let prober = OllamaLocalDirectorProber()
    let compatibility = LocalDirectorCompatibilityService(prober: prober)
    let sem = DispatchSemaphore(value: 0)
    Task {
        print("=== Real Local Runtime Probe for \(model) ===")
        let result = await compatibility.negotiate(model: model)
        switch result {
        case .ready(let proto):
            print("Probe Verdict: READY via \(proto.displayName) (\(proto.rawValue))")
        case .incompatible(let summary):
            print("Probe Verdict: INCOMPATIBLE (\(summary))")
        case .unavailable(let summary):
            print("Probe Verdict: UNAVAILABLE (\(summary))")
        }
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.1) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    }
    exit(0)
}

// CLI probe for real generation cancellation acceptance
//   swift run LTXTests --probe-cancellation-acceptance
if CommandLine.arguments.count >= 2,
   CommandLine.arguments[1] == "--probe-cancellation-acceptance" {
    Task { @MainActor in
        print("=== STARTING REAL GENERATION CANCELLATION RUNTIME PROBE ===")
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancellation-acceptance-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Set temporary isolated output directory to avoid touching Personal App Support
        let originalOutputDir = UserDefaults.standard.string(forKey: "outputDirectory")
        let isolatedVideosDir = tmpDir.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedVideosDir, withIntermediateDirectories: true)
        UserDefaults.standard.set(isolatedVideosDir.path, forKey: "outputDirectory")
        defer {
            if let originalOutputDir {
                UserDefaults.standard.set(originalOutputDir, forKey: "outputDirectory")
            } else {
                UserDefaults.standard.removeObject(forKey: "outputDirectory")
            }
        }

        let queueURL = tmpDir.appendingPathComponent("queue.json")

        let historyManager = HistoryManager(rootDirectory: tmpDir)
        let queueStore = ProductionQueueStore(fileURL: queueURL)
        let coordinator = ProductionQueueCoordinator(store: queueStore)
        let queueService = ProductionQueueService(coordinator: coordinator)
        let generationService = GenerationService(historyManager: historyManager)
        queueService.attach(generationService: generationService)

        print("\n--- CASE A: Real Single Generation Cancel ---")

        var paramsA = GenerationParameters.default
        paramsA.width = 512
        paramsA.height = 320
        paramsA.numFrames = 9
        paramsA.numInferenceSteps = 2
        paramsA.fps = 24

        let reqA = GenerationRequest(
            prompt: "a majestic golden eagle soaring above misty mountains at sunrise",
            disableAudio: true,
            modelId: LTXModelCatalog.defaultModelID,
            textEncoderId: "gemma3_12b_4bit",
            parameters: paramsA,
            qualityMode: GenerationPreset.quickPreview.qualityMode.rawValue,
            preset: GenerationPreset.quickPreview.rawValue,
            generationSource: "generate"
        )

        guard let jobA = try? DirectGenerationSubmission.makeJob(request: reqA, title: "Case A Probe") else {
            print("FAIL: Could not create Job A")
            exit(1)
        }

        print("Submitting Job A to queue...")
        queueService.enqueue(jobA)

        print("Waiting for Job A backend subprocess to start...")
        var started = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if generationService.isProcessing || !generationService.statusMessage.isEmpty {
                started = true
                print("Job A active: status = '\(generationService.statusMessage)', isProcessing = \(generationService.isProcessing)")
                break
            }
        }

        guard started else {
            print("FAIL: Job A did not start in time")
            exit(1)
        }

        // Let it run for 2 seconds into actual inference
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        print("Triggering Cancel on Job A via queueService.cancel(jobID:)...")
        let cancelStart = Date()
        queueService.cancel(jobID: jobA.id)

        // Wait for generationService to settle
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !generationService.isProcessing {
                break
            }
        }
        let cancelDuration = Date().timeIntervalSince(cancelStart)
        print("Cancellation completed in \(String(format: "%.2f", cancelDuration))s")
        queueStore.flush()

        let loadedJobsA = queueStore.load()
        let finalJobA = loadedJobsA.first(where: { $0.id == jobA.id })
        print("Job A final state in queueStore: \(finalJobA?.state.displayName ?? "nil")")
        print("GenerationService error: \(String(describing: generationService.error))")
        print("GenerationService statusMessage: '\(generationService.statusMessage)'")

        guard finalJobA?.state == .cancelled else {
            print("FAIL: Job A state is not .cancelled (was \(String(describing: finalJobA?.state)))")
            exit(2)
        }
        guard generationService.error == nil else {
            print("FAIL: GenerationService recorded an error instead of cancellation")
            exit(3)
        }

        print("CASE A PASS: Job A was cleanly cancelled without errors.")

        print("\n--- CASE B: Cancel Then Next Real Job ---")

        let reqB1 = GenerationRequest(
            prompt: "a fast sports car racing on a neon city street at night",
            disableAudio: true,
            modelId: LTXModelCatalog.defaultModelID,
            textEncoderId: "gemma3_12b_4bit",
            parameters: paramsA,
            qualityMode: GenerationPreset.quickPreview.qualityMode.rawValue,
            preset: GenerationPreset.quickPreview.rawValue,
            generationSource: "generate"
        )
        let reqB2 = GenerationRequest(
            prompt: "a cozy cabin with a smoking chimney in a snowy pine forest",
            disableAudio: true,
            modelId: LTXModelCatalog.defaultModelID,
            textEncoderId: "gemma3_12b_4bit",
            parameters: paramsA,
            qualityMode: GenerationPreset.quickPreview.qualityMode.rawValue,
            preset: GenerationPreset.quickPreview.rawValue,
            generationSource: "generate"
        )

        guard let jobB1 = try? DirectGenerationSubmission.makeJob(request: reqB1, title: "Job B1 (To Cancel)"),
              let jobB2 = try? DirectGenerationSubmission.makeJob(request: reqB2, title: "Job B2 (To Complete)") else {
            print("FAIL: Could not create Job B1 / B2")
            exit(4)
        }

        print("Enqueuing Job B1 and Job B2...")
        queueService.enqueue(jobB1)
        queueService.enqueue(jobB2)

        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if generationService.isProcessing {
                print("Job B1 running...")
                break
            }
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("Cancelling Job B1 while Job B2 is waiting in queue...")
        queueService.cancel(jobID: jobB1.id)

        print("Waiting for Job B2 to start and complete...")
        var b2Completed = false
        for i in 0..<300 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            queueStore.flush()
            let jobs = queueStore.load()
            let b2State = jobs.first(where: { $0.id == jobB2.id })?.state
            if i % 10 == 0 {
                print("[\(i)s] Job B2 state: \(b2State?.displayName ?? "nil"), status: '\(generationService.statusMessage)'")
            }
            if b2State == .completed {
                b2Completed = true
                print("Job B2 completed at \(i)s!")
                break
            }
            if b2State == .failed {
                print("FAIL: Job B2 failed!")
                exit(5)
            }
        }

        guard b2Completed else {
            print("FAIL: Job B2 did not complete in time")
            exit(6)
        }

        let historyResults = historyManager.results
        print("History results count: \(historyResults.count)")
        let b2History = historyResults.first(where: { $0.prompt.contains("cozy cabin") })
        print("Job B2 video output path: \(b2History?.videoPath ?? "nil")")
        if let path = b2History?.videoPath, FileManager.default.fileExists(atPath: path) {
            print("Job B2 video file exists on disk and is readable.")
        }

        print("\n=== ALL REAL RUNTIME ACCEPTANCE TESTS PASSED SUCCESSFULLY! ===")
        exit(0)
    }
    RunLoop.main.run()
}

// CLI probe for the preview.3 strict Auto Movie continuity policy, against a
// real backend. Fully isolated: its own FilmProjectStore and HistoryManager
// under a tmp directory, so it never reads or writes the real Personal/Dev
// project store. GenerationService's own take-completion recording is
// hardcoded to FilmProjectStore.shared, so it is a guaranteed no-op here (the
// probe's project ID does not exist there); completion is instead recorded by
// this probe directly against the isolated store, using the same production
// TakeGenerationCoordinator.recordCompletion(result:) the app itself uses.
//
// Shot 4 is given an explicit scene AND camera change (interior -> exterior
// wide) that the generic Cut/Continue engine would resolve to a cut, to prove
// the new Auto Movie policy overrides it at real generation time.
//
//   swift run LTXTests --probe-strict-continuity-acceptance
if CommandLine.arguments.count >= 2,
   CommandLine.arguments[1] == "--probe-strict-continuity-acceptance" {
    Task { @MainActor in
        print("=== STARTING STRICT AUTO MOVIE CONTINUITY POLICY REAL RUNTIME PROBE ===")
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("strict-continuity-acceptance-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        print("Isolated working directory: \(tmpDir.path)")

        let originalOutputDir = UserDefaults.standard.string(forKey: "outputDirectory")
        let isolatedVideosDir = tmpDir.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedVideosDir, withIntermediateDirectories: true)
        UserDefaults.standard.set(isolatedVideosDir.path, forKey: "outputDirectory")

        let historyManager = HistoryManager(rootDirectory: tmpDir)
        let store = FilmProjectStore(
            projectsDirectory: tmpDir.appendingPathComponent("Projects", isDirectory: true))
        let generationService = GenerationService(historyManager: historyManager)

        var project = FilmProject(title: "Strict Continuity Acceptance")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        project.settings.modelID = LTXModelCatalog.defaultModelID
        // Acceptance must remain offline and reuse the encoder already proven
        // by this repository's real E2E runs. The catalog default is the much
        // larger BF16 encoder and can trigger an unintended model download.
        project.settings.textEncoderID = "gemma3_12b_4bit"
        // .advanced skips Auto Quality resolution entirely, so the literal
        // numFrames/numInferenceSteps below are honored instead of being
        // replaced by a hardware-fitted profile (Auto Quality can pick a much
        // heavier profile than requested, e.g. it resolved 73 frames / 25
        // steps from a 9-frame / 4-step request on the first probe attempt).
        project.settings.qualityMode = QualityMode.advanced.rawValue
        project.settings.preset = GenerationPreset.custom.rawValue
        project.settings.width = 512
        project.settings.height = 320
        project.settings.fps = 24
        project.settings.numFrames = 9
        project.settings.numInferenceSteps = 4
        project.settings.audioEnabled = false

        var shot1 = Shot(index: 0, title: "Reading Room",
                         summary: "A woman sits reading in a quiet library.")
        shot1.compiledPrompt = "A woman sits reading in a quiet sunlit library reading room."
        shot1.durationSeconds = 1
        shot1.continuityMode = .cut

        var shot2 = Shot(index: 1, title: "Rises", summary: "She rises and walks toward the door.")
        shot2.compiledPrompt = "She rises from her chair and walks toward the tall wooden door."
        shot2.durationSeconds = 1
        shot2.continuityMode = .auto

        var shot3 = Shot(index: 2, title: "Opens Door", summary: "She opens the door and steps through.")
        shot3.compiledPrompt = "She opens the tall wooden door and steps through into the hallway."
        shot3.durationSeconds = 1
        shot3.continuityMode = .auto
        var beforeState = ContinuitySnapshot(); beforeState.location = "library hallway"
        shot3.continuityBefore = beforeState

        // A deliberate, explicit scene AND camera change — exactly the kind of
        // cut the OLD Director-driven heuristic would make. The new Auto Movie
        // policy must still continue from Shot 3's actual final frame.
        var shot4 = Shot(index: 3, title: "City Street",
                         summary: "Establishing wide shot of a busy city street at night.")
        shot4.compiledPrompt =
            "Establishing wide shot of a busy city street at night, neon signs reflecting on wet pavement."
        shot4.durationSeconds = 1
        shot4.continuityMode = .auto
        shot4.camera.shotScale = "wide"
        shot4.explicitChanges = ["location=city street at night"]
        var afterState = ContinuitySnapshot(); afterState.location = "city street"
        shot4.continuityBefore = afterState

        project.shots = [shot1, shot2, shot3, shot4]
        store.save(project)
        project = store.project(id: project.id)!

        let coordinator = AutoMovieRunCoordinator(store: store)
        let genericShot4Mode = coordinator.resolvedContinuityMode(forShotAt: 3, in: project)
        print("Sanity check — generic engine resolves Shot 4 to: \(genericShot4Mode) " +
              "(expected .cut; the new Auto Movie policy must override this)")

        struct ShotEvidence {
            let shotIndex: Int
            let request: GenerationRequest
            let elapsedSeconds: TimeInterval
        }
        var evidence: [ShotEvidence] = []

        for shotIndex in 0..<4 {
            var pendingRequests: [GenerationRequest] = []
            let step = coordinator.advance(projectID: project.id) { pendingRequests = $0 }
            guard case .enqueued = step, let request = pendingRequests.first else {
                print("FAIL: expected Shot \(shotIndex + 1) to enqueue, got \(step)")
                exit(1)
            }
            print("\n--- Shot \(shotIndex + 1): submitting real generation ---")
            print("sourceImagePath=\(request.sourceImagePath ?? "nil") imageStrength=\(request.parameters.imageStrength)")

            let submitTime = Date()
            generationService.addBatch([request])

            var finished = false
            // Generous ceiling: the first shot also pays for one-time model
            // loading, on top of real backend inference.
            for i in 0..<1800 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !generationService.isProcessing && generationService.queue.isEmpty {
                    finished = true
                    break
                }
                if i % 20 == 0 {
                    print("[\(Int(Date().timeIntervalSince(submitTime)))s] statusMessage='\(generationService.statusMessage)'")
                }
            }
            let elapsed = Date().timeIntervalSince(submitTime)
            guard finished else {
                print("FAIL: Shot \(shotIndex + 1) did not finish within timeout (900s)")
                exit(2)
            }
            print("Shot \(shotIndex + 1) backend finished in \(String(format: "%.1f", elapsed))s. " +
                  "statusMessage='\(generationService.statusMessage)' error=\(String(describing: generationService.error))")

            guard let result = historyManager.results.first(where: { $0.requestId == request.id }) else {
                print("FAIL: Shot \(shotIndex + 1) produced no history result " +
                      "(likely failed) — error: \(String(describing: generationService.error))")
                exit(3)
            }
            TakeGenerationCoordinator(store: store).recordCompletion(result: result)
            evidence.append(ShotEvidence(shotIndex: shotIndex, request: request, elapsedSeconds: elapsed))
        }

        let final = store.project(id: project.id)!
        print("\n=== RESULTS ===")
        for item in evidence {
            let shot = final.shots[item.shotIndex]
            let take = shot.takes.first(where: { $0.status == .completed })
            print("Shot \(item.shotIndex + 1): sourceImagePath=\(item.request.sourceImagePath ?? "nil") " +
                  "isImageToVideo=\(item.request.isImageToVideo) " +
                  "continuitySourceTakeID=\(shot.continuitySourceTakeID?.uuidString ?? "nil") " +
                  "imageStrength=\(item.request.parameters.imageStrength) " +
                  "outputPath=\(take?.outputPath ?? "nil") " +
                  "elapsed=\(String(format: "%.1f", item.elapsedSeconds))s")
        }

        let shot1TakeID = final.shots[0].takes.first(where: { $0.status == .completed })?.id
        let shot2TakeID = final.shots[1].takes.first(where: { $0.status == .completed })?.id
        let shot3TakeID = final.shots[2].takes.first(where: { $0.status == .completed })?.id

        guard evidence[0].request.sourceImagePath == nil else {
            print("\nFAIL: Shot 1 unexpectedly inherited a source image"); exit(4)
        }
        guard evidence[1].request.sourceImagePath != nil,
              final.shots[1].continuitySourceTakeID == shot1TakeID else {
            print("\nFAIL: Shot 2 did not continue from Shot 1's actual final frame"); exit(4)
        }
        guard evidence[2].request.sourceImagePath != nil,
              final.shots[2].continuitySourceTakeID == shot2TakeID else {
            print("\nFAIL: Shot 3 did not continue from Shot 2's actual final frame"); exit(4)
        }
        guard evidence[3].request.sourceImagePath != nil,
              final.shots[3].continuitySourceTakeID == shot3TakeID else {
            print("\nFAIL: Shot 4 did not continue from Shot 3's actual final frame " +
                  "despite the explicit scene/camera change")
            exit(4)
        }
        print("\nPASS: Shot 4 continued from Shot 3's actual final frame despite the " +
              "explicit scene/camera change. All four shots chained correctly.")

        if let originalOutputDir {
            UserDefaults.standard.set(originalOutputDir, forKey: "outputDirectory")
        } else {
            UserDefaults.standard.removeObject(forKey: "outputDirectory")
        }

        print("\nEvidence preserved at: \(tmpDir.path)")
        print("=== STRICT AUTO MOVIE CONTINUITY POLICY PROBE PASSED ===")
        exit(0)
    }
    RunLoop.main.run()
}

// Creates a deterministic production-acceptance movie from an existing,
// already-rendered opening Shot and appends it to the real Production Queue.
// The shipping app still owns every subsequent step: Shot 2 render, continuity
// extraction, local-Vision assessment, refresh policy/resolver, Shots 3/4 and
// Final Assembly. No production-only force switch is introduced.
//
//   swift run LTXTests --prepare-idrefresh-acceptance <source-project-uuid>
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--prepare-idrefresh-acceptance",
   let sourceID = UUID(uuidString: CommandLine.arguments[2]) {
    let store = FilmProjectStore.shared
    guard let source = store.project(id: sourceID), source.shots.count >= 4,
          let sourceOpening = source.openingReferenceImage,
          let sourceOpeningURL = store.managedProjectAssetURL(
              projectID: sourceID, relativePath: sourceOpening.projectRelativePath),
          source.shots[0].continuitySourceTake?.status == .completed else {
        fputs("Source project is not a usable four-shot Auto Movie fixture.\n", stderr)
        exit(2)
    }

    let unfinished = ProductionQueueStore.shared.load().filter { !$0.state.isTerminal }
    guard unfinished.isEmpty else {
        fputs("Production Queue still has unfinished work; wait before preparing acceptance.\n", stderr)
        exit(3)
    }

    let projectID = UUID()
    var project = source
    project.id = projectID
    project.title = "IDREFRESH ACCEPT — forced true positive"
    project.createdAt = Date()
    project.updatedAt = project.createdAt
    project.lastAssemblySignature = nil
    project.assembledMoviePath = nil
    project.assembledAt = nil
    project.jobs = []
    project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
    project.continuityChainEnabled = true

    do {
        let imported = try store.importOpeningReferenceImage(
            from: sourceOpeningURL, projectID: projectID)
        project.openingReferenceImage = imported
        if project.openingReferenceAppearance != nil {
            project.openingReferenceAppearance?.sourceRelativePath = imported.projectRelativePath
        }
    } catch {
        fputs("Could not copy Opening Reference: \(error)\n", stderr)
        exit(4)
    }

    let characterID = project.characterBible.characters.first?.id ?? UUID()
    var state = ContinuitySnapshot()
    state.location = "Stone Courtyard"
    state.timeOfDay = "Late Afternoon"
    state.weather = "Overcast"
    state.lighting = "Soft, diffuse natural light"
    state.characterOutfit = [
        "Character1": "white blouse with navy vest and bow tie, dark skirt, cream cape",
    ]

    // Shot 1 is existing production evidence. Give it fresh model IDs while
    // retaining the real completed output file as this new movie's selected
    // continuity source.
    var opening = source.shots[0]
    opening.id = UUID()
    opening.index = 0
    opening.characterIDs = [characterID]
    opening.continuityBefore = state
    opening.continuityMode = .cut
    opening.continuityImageRelativePath = nil
    opening.continuitySourceTakeID = nil
    opening.identityRefreshAnchorRelativePath = nil
    opening.identityRefreshAnchorOrigin = nil
    opening.identityRefreshAnchorSourceShotID = nil
    opening.identityRefreshSourceTakeID = nil
    opening.identityRefreshNote = nil
    if var take = source.shots[0].continuitySourceTake {
        take.id = UUID()
        take.shotID = opening.id
        opening.takes = [take]
        opening.selectedTakeID = take.id
    }

    func plannedShot(
        index: Int,
        title: String,
        summary: String,
        scale: String,
        movement: String,
        prompt: String
    ) -> Shot {
        var shot = Shot(
            index: index,
            title: title,
            summary: summary,
            durationSeconds: 5,
            camera: CameraPlan(
                shotScale: scale, angle: "eye-level", movement: movement),
            continuityBefore: state,
            characterIDs: [characterID],
            baseCompiledPrompt: prompt,
            compiledPrompt: prompt,
            continuityMode: .continueFromPrevious,
            plannedContinuityMode: .continueFromPrevious
        )
        shot.continuityReconciliationReason = "acceptance fixture: same courtyard and protagonist"
        return shot
    }

    let common = "The same subject and the existing visual state continue from the input frame. Location: Stone Courtyard, time: Late Afternoon, weather: Overcast, lighting: Soft, diffuse natural light."
    let shot2 = plannedShot(
        index: 1,
        title: "The Departure",
        summary: "Character1 walks steadily away from the camera and ends as a small back-facing figure with her face fully hidden.",
        scale: "medium-wide",
        movement: "slow pull-back",
        prompt: "\(common) The camera holds a medium-wide eye-level shot and slowly pulls back. Character1 walks steadily away from the camera across the courtyard. She becomes a small back-facing figure and remains facing completely away at the end, with no face visible. Audio: footsteps on stone."
    )
    let shot3 = plannedShot(
        index: 2,
        title: "The Look Back",
        summary: "Character1 looks back over her shoulder toward the camera in a close-up.",
        scale: "close-up",
        movement: "slow push-in",
        prompt: "\(common) The camera moves into a close-up at eye level. Character1 looks back over her left shoulder toward the camera, her face clearly visible, with a quiet hopeful expression. Audio: soft fabric rustle."
    )
    let shot4 = plannedShot(
        index: 3,
        title: "The Resolve",
        summary: "Character1 turns toward the library and smiles with resolve.",
        scale: "medium",
        movement: "static",
        prompt: "\(common) The camera holds a medium eye-level shot. Character1 turns toward the library doors, then smiles with quiet resolve. Audio: courtyard ambience."
    )
    project.shots = [opening, shot2, shot3, shot4]
    project.settings.modelID = "ltx23_distilled_q4"
    project.settings.textEncoderID = "gemma3_12b_4bit"
    project.settings.qualityMode = QualityMode.auto.rawValue
    project.settings.preset = GenerationPreset.standard.rawValue
    project.settings.width = 768
    project.settings.height = 512
    project.settings.fps = 24
    project.settings.numFrames = 121
    project.settings.numInferenceSteps = 25
    project.settings.audioEnabled = true
    store.save(project)

    var snapshot = ProductionJobSnapshot()
    snapshot.projectID = projectID
    snapshot.brief = "Deterministic forced-trigger acceptance; same courtyard throughout."
    snapshot.preset = project.settings.preset
    snapshot.qualityMode = project.settings.qualityMode
    snapshot.modelID = project.settings.modelID
    snapshot.textEncoderID = project.settings.textEncoderID
    snapshot.audioEnabled = project.settings.audioEnabled
    snapshot.targetDurationSeconds = project.settings.targetDurationSeconds
    snapshot.openingReferenceRelativePath = project.openingReferenceImage?.projectRelativePath

    let queueStore = ProductionQueueStore.shared
    var jobs = queueStore.load()
    let job = ProductionJob(
        kind: .autoMovie,
        title: project.title,
        snapshot: snapshot
    )
    jobs.append(job)
    queueStore.save(jobs)
    queueStore.flush()

    print("projectID=\(projectID.uuidString)")
    print("queueJobID=\(job.id.uuidString)")
    let projectFile = store.projectsDirectory
        .appendingPathComponent(projectID.uuidString + ".json").path
    let openingPath = project.openingReferenceImage?.projectRelativePath ?? ""
    print("projectFile=\(projectFile)")
    print("openingReference=\(openingPath)")
    exit(0)
}

// Creates a no-queue disposable copy for the final Replace/Clear GUI check.
// It deliberately shares no managed Opening Reference file with the evidence
// project, so exercising Clear cannot destroy acceptance data.
//
//   swift run LTXTests --prepare-idrefresh-gui <source-project-uuid>
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--prepare-idrefresh-gui",
   let sourceID = UUID(uuidString: CommandLine.arguments[2]) {
    let store = FilmProjectStore.shared
    guard let source = store.project(id: sourceID),
          let sourceOpening = source.openingReferenceImage,
          let sourceOpeningURL = store.managedProjectAssetURL(
              projectID: sourceID, relativePath: sourceOpening.projectRelativePath) else {
        fputs("Source project has no usable Opening Reference.\n", stderr)
        exit(2)
    }
    let projectID = UUID()
    var project = source
    project.id = projectID
    project.title = "IDREFRESH GUI — disposable Replace Clear"
    project.createdAt = Date()
    project.updatedAt = project.createdAt
    project.jobs = []
    project.lastAssemblySignature = nil
    project.assembledMoviePath = nil
    project.assembledAt = nil
    do {
        let imported = try store.importOpeningReferenceImage(
            from: sourceOpeningURL, projectID: projectID)
        project.openingReferenceImage = imported
        if project.openingReferenceAppearance != nil {
            project.openingReferenceAppearance?.sourceRelativePath = imported.projectRelativePath
        }
    } catch {
        fputs("Could not copy disposable Opening Reference: \(error)\n", stderr)
        exit(3)
    }
    store.save(project)
    print("projectID=\(projectID.uuidString)")
    print("title=\(project.title)")
    exit(0)
}

// Creates an isolated, no-queue GUI fixture for Selected Take continuity. It
// runs the shipping coordinators in the same order as an actual Retake:
// Take 1 selected -> Shot 2 planned, Take 2 selected -> Shot 2 planned again.
// Existing fixture videos stand in for already-completed renders; no LTX job is
// started merely to inspect the source/provenance UI.
//
//   swift run LTXTests --prepare-selected-take-gui
if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--prepare-selected-take-gui" {
    let fixtureA = TestFixtures.videoWithAudioA
    let fixtureB = TestFixtures.videoWithAudioB
    guard FileManager.default.fileExists(atPath: fixtureA),
          FileManager.default.fileExists(atPath: fixtureB) else {
        fputs("Baseline fixture videos are unavailable.\n", stderr)
        exit(2)
    }

    let store = FilmProjectStore.shared
    var project = FilmProject(title: "SELECTED TAKE CONTINUITY GUI")
    project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
    project.continuityChainEnabled = true
    var first = Shot(
        index: 0, title: "Upstream Retake",
        summary: "The subject reaches the doorway.",
        compiledPrompt: "The subject reaches the doorway.",
        continuityMode: .cut
    )
    var take1 = Take(
        shotID: first.id, modelID: "acceptance-fixture", seed: 111,
        promptSnapshot: first.compiledPrompt, settingsSnapshot: .default,
        requestedWidth: 512, requestedHeight: 320, fps: 24,
        requestedDuration: 1, status: .completed
    )
    take1.outputPath = fixtureA
    take1.generationCompletedAt = Date().addingTimeInterval(-120)
    var take2 = Take(
        shotID: first.id, modelID: "acceptance-fixture", seed: 222,
        promptSnapshot: first.compiledPrompt, settingsSnapshot: .default,
        requestedWidth: 512, requestedHeight: 320, fps: 24,
        requestedDuration: 1, status: .completed
    )
    take2.outputPath = fixtureB
    take2.generationCompletedAt = Date().addingTimeInterval(-60)
    first.takes = [take1, take2]
    first.selectedTakeID = take1.id

    let second = Shot(
        index: 1, title: "Downstream Regeneration",
        summary: "The same subject continues through the doorway.",
        compiledPrompt: "The same subject continues through the doorway.",
        continuityMode: .continueFromPrevious
    )
    project.shots = [first, second]
    project.settings.preset = GenerationPreset.quickPreview.rawValue
    project.settings.width = 512
    project.settings.height = 320
    project.settings.fps = 24
    project.settings.numFrames = 25
    project.settings.numInferenceSteps = 15
    store.save(project)

    let runCoordinator = AutoMovieRunCoordinator(store: store)
    let takeCoordinator = TakeGenerationCoordinator(store: store)
    guard case .success = runCoordinator.prepareContinuityAsset(
        projectID: project.id, shotIndex: 1
    ), let oldRequest = try? takeCoordinator.planTakes(
        projectID: project.id, shotID: second.id, count: 1, baseSeed: 333
    ).first else {
        fputs("Could not create the Take 1 downstream snapshot.\n", stderr)
        exit(3)
    }

    var saved = store.project(id: project.id)!
    let oldTakeID = oldRequest.takeID!
    let oldIndex = saved.shots[1].takes.firstIndex { $0.id == oldTakeID }!
    saved.shots[1].takes[oldIndex].status = .completed
    saved.shots[1].takes[oldIndex].outputPath = fixtureA
    saved.shots[1].takes[oldIndex].generationCompletedAt = Date().addingTimeInterval(-30)
    saved.shots[1].selectedTakeID = oldTakeID
    saved.shots[1].identityRefreshAnchorRelativePath =
        saved.shots[1].continuityImageRelativePath
    saved.shots[1].identityRefreshAnchorOrigin = .generated
    saved.shots[1].identityRefreshSourceTakeID = take1.id
    for index in saved.jobs.indices where saved.jobs[index].takeID == oldTakeID {
        saved.jobs[index].state = .completed
    }
    store.save(saved)

    do {
        try takeCoordinator.selectTake(
            projectID: project.id, shotID: first.id, takeID: take2.id)
        let newRequest = try takeCoordinator.planTakes(
            projectID: project.id, shotID: second.id, count: 1, baseSeed: 444)[0]
        saved = store.project(id: project.id)!
        let newTakeID = newRequest.takeID!
        let newIndex = saved.shots[1].takes.firstIndex { $0.id == newTakeID }!
        saved.shots[1].takes[newIndex].status = .completed
        saved.shots[1].takes[newIndex].outputPath = fixtureB
        saved.shots[1].takes[newIndex].generationCompletedAt = Date()
        for index in saved.jobs.indices where saved.jobs[index].takeID == newTakeID {
            saved.jobs[index].state = .completed
        }
        store.save(saved)

        let reopened = FilmProjectStore(projectsDirectory: store.projectsDirectory)
        let verified = reopened.project(id: project.id)!
        let historical = verified.shots[1].takes[oldIndex].generationSourceDiagnostics
        let regenerated = verified.shots[1].takes[newIndex].generationSourceDiagnostics
        guard verified.shots[0].selectedTakeID == take2.id,
              historical?.continuitySourceTakeID == take1.id,
              regenerated?.continuitySourceTakeID == take2.id,
              regenerated?.continuityTakeSelectionReason == .selectedTake,
              verified.shots[1].identityRefreshAnchorRelativePath == nil else {
            fputs("Persisted Selected Take fixture verification failed.\n", stderr)
            exit(4)
        }
        print("projectID=\(project.id.uuidString)")
        print("projectFile=\(store.projectsDirectory.appendingPathComponent(project.id.uuidString + ".json").path)")
        print("take1=\(take1.id.uuidString)")
        print("take2=\(take2.id.uuidString)")
        print("historicalShot2Take=\(oldTakeID.uuidString)")
        print("regeneratedShot2Take=\(newTakeID.uuidString)")
        print("regeneratedSource=\(newRequest.sourceImagePath ?? "")")
        exit(0)
    } catch {
        fputs("Could not create the Take 2 downstream snapshot: \(error)\n", stderr)
        exit(5)
    }
}

// Creates a no-render acceptance project for Generation Diagnostics Phase 2.
// Existing completed MP4 fixtures exercise the production Take persistence and
// media-inspection path; no model is loaded and no video is generated.
//
//   swift run LTXTests --prepare-runtime-diagnostics-gui
if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--prepare-runtime-diagnostics-gui" {
    let fixtureA = TestFixtures.videoWithAudioA
    let fixtureB = TestFixtures.videoWithAudioB
    guard FileManager.default.fileExists(atPath: fixtureA),
          FileManager.default.fileExists(atPath: fixtureB) else {
        fputs("Baseline fixture videos are unavailable.\n", stderr)
        exit(2)
    }

    let store = FilmProjectStore.shared
    let coordinator = TakeGenerationCoordinator(store: store)
    let now = Date()
    var project = FilmProject(title: "RUNTIME DIAGNOSTICS GUI ACCEPTANCE")
    project.workflowMode = "storyboard"
    project.settings.applyPreset(.custom)
    project.settings.width = 768
    project.settings.height = 1080
    project.settings.fps = 24
    project.settings.numFrames = 121
    var acceptanceParameters = GenerationParameters.default
    acceptanceParameters.width = 768
    acceptanceParameters.height = 1080
    acceptanceParameters.fps = 24
    acceptanceParameters.numFrames = 121

    func makeTake(
        shot: Shot,
        seed: Int,
        status: TakeStatus = .completed,
        source: GenerationSourceDiagnostics? = nil
    ) -> Take {
        Take(
            shotID: shot.id,
            modelID: "acceptance-fixture",
            seed: seed,
            promptSnapshot: shot.compiledPrompt,
            settingsSnapshot: acceptanceParameters,
            requestedWidth: 768,
            requestedHeight: 1080,
            fps: 24,
            requestedDuration: 121.0 / 24.0,
            status: status,
            generationSourceDiagnostics: source
        )
    }

    var legacyShot = Shot(index: 0, title: "Legacy Take")
    legacyShot.compiledPrompt = "A legacy completed take without diagnostics."
    var legacyTake = makeTake(shot: legacyShot, seed: 101)
    legacyTake.outputPath = fixtureA
    legacyTake.generationCompletedAt = now.addingTimeInterval(-80)
    legacyShot.takes = [legacyTake]

    let t2vSource = GenerationSourceDiagnostics(
        requestedContinuityMode: .cut,
        effectiveSource: .none,
        actualVideoMode: .textToVideo,
        sourceFilename: nil,
        sourceProjectRelativePath: nil,
        continuitySourceShotID: nil,
        continuitySourceTakeID: nil,
        continuityTakeSelectionReason: nil,
        refreshAnchorOrigin: nil,
        refreshAnchorSourceShotID: nil,
        refreshAnchorSourceTakeID: nil,
        imagePreparation: nil,
        recordedAt: now.addingTimeInterval(-70)
    )
    var successShot = Shot(index: 1, title: "Succeeded Runtime")
    successShot.compiledPrompt = "A fixture-backed success with runtime facts."
    let successTake = makeTake(shot: successShot, seed: 202, status: .queued, source: t2vSource)
    successShot.takes = [successTake]

    let i2vSource = GenerationSourceDiagnostics(
        requestedContinuityMode: .cut,
        effectiveSource: .explicitStartingImage,
        actualVideoMode: .imageToVideo,
        sourceFilename: "missing-starting-image.png",
        sourceProjectRelativePath: nil,
        continuitySourceShotID: nil,
        continuitySourceTakeID: nil,
        continuityTakeSelectionReason: nil,
        refreshAnchorOrigin: nil,
        refreshAnchorSourceShotID: nil,
        refreshAnchorSourceTakeID: nil,
        imagePreparation: nil,
        recordedAt: now.addingTimeInterval(-60)
    )
    var failedShot = Shot(index: 2, title: "Failed Runtime")
    failedShot.compiledPrompt = "A fixture-backed failure with a concise backend result."
    let failedTake = makeTake(shot: failedShot, seed: 303, status: .queued, source: i2vSource)
    failedShot.takes = [failedTake]

    var selectedSourceShot = Shot(index: 3, title: "Selected Source Take")
    selectedSourceShot.compiledPrompt = "The upstream selected take."
    var sourceTake1 = makeTake(shot: selectedSourceShot, seed: 401)
    sourceTake1.outputPath = fixtureA
    sourceTake1.generationCompletedAt = now.addingTimeInterval(-50)
    var sourceTake2 = makeTake(shot: selectedSourceShot, seed: 402)
    sourceTake2.outputPath = fixtureB
    sourceTake2.generationCompletedAt = now.addingTimeInterval(-40)
    var sourceTake3 = makeTake(shot: selectedSourceShot, seed: 403)
    sourceTake3.outputPath = fixtureA
    sourceTake3.generationCompletedAt = now.addingTimeInterval(-30)
    selectedSourceShot.takes = [sourceTake1, sourceTake2, sourceTake3]
    selectedSourceShot.selectedTakeID = sourceTake2.id

    let selectedSourceDiagnostics = GenerationSourceDiagnostics(
        requestedContinuityMode: .continueFromPrevious,
        effectiveSource: .inheritedLastFrame,
        actualVideoMode: .imageToVideo,
        sourceFilename: URL(fileURLWithPath: fixtureB).lastPathComponent,
        sourceProjectRelativePath: nil,
        continuitySourceShotID: selectedSourceShot.id,
        continuitySourceTakeID: sourceTake2.id,
        continuityTakeSelectionReason: .selectedTake,
        refreshAnchorOrigin: nil,
        refreshAnchorSourceShotID: nil,
        refreshAnchorSourceTakeID: nil,
        imagePreparation: nil,
        recordedAt: now.addingTimeInterval(-20)
    )
    var selectedDownstreamShot = Shot(index: 4, title: "Selected Take Continuation")
    selectedDownstreamShot.compiledPrompt = "The downstream Take must continue from the selected source Take."
    var downstreamTake = makeTake(
        shot: selectedDownstreamShot,
        seed: 404,
        source: selectedSourceDiagnostics
    )
    downstreamTake.outputPath = fixtureB
    downstreamTake.generationCompletedAt = now.addingTimeInterval(-10)
    selectedDownstreamShot.takes = [downstreamTake]

    project.shots = [legacyShot, successShot, failedShot, selectedSourceShot, selectedDownstreamShot]
    let successRequest = GenerationRequest(
        prompt: successShot.compiledPrompt,
        modelId: "acceptance-fixture",
        parameters: acceptanceParameters,
        filmProjectID: project.id,
        shotID: successShot.id,
        takeID: successTake.id
    )
    let failedRequest = GenerationRequest(
        prompt: failedShot.compiledPrompt,
        sourceImagePath: "/tmp/missing-starting-image.png",
        modelId: "acceptance-fixture",
        parameters: acceptanceParameters,
        filmProjectID: project.id,
        shotID: failedShot.id,
        takeID: failedTake.id
    )
    project.jobs = [
        GenerationJob(projectID: project.id, shotID: successShot.id, takeID: successTake.id, requestID: successRequest.id),
        GenerationJob(projectID: project.id, shotID: failedShot.id, takeID: failedTake.id, requestID: failedRequest.id),
    ]
    store.save(project)

    let successStartedAt = now.addingTimeInterval(-19)
    let successFinishedAt = now.addingTimeInterval(-7)
    coordinator.recordExecutionStarted(request: successRequest, startedAt: successStartedAt)
    var effective = successRequest.parameters
    effective.width = 704
    effective.height = 1024
    coordinator.recordCompletion(
        result: GenerationResult(
            id: UUID(), requestId: successRequest.id, prompt: successRequest.prompt,
            enhancedPrompt: nil, negativePrompt: "", voiceoverText: "",
            voiceoverSource: "mlx-audio", voiceoverVoice: "af_heart",
            modelId: successRequest.modelId, parameters: effective,
            videoPath: fixtureA, thumbnailPath: nil, audioPath: nil, musicPath: nil,
            musicGenre: nil, sourceImagePath: nil, createdAt: successStartedAt,
            completedAt: successFinishedAt, duration: 12, seed: successTake.seed,
            requestedWidth: 768, requestedHeight: 1080,
            requestedDurationSeconds: 121.0 / 24.0,
            effectiveWidth: 704, effectiveHeight: 1024,
            filmProjectID: project.id, shotID: successShot.id, takeID: successTake.id
        ),
        finalizedAt: successFinishedAt
    )

    let failureStartedAt = now.addingTimeInterval(-6)
    let failureFinishedAt = now.addingTimeInterval(-3)
    coordinator.recordExecutionStarted(request: failedRequest, startedAt: failureStartedAt)
    coordinator.recordFailure(
        request: failedRequest,
        error: LTXError.generationFailed("Exit code 15. Fixture backend failure."),
        effectiveParameters: failedRequest.parameters,
        outputPath: store.projectsDirectory
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent("missing-runtime-output.mp4").path,
        finalizedAt: failureFinishedAt
    )

    let reopened = FilmProjectStore(projectsDirectory: store.projectsDirectory)
    guard let verified = reopened.project(id: project.id),
          verified.shots[1].takes.first?.generationRuntimeDiagnostics?.status == .succeeded,
          verified.shots[2].takes.first?.generationRuntimeDiagnostics?.failureStage == .backendGeneration,
          verified.shots[4].takes.first?.generationSourceDiagnostics?.continuitySourceTakeID == sourceTake2.id,
          verified.shots[3].selectedTakeID == sourceTake2.id else {
        fputs("Runtime diagnostics acceptance fixture verification failed.\n", stderr)
        exit(3)
    }
    print("projectID=\(project.id.uuidString)")
    print("projectFile=\(store.projectsDirectory.appendingPathComponent(project.id.uuidString + ".json").path)")
    print("successTake=\(successTake.id.uuidString)")
    print("failedTake=\(failedTake.id.uuidString)")
    print("selectedSourceTake=\(sourceTake2.id.uuidString)")
    print("selectedContinuationTake=\(downstreamTake.id.uuidString)")
    exit(0)
}

// Re-runs the shipping local-Vision visibility assessor against one saved
// production frame and prints the complete Codable result. This is a read-only
// acceptance diagnostic: it uses the same model selection/provider/prompt as
// IdentityRefreshService and neither edits the project nor queues a render.
//
//   swift run LTXTests --assess-identity-source <absolute-image-path>
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--assess-identity-source" {
    let imageURL = URL(fileURLWithPath: CommandLine.arguments[2])
    guard let imageData = try? Data(contentsOf: imageURL) else {
        fputs("Could not read identity source image.\n", stderr)
        exit(2)
    }
    Task {
        let assessment = await LocalIdentitySourceAssessmentProvider().assess(
            imageData: imageData,
            sourceRelativePath: imageURL.lastPathComponent
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let encoded = try encoder.encode(assessment)
            print(String(decoding: encoded, as: UTF8.self))
            exit(assessment.isAssessed ? 0 : 3)
        } catch {
            fputs("Could not encode identity assessment: \(error)\n", stderr)
            exit(4)
        }
    }
    RunLoop.main.run()
}

// Inspection mode: run a real Director plan through the shipping capability
// policy and print the original next to the effective plan. Used to sample
// plans from several briefs without writing a second copy of the rules.
//   swift run LTXTests --capability-plan <plan.json> ["<brief>"]
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--capability-plan" {
    let path = CommandLine.arguments[2]
    let brief = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let draft = try JSONDecoder().decode(StoryboardDirector.StoryboardDraft.self, from: data)
    let planned = CapabilityAwareShotPlanner.plan(shots: draft.shots, brief: brief)
    print("brief: \(brief)")
    for (index, adjustment) in planned.adjustments.enumerated() {
        let original = draft.shots[index]
        let effective = planned.shots[index]
        print("--- shot \(index + 1) [\(original.continuity ?? "?")] \(adjustment.risk.rawValue)")
        print("    planned  : \(original.shotScale ?? "?") | \(original.summary)")
        print("    effective: \(effective.shotScale ?? "?") | \(effective.summary)")
        if !adjustment.reasons.isEmpty {
            print("    why      : \(adjustment.reasons.joined(separator: "; "))")
        }
    }
    // The effective plan is written back so a harness can render from exactly
    // what the app would generate, without reimplementing the policy.
    var effectiveDraft = draft
    effectiveDraft.shots = planned.shots
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let effectivePath = path + ".effective.json"
    try encoder.encode(effectiveDraft).write(to: URL(fileURLWithPath: effectivePath))
    print("effective plan: \(effectivePath)")
    exit(0)
}

// Auto Movie V2 storage-recovery + final real A/B acceptance probes.
// All use V3AcceptanceHarness (isolated store/history/output — never touches
// Personal/Dev app data) and the real Auto Movie enqueue path
// (AutoMovieRunCoordinator.advance -> GenerationService.addBatch).
//
//   swift run LTXTests --v3-probe
//   swift run LTXTests --v3-longshot
//   swift run LTXTests --v3-automovie legacy|new
let v3ModelID = LTXModelCatalog.defaultModelID
let v3Brief = "A young woman walks along a beach, the wind moving her hair. She stops, turns toward the camera, and gives a small smile. About 30 seconds, cinematic."
let v3OldSystemPrompt = """
You are a film production team (director, screenwriter, cinematographer,
continuity supervisor) planning a short film as a sequence of concise,
continuous shots. When the user provides a TOTAL MOVIE DURATION TARGET,
treat it as authoritative for the sum of all shots. Respond with ONLY a JSON object:
{
  "logline": "one sentence",
  "synopsis": "short paragraph",
  "setting": "where/when",
  "tone": "mood",
  "initialState": {"location":"...","timeOfDay":"...","weather":"...","lighting":"...",
                   "characterOutfit":{"CharacterID":"outfit"},"characterPosition":{},"characterCondition":{},
                   "props":[],"propOwner":{},"wetness":{},"injuries":{},"dialogueState":"","storyState":""},
  "shots": [
    {"title":"...","summary":"present-tense visible action","durationSeconds":5,
     "shotScale":"extreme-wide|wide|medium-wide|medium|medium-close-up|close-up|extreme-close-up",
     "angle":"low|eye-level|high|overhead","movement":"static|pan|tilt|dolly|track|handheld",
     "motionTempo":"slow|normal|fast","cameraTempo":"static|slow|normal|fast",
     "playbackStyle":"realTime|slowMotion|fastMotion",
     "lighting":"...","dialogue":[{"speaker":"Name","text":"line","sourceId":"D1 (optional)"}],"audioCues":["..."],
     "explicitChanges":["location=...","outfit:CharacterID=...","prop+:item"],
     "characterIDs":["exact-character-uuid"],
     "continuity":"continue|cut"}
  ]
}
Vary shot scale/angle/movement between consecutive shots. explicitChanges
uses only these directives: location=, timeOfDay=, weather=, lighting=,
outfit:CharacterID=, position:CharacterID=, condition:CharacterID=,
wet:CharacterID=, injury:CharacterID=,
prop+:item, prop-:item, propOwner:item=Name, dialogueState=, storyState=.
2 to 8 shots. Keep user-provided dialogue verbatim. If EXPLICIT_DIALOGUE_SOURCES
lists an ID for a line's exact words, set that dialogue entry's "sourceId"
to that ID instead of retyping the words, and never invent an ID it did
not list.
\(PerShotAudioPolicy.directorInstruction)
\(CharacterContinuitySafetyPolicy.directorInstruction)
Motion tempo describes how quickly the subject acts. Camera tempo describes
camera pacing independently. Playback style is realTime unless the brief
explicitly asks for slow motion, fast motion, or time-lapse. Words such as
"slowly opens the door" describe a slow real-time action, not slow-motion
playback. A continuing shot inherits the preceding shot's motion, camera,
and playback tempo unless the story explicitly changes one of them. A cut
does not by itself imply slow motion.
Set "continuity":"continue" only when the shot is a direct physical
continuation of the previous one: same location, same active characters, no
time jump, one unbroken action. Use "cut" for a location change, a time
jump, a new establishing shot, a different character, or any intentional
cinematic cut. When unsure, use "cut". The first shot is always "cut".

Every shot must advance the story to a NEW visible state. Never restate the
previous shot's action in different words: "walks toward the door", then
"keeps walking toward the door", then "continues approaching the door" is
wrong. Each summary describes what newly happens in that shot — approaching,
then arriving, then reaching for the handle, then stepping through.

Continuing shots keep the same character, clothing, place, light and props,
but they do NOT keep the same framing. Let the camera change with the beat:
an establishing view can give way to a closer one as the action tightens.
Choose one primary camera idea per shot from static, slow push-in, pull-back,
tracking, dolly, pan, tilt or handheld follow. A static camera is correct for
dialogue, a held reaction or a deliberately still composition — use it
because the beat calls for it, not as a default for every shot.

When the story moves somewhere genuinely new, such as outside to inside, use
"cut" and open the new place with its own establishing shot. Story
progression matters more than keeping an unbroken visual chain.

Do not mark every shot "cut". If a shot happens in the same place, with the
same character, at the same moment in time as the shot before it, it MUST be
"continue" — even when the framing changes completely, and even when it is a
tight insert such as a hand on a lock. Only use "cut" when the place, the
time or the active character actually changes. Marking a whole scene as cuts
makes each shot regenerate a different-looking person and set, which is
wrong. Worked example for "a woman walks to a library, opens the door and
steps inside":
  shot 1 "cut"      — wide, she crosses the courtyard (the first shot always cuts)
  shot 2 "continue" — medium, she arrives at the doors and reaches for the handle
  shot 3 "continue" — close, the handle turns and the door begins to open
  shot 4 "cut"      — interior establishing shot as she steps inside
"""

func v3OllamaGenerate(system: String, prompt: String) async throws -> String {
    let model = UserDefaults.standard.string(forKey: "directorOllamaModel") ?? "qwen3.6-35b-uncensored:q4kp"
    var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 300
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model, "system": system, "prompt": prompt,
        "stream": false, "think": false, "options": ["num_predict": 4096], "format": "json",
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw NSError(domain: "ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: "HTTP error"])
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return (json?["response"] as? String) ?? (json?["thinking"] as? String) ?? ""
}

// Quick sanity probe: confirms the official model + 4-bit text encoder
// combination produces on-topic output with NO new download (both already
// locally cached), before committing to longer real generations.
//   swift run LTXTests --v3-probe
if CommandLine.arguments.contains("--v3-probe") {
    Task { @MainActor in
        print("=== V3 PROBE: \(v3ModelID) + gemma3_12b_4bit, minimal frame count ===")
        let env = V3AcceptanceHarness.makeEnvironment(label: "probe")
        var project = FilmProject(title: "V3 Probe")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        project.settings = ProjectSettings(
            modelID: v3ModelID, textEncoderID: "gemma3_12b_4bit",
            width: 768, height: 512, fps: 24)
        var shot = Shot(index: 0, title: "Probe", summary: "A woman walks on a beach.")
        shot.compiledPrompt = "A woman walks on a beach."
        shot.durationSeconds = 1
        shot.continuityMode = .cut
        project.shots = [shot]
        env.store.save(project)
        let result = await V3AcceptanceHarness.generateNextShot(env: env, projectID: project.id, label: "PROBE")
        V3AcceptanceHarness.restoreOutputDir(env)
        print("probe result: path=\(result.videoPath ?? "nil") seconds=\(String(format: "%.1f", result.seconds))")
        print("evidence dir: \(env.tmpDir.path)")
        exit(result.videoPath != nil ? 0 : 1)
    }
    RunLoop.main.run()
}

// Long-Shot Experiment (mandatory): same character/action, A = two ~4s
// segments chained by real Continue (Last-Frame Continuity), B = one ~9s
// continuous shot. Real generation through the true Auto Movie path.
//   swift run LTXTests --v3-longshot
if CommandLine.arguments.contains("--v3-longshot") {
    Task { @MainActor in
        print("=== V3 LONG-SHOT EXPERIMENT: segmented (~4s x2) vs continuous (~9s) ===")
        let basePrompt = "A young woman in a blue jacket walks along a sandy beach at golden hour, the wind moving her hair."

        print("\n--- Variant A: two ~4s segments, real Continue handoff ---")
        let envA = V3AcceptanceHarness.makeEnvironment(label: "longshotA")
        var projectA = FilmProject(title: "Long-Shot A (segmented)")
        projectA.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        projectA.continuityChainEnabled = true
        projectA.settings = ProjectSettings(modelID: v3ModelID, textEncoderID: "gemma3_12b_4bit", width: 768, height: 512, fps: 24)
        var a1 = Shot(index: 0, title: "Walk 1", summary: basePrompt + " She walks at a relaxed, steady pace.")
        a1.compiledPrompt = a1.summary
        a1.durationSeconds = 4
        a1.continuityMode = .cut
        var a2 = Shot(index: 1, title: "Walk 2", summary: "The woman continues walking, gradually slows, and comes to a natural stop.")
        a2.compiledPrompt = a2.summary
        a2.durationSeconds = 4
        a2.continuityMode = .continueFromPrevious
        projectA.shots = [a1, a2]
        envA.store.save(projectA)
        let a1Result = await V3AcceptanceHarness.generateNextShot(env: envA, projectID: projectA.id, label: "A1 (~4s, T2V)")
        let a2Result = await V3AcceptanceHarness.generateNextShot(env: envA, projectID: projectA.id, label: "A2 (~4s, I2V continue)")
        V3AcceptanceHarness.restoreOutputDir(envA)

        print("\n--- Variant B: one ~9s continuous shot ---")
        let envB = V3AcceptanceHarness.makeEnvironment(label: "longshotB")
        var projectB = FilmProject(title: "Long-Shot B (continuous)")
        projectB.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        projectB.continuityChainEnabled = true
        projectB.settings = ProjectSettings(modelID: v3ModelID, textEncoderID: "gemma3_12b_4bit", width: 768, height: 512, fps: 24)
        let plan = OneShotPlan(
            camera: "medium wide shot", action: basePrompt + " She walks at a relaxed pace, gradually slows, and comes to a natural stop.",
            motion: "natural, continuous motion",
            endState: "standing still, facing slightly toward the camera"
        )
        var b1 = Shot(index: 0, title: "Walk (continuous)", summary: plan.action)
        b1.compiledPrompt = PromptCompiler.compile(plan: plan, options: .init(perShotAudioPolicy: .naturalProductionSoundNoMusic))
        b1.durationSeconds = 9
        b1.continuityMode = .cut
        projectB.shots = [b1]
        envB.store.save(projectB)
        let bResult = await V3AcceptanceHarness.generateNextShot(env: envB, projectID: projectB.id, label: "B (~9s, T2V)")
        V3AcceptanceHarness.restoreOutputDir(envB)

        print("\n=== TIMING SUMMARY ===")
        print("A1: \(String(format: "%.1f", a1Result.seconds))s -> \(a1Result.videoPath ?? "FAILED")")
        print("A2: \(String(format: "%.1f", a2Result.seconds))s -> \(a2Result.videoPath ?? "FAILED")")
        print("A total: \(String(format: "%.1f", a1Result.seconds + a2Result.seconds))s, 1 continuity handoff")
        print("B: \(String(format: "%.1f", bResult.seconds))s -> \(bResult.videoPath ?? "FAILED")")
        print("B total: \(String(format: "%.1f", bResult.seconds))s, 0 continuity handoffs")
        print("\nEvidence: \(envA.tmpDir.path)  |  \(envB.tmpDir.path)")
        exit(0)
    }
    RunLoop.main.run()
}

// Full Auto Movie video A/B (Phase 7): same brief, legacy materialization
// (reconstructed from the old code, see V3AcceptanceHarness.makeLegacyProject)
// vs the real current pipeline. Renders the first 2 shots of each through the
// true production path for a genuine, if partial, visual comparison.
//   swift run LTXTests --v3-automovie legacy
//   swift run LTXTests --v3-automovie new
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--v3-automovie" {
    let variant = CommandLine.arguments[2]
    Task { @MainActor in
        print("=== V3 FULL AUTO MOVIE A/B: \(variant) ===")
        let env = V3AcceptanceHarness.makeEnvironment(label: "automovie-\(variant)")
        var project: FilmProject

        if variant == "legacy" {
            print("Calling Ollama with the OLD (pre-V2) system prompt...")
            let response = try await v3OllamaGenerate(system: v3OldSystemPrompt, prompt: """
            TOTAL MOVIE DURATION TARGET
            Plan the complete movie to approximately 30.0 seconds total.
            This is the sum across all shots, not the duration of each shot.
            Choose the shot count and per-shot durations so their total is close to this target.

            BRIEF: \(v3Brief)
            """)
            guard let draft = StoryboardDirector.parseDraft(from: response) else {
                print("FAILED: could not parse legacy Director response"); exit(1)
            }
            project = V3AcceptanceHarness.makeLegacyProject(
                draft: draft, modelID: v3ModelID, targetDurationSeconds: 30.0)
        } else {
            print("Calling the real current HybridProjectCoordinator (NEW pipeline)...")
            let settings = ProjectSettings(
                modelID: v3ModelID, textEncoderID: "gemma3_12b_4bit",
                width: 768, height: 512, fps: 24, targetDurationSeconds: 30.0)
            let coordinator = HybridProjectCoordinator()
            let (newProject, violations, providerName) = try await coordinator.makeProject(
                title: "New A/B", brief: v3Brief, settings: settings)
            print("Director provider: \(providerName), violations: \(violations.count)")
            for v in violations { print("  [\(v.severity.rawValue)] \(v.message)") }
            project = newProject
        }

        print("\n" + V3AcceptanceHarness.summarize(project, label: variant.uppercased()))
        env.store.save(project)

        let renderCount = min(2, project.shots.count)
        print("\nRendering first \(renderCount) shot(s) through the real production path...")
        var results: [(String?, Double)] = []
        for i in 0..<renderCount {
            let r = await V3AcceptanceHarness.generateNextShot(
                env: env, projectID: project.id, label: "\(variant.uppercased()) shot \(i + 1)")
            results.append(r)
        }
        V3AcceptanceHarness.restoreOutputDir(env)

        print("\n=== \(variant.uppercased()) RESULT ===")
        for (i, r) in results.enumerated() {
            print("shot \(i + 1): \(String(format: "%.1f", r.1))s -> \(r.0 ?? "FAILED")")
        }
        print("Evidence: \(env.tmpDir.path)")
        exit(0)
    }
    RunLoop.main.run()
}

// Final complete-movie quality gate: plan-only inspection, full real
// generation of every planned shot, real take auto-selection, and real
// FinalAssemblyService export — closing the "only rendered shot 1-2" gap
// left by --v3-automovie.
//   swift run LTXTests --v4-plan
//   swift run LTXTests --v4-plan2
//   swift run LTXTests --v4-full
let v4Brief = "A woman walks slowly along a beach. She gradually slows down and comes to a stop. She looks toward the camera and gives a restrained smile. The sequence ends with a calm environmental reveal of the sunset over the water. About 28 seconds, cinematic, one continuous scene."
let v4SecondBrief = "A man runs across a rooftop, leaps over a gap between buildings, and lands hard, then looks back the way he came, breathing heavily. About 28 seconds, cinematic."

func v4PrintPlan(_ project: FilmProject, violations: [ContinuityEngine.Violation], providerName: String) {
    print("Director provider: \(providerName)")
    print("SHOT_COUNT: \(project.shots.count)")
    var total = 0.0
    for (i, s) in project.shots.enumerated() {
        total += s.durationSeconds
        print("shot \(i + 1):")
        print("  duration=\(String(format: "%.1f", s.durationSeconds))s")
        print("  purpose=\(s.shotPurpose?.shortLabel ?? "-")")
        print("  continuity=\(s.continuityMode?.rawValue ?? "-")")
        print("  camera: scale=\(s.camera.shotScale) angle=\(s.camera.angle) movement=\(s.camera.movement)")
        print("  actionArc(summary)=\"\(s.summary)\"")
        print("  endState=\(s.endStateSummary ?? "-")")
        print("  knowledgeIDs=\(s.consultedKnowledgeIDs)")
    }
    print("TOTAL=\(String(format: "%.1f", total))s")
    print("VIOLATIONS (\(violations.count)):")
    for v in violations { print("  [\(v.severity.rawValue)] \(v.message)") }
}

if CommandLine.arguments.contains("--v4-plan") || CommandLine.arguments.contains("--v4-plan2") {
    let isSecond = CommandLine.arguments.contains("--v4-plan2")
    Task { @MainActor in
        print("=== V4 PLAN ONLY (\(isSecond ? "second/generalization brief" : "primary brief")) ===")
        let brief = isSecond ? v4SecondBrief : v4Brief
        print("brief: \(brief)")
        let settings = ProjectSettings(
            modelID: v3ModelID, textEncoderID: "gemma3_12b_4bit",
            width: 768, height: 512, fps: 24, targetDurationSeconds: 28.0)
        let coordinator = HybridProjectCoordinator()
        do {
            let (project, violations, providerName) = try await coordinator.makeProject(
                title: isSecond ? "V4 Plan 2" : "V4 Plan", brief: brief, settings: settings)
            v4PrintPlan(project, violations: violations, providerName: providerName)
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--v4-full") {
    Task { @MainActor in
        print("=== V4 COMPLETE REAL AUTO MOVIE: plan -> generate all shots -> assemble ===")
        let env = V3AcceptanceHarness.makeEnvironment(label: "full-movie")
        let settings = ProjectSettings(
            modelID: v3ModelID, textEncoderID: "gemma3_12b_4bit",
            width: 768, height: 512, fps: 24, targetDurationSeconds: 28.0)
        let coordinator = HybridProjectCoordinator()
        let (project, violations, providerName) = try await coordinator.makeProject(
            title: "V4 Full Movie", brief: v4Brief, settings: settings)
        v4PrintPlan(project, violations: violations, providerName: providerName)
        env.store.save(project)

        print("\nGenerating ALL \(project.shots.count) shots through the real production path...")
        var perShot: [(videoPath: String?, seconds: Double)] = []
        for i in 0..<project.shots.count {
            let r = await V3AcceptanceHarness.generateNextShot(
                env: env, projectID: project.id, label: "SHOT \(i + 1)/\(project.shots.count)")
            perShot.append(r)
            if r.videoPath == nil {
                print("STOPPING: shot \(i + 1) failed to generate.")
                break
            }
        }
        V3AcceptanceHarness.restoreOutputDir(env)

        guard perShot.allSatisfy({ $0.videoPath != nil }), perShot.count == project.shots.count else {
            print("\nFAILED: not all shots completed (\(perShot.filter { $0.videoPath != nil }.count)/\(project.shots.count)).")
            exit(1)
        }

        env.coordinator.autoSelectUnambiguousTakes(projectID: project.id)
        guard let finalProject = env.store.project(id: project.id) else {
            print("FAILED: project vanished from store"); exit(1)
        }

        print("\n=== CONTINUITY EVIDENCE ===")
        for (i, s) in finalProject.shots.enumerated() {
            let take = s.selectedTake
            print("shot \(i + 1): continuity=\(s.continuityMode?.rawValue ?? "-") " +
                  "selectedTakeID=\(s.selectedTakeID?.uuidString.prefix(8) ?? "nil") " +
                  "continuitySourceTakeID=\(s.continuitySourceTakeID?.uuidString.prefix(8) ?? "nil") " +
                  "outputExists=\(take?.outputPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)")
        }
        let handoffs = finalProject.shots.filter { $0.continuityMode == .continueFromPrevious }.count
        let cuts = finalProject.shots.filter { $0.continuityMode == .cut }.count
        print("HANDOFF_COUNT=\(handoffs) CUT_COUNT=\(cuts)")

        print("\n=== FINAL ASSEMBLY (real FinalAssemblyService) ===")
        let assemblyOutputDir = env.tmpDir.appendingPathComponent("Final", isDirectory: true)
        try? FileManager.default.createDirectory(at: assemblyOutputDir, withIntermediateDirectories: true)
        let finalPath = assemblyOutputDir.appendingPathComponent("final_movie.mp4").path
        do {
            let info = try FinalAssemblyService.assemble(
                project: finalProject, outputPath: finalPath, store: env.store)
            print("ASSEMBLY OK -> \(finalPath)")
            print("duration=\(info.durationSeconds ?? -1) width=\(info.width ?? -1) height=\(info.height ?? -1) " +
                  "fps=\(info.fps ?? -1) videoCodec=\(info.videoCodec ?? "-") audioCodec=\(info.audioCodec ?? "-")")
        } catch {
            print("ASSEMBLY FAILED: \(error)")
            exit(1)
        }
        print("\nEvidence dir: \(env.tmpDir.path)")
        print("Final movie: \(finalPath)")
        exit(0)
    }
    RunLoop.main.run()
}

// V2.1 quality-hardening real short acceptance: 2-3 shots, one CONTINUE
// transition, through the real production path. Same known-good renderer,
// no new download. Checks appearance-preservation text, camera plan, and
// consultedKnowledgeIDs actually reach a real generation, not just plan-only.
//   swift run LTXTests --v5-short
if CommandLine.arguments.contains("--v5-short") {
    Task { @MainActor in
        print("=== V5 SHORT ACCEPTANCE: 2-3 shots, real production path ===")
        let brief = "A man in a gray jacket walks slowly through a quiet park. He stops near a bench and looks around. About 12 seconds, one continuous scene, stable clothing."
        let env = V3AcceptanceHarness.makeEnvironment(label: "short-acceptance")
        let settings = ProjectSettings(
            modelID: v3ModelID, textEncoderID: "gemma3_12b_4bit",
            width: 768, height: 512, fps: 24, targetDurationSeconds: 12.0)
        let coordinator = HybridProjectCoordinator()
        let (project, violations, providerName) = try await coordinator.makeProject(
            title: "V5 Short Acceptance", brief: brief, settings: settings)
        v4PrintPlan(project, violations: violations, providerName: providerName)
        env.store.save(project)

        print("\nGenerating ALL \(project.shots.count) shots through the real production path...")
        var perShot: [(videoPath: String?, seconds: Double)] = []
        for i in 0..<project.shots.count {
            let r = await V3AcceptanceHarness.generateNextShot(
                env: env, projectID: project.id, label: "SHOT \(i + 1)/\(project.shots.count)")
            perShot.append(r)
            if r.videoPath == nil { break }
        }
        V3AcceptanceHarness.restoreOutputDir(env)

        guard perShot.allSatisfy({ $0.videoPath != nil }), perShot.count == project.shots.count else {
            print("\nFAILED: not all shots completed."); exit(1)
        }
        env.coordinator.autoSelectUnambiguousTakes(projectID: project.id)
        guard let finalProject = env.store.project(id: project.id) else {
            print("FAILED: project vanished from store"); exit(1)
        }
        print("\n=== APPEARANCE / CAMERA / KNOWLEDGE EVIDENCE ===")
        for (i, s) in finalProject.shots.enumerated() {
            print("shot \(i + 1): continuity=\(s.continuityMode?.rawValue ?? "-") " +
                  "angle=\(s.camera.angle) movement=\(s.camera.movement) " +
                  "knowledgeIDs=\(s.consultedKnowledgeIDs)")
            print("  prompt: \(s.compiledPrompt.prefix(220))")
        }
        exit(0)
    }
    RunLoop.main.run()
}

let t = TestKit.shared

t.suite("Catalog") {
    t.checkEqual(LTXModelCatalog.resolvedModel(id: nil).id, LTXModelCatalog.defaultModelID, "default model resolves")
    t.checkEqual((1080 / 64) * 64, 1024, "64-px floor")
}

runRegistryTests(t)
runCompatLabTests(t)
runAutoQualityTests(t)
runDirectorTests(t)
runLocalDirectorCompatibilityTests(t)
runFilmProjectTests(t)
runCharacterSheetTests(t)
runDirectorModelProfileTests(t)
runExactDialogueReconcilerTests(t)
runDirectorEndpointTests(t)
runCharacterReferenceExtractionTests(t)
runImageConditioningPreparerTests(t)
runSourceImageOrientationTests(t)
runGenerationSourceDiagnosticsTests(t)
runGenerationRuntimeDiagnosticsTests(t)
runStartingImageBridgeTests(t)
runStartingImageUXTests(t)
runStoryboardTests(t)
runAutoMovieContinuityTests(t)
runAutoMovieStrictContinuityPolicyTests(t)
runContinuityStrengthTests(t)
runCinematicProgressionTests(t)
runContinuityReconcilerTests(t)
runAdaptiveContinuityStrengthTests(t)
runCapabilityAwarePlanningTests(t)
runOpeningAnchorTests(t)
runCharacterAnchorTests(t)
runOpeningReferenceTests(t)
runOpeningReferenceAppearanceTests(t)
runCharacterOpeningConsistencyTests(t)
runContinuationPromptPolicyTests(t)
runIdentityRefreshTests(t)
runLTXContinuityV1Tests(t)
runCutAwareContinuityTests(t)
runAutoMoviePlanPreviewTests(t)
runProductionQueueTests(t)
runSidebarNavigationTests(t)
runPerShotAudioPolicyTests(t)
runMotionTempoContinuityTests(t)
runAPITests(t)
runDependencyHealthTests(t)
runHuggingFaceCacheCheckerTests(t)
runFinalAudioTests(t)
runTextEncoderDownloadTests(t)
runLTX2MLXBackendTests(t)
runActiveModelDisplayResolverTests(t)
runOneShotPromptNormalizationTests(t)
runBasicDirectorStrictEnglishTests(t)
runEnhancedPromptHardeningTests(t)
runKeychainCredentialStoreTests(t)
runAutoMovieDirectorFallbackTests(t)
runQueueCancellationTests(t)
runDirectorPlanningCancellationTests(t)
runStorageHealthTests(t)
runCharacterContinuitySafetyTests(t)
runCharacterAnchorExtractionTests(t)
runLTX25ModelSupportTests(t)
runCustomModelProfileTests(t)
runLTX2MLXRuntimeManagerTests(t)
runMiniMaxH3Tests(t)
runMiniMaxH3GenerationLeaseTests(t)
runShotPlanValidatorTests(t)
runQualityHardeningTests(t)
runCanonicalShotRequestBuilderTests(t)
runOneShotCanonicalParityTests(t)
if CommandLine.arguments.contains("--probe-director-cancellation-acceptance") {
    runRealDirectorPlanningCancellationAcceptanceProbe(t)
}

try? FileManager.default.removeItem(at: ltxTestsStorageRoot)
t.finish()
