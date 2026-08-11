import Foundation
@testable import LTXVideoGeneratorCore

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
runFilmProjectTests(t)
runCharacterSheetTests(t)
runCharacterReferenceExtractionTests(t)
runImageConditioningPreparerTests(t)
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
runAPITests(t)
runDependencyHealthTests(t)
runHuggingFaceCacheCheckerTests(t)

t.finish()
