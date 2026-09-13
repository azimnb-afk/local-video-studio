import Foundation
import CryptoKit
@testable import LTXVideoGeneratorCore

/// The frozen explicit start image must be frozen *by content*, not only by
/// path, and execution must refuse to render when those bytes no longer match.
///
/// A real Auto Movie job showed `explicitStartImageContentHash: nil` even
/// though the production call site supplies a hashing closure: freeze handed
/// that closure the *project-relative* path, and `FileManager.contents(atPath:)`
/// cannot open one. The hash was silently nil, and nothing verified it at
/// execution, so a start image edited or deleted while the work sat in the
/// queue would have been rendered — or dropped to text-to-video — without a
/// word to the user.
///
/// `FrozenMovieAssemblySpec` already had the right shape for this (resolve the
/// managed asset, hash the bytes, verify before use); these tests hold the
/// explicit start image to the same contract.
func runMovieRunContentHashTests(_ t: TestKit) {

    // Real bytes on disk: hashing is the behaviour under test, so it is not
    // stubbed out here the way the wiring-focused AUTOREF suite stubs it.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MovieHashTests-\(UUID().uuidString)", isDirectory: true)
    let store = FilmProjectStore(projectsDirectory: root)

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    let openingPath = "Assets/OpeningReference/opening.png"
    let shotImagePath = "Assets/Shots/shot-start.png"

    /// Writes real bytes into the managed asset tree for `projectID`.
    @discardableResult
    func writeAsset(_ bytes: String, at relative: String, projectID: UUID) -> String {
        guard let url = store.managedProjectAssetURL(
            projectID: projectID, relativePath: relative) else { return "" }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(bytes.utf8).write(to: url)
        return sha256(Data(bytes.utf8))
    }

    func makeProject(
        openingReference: Bool = true,
        shotLevelImage: Bool = false,
        characterReferences: Bool = false
    ) -> FilmProject {
        var project = FilmProject(title: "Hash")
        project.workflowMode = "hybrid"
        if openingReference {
            project.openingReferenceImage = OpeningReferenceImage(
                projectRelativePath: openingPath, originalFilename: "opening.png")
        }
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
        if shotLevelImage {
            project.shots[0].startingImageReferenceAssetID = UUID()
            project.shots[0].continuityImageRelativePath = shotImagePath
        }
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

    t.suite("Auto Movie — the frozen start image is frozen by content") {

        // MOVIEHASH_1 — the reported defect. Freeze through the production
        // submission path, with the production hashing closure, and the hash
        // must actually be there.
        var project = makeProject()
        let openingHash = writeAsset("opening-bytes", at: openingPath, projectID: project.id)
        let job = try! MovieRunSubmission.makeJob(
            project: project, workCount: 1, directorMode: "direct", store: store,
            contentHash: { H3EndingImageCapability.contentHash(ofFileAt: $0) })
        let frozen = job.snapshot.movieRuns[0].plan.shots[0]
        t.check(frozen.explicitStartImageContentHash != nil,
                "MOVIEHASH_1 the frozen opening image carries a content hash")
        t.checkEqual(frozen.explicitStartImageContentHash, openingHash,
                     "MOVIEHASH_1 and it is the SHA-256 of the bytes on disk")

        // MOVIEHASH_2 — the durable record stays project-relative. Hashing has
        // to resolve first; it must not turn the stored path absolute, because
        // an absolute path would not survive a moved library.
        t.checkEqual(frozen.explicitStartImageRelativePath, openingPath,
                     "MOVIEHASH_2 the frozen path stays project-relative")
        t.check(!(frozen.explicitStartImageRelativePath ?? "").hasPrefix("/"),
                "MOVIEHASH_2 no machine-specific absolute path is persisted")
        t.check(frozen.explicitStartImageContentHash != sha256(Data(openingPath.utf8)),
                "MOVIEHASH_2 the contents are hashed, never the path string")

        // MOVIEHASH_3 — an untouched queued file still renders.
        let request = MovieRunRequestBuilder.makeRequest(
            run: job.snapshot.movieRuns[0], shotID: frozen.id,
            parameters: params, resolveAsset: resolve)
        t.check(request?.sourceImagePath != nil,
                "MOVIEHASH_3 an unmodified queued image still builds a request")
        t.checkEqual(request?.sourceImagePath,
                     store.managedProjectAssetURL(
                        projectID: project.id, relativePath: openingPath)?.path,
                     "MOVIEHASH_3 pointing at the resolved managed asset")

        // MOVIEHASH_4 — edited after queueing: refuse, do not render new bytes.
        writeAsset("opening-bytes-EDITED", at: openingPath, projectID: project.id)
        let afterEdit = MovieRunRequestBuilder.makeRequest(
            run: job.snapshot.movieRuns[0], shotID: frozen.id,
            parameters: params, resolveAsset: resolve)
        t.checkEqual(afterEdit?.sourceImagePath, nil,
                     "MOVIEHASH_4 an image edited after queueing is refused")
        t.checkEqual(afterEdit, nil,
                     "MOVIEHASH_4 the whole request is blocked, not just the image")

        // MOVIEHASH_10 — and refusing must not mean "render it as text-to-video
        // instead". A silent T2V fallback is the original bug's failure mode.
        t.check(afterEdit?.sourceImagePath == nil && afterEdit == nil,
                "MOVIEHASH_10 no silent text-to-video fallback on a hash mismatch")

        // Restore, so the remaining checks start from a known-good file.
        writeAsset("opening-bytes", at: openingPath, projectID: project.id)
        t.check(MovieRunRequestBuilder.makeRequest(
            run: job.snapshot.movieRuns[0], shotID: frozen.id,
            parameters: params, resolveAsset: resolve) != nil,
            "MOVIEHASH_4 restoring the original bytes makes it renderable again")

        // MOVIEHASH_5 — deleted after queueing: refuse.
        if let url = store.managedProjectAssetURL(
            projectID: project.id, relativePath: openingPath) {
            try? FileManager.default.removeItem(at: url)
        }
        let afterDelete = MovieRunRequestBuilder.makeRequest(
            run: job.snapshot.movieRuns[0], shotID: frozen.id,
            parameters: params, resolveAsset: resolve)
        t.checkEqual(afterDelete, nil,
                     "MOVIEHASH_5 a frozen source deleted after queueing is refused")
        writeAsset("opening-bytes", at: openingPath, projectID: project.id)

        // MOVIEHASH_6 — the hash has to survive a queue restart.
        let restored = try! JSONDecoder().decode(
            ProductionJobSnapshot.self,
            from: try! JSONEncoder().encode(job.snapshot))
        t.checkEqual(restored.movieRuns[0].plan.shots[0].explicitStartImageContentHash,
                     openingHash,
                     "MOVIEHASH_6 the content hash survives encode/decode")
        t.checkEqual(restored.movieRuns[0].plan.shots[0].explicitStartImageRelativePath,
                     openingPath,
                     "MOVIEHASH_6 as does the relative path")

        // MOVIEHASH_7 — count=3: one freeze, so one hash shared by every work.
        let batch = try! MovieRunSubmission.makeJob(
            project: project, workCount: 3, directorMode: "direct", store: store,
            contentHash: { H3EndingImageCapability.contentHash(ofFileAt: $0) })
        let hashes = batch.snapshot.movieRuns.map { $0.plan.shots[0].explicitStartImageContentHash }
        t.checkEqual(Set(hashes.map { $0 ?? "" }), Set([openingHash]),
                     "MOVIEHASH_7 all three works carry the same frozen image hash")
        t.checkEqual(Set(batch.snapshot.movieRuns.map {
            $0.plan.shots[0].explicitStartImageRelativePath ?? "" }), Set([openingPath]),
            "MOVIEHASH_7 and the same frozen image")

        // MOVIEHASH_8 — a Character Reference is not a start source. Adding
        // one must not change or supply the explicit image hash.
        var withRefs = makeProject(characterReferences: true)
        withRefs.id = project.id
        let refsJob = try! MovieRunSubmission.makeJob(
            project: withRefs, workCount: 1, directorMode: "direct", store: store,
            contentHash: { H3EndingImageCapability.contentHash(ofFileAt: $0) })
        t.checkEqual(refsJob.snapshot.movieRuns[0].plan.shots[0].explicitStartImageContentHash,
                     openingHash,
                     "MOVIEHASH_8 character references do not affect the source hash")

        // MOVIEHASH_9 — CONTINUE is unaffected: it starts from the previous
        // shot's frozen final frame, which has its own verification, and it
        // carries no explicit image hash at all.
        let continueShot = job.snapshot.movieRuns[0].plan.shots[1]
        t.checkEqual(continueShot.startSource, FrozenShotPlan.StartSource.previousShotOutput,
                     "MOVIEHASH_9 shot 2 still continues from the previous shot")
        t.checkEqual(continueShot.explicitStartImageContentHash, nil,
                     "MOVIEHASH_9 and carries no explicit image hash")

        // MOVIEHASH_11 — a shot-level Starting Image gets the same treatment;
        // the guard is about explicit sources, not about the Opening Reference
        // specifically.
        var shotLevel = makeProject(openingReference: false, shotLevelImage: true)
        let shotHash = writeAsset("shot-bytes", at: shotImagePath, projectID: shotLevel.id)
        let shotJob = try! MovieRunSubmission.makeJob(
            project: shotLevel, workCount: 1, directorMode: "direct", store: store,
            contentHash: { H3EndingImageCapability.contentHash(ofFileAt: $0) })
        t.checkEqual(shotJob.snapshot.movieRuns[0].plan.shots[0].explicitStartImageContentHash,
                     shotHash,
                     "MOVIEHASH_11 a shot-level Starting Image is frozen by content too")
        writeAsset("shot-bytes-EDITED", at: shotImagePath, projectID: shotLevel.id)
        t.checkEqual(MovieRunRequestBuilder.makeRequest(
            run: shotJob.snapshot.movieRuns[0],
            shotID: shotJob.snapshot.movieRuns[0].plan.shots[0].id,
            parameters: params, resolveAsset: resolve), nil,
            "MOVIEHASH_11 and editing it after queueing is refused")

        // MOVIEHASH_12 — a legacy job frozen before hashing existed has no
        // hash to check. It must keep rendering rather than becoming
        // unrunnable: fail-closed applies to a broken promise, not a missing
        // one.
        var legacyRun = job.snapshot.movieRuns[0]
        legacyRun.plan.shots[0].explicitStartImageContentHash = nil
        t.check(MovieRunRequestBuilder.makeRequest(
            run: legacyRun, shotID: legacyRun.plan.shots[0].id,
            parameters: params, resolveAsset: resolve) != nil,
            "MOVIEHASH_12 a legacy job without a frozen hash still renders")

        try? FileManager.default.removeItem(at: root)
    }
}
