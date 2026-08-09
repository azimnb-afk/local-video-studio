import Foundation
@testable import LTXVideoGeneratorCore

/// Adaptive Continuity Strength: how hard an inherited frame holds, decided
/// after the cut/continue question is already settled. Framing intent selects
/// the policy; angle and movement never do; and no non-Auto-Movie surface is
/// affected.
func runAdaptiveContinuityStrengthTests(_ t: TestKit) {

    func shot(
        _ index: Int,
        scale: String,
        angle: String = "eye-level",
        movement: String = "static",
        summary: String = "She moves through the scene.",
        composition: String = ""
    ) -> Shot {
        var s = Shot(index: index, title: "Shot \(index + 1)", summary: summary)
        s.camera = CameraPlan(shotScale: scale, angle: angle, movement: movement,
                              composition: composition)
        return s
    }

    t.suite("Adaptive continuity strength — policy selection") {
        // A. A modest step keeps the standard anchor.
        t.checkEqual(ContinuityStrengthResolver.policy(previous: shot(0, scale: "wide"),
                                                       current: shot(1, scale: "medium-wide")),
                     .standard, "A: wide → medium-wide is a standard continuation")
        t.checkEqual(ContinuityStrengthResolver.policy(previous: shot(0, scale: "medium"),
                                                       current: shot(1, scale: "medium-close-up")),
                     .standard, "A: medium → medium-close-up is standard")

        // B/C. A large framing jump asks for the looser anchor.
        t.checkEqual(ContinuityStrengthResolver.policy(previous: shot(0, scale: "wide"),
                                                       current: shot(1, scale: "close-up")),
                     .reframe, "C: wide → close-up is a reframe")
        t.checkEqual(ContinuityStrengthResolver.policy(previous: shot(0, scale: "medium-wide"),
                                                       current: shot(1, scale: "extreme-close-up")),
                     .reframe, "B: medium-wide → extreme-close-up is a reframe")
        // Pulling far back is the same size of change.
        t.checkEqual(ContinuityStrengthResolver.policy(previous: shot(0, scale: "close-up"),
                                                       current: shot(1, scale: "wide")),
                     .reframe, "a large pull-back is also a reframe")

        // D/E. Angle and movement alone never change the policy — they do not
        // change how much of the subject fills the frame.
        t.checkEqual(ContinuityStrengthResolver.policy(
            previous: shot(0, scale: "medium", angle: "eye-level"),
            current: shot(1, scale: "medium", angle: "low")),
                     .standard, "D: an angle change alone stays standard")
        t.checkEqual(ContinuityStrengthResolver.policy(
            previous: shot(0, scale: "medium", movement: "dolly"),
            current: shot(1, scale: "medium", movement: "static")),
                     .standard, "E: a movement change alone stays standard")

        // Vocabulary handling: the ladder is the Director's own, and unseen
        // spellings degrade sensibly rather than throwing.
        t.checkEqual(ContinuityStrengthResolver.rank(ofScale: "extreme-wide"), 0, "ladder starts wide")
        t.checkEqual(ContinuityStrengthResolver.rank(ofScale: "extreme-close-up"), 6, "ladder ends tight")
        t.checkEqual(ContinuityStrengthResolver.rank(ofScale: "Medium Close Up"), 4,
                     "spacing and capitalisation are normalised")
        t.check(ContinuityStrengthResolver.rank(ofScale: "bird's eye") == nil,
                "an unknown scale has no rank")

        // Unknown vocabulary falls back to what the shot says it shows.
        let unknownToDetail = ContinuityStrengthResolver.policy(
            previous: shot(0, scale: "establishing"),
            current: shot(1, scale: "insert", summary: "Extreme close-up of the key in the lock.")
        )
        t.checkEqual(unknownToDetail, .reframe, "an unrecognised detail insert is a reframe")
        let unknownToUnknown = ContinuityStrengthResolver.policy(
            previous: shot(0, scale: "establishing"),
            current: shot(1, scale: "establishing")
        )
        t.checkEqual(unknownToUnknown, .standard, "unknown but undramatic stays standard")

        t.check(ContinuityStrengthResolver.isDetailInsert(shot(0, scale: "extreme-close-up")),
                "an extreme close-up counts as a detail insert")
        t.check(!ContinuityStrengthResolver.isDetailInsert(shot(0, scale: "medium")),
                "a medium shot is not a detail insert")
    }

    t.suite("Adaptive continuity strength — resolved values") {
        // M. Standard remains exactly the previously calibrated value.
        t.checkEqual(ContinuityStrengthResolver.strength(for: .standard), 0.8,
                     "M: standard continuity is still 0.8")
        t.checkEqual(AutoMovieRunCoordinator.continuityImageStrength, 0.8,
                     "M: the standard constant is unchanged")
        // The reframe value is looser but still well clear of the coherence
        // floor observed during calibration.
        let reframe = ContinuityStrengthResolver.strength(for: .reframe)
        t.checkEqual(reframe, 0.5, "reframe uses the measured practical value")
        t.check(reframe < 0.8, "reframe is looser than standard")
        t.check(reframe > 0.35, "reframe stays above the level where coherence broke down")

        let explanation = ContinuityStrengthResolver.explanation(
            previous: shot(0, scale: "medium-wide"), current: shot(1, scale: "extreme-close-up"),
            policy: .reframe)
        t.check(explanation.contains("medium-wide") && explanation.contains("extreme-close-up"),
                "the explanation names the framing change")
    }

    t.suite("Adaptive continuity strength — scope isolation") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-adaptive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fixture = "/tmp/ltx_baseline/T2V-A-ON.mp4"
        let hasFixture = FileManager.default.fileExists(atPath: fixture)
            && FinalAssemblyService.ffmpegPath() != nil

        func makeStore(_ name: String) -> FilmProjectStore {
            FilmProjectStore(projectsDirectory: tmp.appendingPathComponent(name, isDirectory: true))
        }

        /// Auto Movie project whose second shot is a large reframe.
        func makeProject(store: FilmProjectStore, secondScale: String,
                         workflowMode: String? = AutoMovieRunCoordinator.autoMovieWorkflowMode) -> FilmProject {
            var project = FilmProject(title: "Adaptive")
            project.workflowMode = workflowMode
            project.continuityChainEnabled = true
            var first = shot(0, scale: "medium-wide")
            first.compiledPrompt = "p1"
            first.durationSeconds = 1
            first.continuityMode = .cut
            var second = shot(1, scale: secondScale)
            second.compiledPrompt = "p2"
            second.durationSeconds = 1
            second.continuityMode = .continueFromPrevious
            project.shots = [first, second]
            store.save(project)
            return store.project(id: project.id)!
        }

        func completeFirstShot(store: FilmProjectStore, projectID: UUID) {
            var project = store.project(id: projectID)!
            var take = Take(shotID: project.shots[0].id, modelID: "m", seed: 1,
                            promptSnapshot: "p", settingsSnapshot: .default,
                            requestedWidth: 512, requestedHeight: 320, fps: 24,
                            requestedDuration: 1, status: .completed)
            take.outputPath = fixture
            take.generationCompletedAt = Date()
            project.shots[0].takes.append(take)
            store.save(project)
        }

        guard hasFixture else {
            t.check(true, "fixture video unavailable — wiring checks skipped")
            return
        }

        // A reframing continuation renders with the looser anchor.
        let reframeStore = makeStore("reframe")
        let reframeProject = makeProject(store: reframeStore, secondScale: "extreme-close-up")
        completeFirstShot(store: reframeStore, projectID: reframeProject.id)
        var pending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: reframeStore)
            .advance(projectID: reframeProject.id) { pending = $0 }
        t.check(pending.first?.sourceImagePath != nil, "the reframing shot still inherits a frame")
        t.checkEqual(pending.first?.parameters.imageStrength, 0.5,
                     "B: a reframing continuation uses the looser strength")

        // An ordinary continuation keeps 0.8.
        let standardStore = makeStore("standard")
        let standardProject = makeProject(store: standardStore, secondScale: "medium")
        completeFirstShot(store: standardStore, projectID: standardProject.id)
        var standardPending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: standardStore)
            .advance(projectID: standardProject.id) { standardPending = $0 }
        t.checkEqual(standardPending.first?.parameters.imageStrength, 0.8,
                     "A: an ordinary continuation keeps the standard strength")

        // F. A cut inherits nothing and gets no adaptive strength.
        let cutStore = makeStore("cut")
        var cutProject = makeProject(store: cutStore, secondScale: "extreme-close-up")
        cutProject.shots[1].continuityMode = .cut
        cutStore.save(cutProject)
        completeFirstShot(store: cutStore, projectID: cutProject.id)
        var cutPending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: cutStore).advance(projectID: cutProject.id) { cutPending = $0 }
        t.check(cutPending.first?.sourceImagePath == nil, "F: a cut inherits no image")
        t.checkEqual(cutPending.first?.parameters.imageStrength, 1.0,
                     "F: a cut keeps the default strength")

        // G. The first shot is never adapted.
        let firstStore = makeStore("first")
        let firstProject = makeProject(store: firstStore, secondScale: "extreme-close-up")
        var firstPending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: firstStore).advance(projectID: firstProject.id) { firstPending = $0 }
        t.checkEqual(firstPending.first?.parameters.imageStrength, 1.0,
                     "G: the first shot keeps the default strength")

        // H/K/L. An explicit starting image wins and keeps exact-first-frame.
        let explicitStore = makeStore("explicit")
        var explicitProject = makeProject(store: explicitStore, secondScale: "extreme-close-up")
        let characterID = UUID()
        var character = BibleCharacter(id: characterID, name: "Mika")
        let assetID = UUID()
        let assets = explicitStore.characterAssetsDirectory(projectID: explicitProject.id,
                                                           characterID: characterID)
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: assets.appendingPathComponent("front.png").path,
            contents: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        character.referenceAssets = [CharacterReferenceAsset(
            id: assetID, type: .front,
            projectRelativePath: "Assets/Characters/\(characterID.uuidString)/front.png")]
        explicitProject.characterBible.characters = [character]
        explicitProject.shots[1].startingImageReferenceAssetID = assetID
        explicitStore.save(explicitProject)
        completeFirstShot(store: explicitStore, projectID: explicitProject.id)
        var explicitPending: [GenerationRequest] = []
        _ = AutoMovieRunCoordinator(store: explicitStore)
            .advance(projectID: explicitProject.id) { explicitPending = $0 }
        t.check(explicitPending.first?.sourceImagePath?.hasSuffix("front.png") == true,
                "H: the explicit starting image still wins")
        t.checkEqual(explicitPending.first?.parameters.imageStrength, 1.0,
                     "H/K/L: an explicit starting image keeps exact-first-frame strength")

        // J. Storyboard is untouched: it never routes through the Auto Movie
        // coordinator, and its manual takes keep the default strength.
        let storyStore = makeStore("storyboard")
        let storyProject = makeProject(store: storyStore, secondScale: "extreme-close-up",
                                       workflowMode: nil)
        do {
            let requests = try TakeGenerationCoordinator(store: storyStore)
                .planTakes(projectID: storyProject.id, shotID: storyProject.shots[1].id, count: 1)
            t.checkEqual(requests.first?.parameters.imageStrength, 1.0,
                         "J: a storyboard shot keeps the default strength")
        } catch {
            t.check(false, "J: storyboard planTakes threw \(error)")
        }

        // I. Generate / One Shot build requests from the shared defaults.
        t.checkEqual(GenerationParameters.default.imageStrength, 1.0,
                     "I: Generate and One Shot defaults are unchanged")

        // N. A reconciled promotion still resolves a strength policy.
        let reconciled = ContinuityReconciler.reconcile(shots: [
            shot(0, scale: "medium-wide"), shot(1, scale: "extreme-close-up"),
        ])
        t.checkEqual(ContinuityStrengthResolver.policy(previous: reconciled[0], current: reconciled[1]),
                     .reframe, "N: a reconciled boundary still classifies its framing change")

        // P. Old projects decode unchanged; no schema was added for this.
        let legacy = """
        {"id":"\(UUID().uuidString)","index":1,"title":"Legacy","summary":"s",
         "durationSeconds":5,"compiledPrompt":"p"}
        """.data(using: .utf8)!
        do {
            let decoded = try JSONDecoder().decode(Shot.self, from: legacy)
            t.checkEqual(decoded.camera.shotScale, "medium", "P: legacy shot keeps its default camera plan")
        } catch {
            t.check(false, "P: legacy shot failed to decode: \(error)")
        }
    }
}
