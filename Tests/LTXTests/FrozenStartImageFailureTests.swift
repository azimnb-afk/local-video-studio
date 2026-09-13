import Foundation
import CryptoKit
@testable import LTXVideoGeneratorCore

/// Failing closed is only half the job: the user has to be able to tell *why*.
///
/// The frozen-image guards refuse correctly, but `makeRequest` returning nil is
/// a silent signal, and the scheduler used to flatten every refusal into one
/// sentence about a starting "frame" — continuation vocabulary shown to a user
/// whose own chosen picture had been moved or edited. These tests hold the
/// classification, the shot state and the queue's terminal behaviour.
func runFrozenStartImageFailureTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FrozenImgErr-\(UUID().uuidString)", isDirectory: true)
    let store = FilmProjectStore(projectsDirectory: root)

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    let openingPath = "Assets/OpeningReference/opening.png"

    @discardableResult
    func writeAsset(_ bytes: String, projectID: UUID) -> String {
        guard let url = store.managedProjectAssetURL(
            projectID: projectID, relativePath: openingPath) else { return "" }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(bytes.utf8).write(to: url)
        return sha256(Data(bytes.utf8))
    }

    func removeAsset(projectID: UUID) {
        if let url = store.managedProjectAssetURL(
            projectID: projectID, relativePath: openingPath) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func makeProject() -> FilmProject {
        var project = FilmProject(title: "Fail")
        project.workflowMode = "hybrid"
        project.openingReferenceImage = OpeningReferenceImage(
            projectRelativePath: openingPath, originalFilename: "opening.png")
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "opening scene"),
            Shot(index: 1, title: "Two", compiledPrompt: "second scene"),
        ]
        project.shots[1].continuityMode = .continueFromPrevious
        return project
    }

    func makeStoryboardProject() -> FilmProject {
        var project = FilmProject(title: "FailStory")
        project.workflowMode = "storyboard"
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "opening scene"),
            Shot(index: 1, title: "Two", compiledPrompt: "second scene"),
        ]
        project.shots[0].startingImageReferenceAssetID = UUID()
        project.shots[0].continuityImageRelativePath = openingPath
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
    let hasher: (String) -> String? = { H3EndingImageCapability.contentHash(ofFileAt: $0) }

    t.suite("Frozen start image — a refusal says which picture and why") {

        let project = makeProject()
        writeAsset("opening-bytes", projectID: project.id)
        let job = try! MovieRunSubmission.makeJob(
            project: project, workCount: 1, directorMode: "direct", store: store,
            contentHash: hasher)
        let run = job.snapshot.movieRuns[0]
        let shot0 = run.orderedShots[0]

        // FROZENIMGERR_10 — the healthy case still works, and is not reported
        // as a failure. Asserted first so the ones below mean something.
        t.checkEqual(MovieRunRequestBuilder.verifyFrozenStartImage(
            shot0, projectID: project.id, resolveAsset: resolve, contentHash: hasher), nil,
            "FROZENIMGERR_10 an unchanged explicit image verifies clean")
        t.check(MovieRunRequestBuilder.makeRequest(
            run: run, shotID: shot0.id, parameters: params,
            resolveAsset: resolve, contentHash: hasher) != nil,
            "FROZENIMGERR_10 and still builds a request")

        // FROZENIMGERR_11 — CONTINUE is a different axis and must not be
        // classified as an explicit-image failure.
        let continueShot = run.orderedShots[1]
        t.checkEqual(MovieRunRequestBuilder.verifyFrozenStartImage(
            continueShot, projectID: project.id, resolveAsset: resolve, contentHash: hasher), nil,
            "FROZENIMGERR_11 a CONTINUE shot has no explicit image to verify")
        t.checkEqual(RunDispatchRefusal.classify(
            run: run, shotID: continueShot.id,
            resolveAsset: resolve, contentHash: hasher),
            RunDispatchRefusal.continuationUnavailable,
            "FROZENIMGERR_11 so a CONTINUE refusal is still a dependency problem")

        // FROZENIMGERR_1 — missing: classified as missing, shot state failed.
        removeAsset(projectID: project.id)
        let missing = MovieRunRequestBuilder.verifyFrozenStartImage(
            shot0, projectID: project.id, resolveAsset: resolve, contentHash: hasher)
        t.checkEqual(missing, FrozenStartImageFailure.missing("opening.png"),
                     "FROZENIMGERR_1 a deleted explicit image is classified as missing")
        let missingRefusal = RunDispatchRefusal.classify(
            run: run, shotID: shot0.id, resolveAsset: resolve, contentHash: hasher)
        t.checkEqual(missingRefusal.shotState, ShotRunState.State.failed,
                     "FROZENIMGERR_1 and the shot fails rather than blocking on a dependency")

        // FROZENIMGERR_12 — the text names the file and says what to do, and
        // never leaks the absolute path.
        t.check(missingRefusal.message.contains("opening.png"),
                "FROZENIMGERR_12 the message names the picture")
        t.check(missingRefusal.message.contains("見つかりません"),
                "FROZENIMGERR_12 and says it cannot be found")
        t.check(!missingRefusal.message.contains(root.path),
                "FROZENIMGERR_12 without exposing the library path")
        t.check(!missingRefusal.message.contains("/"),
                "FROZENIMGERR_12 no absolute path at all")

        // FROZENIMGERR_3 / _4 — nothing is dispatched, and no text-to-video.
        let missingRequest = MovieRunRequestBuilder.makeRequest(
            run: run, shotID: shot0.id, parameters: params,
            resolveAsset: resolve, contentHash: hasher)
        t.checkEqual(missingRequest, nil,
                     "FROZENIMGERR_3 a missing explicit image launches no backend request")
        t.checkEqual(missingRequest?.sourceImagePath, nil,
                     "FROZENIMGERR_4 and never falls back to text-to-video")

        // FROZENIMGERR_2 — modified: a *different* classification from missing.
        writeAsset("opening-bytes-EDITED", projectID: project.id)
        let changed = MovieRunRequestBuilder.verifyFrozenStartImage(
            shot0, projectID: project.id, resolveAsset: resolve, contentHash: hasher)
        t.checkEqual(changed, FrozenStartImageFailure.changed("opening.png"),
                     "FROZENIMGERR_2 an edited explicit image is classified as changed")
        let changedRefusal = RunDispatchRefusal.classify(
            run: run, shotID: shot0.id, resolveAsset: resolve, contentHash: hasher)
        t.checkEqual(changedRefusal.shotState, ShotRunState.State.failed,
                     "FROZENIMGERR_2 and the shot fails")
        t.check(changedRefusal.message.contains("変更されています"),
                "FROZENIMGERR_12 the message says the picture changed, not that it vanished")
        t.check(changedRefusal.message != missingRefusal.message,
                "FROZENIMGERR_12 the two causes do not share one sentence")
        t.checkEqual(MovieRunRequestBuilder.makeRequest(
            run: run, shotID: shot0.id, parameters: params,
            resolveAsset: resolve, contentHash: hasher), nil,
            "FROZENIMGERR_3 an edited explicit image launches no backend request")

        // FROZENIMGERR_5 — the parent reaches a terminal state carrying the
        // real reason, rather than "one or more works did not finish".
        var failedRun = run
        failedRun.update(shot0.id) {
            $0.state = changedRefusal.shotState
            $0.failureReason = changedRefusal.message
        }
        t.check(ShotRunState.State.failed.isTerminal,
                "FROZENIMGERR_5 a failed shot is terminal")
        t.check(!ShotRunState.State.failed.needsExecution,
                "FROZENIMGERR_5 so the scheduler stops dispatching it — no infinite retry")
        t.check(failedRun.isSettled,
                "FROZENIMGERR_5 and the run settles rather than staying running")
        let summary = RunFailureSummary.reason(
            shotStates: failedRun.shotStates, fallback: "fallback")
        t.checkEqual(summary, changedRefusal.message,
                     "FROZENIMGERR_5 the job-level reason is the shot's real reason")
        t.check(summary != "fallback",
                "FROZENIMGERR_5 not the generic did-not-finish text")

        // Several works failing the same way is one thing to say, not three.
        let threeAlike = Array(repeating: failedRun.shotStates[0], count: 3)
        t.checkEqual(RunFailureSummary.reason(shotStates: threeAlike, fallback: "fallback"),
                     changedRefusal.message,
                     "FROZENIMGERR_5 identical failures are not repeated back")
        var otherShot = failedRun.shotStates[0]
        otherShot.failureReason = "something else"
        t.check(RunFailureSummary.reason(
            shotStates: [failedRun.shotStates[0], otherShot], fallback: "fallback")
                .contains("ほか 1 件"),
                "FROZENIMGERR_5 but distinct failures are counted")
        t.checkEqual(RunFailureSummary.reason(shotStates: [], fallback: "fallback"),
                     "fallback",
                     "FROZENIMGERR_5 and an unexplained failure keeps the generic text")

        // FROZENIMGERR_9 — Retry re-verifies. The same frozen invalid image
        // must not pass just because the attempt number went up.
        var retried = failedRun
        retried.update(shot0.id) {
            $0.state = .queued
            $0.attemptNumber += 1
            $0.failureReason = nil
        }
        t.checkEqual(MovieRunRequestBuilder.makeRequest(
            run: retried, shotID: shot0.id, parameters: params,
            resolveAsset: resolve, contentHash: hasher), nil,
            "FROZENIMGERR_9 retry does not bypass verification")
        t.checkEqual(RunDispatchRefusal.classify(
            run: retried, shotID: shot0.id,
            resolveAsset: resolve, contentHash: hasher).message,
            changedRefusal.message,
            "FROZENIMGERR_9 and reports the same reason")
        t.checkEqual(retried.orderedShots[0].seed, run.orderedShots[0].seed,
                     "FROZENIMGERR_9 while the frozen seed is untouched")

        // FROZENIMGERR_6 / _7 / _8 — Storyboard behaves identically.
        let storyProject = makeStoryboardProject()
        writeAsset("story-bytes", projectID: storyProject.id)
        let storyJob = try! StoryboardRunSubmission.makeJob(
            project: storyProject, workCount: 1, directorMode: "direct", store: store,
            contentHash: hasher)
        let storyRun = storyJob.snapshot.storyboardRuns[0]
        let storyShot = storyRun.orderedShots[0]

        t.check(StoryboardRunRequestBuilder.makeRequest(
            run: storyRun, shotID: storyShot.id, parameters: params,
            resolveAsset: resolve, contentHash: hasher) != nil,
            "FROZENIMGERR_10 Storyboard: an unchanged image still works")

        removeAsset(projectID: storyProject.id)
        let storyMissing = RunDispatchRefusal.classify(
            run: storyRun, shotID: storyShot.id, resolveAsset: resolve, contentHash: hasher)
        t.checkEqual(storyMissing.shotState, ShotRunState.State.failed,
                     "FROZENIMGERR_6 Storyboard: a missing image fails the shot")
        t.check(storyMissing.message.contains("opening.png"),
                "FROZENIMGERR_6 naming the picture")
        t.checkEqual(StoryboardRunRequestBuilder.makeRequest(
            run: storyRun, shotID: storyShot.id, parameters: params,
            resolveAsset: resolve, contentHash: hasher), nil,
            "FROZENIMGERR_8 Storyboard: no backend request on a missing image")

        writeAsset("story-bytes-EDITED", projectID: storyProject.id)
        let storyChanged = RunDispatchRefusal.classify(
            run: storyRun, shotID: storyShot.id, resolveAsset: resolve, contentHash: hasher)
        t.checkEqual(storyChanged.shotState, ShotRunState.State.failed,
                     "FROZENIMGERR_7 Storyboard: an edited image fails the shot")
        t.check(storyChanged.message.contains("変更されています"),
                "FROZENIMGERR_7 with the changed-not-missing wording")
        t.checkEqual(StoryboardRunRequestBuilder.makeRequest(
            run: storyRun, shotID: storyShot.id, parameters: params,
            resolveAsset: resolve, contentHash: hasher), nil,
            "FROZENIMGERR_8 Storyboard: no backend request on an edited image")

        // Both surfaces word the same cause the same way.
        t.checkEqual(storyChanged.message, changedRefusal.message,
                     "FROZENIMGERR_12 Auto Movie and Storyboard agree on the wording")

        // An unresolvable frozen path is its own case, and still never renders.
        var brokenRun = storyRun
        brokenRun.plan.shots[0].explicitStartImageRelativePath = "Assets/../../escape.png"
        t.checkEqual(RunDispatchRefusal.classify(
            run: brokenRun, shotID: storyShot.id,
            resolveAsset: resolve, contentHash: hasher).shotState,
            ShotRunState.State.failed,
            "FROZENIMGERR_6 an unresolvable frozen path fails the shot too")

        try? FileManager.default.removeItem(at: root)
    }
}
