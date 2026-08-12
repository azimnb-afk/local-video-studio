import Foundation
@testable import LTXVideoGeneratorCore

func runAutoMoviePlanPreviewTests(_ t: TestKit) {

    func plannedProject(withOpeningReference: Bool = true) -> FilmProject {
        var project = FilmProject(title: "Preview")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        if withOpeningReference {
            project.openingReferenceImage = OpeningReferenceImage(
                projectRelativePath: "Assets/OpeningReference/o.png",
                originalFilename: "o.png", mimeType: "image/png", fileSizeBytes: 1)
        }
        var one = Shot(index: 0, title: "Approach",
                       summary: "She walks across the courtyard toward the gate.")
        one.durationSeconds = 5
        one.continuityMode = .cut
        one.camera = CameraPlan(shotScale: "medium-wide", angle: "eye-level", movement: "static")

        var two = Shot(index: 1, title: "Pause", summary: "She stops and looks up.")
        two.durationSeconds = 5
        two.continuityMode = .continueFromPrevious
        two.camera = CameraPlan(shotScale: "medium", angle: "eye-level", movement: "slow push-in")

        var three = Shot(index: 2, title: "React", summary: "She reacts.")
        three.durationSeconds = 5
        three.continuityMode = .continueFromPrevious
        three.camera = CameraPlan(shotScale: "close-up", angle: "eye-level", movement: "static")

        var four = Shot(index: 3, title: "Enter", summary: "She moves into the gate.")
        four.durationSeconds = 5
        four.continuityMode = .cut
        four.camera = CameraPlan(shotScale: "wide", angle: "eye-level", movement: "static")

        project.shots = [one, two, three, four]
        return project
    }

    t.suite("Auto Movie plan preview — the plan is readable before generation") {
        let preview = AutoMoviePlanPreview.make(project: plannedProject())
        t.checkEqual(preview.rows.count, 4, "every planned shot appears")
        t.checkEqual(preview.rows[0].number, 1, "shots are numbered from one")
        t.checkEqual(preview.rows[0].action, "She walks across the courtyard toward the gate.",
                     "the planned action is shown")
        t.checkEqual(preview.rows[2].framing, "Close-up", "the planned framing is shown")
        t.checkEqual(preview.rows[1].cameraMovement, "slow push-in",
                     "and the camera movement when the plan has one")
        t.check(!preview.hasAnyGenerated,
                "nothing is generated yet, and the preview says so")
    }

    t.suite("Auto Movie plan preview — durations are approximate") {
        let preview = AutoMoviePlanPreview.make(project: plannedProject())
        t.checkEqual(preview.rows[0].approximateDurationText, "~5 sec",
                     "a shot reads as approximate, never frame-exact")
        t.checkEqual(preview.totalApproximateSeconds, 20, "the total sums the planned beats")
        t.checkEqual(preview.totalDurationText, "Approx. 20 sec total",
                     "and is worded as an approximation")
        for row in preview.rows {
            t.check(row.approximateDurationText.hasPrefix("~"),
                    "shot \(row.number) never implies exact timing")
        }
    }

    t.suite("Auto Movie plan preview — sources match what generation will do") {
        let preview = AutoMoviePlanPreview.make(project: plannedProject())
        t.checkEqual(preview.rows[0].sourceDescription, "Opening Reference",
                     "shot 1 shows the opening reference it will actually start from")
        t.checkEqual(preview.rows[0].continuityIntent, "Cut",
                     "and its planned continuity intent")
        // Before generation a later shot has no inherited asset yet; the
        // preview must describe what it *will* use, not report text-to-video.
        t.checkEqual(preview.rows[1].sourceDescription, "Previous shot's last frame",
                     "a continuing shot says what it will inherit")
        t.checkEqual(preview.rows[1].continuityIntent, "Continue",
                     "and is labelled as a continuation")
        t.checkEqual(preview.rows[3].sourceDescription, "Text to video",
                     "a planned cut correctly shows it inherits nothing")

        // Without an opening reference shot 1 is text-to-video.
        let noRef = AutoMoviePlanPreview.make(project: plannedProject(withOpeningReference: false))
        t.checkEqual(noRef.rows[0].sourceDescription, "Text to video",
                     "with no opening reference the first shot is text-to-video")
    }

    t.suite("Auto Movie plan preview — progress and edge cases") {
        var partly = plannedProject()
        let take = Take(shotID: partly.shots[0].id, modelID: "m", seed: 1,
                        promptSnapshot: "p", settingsSnapshot: .default,
                        requestedWidth: 768, requestedHeight: 512,
                        fps: 24, requestedDuration: 5, status: .completed)
        partly.shots[0].takes = [take]
        let preview = AutoMoviePlanPreview.make(project: partly)
        t.check(preview.rows[0].isGenerated, "a shot with a completed take is marked generated")
        t.check(!preview.rows[1].isGenerated, "and one without is not")
        t.checkEqual(preview.generatedCount, 1, "the generated count is reported")

        // An unplanned project shows nothing rather than an empty frame.
        var empty = FilmProject(title: "Empty")
        empty.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        t.check(AutoMoviePlanPreview.make(project: empty).isEmpty,
                "a project with no shots has no preview")

        // A shot with no summary falls back to its title rather than blank.
        var untitled = plannedProject()
        untitled.shots[0].summary = ""
        t.checkEqual(AutoMoviePlanPreview.make(project: untitled).rows[0].action, "Approach",
                     "a shot with no summary shows its title")
    }

    t.suite("Auto Movie plan preview — previewing starts no generation") {
        // The preview is derived from stored plan data only. It reads the
        // project and touches neither the renderer nor the queue, so opening a
        // project can never begin work.
        var project = plannedProject()
        let before = project
        _ = AutoMoviePlanPreview.make(project: project)
        let after = project
        t.checkEqual(before, after, "building the preview mutates nothing")
        t.check(project.shots.allSatisfy { $0.takes.isEmpty },
                "and creates no takes")
        project.shots[0].takes = []
        t.check(AutoMoviePlanPreview.make(project: project).rows.count == 4,
                "the preview is a pure function of the plan")
    }

    t.suite("Auto Movie plan preview — Action and Camera edits persist to generation") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-plan-edit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilmProjectStore(projectsDirectory: root)
        var project = plannedProject(withOpeningReference: false)
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        let editedShotID = project.shots[0].id
        let originalSecond = project.shots[1]
        let originalContinuity = project.shots[0].continuityMode
        let originalSource = project.shots[0].continuityImageRelativePath
        let originalCharacterIDs = project.shots[0].characterIDs

        let changed = AutoMoviePlanEditor.apply(
            project: &project,
            shotID: editedShotID,
            action: "She raises the flag and looks toward the horizon.",
            shotScale: "close-up",
            angle: "low",
            movement: "slow dolly-in")
        t.check(changed, "a non-empty Action and Camera edit is accepted")
        t.checkEqual(project.shots[0].summary,
                     "She raises the flag and looks toward the horizon.",
                     "the user Action becomes the persisted shot action")
        t.checkEqual(project.shots[0].camera.shotScale, "close-up",
                     "the user Framing becomes the persisted camera scale")
        t.checkEqual(project.shots[0].camera.angle, "low",
                     "the existing camera angle remains a separate editable field")
        t.checkEqual(project.shots[0].camera.movement, "slow dolly-in",
                     "the existing camera movement becomes the persisted value")
        t.check(project.shots[0].compiledPrompt.contains("raises the flag"),
                "the generation-facing compiled prompt receives the edited Action")
        t.check(project.shots[0].compiledPrompt.contains("close-up"),
                "the generation-facing compiled prompt receives the edited Framing")
        t.check(project.shots[0].compiledPrompt.contains("slow dolly-in"),
                "the generation-facing compiled prompt receives the edited movement")

        // Phase A's edit boundary must not be an accidental continuity editor.
        t.checkEqual(project.shots[0].continuityMode, originalContinuity,
                     "Action/Camera edits leave Cut/Continue unchanged")
        t.checkEqual(project.shots[0].continuityImageRelativePath, originalSource,
                     "Action/Camera edits leave the continuity source unchanged")
        t.checkEqual(project.shots[0].characterIDs, originalCharacterIDs,
                     "Action/Camera edits leave CharacterBible references unchanged")
        t.checkEqual(project.shots[1], originalSecond,
                     "an unedited planned shot remains exactly Director-authored")

        // Saving and a fresh store instance prove this is project data, rather
        // than local SwiftUI state. Existing unrelated fields round-trip too.
        store.save(project)
        let reloaded = FilmProjectStore(projectsDirectory: root).project(id: project.id)!
        t.checkEqual(reloaded.shots[0].summary, project.shots[0].summary,
                     "the edited Action survives project reopen")
        t.checkEqual(reloaded.shots[0].camera, project.shots[0].camera,
                     "the edited CameraPlan survives project reopen")
        t.checkEqual(reloaded.shots[0].continuityMode, originalContinuity,
                     "reopen preserves the original Cut/Continue semantics")
        t.checkEqual(reloaded.shots[1], originalSecond,
                     "reopen preserves unrelated planned shots")

        // Take planning is the final boundary before GenerationService. It
        // reads the recompiled prompt, proving this is not preview-only state.
        let requests = try! TakeGenerationCoordinator(store: store).planTakes(
            projectID: project.id, shotID: editedShotID, count: 1, baseSeed: 123)
        t.checkEqual(requests.first?.prompt, project.shots[0].compiledPrompt,
                     "the GenerationRequest uses the edited compiled prompt")
        t.check(requests.first?.prompt.contains("raises the flag") == true,
                "the GenerationRequest contains the edited Action")
        t.check(requests.first?.prompt.contains("slow dolly-in") == true,
                "the GenerationRequest contains the edited Camera movement")
    }

    t.suite("Auto Movie plan preview — invalid edits and new-plan baseline") {
        var project = plannedProject()
        let original = project
        let shotID = project.shots[0].id
        t.check(!AutoMoviePlanEditor.apply(
            project: &project, shotID: shotID,
            action: "   ", shotScale: "wide", angle: "eye-level", movement: "static"),
                "whitespace-only Action is rejected rather than saved as an invalid plan")
        t.checkEqual(project, original, "a rejected edit does not mutate any project data")

        t.check(!AutoMoviePlanEditor.apply(
            project: &project, shotID: shotID,
            action: "Different action", shotScale: "  ", angle: "eye-level", movement: "static"),
                "whitespace-only Camera fields are rejected too")
        t.checkEqual(project, original, "a rejected Camera edit leaves the plan untouched")

        // There is deliberately no in-place plan-regeneration UI: creating a
        // new Auto Movie calls the Director and materializes a new FilmProject.
        // Replacing a plan with that newly materialized baseline necessarily
        // replaces its old shots, so no index-based user-edit migration exists.
        let replacement = plannedProject()
        t.checkEqual(replacement.shots[0].summary,
                     "She walks across the courtyard toward the gate.",
                     "a newly materialized Director plan remains its own baseline")
    }

    t.suite("Auto Movie plan preview — Cut / Continue editing and persistence") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-continuity-edit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilmProjectStore(projectsDirectory: root)
        var project = plannedProject(withOpeningReference: false)
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        let targetID = project.shots[1].id
        let originalPlannedMode = ShotContinuityMode.continueFromPrevious
        project.shots[1].plannedContinuityMode = originalPlannedMode
        project.shots[1].continuityImageRelativePath = "Assets/Continuity/old.png"
        project.shots[1].continuitySourceTakeID = UUID()
        project.shots[1].continuityBlockedReason = .continuityAssetMissing
        project.shots[1].identityRefreshAnchorRelativePath = "Assets/IdentityRefresh/old.png"
        project.shots[1].identityRefreshAnchorOrigin = .generated
        project.shots[1].identityRefreshAnchorSourceShotID = project.shots[0].id
        project.shots[1].identityRefreshSourceTakeID = UUID()
        project.shots[1].identityRefreshNote = "old refresh"

        let historicalTake = Take(
            shotID: targetID, modelID: "m", seed: 7,
            promptSnapshot: "historical", settingsSnapshot: .default,
            requestedWidth: 768, requestedHeight: 512, fps: 24,
            requestedDuration: 5, status: .completed,
            sourceImagePath: "/historical/previous-frame.png")
        project.shots[1].takes = [historicalTake]

        // Phase A remains composable with the new continuity edit.
        t.check(AutoMoviePlanEditor.apply(
            project: &project, shotID: targetID,
            action: "She checks the map before entering.",
            shotScale: "medium-close-up", angle: "high", movement: "tilt down"),
                "Action/Camera editing still applies before a continuity edit")
        t.check(AutoMoviePlanEditor.applyContinuityMode(
            project: &project, shotID: targetID, mode: .cut),
                "Continue can be explicitly changed to Cut")
        t.checkEqual(project.shots[1].continuityMode, .cut,
                     "Cut becomes the persisted effective mode")
        t.checkEqual(project.shots[1].plannedContinuityMode, originalPlannedMode,
                     "the original Director mode remains provenance")
        t.checkEqual(project.shots[1].summary, "She checks the map before entering.",
                     "the Phase A Action edit coexists with Cut")
        t.checkEqual(project.shots[1].camera.movement, "tilt down",
                     "the Phase A Camera edit coexists with Cut")
        t.check(project.shots[1].continuityImageRelativePath == nil,
                "Cut clears the prepared previous-frame path")
        t.check(project.shots[1].continuitySourceTakeID == nil,
                "Cut clears stale previous-Take provenance")
        t.check(project.shots[1].continuityBlockedReason == nil,
                "changing the intent clears an obsolete continuity block")
        t.check(project.shots[1].identityRefreshAnchorRelativePath == nil,
                "Cut clears a continuation-derived refresh anchor")
        t.check(project.shots[1].identityRefreshSourceTakeID == nil,
                "Cut clears refresh provenance derived from the previous Take")
        t.checkEqual(project.shots[1].takes, [historicalTake],
                     "existing Take history is immutable across the plan edit")
        t.checkEqual(AutoMoviePlanPreview.make(project: project).rows[1].sourceDescription,
                     "Text to video", "the preview immediately derives the Cut source")

        store.save(project)
        var reopened = FilmProjectStore(projectsDirectory: root).project(id: project.id)!
        t.checkEqual(reopened.shots[1].continuityMode, .cut,
                     "Continue-to-Cut survives project reopen")
        t.checkEqual(reopened.shots[1].summary, project.shots[1].summary,
                     "reopen also preserves the Phase A Action edit")
        t.check(AutoMoviePlanEditor.applyContinuityMode(
            project: &reopened, shotID: targetID, mode: .continueFromPrevious),
                "Cut can be explicitly changed back to Continue")
        store.save(reopened)
        let continued = FilmProjectStore(projectsDirectory: root).project(id: project.id)!
        t.checkEqual(continued.shots[1].continuityMode, .continueFromPrevious,
                     "Cut-to-Continue survives project reopen")
        t.check(continued.shots[1].continuityImageRelativePath == nil,
                "Continue waits for a fresh previous-Take frame at execution time")
        t.checkEqual(AutoMoviePlanPreview.make(project: continued).rows[1].sourceDescription,
                     "Previous shot's last frame",
                     "the pre-generation preview describes the source Continue will prepare")
    }

    t.suite("Auto Movie plan preview — Shot 1 safety and future-Take history") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-continuity-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilmProjectStore(projectsDirectory: root)
        var project = plannedProject(withOpeningReference: false)
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true

        let untouched = project
        t.check(!AutoMoviePlanEditor.applyContinuityMode(
            project: &project, shotID: project.shots[0].id, mode: .continueFromPrevious),
                "Shot 1 cannot be changed to invalid Continue")
        t.checkEqual(project, untouched, "a rejected Shot 1 edit changes no project state")
        t.check(!AutoMoviePlanEditor.applyContinuityMode(
            project: &project, shotID: project.shots[1].id, mode: .auto),
                "Auto remains a Director state, not a third user-facing option")

        var invalidLegacy = project
        invalidLegacy.shots[0].continuityMode = .continueFromPrevious
        let normalizedPreview = AutoMoviePlanPreview.make(project: invalidLegacy)
        t.checkEqual(normalizedPreview.rows[0].continuityIntent, "Cut",
                     "an invalid persisted Shot 1 Continue is safely displayed as Cut")
        t.checkEqual(AutoMovieRunCoordinator(store: store)
            .resolvedContinuityMode(forShotAt: 0, in: invalidLegacy), .cut,
                     "runtime also normalizes invalid Shot 1 Continue to Cut")

        // Simulate a previously generated I2V Take and stale prepared paths.
        let targetID = project.shots[1].id
        let oldTake = Take(
            shotID: targetID, modelID: "m", seed: 11,
            promptSnapshot: "old", settingsSnapshot: .default,
            requestedWidth: 768, requestedHeight: 512, fps: 24,
            requestedDuration: 5, status: .completed,
            sourceImagePath: "/old/inherited.png")
        project.shots[1].takes = [oldTake]
        project.shots[1].continuityImageRelativePath = "Assets/Continuity/stale.png"
        project.shots[1].identityRefreshAnchorRelativePath = "Assets/IdentityRefresh/stale.png"
        _ = AutoMoviePlanEditor.applyContinuityMode(
            project: &project, shotID: targetID, mode: .cut)
        store.save(project)
        let request = try! TakeGenerationCoordinator(store: store).planTakes(
            projectID: project.id, shotID: targetID, count: 1, baseSeed: 99).first!
        t.check(request.sourceImagePath == nil,
                "the future Cut request cannot leak a stale previous-frame or refresh path")
        let saved = store.project(id: project.id)!
        t.checkEqual(saved.shots[1].takes[0], oldTake,
                     "the existing Take keeps its historical source snapshot")
        t.check(saved.shots[1].takes.last?.sourceImagePath == nil,
                "only the new Take snapshots the edited Cut semantics")
    }

    t.suite("Auto Movie plan preview — Cut preserves an explicit shot source") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-cut-explicit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilmProjectStore(projectsDirectory: root)
        var project = plannedProject(withOpeningReference: false)
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        let characterID = UUID(), assetID = UUID()
        let directory = store.characterAssetsDirectory(projectID: project.id, characterID: characterID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("front.png")
        FileManager.default.createFile(
            atPath: imageURL.path,
            contents: Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z0xkAAAAASUVORK5CYII="))
        var character = BibleCharacter(id: characterID, name: "Maya")
        character.referenceAssets = [CharacterReferenceAsset(
            id: assetID, type: .front,
            projectRelativePath: "Assets/Characters/\(characterID.uuidString)/front.png")]
        project.characterBible.characters = [character]
        project.shots[1].startingImageReferenceAssetID = assetID
        _ = AutoMoviePlanEditor.applyContinuityMode(
            project: &project, shotID: project.shots[1].id, mode: .cut)
        store.save(project)

        let request = try! TakeGenerationCoordinator(store: store).planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 12).first!
        t.check(request.sourceImagePath?.hasSuffix("front.png") == true,
                "Cut disables previous-shot inheritance but preserves an explicit source")
        t.checkEqual(request.parameters.imageStrength, 1.0,
                     "the explicit source keeps its existing exact-first-frame strength")
    }
}
