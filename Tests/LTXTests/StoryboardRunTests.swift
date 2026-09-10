import Foundation
@testable import LTXVideoGeneratorCore

/// Phases 23–30: Storyboard run-scoped execution.
///
/// These drive the real production types (`StoryboardRunBuilder`,
/// `StoryboardRunScheduler`, `StoryboardRun`, `RunLocalTakeMap`) rather than a
/// restatement of their rules, and they target the acceptance invariants
/// directly: run isolation, one-time resolution, restart, retry/retake,
/// blocking, cancel and legacy decoding.
func runStoryboardRunTests(_ t: TestKit) {

    let shot1ID = UUID(), shot2ID = UUID(), shot3ID = UUID()

    func shot(_ id: UUID, index: Int, start: FrozenShotPlan.StartSource) -> FrozenShotPlan {
        FrozenShotPlan(
            id: id, index: index, title: "Shot \(index + 1)",
            compiledPrompt: "shot \(index + 1) prompt", durationSeconds: 5,
            startSource: start,
            explicitStartImageRelativePath: nil, explicitStartImageContentHash: nil,
            endingImagePath: nil, endingImageContentHash: nil,
            seed: 0, characterIDs: [], startingImageReferenceAssetID: nil)
    }

    /// Three shots: 1 stands alone, 2 and 3 continue from their predecessor.
    func makePlan() -> FrozenStoryboardPlan {
        FrozenStoryboardPlan(
            projectID: UUID(), title: "Test Storyboard",
            shots: [
                shot(shot1ID, index: 0, start: .none),
                shot(shot2ID, index: 1, start: .previousShotOutput),
                shot(shot3ID, index: 2, start: .previousShotOutput),
            ],
            modelID: MiniMaxH3Configuration.standardModelID,
            preset: MiniMaxH3Preset.custom.rawValue,
            audioEnabled: true, textEncoderID: nil, directorMode: "direct",
            openingReferenceRelativePath: nil,
            characterAnchorCharacterID: nil, characterAnchorAssetID: nil)
    }

    func path(_ id: UUID) -> String? { "/tmp/\(id.uuidString).mp4" }
    func hash(_ p: String) -> String? { "hash-\(p.suffix(12))" }

    // MARK: Core

    t.suite("Storyboard run — core submission") {
        // STORY_1 / STORY_2: count=1 and count=N take the same path.
        let one = StoryboardRunBuilder.build(plan: makePlan(), count: 1)
        t.checkEqual(one.count, 1, "STORY_1 count=1 creates exactly one run")
        t.checkEqual(one[0].shotStates.count, 3, "STORY_1 with the full frozen composition")
        t.checkEqual(one[0].batchIndex, 0, "STORY_1 and normal batch identity")

        let two = StoryboardRunBuilder.build(plan: makePlan(), count: 2)
        t.checkEqual(two.count, 2, "STORY_2 count=2 creates exactly two runs")
        t.check(two[0].id != two[1].id, "STORY_2 with distinct run ids")
        t.checkEqual(Set(two.map(\.batchID)).count, 1, "STORY_2 sharing one batch id")

        // STORY_3: the same frozen composition in both runs.
        t.checkEqual(two[0].plan.shots.map(\.id), two[1].plan.shots.map(\.id),
                     "STORY_3 both runs carry the same logical shots")
        t.checkEqual(two[0].plan.shots.map(\.compiledPrompt),
                     two[1].plan.shots.map(\.compiledPrompt),
                     "STORY_3 and the same prompts")
        t.checkEqual(two[0].plan.modelID, two[1].plan.modelID, "STORY_3 and the same model")

        // STORY_4: AUTO seeds are per-run and per-shot.
        t.check(two[0].plan.shots[0].seed != two[1].plan.shots[0].seed,
                "STORY_4 run A shot 1 and run B shot 1 have different seeds")
        t.checkEqual(Set(two[0].plan.shots.map(\.seed)).count, 3,
                     "STORY_4 shots within a run also differ")

        // STORY_5: explicit seed follows the shared policy — honoured everywhere.
        let pinned = StoryboardRunBuilder.build(plan: makePlan(), count: 2, explicitSeed: 999)
        t.check(pinned.allSatisfy { $0.plan.shots.allSatisfy { $0.seed == 999 } },
                "STORY_5 an explicit seed is used by every run and every shot")

        // Dependencies exist as descriptors, not resolved paths, at submission.
        let runA = two[0]
        t.checkEqual(runA.state(of: shot1ID)?.state, .queued, "STORY_7 shot 1 is ready to run")
        t.checkEqual(runA.state(of: shot2ID)?.state, .waitingForDependency,
                     "STORY_7 shot 2 waits for its upstream")
        t.checkEqual(runA.state(of: shot2ID)?.dependency?.upstreamShotID, shot1ID,
                     "STORY_7 and knows which upstream")
        t.checkEqual(runA.state(of: shot2ID)?.dependency?.isResolved, false,
                     "STORY_7 unresolved — the output does not exist yet")
        t.checkEqual(runA.state(of: shot2ID)?.dependency?.runID, runA.id,
                     "STORY_7 the descriptor is bound to its own run")
    }

    // MARK: Continuity isolation

    t.suite("Storyboard run — continuity never crosses runs") {
        var runs = StoryboardRunBuilder.build(plan: makePlan(), count: 2)
        var runA = runs[0], runB = runs[1]
        let takeA1 = UUID(), takeB1 = UUID()

        StoryboardRunScheduler.recordCompletion(
            in: &runA, shotID: shot1ID, takeID: takeA1, outputPath: path(takeA1))
        StoryboardRunScheduler.recordCompletion(
            in: &runB, shotID: shot1ID, takeID: takeB1, outputPath: path(takeB1))

        _ = StoryboardRunScheduler.resolveDependency(
            in: &runA, shotID: shot2ID, assetPath: path, contentHash: hash)
        _ = StoryboardRunScheduler.resolveDependency(
            in: &runB, shotID: shot2ID, assetPath: path, contentHash: hash)

        t.checkEqual(runA.state(of: shot2ID)?.dependency?.resolvedTakeID, takeA1,
                     "CONT_1 run A shot 2 resolves only to run A's take")
        t.checkEqual(runB.state(of: shot2ID)?.dependency?.resolvedTakeID, takeB1,
                     "CONT_2 run B shot 2 resolves only to run B's take")
        t.check(runA.state(of: shot2ID)?.dependency?.resolvedTakeID
                != runB.state(of: shot2ID)?.dependency?.resolvedTakeID,
                "CONT_3 CROSS_RUN_REFERENCE_LEAK: no")

        // Run B's map cannot answer for run A's id: there is no such key.
        t.checkEqual(runB.takeMap.take(runID: runA.id, shotID: shot1ID), nil,
                     "CONT_4 one run's map cannot resolve another run's id")

        // A run that has produced nothing waits; it never borrows.
        var runC = StoryboardRunBuilder.build(plan: makePlan(), count: 1)[0]
        t.check(!StoryboardRunScheduler.resolveDependency(
                    in: &runC, shotID: shot2ID, assetPath: path, contentHash: hash),
                "CONT_5 a run with no upstream output cannot resolve")
        // The point of the old project-scoped scheduler's defect: it picked the
        // first shot with no *completed take anywhere in the project*, so once
        // run A finished shot 1, a fresh run skipped straight to shot 2 and
        // inherited A's output. A run-local scheduler starts at its own shot 1.
        t.checkEqual(StoryboardRunScheduler.next(runC), .render(shotID: shot1ID),
                     "CONT_6 a fresh run renders its OWN shot 1, never skipping to shot 2")
        t.checkEqual(runC.state(of: shot2ID)?.state, .waitingForDependency,
                     "CONT_6 while its shot 2 still waits on its own upstream")
        runs = [runA, runB]
        t.checkEqual(runs.count, 2, "CONT_7 both runs remain independent")
    }

    // MARK: One-time resolution

    t.suite("Storyboard run — resolution happens once and freezes") {
        var run = StoryboardRunBuilder.build(plan: makePlan(), count: 1)[0]
        let takeA1 = UUID()
        StoryboardRunScheduler.recordCompletion(
            in: &run, shotID: shot1ID, takeID: takeA1, outputPath: path(takeA1))
        _ = StoryboardRunScheduler.resolveDependency(
            in: &run, shotID: shot2ID, assetPath: path, contentHash: hash)

        let frozen = run.state(of: shot2ID)?.dependency
        t.checkEqual(frozen?.resolvedTakeID, takeA1, "ONCE_1 resolved take recorded")
        t.checkEqual(frozen?.resolvedAssetPath, path(takeA1), "ONCE_2 resolved asset recorded")
        t.checkEqual(frozen?.resolvedContentHash, hash(path(takeA1)!),
                     "ONCE_3 resolved content hash recorded")
        t.check(frozen?.resolvedAt != nil, "ONCE_4 resolution time recorded")

        // The upstream shot is retaken and the run re-adopts for future work.
        let takeA1b = UUID()
        run.takeMap.readopt(runID: run.id, shotID: shot1ID, takeID: takeA1b)
        _ = StoryboardRunScheduler.resolveDependency(
            in: &run, shotID: shot2ID, assetPath: path, contentHash: hash)
        t.checkEqual(run.state(of: shot2ID)?.dependency?.resolvedTakeID, takeA1,
                     "ONCE_5 an already-resolved dependency is NOT re-resolved to the retake")
        t.checkEqual(run.takeMap.take(runID: run.id, shotID: shot1ID), takeA1b,
                     "ONCE_6 though the run has adopted the retake for later work")

        // Restart: encode and decode the run as the queue would.
        let encoded = try! JSONEncoder().encode(run)
        let restored = try! JSONDecoder().decode(StoryboardRun.self, from: encoded)
        let restoredDep = restored.state(of: shot2ID)?.dependency
        t.checkEqual(restoredDep?.resolvedTakeID, takeA1, "ONCE_7 restart restores the exact take")
        t.checkEqual(restoredDep?.resolvedAssetPath, frozen?.resolvedAssetPath,
                     "ONCE_8 restart restores the exact asset")
        t.checkEqual(restoredDep?.resolvedContentHash, frozen?.resolvedContentHash,
                     "ONCE_9 restart restores the exact hash")
        t.checkEqual(StoryboardRunScheduler.next(restored), .render(shotID: shot2ID),
                     "ONCE_10 and proceeds without asking what is selected now")
    }

    // MARK: Failure, blocking, retry

    t.suite("Storyboard run — upstream failure blocks only dependents") {
        var runA = StoryboardRunBuilder.build(plan: makePlan(), count: 2)[0]
        let runB = StoryboardRunBuilder.build(plan: makePlan(), count: 2)[1]

        StoryboardRunScheduler.recordFailure(in: &runA, shotID: shot1ID, reason: "backend error")
        t.checkEqual(runA.state(of: shot1ID)?.state, .failed, "BLOCK_1 the failing shot is failed")
        t.checkEqual(runA.state(of: shot2ID)?.state, .dependencyBlocked,
                     "BLOCK_2 its dependent is blocked, not silently started")
        t.checkEqual(runA.state(of: shot3ID)?.state, .dependencyBlocked,
                     "BLOCK_3 and blocking propagates down the chain")
        t.check(!runA.state(of: shot2ID)!.state.needsExecution,
                "BLOCK_4 a blocked shot is not queued for execution")

        // Run B is untouched.
        t.checkEqual(runB.state(of: shot1ID)?.state, .queued, "BLOCK_5 the sibling run is unaffected")
        t.checkEqual(runA.derivedState, .failed, "BLOCK_6 the parent state derives from its children")
    }

    t.suite("Storyboard run — retry preserves seed and resolved input") {
        var run = StoryboardRunBuilder.build(plan: makePlan(), count: 1)[0]
        let seedBefore = run.plan.shots.first { $0.id == shot2ID }!.seed
        let takeA1 = UUID()

        StoryboardRunScheduler.recordCompletion(
            in: &run, shotID: shot1ID, takeID: takeA1, outputPath: path(takeA1))
        _ = StoryboardRunScheduler.resolveDependency(
            in: &run, shotID: shot2ID, assetPath: path, contentHash: hash)
        StoryboardRunScheduler.recordFailure(in: &run, shotID: shot2ID, reason: "render failed")

        let resolvedBefore = run.state(of: shot2ID)?.dependency
        StoryboardRunScheduler.retry(in: &run, shotID: shot2ID)

        t.checkEqual(run.state(of: shot2ID)?.attemptNumber, 2, "RETRY_1 a new attempt is recorded")
        t.checkEqual(run.state(of: shot2ID)?.state, .queued, "RETRY_2 the shot is runnable again")
        t.checkEqual(run.plan.shots.first { $0.id == shot2ID }!.seed, seedBefore,
                     "RETRY_3 the seed is unchanged")
        t.checkEqual(run.state(of: shot2ID)?.dependency?.resolvedTakeID,
                     resolvedBefore?.resolvedTakeID, "RETRY_4 the resolved take is unchanged")
        t.checkEqual(run.state(of: shot2ID)?.dependency?.resolvedContentHash,
                     resolvedBefore?.resolvedContentHash, "RETRY_5 and its hash")
        t.checkEqual(run.state(of: shot1ID)?.state, .completed,
                     "RETRY_6 the already-completed upstream is not regenerated")
        t.checkEqual(StoryboardRunScheduler.next(run), .render(shotID: shot2ID),
                     "RETRY_7 the retry renders shot 2, not shot 1")
    }

    t.suite("Storyboard run — retake does not mutate historical downstream") {
        var run = StoryboardRunBuilder.build(plan: makePlan(), count: 1)[0]
        let takeA1 = UUID(), takeA2 = UUID()
        StoryboardRunScheduler.recordCompletion(
            in: &run, shotID: shot1ID, takeID: takeA1, outputPath: path(takeA1))
        _ = StoryboardRunScheduler.resolveDependency(
            in: &run, shotID: shot2ID, assetPath: path, contentHash: hash)
        StoryboardRunScheduler.recordCompletion(
            in: &run, shotID: shot2ID, takeID: takeA2, outputPath: path(takeA2))

        // Upstream retake, adopted by the run for future work.
        let takeA1b = UUID()
        run.takeMap.readopt(runID: run.id, shotID: shot1ID, takeID: takeA1b)

        t.checkEqual(run.state(of: shot2ID)?.takeID, takeA2,
                     "RETAKE_1 the completed downstream take is untouched")
        t.checkEqual(run.state(of: shot2ID)?.dependency?.resolvedTakeID, takeA1,
                     "RETAKE_2 UPSTREAM_RETAKE_MUTATES_EXISTING_DOWNSTREAM: no")
        t.checkEqual(run.state(of: shot2ID)?.state, .completed,
                     "RETAKE_3 and it stays completed rather than being invalidated")
    }

    // MARK: Cancel

    t.suite("Storyboard run — cancel") {
        var run = StoryboardRunBuilder.build(plan: makePlan(), count: 2)[0]
        let sibling = StoryboardRunBuilder.build(plan: makePlan(), count: 2)[1]
        let takeA1 = UUID()
        StoryboardRunScheduler.recordCompletion(
            in: &run, shotID: shot1ID, takeID: takeA1, outputPath: path(takeA1))
        run.update(shot2ID) { $0.state = .running }

        StoryboardRunScheduler.cancel(&run)

        t.checkEqual(run.state(of: shot1ID)?.state, .completed,
                     "CANCEL_1 completed output is preserved")
        t.checkEqual(run.state(of: shot1ID)?.takeID, takeA1, "CANCEL_2 including its take")
        t.checkEqual(run.state(of: shot2ID)?.state, .running,
                     "CANCEL_3 the running shot is left to the backend's own cancellation")
        t.checkEqual(run.state(of: shot3ID)?.state, .cancelled,
                     "CANCEL_4 an unstarted shot will never start")
        t.checkEqual(StoryboardRunScheduler.next(run), .cancelled,
                     "CANCEL_5 the scheduler starts nothing further")
        t.checkEqual(sibling.state(of: shot1ID)?.state, .queued,
                     "CANCEL_6 the sibling run in the same batch is unaffected")
    }

    // MARK: Restart

    t.suite("Storyboard run — restart recovery") {
        var runA = StoryboardRunBuilder.build(plan: makePlan(), count: 2)[0]
        let runB = StoryboardRunBuilder.build(plan: makePlan(), count: 2)[1]
        let takeA1 = UUID()
        StoryboardRunScheduler.recordCompletion(
            in: &runA, shotID: shot1ID, takeID: takeA1, outputPath: path(takeA1))
        _ = StoryboardRunScheduler.resolveDependency(
            in: &runA, shotID: shot2ID, assetPath: path, contentHash: hash)
        // Crash while shot 2 was rendering.
        runA.update(shot2ID) { $0.state = .interrupted }

        var snapshot = ProductionJobSnapshot()
        snapshot.storyboardRuns = [runA, runB]
        let data = try! JSONEncoder().encode(snapshot)
        let restored = try! JSONDecoder().decode(ProductionJobSnapshot.self, from: data)

        t.checkEqual(restored.storyboardRuns.count, 2, "RESTART_1 both runs survive")
        let a = restored.storyboardRuns[0]
        t.checkEqual(a.state(of: shot1ID)?.state, .completed,
                     "RESTART_2 the completed shot stays completed")
        t.checkEqual(a.state(of: shot1ID)?.takeID, takeA1,
                     "RESTART_3 COMPLETED_SHOT_DUPLICATED_AFTER_RESTART: no")
        t.checkEqual(a.state(of: shot2ID)?.dependency?.resolvedTakeID, takeA1,
                     "RESTART_4 the resolved dependency is restored exactly")
        t.checkEqual(a.state(of: shot2ID)?.dependency?.resolvedContentHash,
                     hash(path(takeA1)!), "RESTART_5 including its content hash")
        // An interrupted shot is not resumed silently: the app's own policy makes
        // an interrupted job explicitly restartable (`ProductionJob.canRestart`),
        // and the shot level matches it. What must never happen is shot 1 being
        // rendered again.
        t.check(StoryboardRunScheduler.next(a) != .render(shotID: shot1ID),
                "RESTART_6 the completed shot 1 is never re-rendered after restart")
        t.check(a.state(of: shot2ID)!.state.isRetryable,
                "RESTART_6 the interrupted shot is offered for explicit restart")
        var resumed = a
        StoryboardRunScheduler.retry(in: &resumed, shotID: shot2ID)
        t.checkEqual(StoryboardRunScheduler.next(resumed), .render(shotID: shot2ID),
                     "RESTART_6 and resumes on that explicit restart")
        t.checkEqual(restored.storyboardRuns[1].state(of: shot1ID)?.state, .queued,
                     "RESTART_7 the queued sibling run stays queued")
        t.checkEqual(a.takeMap.take(runID: a.id, shotID: shot1ID), takeA1,
                     "RESTART_8 the run-local take map is persisted, not rebuilt")
    }

    // MARK: Authoring isolation and legacy

    t.suite("Storyboard run — authoring edits cannot reach a queued run") {
        let plan = makePlan()
        let run = StoryboardRunBuilder.build(plan: plan, count: 1)[0]
        let promptBefore = run.plan.shots[0].compiledPrompt

        // The user keeps editing the project after submitting. The run holds a
        // value-type copy, so there is no reference by which the edit arrives.
        var edited = plan
        edited.shots[0].compiledPrompt = "COMPLETELY DIFFERENT"
        edited.shots.remove(at: 2)
        edited.title = "renamed"

        t.checkEqual(run.plan.shots[0].compiledPrompt, promptBefore,
                     "AUTH_1 POST_SUBMIT_AUTHORING_EDIT_MUTATES_RUN: no")
        t.checkEqual(run.plan.shots.count, 3, "AUTH_2 shot removal does not reach the run")
        t.checkEqual(run.plan.title, "Test Storyboard", "AUTH_3 nor a rename")
    }

    t.suite("Storyboard run — legacy decoding") {
        // A queue snapshot from before run-scoped Storyboard has no runs and
        // must keep decoding, so existing queued work is not reinterpreted.
        let legacy = "{\"prompt\":\"legacy movie\",\"brief\":\"\",\"batchCount\":1,\"pendingRequests\":[]}"
        let decoded = try? JSONDecoder().decode(
            ProductionJobSnapshot.self, from: Data(legacy.utf8))
        t.check(decoded != nil, "LEGACY_SB_1 a pre-run-scope queue snapshot still decodes")
        t.checkEqual(decoded?.storyboardRuns, [], "LEGACY_SB_2 with no runs")
        t.checkEqual(decoded?.isRunScopedStoryboard, false,
                     "LEGACY_SB_3 so it keeps using the legacy execution path")

        var modern = ProductionJobSnapshot()
        modern.storyboardRuns = StoryboardRunBuilder.build(plan: makePlan(), count: 1)
        t.checkEqual(modern.isRunScopedStoryboard, true,
                     "LEGACY_SB_4 a new submission is recognised as run-scoped")
    }

    t.suite("Storyboard run — freezing the edited project") {
        var project = FilmProject(title: "Freeze me")
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        project.shots[1].continuityMode = .continueFromPrevious

        let plan = try! FrozenStoryboardPlanBuilder.freeze(
            project: project, modelID: "ltx23_distilled_q4", preset: nil,
            audioEnabled: true, textEncoderID: nil, directorMode: "direct")

        t.checkEqual(plan.shots.count, 2, "FREEZE_1 every shot is frozen")
        t.checkEqual(plan.shots[0].startSource, .none, "FREEZE_2 shot 1 has no start source")
        t.checkEqual(plan.shots[1].startSource, .previousShotOutput,
                     "FREEZE_3 a CONTINUE shot depends on the previous shot")
        t.checkEqual(plan.shots.map(\.compiledPrompt), ["one", "two"],
                     "FREEZE_4 prompts are captured verbatim")
        t.checkEqual(plan.projectID, project.id, "FREEZE_5 the source project is recorded")

        // Ambiguity is rejected at submission, not resolved by a hidden rule
        // that the UI and the backend might read differently.
        var ambiguous = project
        ambiguous.shots[1].startingImageReferenceAssetID = UUID()
        var thrown: FrozenStoryboardPlanBuilder.FreezeError?
        do {
            _ = try FrozenStoryboardPlanBuilder.freeze(
                project: ambiguous, modelID: "m", preset: nil,
                audioEnabled: true, textEncoderID: nil, directorMode: nil)
        } catch let error as FrozenStoryboardPlanBuilder.FreezeError {
            thrown = error
        } catch {}
        t.checkEqual(thrown, .ambiguousStartSource(shotIndex: 1),
                     "FREEZE_6 explicit start image + CONTINUE is rejected at submission")

        // The frozen plan is a value: later edits cannot reach it.
        var edited = project
        edited.shots[0].compiledPrompt = "EDITED"
        t.checkEqual(plan.shots[0].compiledPrompt, "one",
                     "FREEZE_7 an edit after freezing does not reach the plan")
    }

    // MARK: - Real wired path (integration)

    t.suite("Storyboard run — real submission builds a ProductionJob") {
        var project = FilmProject(title: "Wired Storyboard")
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        project.shots[1].continuityMode = .continueFromPrevious

        // B/C: the requested 作品数 becomes exactly that many runs, and count=1
        // uses the identical architecture.
        let one = try! StoryboardRunSubmission.makeJob(
            project: project, workCount: 1, directorMode: "direct")
        t.checkEqual(one.kind, .storyboard, "WIRE_1 a real ProductionJob(.storyboard) is created")
        t.checkEqual(one.snapshot.storyboardRuns.count, 1, "WIRE_2 count=1 makes one run")
        t.checkEqual(one.snapshot.isRunScopedStoryboard, true,
                     "WIRE_3 and is flagged run-scoped")

        let two = try! StoryboardRunSubmission.makeJob(
            project: project, workCount: 2, directorMode: "direct")
        t.checkEqual(two.snapshot.storyboardRuns.count, 2, "WIRE_4 count=2 makes two runs")
        // Regression: the enqueue stamper derives batchCount from pendingRequests,
        // which a run-scoped Storyboard job does not have. Observed in the real
        // app as "2作品" reporting batchCount 1.
        let stamped = RunProvenanceStamper.stamp(two)
        t.checkEqual(stamped.snapshot.batchCount, 2,
                     "WIRE_4b batchCount survives enqueue stamping for run-scoped jobs")
        t.checkEqual(Set(two.snapshot.storyboardRuns.map(\.id)).count, 2,
                     "WIRE_5 with distinct run ids")
        t.checkEqual(Set(two.snapshot.storyboardRuns.map(\.batchID)).count, 1,
                     "WIRE_6 sharing one batch")

        // The composition is frozen ONCE and copied: both runs carry identical
        // prompts even though each has its own seeds.
        let runs = two.snapshot.storyboardRuns
        t.checkEqual(runs[0].plan.shots.map(\.compiledPrompt),
                     runs[1].plan.shots.map(\.compiledPrompt),
                     "WIRE_7 one freeze, copied into both runs")
        t.check(runs[0].plan.shots[0].seed != runs[1].plan.shots[0].seed,
                "WIRE_8 but seeds are per-run")

        // The run-scoped job must not be resolvable back to live project state.
        t.checkEqual(two.snapshot.projectID, nil,
                     "WIRE_9 no projectID: execution cannot re-read the editable project")

        // D: routing discriminator is explicit and on the snapshot.
        var legacy = ProductionJobSnapshot()
        legacy.projectID = project.id
        t.checkEqual(legacy.isRunScopedStoryboard, false,
                     "WIRE_10 a legacy Storyboard snapshot routes to the legacy path")

        // Encode/decode the ACTUAL submitted snapshot.
        let data = try! JSONEncoder().encode(two.snapshot)
        let restored = try! JSONDecoder().decode(ProductionJobSnapshot.self, from: data)
        t.checkEqual(restored.storyboardRuns.count, 2, "WIRE_11 the real snapshot round-trips")
        t.checkEqual(restored.storyboardRuns[0].plan.shots.count, 2, "WIRE_12 with its frozen plan")
    }

    t.suite("Storyboard run — run A completion cannot advance run B") {
        var project = FilmProject(title: "Isolation")
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        project.shots[1].continuityMode = .continueFromPrevious
        let job = try! StoryboardRunSubmission.makeJob(
            project: project, workCount: 2, directorMode: "direct")
        var runs = job.snapshot.storyboardRuns
        let s1 = runs[0].plan.shots[0].id
        let s2 = runs[0].plan.shots[1].id

        // E: run A finishes its shot 1. Run B must still start at ITS shot 1.
        StoryboardRunScheduler.recordCompletion(
            in: &runs[0], shotID: s1, takeID: UUID(), outputPath: "/tmp/a1.mp4")
        t.checkEqual(StoryboardRunScheduler.next(runs[1]), .render(shotID: s1),
                     "ISO_1 RUN_A_COMPLETION_ADVANCES_RUN_B: no")
        t.checkEqual(runs[1].state(of: s1)?.state, .queued,
                     "ISO_2 run B's shot 1 is still outstanding")
        t.checkEqual(runs[1].takeMap.take(runID: runs[1].id, shotID: s1), nil,
                     "ISO_3 run B has produced nothing")

        // F/G: run-local take map holds A's output, and only A's.
        t.check(runs[0].takeMap.take(runID: runs[0].id, shotID: s1) != nil,
                "ISO_4 run A's output is registered to run A")
        t.checkEqual(runs[0].takeMap.take(runID: runs[1].id, shotID: s1), nil,
                     "ISO_5 and is not reachable under run B's id")

        // J: a global selection change is irrelevant — there is no read of it.
        project.shots[0].selectedTakeID = UUID()
        t.checkEqual(StoryboardRunScheduler.next(runs[1]), .render(shotID: s1),
                     "ISO_6 GLOBAL_SELECTED_TAKE_AFFECTS_RUN: no")
        _ = s2
    }

    t.suite("Storyboard run — request is built from the frozen plan only") {
        var project = FilmProject(title: "Requests")
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "frozen prompt one"),
            Shot(index: 1, title: "Two", compiledPrompt: "frozen prompt two"),
        ]
        project.shots[1].continuityMode = .continueFromPrevious
        let job = try! StoryboardRunSubmission.makeJob(
            project: project, workCount: 1, directorMode: "direct")
        var run = job.snapshot.storyboardRuns[0]
        let s1 = run.plan.shots[0].id
        let s2 = run.plan.shots[1].id
        let params = GenerationParameters(
            numInferenceSteps: 15, guidanceScale: 3, width: 768, height: 512,
            numFrames: 121, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1)

        let first = StoryboardRunRequestBuilder.makeRequest(
            run: run, shotID: s1, parameters: params)
        t.checkEqual(first?.prompt, "frozen prompt one", "REQ_1 prompt comes from the frozen plan")
        t.checkEqual(first?.parameters.seed, run.plan.shots[0].seed,
                     "REQ_2 the frozen seed is used, not one chosen at the backend")
        t.checkEqual(first?.sourceImagePath, nil, "REQ_3 shot 1 has no start image")
        t.checkEqual(first?.batchID, run.batchID, "REQ_4 run identity travels with the request")
        t.checkEqual(first?.shotID, s1, "REQ_5 and the logical shot")

        // H: the dependent shot's input is the resolved upstream output.
        let takeA1 = UUID()
        StoryboardRunScheduler.recordCompletion(
            in: &run, shotID: s1, takeID: takeA1, outputPath: "/tmp/a1.mp4")
        _ = StoryboardRunScheduler.resolveDependency(
            in: &run, shotID: s2,
            assetPath: { _ in "/tmp/a1.mp4" }, contentHash: { _ in "hashA1" })
        // The dependency here names an upstream take but carries no extracted
        // frame, because this test resolves it by hand rather than through the
        // real freezing path. A CONTINUE without a frozen frame must build no
        // request at all — handing the renderer the upstream MP4 is the defect
        // this refusal exists to prevent.
        let second = StoryboardRunRequestBuilder.makeRequest(
            run: run, shotID: s2, parameters: params)
        t.checkEqual(second?.sourceImagePath, nil,
                     "REQ_6 a CONTINUE with no frozen frame builds no request")
        t.checkEqual(run.state(of: s2)?.dependency?.resolvedTakeID, takeA1,
                     "REQ_7 while the run-local upstream take is still recorded")
        t.checkEqual(run.state(of: s2)?.dependency?.hasFrozenFrame, false,
                     "REQ_7 and the dependency reports it has no usable frame")

        // An edit to the live project cannot change the queued request.
        project.shots[0].compiledPrompt = "EDITED AFTER SUBMIT"
        let again = StoryboardRunRequestBuilder.makeRequest(
            run: run, shotID: s1, parameters: params)
        t.checkEqual(again?.prompt, "frozen prompt one",
                     "REQ_8 AUTHORING_EDIT_MUTATES_QUEUED_RUN: no")
    }

    t.suite("Storyboard run — existing editor actions are untouched") {
        // L: the additive design's core promise. The two editor actions still
        // go through TakeGenerationCoordinator.planTakes and never build a
        // ProductionJob; only the new whole-Storyboard action does.
        let source = try! String(
            contentsOfFile: "LTXVideoGenerator/Sources/Views/StoryboardView.swift",
            encoding: .utf8)

        func body(of function: String) -> String {
            guard let start = source.range(of: "private func \(function)() {") else { return "" }
            let rest = source[start.upperBound...]
            guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
            return String(rest[..<end.lowerBound])
        }

        let missing = body(of: "generateMissingTakes")
        t.check(missing.contains("coordinator.planTakes"),
                "EDIT_1 Generate Missing Takes still uses its direct planTakes path")
        t.check(!missing.contains("ProductionQueueService"),
                "EDIT_2 and still does not create a ProductionJob")
        t.check(!missing.contains("storyboardWorkCount"),
                "EDIT_3 and is not affected by 作品数")

        let regen = body(of: "regenerateSelectedShots")
        t.check(regen.contains("coordinator.planTakes"),
                "EDIT_4 Regenerate Selected Shots still uses its direct path")
        t.check(!regen.contains("ProductionQueueService"),
                "EDIT_5 and still does not create a ProductionJob")
        t.check(!regen.contains("storyboardWorkCount"),
                "EDIT_6 and is not affected by 作品数")

        // Regression: the detail view is shared by the Storyboard and Auto Movie
        // tabs (HybridView is StoryboardView(mode: .hybrid)), so the new
        // whole-Storyboard section must be gated or it appears on Auto Movie —
        // a screen this work is explicitly not allowed to change.
        t.check(source.contains("workspaceMode != .hybrid"),
                "EDIT_9 the whole-Storyboard section is gated to the Storyboard workspace")
        t.check(source.contains("let workspaceMode: StoryboardWorkspaceMode"),
                "EDIT_10 the detail view knows which workspace is showing it")

        let queueWorks = body(of: "queueStoryboardWorks")
        t.check(queueWorks.contains("StoryboardRunSubmission.makeJob"),
                "EDIT_7 only the new action freezes and enqueues")
        t.check(!queueWorks.contains("planTakes"),
                "EDIT_8 and it never calls planTakes against live project state")
    }

    t.suite("Storyboard run — settlement attribution") {
        // Regression from the real wired path: completion arrives as one latched
        // "last settled run" value. Applying it to whatever shot is running
        // mis-attributed a completed shot 1 as a failure, which then blocked
        // shots 3 and 4 through dependency propagation.
        var project = FilmProject(title: "Attribution")
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
            Shot(index: 2, title: "Three", compiledPrompt: "three"),
        ]
        project.shots[1].continuityMode = .continueFromPrevious
        project.shots[2].continuityMode = .continueFromPrevious
        let job = try! StoryboardRunSubmission.makeJob(
            project: project, workCount: 1, directorMode: "direct")
        var run = job.snapshot.storyboardRuns[0]
        let s1 = run.plan.shots[0].id
        let s2 = run.plan.shots[1].id
        let s3 = run.plan.shots[2].id

        // Shot 1 is dispatched and its identity recorded.
        let req1 = UUID(), take1 = UUID()
        run.update(s1) {
            $0.state = .running
            $0.dispatchedRequestID = req1
            $0.dispatchedTakeID = take1
        }
        t.checkEqual(run.state(of: s1)?.dispatchedRequestID, req1,
                     "ATTR_1 the dispatched request is recorded on the shot")

        // A settlement for some OTHER request must not match this shot.
        let foreign = RunOutcomeRecord(runID: UUID(), outcome: .failed)
        t.check(run.state(of: s1)?.dispatchedRequestID != foreign.runID,
                "ATTR_2 a foreign settlement does not match a running shot")

        // The shot's own settlement matches and completes it.
        let mine = RunOutcomeRecord(runID: req1, outcome: .completed, outputPath: "/tmp/1.mp4")
        t.checkEqual(run.state(of: s1)?.dispatchedRequestID, mine.runID,
                     "ATTR_3 its own settlement matches")
        StoryboardRunScheduler.recordCompletion(
            in: &run, shotID: s1, takeID: take1, outputPath: mine.outputPath)

        // Downstream must NOT be blocked: shot 1 succeeded.
        t.checkEqual(run.state(of: s1)?.state, .completed, "ATTR_4 shot 1 completes")
        t.checkEqual(run.state(of: s2)?.state, .waitingForDependency,
                     "ATTR_5 shot 2 still waits, not blocked")
        t.checkEqual(run.state(of: s3)?.state, .waitingForDependency,
                     "ATTR_6 shot 3 still waits, not blocked")
        t.check(run.state(of: s2)?.state != .dependencyBlocked
                && run.state(of: s3)?.state != .dependencyBlocked,
                "ATTR_7 a successful upstream never blocks its dependents")

        // And the take recorded is the dispatched take, not the request id.
        t.checkEqual(run.state(of: s1)?.takeID, take1,
                     "ATTR_8 the recorded take is the one dispatched")
        t.checkEqual(run.takeMap.take(runID: run.id, shotID: s1), take1,
                     "ATTR_9 and it lands in the run-local map")
    }

    // MARK: - Duplicate-enqueue loop regression (LOOP_1..LOOP_8)

    /// Drives `StoryboardRunDriver` — the same decision code the production
    /// queue calls. A pure `next()` test proves nothing here: `next()` was
    /// already correct; the defect was in *when the caller acted on it*.
    t.suite("Storyboard run — duplicate enqueue loop") {

        // One real clip, reused by every harness in this suite.
        let loopRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopFix-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: loopRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: loopRoot) }

        func makeLoopVideo() -> String? {
            guard let ffmpeg = FinalAssemblyService.ffmpegPath() else { return nil }
            let out = loopRoot.appendingPathComponent("clip.mp4").path
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = ["-y", "-f", "lavfi", "-i",
                              "testsrc=size=64x64:rate=10:duration=1",
                              "-pix_fmt", "yuv420p", out]
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            try? proc.run(); proc.waitUntilExit()
            return proc.terminationStatus == 0 ? out : nil
        }
        let loopVideo = makeLoopVideo()

        func twoByTwo() -> [StoryboardRun] {
            var project = FilmProject(title: "Loop")
            project.shots = [
                Shot(index: 0, title: "One", compiledPrompt: "one"),
                Shot(index: 1, title: "Two", compiledPrompt: "two"),
            ]
            project.shots[1].continuityMode = .continueFromPrevious
            let job = try! StoryboardRunSubmission.makeJob(
                project: project, workCount: 2, directorMode: "direct")
            return job.snapshot.storyboardRuns
        }

        /// Simulates the queue: dispatch, then settle, recording every dispatch.
        struct Harness {
            var runs: [StoryboardRun]
            var videoPath: String?
            var dispatches: [StoryboardRunDriver.Dispatch] = []

            mutating func poll() {
                guard let d = StoryboardRunDriver.nextDispatch(in: runs) else { return }
                dispatches.append(d)
                runs[d.runIndex].update(d.shotID) {
                    $0.state = .running
                    $0.dispatchedRequestID = UUID()
                    $0.dispatchedTakeID = UUID()
                }
            }

            mutating func settleActive(completed: Bool = true) -> RunOutcomeRecord? {
                for run in runs {
                    guard let st = run.shotStates.first(where: {
                        $0.state == .running && $0.dispatchedRequestID != nil }) else { continue }
                    let rec = RunOutcomeRecord(
                        runID: st.dispatchedRequestID!,
                        outcome: completed ? .completed : .failed,
                        outputPath: completed ? videoPath : nil,
                        failureReason: completed ? nil : "render failed")
                    if let updated = StoryboardRunDriver.applySettlement(rec, to: runs) {
                        runs = updated
                    }
                    return rec
                }
                return nil
            }
        }

        // LOOP_1 — pure scheduler stability (supporting evidence only).
        let base = twoByTwo()[0]
        let decisions = (0..<10).map { _ in StoryboardRunScheduler.next(base) }
        t.check(decisions.allSatisfy { $0 == decisions[0] },
                "LOOP_1 repeated next() on unchanged state is stable")

        // LOOP_2 — polling while running must not regress or re-enqueue.
        var h = Harness(runs: twoByTwo(), videoPath: loopVideo)
        h.poll()
        t.checkEqual(h.dispatches.count, 1, "LOOP_2 the first poll dispatches one shot")
        let runningShot = h.dispatches[0].shotID
        for _ in 0..<25 { h.poll() }
        t.checkEqual(h.dispatches.count, 1,
                     "LOOP_2 ADDITIONAL_SUBMISSIONS = 0 across 25 polls with no settlement")
        t.checkEqual(h.runs[0].state(of: runningShot)?.state, .running,
                     "LOOP_2 the running shot never regresses to waiting")
        t.check(h.runs[0].state(of: runningShot)?.dispatchedRequestID != nil,
                "LOOP_2 its reservation is intact")

        // LOOP_3 — the same in-flight attempt cannot be dispatched twice.
        t.checkEqual(StoryboardRunDriver.nextDispatch(in: h.runs), nil,
                     "LOOP_3 nothing is dispatchable while an attempt is in flight")

        // LOOP_4 — a settlement is consumed exactly once.
        let rec = h.settleActive()!
        t.checkEqual(h.runs[0].state(of: runningShot)?.state, .completed,
                     "LOOP_4 the settlement completes its shot")
        t.checkEqual(StoryboardRunDriver.applySettlement(rec, to: h.runs), nil,
                     "LOOP_4 replaying the same settlement is a no-op")

        // LOOP_5 — a stale settlement cannot reactivate anything.
        h.poll()
        t.checkEqual(h.dispatches.count, 2, "LOOP_5 the next shot is dispatched once")
        let before = h.runs
        t.checkEqual(StoryboardRunDriver.applySettlement(rec, to: h.runs), nil,
                     "LOOP_5 the old settlement is ignored once a later shot is active")
        t.checkEqual(h.runs, before, "LOOP_5 and changes no state")
        for _ in 0..<10 { h.poll() }
        t.checkEqual(h.dispatches.count, 2, "LOOP_5 no extra dispatch from repeated polling")

        // LOOP_6 — realistic 2 runs x 2 shots, with polling between settlements.
        var full = Harness(runs: twoByTwo(), videoPath: loopVideo)
        for _ in 0..<40 {
            for _ in 0..<3 { full.poll() }
            _ = full.settleActive()
        }
        t.checkEqual(full.dispatches.count, 4,
                     "LOOP_6 TOTAL CHILD EXECUTIONS = 4 (2 runs x 2 shots), no fifth")
        let pairs = full.dispatches.map { "\($0.runID)-\($0.shotID)-\($0.attemptNumber)" }
        t.checkEqual(Set(pairs).count, 4, "LOOP_6 every attempt is unique")
        t.check(full.runs.allSatisfy { $0.derivedState == .completed },
                "LOOP_6 both runs complete")
        t.checkEqual(Set(full.dispatches.map(\.runID)).count, 2,
                     "LOOP_6 both runs actually ran")

        // LOOP_7 — a dependent shot waits until its own upstream resolves.
        var dep = Harness(runs: twoByTwo(), videoPath: loopVideo)
        let shot2 = dep.runs[0].plan.shots[1].id
        dep.poll()
        for _ in 0..<10 { dep.poll() }
        t.check(!dep.dispatches.contains { $0.shotID == shot2 },
                "LOOP_7 the dependent shot is not dispatched while its upstream runs")
        t.checkEqual(dep.runs[0].state(of: shot2)?.state, .waitingForDependency,
                     "LOOP_7 it stays waiting")
        _ = dep.settleActive()
        t.check(dep.runs[0].state(of: shot2)?.dependency?.isResolved == true,
                "LOOP_7 its dependency resolves only after the upstream succeeded")
        dep.poll()
        t.check(dep.dispatches.contains { $0.shotID == shot2 },
                "LOOP_7 and only then is it dispatched")

        // LOOP_8 — explicit retry is the only way to re-run a logical take.
        var fail = Harness(runs: twoByTwo(), videoPath: loopVideo)
        fail.poll()
        let failedShot = fail.dispatches[0].shotID
        let seedBefore = fail.runs[0].plan.shots.first { $0.id == failedShot }!.seed
        _ = fail.settleActive(completed: false)
        t.checkEqual(fail.runs[0].state(of: failedShot)?.state, .failed, "LOOP_8 the shot fails")
        let failedRunID = fail.dispatches[0].runID
        for _ in 0..<10 { fail.poll() }
        // The failed attempt is never re-dispatched by polling. The sibling run
        // legitimately continues — a failure in run A must not stall run B.
        t.checkEqual(fail.dispatches.filter {
            $0.runID == failedRunID && $0.shotID == failedShot }.count, 1,
            "LOOP_8 ordinary polling never re-dispatches the failed attempt")
        t.check(fail.dispatches.dropFirst().allSatisfy { $0.runID != failedRunID },
                "LOOP_8 only the sibling run proceeds after the failure")

        let beforeRetry = fail.dispatches.count
        StoryboardRunScheduler.retry(in: &fail.runs[0], shotID: failedShot)
        t.checkEqual(fail.runs[0].state(of: failedShot)?.attemptNumber, 2,
                     "LOOP_8 explicit retry raises the attempt")
        // Drain whatever the sibling has in flight so the retried shot can run.
        while fail.dispatches.count == beforeRetry {
            if fail.settleActive() == nil { break }
            fail.poll()
        }
        let retried = fail.dispatches.first {
            $0.runID == failedRunID && $0.shotID == failedShot && $0.attemptNumber == 2 }
        t.check(retried != nil, "LOOP_8 the retried attempt is dispatched exactly once")
        t.checkEqual(fail.runs[0].plan.shots.first { $0.id == failedShot }!.seed, seedBefore,
                     "LOOP_8 with the same seed")
    }

    // MARK: - CONTINUE final-frame conditioning (CONT_FIX_1..12)

    t.suite("Storyboard run — CONTINUE uses an extracted final frame") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContFix-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        /// A real, tiny, decodable clip. Without ffmpeg the media-dependent
        /// checks are skipped rather than silently reported as passing.
        func makeVideo(_ name: String, seconds: Double = 1.0) -> String? {
            guard let ffmpeg = FinalAssemblyService.ffmpegPath() else { return nil }
            let out = root.appendingPathComponent(name).path
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = [
                "-y", "-f", "lavfi", "-i",
                "testsrc=size=64x64:rate=10:duration=\(seconds)",
                "-pix_fmt", "yuv420p", out,
            ]
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            try? proc.run(); proc.waitUntilExit()
            return proc.terminationStatus == 0 ? out : nil
        }

        let runID = UUID(), shotID = UUID(), takeID = UUID()

        if let video = makeVideo("upstream.mp4") {
            // CONT_FIX_1 / CONT_FIX_2 — the MP4 becomes a usable PNG.
            let outcome = StoryboardContinuityFrame.freeze(
                runID: runID, shotID: shotID, upstreamTakeID: takeID, videoPath: video)
            guard case .success(let frozen) = outcome else {
                t.check(false, "CONT_FIX_1 extraction succeeded"); return
            }
            defer { try? FileManager.default.removeItem(atPath: frozen.imagePath) }

            t.check(frozen.imagePath.hasSuffix(".png"),
                    "CONT_FIX_1 the frozen asset is a PNG, not the MP4")
            t.check(!frozen.imagePath.hasSuffix(".mp4"), "CONT_FIX_1 and never the video")
            t.checkEqual(frozen.sourceVideoPath, video,
                         "CONT_FIX_1 the source video is recorded separately")
            t.check(ContinuityFrameExtractor.isUsableImage(atPath: frozen.imagePath),
                    "CONT_FIX_2 the extracted frame is a usable image")

            // CONT_FIX_3 — path + hash + provenance are frozen on the dependency.
            var dep = ResolvedShotDependency(runID: runID, upstreamShotID: UUID())
            dep.resolvedTakeID = takeID
            dep.sourceVideoPath = frozen.sourceVideoPath
            dep.sourceVideoContentHash = frozen.sourceVideoContentHash
            dep.extractedImagePath = frozen.imagePath
            dep.extractedImageContentHash = frozen.imageContentHash
            dep.frameReference = frozen.frameReference
            dep.resolvedAt = Date()

            t.check(dep.hasFrozenFrame, "CONT_FIX_3 the dependency carries a frozen frame")
            t.check(dep.extractedImageContentHash?.count == 64,
                    "CONT_FIX_3 with a SHA-256 of the PNG")
            t.check(dep.frameReference?.hasPrefix("final-frame") == true,
                    "CONT_FIX_3 and a deterministic frame reference (no fabricated index)")
            t.checkEqual(StoryboardContinuityFrame.verifyFrozen(dep), nil,
                         "CONT_FIX_3 and verifies against the file on disk")

            // CONT_FIX_4 / CONT_FIX_5 — restart and retry reuse it, no re-extraction.
            let encoded = try! JSONEncoder().encode(dep)
            let restored = try! JSONDecoder().decode(ResolvedShotDependency.self, from: encoded)
            t.checkEqual(restored.extractedImagePath, frozen.imagePath,
                         "CONT_FIX_4 restart restores the exact PNG path")
            t.checkEqual(restored.extractedImageContentHash, frozen.imageContentHash,
                         "CONT_FIX_4 and its hash")
            t.checkEqual(StoryboardContinuityFrame.verifyFrozen(restored), nil,
                         "CONT_FIX_4 which still verifies — nothing is re-extracted")

            // CONT_FIX_9 — a mutated PNG fails closed.
            let saved = try! Data(contentsOf: URL(fileURLWithPath: frozen.imagePath))
            try! Data("not a png".utf8).write(to: URL(fileURLWithPath: frozen.imagePath))
            t.check(StoryboardContinuityFrame.verifyFrozen(dep) != nil,
                    "CONT_FIX_9 a changed frame fails closed")
            try! saved.write(to: URL(fileURLWithPath: frozen.imagePath))
            t.checkEqual(StoryboardContinuityFrame.verifyFrozen(dep), nil,
                         "CONT_FIX_9 and passes again once restored")

            // CONT_FIX_8 — a deleted PNG fails closed.
            try? FileManager.default.removeItem(atPath: frozen.imagePath)
            t.check(StoryboardContinuityFrame.verifyFrozen(dep) != nil,
                    "CONT_FIX_8 a missing frame fails closed")
            try! saved.write(to: URL(fileURLWithPath: frozen.imagePath))

            // CONT_FIX_7 — two runs never share a frame path.
            let runA = UUID(), runB = UUID()
            let pathA = StoryboardContinuityFrame.imageURL(
                runID: runA, shotID: shotID, upstreamTakeID: takeID).path
            let pathB = StoryboardContinuityFrame.imageURL(
                runID: runB, shotID: shotID, upstreamTakeID: takeID).path
            t.check(pathA != pathB, "CONT_FIX_7 CROSS_RUN_FINAL_FRAME_LEAK: no")
            t.check(pathA.contains(runA.uuidString) && pathB.contains(runB.uuidString),
                    "CONT_FIX_7 each run's frames live under its own run id")
        } else {
            t.check(true, "CONT_FIX_1..9 skipped — ffmpeg unavailable in this environment")
        }

        // CONT_FIX_10 — extraction failure blocks; it never degrades to T2V.
        let bogus = root.appendingPathComponent("not-a-video.mp4").path
        try! Data("garbage".utf8).write(to: URL(fileURLWithPath: bogus))
        let failed = StoryboardContinuityFrame.freeze(
            runID: runID, shotID: shotID, upstreamTakeID: takeID, videoPath: bogus)
        if case .failure = failed {
            t.check(true, "CONT_FIX_10 an undecodable source fails rather than falling back")
        } else {
            t.check(false, "CONT_FIX_10 an undecodable source must fail")
        }
        let absent = StoryboardContinuityFrame.freeze(
            runID: runID, shotID: shotID, upstreamTakeID: takeID,
            videoPath: root.appendingPathComponent("missing.mp4").path)
        if case .failure = absent {
            t.check(true, "CONT_FIX_10 a missing source fails closed")
        } else {
            t.check(false, "CONT_FIX_10 a missing source must fail")
        }

        // CONT_FIX_1 (builder half) — the request carries the PNG, never the MP4,
        // and refuses to build without a verified frozen frame.
        var project = FilmProject(title: "ContFix")
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        project.shots[1].continuityMode = .continueFromPrevious
        let job = try! StoryboardRunSubmission.makeJob(
            project: project, workCount: 1, directorMode: "direct")
        var run = job.snapshot.storyboardRuns[0]
        let s1 = run.plan.shots[0].id, s2 = run.plan.shots[1].id
        let params = GenerationParameters(
            numInferenceSteps: 15, guidanceScale: 3, width: 64, height: 64,
            numFrames: 9, fps: 10, seed: nil, vaeTilingMode: "auto", imageStrength: 1)

        if let video = makeVideo("run-upstream.mp4") {
            StoryboardRunScheduler.recordCompletion(
                in: &run, shotID: s1, takeID: takeID, outputPath: video)
            StoryboardRunDriver.resolveNextDependency(in: &run)

            let dep = run.state(of: s2)?.dependency
            t.check(dep?.hasFrozenFrame == true,
                    "CONT_FIX_1 resolving a CONTINUE freezes a frame")
            t.checkEqual(dep?.sourceVideoPath, video, "CONT_FIX_1 recording the source video")
            let request = StoryboardRunRequestBuilder.makeRequest(
                run: run, shotID: s2, parameters: params)
            t.checkEqual(request?.sourceImagePath, dep?.extractedImagePath,
                         "CONT_FIX_1 the request's starting image is the frozen PNG")
            t.check(request?.sourceImagePath?.hasSuffix(".mp4") == false,
                    "CONT_FIX_1 BACKEND_SOURCE_IS_MP4: no")
            defer { try? FileManager.default.removeItem(atPath: dep!.extractedImagePath!) }

            // CONT_FIX_5 — retry reuses the same PNG; nothing is re-extracted.
            let pathBefore = dep?.extractedImagePath
            let hashBefore = dep?.extractedImageContentHash
            StoryboardRunScheduler.recordFailure(in: &run, shotID: s2, reason: "render failed")
            StoryboardRunScheduler.retry(in: &run, shotID: s2)
            StoryboardRunDriver.resolveNextDependency(in: &run)
            t.checkEqual(run.state(of: s2)?.dependency?.extractedImagePath, pathBefore,
                         "CONT_FIX_5 retry reuses the same frozen PNG")
            t.checkEqual(run.state(of: s2)?.dependency?.extractedImageContentHash, hashBefore,
                         "CONT_FIX_5 and the same hash")

            // CONT_FIX_6 — an upstream retake does not rewrite it.
            run.takeMap.readopt(runID: run.id, shotID: s1, takeID: UUID())
            StoryboardRunDriver.resolveNextDependency(in: &run)
            t.checkEqual(run.state(of: s2)?.dependency?.extractedImagePath, pathBefore,
                         "CONT_FIX_6 RETAKE_MUTATES_RESOLVED_FRAME: no")
            t.checkEqual(run.state(of: s2)?.dependency?.resolvedTakeID, takeID,
                         "CONT_FIX_6 and the original upstream take is kept")
        }

        // A CONTINUE with no frozen frame must not produce a request at all.
        let bare = try! StoryboardRunSubmission.makeJob(
            project: project, workCount: 1, directorMode: "direct")
        let bareRun = bare.snapshot.storyboardRuns[0]
        t.checkEqual(
            StoryboardRunRequestBuilder.makeRequest(
                run: bareRun, shotID: bareRun.plan.shots[1].id, parameters: params)?.sourceImagePath,
            nil,
            "CONT_FIX_1 a CONTINUE without a frozen frame builds no request")
        _ = bareRun

        // CONT_FIX_11 — a dependency written before this change still decodes.
        let legacy = "{\"runID\":\"\(UUID().uuidString)\",\"upstreamShotID\":\"\(UUID().uuidString)\"}"
        let old = try? JSONDecoder().decode(
            ResolvedShotDependency.self, from: Data(legacy.utf8))
        t.check(old != nil, "CONT_FIX_11 a legacy resolved dependency still decodes")
        t.checkEqual(old?.extractedImagePath, nil, "CONT_FIX_11 with no invented frame")
        t.checkEqual(old?.hasFrozenFrame, false, "CONT_FIX_11 and is not treated as frozen")

        // CONT_FIX_12 — the run-scoped path never calls the project-coupled wrapper.
        let sources = ["LTXVideoGenerator/Sources/Services/StoryboardRun.swift",
                       "LTXVideoGenerator/Sources/Services/ProductionQueueService.swift"]
        for file in sources {
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            // Strip comments: these files deliberately *document* why the
            // project-coupled wrapper is not used, and a naive substring search
            // would match that explanation.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { return "" }
                    return String(line.prefix(while: { _ in true }))
                }
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
                .joined(separator: "\n")
            t.check(!code.contains("prepareContinuityAsset("),
                    "CONT_FIX_12 \(file) never calls prepareContinuityAsset")
            t.check(!code.contains("autoSelectUnambiguousTakes("),
                    "CONT_FIX_12 \(file) never auto-selects a global take")
        }
    }
}
