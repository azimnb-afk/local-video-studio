import Foundation
@testable import LTXVideoGeneratorCore

/// A run stopped through `StoryboardRunScheduler.cancel` must not turn Retry
/// into a no-op.
///
/// The live parent cancel never calls the scheduler's cancel: it leaves the
/// frozen runs as they were (see `CancelledRunScopedRetryTests`). The scheduler
/// API cancels one run — marks it cancelled and its unstarted shots
/// `.cancelled` — and the rest of the run-scoped state machine reads that shape
/// as settled. Retry reopened only failed, blocked, interrupted or running
/// shots, so it carried the cancelled run forward verbatim: the new job had
/// unfinished work, nothing it could dispatch, and ended at once without
/// rendering anything — every time Retry was pressed. A final assembly left
/// `.cancelled` had the same problem.
///
/// Queue cases drive the real `ProductionQueueService`; the renderer's
/// readiness check is stubbed to fail, so a dispatched shot is counted and
/// settles without Python. Waiting spins the main run loop, bounded.
func runRunScopedCancelRetryTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunCancel-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default

    func spin(maxTurns: Int = 400, until done: () -> Bool) -> Bool {
        for _ in 0..<maxTurns {
            if done() { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return done()
    }

    /// Three shots; the second and third CONTINUE from the one before.
    func project(_ mode: String, continuing: Bool = true, shots: Int = 3) -> FilmProject {
        var p = FilmProject(title: "RunCancel \(mode)")
        p.workflowMode = mode
        p.settings.modelID = "ltx23_distilled_q4"
        p.shots = (0..<shots).map { Shot(index: $0, title: "S\($0)", compiledPrompt: "shot \($0)") }
        if continuing { for i in 1..<shots { p.shots[i].continuityMode = .continueFromPrevious } }
        return p
    }

    func clip(_ name: String) -> String {
        let path = root.appendingPathComponent("\(name).mp4").path
        fm.createFile(atPath: path, contents: Data(name.utf8))
        return path
    }

    func coordinator(_ name: String) -> ProductionQueueCoordinator {
        let q = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(name).json")),
            restoreOnInit: false)
        q.runner = { _ in .started }
        return q
    }

    /// Work 1: shot 1 done, shot 2 rendering, shot 3 not started — then the
    /// scheduler's cancel. Work 2 is left untouched.
    func schedulerCancelled<Run: RunScopedShotExecution>(_ run: inout Run, staleRequest: UUID) {
        let shots = run.orderedShots
        StoryboardRunScheduler.recordCompletion(
            in: &run, shotID: shots[0].id, takeID: UUID(), outputPath: "/tmp/runcancel-0.mp4")
        run.update(shots[1].id) {
            $0.state = .running
            $0.dispatchedRequestID = staleRequest
            $0.dispatchedTakeID = UUID()
        }
        StoryboardRunScheduler.cancel(&run)
    }

    // MARK: The API's shape, and the current parent cancel beside it

    t.suite("Run cancel — the scheduler API and the parent cancel") {
        // RUNCANCEL_1 — the supported parent cancel still leaves runs alone.
        let parent = coordinator("parent")
        let job = parent.enqueue(try! StoryboardRunSubmission.makeJob(
            project: project("storyboard"), workCount: 1, directorMode: "direct"))
        var runs = parent.job(id: job.id)!.snapshot.storyboardRuns
        let request = UUID()
        runs[0].update(runs[0].orderedShots[0].id) { $0.state = .running; $0.dispatchedRequestID = request }
        parent.updateStoryboardRuns(jobID: job.id, runs: runs)
        parent.cancel(jobID: job.id)
        let afterParent = parent.job(id: job.id)!
        t.checkEqual(afterParent.state, .cancelled, "RUNCANCEL_1 the parent job is cancelled")
        t.check(!afterParent.snapshot.storyboardRuns[0].isCancelled,
                "RUNCANCEL_1 the parent cancel does not mark the run cancelled")
        t.checkEqual(afterParent.snapshot.storyboardRuns[0].state(of: runs[0].orderedShots[0].id)?.dispatchedRequestID,
                     request, "RUNCANCEL_1 and leaves the in-flight shot as it was")

        // RUNCANCEL_2 — what the scheduler's cancel leaves.
        var run = try! StoryboardRunSubmission.makeJob(
            project: project("storyboard"), workCount: 1, directorMode: "direct").snapshot.storyboardRuns[0]
        schedulerCancelled(&run, staleRequest: UUID())
        let s = run.orderedShots.map(\.id)
        t.check(run.isCancelled, "RUNCANCEL_2 the run is marked cancelled")
        t.checkEqual(run.shotStates.map(\.state), [.completed, .running, .cancelled],
                     "RUNCANCEL_2 done kept, rendering left to the backend, unstarted cancelled")
        t.checkEqual(StoryboardRunScheduler.next(run), .cancelled, "RUNCANCEL_2 the scheduler starts nothing")
        t.checkEqual(run.state(of: s[2])?.dependency?.upstreamShotID, s[1], "RUNCANCEL_2 fixture: shot 3 continues shot 2")
    }

    // MARK: Retry of a scheduler-cancelled run

    func checkRetried<Run: RunScopedShotExecution>(
        _ label: String, original: Run, retried: Run, seeds: [Int]
    ) {
        let s = original.orderedShots.map(\.id)
        t.check(!retried.isCancelled, "RUNCANCEL_5 \(label): Retry reopens the cancelled run")
        t.checkEqual(retried.state(of: s[0])?.state, .completed, "RUNCANCEL_4 \(label): the completed shot stays completed")
        t.checkEqual(retried.state(of: s[0])?.attemptNumber, 1, "RUNCANCEL_4 \(label): at attempt 1")
        t.checkEqual(retried.state(of: s[0])?.takeID, original.state(of: s[0])?.takeID,
                     "RUNCANCEL_4 \(label): with its take")
        t.check(retried.shotStates.allSatisfy { $0.state != .cancelled },
                "RUNCANCEL_5 \(label): no unfinished shot stays cancelled")
        t.check(retried.shotStates.allSatisfy { $0.state != .running && $0.dispatchedRequestID == nil },
                "RUNCANCEL_6 \(label): no stale dispatched request survives")
        t.checkEqual(retried.state(of: s[1])?.attemptNumber, 2,
                     "RUNCANCEL_8 \(label): the stopped render becomes attempt 2")
        t.checkEqual(retried.state(of: s[2])?.attemptNumber, 2,
                     "RUNCANCEL_8 \(label): a cancelled shot is reopened as a new attempt, like a blocked one")
        t.checkEqual(retried.orderedShots.map(\.seed), seeds, "RUNCANCEL_7 \(label): seeds are unchanged")
        t.checkEqual(retried.state(of: s[1])?.dependency?.upstreamShotID, s[0],
                     "RUNCANCEL_9 \(label): shot 2 still continues from shot 1")
        t.checkEqual(retried.state(of: s[2])?.dependency?.upstreamShotID, s[1],
                     "RUNCANCEL_9 \(label): shot 3 still continues from shot 2")
        t.checkEqual(retried.state(of: s[2])?.dependency?.runID, retried.id,
                     "RUNCANCEL_9 \(label): in the same run")
        t.checkEqual(retried.state(of: s[2])?.state, .waitingForDependency,
                     "RUNCANCEL_9 \(label): shot 3 waits for its upstream again")
        t.checkEqual(StoryboardRunScheduler.next(retried), .render(shotID: s[1]),
                     "UNUSED_CANCEL_RED RUNCANCEL_3 \(label): the next shot is dispatchable after Retry")
    }

    t.suite("Run cancel — Retry of a scheduler-cancelled Storyboard run") {
        let q = coordinator("sb")
        let job = q.enqueue(try! StoryboardRunSubmission.makeJob(
            project: project("storyboard"), workCount: 2, directorMode: "direct"))
        var runs = q.job(id: job.id)!.snapshot.storyboardRuns
        let seeds = runs[0].orderedShots.map(\.seed)
        let stale = UUID()
        schedulerCancelled(&runs[0], staleRequest: stale)
        q.updateStoryboardRuns(jobID: job.id, runs: runs)
        q.cancel(jobID: job.id)

        guard let retried = q.retry(jobID: job.id) else {
            t.check(false, "RUNCANCEL_3 Retry produced a job"); return
        }
        let newRuns = retried.snapshot.storyboardRuns
        checkRetried("Storyboard", original: runs[0], retried: newRuns[0], seeds: seeds)
        t.checkEqual(newRuns[1], runs[1], "RUNCANCEL_4 the untouched sibling work is carried over as it was")

        // RUNCANCEL_12 — the stopped render's late settlement reaches neither job.
        let late = RunOutcomeRecord(runID: stale, outcome: .completed, attemptNumber: 1, outputPath: "/tmp/late.mp4")
        t.check(StoryboardRunDriver.applySettlement(late, to: newRuns) == nil,
                "RUNCANCEL_12 the old attempt's settlement applies to no shot of the new attempt")
        q.recordSettlement(late)
        t.checkEqual(q.job(id: retried.id)?.snapshot.storyboardRuns, newRuns,
                     "RUNCANCEL_12 and the new job's runs are unchanged by it")
        t.checkEqual(q.job(id: job.id)?.state, .cancelled, "RUNCANCEL_12 the original stays cancelled")

        // RUNCANCEL_15 — cancelled jobs stay hidden, whatever their runs hold.
        t.check(q.job(id: job.id)?.staysVisibleWhenTerminal == false,
                "RUNCANCEL_15 the cancelled job is still not shown")

        // Restart of an interrupted job reads the same snapshot Retry does.
        var interrupted = ProductionJob(kind: .storyboard, title: "i", snapshot: q.job(id: job.id)!.snapshot)
        interrupted.state = .interrupted
        var onlyCancelled = interrupted
        onlyCancelled.snapshot.storyboardRuns = [runs[0]]
        t.check(onlyCancelled.restartWouldDoWork,
                "RUNCANCEL_5 Restart counts a cancelled run's unfinished shots as work")
    }

    t.suite("Run cancel — Retry of a scheduler-cancelled Auto Movie run") {
        let q = coordinator("movie")
        let job = q.enqueue(try! MovieRunSubmission.makeJob(
            project: project("hybrid"), workCount: 1, directorMode: "direct"))
        var runs = q.job(id: job.id)!.snapshot.movieRuns
        let seeds = runs[0].orderedShots.map(\.seed)
        schedulerCancelled(&runs[0], staleRequest: UUID())
        q.updateMovieRuns(jobID: job.id, runs: runs)
        q.cancel(jobID: job.id)

        guard let retried = q.retry(jobID: job.id) else {
            t.check(false, "RUNCANCEL_10 Retry produced a job"); return
        }
        let run = retried.snapshot.movieRuns[0]
        checkRetried("Auto Movie", original: runs[0], retried: run, seeds: seeds)
        t.checkEqual(run.assembly.state, .waiting, "RUNCANCEL_11 the assembly waits for its shots")
        t.checkEqual(run.assembly.attemptNumber, 1, "RUNCANCEL_11 with no new assembly attempt")
        t.check(!run.isSettled, "RUNCANCEL_10 the reopened movie run is not settled")

        // RUNCANCEL_11 — completed films are never reopened.
        var done = runs[0]
        for shot in done.orderedShots { done.update(shot.id) { $0.state = .completed } }
        done.assembly.state = .completed
        done.assembly.outputPath = "/tmp/film.mp4"
        StoryboardRunScheduler.cancel(&done)
        let q2 = coordinator("movie-done")
        let job2 = q2.enqueue(try! MovieRunSubmission.makeJob(
            project: project("hybrid"), workCount: 1, directorMode: "direct"))
        q2.updateMovieRuns(jobID: job2.id, runs: [done])
        q2.cancel(jobID: job2.id)
        if let again = q2.retry(jobID: job2.id)?.snapshot.movieRuns[0] {
            t.checkEqual(again.assembly.state, .completed, "RUNCANCEL_11 a completed film stays completed")
            t.checkEqual(again.assembly.attemptNumber, 1, "RUNCANCEL_11 at attempt 1")
            t.checkEqual(again.assembly.outputPath, "/tmp/film.mp4", "RUNCANCEL_11 with its output")
        } else {
            t.check(false, "RUNCANCEL_11 Retry produced a job")
        }

        // RUNCANCEL_11 — a `.cancelled` assembly is a fresh assembly attempt.
        var asm = runs[0]
        asm.isCancelled = false
        for shot in asm.orderedShots { asm.update(shot.id) { $0.state = .completed; $0.dispatchedRequestID = nil } }
        asm.assembly.state = .cancelled
        MovieAssemblyDriver.retryAssembly(in: &asm)
        t.checkEqual(asm.assembly.state, .waiting, "RUNCANCEL_11 a cancelled assembly can be assembled again")
        t.checkEqual(asm.assembly.attemptNumber, 2, "RUNCANCEL_11 as attempt 2")
    }

    // MARK: Through the production queue

    t.suite("Run cancel — the production queue after Retry") {
        MainActor.assumeIsolated {
            final class Calls { var ensure = 0 }
            @MainActor func harness(_ calls: Calls) -> (ProductionQueueService, ProductionQueueCoordinator, GenerationService) {
                let c = ProductionQueueCoordinator(
                    store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(UUID()).json")),
                    restoreOnInit: false)
                let queue = ProductionQueueService(coordinator: c)
                let service = GenerationService(historyManager: HistoryManager(
                    rootDirectory: root.appendingPathComponent(UUID().uuidString)))
                service.preflight = GenerationPreflight(
                    pythonPath: { "/scratch/python" },
                    ensurePythonReady: { _ in
                        calls.ensure += 1
                        return (false, "Python environment is missing mlx.", nil)
                    },
                    configurePython: { _ in },
                    loadModel: { _ in true },
                    storage: { _, _ in .healthy(availableBytes: 1 << 40) })
                queue.attach(generationService: service)
                queue.assembleOverride = { _, _, output, _ in
                    FileManager.default.createFile(atPath: output, contents: Data("film".utf8))
                }
                return (queue, c, service)
            }
            /// Only waits: clearing the renderer here would also drop the
            /// request of a job that started behind this one.
            @MainActor func settle(_ c: ProductionQueueCoordinator, _ id: UUID, _ service: GenerationService) -> Bool {
                spin { c.job(id: id)?.state.isTerminal == true }
            }

            // STORYBOARD_CANCEL_RETRY / RUNCANCEL_13 / _14 — one work, shot 1
            // done, shot 2 cancelled by the scheduler, and a job queued behind.
            do {
                let calls = Calls()
                let (queue, c, service) = harness(calls)
                var job = try! StoryboardRunSubmission.makeJob(
                    project: project("storyboard", continuing: false, shots: 2), workCount: 1, directorMode: "direct")
                StoryboardRunScheduler.recordCompletion(
                    in: &job.snapshot.storyboardRuns[0], shotID: job.snapshot.storyboardRuns[0].orderedShots[0].id,
                    takeID: UUID(), outputPath: clip("sb-0"))
                StoryboardRunScheduler.cancel(&job.snapshot.storyboardRuns[0])
                let first = queue.enqueue(job)
                let behind = queue.enqueue(try! StoryboardRunSubmission.makeJob(
                    project: project("storyboard", continuing: false, shots: 1), workCount: 1, directorMode: "direct"))
                t.check(settle(c, first.id, service), "RUNCANCEL_14 a job holding only a cancelled run ends rather than hanging")
                t.check(settle(c, behind.id, service), "RUNCANCEL_13 the job behind it runs")
                let before = calls.ensure
                t.checkEqual(before, 1, "RUNCANCEL_13 the job behind it is the only one that rendered")

                guard let retried = c.retry(jobID: first.id) else {
                    t.check(false, "STORYBOARD_CANCEL_RETRY Retry produced a job"); return
                }
                t.check(settle(c, retried.id, service), "NO_PROGRESS_GUARD the retried Storyboard reaches a terminal state")
                t.checkEqual(calls.ensure, before + 1,
                             "UNUSED_CANCEL_RED STORYBOARD_CANCEL_RETRY Retry renders the cancelled shot")
                let shots = c.job(id: retried.id)?.snapshot.storyboardRuns[0].shotStates ?? []
                t.checkEqual(shots.first?.state, .completed, "STORYBOARD_CANCEL_RETRY the finished shot was not re-rendered")
                t.check(shots.allSatisfy { $0.state != .running && $0.dispatchedRequestID == nil },
                        "NO_PROGRESS_GUARD nothing is left waiting on a request")
            }

            // AUTOMOVIE_CANCEL_RETRY — the same for a movie, cancelled before
            // any shot ran. (A movie's later shots continue from a real frame of
            // the one before, which a stand-in clip cannot supply.)
            do {
                let calls = Calls()
                let (queue, c, service) = harness(calls)
                var job = try! MovieRunSubmission.makeJob(
                    project: project("hybrid", continuing: false, shots: 2), workCount: 1, directorMode: "direct")
                StoryboardRunScheduler.cancel(&job.snapshot.movieRuns[0])
                let first = queue.enqueue(job)
                t.check(settle(c, first.id, service), "RUNCANCEL_14 a movie holding only a cancelled run ends")
                guard let retried = c.retry(jobID: first.id) else {
                    t.check(false, "AUTOMOVIE_CANCEL_RETRY Retry produced a job"); return
                }
                t.check(settle(c, retried.id, service), "NO_PROGRESS_GUARD the retried movie reaches a terminal state")
                t.checkEqual(calls.ensure, 1, "UNUSED_CANCEL_RED AUTOMOVIE_CANCEL_RETRY Retry renders the cancelled shot")
                t.check(c.job(id: retried.id)?.snapshot.movieRuns[0].shotStates.allSatisfy { $0.state != .cancelled } == true,
                        "AUTOMOVIE_CANCEL_RETRY no shot of the retried movie is left cancelled")
            }

            // AUTOMOVIE_CANCEL_RETRY / RUNCANCEL_11 / _16 — every shot rendered,
            // the run cancelled before its film was assembled.
            do {
                let calls = Calls()
                let (queue, c, service) = harness(calls)
                var job = try! MovieRunSubmission.makeJob(
                    project: project("hybrid", continuing: false, shots: 2), workCount: 1, directorMode: "direct")
                for (i, shot) in job.snapshot.movieRuns[0].orderedShots.enumerated() {
                    StoryboardRunScheduler.recordCompletion(
                        in: &job.snapshot.movieRuns[0], shotID: shot.id, takeID: UUID(), outputPath: clip("asm-\(i)"))
                }
                StoryboardRunScheduler.cancel(&job.snapshot.movieRuns[0])
                let first = queue.enqueue(job)
                t.check(settle(c, first.id, service), "RUNCANCEL_14 ends")
                guard let retried = c.retry(jobID: first.id) else {
                    t.check(false, "AUTOMOVIE_CANCEL_RETRY Retry produced a job"); return
                }
                t.check(settle(c, retried.id, service), "NO_PROGRESS_GUARD the retried movie reaches a terminal state")
                t.checkEqual(c.job(id: retried.id)?.state, .completed,
                             "UNUSED_CANCEL_RED AUTOMOVIE_CANCEL_RETRY Retry assembles the cancelled work's film")
                t.checkEqual(calls.ensure, 0, "RUNCANCEL_4 without re-rendering a shot")
                t.check(queue.assemblyAttempts.isEmpty, "RUNCANCEL_16 no assembly attempt is left registered")
            }

            // RUNCANCEL_11 / _14 — an assembly left `.cancelled` on a live run.
            do {
                let calls = Calls()
                let (queue, c, service) = harness(calls)
                var job = try! MovieRunSubmission.makeJob(
                    project: project("hybrid", continuing: false, shots: 1), workCount: 1, directorMode: "direct")
                let shot = job.snapshot.movieRuns[0].orderedShots[0]
                StoryboardRunScheduler.recordCompletion(
                    in: &job.snapshot.movieRuns[0], shotID: shot.id, takeID: UUID(), outputPath: clip("asmc-0"))
                _ = MovieAssemblyDriver.freezeClips(in: &job.snapshot.movieRuns[0])
                job.snapshot.movieRuns[0].assembly.state = .cancelled
                let first = queue.enqueue(job)
                t.check(settle(c, first.id, service), "RUNCANCEL_14 a cancelled assembly with nothing to run ends")
                t.checkEqual(c.job(id: first.id)?.state, .failed, "RUNCANCEL_14 as failed, not stuck running")
                guard let retried = c.retry(jobID: first.id) else {
                    t.check(false, "RUNCANCEL_11 Retry produced a job"); return
                }
                t.check(settle(c, retried.id, service), "NO_PROGRESS_GUARD reaches a terminal state")
                t.checkEqual(c.job(id: retried.id)?.state, .completed,
                             "UNUSED_CANCEL_RED RUNCANCEL_11 Retry assembles a cancelled assembly again")
                t.checkEqual(c.job(id: retried.id)?.snapshot.movieRuns[0].assembly.attemptNumber, 2,
                             "RUNCANCEL_11 as assembly attempt 2")
            }
        }
    }
}
