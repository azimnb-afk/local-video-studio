import Foundation
@testable import LTXVideoGeneratorCore

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
runCharacterReferenceExtractionTests(t)
runImageConditioningPreparerTests(t)
runSourceImageOrientationTests(t)
runGenerationSourceDiagnosticsTests(t)
runGenerationRuntimeDiagnosticsTests(t)
runStartingImageBridgeTests(t)
runStartingImageUXTests(t)
runStoryboardTests(t)
runAutoMovieContinuityTests(t)
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

t.finish()
