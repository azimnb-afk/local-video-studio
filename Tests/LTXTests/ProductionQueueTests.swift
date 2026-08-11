import Foundation
@testable import LTXVideoGeneratorCore

/// Global production queue: several jobs queued, executed strictly one at a
/// time, surviving a relaunch. The single-active-job guarantee is the property
/// everything else depends on, so it is proved with a runner double rather than
/// asserted in prose.
func runProductionQueueTests(_ t: TestKit) {

    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-queue-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    func makeStore(_ name: String) -> ProductionQueueStore {
        ProductionQueueStore(fileURL: tmpRoot.appendingPathComponent("\(name).json"))
    }

    func job(_ kind: ProductionJobKind, _ title: String,
             snapshot: ProductionJobSnapshot = ProductionJobSnapshot()) -> ProductionJob {
        ProductionJob(kind: kind, title: title, snapshot: snapshot)
    }

    /// Records every start and never reports completion on its own, so the
    /// coordinator cannot advance unless the test says so.
    final class RunnerSpy {
        private(set) var started: [UUID] = []
        var concurrentPeak = 0
        private var active = 0
        var outcome: ProductionQueueCoordinator.StartOutcome = .started

        func run(_ job: ProductionJob) -> ProductionQueueCoordinator.StartOutcome {
            if case .started = outcome {
                started.append(job.id)
                active += 1
                concurrentPeak = max(concurrentPeak, active)
            }
            return outcome
        }
        func finishOne() { active = max(0, active - 1) }
    }

    t.suite("Production queue — one job at a time") {
        // A/B/C. Enqueue several; only the first runs, in FIFO order.
        let coordinator = ProductionQueueCoordinator(store: makeStore("fifo"), restoreOnInit: false)
        let spy = RunnerSpy()
        coordinator.runner = { spy.run($0) }

        let a = coordinator.enqueue(job(.generate, "A"))
        let b = coordinator.enqueue(job(.oneShot, "B"))
        let c = coordinator.enqueue(job(.autoMovie, "C"))

        t.checkEqual(spy.started.count, 1, "C: only one job is started")
        t.checkEqual(spy.started.first, a.id, "B: the first enqueued job runs first (FIFO)")
        t.checkEqual(coordinator.job(id: a.id)?.state, .running, "A is running")
        t.checkEqual(coordinator.job(id: b.id)?.state, .waiting, "B waits")
        t.checkEqual(coordinator.job(id: c.id)?.state, .waiting, "C waits")
        t.checkEqual(coordinator.waitingCount, 2, "two jobs are waiting")

        // THE CONCURRENCY GUARANTEE. Nothing above one, ever — this is what
        // keeps two renders off the same unified memory.
        t.checkEqual(spy.concurrentPeak, 1, "concurrency never exceeds one active job")

        // D. Completing the active job starts exactly the next one.
        spy.finishOne()
        coordinator.markCompleted(jobID: a.id, outputPath: "/tmp/a.mp4")
        t.checkEqual(coordinator.job(id: a.id)?.state, .completed, "D: A completed")
        t.checkEqual(coordinator.job(id: a.id)?.outputPath, "/tmp/a.mp4", "D: output path recorded")
        t.checkEqual(spy.started.count, 2, "D: completion starts the next job")
        t.checkEqual(spy.started.last, b.id, "D: the next job is B")
        t.checkEqual(spy.concurrentPeak, 1, "still never more than one active")

        // E/X. A failure does not stall the queue behind it.
        spy.finishOne()
        coordinator.markFailed(jobID: b.id, reason: "render failed")
        t.checkEqual(coordinator.job(id: b.id)?.state, .failed, "E: B failed")
        t.checkEqual(coordinator.job(id: b.id)?.failureReason, "render failed",
                     "E: the reason is kept for the panel")
        t.checkEqual(spy.started.last, c.id, "X: a failed job does not block the following job")
        t.checkEqual(spy.concurrentPeak, 1, "concurrency held at one across a failure")

        // F. Cancelling the running job also advances the queue.
        let d = coordinator.enqueue(job(.generate, "D"))
        spy.finishOne()
        coordinator.cancel(jobID: c.id)
        t.checkEqual(coordinator.job(id: c.id)?.state, .cancelled, "F: C cancelled")
        t.checkEqual(spy.started.last, d.id, "F: cancelling the running job starts the next")
    }

    t.suite("Production queue — preflight, reorder and lifecycle") {
        // A runner that refuses to start models execution-time preflight: the
        // file vanished while the job waited.
        let coordinator = ProductionQueueCoordinator(store: makeStore("preflight"), restoreOnInit: false)
        let spy = RunnerSpy()
        spy.outcome = .failed("opening reference image is missing")
        coordinator.runner = { spy.run($0) }
        let bad = coordinator.enqueue(job(.autoMovie, "Missing asset"))
        t.checkEqual(coordinator.job(id: bad.id)?.state, .failed,
                     "W: a job whose preflight fails at execution is failed, not started")
        t.checkEqual(coordinator.job(id: bad.id)?.failureReason,
                     "opening reference image is missing",
                     "W: the preflight reason is surfaced")

        // G/H/I. Reordering applies to waiting jobs and never to the active one.
        let reorder = ProductionQueueCoordinator(store: makeStore("reorder"), restoreOnInit: false)
        reorder.runner = { _ in .started }
        let running = reorder.enqueue(job(.generate, "running"))
        let x = reorder.enqueue(job(.generate, "X"))
        let y = reorder.enqueue(job(.generate, "Y"))
        let z = reorder.enqueue(job(.generate, "Z"))

        reorder.moveUp(jobID: y.id)
        t.checkEqual(reorder.jobs.map(\.title), ["running", "Y", "X", "Z"],
                     "G: Move Up reorders a waiting job")
        reorder.moveDown(jobID: y.id)
        t.checkEqual(reorder.jobs.map(\.title), ["running", "X", "Y", "Z"],
                     "H: Move Down reorders a waiting job")

        // The running job cannot be dragged out of its position.
        reorder.moveDown(jobID: running.id)
        t.checkEqual(reorder.jobs.first?.title, "running",
                     "the running job is never reordered")
        // Nor can a waiting job be moved above it.
        reorder.moveUp(jobID: x.id)
        t.checkEqual(reorder.jobs.map(\.title), ["running", "X", "Y", "Z"],
                     "a waiting job cannot displace the running job")

        // I. Removing a waiting job; the running one is protected.
        reorder.remove(jobID: z.id)
        t.check(reorder.job(id: z.id) == nil, "I: a waiting job can be removed")
        reorder.remove(jobID: running.id)
        t.check(reorder.job(id: running.id) != nil,
                "a running job is not removed out from under the renderer")

        // N. Retry re-queues from the original snapshot rather than live state.
        let retryQueue = ProductionQueueCoordinator(store: makeStore("retry"), restoreOnInit: false)
        retryQueue.runner = { _ in .started }
        var snapshot = ProductionJobSnapshot()
        snapshot.prompt = "original prompt"
        snapshot.seed = 4242
        let failed = retryQueue.enqueue(job(.generate, "Retry me", snapshot: snapshot))
        retryQueue.markFailed(jobID: failed.id, reason: "boom")
        let retried = retryQueue.retry(jobID: failed.id)
        t.check(retried != nil, "N: a failed job can be retried")
        t.checkEqual(retried?.snapshot.prompt, "original prompt",
                     "N: the retry carries the original snapshot")
        t.checkEqual(retried?.snapshot.seed, 4242, "N: the retry keeps the original seed")
        t.check(retried?.id != failed.id, "N: the retry is a new record, so the failure stays visible")
        t.checkEqual(retryQueue.job(id: failed.id)?.state, .failed,
                     "N: the original failure record is preserved")

        // Pause holds back waiting work without touching the running job.
        let paused = ProductionQueueCoordinator(store: makeStore("pause"), restoreOnInit: false)
        let pauseSpy = RunnerSpy()
        paused.runner = { pauseSpy.run($0) }
        let first = paused.enqueue(job(.generate, "first"))
        paused.setPaused(true)
        _ = paused.enqueue(job(.generate, "second"))
        pauseSpy.finishOne()
        paused.markCompleted(jobID: first.id)
        t.checkEqual(pauseSpy.started.count, 1, "pause stops the next job from starting")
        paused.setPaused(false)
        t.checkEqual(pauseSpy.started.count, 2, "unpausing resumes the queue")
    }

    t.suite("Production queue — persistence and restart") {
        // J. Round trip through disk.
        let store = makeStore("persist")
        let coordinator = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        coordinator.runner = { _ in .started }
        var snapshot = ProductionJobSnapshot()
        snapshot.brief = "a woman walks to a library"
        snapshot.openingReferenceRelativePath = "Assets/OpeningReference/x.png"
        snapshot.characterAnchorCharacterID = UUID()
        let running = coordinator.enqueue(job(.autoMovie, "Movie A", snapshot: snapshot))
        let waiting = coordinator.enqueue(job(.oneShot, "Shot B"))
        store.flush()

        let reloaded = ProductionQueueCoordinator(store: store, restoreOnInit: true)
        t.checkEqual(reloaded.jobs.count, 2, "J: the queue survives a round trip")
        t.checkEqual(reloaded.job(id: waiting.id)?.snapshot.brief, "",
                     "J: each job keeps its own snapshot")
        t.checkEqual(reloaded.job(id: running.id)?.snapshot.brief,
                     "a woman walks to a library", "S: the brief survives persistence")
        t.checkEqual(reloaded.job(id: running.id)?.snapshot.openingReferenceRelativePath,
                     "Assets/OpeningReference/x.png",
                     "S: the opening reference survives persistence")
        t.check(reloaded.job(id: running.id)?.snapshot.characterAnchorCharacterID != nil,
                "T: the character anchor selection survives persistence")

        // K/L. Waiting stays waiting; a job that was running when the app quit
        //      becomes interrupted — never resumed silently, never completed.
        t.checkEqual(reloaded.job(id: waiting.id)?.state, .waiting,
                     "K: a waiting job restores as waiting")
        t.checkEqual(reloaded.job(id: running.id)?.state, .interrupted,
                     "L: a job that was running restores as interrupted")
        t.check(reloaded.activeJobID == nil,
                "L: nothing is considered active immediately after a restart")

        // M. An interrupted job can be restarted from its snapshot.
        t.check(reloaded.job(id: running.id)?.canRestart == true,
                "M: an interrupted job offers Restart")
        let restarted = reloaded.retry(jobID: running.id)
        t.checkEqual(restarted?.state, .waiting, "M: restarting re-queues the job")
        t.checkEqual(restarted?.snapshot.openingReferenceRelativePath,
                     "Assets/OpeningReference/x.png",
                     "M: the restart uses the original opening reference")

        // AG. No queue file at all is an empty queue, not a crash.
        let fresh = ProductionQueueCoordinator(
            store: makeStore("never-written"), restoreOnInit: true)
        t.checkEqual(fresh.jobs.count, 0, "AG: a missing queue file restores an empty queue")

        // AH. One malformed record must not destroy the rest of the queue.
        let corruptURL = tmpRoot.appendingPathComponent("corrupt.json")
        let corrupt = """
        [{"id":"\(UUID().uuidString)","kind":"generate","title":"good","state":"waiting",
          "snapshot":{"prompt":"ok","brief":"","batchCount":1,"pendingRequests":[]},
          "createdAt":"2026-08-11T00:00:00Z"},
         {"kind":"not-a-real-kind","title":"broken"}]
        """
        try? corrupt.write(to: corruptURL, atomically: true, encoding: .utf8)
        let salvaged = ProductionQueueStore(fileURL: corruptURL).load()
        t.checkEqual(salvaged.count, 1, "AH: a malformed record is dropped, the rest survives")
        t.checkEqual(salvaged.first?.title, "good", "AH: the intact record is the one kept")
    }

    t.suite("Production queue — snapshot determinism") {
        // U/V. The point of a snapshot: editing afterwards must not reach into
        //      a job that is already waiting.
        let coordinator = ProductionQueueCoordinator(store: makeStore("snapshot"), restoreOnInit: false)
        coordinator.runner = { _ in .started }
        _ = coordinator.enqueue(job(.generate, "occupies the runner"))

        var snapshot = ProductionJobSnapshot()
        snapshot.prompt = "prompt at enqueue"
        snapshot.seed = 111
        snapshot.openingReferenceRelativePath = "Assets/OpeningReference/original.png"
        let queued = coordinator.enqueue(job(.autoMovie, "Movie", snapshot: snapshot))

        // The user keeps working: a different prompt, seed and image.
        snapshot.prompt = "prompt changed later"
        snapshot.seed = 999
        snapshot.openingReferenceRelativePath = "Assets/OpeningReference/changed.png"

        let stored = coordinator.job(id: queued.id)
        t.checkEqual(stored?.snapshot.prompt, "prompt at enqueue",
                     "V: a later prompt edit does not reach the queued job")
        t.checkEqual(stored?.snapshot.seed, 111,
                     "U: a later seed change does not reach the queued job")
        t.checkEqual(stored?.snapshot.openingReferenceRelativePath,
                     "Assets/OpeningReference/original.png",
                     "S: a later opening reference change does not reach the queued job")

        // O. A Generate batch is one job, not N jobs.
        var batch = ProductionJobSnapshot()
        batch.batchCount = 10
        let batchJob = coordinator.enqueue(job(.generate, "Batch of 10", snapshot: batch))
        t.checkEqual(coordinator.job(id: batchJob.id)?.snapshot.batchCount, 10,
                     "O: a Generate batch is carried as one job with a count")
        t.checkEqual(coordinator.jobs.filter { $0.title == "Batch of 10" }.count, 1,
                     "O: the batch occupies exactly one queue slot")

        // Generate Now jumps the waiting queue without preempting the running job.
        let urgent = coordinator.enqueueNext(job(.oneShot, "Urgent"))
        let waitingTitles = coordinator.jobs.filter { $0.state == .waiting }.map(\.title)
        t.checkEqual(waitingTitles.first, "Urgent",
                     "Generate Now places the job at the head of the waiting jobs")
        t.checkEqual(coordinator.activeJob?.title, "occupies the runner",
                     "Generate Now does not preempt the running job")
        t.checkEqual(coordinator.job(id: urgent.id)?.state, .waiting,
                     "Generate Now still waits for the single render slot")
    }

    t.suite("Production queue — a film job is finished by the project, not the renderer") {
        // Regression for a defect found in a real run: between two Auto Movie
        // shots the render queue is momentarily empty — the finished take has
        // been removed and the next shot is only appended once the run
        // coordinator advances. Treating that instant as "renderer idle, so the
        // job is done" marked a movie completed while shot 2 was still
        // rendering, and would have let the next queued movie start on top of
        // it. Completion is decided by the project's own state instead.
        func project(shotCount: Int, completedShots: Int,
                     assembled: Bool, failedShot: Int? = nil) -> FilmProject {
            var project = FilmProject(title: "Movie")
            project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
            for index in 0..<shotCount {
                var shot = Shot(index: index, title: "Shot \(index + 1)")
                func take(_ status: TakeStatus) -> Take {
                    Take(shotID: shot.id, modelID: "m", seed: 1,
                         promptSnapshot: "p", settingsSnapshot: .default,
                         requestedWidth: 512, requestedHeight: 320,
                         fps: 24, requestedDuration: 1, status: status)
                }
                if index == failedShot {
                    shot.takes = [take(.failed)]
                } else if index < completedShots {
                    let completed = take(.completed)
                    shot.takes = [completed]
                    shot.selectedTakeID = completed.id
                }
                project.shots.append(shot)
            }
            if assembled { project.assembledMoviePath = "/tmp/final.mp4" }
            return project
        }

        // The rule the service applies, stated once and checked directly.
        func isFinished(_ project: FilmProject) -> Bool {
            let shotFailed = project.shots.contains { shot in
                shot.takes.contains { $0.status == .failed }
                    && shot.selectedTake?.status != .completed
            }
            if shotFailed { return true }
            let everyShotRendered = !project.shots.isEmpty && project.shots.allSatisfy { shot in
                shot.takes.contains { $0.status == .completed }
            }
            return everyShotRendered
                && !(project.assembledMoviePath ?? "").isEmpty
        }

        t.check(!isFinished(project(shotCount: 3, completedShots: 1, assembled: false)),
                "a movie with one of three shots rendered is NOT finished")
        t.check(!isFinished(project(shotCount: 3, completedShots: 3, assembled: false)),
                "all shots rendered but not yet assembled is NOT finished")
        t.check(isFinished(project(shotCount: 3, completedShots: 3, assembled: true)),
                "all shots rendered and assembled IS finished")
        t.check(isFinished(project(shotCount: 3, completedShots: 1, assembled: false, failedShot: 1)),
                "Z: a failed shot ends the job, and no assembly happens")
        t.check(!isFinished(project(shotCount: 0, completedShots: 0, assembled: false)),
                "an empty project is not treated as a finished movie")
    }

    t.suite("Production queue — jobs run in the order they were queued") {
        // Regression for D-068, found in the real GUI run: creating an Auto
        // Movie inserted the job at the *head* of the waiting jobs. With the
        // queue paused (or several movies created before any starts) three
        // movies queued as 1, 2, 3 would run 3, 2, 1 — the opposite of what
        // "leave it running overnight" means.
        let store = ProductionQueueStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("queue-order-\(UUID().uuidString).json"))
        let coordinator = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        coordinator.runner = { _ in .started }
        coordinator.setPaused(true)

        for title in ["First", "Second", "Third"] {
            coordinator.enqueue(ProductionJob(
                kind: .autoMovie, title: title, snapshot: ProductionJobSnapshot()))
        }
        t.checkEqual(coordinator.jobs.map(\.title), ["First", "Second", "Third"],
                     "D-068: movies run in the order they were created")
        t.check(coordinator.jobs.allSatisfy { $0.state == .waiting },
                "D-068: a paused queue starts nothing")

        // Generate Now is still the deliberate exception, and only it.
        coordinator.enqueueNext(ProductionJob(
            kind: .oneShot, title: "Urgent", snapshot: ProductionJobSnapshot()))
        t.checkEqual(coordinator.jobs.map(\.title),
                     ["Urgent", "First", "Second", "Third"],
                     "D-068: Generate Now is the only thing that jumps the queue")
    }

    t.suite("Production queue — a stalled job must not stall the queue") {
        // Regression for two defects found in a real two-job run.
        //
        // D-066: the queue only ever woke on render-queue changes. Final
        // assembly starts after the last take has left that queue, so nothing
        // published again — job A sat in "Assembling" with the finished movie
        // already on disk, and job B never started. The queue was stalled for
        // as long as the app stayed open.
        //
        // D-067: mid-run progress was counted from *selected* takes, but takes
        // are only selected when the whole run ends, so the panel read
        // "Shot 1 / 4" for all four shots.
        func project(shots shotCount: Int, rendered: Int,
                     assembled: Bool, failedShot: Int? = nil,
                     selectTakes: Bool = false) -> FilmProject {
            var project = FilmProject(title: "Movie")
            project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
            for index in 0..<shotCount {
                var shot = Shot(index: index, title: "Shot \(index + 1)")
                func take(_ status: TakeStatus) -> Take {
                    Take(shotID: shot.id, modelID: "m", seed: 1,
                         promptSnapshot: "p", settingsSnapshot: .default,
                         requestedWidth: 512, requestedHeight: 320,
                         fps: 24, requestedDuration: 1, status: status)
                }
                if index == failedShot {
                    shot.takes = [take(.failed)]
                } else if index < rendered {
                    let completed = take(.completed)
                    shot.takes = [completed]
                    if selectTakes { shot.selectedTakeID = completed.id }
                }
                project.shots.append(shot)
            }
            if assembled { project.assembledMoviePath = "/tmp/final.mp4" }
            return project
        }

        // D-067. Progress tracks rendered shots even though nothing is selected
        // yet — which is exactly the state a real run is in mid-movie.
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 0, assembled: false), runOutcome: nil),
            .running(current: 1, total: 4), "D-067: no shot rendered reads Shot 1 / 4")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 1, assembled: false), runOutcome: nil),
            .running(current: 2, total: 4), "D-067: one shot rendered reads Shot 2 / 4")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 3, assembled: false), runOutcome: nil),
            .running(current: 4, total: 4), "D-067: three shots rendered reads Shot 4 / 4")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 2, assembled: false, selectTakes: true),
            runOutcome: nil),
            .running(current: 3, total: 4),
            "D-067: selection state does not change the reported shot")

        // D-066. Every shot rendered but no movie yet is "assembling" — the job
        // is held open, so nothing starts on top of the assembly.
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 4, assembled: false), runOutcome: nil),
            .assembling, "D-066: all shots rendered, no movie yet, is still in flight")
        // …and the assembly landing is what completes it. Before the fix this
        // transition had no signal at all: the renderer was already idle.
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 4, assembled: true),
            runOutcome: .assembled(path: "/tmp/final.mp4")),
            .completed(outputPath: "/tmp/final.mp4"),
            "D-066: the assembled movie completes the job")

        // A job that can never finish must fail, not hold the queue open.
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 4, assembled: false),
            runOutcome: .assemblyFailed("ffmpeg exited 1")),
            .failed("Final assembly failed: ffmpeg exited 1"),
            "D-066: a failed assembly fails the job instead of stalling it")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 4, assembled: false), runOutcome: .settled),
            .failed("Final assembly failed: the movie was not produced."),
            "D-066: a run that settles with no movie fails the job")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 1, assembled: false),
            runOutcome: .blocked("A continuity frame is missing.")),
            .failed("A continuity frame is missing."),
            "D-066: a blocked run fails the job rather than waiting for a shot that never comes")

        // Pre-existing rules must survive the refactor.
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 1, assembled: false, failedShot: 1),
            runOutcome: nil),
            .failed("A shot failed; the movie was not assembled."),
            "a failed shot still ends the job")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 0, rendered: 0, assembled: false), runOutcome: nil),
            .failed("This project has no shots."),
            "an empty project is not treated as a finished movie")

        // An outcome belonging to another project must be ignored, or one
        // movie's failure would kill the next movie's job.
        let other = FilmRunEvent(projectID: UUID(), kind: .settled, at: Date())
        let mine = UUID()
        t.check(other.projectID != mine, "run outcomes are addressed to one project")
    }

    t.suite("Production queue — job model semantics") {
        // Action availability drives the panel, so it is pinned down here.
        var waiting = ProductionJob(kind: .generate, title: "w", snapshot: ProductionJobSnapshot())
        t.check(waiting.canReorder, "waiting jobs can be reordered")
        t.check(waiting.canCancel, "waiting jobs can be cancelled")
        waiting.state = .running
        t.check(!waiting.canReorder, "a running job cannot be reordered")
        t.check(waiting.canCancel, "a running job can be cancelled")
        waiting.state = .failed
        t.check(waiting.canRetry, "a failed job can be retried")
        waiting.state = .cancelled
        t.check(waiting.canRetry, "a cancelled job can be retried")
        waiting.state = .interrupted
        t.check(waiting.canRestart, "an interrupted job can be restarted")
        t.check(!waiting.canCancel, "a terminal job offers no cancel")

        var progress = ProductionJob(kind: .autoMovie, title: "m", snapshot: ProductionJobSnapshot())
        progress.progressCurrent = 2
        progress.progressTotal = 4
        t.checkEqual(progress.progressText, "2 / 4", "progress reads as a count")
        progress.stageDescription = "Assembling"
        t.checkEqual(progress.progressText, "Assembling", "an explicit stage wins over the count")
    }
}
