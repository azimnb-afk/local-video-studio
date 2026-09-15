import Foundation
@testable import LTXVideoGeneratorCore

/// Retry continues one line of attempts: only the latest job of a lineage can
/// be retried.
///
/// Retry copies a job — same request ids (or run ids), next attempt — and
/// leaves the original in the queue. Whether a job offered Retry was decided
/// from its own state alone, and the next attempt from its own snapshot. So
/// once attempt 2 had run, the attempt-1 job still offered Retry and produced
/// attempt 2 a second time. Two jobs then held the same request at the same
/// attempt, a settlement matched both, its owner came back nil, and the
/// result was never recorded. Found in the Dev app: interrupted attempt 1 →
/// Restart → attempt 2 completed → Restart on attempt 1 again.
func runRetrySupersededJobTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RetrySupersede-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let params = GenerationParameters(
        numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
        numFrames: 81, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1)

    func store(_ name: String) -> ProductionQueueStore {
        ProductionQueueStore(fileURL: root.appendingPathComponent("\(name).json"))
    }
    func coordinator(_ s: ProductionQueueStore, restore: Bool = false) -> ProductionQueueCoordinator {
        let q = ProductionQueueCoordinator(store: s, restoreOnInit: restore)
        q.runner = { _ in .started }
        return q
    }
    /// The next launch: the persisted queue restored, running jobs interrupted.
    func relaunch(_ s: ProductionQueueStore, after q: ProductionQueueCoordinator) -> ProductionQueueCoordinator {
        _ = q
        s.flush()
        return coordinator(s, restore: true)
    }
    func requestJob(_ kind: ProductionJobKind, _ title: String, count: Int = 1) -> ProductionJob {
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = CandidateExpander.expand(
            GenerationRequest(prompt: title, modelId: "ltx23_distilled_q4", parameters: params), count: count)
        snapshot.batchCount = count
        return RunProvenanceStamper.stamp(ProductionJob(kind: kind, title: title, snapshot: snapshot))
    }
    func settle(_ q: ProductionQueueCoordinator, _ job: ProductionJob, _ outcome: RunOutcomeRecord.Outcome) {
        for r in job.snapshot.pendingRequests {
            q.recordSettlement(RunOutcomeRecord(runID: r.id, outcome: outcome, attemptNumber: r.attemptNumber ?? 1,
                                                outputPath: outcome == .completed ? "/tmp/\(r.id).mp4" : nil))
        }
    }
    func attempt(_ job: ProductionJob?) -> Int? { job?.snapshot.pendingRequests.first?.attemptNumber ?? (job == nil ? nil : 1) }
    func pairsUnique(_ q: ProductionQueueCoordinator) -> Bool {
        let pairs = q.jobs.flatMap { job in job.snapshot.pendingRequests.map { "\($0.id)#\($0.attemptNumber ?? 1)" } }
        return pairs.count == Set(pairs).count
    }

    for kind in [ProductionJobKind.generate, .oneShot] {
        let label = kind == .generate ? "RETRYSUPERSEDE_9 Generate" : "RETRYSUPERSEDE_10 One Shot"

        t.suite("\(label) — the Dev reproduction") {
            // attempt 1 interrupted (the app quit while it rendered).
            let s = store("dev-\(kind)")
            let first = coordinator(s)
            let original = first.enqueue(requestJob(kind, "dev"))
            var q = relaunch(s, after: first)
            t.checkEqual(q.job(id: original.id)?.state, .interrupted, "\(label) fixture: attempt 1 is interrupted")
            t.check(q.isRetryEligible(jobID: original.id), "RETRYSUPERSEDE_2 \(label): with no later attempt, attempt 1 can be restarted")

            // Restart → attempt 2, running.
            guard let second = q.retry(jobID: original.id) else { t.check(false, "\(label): Restart produced attempt 2"); return }
            t.checkEqual(attempt(second), 2, "\(label): Restart runs attempt 2")
            t.checkEqual(q.job(id: second.id)?.state, .running, "\(label) fixture: attempt 2 is running")
            t.check(!q.isRetryEligible(jobID: original.id),
                    "RETRYSUPERSEDE_RED RETRYSUPERSEDE_2 \(label): while attempt 2 runs, attempt 1 offers no Restart")

            // attempt 2 completes.
            settle(q, second, .completed)
            q.markCompleted(jobID: second.id)
            t.check(!q.isRetryEligible(jobID: original.id),
                    "RETRYSUPERSEDE_RED RETRYSUPERSEDE_1 \(label): once attempt 2 completed, attempt 1 offers no Restart")
            t.check(!ProductionQueueCoordinator.isRetryEligible(q.job(id: original.id)!, in: q.jobs),
                    "RETRYSUPERSEDE_1 \(label): the queue panel's condition agrees")

            // Restart on attempt 1 again — straight to the coordinator, as a stale UI would.
            let jobsBefore = q.jobs.count
            let again = q.retry(jobID: original.id)
            t.check(again == nil, "RETRYSUPERSEDE_RED RETRYSUPERSEDE_7 \(label): the domain layer refuses to retry a superseded job")
            t.checkEqual(q.jobs.count, jobsBefore, "RETRYSUPERSEDE_7 \(label): and queues nothing")
            if let again {
                // What happened before: attempt 2 again, and its settlement had no owner.
                let r = again.snapshot.pendingRequests[0]
                let late = RunOutcomeRecord(runID: r.id, outcome: .completed, attemptNumber: r.attemptNumber ?? 1, outputPath: "/tmp/x.mp4")
                t.checkEqual(ProductionQueueCoordinator.owner(of: late, in: q.jobs), again.id,
                             "RETRYSUPERSEDE_6 \(label): a duplicate attempt's settlement would have no owner")
            }
            t.check(pairsUnique(q), "RETRYSUPERSEDE_6 \(label): no request is held at the same attempt by two jobs")

            // RETRYSUPERSEDE_8 — the next launch reaches the same answer from disk.
            q = relaunch(s, after: q)
            t.check(!q.isRetryEligible(jobID: original.id), "RETRYSUPERSEDE_8 \(label): after a relaunch attempt 1 still offers no Restart")
            t.checkEqual(q.job(id: second.id)?.state, .completed, "RETRYSUPERSEDE_11 \(label): attempt 2 stays completed")
            t.check(!q.isRetryEligible(jobID: second.id) && q.retry(jobID: second.id) == nil,
                    "RETRYSUPERSEDE_11 \(label): a completed job offers no Retry")
        }

        t.suite("\(label) — only the latest attempt retries") {
            // RETRYSUPERSEDE_3 / _5 — attempt 2 failed.
            do {
                let q = coordinator(store("failed-\(kind)"))
                let one = q.enqueue(requestJob(kind, "failed"))
                q.markFailed(jobID: one.id, reason: "boom")
                t.check(q.isRetryEligible(jobID: one.id), "RETRYSUPERSEDE_3 \(label): a failed job with no later attempt can retry")
                guard let two = q.retry(jobID: one.id) else { t.check(false, "\(label): retry"); return }
                q.markFailed(jobID: two.id, reason: "boom again")
                t.check(!q.isRetryEligible(jobID: one.id), "RETRYSUPERSEDE_RED RETRYSUPERSEDE_3 \(label): attempt 1 no longer retries")
                t.check(q.isRetryEligible(jobID: two.id), "RETRYSUPERSEDE_3 \(label): attempt 2, the latest, does")
                let three = q.retry(jobID: two.id)
                t.checkEqual(attempt(three), 3, "RETRYSUPERSEDE_5 \(label): retrying attempt 2 runs attempt 3")
                t.check(pairsUnique(q), "RETRYSUPERSEDE_6 \(label): attempts stay unique")

                // Case 7 — attempt 3 completes; neither earlier attempt retries.
                if let three {
                    settle(q, three, .completed)
                    q.markCompleted(jobID: three.id)
                    t.check(!q.isRetryEligible(jobID: one.id) && !q.isRetryEligible(jobID: two.id),
                            "RETRYSUPERSEDE_3 \(label): after attempt 3 completed, attempts 1 and 2 offer no Retry")
                    t.check(q.retry(jobID: one.id) == nil && q.retry(jobID: two.id) == nil,
                            "RETRYSUPERSEDE_7 \(label): and the coordinator refuses both")
                }
            }

            // RETRYSUPERSEDE_4 — attempt 2 interrupted too.
            do {
                let s = store("interrupted-\(kind)")
                let a = coordinator(s)
                let one = a.enqueue(requestJob(kind, "interrupted"))
                var q = relaunch(s, after: a)
                guard let two = q.retry(jobID: one.id) else { t.check(false, "\(label): restart"); return }
                q = relaunch(s, after: q)
                t.checkEqual(q.job(id: two.id)?.state, .interrupted, "\(label) fixture: attempt 2 interrupted as well")
                t.check(!q.isRetryEligible(jobID: one.id), "RETRYSUPERSEDE_RED RETRYSUPERSEDE_4 \(label): attempt 1 offers no Restart")
                t.check(q.isRetryEligible(jobID: two.id), "RETRYSUPERSEDE_4 \(label): attempt 2 does")
                t.checkEqual(attempt(q.retry(jobID: two.id)), 3, "RETRYSUPERSEDE_5 \(label): and becomes attempt 3")
            }

            // RETRYSUPERSEDE_12 — a cancelled job keeps its Retry until a later attempt exists.
            do {
                let q = coordinator(store("cancelled-\(kind)"))
                let one = q.enqueue(requestJob(kind, "cancelled"))
                q.cancel(jobID: one.id)
                t.checkEqual(q.job(id: one.id)?.state, .cancelled, "RETRYSUPERSEDE_12 \(label): the job is cancelled")
                t.check(q.isRetryEligible(jobID: one.id), "RETRYSUPERSEDE_12 \(label): a cancelled job with no later attempt can retry")
                let two = q.retry(jobID: one.id)
                t.checkEqual(attempt(two), 2, "RETRYSUPERSEDE_12 \(label): as attempt 2")
                t.checkEqual(q.job(id: one.id)?.state, .cancelled, "RETRYSUPERSEDE_12 \(label): the original stays cancelled")
                t.check(!q.isRetryEligible(jobID: one.id), "RETRYSUPERSEDE_12 \(label): and no longer retries")
            }

            // A batch retried in part: the retry carries only the failed request.
            do {
                let q = coordinator(store("partial-\(kind)"))
                let one = q.enqueue(requestJob(kind, "partial", count: 3))
                let r = one.snapshot.pendingRequests
                q.recordSettlement(RunOutcomeRecord(runID: r[0].id, outcome: .completed, attemptNumber: 1, outputPath: "/tmp/a.mp4"))
                q.recordSettlement(RunOutcomeRecord(runID: r[1].id, outcome: .failed, attemptNumber: 1))
                q.recordSettlement(RunOutcomeRecord(runID: r[2].id, outcome: .completed, attemptNumber: 1, outputPath: "/tmp/c.mp4"))
                q.markFailed(jobID: one.id, reason: "work 2 failed")
                guard let two = q.retry(jobID: one.id) else { t.check(false, "\(label): partial retry"); return }
                t.checkEqual(two.snapshot.pendingRequests.map(\.id), [r[1].id], "\(label) fixture: the retry carries work 2 only")
                t.check(!q.isRetryEligible(jobID: one.id),
                        "RETRYSUPERSEDE_RED RETRYSUPERSEDE_1 \(label): a partial retry supersedes the batch it came from")
            }
        }
    }

    t.suite("RETRYSUPERSEDE — independent jobs and film runs") {
        // Unrelated jobs never supersede each other.
        let q = coordinator(store("independent"))
        let a = q.enqueue(requestJob(.generate, "a"))
        q.markFailed(jobID: a.id, reason: "x")
        let b = q.enqueue(requestJob(.generate, "b"))
        q.markFailed(jobID: b.id, reason: "y")
        t.check(q.isRetryEligible(jobID: a.id) && q.isRetryEligible(jobID: b.id),
                "RETRYSUPERSEDE_11 two unrelated failed jobs both keep their Retry")

        // A legacy job with no requests or runs is unaffected.
        var legacy = ProductionJob(kind: .autoMovie, title: "legacy", snapshot: ProductionJobSnapshot())
        legacy.state = .interrupted
        t.check(ProductionQueueCoordinator.isRetryEligible(legacy, in: [legacy, a, b]),
                "RETRYSUPERSEDE_11 a legacy project-driven job keeps its Restart")

        // Run-scoped: the same lineage rule by run.
        var p = FilmProject(title: "sb")
        p.workflowMode = "storyboard"
        p.shots = [Shot(index: 0, title: "S", compiledPrompt: "s")]
        let film = coordinator(store("film"))
        let one = film.enqueue(try! StoryboardRunSubmission.makeJob(project: p, workCount: 1, directorMode: "direct"))
        var runs = film.job(id: one.id)!.snapshot.storyboardRuns
        StoryboardRunScheduler.recordFailure(in: &runs[0], shotID: runs[0].orderedShots[0].id, reason: "boom")
        film.updateStoryboardRuns(jobID: one.id, runs: runs)
        film.markFailed(jobID: one.id, reason: "boom")
        guard let two = film.retry(jobID: one.id) else { t.check(false, "Storyboard retry"); return }
        t.check(!film.isRetryEligible(jobID: one.id), "RETRYSUPERSEDE_RED RETRYSUPERSEDE_1 a retried Storyboard job no longer retries")
        t.check(film.retry(jobID: one.id) == nil, "RETRYSUPERSEDE_7 nor can it be retried directly")
        film.markFailed(jobID: two.id, reason: "boom")
        t.check(film.isRetryEligible(jobID: two.id), "RETRYSUPERSEDE_3 its retry, the latest, can")
    }

    t.suite("RETRYSUPERSEDE — the production queue service") {
        MainActor.assumeIsolated {
            let s = store("service")
            let c = coordinator(s)
            let one = c.enqueue(requestJob(.oneShot, "service"))
            c.markFailed(jobID: one.id, reason: "x")
            guard let two = c.retry(jobID: one.id) else { t.check(false, "service fixture retry"); return }
            settle(c, two, .completed)
            c.markCompleted(jobID: two.id)
            let service = ProductionQueueService(coordinator: c)
            let before = c.jobs.count
            t.check(!service.isRetryEligible(c.job(id: one.id)!), "RETRYSUPERSEDE_RED RETRYSUPERSEDE_7 the service reports attempt 1 as not retryable")
            service.retry(jobID: one.id)
            t.checkEqual(c.jobs.count, before, "RETRYSUPERSEDE_7 and its retry entry point queues nothing")
        }
    }
}
