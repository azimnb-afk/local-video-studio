import Foundation
@testable import LTXVideoGeneratorCore

/// Multi-work siblings stop only when a failure provably applies to all of them.
///
/// The default stays "keep going": a failed work is usually about that work.
/// A batch is stopped only on a typed failure decided before rendering from
/// inputs every remaining sibling shares — model/runtime readiness
/// (`LTXError.modelLoadFailed`, `pythonNotConfigured`), or a frozen explicit
/// image that the sibling froze as the same file and bytes. Stopped works are
/// terminal and retryable, and marked *not attempted* so they never read as
/// having failed on their own.
func runBatchFailurePolicyTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BatchFail-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FilmProjectStore(projectsDirectory: root)
    let hasher: (String) -> String? = { H3EndingImageCapability.contentHash(ofFileAt: $0) }
    let params = GenerationParameters(
        numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
        numFrames: 81, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1)
    func resolve(_ relative: String, _ projectID: UUID) -> String? {
        MovieRunRequestBuilder.resolveFrozenAssetPath(relative, projectID: projectID, store: store)
    }
    typealias W = ProductionWorkDisplayItem.State

    // MARK: Fixtures

    /// Generate / One Shot count=N as submitted: expanded, then stamped.
    func requestJob(_ kind: ProductionJobKind, count: Int = 3) -> ProductionJob {
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = CandidateExpander.expand(
            GenerationRequest(prompt: "p", modelId: "ltx23_distilled_q4", parameters: params), count: count)
        snapshot.batchCount = count
        return RunProvenanceStamper.stamp(ProductionJob(kind: kind, title: "\(kind)", snapshot: snapshot))
    }

    /// What the renderer publishes for request 1 failing on a readiness error
    /// and its siblings being stopped (`GenerationService.stopBatchSiblings`).
    func rendererSettlements(for job: ProductionJob, error: LTXError) -> [RunOutcomeRecord] {
        let requests = job.snapshot.pendingRequests
        let failed = requests[0]
        var renderQueue = requests
        renderQueue[0].status = .processing
        var out = [RunOutcomeRecord(runID: failed.id, outcome: .failed, attemptNumber: 1,
                                    failureReason: error.localizedDescription)]
        guard BatchFailurePolicy.scope(of: error) == .batchDeterministic else { return out }
        for sibling in BatchFailurePolicy.siblingsSharingPrerequisite(of: failed, in: renderQueue) {
            out.append(RunOutcomeRecord(runID: sibling.id, outcome: .failed, attemptNumber: 1,
                                        failureReason: BatchFailurePolicy.notAttemptedReason,
                                        notAttempted: true))
        }
        return out
    }

    /// Storyboard / Auto Movie 作品数 3; shot `explicitShot` starts from one
    /// real image every run froze.
    func project(_ mode: String, shots: Int = 1, explicitShot: Int = 0) -> FilmProject {
        var p = FilmProject(title: "batch \(mode)")
        p.workflowMode = mode
        p.shots = (0..<shots).map { Shot(index: $0, title: "S\($0)", compiledPrompt: "s\($0)") }
        for i in p.shots.indices { p.shots[i].continuityMode = .cut }
        p.shots[explicitShot].startingImageReferenceAssetID = UUID()
        p.shots[explicitShot].continuityImageRelativePath = "Assets/Shots/start.png"
        let url = store.managedProjectAssetURL(projectID: p.id, relativePath: "Assets/Shots/start.png")!
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("original".utf8).write(to: url)
        return p
    }
    func editImage(_ p: FilmProject) {
        let url = store.managedProjectAssetURL(projectID: p.id, relativePath: "Assets/Shots/start.png")!
        try? Data("edited-after-queueing".utf8).write(to: url)
    }
    func decide<Run: RunScopedShotExecution>(
        _ runs: [Run], built: inout Int,
        request: (Run, UUID, UUID) -> GenerationRequest?
    ) -> RunScopedDispatchDriver.Decision<Run> {
        var count = 0
        let d = RunScopedDispatchDriver.nextShot(
            in: runs, takeID: UUID(),
            makeRequest: { r, s, tk in let x = request(r, s, tk); if x != nil { count += 1 }; return x },
            classifyRefusal: { r, s in
                if let sb = r as? StoryboardRun {
                    return RunDispatchRefusal.classify(run: sb, shotID: s, resolveAsset: resolve, contentHash: hasher)
                }
                return RunDispatchRefusal.classify(run: r as! MovieRun, shotID: s, resolveAsset: resolve, contentHash: hasher)
            })
        built = count
        return d
    }
    func storyboardRequest(_ r: StoryboardRun, _ s: UUID, _ tk: UUID) -> GenerationRequest? {
        StoryboardRunRequestBuilder.makeRequest(run: r, shotID: s, takeID: tk, parameters: params,
                                                resolveAsset: resolve, contentHash: hasher)
    }
    func movieRequest(_ r: MovieRun, _ s: UUID, _ tk: UUID) -> GenerationRequest? {
        MovieRunRequestBuilder.makeRequest(run: r, shotID: s, takeID: tk, parameters: params,
                                           resolveAsset: resolve, contentHash: hasher)
    }
    func states(_ items: [ProductionWorkDisplayItem]) -> [W] { items.map(\.state) }

    /// Storyboard 作品数 3 (no images) with work 1's shot dispatched.
    func storyboardRunsDispatched() -> (runs: [StoryboardRun], dispatched: UUID) {
        var p = FilmProject(title: "plain")
        p.workflowMode = "storyboard"
        p.shots = [Shot(index: 0, title: "S", compiledPrompt: "s")]
        let job = try! StoryboardRunSubmission.makeJob(project: p, workCount: 3, directorMode: "direct")
        var runs = job.snapshot.storyboardRuns.sorted { $0.batchIndex < $1.batchIndex }
        let id = UUID()
        runs[0].update(runs[0].orderedShots[0].id) { $0.state = .running; $0.dispatchedRequestID = id }
        return (runs, id)
    }

    // MARK: Classification

    t.suite("Batch failure — only typed, shared, pre-render failures stop siblings") {
        t.checkEqual(BatchFailurePolicy.scope(of: .modelLoadFailed("Model X is not prepared locally.")),
                     .batchDeterministic, "BATCHFAIL_1 model not prepared is batch-wide")
        t.checkEqual(BatchFailurePolicy.scope(of: .pythonNotConfigured), .batchDeterministic,
                     "BATCHFAIL_1 a missing runtime environment is batch-wide")
        t.checkEqual(BatchFailurePolicy.scope(of: .generationFailed("ltx-2-mlx exited with code 1.")),
                     .workLocalOrUnknown, "BATCHFAIL_6 an unexplained backend exit continues")
        t.checkEqual(BatchFailurePolicy.scope(of: .generationFailed("kIOGPUCommandBufferCallbackErrorOutOfMemory")),
                     .workLocalOrUnknown, "BATCHFAIL_7 GPU out-of-memory is not treated as deterministic")
        t.checkEqual(BatchFailurePolicy.scope(of: .exportFailed("disk hiccup")), .workLocalOrUnknown,
                     "BATCHFAIL_7 an export failure continues")
        t.checkEqual(BatchFailurePolicy.scope(of: .cancelled), .workLocalOrUnknown,
                     "BATCHFAIL_20 cancellation is never a batch failure")
        t.checkEqual(BatchFailurePolicy.scope(of: nil), .workLocalOrUnknown,
                     "BATCHFAIL_20 no typed error defaults to continue")
        t.checkEqual(RunDispatchRefusal.continuationUnavailable.scope, .workLocalOrUnknown,
                     "BATCHFAIL_5 a missing continuation frame is this run's own")
    }

    // MARK: Generate / One Shot

    t.suite("Batch failure — Generate and One Shot") {
        for kind in [ProductionJobKind.generate, .oneShot] {
            let label = kind == .generate ? "BATCHFAIL_1" : "BATCHFAIL_2"
            let q = ProductionQueueCoordinator(
                store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(kind).json")),
                restoreOnInit: false)
            q.runner = { _ in .started }
            let job = q.enqueue(requestJob(kind))
            let settlements = rendererSettlements(for: job, error: .modelLoadFailed("Model X is not prepared locally."))
            t.checkEqual(settlements.count, 3, "\(label) request 1 fails and both siblings are stopped")
            t.check(settlements.dropFirst().allSatisfy { $0.notAttempted == true },
                    "\(label) the siblings are settled as not attempted, not dispatched")
            settlements.forEach { q.recordSettlement($0) }
            q.markFailed(jobID: job.id, reason: LTXError.modelLoadFailed("Model X is not prepared locally.").localizedDescription)
            let items = ProductionWorkPresenter.items(for: q.job(id: job.id)!)
            t.checkEqual(states(items), [.failed, .notRun, .notRun],
                         "BATCHFAIL_15 \(kind): 作品 1 失敗, 作品 2/3 未実行")
            t.checkEqual(items[1].failureReason, BatchFailurePolicy.notAttemptedReason,
                         "BATCHFAIL_10 \(kind): a stopped work says why it did not run")
            t.check((items[0].failureReason ?? "").contains("not prepared locally"),
                    "BATCHFAIL_10 \(kind): the real cause stays on the work that failed")
        }

        // Siblings are only swept up when they share the prerequisite.
        var mixed = requestJob(.generate).snapshot.pendingRequests
        var otherModel = GenerationRequest(prompt: "p", modelId: "a_different_model", parameters: params)
        otherModel.batchID = mixed[0].batchID
        mixed[2] = otherModel
        mixed[0].status = .processing
        t.checkEqual(BatchFailurePolicy.siblingsSharingPrerequisite(of: mixed[0], in: mixed).map(\.id), [mixed[1].id],
                     "BATCHFAIL_1 a sibling on a different model is not stopped")
        var takes = requestJob(.generate).snapshot.pendingRequests
        for i in takes.indices { takes[i].takeID = UUID() }
        t.checkEqual(BatchFailurePolicy.siblingsSharingPrerequisite(of: takes[0], in: takes), [],
                     "BATCHFAIL_1 film-project takes are never swept up")

        // BATCHFAIL_6 — an unknown backend failure stops nobody.
        let unknown = rendererSettlements(for: requestJob(.generate), error: .generationFailed("exited with code 1"))
        t.checkEqual(unknown.count, 1, "BATCHFAIL_6 an unknown failure leaves the siblings queued")

        // BATCHFAIL_13 — Retry after a batch stop re-runs every unfinished work
        // with its own seed; nothing is permanently poisoned.
        var retryJob = requestJob(.oneShot)
        retryJob.snapshot.runOutcomes = rendererSettlements(for: retryJob, error: .pythonNotConfigured)
        let plan = RunRetryPlanner.plan(requests: retryJob.snapshot.pendingRequests,
                                        outcomes: retryJob.snapshot.runOutcomes)
        t.checkEqual(plan.requestsToRun.map(\.id), retryJob.snapshot.pendingRequests.map(\.id),
                     "BATCHFAIL_13 Retry runs the failed work and both stopped works")
        t.checkEqual(plan.requestsToRun.map(\.parameters.seed), retryJob.snapshot.pendingRequests.map(\.parameters.seed),
                     "BATCHFAIL_13 each with its original seed")
        t.check(plan.requestsToRun.allSatisfy { $0.attemptNumber == 2 }, "BATCHFAIL_13 as attempt 2")
        t.checkEqual(plan.preservedOutcomes, [], "BATCHFAIL_13 no stopped outcome is carried forward")

        // BATCHFAIL_16 — the root reason is still sanitised; the stop reason is short.
        let leaky = LTXError.modelLoadFailed("LTX-2.5: runtime not ready at /Users/alice/Library/Application Support/x/bin")
        let lq = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: root.appendingPathComponent("leak.json")), restoreOnInit: false)
        lq.runner = { _ in .started }
        let lj = lq.enqueue(requestJob(.generate))
        rendererSettlements(for: lj, error: leaky).forEach { lq.recordSettlement($0) }
        lq.markFailed(jobID: lj.id, reason: leaky.localizedDescription)
        let leakItems = ProductionWorkPresenter.items(for: lq.job(id: lj.id)!)
        t.check(!(leakItems[0].failureReason ?? "").contains("/Users/"), "BATCHFAIL_16 the root reason has no private path")
        t.check(!(leakItems[1].failureReason ?? "").contains("/"), "BATCHFAIL_16 the stop reason carries no path")

        // BATCHFAIL_18 — a stopped sibling's settlement arriving after close-out
        // still lands in its own job and replaces the placeholder.
        let oq = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: root.appendingPathComponent("own.json")), restoreOnInit: false)
        oq.runner = { _ in .started }
        let a = oq.enqueue(requestJob(.oneShot))
        let b = oq.enqueue(requestJob(.oneShot))
        let late = rendererSettlements(for: a, error: .pythonNotConfigured)
        oq.recordSettlement(late[0])
        oq.recordRunOutcomes(jobID: a.id, outcomes: late.dropFirst().map {
            RunOutcomeRecord(runID: $0.runID, outcome: .failed, attemptNumber: 1, failureReason: "closed out")
        })
        oq.markFailed(jobID: a.id, reason: "python")
        t.checkEqual(oq.activeJob?.id, b.id, "fixture: B active before the stop settlements arrive")
        late.dropFirst().forEach { oq.recordSettlement($0) }
        t.checkEqual(oq.job(id: b.id)?.snapshot.runOutcomes.count, 0, "BATCHFAIL_18 none land in B")
        t.check(oq.job(id: a.id)!.snapshot.runOutcomes.filter { $0.notAttempted == true }.count == 2,
                "BATCHFAIL_18 both are recorded in A as not attempted")
    }

    // MARK: Storyboard / Auto Movie

    t.suite("Batch failure — Storyboard and Auto Movie") {
        // BATCHFAIL_3 — Storyboard 作品数 3, the shared frozen image edited
        // before the first dispatch.
        let sp = project("storyboard")
        let sjob = try! StoryboardRunSubmission.makeJob(project: sp, workCount: 3, directorMode: "direct",
                                                        store: store, contentHash: hasher)
        editImage(sp)
        var built = 0
        let sdecision = decide(sjob.snapshot.storyboardRuns.sorted { $0.batchIndex < $1.batchIndex },
                               built: &built, request: storyboardRequest)
        guard case .noShotToDispatch(let sruns) = sdecision else {
            t.check(false, "BATCHFAIL_3 nothing is dispatched (got \(sdecision))"); return
        }
        t.checkEqual(sruns.map { $0.shotStates[0].state }, [.failed, .dependencyBlocked, .dependencyBlocked],
                     "BATCHFAIL_3 work 1 fails, works 2 and 3 are stopped")
        t.checkEqual(built, 0, "BATCHFAIL_8 no backend request is built for any work")
        t.checkEqual(RunScopedDispatchDriver.storyboardCompletion(sruns), .settled(allCompleted: false),
                     "BATCHFAIL_11 the job settles instead of running on")
        var sjobDone = sjob
        sjobDone.snapshot.storyboardRuns = sruns
        sjobDone.state = .failed
        t.checkEqual(states(ProductionWorkPresenter.items(for: sjobDone)), [.failed, .notRun, .notRun],
                     "BATCHFAIL_15 Storyboard: 失敗 / 未実行 / 未実行")

        // BATCHFAIL_8 — the wasteful case: shot 2's image is shared; work 1
        // rendered shot 1 and refuses at shot 2. Works 2 and 3 must not start.
        let two = project("storyboard", shots: 2, explicitShot: 1)
        let twoJob = try! StoryboardRunSubmission.makeJob(project: two, workCount: 3, directorMode: "direct",
                                                          store: store, contentHash: hasher)
        var twoRuns = twoJob.snapshot.storyboardRuns.sorted { $0.batchIndex < $1.batchIndex }
        twoRuns[0].update(twoRuns[0].orderedShots[0].id) { $0.state = .completed; $0.outputPath = "/tmp/a.mp4" }
        editImage(two)
        let twoDecision = decide(twoRuns, built: &built, request: storyboardRequest)
        if case .noShotToDispatch(let after) = twoDecision {
            t.checkEqual(built, 0, "BATCHFAIL_8 no doomed sibling renders its earlier shot")
            t.checkEqual(after[0].state(of: after[0].orderedShots[0].id)?.state, .completed,
                         "BATCHFAIL_9 work 1's rendered shot stays completed")
            t.check(after[1...].allSatisfy { $0.shotStates.allSatisfy { $0.notAttempted == true } },
                    "BATCHFAIL_8 works 2 and 3 are stopped before rendering anything")
        } else {
            t.check(false, "BATCHFAIL_8 doomed siblings are not dispatched (got \(twoDecision))")
        }

        // BATCHFAIL_4 — Auto Movie, same shared image.
        let mp = project("hybrid")
        let mjob = try! MovieRunSubmission.makeJob(project: mp, workCount: 3, directorMode: "direct",
                                                   store: store, contentHash: hasher)
        editImage(mp)
        let mdecision = decide(mjob.snapshot.movieRuns.sorted { $0.batchIndex < $1.batchIndex },
                               built: &built, request: movieRequest)
        if case .noShotToDispatch(let mruns) = mdecision {
            t.checkEqual(mruns.map { $0.shotStates[0].state }, [.failed, .dependencyBlocked, .dependencyBlocked],
                         "BATCHFAIL_4 Auto Movie work 1 fails, works 2 and 3 are stopped")
            t.checkEqual(built, 0, "BATCHFAIL_4 with no backend request")
            t.checkEqual(RunScopedDispatchDriver.movieCompletion(mruns), .settled(allCompleted: false),
                         "BATCHFAIL_11 the movie job settles")
        } else {
            t.check(false, "BATCHFAIL_4 Auto Movie stops doomed siblings (got \(mdecision))")
        }

        // BATCHFAIL_5 / _17 — a work-local refusal: only work 2's frozen
        // bytes differ, so work 3 is not stopped and is dispatched.
        let lp = project("storyboard")
        let ljob = try! StoryboardRunSubmission.makeJob(project: lp, workCount: 3, directorMode: "direct",
                                                        store: store, contentHash: hasher)
        var lruns = ljob.snapshot.storyboardRuns.sorted { $0.batchIndex < $1.batchIndex }
        lruns[0].update(lruns[0].orderedShots[0].id) { $0.state = .completed }
        lruns[1].plan.shots[0].explicitStartImageContentHash = String(repeating: "0", count: 64)
        if case .dispatch(let after, let idx, _, _) = decide(lruns, built: &built, request: storyboardRequest) {
            t.checkEqual(after[idx].batchIndex, 2, "BATCHFAIL_5 a work-local refusal lets work 3 run")
            t.checkEqual(after[2].shotStates[0].notAttempted, nil, "BATCHFAIL_17 work 3 is not marked stopped")
        } else {
            t.check(false, "BATCHFAIL_5 a work-local refusal continues")
        }

        // Backend readiness failure on a run-scoped shot.
        var backend = storyboardRunsDispatched()
        let settlement = RunOutcomeRecord(runID: backend.dispatched, outcome: .failed, attemptNumber: 1,
                                          failureReason: "Model X is not prepared locally.")
        var applied = StoryboardRunDriver.applySettlement(settlement, to: backend.runs)!
        RunScopedDispatchDriver.stopUnstartedRunsAfterFailure(
            &applied, settlement: settlement, dispatchedIn: 0,
            error: .modelLoadFailed("Model X is not prepared locally."))
        t.checkEqual(applied.map { $0.shotStates[0].state }, [.failed, .dependencyBlocked, .dependencyBlocked],
                     "BATCHFAIL_3 a readiness failure on work 1 stops works 2 and 3")
        var unknownApplied = StoryboardRunDriver.applySettlement(settlement, to: backend.runs)!
        RunScopedDispatchDriver.stopUnstartedRunsAfterFailure(
            &unknownApplied, settlement: settlement, dispatchedIn: 0,
            error: .generationFailed("exited with code 1"))
        t.checkEqual(unknownApplied.map { $0.shotStates[0].state }, [.failed, .queued, .queued],
                     "BATCHFAIL_20 an unknown backend failure leaves works 2 and 3 to run")
        backend.runs[2].markCancelled()
        var withCancelled = StoryboardRunDriver.applySettlement(settlement, to: backend.runs)!
        RunScopedDispatchDriver.stopUnstartedRunsAfterFailure(
            &withCancelled, settlement: settlement, dispatchedIn: 0, error: .pythonNotConfigured)
        t.checkEqual(withCancelled[2].shotStates[0].notAttempted, nil,
                     "BATCHFAIL_19 a cancelled run is left exactly as it was")

        // BATCHFAIL_13 — Retry clears the stop and keeps seeds.
        let rq = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: root.appendingPathComponent("sbretry.json")), restoreOnInit: false)
        rq.setPaused(true)
        var stopped = sjob
        stopped.snapshot.storyboardRuns = sruns
        let queued = rq.enqueue(stopped)
        rq.markFailed(jobID: queued.id, reason: "stopped")
        if let retried = rq.retry(jobID: queued.id) {
            let r = retried.snapshot.storyboardRuns
            t.check(r.allSatisfy { $0.shotStates.allSatisfy { $0.state == .queued && $0.notAttempted == nil } },
                    "BATCHFAIL_13 Retry reopens every stopped work and clears the stop marker")
            t.checkEqual(r.map { $0.orderedShots[0].seed }, sruns.map { $0.orderedShots[0].seed },
                         "BATCHFAIL_13 with the frozen seeds")
            t.checkEqual(r.map { $0.orderedShots[0].explicitStartImageContentHash },
                         sruns.map { $0.orderedShots[0].explicitStartImageContentHash },
                         "BATCHFAIL_14 frozen inputs untouched — Retake, which re-freezes, is a separate path")
        } else {
            t.check(false, "BATCHFAIL_13 Retry produced a job")
        }

        // BATCHFAIL_12 — the job behind a batch stop starts.
        let nq = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: root.appendingPathComponent("next.json")), restoreOnInit: false)
        nq.runner = { job in
            guard job.snapshot.isRunScopedStoryboard else { return .started }
            var ignored = 0
            if case .noShotToDispatch(let updated) = decide(job.snapshot.storyboardRuns, built: &ignored,
                                                           request: storyboardRequest) {
                nq.updateStoryboardRuns(jobID: job.id, runs: updated)
                nq.markFailed(jobID: job.id, reason: "stopped")
            }
            return .started
        }
        nq.setPaused(true)
        var fresh = try! StoryboardRunSubmission.makeJob(project: sp, workCount: 3, directorMode: "direct",
                                                         store: store, contentHash: hasher)
        fresh.snapshot.storyboardRuns = fresh.snapshot.storyboardRuns.map { run in
            var r = run; r.plan.shots[0].explicitStartImageContentHash = String(repeating: "f", count: 64); return r
        }
        let doomed = nq.enqueue(fresh)
        let behind = nq.enqueue(ProductionJob(kind: .generate, title: "behind", snapshot: ProductionJobSnapshot()))
        nq.setPaused(false)
        t.checkEqual(nq.job(id: doomed.id)?.state, .failed, "BATCHFAIL_11 the stopped job ends")
        t.checkEqual(nq.job(id: behind.id)?.state, .running, "BATCHFAIL_12 and the job behind it starts")
    }

}
