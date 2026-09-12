import Foundation
@testable import LTXVideoGeneratorCore

/// Regression tests for the bookkeeping defect where the LAST run of a
/// Generate/One Shot job was recorded `.interrupted` even though it had
/// finished and written a valid video: the queue subscription reached the
/// terminal close-out before the settlement subscription delivered, and the
/// settlement was then dropped because the job was no longer active.
func runTerminalSettlementTests(_ t: TestKit) {
    func makeRuns(_ count: Int, attempt: Int = 1) -> [GenerationRequest] {
        var params = GenerationParameters.default
        params.seed = nil
        let base = GenerationRequest(prompt: "p", modelId: ModelRegistry.customModelID, parameters: params)
        return CandidateExpander.expand(base, count: count).map {
            var r = $0; r.attemptNumber = attempt; return r
        }
    }
    func completed(_ r: GenerationRequest, path: String = "/tmp/out.mp4") -> RunOutcomeRecord {
        RunOutcomeRecord(runID: r.id, outcome: .completed, attemptNumber: r.attemptNumber ?? 1, outputPath: path)
    }
    /// Outcomes as the job ends up holding them: what was already recorded,
    /// merged with what the terminal close-out resolves (same merge rule as
    /// ProductionQueueCoordinator.recordRunOutcomes — replace by runID).
    func finalOutcomes(
        requests: [GenerationRequest], recorded: [RunOutcomeRecord],
        pending: RunOutcomeRecord?, failureReason: String? = nil
    ) -> [RunOutcomeRecord] {
        var merged = recorded
        for outcome in TerminalRunOutcomeResolver.resolve(
            requests: requests, recorded: recorded, pendingSettlement: pending, failureReason: failureReason) {
            if let i = merged.firstIndex(where: { $0.runID == outcome.runID }) { merged[i] = outcome } else { merged.append(outcome) }
        }
        return merged
    }
    func count(_ outcomes: [RunOutcomeRecord], _ outcome: RunOutcomeRecord.Outcome) -> Int {
        outcomes.filter { $0.outcome == outcome }.count
    }

    t.suite("SETTLEFINAL — a finished final run is never recorded interrupted") {
        // SETTLEFINAL_1 / SETTLEFINAL_11: one run, its settlement still in flight.
        let single = makeRuns(1)
        let one = finalOutcomes(requests: single, recorded: [], pending: completed(single[0]))
        t.checkEqual(count(one, .completed), 1, "SETTLEFINAL_1: the single run is recorded completed")
        t.checkEqual(count(one, .interrupted), 0, "SETTLEFINAL_1: nothing is left interrupted")
        t.checkEqual(one.first?.outputPath, "/tmp/out.mp4", "SETTLEFINAL_11: the settlement's output path is kept")
        t.checkEqual(one.count, 1, "SETTLEFINAL_11: batch of 1 records exactly one outcome")
        // Without the fix this was the failure: no pending settlement consumed.
        let unfixed = finalOutcomes(requests: single, recorded: [], pending: nil)
        t.checkEqual(count(unfixed, .interrupted), 1,
                     "SETTLEFINAL_1: a run that truly never settled is still interrupted")

        // SETTLEFINAL_2 / SETTLEFINAL_12: the 10th of 10.
        let ten = makeRuns(10)
        let nine = ten.dropLast().map { completed($0) }
        let all = finalOutcomes(requests: ten, recorded: Array(nine), pending: completed(ten[9]))
        t.checkEqual(count(all, .completed), 10, "SETTLEFINAL_2: all ten runs are completed")
        t.checkEqual(count(all, .interrupted), 0, "SETTLEFINAL_2: the tenth is not interrupted")
        t.checkEqual(all.count, 10, "SETTLEFINAL_12: one outcome per run, no duplicates")
        t.checkEqual(Set(all.map(\.runID)).count, 10, "SETTLEFINAL_12: outcomes cover all ten distinct runs")

        // SETTLEFINAL_3: while a matching success settlement is pending, the
        // close-out can never write interrupted for that run.
        let resolved = TerminalRunOutcomeResolver.resolve(
            requests: ten, recorded: Array(nine), pendingSettlement: completed(ten[9]), failureReason: nil)
        t.check(!resolved.contains { $0.runID == ten[9].id && $0.outcome == .interrupted },
                "SETTLEFINAL_3: the pending run is not closed out as interrupted")
        t.checkEqual(resolved.count, 1, "SETTLEFINAL_3: only the pending run's outcome is written")

        // SETTLEFINAL_4: a late but matching settlement is reconciled.
        let late = finalOutcomes(requests: single, recorded: [], pending: completed(single[0]))
        t.checkEqual(late.first?.outcome, .completed, "SETTLEFINAL_4: a late matching settlement is adopted")

        // SETTLEFINAL_5: a settlement from an earlier attempt is ignored.
        let retried = makeRuns(1, attempt: 2)
        let stale = RunOutcomeRecord(runID: retried[0].id, outcome: .completed, attemptNumber: 1, outputPath: "/tmp/old.mp4")
        let afterStale = finalOutcomes(requests: retried, recorded: [], pending: stale)
        t.checkEqual(count(afterStale, .completed), 0, "SETTLEFINAL_5: a prior-attempt settlement does not complete the run")
        t.checkEqual(count(afterStale, .interrupted), 1, "SETTLEFINAL_5: the current attempt is closed out instead")
        // A settlement belonging to another job's run is ignored too.
        let foreign = RunOutcomeRecord(runID: UUID(), outcome: .completed, attemptNumber: 1, outputPath: "/tmp/x.mp4")
        let afterForeign = finalOutcomes(requests: single, recorded: [], pending: foreign)
        t.checkEqual(afterForeign.count, 1, "SETTLEFINAL_5: a cross-run settlement adds no outcome")
        t.checkEqual(afterForeign.first?.outcome, .interrupted, "SETTLEFINAL_5: and does not complete this job's run")

        // SETTLEFINAL_6: the same settlement twice is idempotent.
        let firstPass = finalOutcomes(requests: single, recorded: [], pending: completed(single[0]))
        let secondPass = finalOutcomes(requests: single, recorded: firstPass, pending: completed(single[0]))
        t.checkEqual(secondPass, firstPass, "SETTLEFINAL_6: a repeated settlement changes nothing")
        t.checkEqual(TerminalRunOutcomeResolver.resolve(
            requests: single, recorded: firstPass, pendingSettlement: completed(single[0]), failureReason: nil).count, 0,
                     "SETTLEFINAL_6: an already-recorded run is not written again")
        let recordedCompleted = finalOutcomes(requests: single, recorded: firstPass, pending: nil)
        t.checkEqual(count(recordedCompleted, .completed), 1,
                     "SETTLEFINAL_6: a completed run is never downgraded by a later close-out")

        // SETTLEFINAL_7: cancellation stays cancellation.
        let three = makeRuns(3)
        let cancelled = RunOutcomeRecord(runID: three[1].id, outcome: .cancelled, attemptNumber: 1)
        let afterCancel = finalOutcomes(requests: three, recorded: [completed(three[0])], pending: cancelled)
        t.checkEqual(count(afterCancel, .completed), 1, "SETTLEFINAL_7: only the genuinely finished run is completed")
        t.checkEqual(count(afterCancel, .cancelled), 1, "SETTLEFINAL_7: the cancelled run stays cancelled")
        t.checkEqual(count(afterCancel, .interrupted), 1, "SETTLEFINAL_7: the run that never started is interrupted")

        // SETTLEFINAL_8: a real backend failure stays failed.
        let failedSettlement = RunOutcomeRecord(
            runID: three[1].id, outcome: .failed, attemptNumber: 1, failureReason: "ltx-2-mlx exited with code 1")
        let afterFailure = finalOutcomes(
            requests: three, recorded: [completed(three[0])], pending: failedSettlement,
            failureReason: "ltx-2-mlx exited with code 1")
        t.checkEqual(count(afterFailure, .failed), 2, "SETTLEFINAL_8: the failed run and the unreached one are failed")
        t.checkEqual(count(afterFailure, .completed), 1, "SETTLEFINAL_8: the earlier success is untouched")
        t.check(afterFailure.contains { $0.runID == three[1].id && $0.failureReason?.contains("exited with code 1") == true },
                "SETTLEFINAL_8: the backend reason is preserved")

        // SETTLEFINAL_9: a restart does not regenerate a completed final run.
        let persisted = finalOutcomes(requests: ten, recorded: Array(nine), pending: completed(ten[9]))
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = ten
        snapshot.runOutcomes = persisted
        let reloaded = try? JSONDecoder().decode(ProductionJobSnapshot.self, from: JSONEncoder().encode(snapshot))
        t.checkEqual(reloaded?.runOutcomes, persisted, "SETTLEFINAL_9: outcomes survive persistence")
        let plan = RunRetryPlanner.plan(requests: ten, outcomes: reloaded?.runOutcomes ?? [])
        t.check(plan.isEmpty, "SETTLEFINAL_9: after a restart nothing is re-run")
        t.checkEqual(plan.skippedRunIDs.count, 10, "SETTLEFINAL_9: all ten are recognised as already done")
        let planBeforeFix = RunRetryPlanner.plan(
            requests: ten,
            outcomes: Array(nine) + [RunOutcomeRecord(runID: ten[9].id, outcome: .interrupted, attemptNumber: 1)])
        t.checkEqual(planBeforeFix.requestsToRun.count, 1,
                     "SETTLEFINAL_9: this is what the defect cost — the finished run would be rendered again")

        // SETTLEFINAL_10: execution state never comes from History or the disk.
        let existing = FileManager.default.temporaryDirectory.appendingPathComponent("settlefinal-\(UUID().uuidString).mp4")
        try? Data("not a settlement".utf8).write(to: existing)
        defer { try? FileManager.default.removeItem(at: existing) }
        let onDiskOnly = finalOutcomes(requests: single, recorded: [], pending: nil)
        t.checkEqual(count(onDiskOnly, .completed), 0,
                     "SETTLEFINAL_10: a video on disk does not make a run completed without a settlement")
        t.check(!(try! String(contentsOfFile: "LTXVideoGenerator/Sources/Services/ProductionQueueService.swift", encoding: .utf8)
            .components(separatedBy: "enum TerminalRunOutcomeResolver")[1]
            .contains("history") ),
                "SETTLEFINAL_10: the resolver does not consult History")
    }
}
