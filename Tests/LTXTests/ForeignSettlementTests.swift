import Foundation
@testable import LTXVideoGeneratorCore

/// A render settlement must land in the job that dispatched it — never in
/// whichever job happens to be active when the notification arrives.
///
/// The renderer publishes each settlement once, and the queue receives it on a
/// later main-queue turn (`receive(on: RunLoop.main)`). The recorder then wrote
/// it into `coordinator.activeJob`. When a job's last run finished, the queue's
/// other subscription could close that job out and start the next one first,
/// so the settlement arrived after the active job had already changed and was
/// recorded as the *new* job's outcome. Real Dev data shows exactly that: One
/// Shot AC2F000A's second run recorded "interrupted" in its own job, while its
/// real "completed" settlement sat in the next job, AE0E208E.
///
/// Deterministic: the delivery gap is modelled by changing the active job
/// between creating the settlement and delivering it. No sleeps.
func runForeignSettlementTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ForeignSettle-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func queue(_ name: String) -> ProductionQueueCoordinator {
        let q = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(name).json")),
            restoreOnInit: false)
        q.runner = { _ in .started }
        return q
    }

    /// One Shot / Generate count=N exactly as submitted: expanded, then stamped.
    func requestJob(_ title: String, count: Int = 2, kind: ProductionJobKind = .oneShot) -> ProductionJob {
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = CandidateExpander.expand(
            GenerationRequest(
                prompt: title,
                parameters: GenerationParameters(
                    numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
                    numFrames: 81, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1)),
            count: count)
        snapshot.batchCount = count
        return RunProvenanceStamper.stamp(ProductionJob(kind: kind, title: title, snapshot: snapshot))
    }

    /// What the renderer publishes for one request.
    func settlement(for request: GenerationRequest, _ outcome: RunOutcomeRecord.Outcome = .completed) -> RunOutcomeRecord {
        RunOutcomeRecord(
            runID: request.id, outcome: outcome,
            attemptNumber: request.attemptNumber ?? 1,
            outputPath: outcome == .completed ? "/tmp/\(request.id).mp4" : nil)
    }

    t.suite("Foreign settlement — a late completion lands in its own job") {
        let q = queue("race")
        let a = q.enqueue(requestJob("A"))
        let b = q.enqueue(requestJob("B"))
        t.checkEqual(q.activeJob?.id, a.id, "fixture: A is active")

        let a1 = a.snapshot.pendingRequests[0], a2 = a.snapshot.pendingRequests[1]
        q.recordSettlement(settlement(for: a1))

        // A2 finishes. Its settlement is published, but before it is delivered
        // the queue observes the drained renderer, closes A out (A2 has no
        // recorded state yet, so it is filled in as interrupted) and starts B.
        let late = settlement(for: a2)
        q.recordRunOutcomes(jobID: a.id, outcomes: [RunOutcomeRecord(
            runID: a2.id, outcome: .interrupted, attemptNumber: 1)])
        q.markCompleted(jobID: a.id)
        t.checkEqual(q.activeJob?.id, b.id, "fixture: B became active before A2's settlement arrived")

        // Only now is A2's settlement delivered.
        q.recordSettlement(late)

        // FOREIGNSETTLE_1 — the defect: it must not become B's outcome.
        let bOutcomes = q.job(id: b.id)?.snapshot.runOutcomes ?? []
        t.check(!bOutcomes.contains { $0.runID == a2.id },
                "FOREIGNSETTLE_1 A's settlement is not recorded into the active job B")
        t.checkEqual(bOutcomes.count, 0, "FOREIGNSETTLE_1 B's outcomes are untouched")
        t.checkEqual(q.job(id: b.id)?.state, .running, "FOREIGNSETTLE_1 B's state is untouched")

        // FOREIGNSETTLE_2 — it lands where it belongs, replacing the
        // close-out placeholder with what actually happened.
        let aOutcome = q.job(id: a.id)?.snapshot.runOutcomes.first { $0.runID == a2.id }
        t.checkEqual(aOutcome?.outcome, .completed,
                     "FOREIGNSETTLE_2 A2's real completion is recorded in A, not left interrupted")
        t.checkEqual(aOutcome?.outputPath, "/tmp/\(a2.id).mp4",
                     "FOREIGNSETTLE_2 with its output")
        t.checkEqual(q.job(id: a.id)?.state, .completed,
                     "FOREIGNSETTLE_2 A's job state is not changed by a late outcome")

        // FOREIGNSETTLE_3 — so a Retry of A would not render A2 again.
        let plan = RunRetryPlanner.plan(
            requests: q.job(id: a.id)!.snapshot.pendingRequests,
            outcomes: q.job(id: a.id)!.snapshot.runOutcomes)
        t.check(plan.isEmpty, "FOREIGNSETTLE_3 with both runs completed, nothing is re-rendered")

        // FOREIGNSETTLE_4 — B's own settlement still records normally.
        let b1 = b.snapshot.pendingRequests[0]
        q.recordSettlement(settlement(for: b1))
        t.checkEqual(q.job(id: b.id)?.snapshot.runOutcomes.map(\.runID), [b1.id],
                     "FOREIGNSETTLE_4 the active job's own settlement is recorded")
    }

    t.suite("Foreign settlement — ownership is by request id and attempt") {
        // FOREIGNSETTLE_5 — Retry copies request ids; the attempt number is what
        // tells the original job's late settlement from the retry's.
        let q = queue("retry")
        let original = q.enqueue(requestJob("orig", count: 1))
        let r1 = original.snapshot.pendingRequests[0]
        q.markFailed(jobID: original.id, reason: "backend failed")
        guard let retried = q.retry(jobID: original.id) else {
            t.check(false, "FOREIGNSETTLE_5 fixture: retry"); return
        }
        t.checkEqual(retried.snapshot.pendingRequests[0].id, r1.id, "fixture: retry keeps the request id")
        t.checkEqual(q.activeJob?.id, retried.id, "fixture: the retry is active")

        q.recordSettlement(RunOutcomeRecord(runID: r1.id, outcome: .failed, attemptNumber: 1,
                                            failureReason: "late attempt 1"))
        t.checkEqual(q.job(id: retried.id)?.snapshot.runOutcomes.count, 0,
                     "FOREIGNSETTLE_5 a late attempt-1 settlement does not touch the attempt-2 retry")
        t.checkEqual(q.job(id: original.id)?.snapshot.runOutcomes.first?.failureReason, "late attempt 1",
                     "FOREIGNSETTLE_5 it belongs to the original job")

        q.recordSettlement(RunOutcomeRecord(runID: r1.id, outcome: .completed, attemptNumber: 2,
                                            outputPath: "/tmp/r.mp4"))
        t.checkEqual(q.job(id: retried.id)?.snapshot.runOutcomes.first?.outcome, .completed,
                     "FOREIGNSETTLE_5 the attempt-2 settlement is the retry's")
        t.checkEqual(q.job(id: original.id)?.snapshot.runOutcomes.count, 1,
                     "FOREIGNSETTLE_5 and leaves the original alone")

        // FOREIGNSETTLE_6 — an id no job owns is dropped, not attributed.
        let before = q.jobs
        q.recordSettlement(RunOutcomeRecord(runID: UUID(), outcome: .completed, attemptNumber: 1))
        t.checkEqual(q.jobs, before, "FOREIGNSETTLE_6 a settlement nobody owns mutates nothing")

        // FOREIGNSETTLE_7 — the owner was dismissed before delivery.
        let gone = q.enqueue(requestJob("gone", count: 1))
        let goneRequest = gone.snapshot.pendingRequests[0]
        q.remove(jobID: gone.id)
        let afterRemoval = q.jobs
        q.recordSettlement(settlement(for: goneRequest))
        t.checkEqual(q.jobs, afterRemoval,
                     "FOREIGNSETTLE_7 a settlement for a removed job is dropped, not given to another")
    }

    t.suite("Foreign settlement — run-scoped jobs") {
        // FOREIGNSETTLE_8 — a run-scoped job owns a settlement through the
        // shot that dispatched it; it is never recorded into another job.
        var p = FilmProject(title: "sb")
        p.workflowMode = "storyboard"
        p.shots = [Shot(index: 0, title: "One", compiledPrompt: "one")]
        let q = queue("runscoped")
        let sb = q.enqueue(try! StoryboardRunSubmission.makeJob(project: p, workCount: 1, directorMode: "direct"))
        var runs = q.job(id: sb.id)!.snapshot.storyboardRuns
        let dispatched = UUID()
        runs[0].update(runs[0].orderedShots[0].id) { $0.state = .running; $0.dispatchedRequestID = dispatched }
        q.updateStoryboardRuns(jobID: sb.id, runs: runs)
        let next = q.enqueue(requestJob("next"))
        q.markCancelled(jobID: sb.id)
        t.checkEqual(q.activeJob?.id, next.id, "fixture: the next job is active")

        q.recordSettlement(RunOutcomeRecord(runID: dispatched, outcome: .completed, attemptNumber: 1))
        t.checkEqual(q.job(id: next.id)?.snapshot.runOutcomes.count, 0,
                     "FOREIGNSETTLE_8 a Storyboard shot's settlement never becomes another job's outcome")
    }
}
