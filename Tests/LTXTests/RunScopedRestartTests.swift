import Foundation
@testable import LTXVideoGeneratorCore

/// Restarting (or retrying) a run-scoped Storyboard or Auto Movie job must give
/// the scheduler something it can actually dispatch.
///
/// Job-level `retry(jobID:)` copies the snapshot verbatim. For run-scoped jobs
/// that copies each shot's execution state too — including a shot that was
/// `running` with a `dispatchedRequestID` when the app quit, or one that
/// `failed`. `nextDispatch` refuses to dispatch while any attempt is in flight
/// and never re-dispatches a failed shot on its own, and the run-scoped
/// starters return `.started` when there is nothing to dispatch. The restarted
/// job would therefore sit "running" with nothing running — and, because the
/// queue runs one job at a time, hold every job behind it.
///
/// `StoryboardRunScheduler.retry(in:shotID:)` and
/// `MovieAssemblyDriver.retryAssembly(in:)` were written for exactly this and
/// had no callers.
func runRunScopedRestartTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunRestart-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    func project(_ mode: String) -> FilmProject {
        var p = FilmProject(title: "Restart \(mode)")
        p.workflowMode = mode
        p.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        p.shots[1].continuityMode = .cut
        return p
    }

    /// Enqueues `job` as the running job, lets `mutate` shape its persisted
    /// run state, then relaunches the queue from disk.
    func relaunch(
        _ job: ProductionJob, name: String,
        mutate: (ProductionQueueCoordinator, ProductionJob) -> Void
    ) -> (ProductionQueueCoordinator, ProductionJob) {
        let store = ProductionQueueStore(fileURL: root.appendingPathComponent("\(name).json"))
        let before = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        before.runner = { _ in .started }
        let running = before.enqueue(job)
        mutate(before, before.job(id: running.id)!)
        store.flush()
        let after = ProductionQueueCoordinator(store: store, restoreOnInit: true)
        return (after, after.job(id: running.id)!)
    }

    t.suite("Run-scoped Restart — an interrupted Storyboard resumes") {
        let job = try! StoryboardRunSubmission.makeJob(
            project: project("storyboard"), workCount: 1, directorMode: "direct")
        let seeds = job.snapshot.storyboardRuns[0].orderedShots.map(\.seed)
        let (queue, interrupted) = relaunch(job, name: "sb-interrupted") { c, j in
            var runs = j.snapshot.storyboardRuns
            let first = runs[0].orderedShots[0].id
            runs[0].update(first) {
                $0.state = .running
                $0.dispatchedRequestID = UUID()
                $0.dispatchedTakeID = UUID()
            }
            c.updateStoryboardRuns(jobID: j.id, runs: runs)
        }

        t.checkEqual(interrupted.state, .interrupted,
                     "RESTART_SB_1 fixture: a job running at quit restores as interrupted")
        t.check(interrupted.canRestart, "RESTART_SB_1 fixture: and offers Restart")

        guard let restarted = queue.retry(jobID: interrupted.id) else {
            t.check(false, "RESTART_SB_2 Restart produced a job"); return
        }
        let runs = restarted.snapshot.storyboardRuns
        t.check(StoryboardRunDriver.nextDispatch(in: runs) != nil,
                "RESTART_SB_2 the restarted job has a dispatchable shot")
        let first = runs[0].orderedShots[0].id
        t.checkEqual(runs[0].state(of: first)?.state, .queued,
                     "RESTART_SB_3 the shot that was mid-render is queued again")
        t.checkEqual(runs[0].state(of: first)?.dispatchedRequestID, nil,
                     "RESTART_SB_3 with no stale in-flight request to wait on")
        t.checkEqual(runs[0].state(of: first)?.attemptNumber, 2,
                     "RESTART_SB_4 as a new attempt, so a late settlement for the old one is ignored")
        t.checkEqual(runs[0].orderedShots.map(\.seed), seeds,
                     "RESTART_SB_5 frozen seeds are untouched — Restart is not Retake")
        let untouched = runs[0].orderedShots[1].id
        t.checkEqual(runs[0].state(of: untouched)?.attemptNumber, 1,
                     "RESTART_SB_6 a shot that never ran keeps its attempt number")
        t.checkEqual(queue.job(id: interrupted.id)?.state, .interrupted,
                     "RESTART_SB_7 the original record is left as it was")
    }

    t.suite("Run-scoped Retry — a failed Storyboard resumes its failed shot") {
        let job = try! StoryboardRunSubmission.makeJob(
            project: project("storyboard"), workCount: 1, directorMode: "direct")
        let (queue, restored) = relaunch(job, name: "sb-failed") { c, j in
            var runs = j.snapshot.storyboardRuns
            let ordered = runs[0].orderedShots
            runs[0].update(ordered[0].id) { $0.state = .completed; $0.outputPath = "/tmp/a.mp4" }
            runs[0].update(ordered[1].id) {
                $0.state = .failed
                $0.failureReason = "backend failed"
            }
            c.updateStoryboardRuns(jobID: j.id, runs: runs)
            c.markFailed(jobID: j.id, reason: "One or more works did not finish.")
        }
        t.checkEqual(restored.state, .failed, "RETRY_SB_1 fixture: failed job")

        guard let retried = queue.retry(jobID: restored.id) else {
            t.check(false, "RETRY_SB_2 Retry produced a job"); return
        }
        let runs = retried.snapshot.storyboardRuns
        let ordered = runs[0].orderedShots
        t.check(StoryboardRunDriver.nextDispatch(in: runs)?.shotID == ordered[1].id,
                "RETRY_SB_2 the failed shot is what gets dispatched")
        t.checkEqual(runs[0].state(of: ordered[0].id)?.state, .completed,
                     "RETRY_SB_3 a completed shot is not rendered again")
        t.checkEqual(runs[0].state(of: ordered[0].id)?.outputPath, "/tmp/a.mp4",
                     "RETRY_SB_3 and keeps its output")
        t.checkEqual(runs[0].state(of: ordered[1].id)?.failureReason, nil,
                     "RETRY_SB_4 the old failure reason does not carry into the new attempt")
    }

    t.suite("Run-scoped Restart — an interrupted Auto Movie resumes") {
        let job = try! MovieRunSubmission.makeJob(
            project: project("hybrid"), workCount: 2, directorMode: "direct")
        let (queue, interrupted) = relaunch(job, name: "movie-interrupted") { c, j in
            var runs = j.snapshot.movieRuns
            let first = runs[0].orderedShots[0].id
            runs[0].update(first) {
                $0.state = .running
                $0.dispatchedRequestID = UUID()
            }
            c.updateMovieRuns(jobID: j.id, runs: runs)
        }
        t.checkEqual(interrupted.state, .interrupted, "RESTART_MOVIE_1 fixture: interrupted")

        guard let restarted = queue.retry(jobID: interrupted.id) else {
            t.check(false, "RESTART_MOVIE_2 Restart produced a job"); return
        }
        let runs = restarted.snapshot.movieRuns
        t.check(StoryboardRunDriver.nextDispatch(in: runs) != nil,
                "RESTART_MOVIE_2 the restarted movie has a dispatchable shot")
        t.checkEqual(runs[1].shotStates.map(\.attemptNumber), [1, 1],
                     "RESTART_MOVIE_3 the other work, which never started, is untouched")
    }

    t.suite("Run-scoped Retry — a movie whose assembly failed re-assembles") {
        let job = try! MovieRunSubmission.makeJob(
            project: project("hybrid"), workCount: 1, directorMode: "direct")
        let (queue, restored) = relaunch(job, name: "movie-asm-failed") { c, j in
            var runs = j.snapshot.movieRuns
            for shot in runs[0].orderedShots {
                runs[0].update(shot.id) { $0.state = .completed; $0.outputPath = "/tmp/\(shot.index).mp4" }
            }
            runs[0].assembly.state = .failed
            runs[0].assembly.failureReason = "ffmpeg failed"
            c.updateMovieRuns(jobID: j.id, runs: runs)
            c.markFailed(jobID: j.id, reason: "ffmpeg failed")
        }
        guard let retried = queue.retry(jobID: restored.id) else {
            t.check(false, "RETRY_ASM_1 Retry produced a job"); return
        }
        let run = retried.snapshot.movieRuns[0]
        t.check(run.assembly.state == .waiting || run.assembly.state == .ready,
                "RETRY_ASM_1 the failed assembly is eligible to run again")
        t.checkEqual(run.assembly.attemptNumber, 2, "RETRY_ASM_2 as a new assembly attempt")
        t.check(run.shotStates.allSatisfy { $0.state == .completed && $0.attemptNumber == 1 },
                "RETRY_ASM_3 without re-rendering any shot")
    }

    try? FileManager.default.removeItem(at: root)
}
