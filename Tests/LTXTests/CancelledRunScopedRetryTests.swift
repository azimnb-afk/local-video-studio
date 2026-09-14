import Foundation
@testable import LTXVideoGeneratorCore

/// What a cancelled run-scoped job leaves behind, and whether a fresh attempt
/// built from it can run.
///
/// Cancelling a job goes through `ProductionQueueService.cancel` →
/// `ProductionQueueCoordinator.cancel`, which stops the renderer and marks the
/// *job* cancelled but never touches the frozen runs: the shot that was
/// rendering stays `running` with its `dispatchedRequestID`, and no run is
/// marked cancelled (`StoryboardRunScheduler.cancel` has no callers, and a
/// `.cancelled` settlement is recorded as `.failed`). Both cancelled run-scoped
/// jobs in the real Dev queue have exactly that shape.
///
/// That is the same stale in-flight state an app quit leaves, so these pin that
/// Retry of a cancelled job goes through the same normalisation as Restart.
func runCancelledRunScopedRetryTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CancelResume-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    /// Two shots; the second CONTINUEs from the first, so it carries a
    /// same-run dependency.
    func project(_ mode: String) -> FilmProject {
        var p = FilmProject(title: "Cancel \(mode)")
        p.workflowMode = mode
        p.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        p.shots[1].continuityMode = .continueFromPrevious
        return p
    }

    /// Starts `job`, applies `inFlight` to its persisted runs, then cancels it
    /// through the production coordinator path.
    func cancelMidRun(
        _ job: ProductionJob, name: String,
        inFlight: (ProductionQueueCoordinator, ProductionJob) -> Void
    ) -> (ProductionQueueCoordinator, ProductionJob) {
        let store = ProductionQueueStore(fileURL: root.appendingPathComponent("\(name).json"))
        let queue = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        queue.runner = { _ in .started }
        let started = queue.enqueue(job)
        inFlight(queue, queue.job(id: started.id)!)
        queue.cancel(jobID: started.id)
        return (queue, queue.job(id: started.id)!)
    }

    /// A fresh attempt is healthy when every unfinished run has something the
    /// scheduler can hand out now — a shot to render, or an assembly to start —
    /// and nothing is waiting on a request that no longer exists.
    func hasNoStaleInFlight<Run: RunScopedShotExecution>(_ runs: [Run]) -> Bool {
        !runs.contains { $0.shotStates.contains { $0.state == .running || $0.dispatchedRequestID != nil } }
    }

    t.suite("Cancelled run-scoped Retry — a cancelled Storyboard resumes") {
        let job = try! StoryboardRunSubmission.makeJob(
            project: project("storyboard"), workCount: 1, directorMode: "direct")
        let run0 = job.snapshot.storyboardRuns[0]
        let first = run0.orderedShots[0].id, second = run0.orderedShots[1].id
        let seeds = run0.orderedShots.map(\.seed)
        let staleRequest = UUID()

        let (queue, cancelled) = cancelMidRun(job, name: "sb") { q, j in
            var runs = j.snapshot.storyboardRuns
            runs[0].update(first) {
                $0.state = .running
                $0.dispatchedRequestID = staleRequest
                $0.dispatchedTakeID = UUID()
            }
            q.updateStoryboardRuns(jobID: j.id, runs: runs)
        }

        // Fixture matches the real Dev snapshot, not an idealised one.
        t.checkEqual(cancelled.state, .cancelled, "fixture: the job is cancelled")
        t.checkEqual(cancelled.snapshot.storyboardRuns[0].state(of: first)?.dispatchedRequestID,
                     staleRequest,
                     "fixture: cancel leaves the stale in-flight request, as in real data")
        t.check(!cancelled.snapshot.storyboardRuns[0].isCancelled,
                "fixture: and never marks the run cancelled")
        t.check(cancelled.canRetry, "fixture: the Retry API accepts a cancelled job")

        guard let retried = queue.retry(jobID: cancelled.id) else {
            t.check(false, "CANCELRESUME_1 Retry produced a job"); return
        }
        let runs = retried.snapshot.storyboardRuns
        t.check(hasNoStaleInFlight(runs),
                "CANCELRESUME_1 the new attempt carries no stale running request")
        t.checkEqual(runs[0].state(of: first)?.dispatchedRequestID, nil,
                     "CANCELRESUME_3 the stale dispatchedRequestID is cleared")
        t.checkEqual(runs[0].state(of: first)?.state, .queued,
                     "CANCELRESUME_5 the interrupted shot is retryable, not stuck running")
        t.checkEqual(runs[0].state(of: first)?.attemptNumber, 2,
                     "CANCELRESUME_6 as a new attempt")
        t.checkEqual(runs[0].orderedShots.map(\.seed), seeds,
                     "CANCELRESUME_7 seeds are unchanged")
        t.checkEqual(StoryboardRunDriver.nextDispatch(in: runs)?.shotID, first,
                     "CANCELRESUME_10 the first unfinished shot is dispatchable")

        // CANCELRESUME_8 — the CONTINUE shot still depends on this run's own
        // upstream, and waits for it rather than being blocked.
        let dependency = runs[0].state(of: second)?.dependency
        t.checkEqual(dependency?.upstreamShotID, first,
                     "CANCELRESUME_8 the continuation still points at the same upstream shot")
        t.checkEqual(dependency?.runID, runs[0].id,
                     "CANCELRESUME_8 in the same run")
        t.checkEqual(runs[0].state(of: second)?.attemptNumber, 1,
                     "CANCELRESUME_6 a shot that never ran keeps its attempt number")
        switch StoryboardRunScheduler.next(runs[0]) {
        case .render(let id): t.checkEqual(id, first, "CANCELRESUME_8 upstream renders first")
        default: t.check(false, "CANCELRESUME_8 upstream renders first")
        }
    }

    t.suite("Cancelled run-scoped Retry — a cancelled Auto Movie resumes") {
        let job = try! MovieRunSubmission.makeJob(
            project: project("hybrid"), workCount: 2, directorMode: "direct")
        let finishedRun = job.snapshot.movieRuns[0]
        let activeRun = job.snapshot.movieRuns[1]

        let (queue, cancelled) = cancelMidRun(job, name: "movie") { q, j in
            var runs = j.snapshot.movieRuns
            // E — one work already produced its film.
            for shot in runs[0].orderedShots {
                runs[0].update(shot.id) {
                    $0.state = .completed
                    $0.outputPath = "/tmp/done-\(shot.index).mp4"
                }
            }
            runs[0].assembly.state = .completed
            runs[0].assembly.outputPath = "/tmp/done-final.mp4"
            // A — the other was mid-shot when the user cancelled.
            runs[1].update(runs[1].orderedShots[0].id) {
                $0.state = .running
                $0.dispatchedRequestID = UUID()
            }
            q.updateMovieRuns(jobID: j.id, runs: runs)
        }
        t.checkEqual(cancelled.state, .cancelled, "fixture: cancelled")

        guard let retried = queue.retry(jobID: cancelled.id) else {
            t.check(false, "CANCELRESUME_2 Retry produced a job"); return
        }
        let runs = retried.snapshot.movieRuns
        t.check(hasNoStaleInFlight(runs),
                "CANCELRESUME_2 the new movie attempt carries no stale running request")
        t.checkEqual(StoryboardRunDriver.nextDispatch(in: runs)?.runID, activeRun.id,
                     "CANCELRESUME_10 the unfinished work is what gets dispatched")

        // CANCELRESUME_4 / _12 — the finished work is not re-generated.
        t.check(runs[0].shotStates.allSatisfy { $0.state == .completed && $0.attemptNumber == 1 },
                "CANCELRESUME_4 completed shots stay completed, attempt 1")
        t.checkEqual(runs[0].assembly.state, .completed,
                     "CANCELRESUME_12 its film stays completed")
        t.checkEqual(runs[0].assembly.outputPath, "/tmp/done-final.mp4",
                     "CANCELRESUME_12 with its output")
        t.checkEqual(runs[0].assembly.attemptNumber, 1,
                     "CANCELRESUME_12 and no new assembly attempt")
        t.checkEqual(runs[0].id, finishedRun.id, "CANCELRESUME_12 run identity preserved")
        t.checkEqual(runs[1].orderedShots.map(\.seed), activeRun.orderedShots.map(\.seed),
                     "CANCELRESUME_7 seeds are unchanged for the resumed work")
    }

    t.suite("Cancelled run-scoped Retry — cancelled during assembly") {
        let job = try! MovieRunSubmission.makeJob(
            project: project("hybrid"), workCount: 1, directorMode: "direct")
        let (queue, cancelled) = cancelMidRun(job, name: "asm") { q, j in
            var runs = j.snapshot.movieRuns
            for shot in runs[0].orderedShots {
                runs[0].update(shot.id) {
                    $0.state = .completed
                    $0.outputPath = "/tmp/clip-\(shot.index).mp4"
                }
            }
            runs[0].assembly.state = .running
            q.updateMovieRuns(jobID: j.id, runs: runs)
        }
        guard let retried = queue.retry(jobID: cancelled.id) else {
            t.check(false, "CANCELRESUME_9 Retry produced a job"); return
        }
        let run = retried.snapshot.movieRuns[0]
        t.check(run.assembly.state == .waiting || run.assembly.state == .ready,
                "CANCELRESUME_9 an assembly cancelled mid-run is eligible to run again")
        t.checkEqual(run.assembly.attemptNumber, 2, "CANCELRESUME_9 as a new assembly attempt")
        t.check(run.shotStates.allSatisfy { $0.state == .completed && $0.attemptNumber == 1 },
                "CANCELRESUME_9 without re-rendering any shot")
    }

    t.suite("Cancelled run-scoped Retry — the queue behind it keeps moving") {
        // The stall this guards against is a job that starts with nothing it
        // can run. Model the run-scoped starter's decision exactly: `.started`
        // is only honest when there is a shot to dispatch.
        let job = try! StoryboardRunSubmission.makeJob(
            project: project("storyboard"), workCount: 1, directorMode: "direct")
        let store = ProductionQueueStore(fileURL: root.appendingPathComponent("behind.json"))
        let queue = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        var starts: [String] = []
        queue.runner = { job in
            starts.append(job.title)
            guard job.snapshot.isRunScopedStoryboard else { return .started }
            return StoryboardRunDriver.nextDispatch(in: job.snapshot.storyboardRuns) != nil
                ? .started : .failed("nothing dispatchable")
        }
        let original = queue.enqueue(job)
        var runs = queue.job(id: original.id)!.snapshot.storyboardRuns
        runs[0].update(runs[0].orderedShots[0].id) {
            $0.state = .running
            $0.dispatchedRequestID = UUID()
        }
        queue.updateStoryboardRuns(jobID: original.id, runs: runs)
        queue.cancel(jobID: original.id)

        queue.setPaused(true)
        let retried = queue.retry(jobID: original.id)!
        let behind = queue.enqueue(ProductionJob(
            kind: .generate, title: "behind", snapshot: ProductionJobSnapshot()))
        queue.setPaused(false)

        t.checkEqual(queue.job(id: retried.id)?.state, .running,
                     "CANCELRESUME_11 the retried job starts with real work, not a false start")
        queue.markCompleted(jobID: retried.id)
        t.checkEqual(queue.job(id: behind.id)?.state, .running,
                     "CANCELRESUME_11 and the job behind it runs once it finishes")
        t.check(!starts.isEmpty, "CANCELRESUME_11 fixture: the runner was exercised")
    }

    try? FileManager.default.removeItem(at: root)
}
