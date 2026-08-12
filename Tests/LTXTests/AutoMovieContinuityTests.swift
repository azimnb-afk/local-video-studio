import Foundation
@testable import LTXVideoGeneratorCore

/// Covers the Auto Movie vertical slice: sequential shot advancement,
/// continuity inheritance between consecutive shots, and single automatic
/// Final Assembly. Fixture videos come from the Phase 0 baseline renders when
/// present; media-dependent checks are skipped (not failed) without them.
func runAutoMovieContinuityTests(_ t: TestKit) {

    let fixtureA = "/tmp/ltx_baseline/T2V-A-ON.mp4"
    let fixtureB = "/tmp/ltx_baseline/I2V-A-ON.mp4"
    let hasFixtures = FileManager.default.fileExists(atPath: fixtureA)
        && FileManager.default.fileExists(atPath: fixtureB)
        && FinalAssemblyService.ffmpegPath() != nil

    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-automovie-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    func makeStore(_ name: String) -> FilmProjectStore {
        FilmProjectStore(projectsDirectory: tmpRoot.appendingPathComponent(name, isDirectory: true))
    }

    /// Builds a project with `shotCount` shots; every shot after the first is
    /// marked to continue from its predecessor.
    func makeProject(
        store: FilmProjectStore,
        shotCount: Int,
        workflowMode: String? = AutoMovieRunCoordinator.autoMovieWorkflowMode,
        continuity: ShotContinuityMode = .continueFromPrevious
    ) -> FilmProject {
        var project = FilmProject(title: "Auto Movie Test")
        project.workflowMode = workflowMode
        project.continuityChainEnabled = true
        for index in 0..<shotCount {
            var shot = Shot(index: index, title: "Shot \(index + 1)", summary: "beat \(index + 1)")
            shot.compiledPrompt = "A woman walks toward an old stone library, beat \(index + 1)."
            shot.durationSeconds = 1
            shot.continuityMode = index == 0 ? .cut : continuity
            project.shots.append(shot)
        }
        store.save(project)
        return store.project(id: project.id)!
    }

    /// Marks a shot's single take completed, pointing at a real fixture video.
    func completeShot(
        store: FilmProjectStore, projectID: UUID, shotIndex: Int,
        videoPath: String, selected: Bool = false
    ) -> UUID {
        var project = store.project(id: projectID)!
        var take = Take(
            shotID: project.shots[shotIndex].id, modelID: "m", seed: 100 + shotIndex,
            promptSnapshot: project.shots[shotIndex].compiledPrompt,
            settingsSnapshot: .default, requestedWidth: 512, requestedHeight: 320,
            fps: 24, requestedDuration: 1, status: .completed
        )
        take.outputPath = videoPath
        take.generationCompletedAt = Date()
        project.shots[shotIndex].takes.append(take)
        if selected { project.shots[shotIndex].selectedTakeID = take.id }
        store.save(project)
        return take.id
    }

    // MARK: - Continuity decision rules

    t.suite("Auto Movie — continuity decision") {
        let store = makeStore("decide")
        var project = makeProject(store: store, shotCount: 3)
        let coordinator = AutoMovieRunCoordinator(store: store)

        // O. First shot never inherits.
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 0, in: project), .cut,
                     "first shot resolves to cut")
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 1, in: project), .continueFromPrevious,
                     "declared continue is honoured")

        // Explicit cut wins.
        project.shots[1].continuityMode = .cut
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 1, in: project), .cut,
                     "declared cut is honoured")

        // Disabling the chain forces cuts everywhere.
        project.shots[1].continuityMode = .continueFromPrevious
        project.continuityChainEnabled = false
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 1, in: project), .cut,
                     "continuity disabled forces cut")
        project.continuityChainEnabled = true

        // auto → conservative inference.
        project.shots[1].continuityMode = .auto
        project.shots[1].explicitChanges = ["location=rooftop"]
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 1, in: project), .cut,
                     "auto + location change → cut")

        project.shots[1].explicitChanges = []
        var before = ContinuitySnapshot(); before.location = "library steps"
        var after = ContinuitySnapshot(); after.location = "library steps"
        project.shots[0].continuityBefore = before
        project.shots[1].continuityBefore = after
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 1, in: project), .continueFromPrevious,
                     "auto + same location → continue")

        after.location = "inside the library"
        project.shots[1].continuityBefore = after
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 1, in: project), .cut,
                     "auto + different location → cut")

        // No evidence at all stays a cut: absence of evidence is not continuity.
        project.shots[0].continuityBefore = nil
        project.shots[1].continuityBefore = nil
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 1, in: project), .cut,
                     "auto with no evidence → cut")

        // A widening establishing shot cuts even with the same cast.
        let cast = [UUID()]
        project.shots[0].characterIDs = cast
        project.shots[1].characterIDs = cast
        project.shots[0].camera.shotScale = "medium"
        project.shots[1].camera.shotScale = "wide"
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 1, in: project), .cut,
                     "auto + widening establishing shot → cut")
        project.shots[1].camera.shotScale = "close-up"
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 1, in: project), .continueFromPrevious,
                     "auto + same cast, tighter framing → continue")
    }

    // MARK: - Frame extraction and inheritance

    t.suite("Auto Movie — continuity frame inheritance") {
        guard hasFixtures else {
            t.check(true, "fixture videos unavailable — continuity extraction skipped")
            return
        }
        let store = makeStore("inherit")
        let project = makeProject(store: store, shotCount: 3)
        let coordinator = AutoMovieRunCoordinator(store: store)

        // I. Shot 1 completes → shot 2 gets an inherited frame.
        let takeID = completeShot(store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureA)
        switch coordinator.prepareContinuityAsset(projectID: project.id, shotIndex: 1) {
        case .success(let relativePath):
            t.check(relativePath.hasPrefix("Assets/Continuity/"), "continuity frame stored under the project")
            let url = store.managedProjectAssetURL(projectID: project.id, relativePath: relativePath)
            t.check(url != nil && ContinuityFrameExtractor.isUsableImage(atPath: url!.path),
                    "extracted frame is a usable PNG")
            let saved = store.project(id: project.id)!
            // P/Q. Source take is recorded for staleness tracking.
            t.checkEqual(saved.shots[1].continuitySourceTakeID, takeID,
                         "continuity records the take it came from")
        case .failure(let reason):
            t.check(false, "continuity extraction failed: \(reason)")
        }

        // Shot 2's request must carry the inherited frame as its starting image.
        let takeCoordinator = TakeGenerationCoordinator(store: store)
        do {
            let saved = store.project(id: project.id)!
            let requests = try takeCoordinator.planTakes(
                projectID: project.id, shotID: saved.shots[1].id, count: 1
            )
            t.check(requests.first?.sourceImagePath != nil,
                    "continue shot inherits sourceImagePath")
            t.check(requests.first?.isImageToVideo == true,
                    "continue shot renders as image-to-video")
        } catch {
            t.check(false, "planTakes threw for continue shot: \(error)")
        }

        // J. A cut shot must NOT inherit anything.
        let cutStore = makeStore("cut")
        let cutProject = makeProject(store: cutStore, shotCount: 2, continuity: .cut)
        _ = completeShot(store: cutStore, projectID: cutProject.id, shotIndex: 0, videoPath: fixtureA)
        var pending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: cutStore).advance(projectID: cutProject.id) { pending = $0 }
        t.check(pending.first?.sourceImagePath == nil, "cut shot does not inherit a starting image")
        let cutSaved = cutStore.project(id: cutProject.id)!
        t.check(cutSaved.shots[1].continuityImageRelativePath == nil,
                "cut shot stores no continuity asset")
    }

    t.suite("Auto Movie — selected Take controls future regeneration") {
        guard hasFixtures else {
            t.check(true, "fixture videos unavailable — selected-Take regeneration skipped")
            return
        }

        let store = makeStore("selected-retake")
        let project = makeProject(store: store, shotCount: 2)
        let takeCoordinator = TakeGenerationCoordinator(store: store)
        let runCoordinator = AutoMovieRunCoordinator(store: store)

        let take1 = completeShot(
            store: store, projectID: project.id, shotIndex: 0,
            videoPath: fixtureA, selected: true)
        _ = runCoordinator.prepareContinuityAsset(projectID: project.id, shotIndex: 1)
        let firstRequests = try? takeCoordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 900)
        let firstRequest = firstRequests?.first
        let firstDownstreamTake = store.project(id: project.id)?.shots[1].takes.last
        t.checkEqual(firstDownstreamTake?.generationSourceDiagnostics?.continuitySourceTakeID,
                     take1, "first downstream Take records Take 1")

        // A newer completed Take is explicitly selected before regeneration.
        let take2 = completeShot(
            store: store, projectID: project.id, shotIndex: 0,
            videoPath: fixtureB)
        var staleAnchorProject = store.project(id: project.id)!
        staleAnchorProject.shots[1].identityRefreshAnchorRelativePath =
            staleAnchorProject.shots[1].continuityImageRelativePath
        staleAnchorProject.shots[1].identityRefreshAnchorOrigin = .generated
        staleAnchorProject.shots[1].identityRefreshSourceTakeID = take1
        store.save(staleAnchorProject)
        try? takeCoordinator.selectTake(
            projectID: project.id, shotID: project.shots[0].id, takeID: take2)

        // Persistence is part of the contract: reconstruct the store before
        // pressing Regenerate, as a relaunch would.
        let reopened = FilmProjectStore(projectsDirectory: store.projectsDirectory)
        t.checkEqual(reopened.project(id: project.id)?.shots[0].selectedTakeID, take2,
                     "explicit Take selection survives project reopen")
        let reopenedCoordinator = TakeGenerationCoordinator(store: reopened)
        let secondRequests = try? reopenedCoordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 901)
        let secondRequest = secondRequests?.first
        let afterSelection = reopened.project(id: project.id)!
        let newDownstreamTake = afterSelection.shots[1].takes.last

        t.check(secondRequest?.sourceImagePath?.contains(take2.uuidString) == true,
                "future regeneration extracts the currently selected Take 2")
        t.check(secondRequest?.sourceImagePath?.contains(take1.uuidString) == false,
                "future regeneration does not reuse Take 1's cached frame")
        t.checkEqual(newDownstreamTake?.generationSourceDiagnostics?.continuitySourceTakeID,
                     take2, "new diagnostics record selected Take 2")
        t.checkEqual(newDownstreamTake?.generationSourceDiagnostics?.continuityTakeSelectionReason,
                     .selectedTake, "new diagnostics state Selected take")
        t.check(afterSelection.shots[1].identityRefreshAnchorRelativePath == nil,
                "an Identity Refresh anchor from Take 1 cannot override selected Take 2")
        t.checkEqual(afterSelection.shots[1].takes.first?.generationSourceDiagnostics,
                     firstDownstreamTake?.generationSourceDiagnostics,
                     "the earlier downstream Take keeps its Take 1 provenance")
        t.check(firstRequest?.sourceImagePath?.contains(take1.uuidString) == true,
                "the historical request remains tied to Take 1")

        // Selected beats latest. Take 3 completes later, but Take 2 stays the
        // user's explicit choice and must remain the future continuity source.
        let take3 = completeShot(
            store: reopened, projectID: project.id, shotIndex: 0,
            videoPath: fixtureA)
        let thirdRequests = try? reopenedCoordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 902)
        t.check(thirdRequests?.first?.sourceImagePath?.contains(take2.uuidString) == true,
                "selected Take 2 wins over latest completed Take 3")
        t.check(thirdRequests?.first?.sourceImagePath?.contains(take3.uuidString) == false,
                "latest completion cannot override an explicit valid selection")

        // With no selection the newest usable completed Take is the formal
        // fallback. Invalid selected Takes must not pin the chain or crash it.
        var fallbackProject = reopened.project(id: project.id)!
        fallbackProject.shots[0].selectedTakeID = nil
        reopened.save(fallbackProject)
        let fallbackRequests = try? reopenedCoordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 903)
        t.check(fallbackRequests?.first?.sourceImagePath?.contains(take3.uuidString) == true,
                "without selection the latest usable completed Take is used")

        var invalidProject = reopened.project(id: project.id)!
        var invalidSelected = Take(
            shotID: invalidProject.shots[0].id, modelID: "m", seed: 999,
            promptSnapshot: "invalid", settingsSnapshot: .default,
            requestedWidth: 512, requestedHeight: 320,
            fps: 24, requestedDuration: 1, status: .failed)
        invalidSelected.outputPath = tmpRoot.appendingPathComponent("missing-selected.mp4").path
        invalidProject.shots[0].takes.append(invalidSelected)
        invalidProject.shots[0].selectedTakeID = invalidSelected.id
        reopened.save(invalidProject)
        let invalidRequests = try? reopenedCoordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 904)
        t.check(invalidRequests?.first?.sourceImagePath?.contains(take3.uuidString) == true,
                "failed selected Take safely falls back to the latest usable Take")

        var missingProject = reopened.project(id: project.id)!
        var missingSelected = Take(
            shotID: missingProject.shots[0].id, modelID: "m", seed: 1000,
            promptSnapshot: "missing", settingsSnapshot: .default,
            requestedWidth: 512, requestedHeight: 320,
            fps: 24, requestedDuration: 1, status: .completed)
        missingSelected.outputPath = tmpRoot.appendingPathComponent("missing-completed.mp4").path
        missingSelected.generationCompletedAt = Date().addingTimeInterval(60)
        missingProject.shots[0].takes.append(missingSelected)
        missingProject.shots[0].selectedTakeID = missingSelected.id
        reopened.save(missingProject)
        let missingRequests = try? reopenedCoordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 905)
        t.check(missingRequests?.first?.sourceImagePath?.contains(take3.uuidString) == true,
                "missing selected output safely falls back to a usable Take")

        let corruptURL = tmpRoot.appendingPathComponent("corrupt-completed.mp4")
        try? Data("not a video".utf8).write(to: corruptURL)
        var corruptProject = reopened.project(id: project.id)!
        var corruptSelected = Take(
            shotID: corruptProject.shots[0].id, modelID: "m", seed: 1001,
            promptSnapshot: "corrupt", settingsSnapshot: .default,
            requestedWidth: 512, requestedHeight: 320,
            fps: 24, requestedDuration: 1, status: .completed)
        corruptSelected.outputPath = corruptURL.path
        corruptSelected.generationCompletedAt = Date().addingTimeInterval(120)
        corruptProject.shots[0].takes.append(corruptSelected)
        corruptProject.shots[0].selectedTakeID = corruptSelected.id
        reopened.save(corruptProject)
        let corruptRequests = try? reopenedCoordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 906)
        t.check(corruptRequests?.first?.sourceImagePath?.contains(take3.uuidString) == true,
                "corrupt selected output safely falls back to a usable Take")

        let unavailableStore = makeStore("selected-unavailable")
        let unavailableProject = makeProject(store: unavailableStore, shotCount: 2)
        var unavailable = unavailableStore.project(id: unavailableProject.id)!
        var unavailableTake = Take(
            shotID: unavailable.shots[0].id, modelID: "m", seed: 1002,
            promptSnapshot: "unavailable", settingsSnapshot: .default,
            requestedWidth: 512, requestedHeight: 320,
            fps: 24, requestedDuration: 1, status: .completed)
        unavailableTake.outputPath = tmpRoot.appendingPathComponent("no-usable-output.mp4").path
        unavailable.shots[0].takes = [unavailableTake]
        unavailable.shots[0].selectedTakeID = unavailableTake.id
        // Simulate a stale downstream cache from a different, removed Take.
        unavailable.shots[1].continuityImageRelativePath =
            "Assets/Continuity/old-unrelated-frame.png"
        unavailable.shots[1].continuitySourceTakeID = UUID()
        unavailableStore.save(unavailable)
        do {
            _ = try TakeGenerationCoordinator(store: unavailableStore).planTakes(
                projectID: unavailable.id, shotID: unavailable.shots[1].id,
                count: 1, baseSeed: 907)
            t.check(false, "no usable Take must not silently reuse an unrelated old cache")
        } catch let error as TakeGenerationCoordinator.CoordinatorError {
            t.checkEqual(error, .continuityImageUnavailable(unavailable.shots[1].id),
                         "no usable Take blocks with the continuity unavailable result")
        } catch {
            t.check(false, "unexpected no-usable-Take error: \(error)")
        }

        var cutProject = reopened.project(id: project.id)!
        cutProject.shots[1].continuityMode = .cut
        reopened.save(cutProject)
        let cutRequests = try? reopenedCoordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 908)
        t.check(cutRequests?.first?.sourceImagePath == nil,
                "Cut ignores every previous selected Take")
    }

    t.suite("Auto Movie — edited Cut / Continue reaches execution") {
        guard hasFixtures else {
            t.check(true, "fixture videos unavailable — edited execution wiring skipped")
            return
        }

        // CUT → CONTINUE uses the accepted Last Frame I2V path: the currently
        // selected previous Take is extracted, recorded, and passed to the new
        // request. The editor adds no second continuity algorithm.
        let continueStore = makeStore("edited-continue")
        var continueProject = makeProject(
            store: continueStore, shotCount: 2, continuity: .cut)
        let previousTakeID = completeShot(
            store: continueStore, projectID: continueProject.id,
            shotIndex: 0, videoPath: fixtureA, selected: true)
        continueProject = continueStore.project(id: continueProject.id)!
        t.check(AutoMoviePlanEditor.applyContinuityMode(
            project: &continueProject,
            shotID: continueProject.shots[1].id,
            mode: .continueFromPrevious),
                "an edited Cut becomes Continue before execution")
        continueStore.save(continueProject)
        var continueRequests: [GenerationRequest] = []
        let continueStep = AutoMovieRunCoordinator(store: continueStore).advance(
            projectID: continueProject.id) { continueRequests = $0 }
        if case .enqueued = continueStep {
            t.check(true, "the edited Continue is enqueued through the existing run coordinator")
        } else {
            t.check(false, "expected edited Continue to enqueue, got \(continueStep)")
        }
        let continued = continueStore.project(id: continueProject.id)!
        t.checkEqual(continued.shots[1].continuitySourceTakeID, previousTakeID,
                     "the selected previous Take is the recorded continuity source")
        t.check(continued.shots[1].continuityImageRelativePath != nil,
                "the existing extractor creates a fresh last-frame asset")
        t.check(continueRequests.first?.sourceImagePath != nil,
                "the future request receives that last usable frame")
        t.check(continueRequests.first?.isImageToVideo == true,
                "the edited Continue executes as Last Frame I2V")

        // CONTINUE → CUT after a frame was already prepared must not leak that
        // path. Advance sees the new effective mode and plans an independent
        // request; the editor has also removed every stale prepared reference.
        let cutStore = makeStore("edited-cut")
        var cutProject = makeProject(store: cutStore, shotCount: 2)
        _ = completeShot(
            store: cutStore, projectID: cutProject.id,
            shotIndex: 0, videoPath: fixtureA, selected: true)
        _ = AutoMovieRunCoordinator(store: cutStore)
            .prepareContinuityAsset(projectID: cutProject.id, shotIndex: 1)
        cutProject = cutStore.project(id: cutProject.id)!
        t.check(cutProject.shots[1].continuityImageRelativePath != nil,
                "fixture begins with a prepared continuation frame")
        t.check(AutoMoviePlanEditor.applyContinuityMode(
            project: &cutProject, shotID: cutProject.shots[1].id, mode: .cut),
                "a prepared Continue can be changed to Cut")
        cutStore.save(cutProject)
        var cutRequests: [GenerationRequest] = []
        let cutStep = AutoMovieRunCoordinator(store: cutStore).advance(
            projectID: cutProject.id) { cutRequests = $0 }
        if case .enqueued = cutStep {
            t.check(true, "the edited Cut is enqueued independently")
        } else {
            t.check(false, "expected edited Cut to enqueue, got \(cutStep)")
        }
        let cutSaved = cutStore.project(id: cutProject.id)!
        t.check(cutSaved.shots[1].continuityImageRelativePath == nil,
                "edited Cut retains no prepared previous-frame path")
        t.check(cutSaved.shots[1].identityRefreshAnchorRelativePath == nil,
                "edited Cut retains no continuation-derived refresh anchor")
        t.check(cutRequests.first?.sourceImagePath == nil,
                "the generation request contains no previous-frame leak")
        t.check(cutRequests.first?.isImageToVideo == false,
                "without another valid source the edited Cut executes as T2V")
    }

    // MARK: - No silent fallback

    t.suite("Auto Movie — no silent text-to-video fallback") {
        // L. CONTINUE with a missing previous output must block, not fall back.
        let store = makeStore("missing")
        let project = makeProject(store: store, shotCount: 2)
        _ = completeShot(store: store, projectID: project.id, shotIndex: 0,
                         videoPath: tmpRoot.appendingPathComponent("does-not-exist.mp4").path)
        let coordinator = AutoMovieRunCoordinator(store: store)
        var pending: [GenerationRequest] = []
        let step = coordinator.advance(projectID: project.id) { pending = $0 }
        t.check(pending.isEmpty, "blocked continue shot is not queued")
        if case .blocked(_, let reason) = step {
            t.checkEqual(reason, .previousOutputMissing, "missing previous output is reported")
        } else {
            t.check(false, "expected blocked step, got \(step)")
        }
        let saved = store.project(id: project.id)!
        t.check(saved.shots[1].continuityBlockedReason != nil, "block reason persisted on the shot")
        t.check(!coordinator.shouldAutoAssemble(project: saved), "blocked run does not auto-assemble")

        // M. An unusable continuity asset is rejected at the queue boundary.
        let brokenStore = makeStore("broken")
        var brokenProject = makeProject(store: brokenStore, shotCount: 2)
        brokenProject.shots[1].continuityImageRelativePath = "Assets/Continuity/missing.png"
        brokenStore.save(brokenProject)
        do {
            _ = try TakeGenerationCoordinator(store: brokenStore)
                .planTakes(projectID: brokenProject.id, shotID: brokenProject.shots[1].id, count: 1)
            t.check(false, "planTakes should reject an unusable continuity image")
        } catch {
            t.check(true, "unusable continuity image is rejected instead of rendering text-to-video")
        }
    }

    // MARK: - Starting image precedence

    t.suite("Auto Movie — starting image precedence") {
        guard hasFixtures else {
            t.check(true, "fixture videos unavailable — precedence check skipped")
            return
        }
        // K. An explicit user starting image is never overwritten by continuity.
        let store = makeStore("precedence")
        var project = makeProject(store: store, shotCount: 2)

        let characterID = UUID()
        var character = BibleCharacter(id: characterID, name: "Mika")
        let assetID = UUID()
        let assetsDir = store.characterAssetsDirectory(projectID: project.id, characterID: characterID)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let assetURL = assetsDir.appendingPathComponent("front.png")
        FileManager.default.createFile(
            atPath: assetURL.path,
            contents: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        )
        let relative = "Assets/Characters/\(characterID.uuidString)/front.png"
        character.referenceAssets = [
            CharacterReferenceAsset(id: assetID, type: .front, projectRelativePath: relative)
        ]
        project.characterBible.characters = [character]
        project.shots[1].startingImageReferenceAssetID = assetID
        store.save(project)

        _ = completeShot(store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureA)
        var pending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: store).advance(projectID: project.id) { pending = $0 }
        t.check(pending.first?.sourceImagePath?.hasSuffix("front.png") == true,
                "explicit starting image wins over inherited continuity frame")
    }

    // MARK: - Sequential dependency and assembly

    t.suite("Auto Movie — sequential run and single assembly") {
        guard hasFixtures else {
            t.check(true, "fixture videos unavailable — run/assembly checks skipped")
            return
        }
        let store = makeStore("run")
        let project = makeProject(store: store, shotCount: 2)
        let coordinator = AutoMovieRunCoordinator(store: store)

        // N. Shot 2 is not started while shot 1 is still in flight.
        var working = store.project(id: project.id)!
        var queuedTake = Take(
            shotID: working.shots[0].id, modelID: "m", seed: 1,
            promptSnapshot: "p", settingsSnapshot: .default,
            requestedWidth: 512, requestedHeight: 320, fps: 24,
            requestedDuration: 1, status: .queued
        )
        queuedTake.outputPath = nil
        working.shots[0].takes = [queuedTake]
        store.save(working)
        var pending: [GenerationRequest] = []
        let waitingStep = coordinator.advance(projectID: project.id) { pending = $0 }
        t.checkEqual(waitingStep, .waiting, "run waits while a generation is in flight")
        t.check(pending.isEmpty, "no shot is queued while another is generating")

        // Complete shot 1, then shot 2 becomes queueable with an inherited frame.
        working = store.project(id: project.id)!
        working.shots[0].takes = []
        store.save(working)
        _ = completeShot(store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureA)
        pending = []
        let enqueueStep = coordinator.advance(projectID: project.id) { pending = $0 }
        if case .enqueued = enqueueStep {
            t.check(true, "next shot is enqueued after the previous one completes")
        } else {
            t.check(false, "expected enqueued step, got \(enqueueStep)")
        }
        t.checkEqual(pending.count, 1, "exactly one shot is queued at a time")

        // Finish shot 2 → run is complete and ready to assemble exactly once.
        var afterQueue = store.project(id: project.id)!
        afterQueue.shots[1].takes = []
        store.save(afterQueue)
        _ = completeShot(store: store, projectID: project.id, shotIndex: 1, videoPath: fixtureB)

        // C. A single completed take is auto-selected.
        coordinator.autoSelectUnambiguousTakes(projectID: project.id)
        let selected = store.project(id: project.id)!
        t.check(selected.shots.allSatisfy { $0.selectedTakeID != nil },
                "single completed takes are auto-selected")
        t.check(coordinator.shouldAutoAssemble(project: selected), "complete run is ready to assemble")

        // A/D. Assembly produces a playable movie.
        let result = coordinator.performAutoAssembly(projectID: project.id)
        if case .assembled(let path) = result {
            t.check(FileManager.default.fileExists(atPath: path), "assembled movie exists")
            if let info = MediaProbe.probe(path: path) {
                t.check((info.durationSeconds ?? 0) > 1.5, "assembled movie spans both shots")
            }
        } else {
            t.check(false, "expected assembled step, got \(result)")
        }

        // F. Duplicate assembly prevention.
        let assembled = store.project(id: project.id)!
        t.check(assembled.lastAssemblySignature != nil, "assembly signature recorded")
        t.check(assembled.assembledMoviePath != nil, "assembled movie path recorded")
        t.check(!coordinator.shouldAutoAssemble(project: assembled),
                "already-assembled run does not assemble again")
        t.checkEqual(coordinator.performAutoAssembly(projectID: project.id), .completed,
                     "second assembly attempt is a no-op")
    }

    t.suite("Auto Movie — failure, cancel and ambiguity block assembly") {
        // B/E. A failed shot must not produce a movie.
        let store = makeStore("failure")
        let project = makeProject(store: store, shotCount: 2)
        _ = completeShot(store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureA)
        var withFailure = store.project(id: project.id)!
        var failed = Take(
            shotID: withFailure.shots[1].id, modelID: "m", seed: 2,
            promptSnapshot: "p", settingsSnapshot: .default,
            requestedWidth: 512, requestedHeight: 320, fps: 24,
            requestedDuration: 1, status: .failed
        )
        failed.outputPath = nil
        withFailure.shots[1].takes = [failed]
        store.save(withFailure)
        let coordinator = AutoMovieRunCoordinator(store: store)
        let saved = store.project(id: project.id)!
        t.check(!coordinator.shouldAutoAssemble(project: saved), "failed shot blocks assembly")
        var pending: [GenerationRequest] = []
        let step = coordinator.advance(projectID: project.id) { pending = $0 }
        if case .shotFailed = step {
            t.check(true, "failed shot stops the run instead of silently retrying")
        } else {
            t.check(false, "expected shotFailed step, got \(step)")
        }
        t.check(pending.isEmpty, "nothing is queued after a failure")

        // G. Cancellation behaves the same way.
        let cancelStore = makeStore("cancel")
        let cancelProject = makeProject(store: cancelStore, shotCount: 2)
        _ = completeShot(store: cancelStore, projectID: cancelProject.id, shotIndex: 0, videoPath: fixtureA)
        var cancelled = cancelStore.project(id: cancelProject.id)!
        var cancelledTake = Take(
            shotID: cancelled.shots[1].id, modelID: "m", seed: 3,
            promptSnapshot: "p", settingsSnapshot: .default,
            requestedWidth: 512, requestedHeight: 320, fps: 24,
            requestedDuration: 1, status: .cancelled
        )
        cancelledTake.outputPath = nil
        cancelled.shots[1].takes = [cancelledTake]
        cancelStore.save(cancelled)
        t.check(!AutoMovieRunCoordinator(store: cancelStore)
            .shouldAutoAssemble(project: cancelStore.project(id: cancelProject.id)!),
                "cancelled shot blocks assembly")

        // Ambiguous selection: several completed takes and no choice made.
        let ambiguousStore = makeStore("ambiguous")
        let ambiguous = makeProject(store: ambiguousStore, shotCount: 1)
        _ = completeShot(store: ambiguousStore, projectID: ambiguous.id, shotIndex: 0, videoPath: fixtureA)
        _ = completeShot(store: ambiguousStore, projectID: ambiguous.id, shotIndex: 0, videoPath: fixtureB)
        let ambiguousCoordinator = AutoMovieRunCoordinator(store: ambiguousStore)
        ambiguousCoordinator.autoSelectUnambiguousTakes(projectID: ambiguous.id)
        let ambiguousSaved = ambiguousStore.project(id: ambiguous.id)!
        t.check(ambiguousSaved.shots[0].selectedTakeID == nil,
                "multiple completed takes are never auto-ranked")
        t.check(!ambiguousCoordinator.shouldAutoAssemble(project: ambiguousSaved),
                "ambiguous take selection blocks automatic assembly")
    }

    // MARK: - Storyboard behaviour and compatibility

    t.suite("Storyboard — automatic assembly, manual continuity") {
        guard hasFixtures else {
            t.check(true, "fixture videos unavailable — storyboard assembly skipped")
            return
        }
        // Storyboard projects are not auto-advanced by the run coordinator.
        let store = makeStore("storyboard")
        let project = makeProject(store: store, shotCount: 2, workflowMode: nil)
        let coordinator = AutoMovieRunCoordinator(store: store)
        var pending: [GenerationRequest] = []
        t.checkEqual(coordinator.advance(projectID: project.id) { pending = $0 }, .idle,
                     "manual storyboards are not auto-advanced")
        t.check(pending.isEmpty, "storyboard shots are not queued automatically")

        // H. But a completed storyboard still assembles once, automatically.
        _ = completeShot(store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureA)
        _ = completeShot(store: store, projectID: project.id, shotIndex: 1, videoPath: fixtureB)
        let outcome = coordinator.autoAssembleIfComplete(projectID: project.id)
        if case .assembled = outcome {
            t.check(true, "storyboard assembles automatically when every shot is ready")
        } else {
            t.check(false, "expected storyboard assembly, got \(outcome)")
        }
        t.checkEqual(coordinator.autoAssembleIfComplete(projectID: project.id), .completed,
                     "storyboard assembly does not repeat")

        // Selected take wins over other completed takes.
        let selectStore = makeStore("selected")
        let selectProject = makeProject(store: selectStore, shotCount: 1, workflowMode: nil)
        _ = completeShot(store: selectStore, projectID: selectProject.id, shotIndex: 0, videoPath: fixtureA)
        let chosen = completeShot(store: selectStore, projectID: selectProject.id, shotIndex: 0,
                                  videoPath: fixtureB, selected: true)
        let selectSaved = selectStore.project(id: selectProject.id)!
        t.checkEqual(selectSaved.shots[0].assemblyCandidateTake?.id, chosen,
                     "explicitly selected take is used for assembly")
    }

    t.suite("Auto Movie — persistence and staleness") {
        // R. Projects saved before continuity existed still decode.
        let legacyShotJSON = """
        {"id":"\(UUID().uuidString)","index":0,"title":"Legacy","summary":"s",
         "durationSeconds":5,"compiledPrompt":"p"}
        """.data(using: .utf8)!
        do {
            let shot = try JSONDecoder().decode(Shot.self, from: legacyShotJSON)
            t.check(shot.continuityMode == nil, "legacy shot decodes with no continuity mode")
            t.check(shot.continuityImageRelativePath == nil, "legacy shot has no continuity asset")
            t.check(shot.continuityBlockedReason == nil, "legacy shot is not blocked")
        } catch {
            t.check(false, "legacy shot failed to decode: \(error)")
        }

        let legacyProjectJSON = """
        {"schemaVersion":1,"id":"\(UUID().uuidString)","title":"Legacy Project","shots":[]}
        """.data(using: .utf8)!
        do {
            let project = try JSONDecoder().decode(FilmProject.self, from: legacyProjectJSON)
            t.check(project.lastAssemblySignature == nil, "legacy project has no assembly signature")
            t.check(project.continuityChainEnabled == nil, "legacy project has no continuity flag")
        } catch {
            t.check(false, "legacy project failed to decode: \(error)")
        }

        // Round-trip of the new fields.
        var shot = Shot(index: 1, title: "S2")
        shot.continuityMode = .continueFromPrevious
        shot.continuityImageRelativePath = "Assets/Continuity/shot-002.png"
        shot.continuitySourceTakeID = UUID()
        shot.continuityBlockedReason = .frameExtractionFailed
        do {
            let decoded = try JSONDecoder().decode(Shot.self, from: try JSONEncoder().encode(shot))
            t.checkEqual(decoded.continuityMode, .continueFromPrevious, "continuity mode round-trips")
            t.checkEqual(decoded.continuityImageRelativePath, shot.continuityImageRelativePath,
                         "continuity asset path round-trips")
            t.checkEqual(decoded.continuitySourceTakeID, shot.continuitySourceTakeID,
                         "continuity source take round-trips")
            t.checkEqual(decoded.continuityBlockedReason, .frameExtractionFailed,
                         "continuity block reason round-trips")
        } catch {
            t.check(false, "continuity fields failed to round-trip: \(error)")
        }
        t.checkEqual(ShotContinuityMode(rawValue: "continue"), .continueFromPrevious,
                     "planner value 'continue' maps to the continue mode")

        // Q. A Retake upstream makes a downstream inherited frame stale.
        guard hasFixtures else {
            t.check(true, "fixture videos unavailable — staleness check skipped")
            return
        }
        let store = makeStore("stale")
        let project = makeProject(store: store, shotCount: 2)
        let firstTake = completeShot(store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureA)
        _ = AutoMovieRunCoordinator(store: store).prepareContinuityAsset(projectID: project.id, shotIndex: 1)
        var saved = store.project(id: project.id)!
        t.checkEqual(saved.shots[1].continuitySourceTakeID, firstTake, "continuity points at the first take")
        t.check(!AutoMovieRunCoordinator(store: store).continuityIsStale(shotIndex: 1, in: saved),
                "continuity is fresh right after extraction")

        // A newer take on shot 1 (a Retake) becomes the continuity source.
        let retake = completeShot(store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureB)
        saved = store.project(id: project.id)!
        saved.shots[0].selectedTakeID = retake
        store.save(saved)
        saved = store.project(id: project.id)!
        t.check(AutoMovieRunCoordinator(store: store).continuityIsStale(shotIndex: 1, in: saved),
                "downstream continuity is flagged stale after a retake")
    }
}

