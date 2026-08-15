import Foundation
@testable import LTXVideoGeneratorCore

/// Preview.3 product policy: Auto Movie is a single continuous sequence.
/// After Shot 1, every shot always continues from the immediately previous
/// shot's actual final frame — never an automatic scene-change cut, never an
/// automatic Identity Refresh substitution, never a silent independent
/// fallback. This file is the acceptance suite for that policy (TEST A–E),
/// separate from `AutoMovieContinuityTests.swift`, which covers the
/// generic Cut/Continue engine still backing manual Storyboards.
func runAutoMovieStrictContinuityPolicyTests(_ t: TestKit) {

    let fixtureA = TestFixtures.videoWithAudioA
    let fixtureB = TestFixtures.videoWithAudioB
    let hasFixtures = FileManager.default.fileExists(atPath: fixtureA)
        && FileManager.default.fileExists(atPath: fixtureB)
        && FinalAssemblyService.ffmpegPath() != nil

    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-strict-policy-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    func makeStore(_ name: String) -> FilmProjectStore {
        FilmProjectStore(projectsDirectory: tmpRoot.appendingPathComponent(name, isDirectory: true))
    }

    func makeProject(store: FilmProjectStore, shotCount: Int) -> FilmProject {
        var project = FilmProject(title: "Strict Policy Test")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        for index in 0..<shotCount {
            var shot = Shot(index: index, title: "Shot \(index + 1)", summary: "beat \(index + 1)")
            shot.compiledPrompt = "beat \(index + 1)"
            shot.durationSeconds = 1
            shot.continuityMode = index == 0 ? .cut : .auto
            project.shots.append(shot)
        }
        store.save(project)
        return store.project(id: project.id)!
    }

    /// Replaces the shot's takes with one completed take, as if the queued
    /// take `advance()` planned had finished rendering (mirrors the pattern
    /// used in `AutoMovieContinuityTests.swift`: a still-`.queued` take left
    /// in place would otherwise keep `hasGenerationInFlight` true forever).
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

    /// Clears any in-flight (queued/generating) takes for a shot before
    /// completing it, so `advance()` does not see a stale in-flight take.
    func settle(store: FilmProjectStore, projectID: UUID, shotIndex: Int) {
        var project = store.project(id: projectID)!
        project.shots[shotIndex].takes.removeAll { $0.status == .queued || $0.status == .generating }
        store.save(project)
    }

    /// Advances one step and returns the pending requests, or nil on a step
    /// that enqueues nothing.
    func advanceOnce(_ coordinator: AutoMovieRunCoordinator, projectID: UUID) -> (AutoMovieRunCoordinator.RunStep, [GenerationRequest]) {
        var pending: [GenerationRequest] = []
        let step = coordinator.advance(projectID: projectID) { pending = $0 }
        return (step, pending)
    }

    guard hasFixtures else {
        t.suite("Auto Movie strict continuity policy") {
            t.check(true, "fixture videos unavailable — strict policy acceptance skipped")
        }
        return
    }

    // MARK: - TEST A: strict four-shot chain

    t.suite("TEST A — strict four-shot Auto Movie") {
        let store = makeStore("test-a")
        let project = makeProject(store: store, shotCount: 4)
        let coordinator = AutoMovieRunCoordinator(store: store)

        // Shot 1: existing first-shot behaviour — never continues.
        t.checkEqual(coordinator.autoMovieContinuityMode(forShotAt: 0, in: project), .cut,
                     "Shot 1 keeps existing first-shot behaviour")

        var videoPaths = [fixtureA, fixtureB, fixtureA]
        for shotIndex in 0..<3 {
            let (step, pending) = advanceOnce(coordinator, projectID: project.id)
            guard case .enqueued = step else {
                t.check(false, "expected shot \(shotIndex + 1) to enqueue, got \(step)")
                continue
            }
            if shotIndex > 0 {
                t.check(pending.first?.sourceImagePath != nil,
                        "Shot \(shotIndex + 1): continues from the previous shot's frame")
                t.check(pending.first?.isImageToVideo == true,
                        "Shot \(shotIndex + 1): executes as Last Frame I2V")
            } else {
                t.check(pending.first?.sourceImagePath == nil,
                        "Shot 1: no previous shot to inherit from")
            }
            settle(store: store, projectID: project.id, shotIndex: shotIndex)
            _ = completeShot(store: store, projectID: project.id, shotIndex: shotIndex,
                             videoPath: videoPaths.removeFirst())
        }

        // Shot 4 — the final shot — also continues.
        let (finalStep, finalPending) = advanceOnce(coordinator, projectID: project.id)
        guard case .enqueued = finalStep else {
            t.check(false, "expected Shot 4 to enqueue, got \(finalStep)")
            return
        }
        t.check(finalPending.first?.sourceImagePath != nil, "Shot 4: continue")
        t.check(finalPending.first?.isImageToVideo == true, "Shot 4: continue")

        let saved = store.project(id: project.id)!
        t.checkEqual(saved.shots[1].continuitySourceTakeID, saved.shots[0].takes.first?.id,
                     "Shot 2's continuity source is Shot 1's completed Take")
        t.checkEqual(saved.shots[2].continuitySourceTakeID, saved.shots[1].takes.first?.id,
                     "Shot 3's continuity source is Shot 2's completed Take")
        t.checkEqual(saved.shots[3].continuitySourceTakeID, saved.shots[2].takes.first?.id,
                     "Shot 4's continuity source is Shot 3's completed Take")
    }

    // MARK: - TEST B: scene change does not cut

    t.suite("TEST B — scene change does not cut") {
        let store = makeStore("test-b")
        var project = makeProject(store: store, shotCount: 4)

        // A Director plan with an explicit scene change at every later shot —
        // each of these would resolve to `.cut` under the generic engine.
        project.shots[1].explicitChanges = ["location=corridor"]
        var beforeLocation = ContinuitySnapshot(); beforeLocation.location = "study"
        var afterLocation = ContinuitySnapshot(); afterLocation.location = "corridor"
        project.shots[0].continuityBefore = beforeLocation
        project.shots[1].continuityBefore = afterLocation

        project.shots[2].explicitChanges = ["timeOfDay=night"]
        var afterTime = ContinuitySnapshot(); afterTime.location = "corridor"; afterTime.timeOfDay = "night"
        project.shots[1].continuityBefore?.timeOfDay = "day"
        project.shots[2].continuityBefore = afterTime

        project.shots[3].camera.shotScale = "wide"
        project.shots[2].camera.shotScale = "medium"
        var afterExterior = ContinuitySnapshot(); afterExterior.location = "exterior courtyard"
        project.shots[3].continuityBefore = afterExterior
        store.save(project)
        project = store.project(id: project.id)!

        let coordinator = AutoMovieRunCoordinator(store: store)

        // Sanity check: the generic engine really would cut every one of
        // these under the old Director-driven heuristic.
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 1, in: project), .cut,
                     "sanity: the generic engine would cut on the location change")
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 2, in: project), .cut,
                     "sanity: the generic engine would cut on the time-of-day change")
        t.checkEqual(coordinator.resolvedContinuityMode(forShotAt: 3, in: project), .cut,
                     "sanity: the generic engine would cut on the widening establishing shot")

        // Auto Movie's own policy ignores all of it.
        t.checkEqual(coordinator.autoMovieContinuityMode(forShotAt: 1, in: project), .continueFromPrevious,
                     "Shot 2 still continues despite the location change")
        t.checkEqual(coordinator.autoMovieContinuityMode(forShotAt: 2, in: project), .continueFromPrevious,
                     "Shot 3 still continues despite the time-of-day change")
        t.checkEqual(coordinator.autoMovieContinuityMode(forShotAt: 3, in: project), .continueFromPrevious,
                     "Shot 4 still continues despite the widening establishing shot")

        var automaticCutCount = 0
        var videoPaths = [fixtureA, fixtureB, fixtureA]
        for shotIndex in 0..<3 {
            let (step, pending) = advanceOnce(coordinator, projectID: project.id)
            guard case .enqueued = step else {
                t.check(false, "expected shot \(shotIndex + 1) to enqueue, got \(step)")
                continue
            }
            if shotIndex > 0, pending.first?.sourceImagePath == nil { automaticCutCount += 1 }
            settle(store: store, projectID: project.id, shotIndex: shotIndex)
            _ = completeShot(store: store, projectID: project.id, shotIndex: shotIndex,
                             videoPath: videoPaths.removeFirst())
        }
        let (finalStep, finalPending) = advanceOnce(coordinator, projectID: project.id)
        if case .enqueued = finalStep {
            if finalPending.first?.sourceImagePath == nil { automaticCutCount += 1 }
        } else {
            t.check(false, "expected Shot 4 to enqueue, got \(finalStep)")
        }
        t.checkEqual(automaticCutCount, 0, "automatic cut count after Shot 1 is zero")
    }

    // MARK: - TEST C: no auto identity refresh

    t.suite("TEST C — no automatic Identity Refresh") {
        let store = makeStore("test-c")
        var project = makeProject(store: store, shotCount: 4)
        project.openingReferenceImage = OpeningReferenceImage(
            projectRelativePath: "Assets/OpeningReference/o.png",
            originalFilename: "o.png", mimeType: "image/png", fileSizeBytes: 1)
        // A tight close-up is exactly the framing that used to make Adaptive
        // Identity Refresh's heuristic fire.
        project.shots[2].camera.shotScale = "extreme-close-up"
        project.shots[3].camera.shotScale = "extreme-close-up"
        store.save(project)
        project = store.project(id: project.id)!

        let coordinator = AutoMovieRunCoordinator(store: store)

        _ = completeShot(store: store, projectID: project.id, shotIndex: 0, videoPath: fixtureA)
        // Auto Movie's coordinator never opts into Identity Refresh, for any
        // shot, regardless of framing.
        t.check(coordinator.prepareNextShotContinuity(projectID: project.id) == nil,
                "Auto Movie never triggers Adaptive Identity Refresh preparation")

        _ = advanceOnce(coordinator, projectID: project.id) // enqueues shot 2
        settle(store: store, projectID: project.id, shotIndex: 1)
        _ = completeShot(store: store, projectID: project.id, shotIndex: 1, videoPath: fixtureB)
        t.check(coordinator.prepareNextShotContinuity(projectID: project.id) == nil,
                "still never triggers, even for a tight close-up shot")

        let (step3, pending3) = advanceOnce(coordinator, projectID: project.id) // enqueues shot 3
        guard case .enqueued = step3 else {
            t.check(false, "expected Shot 3 to enqueue, got \(step3)")
            return
        }
        let saved3 = store.project(id: project.id)!
        t.check(pending3.first?.sourceImagePath?.contains("OpeningReference") == false,
                "Shot 3 does not fall back to the Opening Reference")
        t.checkEqual(saved3.shots[2].continuitySourceTakeID, saved3.shots[1].takes.first?.id,
                     "Shot 3's source is Shot 2's own final frame")
        t.check(saved3.shots[2].identityRefreshAnchorRelativePath == nil,
                "Shot 3 has no Identity Refresh anchor")

        settle(store: store, projectID: project.id, shotIndex: 2)
        _ = completeShot(store: store, projectID: project.id, shotIndex: 2, videoPath: fixtureA)
        let (step4, pending4) = advanceOnce(coordinator, projectID: project.id) // enqueues shot 4
        guard case .enqueued = step4 else {
            t.check(false, "expected Shot 4 to enqueue, got \(step4)")
            return
        }
        let saved4 = store.project(id: project.id)!
        t.check(pending4.first?.sourceImagePath?.contains("OpeningReference") == false,
                "Shot 4 does not fall back to the Opening Reference either")
        t.checkEqual(saved4.shots[3].continuitySourceTakeID, saved4.shots[2].takes.first?.id,
                     "Shot 4's source is Shot 3's own final frame")
        t.check(saved4.shots[3].identityRefreshAnchorRelativePath == nil,
                "Shot 4 has no Identity Refresh anchor")
    }

    // MARK: - TEST D: selected Take controls the next shot's source

    t.suite("TEST D — selected Take controls the next shot's source") {
        let store = makeStore("test-d")
        let project = makeProject(store: store, shotCount: 2)
        let coordinator = AutoMovieRunCoordinator(store: store)

        let takeA = completeShot(store: store, projectID: project.id, shotIndex: 0,
                                 videoPath: fixtureA, selected: false)
        let takeB = completeShot(store: store, projectID: project.id, shotIndex: 0,
                                 videoPath: fixtureB, selected: true)
        t.check(takeA != takeB, "two distinct Takes exist for Shot 1")

        let (step, pending) = advanceOnce(coordinator, projectID: project.id)
        guard case .enqueued = step else {
            t.check(false, "expected Shot 2 to enqueue, got \(step)")
            return
        }
        t.check(pending.first?.sourceImagePath != nil, "Shot 2 inherits a frame")
        let saved = store.project(id: project.id)!
        t.checkEqual(saved.shots[1].continuitySourceTakeID, takeB,
                     "the selected Take (B), not the first-completed Take (A), is the continuity source")
    }

    // MARK: - TEST E: cancel / failure stop the chain

    t.suite("TEST E — cancel, failure and frame-extraction-failure stop the chain") {
        // Cancelled: the next shot is never enqueued.
        let cancelStore = makeStore("test-e-cancel")
        let cancelProject = makeProject(store: cancelStore, shotCount: 2)
        _ = completeShot(store: cancelStore, projectID: cancelProject.id, shotIndex: 0, videoPath: fixtureA)
        var cancelled = cancelStore.project(id: cancelProject.id)!
        var cancelledTake = Take(
            shotID: cancelled.shots[1].id, modelID: "m", seed: 3,
            promptSnapshot: "p", settingsSnapshot: .default,
            requestedWidth: 512, requestedHeight: 320, fps: 24,
            requestedDuration: 1, status: .cancelled)
        cancelledTake.outputPath = nil
        cancelled.shots[1].takes = [cancelledTake]
        cancelStore.save(cancelled)
        let (cancelStep, cancelPending) = advanceOnce(
            AutoMovieRunCoordinator(store: cancelStore), projectID: cancelProject.id)
        if case .shotFailed = cancelStep {
            t.check(true, "a cancelled shot stops the chain")
        } else {
            t.check(false, "expected shotFailed after cancellation, got \(cancelStep)")
        }
        t.checkEqual(cancelPending.count, 0, "next backend invocation = 0 after cancellation")

        // Failed: the next shot is never enqueued.
        let failStore = makeStore("test-e-fail")
        let failProject = makeProject(store: failStore, shotCount: 2)
        _ = completeShot(store: failStore, projectID: failProject.id, shotIndex: 0, videoPath: fixtureA)
        var failed = failStore.project(id: failProject.id)!
        var failedTake = Take(
            shotID: failed.shots[1].id, modelID: "m", seed: 4,
            promptSnapshot: "p", settingsSnapshot: .default,
            requestedWidth: 512, requestedHeight: 320, fps: 24,
            requestedDuration: 1, status: .failed)
        failedTake.outputPath = nil
        failed.shots[1].takes = [failedTake]
        failStore.save(failed)
        let (failStep, failPending) = advanceOnce(
            AutoMovieRunCoordinator(store: failStore), projectID: failProject.id)
        if case .shotFailed = failStep {
            t.check(true, "a failed shot stops the chain")
        } else {
            t.check(false, "expected shotFailed after failure, got \(failStep)")
        }
        t.checkEqual(failPending.count, 0, "next backend invocation = 0 after failure")

        // Frame extraction failure (previous shot's output missing): blocked,
        // not queued.
        let missingStore = makeStore("test-e-missing")
        let missingProject = makeProject(store: missingStore, shotCount: 2)
        _ = completeShot(
            store: missingStore, projectID: missingProject.id, shotIndex: 0,
            videoPath: tmpRoot.appendingPathComponent("does-not-exist.mp4").path)
        let (missingStep, missingPending) = advanceOnce(
            AutoMovieRunCoordinator(store: missingStore), projectID: missingProject.id)
        if case .blocked(_, let reason) = missingStep {
            t.checkEqual(reason, .previousOutputMissing,
                         "frame extraction failure is reported instead of a silent fallback")
        } else {
            t.check(false, "expected blocked after frame extraction failure, got \(missingStep)")
        }
        t.checkEqual(missingPending.count, 0, "next backend invocation = 0 after frame extraction failure")
    }

    // MARK: - TEST F: legacy completed projects preserve historical display

    t.suite("TEST F — legacy Auto Movie history is not rewritten by preview.3") {
        let store = makeStore("test-f-legacy")
        var project = makeProject(store: store, shotCount: 4)
        project.shots[3].continuityMode = .cut
        var historicalCutTake = Take(
            shotID: project.shots[3].id, modelID: "legacy-model", seed: 404,
            promptSnapshot: "historical exterior cut",
            settingsSnapshot: .default, requestedWidth: 512, requestedHeight: 320,
            fps: 24, requestedDuration: 1, status: .completed
        )
        historicalCutTake.outputPath = fixtureA
        historicalCutTake.sourceImagePath = nil
        historicalCutTake.generationCompletedAt = Date(timeIntervalSince1970: 404)
        project.shots[3].takes = [historicalCutTake]
        project.shots[3].selectedTakeID = historicalCutTake.id
        store.save(project)

        let before = store.project(id: project.id)!
        let outputBytesBefore = try? Data(contentsOf: URL(fileURLWithPath: fixtureA))
        let preview = AutoMoviePlanPreview.make(project: before)
        let after = store.project(id: project.id)!

        t.checkEqual(preview.rows[3].continuityIntent, "Cut",
                     "a legacy completed Shot 4 still displays its historical Cut")
        t.checkEqual(
            AutoMovieRunCoordinator(store: store)
                .displayedAutoMovieContinuityMode(forShotAt: 3, in: before),
            .cut,
            "the Shot Card presentation resolver preserves the historical Cut")
        t.checkEqual(
            AutoMovieRunCoordinator(store: store)
                .autoMovieContinuityMode(forShotAt: 3, in: before),
            .continueFromPrevious,
            "a future new Shot 4 generation still uses preview.3 strict Continue")
        t.checkEqual(after, before, "opening/previewing the project does not mutate persisted metadata or Takes")
        t.checkEqual(try? Data(contentsOf: URL(fileURLWithPath: fixtureA)), outputBytesBefore,
                     "opening/previewing the project does not mutate the historical output")
    }
}
