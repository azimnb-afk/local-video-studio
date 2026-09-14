import Foundation
import CryptoKit
@testable import LTXVideoGeneratorCore

/// A work that refuses before dispatch must not strand the works after it.
///
/// Reproduced live in Dev: Storyboard 作品数 3, work 1 rendered, work 2's frozen
/// starting image had been edited, work 3 was valid. Work 2 was marked failed —
/// and work 3 stayed queued for 15+ minutes with the parent "running" and the
/// renderer empty. The refusal returned `.failed` from the run-scoped starter,
/// but mid-run that result is discarded by the advance path, and no backend
/// request existed whose settlement could ever call it again.
///
/// A refusal is terminal for that one work, not an operation in flight. These
/// drive the same decision the service acts on.
func runMidRunRefusalTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MidRefuse-\(UUID().uuidString)", isDirectory: true)
    let store = FilmProjectStore(projectsDirectory: root)
    let imagePath = "Assets/Shots/start.png"
    let params = GenerationParameters(
        numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
        numFrames: 81, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1)

    func writeImage(_ bytes: String, projectID: UUID) {
        guard let url = store.managedProjectAssetURL(projectID: projectID, relativePath: imagePath) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(bytes.utf8).write(to: url)
    }
    func resolve(_ relative: String, _ projectID: UUID) -> String? {
        MovieRunRequestBuilder.resolveFrozenAssetPath(relative, projectID: projectID, store: store)
    }
    let hasher: (String) -> String? = { H3EndingImageCapability.contentHash(ofFileAt: $0) }

    func project(_ mode: String) -> FilmProject {
        var p = FilmProject(title: "refuse \(mode)")
        p.workflowMode = mode
        p.shots = [Shot(index: 0, title: "One", compiledPrompt: "one")]
        p.shots[0].startingImageReferenceAssetID = UUID()
        p.shots[0].continuityImageRelativePath = imagePath
        if mode == "hybrid" {
            p.openingReferenceImage = nil
        }
        return p
    }

    func storyboardDecision(_ runs: [StoryboardRun], counter: inout Int) -> RunScopedDispatchDriver.Decision<StoryboardRun> {
        var built = 0
        let decision = RunScopedDispatchDriver.nextShot(
            in: runs, takeID: UUID(),
            makeRequest: { run, shotID, takeID in
                let r = StoryboardRunRequestBuilder.makeRequest(
                    run: run, shotID: shotID, takeID: takeID, parameters: params,
                    resolveAsset: resolve, contentHash: hasher)
                if r != nil { built += 1 }
                return r
            },
            classifyRefusal: { run, shotID in
                RunDispatchRefusal.classify(run: run, shotID: shotID, resolveAsset: resolve, contentHash: hasher)
            })
        counter = built
        return decision
    }

    func movieDecision(_ runs: [MovieRun]) -> RunScopedDispatchDriver.Decision<MovieRun> {
        RunScopedDispatchDriver.nextShot(
            in: runs, takeID: UUID(),
            makeRequest: { run, shotID, takeID in
                MovieRunRequestBuilder.makeRequest(
                    run: run, shotID: shotID, takeID: takeID, parameters: params,
                    resolveAsset: resolve, contentHash: hasher)
            },
            classifyRefusal: { run, shotID in
                RunDispatchRefusal.classify(run: run, shotID: shotID, resolveAsset: resolve, contentHash: hasher)
            })
    }

    /// Storyboard 作品数 3 frozen from one real image, sorted by work.
    func storyboardRuns() -> [StoryboardRun] {
        let p = project("storyboard")
        writeImage("start-bytes", projectID: p.id)
        let job = try! StoryboardRunSubmission.makeJob(
            project: p, workCount: 3, directorMode: "direct", store: store, contentHash: hasher)
        return job.snapshot.storyboardRuns.sorted { $0.batchIndex < $1.batchIndex }
    }
    func movieRuns() -> [MovieRun] {
        let p = project("hybrid")
        writeImage("start-bytes", projectID: p.id)
        let job = try! MovieRunSubmission.makeJob(
            project: p, workCount: 3, directorMode: "direct", store: store, contentHash: hasher)
        return job.snapshot.movieRuns.sorted { $0.batchIndex < $1.batchIndex }
    }
    func shot<Run: RunScopedShotExecution>(_ run: Run) -> UUID { run.orderedShots[0].id }
    func complete<Run: RunScopedShotExecution>(_ runs: inout [Run], _ i: Int) {
        runs[i].update(shot(runs[i])) { $0.state = .completed; $0.outputPath = "/tmp/w\(i).mp4" }
    }
    /// Work `i` alone no longer matches its frozen bytes — one work refuses
    /// while its siblings, frozen identically, stay valid.
    func breakFrozenHash(_ runs: inout [StoryboardRun], _ i: Int) {
        runs[i].plan.shots[0].explicitStartImageContentHash = String(repeating: "0", count: 64)
    }
    func breakFrozenHash(_ runs: inout [MovieRun], _ i: Int) {
        runs[i].plan.shots[0].explicitStartImageContentHash = String(repeating: "0", count: 64)
    }

    t.suite("Mid-run refusal — the next work still gets its chance") {

        // MIDREFUSE_1 — the live shape: 1 complete, 2 refuses, 3 valid.
        var runs = storyboardRuns()
        complete(&runs, 0)
        breakFrozenHash(&runs, 1)
        let seed3 = runs[2].orderedShots[0].seed
        var built = 0
        let decision = storyboardDecision(runs, counter: &built)
        guard case .dispatch(let after, let runIndex, let shotID, let request) = decision else {
            t.check(false, "MIDREFUSE_1 work 3 is dispatched after work 2 refuses (got \(decision))")
            return
        }
        t.checkEqual(after[runIndex].batchIndex, 2, "MIDREFUSE_1 the dispatched work is work 3")
        t.checkEqual(shotID, shot(runs[2]), "MIDREFUSE_1 with work 3's own shot")

        // MIDREFUSE_6 / _11 — the refusal is recorded once, on work 2 only.
        t.checkEqual(after[1].state(of: shot(after[1]))?.state, .failed,
                     "MIDREFUSE_6 work 2 is recorded failed")
        t.checkEqual(after[1].state(of: shot(after[1]))?.attemptNumber, 1,
                     "MIDREFUSE_6 exactly once — no retry attempt was spent")
        t.checkEqual(after.flatMap(\.shotStates).filter { $0.state == .failed }.count, 1,
                     "MIDREFUSE_6 one failed shot in the whole job")
        t.check((after[1].state(of: shot(after[1]))?.failureReason ?? "").contains("変更されています"),
                "MIDREFUSE_11 work 2 carries the changed-image reason")
        t.checkEqual(after[0].state(of: shot(after[0]))?.failureReason, nil,
                     "MIDREFUSE_11 work 1 carries none")
        t.checkEqual(after[2].state(of: shot(after[2]))?.failureReason, nil,
                     "MIDREFUSE_11 work 3 carries none")

        // MIDREFUSE_7 / _8 — nothing pretends work 2 reached the renderer.
        t.checkEqual(built, 1, "MIDREFUSE_7 exactly one real request was built — for work 3")
        t.checkEqual(after[1].state(of: shot(after[1]))?.dispatchedRequestID, nil,
                     "MIDREFUSE_8 the refused work has no dispatched request to wait on")
        t.check(request.shotID == shot(runs[2]),
                "MIDREFUSE_7 the request is work 3's, not a stand-in for work 2")

        // MIDREFUSE_9 / _10 — identity of the surviving works.
        t.checkEqual(request.parameters.seed, seed3,
                     "MIDREFUSE_9 work 3 renders with its submission seed")
        t.checkEqual(after[0].state(of: shot(after[0]))?.state, .completed,
                     "MIDREFUSE_10 work 1 stays completed and is not dispatched again")

        // MIDREFUSE_3 — Auto Movie, same shape.
        var movie = movieRuns()
        complete(&movie, 0)
        movie[0].assembly.state = .completed
        breakFrozenHash(&movie, 1)
        let movieDecided = movieDecision(movie)
        if case .dispatch(let mAfter, let mIndex, _, _) = movieDecided {
            t.checkEqual(mAfter[mIndex].batchIndex, 2, "MIDREFUSE_3 Auto Movie dispatches work 3")
            t.checkEqual(mAfter[1].state(of: shot(mAfter[1]))?.state, .failed,
                         "MIDREFUSE_3 after recording work 2 failed")
        } else {
            t.check(false, "MIDREFUSE_3 Auto Movie dispatches work 3 after work 2 refuses (got \(movieDecided))")
        }

        // MIDREFUSE_14 — the last work refuses: nothing is left to dispatch,
        // and the refusal is already recorded so the job can settle now.
        var last = storyboardRuns()
        complete(&last, 0)
        complete(&last, 1)
        breakFrozenHash(&last, 2)
        var lastBuilt = 0
        let lastDecision = storyboardDecision(last, counter: &lastBuilt)
        if case .noShotToDispatch(let settled) = lastDecision {
            t.checkEqual(settled[2].state(of: shot(settled[2]))?.state, .failed,
                         "MIDREFUSE_14 the last work is recorded failed")
            t.check(StoryboardRunDriver.allSettled(settled),
                    "MIDREFUSE_14 and every work is settled — no settlement to wait for")
        } else {
            t.check(false, "MIDREFUSE_14 a refused last work leaves nothing to dispatch (got \(lastDecision))")
        }

        // MIDREFUSE_13 — every remaining work refuses (the live E2E, where
        // works 2 and 3 share the edited image): finite, settled, no request.
        // The shared image is a batch-wide failure (BatchFailurePolicy), so
        // work 2 records the real refusal and work 3, which froze the same
        // file and bytes, is stopped as not attempted rather than failed again.
        var allRefuse = storyboardRuns()
        complete(&allRefuse, 0)
        breakFrozenHash(&allRefuse, 1)
        breakFrozenHash(&allRefuse, 2)
        var noneBuilt = 0
        let allDecision = storyboardDecision(allRefuse, counter: &noneBuilt)
        if case .noShotToDispatch(let settled) = allDecision {
            t.checkEqual(settled.map { $0.state(of: shot($0))?.state }, [.completed, .failed, .dependencyBlocked],
                         "MIDREFUSE_13 work 2 is recorded failed and work 3 is stopped")
            t.checkEqual(settled[2].state(of: shot(settled[2]))?.notAttempted, true,
                         "MIDREFUSE_13 work 3 is marked not attempted")
            t.check(StoryboardRunDriver.allSettled(settled), "MIDREFUSE_13 and the job is settled")
            t.checkEqual(noneBuilt, 0, "MIDREFUSE_13 without building any request")
        } else {
            t.check(false, "MIDREFUSE_13 all remaining refusals settle finitely (got \(allDecision))")
        }

        // MIDREFUSE_15 — a real in-flight attempt is waited on, not failed.
        var active = storyboardRuns()
        complete(&active, 0)
        active[1].update(shot(active[1])) { $0.state = .running; $0.dispatchedRequestID = UUID() }
        var activeBuilt = 0
        let activeDecision = storyboardDecision(active, counter: &activeBuilt)
        if case .waitingOnActiveRequest = activeDecision {
            t.check(true, "MIDREFUSE_15 an in-flight work is waited on")
        } else {
            t.check(false, "MIDREFUSE_15 an in-flight work is waited on (got \(activeDecision))")
        }
        t.checkEqual(activeBuilt, 0, "MIDREFUSE_15 and nothing else is dispatched past it")
    }

    t.suite("Mid-run refusal — the job ends instead of claiming progress") {

        // MIDREFUSE_2 / _12 — after the refusal, the job is judged, not left running.
        var refusedLast = storyboardRuns()
        complete(&refusedLast, 0)
        complete(&refusedLast, 2)
        breakFrozenHash(&refusedLast, 1)
        var ignored = 0
        guard case .noShotToDispatch(let judged) = storyboardDecision(refusedLast, counter: &ignored) else {
            t.check(false, "MIDREFUSE_2 fixture: nothing left to dispatch"); return
        }
        t.checkEqual(RunScopedDispatchDriver.storyboardCompletion(judged), .settled(allCompleted: false),
                     "MIDREFUSE_2 the parent settles as failed rather than staying running")
        var allDone = storyboardRuns()
        (0..<3).forEach { complete(&allDone, $0) }
        t.checkEqual(RunScopedDispatchDriver.storyboardCompletion(allDone), .settled(allCompleted: true),
                     "MIDREFUSE_12 once every work has completed, the parent completes")

        // No-dispatchable-work guard: unfinished work, nothing runnable, nothing
        // in flight. A shot left `interrupted` inside a run is exactly that.
        var stuck = storyboardRuns()
        complete(&stuck, 0)
        complete(&stuck, 1)
        stuck[2].update(shot(stuck[2])) { $0.state = .interrupted }
        guard case .noShotToDispatch(let stuckRuns) = storyboardDecision(stuck, counter: &ignored) else {
            t.check(false, "MIDREFUSE_GUARD fixture: nothing dispatchable, nothing in flight"); return
        }
        t.checkEqual(RunScopedDispatchDriver.storyboardCompletion(stuckRuns), .stalled,
                     "MIDREFUSE_GUARD unfinished work that can never start is classified stalled")

        // Auto Movie completion includes the film.
        var film = movieRuns()
        for i in 0..<3 { complete(&film, i) }
        film[0].assembly.state = .completed
        film[1].assembly.state = .running
        t.checkEqual(RunScopedDispatchDriver.movieCompletion(film), nil,
                     "MIDREFUSE_15 a running assembly is waited on, not judged")
        film[1].assembly.state = .completed
        film[2].assembly.state = .waiting
        t.checkEqual(RunScopedDispatchDriver.movieCompletion(film), .stalled,
                     "MIDREFUSE_GUARD an assembly that could not start is stalled, not waited on forever")
        film[2].assembly.state = .completed
        t.checkEqual(RunScopedDispatchDriver.movieCompletion(film), .settled(allCompleted: true),
                     "MIDREFUSE_12 every film assembled: the movie job completes")

        // MIDREFUSE_4 / _5 — Generate and One Shot hand every request to the
        // renderer at once, whose loop moves on after a failed request; they
        // never enter the run-scoped dispatch path this fix is in.
        var genSnap = ProductionJobSnapshot()
        genSnap.pendingRequests = CandidateExpander.expand(
            GenerationRequest(prompt: "p", parameters: params), count: 3)
        let generate = RunProvenanceStamper.stamp(ProductionJob(kind: .generate, title: "g", snapshot: genSnap))
        let oneShot = RunProvenanceStamper.stamp(ProductionJob(kind: .oneShot, title: "o", snapshot: genSnap))
        for job in [generate, oneShot] {
            t.check(!job.snapshot.isRunScopedStoryboard && !job.snapshot.isRunScopedMovie,
                    "MIDREFUSE_4/5 \(job.kind) is not run-scoped, so it never reaches this starter")
            t.checkEqual(job.snapshot.pendingRequests.count, 3,
                         "MIDREFUSE_4/5 \(job.kind) submits all works to the renderer together")
        }
    }

    t.suite("Mid-run refusal — the job behind it starts") {
        // MIDREFUSE_16 — drive a real coordinator with a runner that acts on the
        // driver exactly as the run-scoped starter does: dispatch → started;
        // nothing left → persist and end the job.
        let queueRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MidRefuseQueue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: queueRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: queueRoot) }
        let queue = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: queueRoot.appendingPathComponent("q.json")),
            restoreOnInit: false)
        var started: [String] = []
        queue.runner = { job in
            started.append(job.title)
            guard job.snapshot.isRunScopedStoryboard else { return .started }
            var ignored = 0
            switch storyboardDecision(job.snapshot.storyboardRuns, counter: &ignored) {
            case .dispatch, .waitingOnActiveRequest:
                return .started
            case .noShotToDispatch(let updated):
                queue.updateStoryboardRuns(jobID: job.id, runs: updated)
                switch RunScopedDispatchDriver.storyboardCompletion(updated) {
                case .settled(allCompleted: true): queue.markCompleted(jobID: job.id)
                case .settled(allCompleted: false), .stalled:
                    queue.markFailed(jobID: job.id, reason: "refused")
                }
                return .started
            }
        }
        queue.setPaused(true)
        var everyWorkRefuses = storyboardRuns()
        (0..<3).forEach { breakFrozenHash(&everyWorkRefuses, $0) }
        var job = ProductionJob(kind: .storyboard, title: "refusing", snapshot: ProductionJobSnapshot())
        job.snapshot.storyboardRuns = everyWorkRefuses
        let refusing = queue.enqueue(job)
        let behind = queue.enqueue(ProductionJob(kind: .generate, title: "behind", snapshot: ProductionJobSnapshot()))
        queue.setPaused(false)

        t.checkEqual(queue.job(id: refusing.id)?.state, .failed,
                     "MIDREFUSE_16 a job whose every work refuses ends — at start, too")
        // Every work froze the same broken image: the first records the
        // refusal, the rest are stopped as not attempted (BatchFailurePolicy).
        t.checkEqual(queue.job(id: refusing.id)?.snapshot.storyboardRuns.map { $0.shotStates[0].state },
                     [.failed, .dependencyBlocked, .dependencyBlocked],
                     "MIDREFUSE_16 with every work settled, not only the first")
        t.checkEqual(queue.job(id: refusing.id)?.snapshot.storyboardRuns.map { $0.shotStates[0].notAttempted },
                     [nil, true, true],
                     "MIDREFUSE_16 the stopped works are marked not attempted")
        t.checkEqual(queue.job(id: behind.id)?.state, .running,
                     "MIDREFUSE_16 and the job behind it starts")
        t.checkEqual(started, ["refusing", "behind"], "MIDREFUSE_16 in queue order")
    }

    try? FileManager.default.removeItem(at: root)
}
