import Foundation
import CryptoKit
@testable import LTXVideoGeneratorCore

/// A Storyboard shot's explicit Starting Image must reach the renderer as an
/// openable path, and must be frozen by content the same way Auto Movie's is.
///
/// `StoryboardRunRequestBuilder` handed the backend `explicitStartImageRelative
/// Path` verbatim — a project-relative path the renderer cannot open — and the
/// freeze hashed that same relative path, so the content hash was always nil.
/// This is the defect already fixed on the Auto Movie side; the Storyboard run
/// path carried its own copy of it.
///
/// Scope note: these tests deliberately do **not** assert that a project
/// Opening Reference becomes Storyboard shot 1's start image. The Storyboard
/// workspace cannot hold one (StoryboardView filters the two workspaces into a
/// total partition on `workflowMode`, offers `OpeningReferenceSection` only for
/// Auto Movie, and passes the chosen URL only when `mode == .hybrid`), and no
/// project on disk contradicts that. STORYOPEN_1 pins that invariant instead,
/// so the dead path is documented rather than speculatively implemented.
func runStoryboardRunStartImageTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StoryOpenTests-\(UUID().uuidString)", isDirectory: true)
    let store = FilmProjectStore(projectsDirectory: root)

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    let startPath = "Assets/Shots/start.png"

    @discardableResult
    func writeAsset(_ bytes: String, at relative: String, projectID: UUID) -> String {
        guard let url = store.managedProjectAssetURL(
            projectID: projectID, relativePath: relative) else { return "" }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(bytes.utf8).write(to: url)
        return sha256(Data(bytes.utf8))
    }

    func makeProject(characterReferences: Bool = false) -> FilmProject {
        var project = FilmProject(title: "Story")
        project.workflowMode = "storyboard"
        if characterReferences {
            let charID = UUID()
            project.characterBible.characters.append(
                BibleCharacter(id: charID, name: "Rena", referenceAssets: [
                    CharacterReferenceAsset(
                        id: UUID(), type: .characterSheet, label: "Sheet",
                        projectRelativePath: "Assets/Characters/sheet.png")
                ]))
        }
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "opening scene"),
            Shot(index: 1, title: "Two", compiledPrompt: "second scene"),
        ]
        project.shots[0].startingImageReferenceAssetID = UUID()
        project.shots[0].continuityImageRelativePath = startPath
        project.shots[1].continuityMode = .continueFromPrevious
        return project
    }

    let params = GenerationParameters(
        numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
        numFrames: 81, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1)

    func resolve(_ relative: String, _ projectID: UUID) -> String? {
        MovieRunRequestBuilder.resolveFrozenAssetPath(
            relative, projectID: projectID, store: store)
    }

    t.suite("Storyboard — an explicit Starting Image reaches the renderer") {

        var project = makeProject()
        let startHash = writeAsset("start-bytes", at: startPath, projectID: project.id)

        let job = try! StoryboardRunSubmission.makeJob(
            project: project, workCount: 1, directorMode: "direct", store: store,
            contentHash: { H3EndingImageCapability.contentHash(ofFileAt: $0) })
        let run = job.snapshot.storyboardRuns[0]
        let shot0 = run.orderedShots[0]

        // STORYOPEN_1 — the Opening Reference path stays dead by construction.
        // A Storyboard project has no way to acquire one; if that ever changes
        // this fails and the freeze rule has to be revisited deliberately.
        t.checkEqual(project.openingReferenceImage, nil,
                     "STORYOPEN_1 a Storyboard project carries no Opening Reference")
        t.checkEqual(run.plan.openingReferenceRelativePath, nil,
                     "STORYOPEN_1 so the frozen plan has none to resolve either")

        // STORYOPEN_2 — the shot-level Starting Image is the start source.
        t.checkEqual(shot0.startSource, FrozenShotPlan.StartSource.explicitImage,
                     "STORYOPEN_2 shot 1 starts from its Starting Image")
        t.checkEqual(shot0.explicitStartImageRelativePath, startPath,
                     "STORYOPEN_2 and it is the image the user chose")

        // STORYOPEN_3 — a later CONTINUE shot is unaffected.
        let shot1 = run.orderedShots[1]
        t.checkEqual(shot1.startSource, FrozenShotPlan.StartSource.previousShotOutput,
                     "STORYOPEN_3 shot 2 continues from the previous shot")
        t.checkEqual(shot1.explicitStartImageRelativePath, nil,
                     "STORYOPEN_3 and carries no explicit image")

        // STORYOPEN_5 — frozen by content, not only by path.
        t.check(shot0.explicitStartImageContentHash != nil,
                "STORYOPEN_5 the Starting Image is frozen by content")
        t.checkEqual(shot0.explicitStartImageContentHash, startHash,
                     "STORYOPEN_5 and the hash is the SHA-256 of the bytes on disk")
        t.check(!(shot0.explicitStartImageRelativePath ?? "").hasPrefix("/"),
                "STORYOPEN_5 while the stored path stays project-relative")

        // STORYOPEN_7 — count=1 builds a request the renderer can actually open.
        let request = StoryboardRunRequestBuilder.makeRequest(
            run: run, shotID: shot0.id, parameters: params, resolveAsset: resolve)
        t.checkEqual(request?.sourceImagePath,
                     store.managedProjectAssetURL(
                        projectID: project.id, relativePath: startPath)?.path,
                     "STORYOPEN_7 the request carries the resolved absolute path")
        t.check(!(request?.sourceImagePath ?? "/").hasPrefix("Assets/"),
                "STORYOPEN_7 never the unopenable project-relative path")

        // STORYOPEN_4 — a Character Reference is an identity input, never the
        // start source.
        var withRefs = makeProject(characterReferences: true)
        withRefs.id = project.id
        let refsJob = try! StoryboardRunSubmission.makeJob(
            project: withRefs, workCount: 1, directorMode: "direct", store: store,
            contentHash: { H3EndingImageCapability.contentHash(ofFileAt: $0) })
        let refsShot = refsJob.snapshot.storyboardRuns[0].orderedShots[0]
        t.checkEqual(refsShot.explicitStartImageRelativePath, startPath,
                     "STORYOPEN_4 a Character Reference did not replace the start image")
        t.checkEqual(refsShot.explicitStartImageContentHash, startHash,
                     "STORYOPEN_4 nor the frozen hash")

        // STORYOPEN_8 — count=3: one freeze, so one source and one hash.
        let batch = try! StoryboardRunSubmission.makeJob(
            project: project, workCount: 3, directorMode: "direct", store: store,
            contentHash: { H3EndingImageCapability.contentHash(ofFileAt: $0) })
        t.checkEqual(batch.snapshot.storyboardRuns.count, 3, "STORYOPEN_8 three runs")
        t.checkEqual(Set(batch.snapshot.storyboardRuns.map {
            $0.orderedShots[0].explicitStartImageRelativePath ?? "" }), Set([startPath]),
            "STORYOPEN_8 all three works share the frozen Starting Image")
        t.checkEqual(Set(batch.snapshot.storyboardRuns.map {
            $0.orderedShots[0].explicitStartImageContentHash ?? "" }), Set([startHash]),
            "STORYOPEN_8 and the same frozen bytes")
        t.checkEqual(Set(batch.snapshot.storyboardRuns.map {
            StoryboardRunRequestBuilder.makeRequest(
                run: $0, shotID: $0.orderedShots[0].id,
                parameters: params, resolveAsset: resolve)?.sourceImagePath ?? "" }).count,
            1, "STORYOPEN_8 resolving to one absolute path")

        // STORYOPEN_9 — a restart must not lose the source or the hash.
        let restored = try! JSONDecoder().decode(
            ProductionJobSnapshot.self, from: try! JSONEncoder().encode(job.snapshot))
        t.checkEqual(restored.storyboardRuns[0].orderedShots[0].explicitStartImageRelativePath,
                     startPath, "STORYOPEN_9 the frozen path survives a restart")
        t.checkEqual(restored.storyboardRuns[0].orderedShots[0].explicitStartImageContentHash,
                     startHash, "STORYOPEN_9 as does the content hash")

        // STORYOPEN_6 — edited after queueing: refuse.
        writeAsset("start-bytes-EDITED", at: startPath, projectID: project.id)
        let afterEdit = StoryboardRunRequestBuilder.makeRequest(
            run: run, shotID: shot0.id, parameters: params, resolveAsset: resolve)
        t.checkEqual(afterEdit, nil,
                     "STORYOPEN_6 a Starting Image edited after queueing is refused")

        // STORYOPEN_10 — and refusing never means "render it as text-to-video".
        t.check(afterEdit?.sourceImagePath == nil,
                "STORYOPEN_10 no silent text-to-video fallback on a hash mismatch")

        // Deleted after queueing: also refused.
        writeAsset("start-bytes", at: startPath, projectID: project.id)
        if let url = store.managedProjectAssetURL(
            projectID: project.id, relativePath: startPath) {
            try? FileManager.default.removeItem(at: url)
        }
        t.checkEqual(StoryboardRunRequestBuilder.makeRequest(
            run: run, shotID: shot0.id, parameters: params, resolveAsset: resolve), nil,
            "STORYOPEN_6 a Starting Image deleted after queueing is refused")
        writeAsset("start-bytes", at: startPath, projectID: project.id)

        // A legacy plan frozen before hashing existed still renders: fail-closed
        // applies to a broken promise, not a missing one.
        var legacy = run
        legacy.plan.shots[0].explicitStartImageContentHash = nil
        t.check(StoryboardRunRequestBuilder.makeRequest(
            run: legacy, shotID: legacy.plan.shots[0].id,
            parameters: params, resolveAsset: resolve) != nil,
            "STORYOPEN_6 a legacy plan without a frozen hash still renders")

        try? FileManager.default.removeItem(at: root)
    }
}
