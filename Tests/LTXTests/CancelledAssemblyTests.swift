import Foundation
@testable import LTXVideoGeneratorCore

/// A final assembly that finishes after its job was cancelled must not reverse
/// the cancellation.
///
/// Cancelling stops the renderer and marks the job cancelled, but the Auto Movie
/// assembly runs ffmpeg in a detached task with no cancellation handle, so it
/// keeps going. When it returned, the result was written by run index with no
/// check of the job, the run or the attempt, and the job was then settled —
/// turning a cancelled job completed or failed, or, when other works were still
/// unfinished, dispatching them again for a job the user had cancelled.
///
/// The service applies a finished assembly through
/// `ProductionQueueCoordinator.applyAssemblyResult` and settles the job only
/// when that returns true; `deliver` below is that step, as the service runs it.
/// Deterministic: the cancel happens between dispatch and result. No sleeps.
func runCancelledAssemblyTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CancelAsm-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func queue(_ name: String) -> ProductionQueueCoordinator {
        let q = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(name).json")),
            restoreOnInit: false)
        q.runner = { _ in .started }
        return q
    }

    func movieJob(works: Int = 1) -> ProductionJob {
        var p = FilmProject(title: "asm")
        p.workflowMode = "hybrid"
        p.shots = [Shot(index: 0, title: "One", compiledPrompt: "one")]
        return try! MovieRunSubmission.makeJob(project: p, workCount: works, directorMode: "direct")
    }

    /// Every shot rendered and work `i`'s assembly dispatched, as the movie
    /// starter leaves it just before the detached assembly task begins.
    func assembling(_ q: ProductionQueueCoordinator, _ jobID: UUID, works: [Int]) {
        var runs = q.job(id: jobID)!.snapshot.movieRuns
        for i in runs.indices {
            for shot in runs[i].orderedShots {
                runs[i].update(shot.id) { $0.state = .completed; $0.outputPath = "/tmp/clip-\(i).mp4" }
            }
            if works.contains(i) {
                runs[i].assembly.state = .running
                runs[i].assembly.outputPath = "/tmp/final-\(i).mp4"
            }
        }
        q.updateMovieRuns(jobID: jobID, runs: runs)
    }

    /// Jobs the post-assembly step handed back to the movie starter.
    var resumed: [UUID] = []

    /// The service's post-assembly step, as `runAssembly` +
    /// `settleRunScopedMovieIfDone` do it: apply, then — only if applied —
    /// settle a job whose works are all settled, or hand it back to the movie
    /// starter to dispatch what is left.
    @discardableResult
    func deliver(
        _ q: ProductionQueueCoordinator, jobID: UUID, runIndex: Int,
        runID: UUID, attempt: Int, result: ProductionQueueCoordinator.AssemblyResult
    ) -> Bool {
        guard q.applyAssemblyResult(jobID: jobID, runID: runID,
                                    attempt: attempt, result: result) else { return false }
        let runs = q.job(id: jobID)?.snapshot.movieRuns ?? []
        guard runs.allSatisfy({ $0.isSettled }) else {
            resumed.append(jobID)
            return true
        }
        let completed = runs.filter { $0.assembly.state == .completed }
        if completed.count == runs.count {
            q.markCompleted(jobID: jobID, outputPath: completed.first?.assembly.outputPath)
        } else {
            q.markFailed(jobID: jobID, reason: "assembly failed")
        }
        return true
    }

    t.suite("Cancelled assembly — a late result does not reverse the cancel") {
        let q = queue("late-success")
        let job = q.enqueue(movieJob())
        assembling(q, job.id, works: [0])
        let run = q.job(id: job.id)!.snapshot.movieRuns[0]
        let attempt = run.assembly.attemptNumber

        // The user cancels while ffmpeg is still running.
        q.cancel(jobID: job.id)
        t.checkEqual(q.job(id: job.id)?.state, .cancelled, "fixture: the job is cancelled mid-assembly")

        // CANCELASM_2 / _3 — then the assembly finishes successfully.
        deliver(q, jobID: job.id, runIndex: 0, runID: run.id, attempt: attempt,
                result: .completed(outputPath: "/tmp/final-0.mp4"))
        t.checkEqual(q.job(id: job.id)?.state, .cancelled,
                     "CANCELASM_2 the cancelled Auto Movie stays cancelled after a late assembly")
        t.check(q.job(id: job.id)?.snapshot.movieRuns[0].assembly.state != .completed,
                "CANCELASM_3 the late success does not mark the work's film completed")
        t.checkEqual(q.job(id: job.id)?.outputPath, nil,
                     "CANCELASM_5 no output is attached to the cancelled job")

        // CANCELASM_4 — a late failure does not replace cancelled with failed.
        let qf = queue("late-failure")
        let failing = qf.enqueue(movieJob())
        assembling(qf, failing.id, works: [0])
        let frun = qf.job(id: failing.id)!.snapshot.movieRuns[0]
        qf.cancel(jobID: failing.id)
        deliver(qf, jobID: failing.id, runIndex: 0, runID: frun.id, attempt: frun.assembly.attemptNumber,
                result: .failed(reason: "ffmpeg killed"))
        t.checkEqual(qf.job(id: failing.id)?.state, .cancelled,
                     "CANCELASM_4 a late assembly failure leaves the job cancelled, not failed")
        t.checkEqual(qf.job(id: failing.id)?.failureReason, nil,
                     "CANCELASM_4 and attaches no failure reason")

        // CANCELASM_12 — parent and works stay consistent: the work reads as
        // cancelled, not completed, under a cancelled parent.
        let multi = queue("consistent")
        let two = multi.enqueue(movieJob(works: 2))
        assembling(multi, two.id, works: [0])
        let r0 = multi.job(id: two.id)!.snapshot.movieRuns[0]
        multi.cancel(jobID: two.id)
        deliver(multi, jobID: two.id, runIndex: 0, runID: r0.id, attempt: r0.assembly.attemptNumber,
                result: .completed(outputPath: "/tmp/final-0.mp4"))
        let items = ProductionWorkPresenter.items(for: multi.job(id: two.id)!)
        t.check(items.allSatisfy { $0.state == .cancelled },
                "CANCELASM_12 every work of the cancelled job reads as cancelled")
        t.check(!resumed.contains(two.id),
                "CANCELASM_12 a late assembly does not hand the cancelled job back to dispatch its other work")
        t.checkEqual(multi.job(id: two.id)?.state, .cancelled, "CANCELASM_12 which stays cancelled")
    }

    t.suite("Cancelled assembly — identity and attempts") {
        // CANCELASM_6 / _7 — a Retry makes a new job and a new assembly
        // attempt; the old attempt's result cannot complete it.
        let q = queue("retry")
        let original = q.enqueue(movieJob())
        assembling(q, original.id, works: [0])
        let old = q.job(id: original.id)!.snapshot.movieRuns[0]
        let oldAttempt = old.assembly.attemptNumber
        q.cancel(jobID: original.id)
        guard let retried = q.retry(jobID: original.id) else {
            t.check(false, "CANCELASM_6 fixture: retry"); return
        }
        let fresh = q.job(id: retried.id)!.snapshot.movieRuns[0]
        t.checkEqual(fresh.id, old.id, "fixture: the retry keeps the run identity")
        t.checkEqual(fresh.assembly.attemptNumber, oldAttempt + 1, "fixture: as a new assembly attempt")

        // Old attempt's result, addressed to the retry by run id — the one
        // identity the two share.
        let applied = q.applyAssemblyResult(
            jobID: retried.id, runID: old.id, attempt: oldAttempt,
            result: .completed(outputPath: "/tmp/final-0.mp4"))
        t.check(!applied, "CANCELASM_6 the old attempt's result is not applied to the retry")
        t.check(q.job(id: retried.id)?.snapshot.movieRuns[0].assembly.state != .completed,
                "CANCELASM_7 the old attempt's output does not satisfy the new attempt")

        // CANCELASM_8 — a duplicate result is applied at most once.
        let dq = queue("duplicate")
        let dup = dq.enqueue(movieJob())
        assembling(dq, dup.id, works: [0])
        let drun = dq.job(id: dup.id)!.snapshot.movieRuns[0]
        let first = deliver(dq, jobID: dup.id, runIndex: 0, runID: drun.id,
                            attempt: drun.assembly.attemptNumber, result: .completed(outputPath: "/tmp/d.mp4"))
        let finishedAt = dq.job(id: dup.id)?.finishedAt
        let second = deliver(dq, jobID: dup.id, runIndex: 0, runID: drun.id,
                             attempt: drun.assembly.attemptNumber, result: .failed(reason: "late duplicate"))
        t.check(first, "CANCELASM_8 fixture: the first result applies")
        t.check(!second, "CANCELASM_8 a duplicate result is ignored")
        t.checkEqual(dq.job(id: dup.id)?.snapshot.movieRuns[0].assembly.state, .completed,
                     "CANCELASM_8 and does not overwrite the recorded film")
        t.checkEqual(dq.job(id: dup.id)?.finishedAt, finishedAt,
                     "CANCELASM_8 nor re-finish the job")

        // CANCELASM_9 — the normal path still completes.
        let nq = queue("normal")
        let normal = nq.enqueue(movieJob())
        assembling(nq, normal.id, works: [0])
        let nrun = nq.job(id: normal.id)!.snapshot.movieRuns[0]
        t.check(deliver(nq, jobID: normal.id, runIndex: 0, runID: nrun.id,
                        attempt: nrun.assembly.attemptNumber, result: .completed(outputPath: "/tmp/n.mp4")),
                "CANCELASM_9 an uncancelled assembly result is applied")
        t.checkEqual(nq.job(id: normal.id)?.state, .completed, "CANCELASM_9 and the movie completes")
        t.checkEqual(nq.job(id: normal.id)?.snapshot.movieRuns[0].assembly.outputPath, "/tmp/n.mp4",
                     "CANCELASM_9 with its film")

        // CANCELASM_10 — an assembly that was never dispatched cannot be
        // completed by a stray result.
        let wq = queue("never")
        let never = wq.enqueue(movieJob())
        assembling(wq, never.id, works: [])
        let wrun = wq.job(id: never.id)!.snapshot.movieRuns[0]
        wq.cancel(jobID: never.id)
        t.check(!wq.applyAssemblyResult(jobID: never.id, runID: wrun.id,
                                        attempt: wrun.assembly.attemptNumber,
                                        result: .completed(outputPath: "/tmp/x.mp4")),
                "CANCELASM_10 no assembly result applies to a job cancelled before assembly")
    }

    t.suite("Cancelled assembly — the queue moves on") {
        // CANCELASM_11 — cancelling mid-assembly releases the queue, and the
        // late result neither blocks nor touches the next job.
        let q = queue("next")
        let cancelled = q.enqueue(movieJob())
        let next = q.enqueue(ProductionJob(kind: .generate, title: "next", snapshot: ProductionJobSnapshot()))
        assembling(q, cancelled.id, works: [0])
        let run = q.job(id: cancelled.id)!.snapshot.movieRuns[0]
        q.cancel(jobID: cancelled.id)
        t.checkEqual(q.activeJob?.id, next.id, "CANCELASM_11 the next job starts once the movie is cancelled")
        let nextBefore = q.job(id: next.id)
        deliver(q, jobID: cancelled.id, runIndex: 0, runID: run.id, attempt: run.assembly.attemptNumber,
                result: .completed(outputPath: "/tmp/final-0.mp4"))
        t.checkEqual(q.activeJob?.id, next.id, "CANCELASM_11 the late result does not change the active job")
        t.checkEqual(q.job(id: next.id), nextBefore, "CANCELASM_11 nor the next job")

        // CANCELASM_1 — Storyboard has no final assembly; its late shot
        // settlement is recorded into the owner's outcomes only and cannot
        // change the cancelled job or its shots.
        var p = FilmProject(title: "sb")
        p.workflowMode = "storyboard"
        p.shots = [Shot(index: 0, title: "One", compiledPrompt: "one")]
        let sq = queue("storyboard")
        let sb = sq.enqueue(try! StoryboardRunSubmission.makeJob(project: p, workCount: 1, directorMode: "direct"))
        var runs = sq.job(id: sb.id)!.snapshot.storyboardRuns
        let dispatched = UUID()
        runs[0].update(runs[0].orderedShots[0].id) { $0.state = .running; $0.dispatchedRequestID = dispatched }
        sq.updateStoryboardRuns(jobID: sb.id, runs: runs)
        sq.cancel(jobID: sb.id)
        let shotsBefore = sq.job(id: sb.id)!.snapshot.storyboardRuns
        sq.recordSettlement(RunOutcomeRecord(runID: dispatched, outcome: .completed, attemptNumber: 1))
        t.checkEqual(sq.job(id: sb.id)?.state, .cancelled,
                     "CANCELASM_1 a cancelled Storyboard stays cancelled after a late shot settlement")
        t.checkEqual(sq.job(id: sb.id)?.snapshot.storyboardRuns, shotsBefore,
                     "CANCELASM_1 and its shots are unchanged")
    }
}
