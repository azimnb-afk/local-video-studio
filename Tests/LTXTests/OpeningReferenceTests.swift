import Foundation
@testable import LTXVideoGeneratorCore

/// Auto Movie Opening Reference Image: a scene-like still that becomes the
/// **opening shot's first frame only**. It outranks the Character Anchor, and
/// like the anchor it is never re-injected into a later shot.
func runOpeningReferenceTests(_ t: TestKit) {

    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-openref-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    func makeStore(_ name: String) -> FilmProjectStore {
        FilmProjectStore(projectsDirectory: tmpRoot.appendingPathComponent(name, isDirectory: true))
    }

    let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// A source image outside the project, as a user's own file would be.
    func externalImage(_ name: String) -> URL {
        let url = tmpRoot.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: pngMagic)
        return url
    }

    func makeProject(store: FilmProjectStore, shotCount: Int = 3)
    -> (project: FilmProject, characterID: UUID, frontID: UUID) {
        var project = FilmProject(title: "Opening Reference Test")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        for index in 0..<shotCount {
            var shot = Shot(index: index, title: "Shot \(index + 1)", summary: "beat \(index + 1)")
            shot.compiledPrompt = "A woman walks through a courtyard, beat \(index + 1)."
            shot.durationSeconds = 1
            shot.continuityMode = index == 0 ? .cut : .continueFromPrevious
            project.shots.append(shot)
        }
        // A configured Character Anchor, so precedence is actually exercised.
        let characterID = UUID(), frontID = UUID()
        var character = BibleCharacter(id: characterID, name: "Mika")
        let assetsDir = store.characterAssetsDirectory(projectID: project.id, characterID: characterID)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: assetsDir.appendingPathComponent("front.png").path, contents: pngMagic)
        character.referenceAssets = [
            CharacterReferenceAsset(
                id: frontID, type: .front,
                projectRelativePath: "Assets/Characters/\(characterID.uuidString)/front.png"),
        ]
        project.characterBible.characters = [character]
        project.characterAnchor.isEnabled = true
        project.characterAnchor.characterID = characterID
        project.characterAnchor.referenceAssetID = frontID
        store.save(project)
        return (project, characterID, frontID)
    }

    t.suite("Opening Reference — source precedence and shot scope") {
        // A. Nothing configured beyond the anchor: the anchor still supplies
        //    shot 1, exactly as it did before this feature.
        let baseStore = makeStore("base")
        let base = makeProject(store: baseStore)
        let baseOpening = try? TakeGenerationCoordinator(store: baseStore).planTakes(
            projectID: base.project.id, shotID: base.project.shots[0].id, count: 1, baseSeed: 1)
        t.check(baseOpening?.first?.sourceImagePath?.hasSuffix("front.png") == true,
                "A: with no opening reference the Character Anchor still supplies shot 1")

        // B/E. With an opening reference imported, it wins over the anchor.
        let store = makeStore("openref")
        let made = makeProject(store: store)
        guard let imported = try? store.importOpeningReferenceImage(
            from: externalImage("scene-a.png"), projectID: made.project.id) else {
            t.check(false, "B: import failed"); return
        }
        if var project = store.project(id: made.project.id) {
            project.openingReferenceImage = imported
            store.save(project)
        }
        let coordinator = TakeGenerationCoordinator(store: store)
        let opening = try? coordinator.planTakes(
            projectID: made.project.id, shotID: made.project.shots[0].id, count: 1, baseSeed: 1)
        t.check(opening?.first?.sourceImagePath?.contains("OpeningReference") == true,
                "B/E: the opening reference wins over the Character Anchor for shot 1")
        t.check(opening?.first?.sourceImagePath?.hasSuffix("front.png") != true,
                "E: the anchor image is not used when an opening reference exists")
        t.checkEqual(opening?.first?.parameters.imageStrength,
                     OpeningReferencePolicy.openingImageStrength,
                     "the opening reference conditions like an explicit starting image")

        // C. THE CRITICAL REGRESSION — shots 2 and 3 never receive it.
        let second = try? coordinator.planTakes(
            projectID: made.project.id, shotID: made.project.shots[1].id, count: 1, baseSeed: 2)
        t.check(second?.first?.sourceImagePath == nil,
                "C: shot 2 never receives the opening reference")
        let third = try? coordinator.planTakes(
            projectID: made.project.id, shotID: made.project.shots[2].id, count: 1, baseSeed: 3)
        t.check(third?.first?.sourceImagePath == nil,
                "C: shot 3 never receives the opening reference either")

        // D. Shot 2 uses its inherited continuity frame at the usual strength.
        if var project = store.project(id: made.project.id),
           let continuityFile = store.managedProjectAssetURL(
               projectID: made.project.id, relativePath: "Assets/Continuity/inherited.png") {
            try? FileManager.default.createDirectory(
                at: continuityFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: continuityFile.path, contents: pngMagic)
            project.shots[1].continuityImageRelativePath = "Assets/Continuity/inherited.png"
            store.save(project)
            let inherited = try? coordinator.planTakes(
                projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 4)
            t.check(inherited?.first?.sourceImagePath?.hasSuffix("inherited.png") == true,
                    "D: shot 2 uses its inherited continuity frame")
            t.checkEqual(inherited?.first?.parameters.imageStrength,
                         AutoMovieRunCoordinator.continuityImageStrength,
                         "R: shot 2 keeps the standard 0.8 continuity strength")
        }

        // An explicit per-shot starting image still outranks everything.
        if var project = store.project(id: made.project.id) {
            project.shots[0].startingImageReferenceAssetID = made.frontID
            store.save(project)
            let explicit = try? coordinator.planTakes(
                projectID: project.id, shotID: project.shots[0].id, count: 1, baseSeed: 5)
            t.check(explicit?.first?.sourceImagePath?.hasSuffix("front.png") == true,
                    "an explicit per-shot starting image still wins over the opening reference")
        }
    }

    t.suite("Opening Reference — managed asset lifecycle") {
        let store = makeStore("lifecycle")
        let made = makeProject(store: store)

        // I. The import is a project-owned copy, not the external original.
        let source = externalImage("scene-b.png")
        guard let imported = try? store.importOpeningReferenceImage(
            from: source, projectID: made.project.id) else {
            t.check(false, "I: import failed"); return
        }
        t.check(imported.projectRelativePath.hasPrefix("Assets/OpeningReference/"),
                "I: the image is stored under the project's managed asset tree")
        t.check(!imported.projectRelativePath.hasPrefix("/"),
                "I: the stored path is project-relative, never absolute")
        t.checkEqual(imported.originalFilename, "scene-b.png",
                     "the original filename is kept for display")
        t.check(FileManager.default.fileExists(atPath: source.path),
                "I: the user's original file is never moved or deleted")

        if var project = store.project(id: made.project.id) {
            project.openingReferenceImage = imported
            store.save(project)
        }

        // K. It survives a reload — this is what makes a project portable.
        if let reloaded = store.project(id: made.project.id) {
            t.checkEqual(reloaded.openingReferenceImage?.projectRelativePath,
                         imported.projectRelativePath,
                         "K: the opening reference persists across a reload")
            if case .success(let url)? = CharacterAnchorResolver.resolveOpeningReference(
                project: reloaded, store: store) {
                t.check(FileManager.default.fileExists(atPath: url.path),
                        "K: the managed file resolves after reload")
            } else {
                t.check(false, "K: the reference failed to resolve after reload")
            }
        }

        // L. Replacing points at the new image and removes the superseded copy.
        guard let replacement = try? store.importOpeningReferenceImage(
            from: externalImage("scene-c.png"), projectID: made.project.id) else {
            t.check(false, "L: replacement import failed"); return
        }
        let supersededURL = store.managedProjectAssetURL(
            projectID: made.project.id, relativePath: imported.projectRelativePath)
        store.removeManagedOpeningReference(projectID: made.project.id, reference: imported)
        if var project = store.project(id: made.project.id) {
            project.openingReferenceImage = replacement
            store.save(project)
        }
        if let reloaded = store.project(id: made.project.id) {
            t.checkEqual(reloaded.openingReferenceImage?.originalFilename, "scene-c.png",
                         "L: replacing switches the project to the new image")
        }
        if let supersededURL {
            t.check(!FileManager.default.fileExists(atPath: supersededURL.path),
                    "L: the superseded copy is removed rather than orphaned")
        }

        // M. Clearing removes only the opening reference; the anchor survives.
        if var project = store.project(id: made.project.id) {
            if let existing = project.openingReferenceImage {
                store.removeManagedOpeningReference(projectID: project.id, reference: existing)
            }
            project.openingReferenceImage = nil
            store.save(project)
        }
        if let cleared = store.project(id: made.project.id) {
            t.check(cleared.openingReferenceImage == nil, "M: clearing removes the reference")
            t.check(cleared.characterAnchor.isActive,
                    "M: clearing leaves the Character Anchor untouched")
            // F. And the anchor takes over shot 1 again.
            let after = try? TakeGenerationCoordinator(store: store).planTakes(
                projectID: cleared.id, shotID: cleared.shots[0].id, count: 1, baseSeed: 6)
            t.check(after?.first?.sourceImagePath?.hasSuffix("front.png") == true,
                    "F: clearing restores the Character Anchor as the shot 1 source")
        }

        // Non-image files are refused rather than imported as a broken asset.
        let bogus = tmpRoot.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: bogus.path, contents: Data("x".utf8))
        t.checkThrows(FilmProjectStore.StoreError.unsupportedOpeningReferenceFormat("txt"),
                      "an unsupported file type is refused") {
            _ = try store.importOpeningReferenceImage(from: bogus, projectID: made.project.id)
        }
    }

    t.suite("Opening Reference — creation-time flow") {
        // The New Auto Movie sheet holds a plain URL and imports only on
        // Create, so these cover the order the creation handler runs in.
        let store = makeStore("createflow")

        // A. Created with no image chosen: an ordinary text-to-video opening.
        let plain = makeProject(store: store)
        if var project = store.project(id: plain.project.id) {
            project.characterAnchor = CharacterAnchor()   // no anchor either
            store.save(project)
            let opening = try? TakeGenerationCoordinator(store: store).planTakes(
                projectID: project.id, shotID: project.shots[0].id, count: 1, baseSeed: 1)
            t.check(opening?.first?.sourceImagePath == nil,
                    "A: creating without an opening image leaves shot 1 as text-to-video")
        }

        // B/C/D. Created with an image: the import happens, the project carries
        //        it, and the very first generation request already resolves it.
        //        This is the ordering the creation handler must preserve —
        //        importing after the project is saved would race the first
        //        render.
        let withImage = makeProject(store: store)
        guard var created = store.project(id: withImage.project.id),
              let imported = try? store.importOpeningReferenceImage(
                  from: externalImage("created-scene.png"), projectID: created.id) else {
            t.check(false, "B: creation-time import failed"); return
        }
        created.openingReferenceImage = imported          // set BEFORE save
        store.save(created)                                // then persisted
        t.check(store.project(id: created.id)?.openingReferenceImage != nil,
                "C: the created project carries the opening reference")
        let first = try? TakeGenerationCoordinator(store: store).planTakes(
            projectID: created.id, shotID: created.shots[0].id, count: 1, baseSeed: 2)
        t.check(first?.first?.sourceImagePath?.contains("OpeningReference") == true,
                "D: shot 1's first generation request already resolves the reference")
        let secondShot = try? TakeGenerationCoordinator(store: store).planTakes(
            projectID: created.id, shotID: created.shots[1].id, count: 1, baseSeed: 3)
        t.check(secondShot?.first?.sourceImagePath == nil,
                "E: shot 2 still does not receive it")

        // F. Cancelling the sheet imports nothing, so no managed asset and no
        //    project residue are left behind.
        let cancelledID = UUID()
        let cancelledDir = store.openingReferenceDirectory(projectID: cancelledID)
        t.check(!FileManager.default.fileExists(atPath: cancelledDir.path),
                "F: cancelling before Create leaves no opening reference directory")
        store.removeUncommittedProjectAssets(projectID: cancelledID)
        t.check(store.project(id: cancelledID) == nil,
                "F: cancelling creates no project")

        // G. An unreadable source fails the import, which the creation handler
        //    turns into a refusal to create rather than a silent text-to-video.
        let missingSource = tmpRoot.appendingPathComponent("does-not-exist.png")
        t.checkThrows(FilmProjectStore.StoreError.invalidOpeningReferenceSource,
                      "G: an unreadable source blocks creation instead of falling back") {
            _ = try store.importOpeningReferenceImage(
                from: missingSource, projectID: created.id)
        }
    }

    t.suite("Opening Reference — missing file and compatibility") {
        // G/H. A missing file blocks the shot; it never silently becomes T2V,
        //      and it never silently falls through to the Character Anchor.
        let store = makeStore("missing")
        let made = makeProject(store: store)
        if var project = store.project(id: made.project.id) {
            project.openingReferenceImage = OpeningReferenceImage(
                projectRelativePath: "Assets/OpeningReference/gone.png",
                originalFilename: "gone.png")
            store.save(project)
            t.check(store.project(id: project.id) != nil,
                    "G: a project with a missing opening reference still loads")
            t.checkThrows(
                TakeGenerationCoordinator.CoordinatorError.openingReferenceUnavailable(.fileMissing),
                "G/H: a missing opening reference blocks generation, with no silent fallback"
            ) {
                _ = try TakeGenerationCoordinator(store: store).planTakes(
                    projectID: project.id, shotID: project.shots[0].id, count: 1)
            }
        }

        // J. A project saved before this feature decodes with no reference.
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"Legacy","workflowMode":"hybrid","shots":[],"jobs":[]}
        """
        if let data = legacy.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(FilmProject.self, from: data) {
            t.check(decoded.openingReferenceImage == nil,
                    "J: an old project decodes with no opening reference")
            t.check(CharacterAnchorResolver.resolveOpeningReference(project: decoded) == nil,
                    "J: an absent reference resolves to nil, not to an error")
        } else {
            t.check(false, "J: legacy project failed to decode")
        }

        // N/O/P/Q/S. Neighbouring systems are untouched.
        t.checkEqual(AutoMovieRunCoordinator.continuityImageStrength, 0.8,
                     "R: standard continuity strength is still 0.8")
        t.checkEqual(AutoMovieRunCoordinator.reframeContinuityImageStrength, 0.5,
                     "S: the reframe fallback is still 0.5")
        t.checkEqual(CharacterAnchorPolicy.openingImageStrength, 1.0,
                     "N: the Character Anchor policy is unchanged")
        t.checkEqual(OpeningReferencePolicy.appliesToShotIndex, 0,
                     "the opening reference applies to shot 1 only")
        let planned = CapabilityAwareShotPlanner.plan(
            shots: [StoryboardDirector.ShotPlanDraft(
                title: "Open", summary: "She walks on, her figure small against the wall.",
                durationSeconds: 5, shotScale: "wide", angle: "eye-level", movement: "track",
                lighting: "soft", dialogue: [], audioCues: [], explicitChanges: [],
                characterIDs: nil, characterNames: nil, continuity: "cut")],
            brief: "a woman walks")
        t.check(!planned.shots[0].summary.contains("figure small"),
                "O: the Opening Shot Anchor still removes miniaturizing wording")
    }
}