/// Continuity image-strength calibration: the calibrated value must reach
/// inherited frames only, and every explicit starting-image path must keep its
/// original exact-first-frame behaviour.
func runContinuityStrengthTests(_ t: TestKit) {
    let fixtureA = "/tmp/ltx_baseline/T2V-A-ON.mp4"
    let hasFixtures = FileManager.default.fileExists(atPath: fixtureA)
        && FinalAssemblyService.ffmpegPath() != nil

    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-strength-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    func makeStore(_ name: String) -> FilmProjectStore {
        FilmProjectStore(projectsDirectory: tmpRoot.appendingPathComponent(name, isDirectory: true))
    }

    func makeProject(store: FilmProjectStore, shotCount: Int,
                     workflowMode: String? = AutoMovieRunCoordinator.autoMovieWorkflowMode,
                     continuity: ShotContinuityMode = .continueFromPrevious) -> FilmProject {
        var project = FilmProject(title: "Strength Test")
        project.workflowMode = workflowMode
        project.continuityChainEnabled = true
        for index in 0..<shotCount {
            var shot = Shot(index: index, title: "Shot \(index + 1)", summary: "beat")
            shot.compiledPrompt = "prompt \(index + 1)"
            shot.durationSeconds = 1
            shot.continuityMode = index == 0 ? .cut : continuity
            project.shots.append(shot)
        }
        store.save(project)
        return store.project(id: project.id)!
    }

    func completeShot(store: FilmProjectStore, projectID: UUID, shotIndex: Int, videoPath: String) {
        var project = store.project(id: projectID)!
        var take = Take(
            shotID: project.shots[shotIndex].id, modelID: "m", seed: 7,
            promptSnapshot: "p", settingsSnapshot: .default,
            requestedWidth: 512, requestedHeight: 320, fps: 24,
            requestedDuration: 1, status: .completed
        )
        take.outputPath = videoPath
        take.generationCompletedAt = Date()
        project.shots[shotIndex].takes.append(take)
        store.save(project)
    }

    t.suite("Continuity strength — calibrated value and scope") {
        // The calibrated constant must stay in the range the backend accepts and
        // below 1.0, which is what caused the frozen-composition regression.
        let strength = AutoMovieRunCoordinator.continuityImageStrength
        t.check(strength > 0 && strength < 1.0, "calibrated continuity strength is inside (0, 1)")
        t.checkEqual(strength, 0.8, "calibrated continuity strength is the measured knee value")

        // Defaults for every non-continuity path stay at the original 1.0.
        t.checkEqual(GenerationParameters.default.imageStrength, 1.0,
                     "E: default parameters keep exact-first-frame strength")
        t.checkEqual(GenerationParameters.preview.imageStrength, 1.0,
                     "E: preview parameters keep exact-first-frame strength")
        t.checkEqual(GenerationParameters.highQuality.imageStrength, 1.0,
                     "E: high quality parameters keep exact-first-frame strength")

        guard hasFixtures else {
            t.check(true, "fixture video unavailable — strength wiring checks skipped")
            return
        }

        // A. An inherited continuity frame receives the calibrated strength.
        let store = makeStore("inherited")
        let project = makeProject(store: store, shotCount: 2)
        completeShot(store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureA)
        var pending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: store).advance(projectID: project.id) { pending = $0 }
        t.check(pending.first?.sourceImagePath != nil, "A: continuing shot inherits a frame")
        t.checkEqual(pending.first?.parameters.imageStrength,
                     AutoMovieRunCoordinator.continuityImageStrength,
                     "A: inherited frame uses the calibrated continuity strength")
        // The value is snapshotted on the Take, so a run stays reproducible.
        let savedTake = store.project(id: project.id)!.shots[1].takes.first
        t.checkEqual(savedTake?.settingsSnapshot.imageStrength,
                     AutoMovieRunCoordinator.continuityImageStrength,
                     "A: persisted Take records the effective continuity strength")

        // B. An explicit starting image is untouched by the calibration.
        let explicitStore = makeStore("explicit")
        var explicitProject = makeProject(store: explicitStore, shotCount: 2)
        let characterID = UUID()
        var character = BibleCharacter(id: characterID, name: "Mika")
        let assetID = UUID()
        let assetsDir = explicitStore.characterAssetsDirectory(projectID: explicitProject.id, characterID: characterID)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: assetsDir.appendingPathComponent("front.png").path,
            contents: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        )
        character.referenceAssets = [CharacterReferenceAsset(
            id: assetID, type: .front,
            projectRelativePath: "Assets/Characters/\(characterID.uuidString)/front.png"
        )]
        explicitProject.characterBible.characters = [character]
        explicitProject.shots[1].startingImageReferenceAssetID = assetID
        explicitStore.save(explicitProject)
        completeShot(store: explicitStore, projectID: explicitProject.id, shotIndex: 0, videoPath: fixtureA)
        var explicitPending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: explicitStore)
            .advance(projectID: explicitProject.id) { explicitPending = $0 }
        t.check(explicitPending.first?.sourceImagePath?.hasSuffix("front.png") == true,
                "B: explicit starting image still wins")
        t.checkEqual(explicitPending.first?.parameters.imageStrength, 1.0,
                     "B: explicit starting image keeps exact-first-frame strength")

        // C. A cut shot gets neither an image nor the continuity strength.
        let cutStore = makeStore("cut")
        let cutProject = makeProject(store: cutStore, shotCount: 2, continuity: .cut)
        completeShot(store: cutStore, projectID: cutProject.id, shotIndex: 0, videoPath: fixtureA)
        var cutPending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: cutStore).advance(projectID: cutProject.id) { cutPending = $0 }
        t.check(cutPending.first?.sourceImagePath == nil, "C: cut shot inherits no image")
        t.checkEqual(cutPending.first?.parameters.imageStrength, 1.0,
                     "C: cut shot keeps the default strength")

        // D. The first shot has nothing to inherit, so it is unaffected.
        let firstStore = makeStore("first")
        let firstProject = makeProject(store: firstStore, shotCount: 2)
        var firstPending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: firstStore).advance(projectID: firstProject.id) { firstPending = $0 }
        t.check(firstPending.first?.sourceImagePath == nil, "D: first shot has no inherited image")
        t.checkEqual(firstPending.first?.parameters.imageStrength, 1.0,
                     "D: first shot keeps the default strength")

        // G. A manual storyboard shot with an explicit image is unaffected.
        let sbStore = makeStore("storyboard")
        var sbProject = makeProject(store: sbStore, shotCount: 1, workflowMode: nil)
        let sbCharacterID = UUID()
        var sbCharacter = BibleCharacter(id: sbCharacterID, name: "Ken")
        let sbAssetID = UUID()
        let sbAssets = sbStore.characterAssetsDirectory(projectID: sbProject.id, characterID: sbCharacterID)
        try? FileManager.default.createDirectory(at: sbAssets, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: sbAssets.appendingPathComponent("front.png").path,
            contents: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        )
        sbCharacter.referenceAssets = [CharacterReferenceAsset(
            id: sbAssetID, type: .front,
            projectRelativePath: "Assets/Characters/\(sbCharacterID.uuidString)/front.png"
        )]
        sbProject.characterBible.characters = [sbCharacter]
        sbProject.shots[0].startingImageReferenceAssetID = sbAssetID
        sbStore.save(sbProject)
        do {
            let requests = try TakeGenerationCoordinator(store: sbStore)
                .planTakes(projectID: sbProject.id, shotID: sbProject.shots[0].id, count: 1)
            t.checkEqual(requests.first?.parameters.imageStrength, 1.0,
                         "G: storyboard explicit starting image keeps exact-first-frame strength")
        } catch {
            t.check(false, "G: storyboard planTakes threw \(error)")
        }
    }

    t.suite("Continuity strength — unrelated surfaces unchanged") {
        // F. One Shot and Generate build requests without the coordinator, so
        // their strength comes from the shared parameter defaults.
        var params = GenerationParameters.default
        t.checkEqual(params.imageStrength, 1.0, "F: One Shot / Generate default strength unchanged")
        params.imageStrength = 0.5
        let request = GenerationRequest(prompt: "p", sourceImagePath: "/tmp/x.png", parameters: params)
        t.checkEqual(request.parameters.imageStrength, 0.5,
                     "F: a manually chosen strength is still carried through unchanged")

        // H. Projects persisted before the calibration still decode.
        let legacy = """
        {"schemaVersion":1,"id":"\(UUID().uuidString)","title":"Legacy","workflowMode":"hybrid","shots":[]}
        """.data(using: .utf8)!
        do {
            let project = try JSONDecoder().decode(FilmProject.self, from: legacy)
            t.checkEqual(project.workflowMode, "hybrid", "H: legacy auto movie project still decodes")
        } catch {
            t.check(false, "H: legacy project failed to decode: \(error)")
        }
    }
}
