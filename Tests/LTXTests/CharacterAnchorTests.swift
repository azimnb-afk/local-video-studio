import Foundation
@testable import LTXVideoGeneratorCore

/// Auto Movie Character Anchor: an optional protagonist reference that
/// conditions the **opening shot only**. Every later shot must keep inheriting
/// from the shot before it — the reference is never re-injected.
func runCharacterAnchorTests(_ t: TestKit) {

    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-anchor-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    func makeStore(_ name: String) -> FilmProjectStore {
        FilmProjectStore(projectsDirectory: tmpRoot.appendingPathComponent(name, isDirectory: true))
    }

    let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Project with `shotCount` shots, a character carrying front + face
    /// references on disk, and the anchor left disabled.
    @discardableResult
    func makeProject(
        store: FilmProjectStore,
        shotCount: Int = 3,
        writeFiles: Bool = true
    ) -> (project: FilmProject, characterID: UUID, frontID: UUID, faceID: UUID) {
        var project = FilmProject(title: "Anchor Test")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        for index in 0..<shotCount {
            var shot = Shot(index: index, title: "Shot \(index + 1)", summary: "beat \(index + 1)")
            shot.compiledPrompt = "A woman walks toward an old stone library, beat \(index + 1)."
            shot.durationSeconds = 1
            shot.continuityMode = index == 0 ? .cut : .continueFromPrevious
            project.shots.append(shot)
        }

        let characterID = UUID()
        var character = BibleCharacter(id: characterID, name: "Mika")
        let assetsDir = store.characterAssetsDirectory(projectID: project.id, characterID: characterID)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let frontID = UUID(), faceID = UUID()
        if writeFiles {
            FileManager.default.createFile(
                atPath: assetsDir.appendingPathComponent("front.png").path, contents: pngMagic)
            FileManager.default.createFile(
                atPath: assetsDir.appendingPathComponent("face.png").path, contents: pngMagic)
        }
        let base = "Assets/Characters/\(characterID.uuidString)"
        character.referenceAssets = [
            // Deliberately out of preference order so the resolver's ordering is
            // actually exercised rather than accidentally satisfied.
            CharacterReferenceAsset(id: faceID, type: .face,
                                    projectRelativePath: "\(base)/face.png"),
            CharacterReferenceAsset(id: frontID, type: .front,
                                    projectRelativePath: "\(base)/front.png"),
        ]
        project.characterBible.characters = [character]
        store.save(project)
        return (project, characterID, frontID, faceID)
    }

    func enableAnchor(
        store: FilmProjectStore, projectID: UUID, characterID: UUID, assetID: UUID
    ) {
        guard var project = store.project(id: projectID) else { return }
        project.characterAnchor.isEnabled = true
        project.characterAnchor.characterID = characterID
        project.characterAnchor.referenceAssetID = assetID
        store.save(project)
    }

    t.suite("Character Anchor — opening shot source") {
        // A. Disabled leaves the opening exactly as it was: text-to-video.
        let offStore = makeStore("off")
        let off = makeProject(store: offStore)
        let offCoordinator = TakeGenerationCoordinator(store: offStore)
        let offRequests = try? offCoordinator.planTakes(
            projectID: off.project.id, shotID: off.project.shots[0].id, count: 1, baseSeed: 1)
        t.check(offRequests?.first?.sourceImagePath == nil,
                "A: anchor disabled leaves the opening shot as text-to-video")

        // B. Enabled puts the chosen reference on shot 1.
        let store = makeStore("on")
        let made = makeProject(store: store)
        enableAnchor(store: store, projectID: made.project.id,
                     characterID: made.characterID, assetID: made.frontID)
        let coordinator = TakeGenerationCoordinator(store: store)
        let opening = try? coordinator.planTakes(
            projectID: made.project.id, shotID: made.project.shots[0].id, count: 1, baseSeed: 1)
        t.check(opening?.first?.sourceImagePath?.hasSuffix("front.png") == true,
                "B: the opening shot conditions on the anchored reference")
        t.checkEqual(opening?.first?.parameters.imageStrength,
                     CharacterAnchorPolicy.openingImageStrength,
                     "B: the opening uses the character anchor strength")

        // C/D. THE CRITICAL REGRESSION — shot 2 must not see the reference. It
        //      has no inherited frame yet, so it must be text-to-video, never
        //      the character sheet again.
        let second = try? coordinator.planTakes(
            projectID: made.project.id, shotID: made.project.shots[1].id, count: 1, baseSeed: 2)
        t.check(second?.first?.sourceImagePath == nil,
                "C: shot 2 never receives the character reference")
        let third = try? coordinator.planTakes(
            projectID: made.project.id, shotID: made.project.shots[2].id, count: 1, baseSeed: 3)
        t.check(third?.first?.sourceImagePath == nil,
                "C: shot 3 never receives the character reference either")

        // D. With an inherited frame present, shot 2 uses that frame and the
        //    ordinary continuity strength.
        if var project = store.project(id: made.project.id) {
            guard let continuityFile = store.managedProjectAssetURL(
                projectID: project.id, relativePath: "Assets/Continuity/inherited.png") else { return }
            let continuityDir = continuityFile.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: continuityDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: continuityFile.path, contents: pngMagic)
            project.shots[1].continuityImageRelativePath = "Assets/Continuity/inherited.png"
            store.save(project)
            let inherited = try? coordinator.planTakes(
                projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 4)
            t.check(inherited?.first?.sourceImagePath?.hasSuffix("inherited.png") == true,
                    "D: shot 2 uses its inherited continuity frame")
            t.checkEqual(inherited?.first?.parameters.imageStrength,
                         AutoMovieRunCoordinator.continuityImageStrength,
                         "D: shot 2 keeps the standard 0.8 continuity strength")
        }

        // E. An explicit per-shot starting image outranks the anchor.
        let explicitStore = makeStore("explicit")
        let explicit = makeProject(store: explicitStore)
        enableAnchor(store: explicitStore, projectID: explicit.project.id,
                     characterID: explicit.characterID, assetID: explicit.frontID)
        if var project = explicitStore.project(id: explicit.project.id) {
            project.shots[0].startingImageReferenceAssetID = explicit.faceID
            explicitStore.save(project)
            let requests = try? TakeGenerationCoordinator(store: explicitStore).planTakes(
                projectID: project.id, shotID: project.shots[0].id, count: 1, baseSeed: 5)
            t.check(requests?.first?.sourceImagePath?.hasSuffix("face.png") == true,
                    "E: an explicit starting image wins over the character anchor")
            t.checkEqual(requests?.first?.parameters.imageStrength, 1.0,
                         "E: an explicit starting image keeps exact first-frame conditioning")
        }
    }

    t.suite("Character Anchor — missing references never fall back silently") {
        // F/G. A missing file blocks the shot instead of quietly producing a
        //      different-looking protagonist.
        let store = makeStore("missingfile")
        let made = makeProject(store: store, writeFiles: false)
        enableAnchor(store: store, projectID: made.project.id,
                     characterID: made.characterID, assetID: made.frontID)
        t.checkThrows(
            TakeGenerationCoordinator.CoordinatorError.characterAnchorUnavailable(.fileMissing),
            "F/G: a missing anchor file blocks generation with no silent text-to-video"
        ) {
            _ = try TakeGenerationCoordinator(store: store).planTakes(
                projectID: made.project.id, shotID: made.project.shots[0].id, count: 1)
        }

        // A deleted character, and a deleted asset, are each reported distinctly.
        let charStore = makeStore("missingchar")
        let charMade = makeProject(store: charStore)
        enableAnchor(store: charStore, projectID: charMade.project.id,
                     characterID: charMade.characterID, assetID: charMade.frontID)
        if var project = charStore.project(id: charMade.project.id) {
            project.characterBible.characters = []
            charStore.save(project)
            t.checkEqual(CharacterAnchorResolver.issue(project: project, store: charStore),
                         .characterMissing, "L: a deleted character reports characterMissing")
        }
        let assetStore = makeStore("missingasset")
        let assetMade = makeProject(store: assetStore)
        enableAnchor(store: assetStore, projectID: assetMade.project.id,
                     characterID: assetMade.characterID, assetID: assetMade.frontID)
        if var project = assetStore.project(id: assetMade.project.id) {
            project.characterBible.characters[0].referenceAssets.removeAll { $0.id == assetMade.frontID }
            assetStore.save(project)
            t.checkEqual(CharacterAnchorResolver.issue(project: project, store: assetStore),
                         .assetMissing, "L: a deleted asset reports assetMissing")
            // The project still loads — a broken anchor is never a load failure.
            t.check(assetStore.project(id: project.id) != nil,
                    "L: a project with a broken anchor still loads")
        }
    }

    t.suite("Character Anchor — selection, persistence and compatibility") {
        // K. Preference order picks Front over Face when both exist.
        var character = BibleCharacter(name: "Mika")
        let faceID = UUID(), frontID = UUID()
        character.referenceAssets = [
            CharacterReferenceAsset(id: faceID, type: .face, projectRelativePath: "a/face.png"),
            CharacterReferenceAsset(id: frontID, type: .front, projectRelativePath: "a/front.png"),
        ]
        t.checkEqual(CharacterAnchor.preferredAsset(for: character)?.id, frontID,
                     "K: Front is preferred over Face as the default reference")
        var faceOnly = BibleCharacter(name: "Solo")
        faceOnly.referenceAssets = [
            CharacterReferenceAsset(id: faceID, type: .face, projectRelativePath: "a/face.png"),
        ]
        t.checkEqual(CharacterAnchor.preferredAsset(for: faceOnly)?.id, faceID,
                     "K: Face is used when it is the only reference available")
        // A raw character sheet is a multi-pose layout, never an opening frame.
        t.check(!CharacterAnchor.offeredTypes.contains(.characterSheet),
                "K: a raw character sheet is not offered as an anchor")

        // H/I. The selection round-trips through persistence.
        let store = makeStore("persist")
        let made = makeProject(store: store)
        enableAnchor(store: store, projectID: made.project.id,
                     characterID: made.characterID, assetID: made.frontID)
        if let reloaded = store.project(id: made.project.id) {
            t.check(reloaded.characterAnchor.isEnabled, "H: enabled state persists")
            t.checkEqual(reloaded.characterAnchor.characterID, made.characterID,
                         "H: the selected character persists")
            t.checkEqual(reloaded.characterAnchor.referenceAssetID, made.frontID,
                         "I: the selected reference asset persists")
        } else {
            t.check(false, "H/I: project reload failed")
        }

        // J. A project saved before the feature existed decodes with the anchor
        //    off, and nothing about its behaviour changes.
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"Legacy Auto Movie","workflowMode":"hybrid",
         "shots":[],"jobs":[]}
        """
        if let data = legacy.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(FilmProject.self, from: data) {
            t.check(!decoded.characterAnchor.isEnabled,
                    "J: an old project decodes with the anchor disabled")
            t.check(!decoded.characterAnchor.isActive,
                    "J: an old project's anchor is inactive")
            t.checkEqual(CharacterAnchorResolver.resolve(project: decoded), .inactive,
                         "J: an old project resolves as inactive, not as an error")
        } else {
            t.check(false, "J: legacy project failed to decode")
        }

        // An enabled-but-unconfigured anchor is inert rather than an error.
        var halfConfigured = FilmProject(title: "Half")
        halfConfigured.characterAnchor.isEnabled = true
        t.checkEqual(CharacterAnchorResolver.resolve(project: halfConfigured), .inactive,
                     "an enabled but unconfigured anchor stays inactive")
    }

    t.suite("Character Anchor — surrounding systems unchanged") {
        // P/Q. Continuity strengths are untouched by this feature.
        t.checkEqual(AutoMovieRunCoordinator.continuityImageStrength, 0.8,
                     "P: standard continuity strength is still 0.8")
        t.checkEqual(AutoMovieRunCoordinator.reframeContinuityImageStrength, 0.5,
                     "Q: the reframe fallback is still 0.5")
        t.check(CharacterAnchorPolicy.openingImageStrength
                != AutoMovieRunCoordinator.continuityImageStrength,
                "the anchor does not borrow the inherited-frame strength")
        t.checkEqual(CharacterAnchorPolicy.appliesToShotIndex, 0,
                     "the anchor applies to the opening shot only")

        // M/N/O. Opening Shot Anchor, capability planning and reconciliation are
        //        untouched — the anchor is a source of pixels, not a planner.
        let planned = CapabilityAwareShotPlanner.plan(
            shots: [StoryboardDirector.ShotPlanDraft(
                title: "Open", summary: "She walks toward the door, her figure small against the wall.",
                durationSeconds: 5, shotScale: "wide", angle: "eye-level", movement: "track",
                lighting: "soft", dialogue: [], audioCues: [], explicitChanges: [],
                characterIDs: nil, characterNames: nil, continuity: "cut")],
            brief: "a woman walks to a door")
        t.check(!planned.shots[0].summary.contains("figure small"),
                "M: the Opening Shot Anchor still removes miniaturizing wording")
        t.check(planned.adjustments[0].appliedOpeningAnchor,
                "M: the opening anchor adjustment is still recorded")
    }
}
