import Foundation
@testable import LTXVideoGeneratorCore

private final class StubIdentityAssessmentProvider: IdentitySourceAssessmentProviding {
    var assessments: [String: IdentitySourceAssessment]
    private(set) var requestedPaths: [String] = []

    init(_ assessments: [String: IdentitySourceAssessment]) {
        self.assessments = assessments
    }

    func assess(imageData: Data, sourceRelativePath: String) async -> IdentitySourceAssessment {
        requestedPaths.append(sourceRelativePath)
        return assessments[sourceRelativePath]
            ?? IdentitySourceAssessor.unavailable(sourceRelativePath: sourceRelativePath)
    }
}

private final class CountingIdentityAnchorGenerator: IdentityAnchorGenerator {
    private(set) var callCount = 0
    let imageData: Data

    init(imageData: Data) { self.imageData = imageData }

    func generateAnchor(
        fromAnchorImage imageURL: URL,
        targetShot: Shot,
        settings: ProjectSettings
    ) async -> (imageData: Data, framePercent: Int)? {
        callCount += 1
        return (imageData, 80)
    }
}

func runIdentityRefreshTests(_ t: TestKit) {

    func assessment(
        scale: IdentitySourceAssessment.SubjectScale = .medium,
        face: IdentitySourceAssessment.Visibility = .clear,
        orientation: IdentitySourceAssessment.Orientation = .front,
        present: Bool = true,
        status: IdentitySourceAssessment.Status = .assessed
    ) -> IdentitySourceAssessment {
        var a = IdentitySourceAssessment()
        a.status = status
        a.subjectPresent = present
        a.subjectCount = present ? 1 : 0
        a.subjectScale = scale
        a.faceVisibility = face
        a.subjectOrientation = orientation
        a.hairVisibility = face
        a.costumeVisibility = .clear
        return a
    }

    let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z0xkAAAAASUVORK5CYII=")!

    func waitForMainActor(_ semaphore: DispatchSemaphore) {
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    t.suite("Identity refresh — what the next shot needs") {
        for scale in ["close-up", "extreme close-up", "medium-close-up", "closeup"] {
            t.checkEqual(IdentityDetailRequirement.from(shotScale: scale), .faceCritical,
                         "\"\(scale)\" needs facial detail")
        }
        for scale in ["wide", "extreme wide", "wide shot", "establishing", "long shot"] {
            t.checkEqual(IdentityDetailRequirement.from(shotScale: scale), .low,
                         "\"\(scale)\" does not depend on facial detail")
        }
        t.checkEqual(IdentityDetailRequirement.from(shotScale: "medium"), .moderate,
                     "a plain medium shot sits in between")
        t.checkEqual(IdentityDetailRequirement.from(shotScale: "medium-wide"), .low,
                     "medium-wide reads as wide, not as close")
        t.checkEqual(IdentityDetailRequirement.from(shotScale: nil), .moderate,
                     "a missing shot scale is treated conservatively")
    }

    t.suite("Identity refresh — decision policy") {
        // A. good source + close shot → leave it alone. This is the case
        // controlled test D proved already works, so spending a whole
        // generation on it would be waste.
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(scale: .large, face: .clear, orientation: .front),
            hasExplicitStartingImage: false).isRefresh,
                "A: a clear front-on source needs no refresh even for a close-up")

        // B. back-facing + close shot → refresh. The exact production failure.
        t.check(IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(face: .none, orientation: .back),
            hasExplicitStartingImage: false).isRefresh,
                "B: a back-facing source before a close-up triggers a refresh")

        // C. tiny subject + close shot → refresh.
        t.check(IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(scale: .tiny, face: .partial, orientation: .front),
            hasExplicitStartingImage: false).isRefresh,
                "C: a tiny subject before a close-up triggers a refresh")

        // D/E. wide next shot → never refresh, however poor the source.
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .low,
            assessment: assessment(scale: .large, face: .clear),
            hasExplicitStartingImage: false).isRefresh,
                "D: a clear source before a wide shot needs no refresh")
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .low,
            assessment: assessment(scale: .tiny, face: .none, orientation: .back),
            hasExplicitStartingImage: false).isRefresh,
                "E: even a poor source needs no refresh when the next shot is wide")

        // F. medium framing is not close enough to be worth a generation.
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .moderate,
            assessment: assessment(face: .none, orientation: .back),
            hasExplicitStartingImage: false).isRefresh,
                "F: a medium shot does not trigger a refresh on its own")

        // G. the user's own choice always wins.
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(face: .none, orientation: .back),
            hasExplicitStartingImage: true).isRefresh,
                "G: an explicit starting image is never overridden by auto refresh")

        // H. no usable assessment → conservative, do nothing.
        for status: IdentitySourceAssessment.Status in [.unavailable, .failed] {
            t.check(!IdentityRefreshPolicy.decide(
                requirement: .faceCritical,
                assessment: assessment(face: .none, orientation: .back, status: status),
                hasExplicitStartingImage: false).isRefresh,
                    "H: \(status.rawValue) vision leaves continuity alone rather than guessing")
        }
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical, assessment: nil,
            hasExplicitStartingImage: false).isRefresh,
                "H: no assessment at all leaves continuity alone")
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(present: false),
            hasExplicitStartingImage: false).isRefresh,
                "H: a frame with no subject is not refreshed")

        // Small-but-clear is fine; small-and-unclear is not.
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(scale: .small, face: .clear),
            hasExplicitStartingImage: false).isRefresh,
                "a small subject with a clear face is still usable")
        t.check(IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(scale: .small, face: .partial),
            hasExplicitStartingImage: false).isRefresh,
                "a small subject with a partial face is not")
    }

    t.suite("Identity refresh — anchor selection") {
        t.checkEqual(
            IdentityAnchorSelector.select(
                previousRefreshPaths: [], openingReferenceRelativePath: "Assets/OpeningReference/o.png"),
            .openingReference(relativePath: "Assets/OpeningReference/o.png"),
            "C: the opening reference is used when nothing better exists")

        t.checkEqual(
            IdentityAnchorSelector.select(
                previousRefreshPaths: ["Assets/IdentityRefresh/a.png", "Assets/IdentityRefresh/b.png"],
                openingReferenceRelativePath: "Assets/OpeningReference/o.png"),
            .previousRefresh(relativePath: "Assets/IdentityRefresh/b.png"),
            "B: the most recent refresh anchor is preferred over the opening reference")

        t.checkEqual(
            IdentityAnchorSelector.select(previousRefreshPaths: [], openingReferenceRelativePath: nil),
            .none,
            "E: with no anchor at all, selection reports none rather than inventing one")
        t.checkEqual(
            IdentityAnchorSelector.select(previousRefreshPaths: [], openingReferenceRelativePath: ""),
            .none,
            "an empty opening reference path is not an anchor")

        // D. a raw character sheet is never offered as a final scene anchor —
        // it is not part of the selectable set at all.
        let anchors: [IdentityAnchorSelector.Anchor] = [
            .previousRefresh(relativePath: "x"), .openingReference(relativePath: "y"), .none,
        ]
        t.checkEqual(anchors.count, 3,
                     "D: only scene-like anchors are selectable; a character sheet plate is not one")
    }

    t.suite("Identity refresh — scene-compatible existing anchor resolver") {
        let characterID = UUID()
        func shot(
            _ index: Int,
            location: String = "castle courtyard",
            costume: String = "navy-and-white adventurer uniform",
            scale: String = "medium",
            changes: [String] = []
        ) -> Shot {
            var state = ContinuitySnapshot()
            state.location = location
            state.timeOfDay = "sunset"
            state.characterOutfit = ["Maya": costume]
            var value = Shot(
                index: index,
                title: "Shot \(index + 1)",
                summary: "Maya continues the action",
                camera: CameraPlan(shotScale: scale, angle: "eye-level", movement: "static"),
                continuityBefore: state,
                explicitChanges: changes,
                characterIDs: [characterID]
            )
            value.continuityMode = index == 0 ? .cut : .continueFromPrevious
            return value
        }
        let shots = [shot(0), shot(1, scale: "wide"), shot(2, scale: "close-up")]
        let rich = assessment(scale: .medium, face: .clear, orientation: .front)
        let opening = SceneCompatibleIdentityAnchorResolver.Candidate(
            kind: .openingReference,
            relativePath: "Assets/OpeningReference/opening.png",
            assessment: rich,
            referenceShotIndex: 0,
            sourceShotID: nil,
            sourceTakeID: nil
        )

        // A. The proven medium-wide scene still may seed a close-up without a
        // preparation render when the scene and identity evidence remain good.
        if case .reuse(let selected, _) = SceneCompatibleIdentityAnchorResolver.resolve(
            targetShotIndex: 2, shots: shots, candidates: [opening]
        ) {
            t.checkEqual(selected.kind, .openingReference,
                         "A: identity-rich Opening Reference is reused in the same scene")
        } else {
            t.check(false, "A: compatible Opening Reference should be reused")
        }

        // B. An explicit location transition rejects the old scene.
        var moved = shots
        moved[2].continuityBefore?.location = "library interior"
        moved[2].explicitChanges = ["location=library interior"]
        if case .generate(let why) = SceneCompatibleIdentityAnchorResolver.resolve(
            targetShotIndex: 2, shots: moved, candidates: [opening]
        ) {
            t.check(why.contains("location" ) || why.contains("transition"),
                    "B: location rejection records its reason")
        } else { t.check(false, "B: a different location must not reuse the courtyard") }

        // C. A recent generated anchor is equally eligible when it is rich and
        // remains inside the continuity segment.
        var prior = opening
        prior.kind = .previousRefresh
        prior.relativePath = "Assets/IdentityRefresh/prior.png"
        prior.referenceShotIndex = 1
        prior.sourceShotID = shots[1].id
        if case .reuse(let selected, _) = SceneCompatibleIdentityAnchorResolver.resolve(
            targetShotIndex: 2, shots: shots, candidates: [prior, opening]
        ) {
            t.checkEqual(selected.kind, .previousRefresh,
                         "C: recent generated anchor is reusable in the same scene")
        } else { t.check(false, "C: prior refresh should be selected") }

        // D/E. Identity-poor and stale images are rejected independently.
        var poor = opening
        poor.assessment = assessment(scale: .small, face: .none, orientation: .back)
        if case .generate = SceneCompatibleIdentityAnchorResolver.resolve(
            targetShotIndex: 2, shots: shots, candidates: [poor]
        ) { t.check(true, "D: identity-poor candidate is rejected") }
        else { t.check(false, "D: identity-poor candidate was reused") }
        var stale = opening
        stale.isStale = true
        if case .generate = SceneCompatibleIdentityAnchorResolver.resolve(
            targetShotIndex: 2, shots: shots, candidates: [stale]
        ) { t.check(true, "E: stale candidate is rejected") }
        else { t.check(false, "E: stale candidate was reused") }

        // Intentional wardrobe and character transformations are story truth;
        // ordinary camera and action edits are deliberately irrelevant.
        var wardrobe = shots
        wardrobe[2].explicitChanges = ["wardrobe=red ceremonial cloak"]
        if case .generate = SceneCompatibleIdentityAnchorResolver.resolve(
            targetShotIndex: 2, shots: wardrobe, candidates: [opening]
        ) { t.check(true, "wardrobe transition rejects the old outfit anchor") }
        else { t.check(false, "wardrobe transition was ignored") }

        var realDirectorWardrobe = shots
        realDirectorWardrobe[2].explicitChanges = [
            "outfit:\(characterID.uuidString)=red ceremonial cloak",
        ]
        if case .generate = SceneCompatibleIdentityAnchorResolver.resolve(
            targetShotIndex: 2, shots: realDirectorWardrobe, candidates: [opening]
        ) { t.check(true, "Director outfit directive rejects the old outfit anchor") }
        else { t.check(false, "Director outfit directive was ignored") }

        var transformed = shots
        transformed[2].explicitChanges = ["transformation=turned to stone"]
        if case .generate = SceneCompatibleIdentityAnchorResolver.resolve(
            targetShotIndex: 2, shots: transformed, candidates: [opening]
        ) { t.check(true, "major character transformation rejects the old state") }
        else { t.check(false, "character transformation was ignored") }

        var ordinary = shots
        ordinary[2].summary = "Maya raises the compass and smiles"
        ordinary[2].camera = CameraPlan(
            shotScale: "extreme-close-up", angle: "low", movement: "fast push-in")
        if case .reuse = SceneCompatibleIdentityAnchorResolver.resolve(
            targetShotIndex: 2, shots: ordinary, candidates: [opening]
        ) { t.check(true, "ordinary camera/action changes still allow reuse") }
        else { t.check(false, "camera/action change incorrectly forced generation") }
    }

    t.suite("Identity refresh — zero-generation production preparation") {
        func makeStore(_ suffix: String) -> (FilmProjectStore, URL) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LTXTests-idreuse-\(suffix)-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return (FilmProjectStore(projectsDirectory: root), root)
        }

        func makeProject(store: FilmProjectStore, openingAssessment: OpeningReferenceAppearance?) -> FilmProject {
            let characterID = UUID()
            var project = FilmProject(title: "Forced refresh fixture")
            project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
            project.continuityChainEnabled = true
            let openingPath = "Assets/OpeningReference/opening.png"
            let continuityPath = "Assets/Continuity/source-before-02.png"
            project.openingReferenceImage = OpeningReferenceImage(
                projectRelativePath: openingPath, originalFilename: "opening.png")
            project.openingReferenceAppearance = openingAssessment
            var state = ContinuitySnapshot()
            state.location = "castle courtyard"
            state.timeOfDay = "sunset"
            state.characterOutfit = ["Maya": "navy-and-white adventurer uniform"]
            var first = Shot(
                index: 0, title: "Opening", summary: "Maya enters the courtyard",
                camera: CameraPlan(shotScale: "medium", angle: "eye-level", movement: "static"),
                continuityBefore: state, characterIDs: [characterID]
            )
            first.continuityMode = .cut
            var target = Shot(
                index: 1, title: "Close", summary: "Maya looks over her shoulder",
                camera: CameraPlan(shotScale: "close-up", angle: "eye-level", movement: "push-in"),
                continuityBefore: state, characterIDs: [characterID]
            )
            target.continuityMode = .continueFromPrevious
            target.continuityImageRelativePath = continuityPath
            project.shots = [first, target]
            store.save(project)
            for path in [openingPath, continuityPath] {
                if let url = store.managedProjectAssetURL(projectID: project.id, relativePath: path) {
                    try? FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? onePixelPNG.write(to: url)
                }
            }
            return project
        }

        var cachedOpening = OpeningReferenceAppearance()
        cachedOpening.status = .analysed
        cachedOpening.sourceRelativePath = "Assets/OpeningReference/opening.png"
        cachedOpening.faceVisible = true
        cachedOpening.subjectCount = 1
        cachedOpening.hairDescription = "brown ponytail"
        cachedOpening.clothingDescription = "navy-and-white adventurer uniform"
        cachedOpening.analysisModel = "cached-local-vision"

        // H/F: real service persistence → TakeGenerationCoordinator source
        // precedence, with a generator spy proving no preparation render.
        let (reuseStore, reuseRoot) = makeStore("reuse")
        defer { try? FileManager.default.removeItem(at: reuseRoot) }
        let reuseProject = makeProject(store: reuseStore, openingAssessment: cachedOpening)
        let poorContinuity = assessment(scale: .tiny, face: .none, orientation: .back)
        let reuseAssessor = StubIdentityAssessmentProvider([
            "Assets/Continuity/source-before-02.png": poorContinuity,
        ])
        let skippedGenerator = CountingIdentityAnchorGenerator(imageData: onePixelPNG)
        let reuseDone = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let outcome = await IdentityRefreshService.prepareIfNeeded(
                projectID: reuseProject.id,
                shotIndex: 1,
                store: reuseStore,
                generator: skippedGenerator,
                assessor: reuseAssessor
            )
            if case .refreshed(let path, _) = outcome {
                t.checkEqual(path, "Assets/OpeningReference/opening.png",
                             "H: service reuses the expected Opening Reference path")
            } else { t.check(false, "H: service did not reuse the Opening Reference") }
            t.checkEqual(skippedGenerator.callCount, 0,
                         "H: suitable existing anchor costs zero generator calls")
            let saved = reuseStore.project(id: reuseProject.id)!
            t.checkEqual(saved.shots[1].identityRefreshAnchorOrigin, .reusedOpeningReference,
                         "reuse origin is persisted")
            let requests = try? TakeGenerationCoordinator(store: reuseStore).planTakes(
                projectID: saved.id, shotID: saved.shots[1].id, count: 1, baseSeed: 42)
            t.check(requests?.first?.sourceImagePath?.contains("OpeningReference/opening.png") == true,
                    "Shot request actually uses the reused managed image")
            reuseDone.signal()
        }
        waitForMainActor(reuseDone)

        // G: when the only candidate lacks identity information, the existing
        // LTX generator boundary is invoked exactly once and persists output.
        let (generateStore, generateRoot) = makeStore("generate")
        defer { try? FileManager.default.removeItem(at: generateRoot) }
        let generateProject = makeProject(store: generateStore, openingAssessment: nil)
        let generateAssessor = StubIdentityAssessmentProvider([
            "Assets/Continuity/source-before-02.png": poorContinuity,
            "Assets/OpeningReference/opening.png": poorContinuity,
        ])
        let invokedGenerator = CountingIdentityAnchorGenerator(imageData: onePixelPNG)
        let generateDone = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let outcome = await IdentityRefreshService.prepareIfNeeded(
                projectID: generateProject.id,
                shotIndex: 1,
                store: generateStore,
                generator: invokedGenerator,
                assessor: generateAssessor
            )
            if case .refreshed = outcome { t.check(true, "G: generated fallback completes") }
            else { t.check(false, "G: generated fallback did not complete") }
            t.checkEqual(invokedGenerator.callCount, 1,
                         "G: no suitable anchor invokes the generator exactly once")
            t.checkEqual(generateStore.project(id: generateProject.id)?
                .shots[1].identityRefreshAnchorOrigin, .generated,
                "generated fallback origin is persisted")
            generateDone.signal()
        }
        waitForMainActor(generateDone)
    }

    t.suite("Identity refresh — assessment parsing") {
        let good = """
        {"subjectPresent":true,"subjectCount":1,"subjectScale":"tiny",
         "faceVisibility":"none","hairVisibility":"partial",
         "costumeVisibility":"clear","subjectOrientation":"back"}
        """
        let parsed = IdentitySourceAssessor.assessment(
            fromResponse: good, sourceRelativePath: "p.png", model: "m")
        t.checkEqual(parsed.status, .assessed, "a well-formed answer is assessed")
        t.checkEqual(parsed.subjectScale, .tiny, "scale is read")
        t.checkEqual(parsed.faceVisibility, .none, "face visibility is read")
        t.checkEqual(parsed.subjectOrientation, .back, "orientation is read")
        t.check(IdentityRefreshPolicy.decide(
            requirement: .faceCritical, assessment: parsed,
            hasExplicitStartingImage: false).isRefresh,
                "and that assessment drives a refresh, end to end")

        t.checkEqual(
            IdentitySourceAssessor.assessment(
                fromResponse: "sorry", sourceRelativePath: "p.png", model: "m").status,
            .failed, "a non-JSON answer fails safely")
        t.checkEqual(
            IdentitySourceAssessor.unavailable(sourceRelativePath: "p.png").status,
            .unavailable, "unavailable is a status rather than an error")

        // Unknown enum values must degrade, not crash or silently become risky.
        let odd = """
        {"subjectPresent":true,"subjectCount":1,"subjectScale":"gigantic",
         "faceVisibility":"maybe","hairVisibility":"clear",
         "costumeVisibility":"clear","subjectOrientation":"upside-down"}
        """
        let degraded = IdentitySourceAssessor.assessment(
            fromResponse: odd, sourceRelativePath: "p.png", model: "m")
        t.checkEqual(degraded.subjectScale, .unknown, "an unknown scale becomes unknown")
        t.checkEqual(degraded.faceVisibility, .unknown, "an unknown visibility becomes unknown")
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical, assessment: degraded,
            hasExplicitStartingImage: false).isRefresh,
                "unknown values do not trigger a refresh — ambiguity stays conservative")
    }

    t.suite("Identity refresh — persistence and staleness") {
        var project = FilmProject(title: "M")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        var shot1 = Shot(index: 0, title: "One")
        let take = Take(shotID: shot1.id, modelID: "m", seed: 1,
                        promptSnapshot: "p", settingsSnapshot: .default,
                        requestedWidth: 768, requestedHeight: 512,
                        fps: 24, requestedDuration: 5, status: .completed)
        shot1.takes = [take]
        shot1.selectedTakeID = take.id
        var shot2 = Shot(index: 1, title: "Two")
        shot2.identityRefreshAnchorRelativePath = "Assets/IdentityRefresh/shot-002-x.png"
        shot2.identityRefreshAnchorOrigin = .generated
        shot2.identityRefreshSourceTakeID = take.id
        shot2.continuitySourceTakeID = take.id
        shot2.identityRefreshNote = "Identity Refresh: applied"
        project.shots = [shot1, shot2]

        // A/B. round trip.
        let data = try! JSONEncoder().encode(project)
        let decoded = try! JSONDecoder().decode(FilmProject.self, from: data)
        t.checkEqual(decoded.shots[1].identityRefreshAnchorRelativePath,
                     "Assets/IdentityRefresh/shot-002-x.png",
                     "A/B: the refresh anchor survives a save and reload")
        t.checkEqual(decoded.shots[1].identityRefreshSourceTakeID, take.id,
                     "and remembers which take it was derived from")
        t.checkEqual(decoded.shots[1].identityRefreshAnchorOrigin, .generated,
                     "and records that it was generated")

        // C/D. a retake upstream makes the anchor stale.
        var retaken = decoded
        let newTake = Take(shotID: retaken.shots[0].id, modelID: "m", seed: 2,
                           promptSnapshot: "p", settingsSnapshot: .default,
                           requestedWidth: 768, requestedHeight: 512,
                           fps: 24, requestedDuration: 5, status: .completed)
        retaken.shots[0].takes = [newTake]
        retaken.shots[0].selectedTakeID = newTake.id
        retaken.shots[1].continuitySourceTakeID = newTake.id
        IdentityRefreshService.invalidateStaleAnchor(shotIndex: 1, in: &retaken)
        t.check(retaken.shots[1].identityRefreshAnchorRelativePath == nil,
                "C/D: a retake upstream invalidates the dependent refresh anchor")
        t.check(retaken.shots[1].identityRefreshNote == nil,
                "and clears its note, so no stale explanation is shown")

        // An unchanged take keeps the anchor.
        var unchanged = decoded
        IdentityRefreshService.invalidateStaleAnchor(shotIndex: 1, in: &unchanged)
        t.checkEqual(unchanged.shots[1].identityRefreshAnchorRelativePath,
                     "Assets/IdentityRefresh/shot-002-x.png",
                     "an anchor from the current take is kept")

        // A later shot may reuse the generated anchor without changing its
        // root dependency. Retaking that root invalidates the reuse chain too.
        var chained = decoded
        var shot3 = Shot(index: 2, title: "Three")
        shot3.identityRefreshAnchorRelativePath = "Assets/IdentityRefresh/shot-002-x.png"
        shot3.identityRefreshAnchorOrigin = .reusedPriorRefresh
        shot3.identityRefreshAnchorSourceShotID = chained.shots[1].id
        shot3.identityRefreshSourceTakeID = take.id
        chained.shots.append(shot3)
        IdentityRefreshService.invalidateStaleAnchor(shotIndex: 2, in: &chained)
        t.checkEqual(chained.shots[2].identityRefreshAnchorRelativePath,
                     "Assets/IdentityRefresh/shot-002-x.png",
                     "a prior generated anchor remains reusable while its root take is current")
        chained.shots[0].takes = [newTake]
        chained.shots[0].selectedTakeID = newTake.id
        chained.shots[1].continuitySourceTakeID = newTake.id
        IdentityRefreshService.invalidateStaleAnchor(shotIndex: 2, in: &chained)
        t.check(chained.shots[2].identityRefreshAnchorRelativePath == nil,
                "a retake at the root invalidates a later reused-anchor chain")

        // Opening Reference reuse is independent of upstream takes, but Replace
        // and Clear must invalidate the old path immediately.
        var openingReuse = FilmProject(title: "Opening reuse")
        openingReuse.openingReferenceImage = OpeningReferenceImage(
            projectRelativePath: "Assets/OpeningReference/old.png")
        var openingTarget = Shot(index: 1, title: "Close")
        openingTarget.identityRefreshAnchorRelativePath = "Assets/OpeningReference/old.png"
        openingTarget.identityRefreshAnchorOrigin = .reusedOpeningReference
        openingReuse.shots = [Shot(index: 0, title: "Open"), openingTarget]
        openingReuse.openingReferenceImage = OpeningReferenceImage(
            projectRelativePath: "Assets/OpeningReference/new.png")
        IdentityRefreshService.invalidateOpeningReferenceAnchors(in: &openingReuse)
        t.check(openingReuse.shots[1].identityRefreshAnchorRelativePath == nil,
                "Replace invalidates a refresh that reused the superseded Opening Reference")

        // F. legacy projects decode with no refresh state.
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        var shots = object["shots"] as! [[String: Any]]
        shots[1].removeValue(forKey: "identityRefreshAnchorRelativePath")
        shots[1].removeValue(forKey: "identityRefreshAnchorOrigin")
        shots[1].removeValue(forKey: "identityRefreshAnchorSourceShotID")
        shots[1].removeValue(forKey: "identityRefreshSourceTakeID")
        shots[1].removeValue(forKey: "identityRefreshNote")
        object["shots"] = shots
        let legacy = try! JSONDecoder().decode(
            FilmProject.self, from: try! JSONSerialization.data(withJSONObject: object))
        t.check(legacy.shots[1].identityRefreshAnchorRelativePath == nil,
                "F: a project written before this feature decodes with no anchor")
        t.checkEqual(legacy.shots.count, 2, "and is otherwise intact")
    }

    t.suite("Identity refresh — an edited Cut never enters refresh") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-refresh-cut-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilmProjectStore(projectsDirectory: root)
        var project = FilmProject(title: "Cut refresh guard")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        var first = Shot(index: 0, title: "Opening")
        first.continuityMode = .cut
        var second = Shot(
            index: 1, title: "Close", summary: "Maya looks toward camera",
            camera: CameraPlan(shotScale: "close-up", angle: "eye-level", movement: "static"))
        second.continuityMode = .cut
        second.continuityImageRelativePath = "Assets/Continuity/stale.png"
        project.shots = [first, second]
        store.save(project)

        let assessor = StubIdentityAssessmentProvider([:])
        let generator = CountingIdentityAnchorGenerator(imageData: onePixelPNG)
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let outcome = await IdentityRefreshService.prepareIfNeeded(
                projectID: project.id, shotIndex: 1, store: store,
                generator: generator, assessor: assessor)
            if case .notNeeded(let reason) = outcome {
                t.check(reason.contains("Cut"),
                        "the service records why continuation refresh is not applicable")
            } else {
                t.check(false, "an edited Cut must not prepare Identity Refresh: \(outcome)")
            }
            t.checkEqual(assessor.requestedPaths.count, 0,
                         "Cut performs no continuation-frame assessment")
            t.checkEqual(generator.callCount, 0,
                         "Cut performs no Identity Refresh generation")
            done.signal()
        }
        waitForMainActor(done)
    }

    t.suite("Identity refresh — the generator is a transformation, not a continuation") {
        var shot = Shot(index: 2, title: "Closer")
        shot.camera = CameraPlan(shotScale: "medium-close-up", angle: "eye-level", movement: "slow push-in")
        let prompt = LTXTemporalRefreshGenerator.prompt(for: shot)
        t.check(prompt.contains("medium-close-up"),
                "the refresh prompt asks for the target framing")
        t.check(prompt.lowercased().contains("face becomes clearly visible"),
                "and explicitly asks for the face the next shot needs")
        t.check(!prompt.contains(ContinuationPromptPolicy.continuityStatement),
                "it does not use the CONTINUE policy: preserving the state is the opposite of the goal (D-073)")
        for banned in ["face lock", "identity lock", "guaranteed"] {
            t.check(!prompt.lowercased().contains(banned),
                    "the refresh prompt makes no '\(banned)' claim")
        }
        t.checkEqual(LTXTemporalRefreshGenerator.frameCount, 49,
                     "the preparation clip uses a valid 8n+1 frame count")
        t.check(LTXTemporalRefreshGenerator.frameCount % 8 == 1,
                "49 is 8n+1, which this backend requires")
        t.checkEqual(LTXTemporalRefreshGenerator.preferredPercent, 80,
                     "the anchor frame is taken from part-way through, not the end")
    }
}
