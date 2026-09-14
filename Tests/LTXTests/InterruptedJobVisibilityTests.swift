import Foundation
@testable import LTXVideoGeneratorCore

/// `.interrupted` is written in exactly one place — relaunch finding a job
/// recorded as `running` — so it always means "the app quit mid-job". Whether
/// it deserves the user's attention depends on whether Restart would do
/// anything. The real Dev queue held both kinds: four Generate jobs with an
/// unfinished render, two run-scoped Auto Movies stopped mid-shot, and a One
/// Shot whose two candidates had both already succeeded before the quit.
func runInterruptedJobVisibilityTests(_ t: TestKit) {

    func request() -> GenerationRequest {
        GenerationRequest(
            prompt: "p",
            parameters: GenerationParameters(
                numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
                numFrames: 81, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1))
    }

    func interrupted(
        _ title: String, kind: ProductionJobKind = .generate,
        snapshot: ProductionJobSnapshot
    ) -> ProductionJob {
        var j = ProductionJob(kind: kind, title: title, snapshot: snapshot)
        j.state = .interrupted
        j.stageDescription = "Interrupted when the app quit"
        return j
    }

    func displayed(_ jobs: [ProductionJob]) -> [String] {
        ProductionQueueCoordinator.activeDisplayJobs(from: jobs).map(\.title)
    }

    // Unfinished Generate: one pending render, no outcome recorded.
    var unfinishedSnap = ProductionJobSnapshot()
    unfinishedSnap.pendingRequests = [request()]
    let unfinished = interrupted("unfinished generate", snapshot: unfinishedSnap)

    // Already done: every pending request has a successful outcome. Restart
    // returns nil for this — there is nothing left to run.
    var doneSnap = ProductionJobSnapshot()
    let r1 = request(), r2 = request()
    doneSnap.pendingRequests = [r1, r2]
    doneSnap.runOutcomes = [
        RunOutcomeRecord(runID: r1.id, outcome: .completed, attemptNumber: 1, failureReason: nil),
        RunOutcomeRecord(runID: r2.id, outcome: .completed, attemptNumber: 1, failureReason: nil),
    ]
    let alreadyDone = interrupted("already done", kind: .oneShot, snapshot: doneSnap)

    // Run-scoped Auto Movie stopped mid-shot.
    var movieProject = FilmProject(title: "movie")
    movieProject.workflowMode = "hybrid"
    movieProject.shots = [Shot(index: 0, title: "One", compiledPrompt: "one")]
    let movieJob = try! MovieRunSubmission.makeJob(
        project: movieProject, workCount: 1, directorMode: "direct")
    var midShot = movieJob.snapshot
    midShot.movieRuns[0].update(midShot.movieRuns[0].orderedShots[0].id) {
        $0.state = .running
        $0.dispatchedRequestID = UUID()
    }
    let movieInterrupted = interrupted("movie mid-shot", kind: .autoMovie, snapshot: midShot)

    // Run-scoped movie that had in fact produced its film.
    var finishedMovie = movieJob.snapshot
    finishedMovie.movieRuns[0].update(finishedMovie.movieRuns[0].orderedShots[0].id) {
        $0.state = .completed
    }
    finishedMovie.movieRuns[0].assembly.state = .completed
    let movieDone = interrupted("movie finished", kind: .autoMovie, snapshot: finishedMovie)

    // Legacy project-driven job: no frozen runs, no pending requests.
    let legacy = interrupted("legacy movie", kind: .autoMovie, snapshot: ProductionJobSnapshot())

    var failed = ProductionJob(kind: .generate, title: "failed", snapshot: ProductionJobSnapshot())
    failed.state = .failed
    failed.failureReason = "backend failed"
    var cancelled = ProductionJob(kind: .generate, title: "cancelled", snapshot: ProductionJobSnapshot())
    cancelled.state = .cancelled
    var completed = ProductionJob(kind: .generate, title: "completed", snapshot: ProductionJobSnapshot())
    completed.state = .completed
    var running = ProductionJob(kind: .generate, title: "running", snapshot: ProductionJobSnapshot())
    running.state = .running

    t.suite("Production Queue — interrupted jobs show when Restart would do work") {

        // INTERRUPTEDUI_1 — actionable interrupted work stays readable.
        t.checkEqual(displayed([unfinished]), ["unfinished generate"],
                     "INTERRUPTEDUI_1 an unfinished interrupted render is displayed")
        t.checkEqual(displayed([movieInterrupted]), ["movie mid-shot"],
                     "INTERRUPTEDUI_1 so is a run-scoped movie stopped mid-shot")
        t.checkEqual(displayed([legacy]), ["legacy movie"],
                     "INTERRUPTEDUI_1 and a legacy job, whose Restart re-runs from its project")

        // INTERRUPTEDUI_2 / _3 / _4 — the existing policy is untouched.
        t.checkEqual(displayed([cancelled]), [], "INTERRUPTEDUI_2 cancelled stays hidden")
        t.checkEqual(displayed([completed]), [], "INTERRUPTEDUI_3 completed stays hidden")
        t.checkEqual(displayed([failed]), ["failed"], "INTERRUPTEDUI_4 failed stays visible")

        // INTERRUPTEDUI_5 — every displayed interrupted job has a Restart that
        // does something.
        for job in [unfinished, movieInterrupted, legacy] {
            t.check(job.canRestart && job.restartWouldDoWork,
                    "INTERRUPTEDUI_5 \(job.title): Restart is offered and has work to do")
        }

        // INTERRUPTEDUI_11 — historical interrupted records with nothing left
        // to run stay hidden: showing them would offer a Restart that does
        // nothing.
        t.checkEqual(displayed([alreadyDone]), [],
                     "INTERRUPTEDUI_11 an interrupted job whose runs all succeeded stays hidden")
        t.check(!alreadyDone.restartWouldDoWork,
                "INTERRUPTEDUI_11 because Restart would find nothing to run")
        t.checkEqual(displayed([movieDone]), [],
                     "INTERRUPTEDUI_11 as does a movie that had already produced its film")

        // INTERRUPTEDUI_7 — pure projection, stable across redraws.
        let mixed = [unfinished, alreadyDone, movieInterrupted, movieDone, failed, completed]
        t.checkEqual(displayed(mixed), displayed(mixed),
                     "INTERRUPTEDUI_7 recomputing the display set is stable")
        t.checkEqual(Set(displayed(mixed)),
                     Set(["unfinished generate", "movie mid-shot", "failed"]),
                     "INTERRUPTEDUI_7 and shows exactly the actionable jobs")

        // INTERRUPTEDUI_8 — the reason text travels with the job.
        let shown = ProductionQueueCoordinator.activeDisplayJobs(from: [unfinished]).first
        t.checkEqual(shown?.stageDescription, "Interrupted when the app quit",
                     "INTERRUPTEDUI_8 the interrupted explanation reaches the display model")
        t.checkEqual(shown?.failureReason, nil,
                     "INTERRUPTEDUI_8 and it is not dressed up as a failure")

        // INTERRUPTEDUI_12 — projecting mutates nothing.
        let before = mixed
        _ = ProductionQueueCoordinator.activeDisplayJobs(from: mixed)
        t.checkEqual(mixed, before, "INTERRUPTEDUI_12 display projection does not mutate jobs")
        t.check(ProductionJobState.interrupted.isTerminal,
                "INTERRUPTEDUI_12 interrupted stays terminal")
    }

    t.suite("Production Queue — interrupted dismissal, Clear Failed and Pause") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterruptedUI-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Build interrupted records the way production does: running at quit,
        // then relaunched.
        let store = ProductionQueueStore(fileURL: root.appendingPathComponent("q.json"))
        let before = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        before.runner = { _ in .started }
        let a = before.enqueue(ProductionJob(kind: .generate, title: "A", snapshot: unfinishedSnap))
        store.flush()
        var queue = ProductionQueueCoordinator(store: store, restoreOnInit: true)
        queue.runner = { _ in .started }
        queue.setPaused(true)
        let b = queue.enqueue(ProductionJob(kind: .generate, title: "B", snapshot: unfinishedSnap))
        queue.setPaused(false)
        queue.runner = { _ in .started }
        // B is now running; persist and relaunch again so it is interrupted too.
        store.flush()
        queue = ProductionQueueCoordinator(store: store, restoreOnInit: true)
        let f = queue.enqueue(ProductionJob(kind: .generate, title: "F", snapshot: ProductionJobSnapshot()))
        queue.markFailed(jobID: f.id, reason: "backend failed")

        t.checkEqual(queue.job(id: a.id)?.state, .interrupted, "fixture: A interrupted by relaunch")
        t.checkEqual(queue.job(id: b.id)?.state, .interrupted, "fixture: B interrupted by relaunch")

        // INTERRUPTEDUI_6 — dismissing one interrupted job touches only it.
        queue.remove(jobID: a.id)
        t.checkEqual(Set(queue.activeDisplayJobs.map(\.title)), Set(["B", "F"]),
                     "INTERRUPTEDUI_6 dismissing A removes only A")
        t.checkEqual(queue.job(id: b.id)?.state, .interrupted,
                     "INTERRUPTEDUI_6 B is untouched")

        // INTERRUPTEDUI_9 — Clear Failed clears failures, not interruptions.
        queue.removeFailed()
        t.checkEqual(queue.activeDisplayJobs.map(\.title), ["B"],
                     "INTERRUPTEDUI_9 Clear Failed leaves the interrupted job")
        t.check(queue.job(id: f.id) == nil, "INTERRUPTEDUI_9 and removes the failure")

        // INTERRUPTEDUI_10 — Pause reflects pausable work only.
        t.check(!ProductionQueueCoordinator.showsPauseControl(
                    jobs: queue.jobs, isPaused: queue.isPaused),
                "INTERRUPTEDUI_10 an interrupted-only queue hides Pause")
        t.check(ProductionQueueCoordinator.showsPauseControl(
                    jobs: [queue.job(id: b.id)!, running], isPaused: false),
                "INTERRUPTEDUI_10 running + interrupted shows Pause")

        // INTERRUPTEDUI_5 — Restart from the queue produces runnable work.
        queue.runner = { _ in .started }
        let restarted = queue.retry(jobID: b.id)
        // `retry` returns the record as appended; read back the live one.
        t.checkEqual(restarted.flatMap { queue.job(id: $0.id) }?.state, .running,
                     "INTERRUPTEDUI_5 Restart starts a new attempt on an idle queue")
        t.checkEqual(restarted?.snapshot.pendingRequests.first?.attemptNumber, 2,
                     "INTERRUPTEDUI_5 as attempt 2")
    }
}
