import Foundation
@testable import LTXVideoGeneratorCore

/// A Generate / One Shot job is completed only when every work it asked for
/// completed.
///
/// When the renderer drains, the queue closes the job out: any request that
/// never settled is recorded `interrupted`. The job was then completed unless
/// the renderer still held an error (or, since 16d748c, a work had failed). A
/// work removed from the renderer queue — the × on a pending row — never
/// settles, so a count-3 job could end "completed" with two videos, or none:
/// hidden from the queue like any completed job, with no Retry for the work it
/// is missing.
///
/// Queue cases drive the real `ProductionQueueService`; the renderer's
/// readiness check is stubbed, so no render runs.
func runReleaseBlockerParentTerminalTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReleaseBlock-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func spin(maxTurns: Int = 400, until done: () -> Bool) -> Bool {
        for _ in 0..<maxTurns {
            if done() { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return done()
    }

    let params = GenerationParameters(
        numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
        numFrames: 81, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1)
    func requestJob(_ kind: ProductionJobKind, _ title: String, count: Int = 3) -> ProductionJob {
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = CandidateExpander.expand(
            GenerationRequest(prompt: title, modelId: "ltx23_distilled_q4", parameters: params), count: count)
        snapshot.batchCount = count
        return RunProvenanceStamper.stamp(ProductionJob(kind: kind, title: title, snapshot: snapshot))
    }
    func outcome(_ r: GenerationRequest, _ o: RunOutcomeRecord.Outcome, notAttempted: Bool? = nil) -> RunOutcomeRecord {
        RunOutcomeRecord(runID: r.id, outcome: o, attemptNumber: r.attemptNumber ?? 1,
                         outputPath: o == .completed ? "/tmp/\(r.id).mp4" : nil,
                         failureReason: o == .failed ? "exited with code 1" : nil, notAttempted: notAttempted)
    }
    func ends(_ job: ProductionJob, _ states: [RunOutcomeRecord.Outcome], error: String? = nil,
              notAttempted: Bool? = nil) -> String? {
        let r = job.snapshot.pendingRequests
        return RequestJobCompletion.failureReason(
            requests: r, outcomes: zip(r, states).map { outcome($0, $1, notAttempted: notAttempted) }, rendererError: error)
    }

    t.suite("RELEASEBLOCK — a request job's end follows its works") {
        for kind in [ProductionJobKind.generate, .oneShot] {
            let label = kind == .generate ? "Generate" : "One Shot"
            let job = requestJob(kind, label)
            t.checkEqual(ends(job, [.completed, .completed, .completed]), nil,
                         "RELEASEBLOCK_1 \(label): three completed works complete the job")
            t.check(ends(job, [.completed, .failed, .completed]) != nil,
                    "RELEASEBLOCK_2 \(label): a failed work fails the job")
            t.check(ends(job, [.completed, .interrupted, .completed]) != nil,
                    "RELEASEBLOCK_RED RELEASEBLOCK_3 \(label): a work that never finished does not complete the job")
            t.check(ends(job, [.completed, .cancelled, .completed]) != nil,
                    "RELEASEBLOCK_3 \(label): nor does a work cancelled on its own")
            t.check(ends(job, [.completed, .failed, .failed], notAttempted: true) != nil,
                    "RELEASEBLOCK_7 \(label): works stopped as not attempted do not complete the job")
            t.check(ends(job, [.completed, .failed, .completed], error: nil) != nil,
                    "RELEASEBLOCK_10 \(label): a cleared error alert does not change a failed work")
            t.check(ends(job, [.completed, .interrupted, .completed], error: nil) != nil,
                    "RELEASEBLOCK_10 \(label): nor a work that never finished")
        }

        // A retry is judged on its own works; siblings carried over as completed count.
        let job = requestJob(.generate, "retry")
        let r = job.snapshot.pendingRequests
        var again = r[1]; again.attemptNumber = 2
        t.checkEqual(RequestJobCompletion.failureReason(
            requests: [again], outcomes: [outcome(r[0], .completed), outcome(r[2], .completed), outcome(again, .completed)],
            rendererError: nil), nil, "RELEASEBLOCK_6 a retry whose own work completed completes")
        t.check(RequestJobCompletion.failureReason(
            requests: [again], outcomes: [outcome(r[0], .completed), outcome(r[2], .completed)], rendererError: nil) != nil,
                "RELEASEBLOCK_6 a retry whose work has no outcome of this attempt does not complete")
    }

    t.suite("RELEASEBLOCK — through the queue") {
        MainActor.assumeIsolated {
            final class Hook { var onFirstEnsure: (@MainActor (GenerationService) -> Void)? }
            @MainActor func harness(_ hook: Hook) -> (ProductionQueueService, ProductionQueueCoordinator, GenerationService) {
                let c = ProductionQueueCoordinator(
                    store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(UUID()).json")),
                    restoreOnInit: false)
                let queue = ProductionQueueService(coordinator: c,
                    assemblyLedger: AssemblyProcessLedger(fileURL: root.appendingPathComponent("\(UUID())-leases.json")))
                let service = GenerationService(historyManager: HistoryManager(
                    rootDirectory: root.appendingPathComponent(UUID().uuidString)))
                service.preflight = GenerationPreflight(
                    pythonPath: { "/scratch/python" },
                    ensurePythonReady: { [weak service] _ in
                        if let first = hook.onFirstEnsure, let service {
                            hook.onFirstEnsure = nil
                            await first(service)
                        }
                        return (false, "Python environment is missing mlx.", nil)
                    },
                    configurePython: { _ in },
                    loadModel: { _ in true },
                    storage: { _, _ in .healthy(availableBytes: 1 << 40) })
                queue.attach(generationService: service)
                return (queue, c, service)
            }

            // RELEASEBLOCK_4 / _5 / _6 — every work leaves the renderer without settling.
            for kind in [ProductionJobKind.generate, .oneShot] {
                let label = kind == .generate ? "Generate" : "One Shot"
                let hook = Hook()
                hook.onFirstEnsure = { service in
                    for request in service.queue where request.status == .pending { service.removeFromQueue(request) }
                }
                let (queue, c, service) = harness(hook)
                let job = queue.enqueue(requestJob(kind, "removed-\(label)", count: 3))
                let behind = queue.enqueue(requestJob(.oneShot, "behind-\(label)", count: 1))
                t.check(spin { c.job(id: job.id)?.state.isTerminal == true }, "RELEASEBLOCK_5 \(label): the job ends")
                let ended = c.job(id: job.id)!
                t.check(ended.snapshot.runOutcomes.allSatisfy { $0.outcome == .interrupted },
                        "RELEASEBLOCK_5 \(label) fixture: no work produced a video")
                t.checkEqual(service.error == nil, true, "RELEASEBLOCK_5 \(label) fixture: the renderer reports no error")
                t.checkEqual(ended.state, .failed,
                             "RELEASEBLOCK_RED RELEASEBLOCK_\(kind == .generate ? 5 : 4) \(label): a job missing its works is not completed")
                t.check(ended.staysVisibleWhenTerminal, "RELEASEBLOCK_5 \(label): it stays in the queue")
                t.check(ended.canRetry, "RELEASEBLOCK_6 \(label): with Retry")
                if let retried = c.retry(jobID: job.id) {
                    t.checkEqual(Set(retried.snapshot.pendingRequests.map(\.id)), Set(job.snapshot.pendingRequests.map(\.id)),
                                 "RELEASEBLOCK_6 \(label): Retry runs the works that did not finish")
                    t.checkEqual(retried.snapshot.pendingRequests.map(\.parameters.seed), job.snapshot.pendingRequests.map(\.parameters.seed),
                                 "RELEASEBLOCK_6 \(label): with their seeds")
                    t.check(retried.snapshot.pendingRequests.allSatisfy { $0.attemptNumber == 2 },
                            "RELEASEBLOCK_6 \(label): as attempt 2")
                    queue.cancel(jobID: retried.id)
                } else {
                    t.check(false, "RELEASEBLOCK_6 \(label): Retry produced a job")
                }
                t.check(spin { c.job(id: behind.id)?.state.isTerminal == true }, "RELEASEBLOCK_5 \(label): the next job still runs")

                // RELEASEBLOCK_9 — a settlement of another job cannot fill the missing work.
                let foreign = RunOutcomeRecord(runID: behind.snapshot.pendingRequests[0].id, outcome: .completed,
                                               attemptNumber: 1, outputPath: "/tmp/foreign.mp4")
                c.recordSettlement(foreign)
                t.check(c.job(id: job.id)?.snapshot.runOutcomes.contains { $0.outcome == .completed } == false,
                        "RELEASEBLOCK_9 \(label): another job's completion does not complete a missing work")
                t.checkEqual(c.job(id: job.id)?.state, .failed, "RELEASEBLOCK_9 \(label): and the job stays failed")
            }

            // RELEASEBLOCK_8 — cancelling the job is still a cancel.
            do {
                let hook = Hook()
                var jobID: UUID?
                let (queue, c, _) = harness(hook)
                hook.onFirstEnsure = { _ in if let jobID { queue.cancel(jobID: jobID) } }
                let job = queue.enqueue(requestJob(.generate, "cancelled", count: 3))
                jobID = job.id
                t.check(spin { c.job(id: job.id)?.state.isTerminal == true }, "RELEASEBLOCK_8 the cancelled job ends")
                t.checkEqual(c.job(id: job.id)?.state, .cancelled, "RELEASEBLOCK_8 a user-cancelled job stays cancelled")
            }
        }
    }
}
