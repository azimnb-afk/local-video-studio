import Foundation
@testable import LTXVideoGeneratorCore

/// What the Production Queue panel is actually handed — not what the model
/// stores.
///
/// A live Dev run showed a job failing with a correct, specific, actionable
/// reason that no user could ever read: `ProductionQueuePanel` renders
/// `activeDisplayJobs`, which filtered out every terminal job, and `.failed`
/// is terminal. The panel therefore dropped the job in the same transition
/// that set its `failureReason`, and the orange reason `Text` in
/// `ProductionQueueRow` was unreachable for a failure by construction.
///
/// Every earlier suite asserted on the persisted model and passed. These
/// assert on the projection the view consumes, which is where the defect was.
func runFailedJobVisibilityTests(_ t: TestKit) {

    func job(
        _ state: ProductionJobState,
        title: String,
        reason: String? = nil,
        createdAt: Date = Date()
    ) -> ProductionJob {
        var j = ProductionJob(
            kind: .autoMovie, title: title, snapshot: ProductionJobSnapshot())
        j.state = state
        j.failureReason = reason
        j.createdAt = createdAt
        return j
    }

    let frozenImageReason =
        "開始画像がキュー追加後に変更されています（scratch-start.png）。"
        + "意図しない画像で生成しないよう、生成を中止しました。再度キューに追加してください。"

    func displayed(_ jobs: [ProductionJob]) -> [ProductionJob] {
        ProductionQueueCoordinator.activeDisplayJobs(from: jobs)
    }
    func titles(_ jobs: [ProductionJob]) -> [String] {
        displayed(jobs).map(\.title)
    }

    t.suite("Production Queue — a failure stays readable until it is dismissed") {

        // FAILEDUI_1 — the existing active cases are untouched.
        let running = job(.running, title: "running")
        let waiting = job(.waiting, title: "waiting")
        t.checkEqual(titles([running]), ["running"],
                     "FAILEDUI_1 a running job is displayed")
        t.checkEqual(titles([waiting]), ["waiting"],
                     "FAILEDUI_1 and so is a waiting job")

        // FAILEDUI_2 — a finished job still leaves. The queue is not a log.
        let completed = job(.completed, title: "completed")
        t.checkEqual(titles([completed]), [],
                     "FAILEDUI_2 a completed job is not displayed")

        // FAILEDUI_3 — the defect this suite exists for.
        let failed = job(.failed, title: "failed", reason: frozenImageReason)
        t.checkEqual(titles([failed]), ["failed"],
                     "FAILEDUI_3 a failed job stays visible even though it is terminal")

        // FAILEDUI_4 / FAILEDUI_12 — the reason survives the projection intact.
        // Verbatim: a summarised or truncated reason is not actionable.
        t.checkEqual(displayed([failed]).first?.failureReason, frozenImageReason,
                     "FAILEDUI_4 the exact failure reason reaches the display model")
        t.check(displayed([failed]).first?.failureReason?
                    .contains("開始画像がキュー追加後に変更されています") == true,
                "FAILEDUI_12 the specific frozen-image cause reaches the panel")
        t.check(displayed([failed]).first?.failureReason?.contains("scratch-start.png") == true,
                "FAILEDUI_12 naming the picture")
        t.check(displayed([failed]).first?.failureReason?.contains("/") == false,
                "FAILEDUI_12 and never an absolute path")

        // FAILEDUI_5 / FAILEDUI_6 — dismissal is the existing terminal-job
        // removal, which is already wired to the row's xmark button. Removing
        // one job must not disturb another.
        let otherFailed = job(.failed, title: "other", reason: "something else")
        let afterDismiss = [failed, otherFailed].filter { $0.id != failed.id }
        t.checkEqual(titles(afterDismiss), ["other"],
                     "FAILEDUI_5 a dismissed failure is no longer displayed")
        t.checkEqual(displayed(afterDismiss).first?.failureReason, "something else",
                     "FAILEDUI_6 and the other job keeps its own reason")
        t.checkEqual(displayed(afterDismiss).count, 1,
                     "FAILEDUI_6 dismissing one does not dismiss the rest")

        // FAILEDUI_7 — the projection is pure, so a redraw cannot lose it.
        // (SwiftUI recomputes `activeDisplayJobs` on every body evaluation;
        // this is what makes "navigate away and back" safe.)
        let once = titles([failed])
        let twice = titles([failed])
        t.checkEqual(once, twice,
                     "FAILEDUI_7 recomputing the display set is stable across redraws")
        t.checkEqual(titles([failed, completed, running]),
                     titles([failed, completed, running]),
                     "FAILEDUI_7 and stable for a mixed queue")

        // FAILEDUI_8 — cancelled keeps today's policy. A user who cancelled
        // knows why it stopped; showing it as an unread error would be noise.
        let cancelled = job(.cancelled, title: "cancelled")
        t.checkEqual(titles([cancelled]), [],
                     "FAILEDUI_8 a cancelled job stays hidden, as before")

        // FAILEDUI_9 — several failures are each independently inspectable.
        let f1 = job(.failed, title: "f1", reason: "reason one",
                     createdAt: Date(timeIntervalSince1970: 100))
        let f2 = job(.failed, title: "f2", reason: "reason two",
                     createdAt: Date(timeIntervalSince1970: 200))
        let f3 = job(.failed, title: "f3", reason: "reason three",
                     createdAt: Date(timeIntervalSince1970: 300))
        let many = displayed([f1, f2, f3])
        t.checkEqual(many.count, 3, "FAILEDUI_9 every failure is displayed")
        t.checkEqual(many.map(\.failureReason),
                     ["reason three", "reason two", "reason one"],
                     "FAILEDUI_9 each keeps its own reason, newest first")

        // FAILEDUI_10 — a failure does not hide live work, or vice versa.
        let mixed = titles([running, failed])
        t.check(mixed.contains("running") && mixed.contains("failed"),
                "FAILEDUI_10 a running job and a failed job are both shown")
        t.checkEqual(mixed.count, 2, "FAILEDUI_10 and nothing else appears")

        // FAILEDUI_11 — success still disappears while the failure remains.
        t.checkEqual(titles([completed, failed]), ["failed"],
                     "FAILEDUI_11 only the failure is shown")

        // The ordering contract the panel relies on is unchanged: newest first.
        let older = job(.failed, title: "older", reason: "r",
                        createdAt: Date(timeIntervalSince1970: 1))
        let newer = job(.running, title: "newer",
                        createdAt: Date(timeIntervalSince1970: 2))
        t.checkEqual(titles([older, newer]), ["newer", "older"],
                     "FAILEDUI_10 newest-first ordering still holds with failures mixed in")

        // The state model itself must not have been bent to achieve this:
        // failed stays terminal, so nothing reschedules it.
        t.check(ProductionJobState.failed.isTerminal,
                "FAILEDUI_3 failed remains terminal — this is presentation only")
        t.check(!ProductionJobState.failed.isTerminal == false,
                "FAILEDUI_3 execution semantics are untouched")
        t.check(job(.failed, title: "x").canRetry,
                "FAILEDUI_5 and a displayed failure can still be retried by the user")
    }

    // Failures now stay until dismissed, and a real Dev queue already held 26
    // of them from earlier weeks. "Clear Failed" dismisses them in one step —
    // it must be exactly the per-row dismissal applied to failures and
    // nothing else, so it is exercised on a real coordinator with a real
    // store, including a relaunch.
    t.suite("Production Queue — Clear Failed removes failures and nothing else") {
        func queued(_ kind: ProductionJobKind, _ title: String) -> ProductionJob {
            ProductionJob(kind: kind, title: title, snapshot: ProductionJobSnapshot())
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClearFailed-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProductionQueueStore(fileURL: root.appendingPathComponent("queue.json"))

        let coordinator = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        var started: [UUID] = []
        coordinator.runner = { started.append($0.id); return .started }
        // Paused so nothing is dispatched while the fixture is built; the
        // waiting job must still be waiting after the clear.
        coordinator.setPaused(true)

        let waiting = coordinator.enqueue(queued(.autoMovie, "waiting"))
        let failedA = coordinator.enqueue(queued(.autoMovie, "failed A"))
        let failedB = coordinator.enqueue(queued(.oneShot, "failed B"))
        let completed = coordinator.enqueue(queued(.generate, "completed"))
        let cancelled = coordinator.enqueue(queued(.storyboard, "cancelled"))
        coordinator.markFailed(jobID: failedA.id, reason: frozenImageReason)
        coordinator.markFailed(jobID: failedB.id, reason: "backend failed")
        coordinator.markCompleted(jobID: completed.id, outputPath: "/tmp/kept.mp4")
        coordinator.markCancelled(jobID: cancelled.id)

        t.checkEqual(Set(coordinator.activeDisplayJobs.map(\.title)),
                     Set(["waiting", "failed A", "failed B"]),
                     "CLEARFAILED_1 before: the waiting job and both failures are shown")

        coordinator.removeFailed()

        t.checkEqual(coordinator.activeDisplayJobs.map(\.title), ["waiting"],
                     "CLEARFAILED_2 after: every failure is gone from the display")
        t.check(coordinator.job(id: failedA.id) == nil && coordinator.job(id: failedB.id) == nil,
                "CLEARFAILED_2 and from the queue records")
        t.checkEqual(coordinator.job(id: waiting.id)?.state, .waiting,
                     "CLEARFAILED_3 the waiting job is untouched")
        t.checkEqual(coordinator.job(id: completed.id)?.outputPath, "/tmp/kept.mp4",
                     "CLEARFAILED_3 a completed job keeps its output provenance")
        t.checkEqual(coordinator.job(id: cancelled.id)?.state, .cancelled,
                     "CLEARFAILED_3 a cancelled record is not a failure and is kept")
        t.checkEqual(coordinator.jobs.count, 3,
                     "CLEARFAILED_3 exactly the two failures were removed")
        t.checkEqual(started, [],
                     "CLEARFAILED_4 clearing starts nothing — no retry, no requeue")

        // A relaunch must not bring them back.
        store.flush()
        let reloaded = ProductionQueueCoordinator(store: store, restoreOnInit: true)
        t.check(!reloaded.jobs.contains { $0.state == .failed },
                "CLEARFAILED_5 cleared failures stay cleared after a relaunch")
        t.checkEqual(reloaded.jobs.count, 3,
                     "CLEARFAILED_5 and everything else survives it")

        // Nothing to clear is a no-op, not a reshuffle.
        let snapshotIDs = coordinator.jobs.map(\.id)
        coordinator.removeFailed()
        t.checkEqual(coordinator.jobs.map(\.id), snapshotIDs,
                     "CLEARFAILED_6 with no failures, Clear Failed changes nothing")

        // A running job is never a failure and must never be swept up.
        let live = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: root.appendingPathComponent("live.json")),
            restoreOnInit: false)
        live.runner = { _ in .started }
        let running = live.enqueue(queued(.autoMovie, "running"))
        let alsoFailed = live.enqueue(queued(.autoMovie, "failed"))
        live.markFailed(jobID: alsoFailed.id, reason: "r")
        t.checkEqual(live.job(id: running.id)?.state, .running,
                     "CLEARFAILED_7 fixture: one job is genuinely running")
        live.removeFailed()
        t.checkEqual(live.job(id: running.id)?.state, .running,
                     "CLEARFAILED_7 the running job survives Clear Failed")
        t.checkEqual(live.activeDisplayJobs.map(\.title), ["running"],
                     "CLEARFAILED_7 and is all that remains displayed")
    }
}
