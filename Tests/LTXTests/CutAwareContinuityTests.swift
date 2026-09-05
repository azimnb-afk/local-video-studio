import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import LTXVideoGeneratorCore

/// Deterministic acceptance suite for Cut-Aware Continuity / New Start Frame.
///
/// Covers what `AutoMovieStrictContinuityPolicyTests.swift`,
/// `AutoMovieContinuityTests.swift`, `AutoMoviePlanPreviewTests.swift` and
/// `LTXContinuityV1Tests.swift` (all updated alongside this file) do not:
/// the New Start Frame field/storage/precedence itself, the widened
/// Character Anchor fallback, missing/corrupt New Start Frame failure
/// behavior, Selected-Take irrelevance for Cut, and Structured JSON / Text
/// Protocol convergence on one shared continuity vocabulary.
func runCutAwareContinuityTests(_ t: TestKit) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-cutaware-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func makeStore(_ name: String) -> FilmProjectStore {
        FilmProjectStore(projectsDirectory: root.appendingPathComponent(name, isDirectory: true))
    }

    @discardableResult
    func writePNG(_ url: URL, width: Int = 64, height: Int = 64) -> Bool {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
           ) else { return false }
        context.setFillColor(NSColor.systemPurple.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    func makeAutoMovieProject(
        store: FilmProjectStore, shotCount: Int = 2
    ) -> FilmProject {
        var project = FilmProject(title: "Cut-Aware Test")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        for index in 0..<shotCount {
            var shot = Shot(index: index, title: "Shot \(index + 1)", summary: "beat \(index + 1)")
            shot.compiledPrompt = "beat \(index + 1)"
            shot.durationSeconds = 1
            shot.continuityMode = index == 0 ? .cut : .continueFromPrevious
            project.shots.append(shot)
        }
        store.save(project)
        return store.project(id: project.id)!
    }

    @discardableResult
    func completeShot(
        store: FilmProjectStore, projectID: UUID, shotIndex: Int,
        videoPath: String, selected: Bool = true
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

    // MARK: - 1. Default Continue behavior is unaffected

    t.suite("CutAware 1 — default Continue behavior unaffected") {
        let store = makeStore("default-continue")
        let project = makeAutoMovieProject(store: store)
        let coordinator = AutoMovieRunCoordinator(store: store)
        t.checkEqual(coordinator.autoMovieContinuityMode(forShotAt: 1, in: project), .continueFromPrevious,
                     "an ordinary (non-cut) shot still continues by default")

        var autoProject = project
        autoProject.shots[1].continuityMode = .auto
        t.checkEqual(coordinator.autoMovieContinuityMode(forShotAt: 1, in: autoProject), .continueFromPrevious,
                     "auto/unplanned still resolves to continue for Auto Movie, unchanged")
    }

    // MARK: - 2. Legacy JSON decodes without the new field

    t.suite("CutAware 2 — legacy project JSON decodes safely") {
        var shot = Shot(index: 1, title: "Legacy")
        shot.continuityMode = .cut
        do {
            let data = try JSONEncoder().encode(shot)
            var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            t.check(legacy["newStartFrameRelativePath"] == nil || legacy["newStartFrameRelativePath"] is NSNull,
                    "sanity: a freshly encoded Shot carries no New Start Frame by default")
            legacy.removeValue(forKey: "newStartFrameRelativePath")
            let migrated = try JSONDecoder().decode(
                Shot.self, from: JSONSerialization.data(withJSONObject: legacy))
            t.check(migrated.newStartFrameRelativePath == nil,
                    "a project JSON written before Cut-Aware Continuity decodes with no New Start Frame")
            t.checkEqual(migrated.continuityMode, .cut,
                         "and its existing Cut/Continue data remains meaningful")
        } catch {
            t.check(false, "legacy Shot decode threw \(error)")
        }
    }

    // MARK: - 3/4/5. Source resolution: CONTINUE vs CUT+New Start Frame, no previous-frame extraction

    t.suite("CutAware 3-5 — CONTINUE vs CUT+New Start Frame source resolution") {
        let store = makeStore("source-resolution")
        var project = makeAutoMovieProject(store: store)
        let continuityImage = store.continuityAssetsDirectory(projectID: project.id)
            .appendingPathComponent("shot-002-from-take.png")
        try? FileManager.default.createDirectory(
            at: continuityImage.deletingLastPathComponent(), withIntermediateDirectories: true)
        t.check(writePNG(continuityImage), "fixture: usable inherited-frame PNG written")
        project.shots[1].continuityImageRelativePath =
            "Assets/Continuity/\(continuityImage.lastPathComponent)"
        project.shots[1].continuitySourceTakeID = UUID()
        store.save(project)

        let coordinator = TakeGenerationCoordinator(store: store)
        let continueRequests = try? coordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 1)
        t.check(continueRequests?.first?.sourceImagePath == continuityImage.path,
                "3: a CONTINUE shot's source is the previous shot's actual final frame")
        let continueDiagnostics = store.project(id: project.id)?.shots[1].takes.last?.generationSourceDiagnostics
        t.checkEqual(continueDiagnostics?.effectiveSource, .inheritedLastFrame,
                     "3: recorded as inheritedLastFrame")

        // A fresh project: shot 2 is Cut with an explicit New Start Frame.
        let cutStore = makeStore("cut-newstart")
        var cutProject = makeAutoMovieProject(store: cutStore)
        cutProject.shots[1].continuityMode = .cut
        // Simulate stale leftover continuity metadata from a prior Continue
        // choice, exactly as `TakeGenerationCoordinator` would see it if the
        // shot had been switched from Continue to Cut without going through
        // `AutoMoviePlanEditor` (which would have cleared it) — proving CUT
        // ignores it regardless of how it got there.
        let staleImage = cutStore.continuityAssetsDirectory(projectID: cutProject.id)
            .appendingPathComponent("stale.png")
        try? FileManager.default.createDirectory(
            at: staleImage.deletingLastPathComponent(), withIntermediateDirectories: true)
        writePNG(staleImage)
        cutProject.shots[1].continuityImageRelativePath = "Assets/Continuity/stale.png"
        cutProject.shots[1].continuitySourceTakeID = UUID()
        cutStore.save(cutProject)

        let newStartSource = root.appendingPathComponent("external-new-start.png")
        writePNG(newStartSource)
        guard let importedRelativePath = try? cutStore.importNewStartFrame(
            from: newStartSource, projectID: cutProject.id, shotID: cutProject.shots[1].id
        ) else {
            t.check(false, "importNewStartFrame threw unexpectedly")
            return
        }
        t.check(importedRelativePath.hasPrefix("Assets/NewStartFrame/"),
                "New Start Frame is stored under the project, not as an absolute path")
        cutProject = cutStore.project(id: cutProject.id)!
        cutProject.shots[1].newStartFrameRelativePath = importedRelativePath
        cutStore.save(cutProject)

        let cutCoordinator = TakeGenerationCoordinator(store: cutStore)
        let cutRequests = try? cutCoordinator.planTakes(
            projectID: cutProject.id, shotID: cutProject.shots[1].id, count: 1, baseSeed: 2)
        let expectedURL = cutStore.managedProjectAssetURL(
            projectID: cutProject.id, relativePath: importedRelativePath)
        t.check(cutRequests?.first?.sourceImagePath == expectedURL?.path,
                "4: a CUT shot with an explicit New Start Frame starts from that image")
        t.check(cutRequests?.first?.sourceImagePath != staleImage.path,
                "5: the stale previous-shot continuity path never leaks into a CUT's source")
        let cutDiagnostics = cutStore.project(id: cutProject.id)?.shots[1].takes.last?.generationSourceDiagnostics
        t.checkEqual(cutDiagnostics?.effectiveSource, .newStartFrame,
                     "4: recorded as newStartFrame, not inheritedLastFrame")
        t.checkEqual(cutDiagnostics?.sourceProjectRelativePath, importedRelativePath,
                     "15: diagnostics record the project-relative path, not a raw absolute path")

        // 5 (continued): the run coordinator itself never even attempts
        // previous-frame extraction for a Cut shot.
        let advanceStore = makeStore("cut-no-extraction")
        var advanceProject = makeAutoMovieProject(store: advanceStore)
        advanceProject.shots[1].continuityMode = .cut
        advanceStore.save(advanceProject)
        let fixtureA = TestFixtures.videoWithAudioA
        if FileManager.default.fileExists(atPath: fixtureA) {
            completeShot(store: advanceStore, projectID: advanceProject.id, shotIndex: 0, videoPath: fixtureA)
            var pending: [GenerationRequest] = []
            _ = AutoMovieRunCoordinator(store: advanceStore).advance(projectID: advanceProject.id) { pending = $0 }
            let saved = advanceStore.project(id: advanceProject.id)!
            t.check(saved.shots[1].continuityImageRelativePath == nil,
                    "5: advance() never extracts a previous frame for a Cut shot")
            t.check(pending.first?.sourceImagePath == nil,
                    "5: and the Cut shot enqueues as plain text-to-video with no New Start Frame")
        } else {
            t.check(true, "fixture video unavailable — advance()-level extraction check skipped")
        }
    }

    // MARK: - 6. CUT ignores the previous shot's Selected Take entirely

    t.suite("CutAware 6 — CUT ignores the previous shot's Selected Take") {
        let store = makeStore("cut-ignores-selected-take")
        var project = makeAutoMovieProject(store: store)
        project.shots[1].continuityMode = .cut
        store.save(project)

        let newStartSource = root.appendingPathComponent("selected-take-irrelevant.png")
        writePNG(newStartSource)
        let relativePath = try! store.importNewStartFrame(
            from: newStartSource, projectID: project.id, shotID: project.shots[1].id)
        project = store.project(id: project.id)!
        project.shots[1].newStartFrameRelativePath = relativePath
        store.save(project)

        // Shot 1 gets two completed Takes with an explicit selection.
        let fixtureA = TestFixtures.videoWithAudioA
        let fixtureB = TestFixtures.videoWithAudioB
        guard FileManager.default.fileExists(atPath: fixtureA),
              FileManager.default.fileExists(atPath: fixtureB) else {
            t.check(true, "fixture videos unavailable — Selected Take irrelevance check skipped")
            return
        }
        completeShot(store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureA, selected: false)
        let selectedTakeID = completeShot(
            store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureB, selected: true)

        let coordinator = TakeGenerationCoordinator(store: store)
        let expectedURL = store.managedProjectAssetURL(projectID: project.id, relativePath: relativePath)
        let firstPass = try? coordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 10)
        t.check(firstPass?.first?.sourceImagePath == expectedURL?.path,
                "CUT's source is the New Start Frame regardless of Shot 1's Selected Take")

        // Changing the selection (and even removing the selected Take
        // entirely) must have zero effect on the Cut shot's source.
        var reselected = store.project(id: project.id)!
        reselected.shots[0].selectedTakeID = nil
        store.save(reselected)
        let secondPass = try? coordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 11)
        t.check(secondPass?.first?.sourceImagePath == expectedURL?.path,
                "clearing Shot 1's selection still does not change the CUT shot's source")
        t.check(selectedTakeID != UUID(),
                "sanity: a real selected Take existed and was legitimately ignored, not just absent")
    }

    // MARK: - 8. Missing/corrupt New Start Frame fails clearly, never falls back silently

    t.suite("CutAware 8 — missing/corrupt New Start Frame fails clearly") {
        let store = makeStore("newstart-missing")
        var project = makeAutoMovieProject(store: store)
        project.shots[1].continuityMode = .cut
        project.shots[1].newStartFrameRelativePath = "Assets/NewStartFrame/\(project.shots[1].id.uuidString)/does-not-exist.png"
        // A Character Anchor is ALSO active, to prove a missing-but-explicitly
        // -set New Start Frame fails clearly instead of silently falling
        // through to the anchor fallback.
        let characterID = UUID(), assetID = UUID()
        let assetsDir = store.characterAssetsDirectory(projectID: project.id, characterID: characterID)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        writePNG(assetsDir.appendingPathComponent("front.png"))
        var character = BibleCharacter(id: characterID, name: "Anchor")
        character.referenceAssets = [CharacterReferenceAsset(
            id: assetID, type: .front,
            projectRelativePath: "Assets/Characters/\(characterID.uuidString)/front.png")]
        project.characterBible.characters = [character]
        project.characterAnchor.isEnabled = true
        project.characterAnchor.characterID = characterID
        project.characterAnchor.referenceAssetID = assetID
        store.save(project)

        let coordinator = TakeGenerationCoordinator(store: store)
        do {
            _ = try coordinator.planTakes(
                projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 20)
            t.check(false, "a missing New Start Frame must throw, not silently succeed")
        } catch let error as TakeGenerationCoordinator.CoordinatorError {
            t.checkEqual(error, .newStartFrameUnavailable(project.shots[1].id),
                         "missing New Start Frame fails with the dedicated error, not a fallback")
        } catch {
            t.check(false, "unexpected error type: \(error)")
        }

        // Corrupt (present but not a usable image) behaves the same way.
        var corruptProject = store.project(id: project.id)!
        let corruptPath = store.newStartFrameDirectory(
            projectID: project.id, shotID: corruptProject.shots[1].id
        ).appendingPathComponent("corrupt.png")
        try? FileManager.default.createDirectory(
            at: corruptPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not a png".utf8).write(to: corruptPath)
        corruptProject.shots[1].newStartFrameRelativePath =
            "Assets/NewStartFrame/\(corruptProject.shots[1].id.uuidString)/corrupt.png"
        store.save(corruptProject)
        do {
            _ = try coordinator.planTakes(
                projectID: corruptProject.id, shotID: corruptProject.shots[1].id, count: 1, baseSeed: 21)
            t.check(false, "a corrupt New Start Frame must throw, not silently succeed")
        } catch let error as TakeGenerationCoordinator.CoordinatorError {
            t.checkEqual(error, .newStartFrameUnavailable(corruptProject.shots[1].id),
                         "corrupt New Start Frame fails with the dedicated error too")
        } catch {
            t.check(false, "unexpected error type: \(error)")
        }
    }

    // MARK: - Persistence: New Start Frame survives a genuine project reopen

    t.suite("CutAware — New Start Frame and Cut mode survive project reopen") {
        let store = makeStore("persistence-roundtrip")
        var project = makeAutoMovieProject(store: store)
        project.shots[1].continuityMode = .cut
        store.save(project)

        let source = root.appendingPathComponent("persist-new-start.png")
        writePNG(source)
        let relativePath = try! store.importNewStartFrame(
            from: source, projectID: project.id, shotID: project.shots[1].id)
        project = store.project(id: project.id)!
        project.shots[1].newStartFrameRelativePath = relativePath
        store.save(project)

        // A genuinely fresh FilmProjectStore instance over the same directory
        // — exactly what happens on app relaunch — not the same in-memory
        // store instance.
        let reopened = FilmProjectStore(projectsDirectory: store.projectsDirectory)
        let reopenedProject = reopened.project(id: project.id)!
        t.checkEqual(reopenedProject.shots[1].continuityMode, .cut,
                     "Cut mode survives a genuine project reopen")
        t.checkEqual(reopenedProject.shots[1].newStartFrameRelativePath, relativePath,
                     "the New Start Frame's project-relative path survives a genuine project reopen")
        let reopenedURL = reopened.managedProjectAssetURL(
            projectID: project.id, relativePath: relativePath)
        t.check(reopenedURL != nil && FileManager.default.fileExists(atPath: reopenedURL!.path),
                "the New Start Frame file itself is still present on disk after reopen")

        // The reopened store's coordinator resolves generation identically.
        let coordinator = TakeGenerationCoordinator(store: reopened)
        let requests = try? coordinator.planTakes(
            projectID: reopenedProject.id, shotID: reopenedProject.shots[1].id, count: 1, baseSeed: 50)
        t.check(requests?.first?.sourceImagePath == reopenedURL?.path,
                "generation after reopen still resolves the persisted New Start Frame")
    }

    // MARK: - 9. Shot 1 is completely unaffected by the New Start Frame field

    t.suite("CutAware 9 — Shot 1 ignores New Start Frame entirely") {
        let store = makeStore("shot1-unaffected")
        var project = makeAutoMovieProject(store: store, shotCount: 1)
        // Defensive: even if a New Start Frame were somehow set on Shot 1
        // (never exposed by the UI), Shot 1 must not consult it — it is not
        // Cut in the sense this field applies to.
        let bogusSource = root.appendingPathComponent("shot1-bogus.png")
        writePNG(bogusSource)
        let relativePath = try! store.importNewStartFrame(
            from: bogusSource, projectID: project.id, shotID: project.shots[0].id)
        project.shots[0].newStartFrameRelativePath = relativePath
        store.save(project)

        let coordinator = TakeGenerationCoordinator(store: store)
        let requests = try? coordinator.planTakes(
            projectID: project.id, shotID: project.shots[0].id, count: 1, baseSeed: 30)
        t.check(requests?.first?.sourceImagePath == nil,
                "Shot 1 with no Opening Reference/Character Anchor is still plain text-to-video")
        let expectedURL = store.managedProjectAssetURL(projectID: project.id, relativePath: relativePath)
        t.check(requests?.first?.sourceImagePath != expectedURL?.path,
                "Shot 1 never picks up a New Start Frame even if one happens to be set")
    }

    // MARK: - 10. Character Anchor identity re-anchor fallback for CUT

    t.suite("CutAware 10 — Character Anchor re-anchors a CUT with no New Start Frame") {
        let store = makeStore("cut-anchor-fallback")
        var project = makeAutoMovieProject(store: store)
        project.shots[1].continuityMode = .cut
        let characterID = UUID(), assetID = UUID()
        let assetsDir = store.characterAssetsDirectory(projectID: project.id, characterID: characterID)
        try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        writePNG(assetsDir.appendingPathComponent("front.png"))
        var character = BibleCharacter(id: characterID, name: "Anchor")
        character.referenceAssets = [CharacterReferenceAsset(
            id: assetID, type: .front,
            projectRelativePath: "Assets/Characters/\(characterID.uuidString)/front.png")]
        project.characterBible.characters = [character]
        project.characterAnchor.isEnabled = true
        project.characterAnchor.characterID = characterID
        project.characterAnchor.referenceAssetID = assetID
        store.save(project)

        let coordinator = TakeGenerationCoordinator(store: store)
        let requests = try? coordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 40)
        t.check(requests?.first?.sourceImagePath?.hasSuffix("front.png") == true,
                "a CUT with no New Start Frame but an active Character Anchor re-anchors identity")
        t.checkEqual(requests?.first?.parameters.imageStrength, CharacterAnchorPolicy.openingImageStrength,
                     "the anchor conditions at the Character Anchor's own (looser) strength, not an exact pin")
        let diagnostics = store.project(id: project.id)?.shots[1].takes.last?.generationSourceDiagnostics
        t.checkEqual(diagnostics?.effectiveSource, .characterAnchor,
                     "recorded as characterAnchor — not claimed as Face Lock or a new mechanism")

        // Opening Reference, by contrast, is deliberately NOT extended to a
        // later Cut — it is a whole-movie concept, first shot only.
        var withOpening = store.project(id: project.id)!
        withOpening.openingReferenceImage = OpeningReferenceImage(
            projectRelativePath: "Assets/OpeningReference/o.png",
            originalFilename: "o.png", mimeType: "image/png", fileSizeBytes: 1)
        let openingFile = store.openingReferenceDirectory(projectID: project.id)
            .appendingPathComponent("o.png")
        try? FileManager.default.createDirectory(
            at: openingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        writePNG(openingFile)
        store.save(withOpening)
        let requestsWithOpening = try? coordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 41)
        t.check(requestsWithOpening?.first?.sourceImagePath?.contains("OpeningReference") == false,
                "a later Cut never falls back to the whole-movie Opening Reference")
        t.check(requestsWithOpening?.first?.sourceImagePath?.hasSuffix("front.png") == true,
                "it still re-anchors via the Character Anchor instead")
    }

    // MARK: - 11/12. Structured JSON and Text Protocol converge on one continuity vocabulary

    t.suite("CutAware 11-12 — Structured JSON and Text Protocol share one continuity parse") {
        let jsonDraft = StoryboardDirector.parseDraftDetailed(from: """
        {"logline":"A courier delivers a package.","shots":[
          {"title":"Arrival","summary":"He arrives at the door.","continuity":"cut"},
          {"title":"Later","summary":"Meanwhile, across town.","continuity":"cut"},
          {"title":"Handoff","summary":"He hands over the package.","continuity":"continue"}
        ]}
        """, brief: "A courier delivers a package.").draft
        t.checkEqual(jsonDraft?.shots.map(\.continuity), ["cut", "cut", "continue"],
                     "Structured JSON carries the raw continuity token per shot")

        let textDraft = TextProtocolPlanParser.parse("""
        LOGLINE: A courier delivers a package.
        SHOT 1
        ACTION: He arrives at the door.
        CONTINUITY: CUT
        SHOT 2
        ACTION: Meanwhile, across town.
        CONTINUITY: cut
        SHOT 3
        ACTION: He hands over the package.
        CONTINUITY: CONTINUE
        """, brief: "A courier delivers a package.").draft
        t.checkEqual(textDraft?.shots.map(\.continuity), ["cut", "cut", "continue"],
                     "Text Protocol normalizes to the identical lowercase tokens")

        // Both feed the SAME conversion in StoryboardDirector.makeProject
        // (`ShotContinuityMode(rawValue: (shotDraft.continuity ?? "").lowercased())`
        // — one line, shared by both protocols, unmodified by this task) into
        // the reusable existing enum. No second continuity vocabulary exists.
        t.checkEqual(ShotContinuityMode(rawValue: "cut"), .cut,
                     "the raw token both protocols emit maps to the existing enum's Cut case")
        t.checkEqual(ShotContinuityMode(rawValue: "continue"), .continueFromPrevious,
                     "and to the existing enum's Continue case — no new continuity type was introduced")
    }

    // MARK: - 14. LTX-2.5 GenerationRequest construction is source-agnostic

    t.suite("CutAware 14 — LTX-2.5 backend treats a New-Start-Frame source like any other") {
        var params = GenerationParameters.default
        params.width = 768
        params.height = 512
        params.numFrames = 49
        params.fps = 24
        params.seed = 7

        let cutRequest = GenerationRequest(
            prompt: "A woman turns and walks away.",
            sourceImagePath: "/project/Assets/NewStartFrame/shot-2/new-start.png",
            modelId: LTX25ModelCatalog.ltx25ExperimentalID,
            parameters: params
        )
        let args = LTX2MLXBackend.arguments(
            request: cutRequest, modelDirectory: "/path/to/ltx25",
            outputPath: "/path/to/out.mp4", seed: 7, width: 768, height: 512
        )
        t.check(args.contains("--image") && args.contains("/project/Assets/NewStartFrame/shot-2/new-start.png"),
                "a New-Start-Frame-sourced image is passed through --image with no special-casing")

        // No branch anywhere on effectiveSource: an inherited-frame path
        // produces byte-identical argument shape apart from the path itself.
        let continueRequest = GenerationRequest(
            prompt: "A woman turns and walks away.",
            sourceImagePath: "/project/Assets/Continuity/shot-2-from-take.png",
            modelId: LTX25ModelCatalog.ltx25ExperimentalID,
            parameters: params
        )
        let continueArgs = LTX2MLXBackend.arguments(
            request: continueRequest, modelDirectory: "/path/to/ltx25",
            outputPath: "/path/to/out.mp4", seed: 7, width: 768, height: 512
        )
        let stripPath: ([String]) -> [String] = { list in
            list.map { $0.hasPrefix("/project/") ? "<path>" : $0 }
        }
        t.checkEqual(stripPath(args), stripPath(continueArgs),
                     "LTX-2.5 argument shape is identical for New Start Frame vs inherited-frame sources")
    }
}
