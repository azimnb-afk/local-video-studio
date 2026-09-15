import Foundation
@testable import LTXVideoGeneratorCore

/// The queue, Retry and assembly fixes composed as one state machine.
///
/// Each earlier fix has its own suite. These cross them: a Retry after a
/// batch-wide stop meeting a late settlement, a crashed session's assembly
/// being reaped while the Restart's attempt runs, a cancelled render beside
/// the job queued behind it. Render outcomes are delivered as the renderer
/// publishes them (a settlement per request, applied through the same
/// coordinator and driver the app uses); preflight, assembly, cancellation
/// and the next job run through the real `ProductionQueueService`.
///
/// It also covers the project-driven assembly — Storyboard's "Assemble Final
/// Video" and a legacy film run's automatic assembly — which launched ffmpeg
/// with no controller and no lease: a quit or a crash left it running.
func runQueueRecoveryFinalAuditTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryFinal-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fm = FileManager.default
    var workDirectories: [String] = []
    defer {
        try? fm.removeItem(at: root)
        for dir in workDirectories { try? fm.removeItem(atPath: dir) }
    }

    func spin(maxTurns: Int = 400, until done: () -> Bool) -> Bool {
        for _ in 0..<maxTurns {
            if done() { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return done()
    }
    func write(_ path: String, _ text: String) {
        try? fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data(text.utf8))
    }
    func read(_ path: String) -> String? {
        fm.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
    }
    func coordinator(_ name: String, runner: Bool = true) -> ProductionQueueCoordinator {
        let q = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(name).json")),
            restoreOnInit: false)
        if runner { q.runner = { _ in .started } }
        return q
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
    func settlement(_ request: GenerationRequest, _ outcome: RunOutcomeRecord.Outcome,
                    attempt: Int? = nil) -> RunOutcomeRecord {
        RunOutcomeRecord(runID: request.id, outcome: outcome,
                         attemptNumber: attempt ?? request.attemptNumber ?? 1,
                         outputPath: outcome == .completed ? "/tmp/\(request.id).mp4" : nil,
                         failureReason: outcome == .failed ? "exited with code 1" : nil)
    }
    func project(_ mode: String, shots: Int = 1) -> FilmProject {
        var p = FilmProject(title: "RF \(mode)")
        p.workflowMode = mode
        p.settings.modelID = "ltx23_distilled_q4"
        p.shots = (0..<shots).map { Shot(index: $0, title: "S\($0)", compiledPrompt: "shot \($0)") }
        return p
    }

    // MARK: Generate / One Shot

    t.suite("RECOVERYFINAL — Generate and One Shot outcomes") {
        // RECOVERYFINAL_1 — normal completion.
        do {
            let q = coordinator("gen-ok")
            let job = q.enqueue(requestJob(.generate, "ok"))
            for r in job.snapshot.pendingRequests { q.recordSettlement(settlement(r, .completed)) }
            q.markCompleted(jobID: job.id)
            let done = q.job(id: job.id)!
            t.checkEqual(done.snapshot.runOutcomes.map(\.outcome), [.completed, .completed, .completed],
                         "RECOVERYFINAL_1 every run is recorded completed")
            let before = done
            t.checkEqual(ProductionWorkPresenter.items(for: done).map(\.state), [.completed, .completed, .completed],
                         "RECOVERYFINAL_23 per-work rows match the recorded outcomes")
            t.checkEqual(q.job(id: job.id), before, "RECOVERYFINAL_24 projecting rows does not change the job")
            t.check(q.retry(jobID: job.id) == nil, "RECOVERYFINAL_1 a completed job offers nothing to retry")
        }

        // RECOVERYFINAL_2 / _25 / _15 / _13 — work 2 fails locally, then Retry, then late events.
        do {
            let q = coordinator("gen-fail")
            let job = q.enqueue(requestJob(.generate, "fail"))
            let behind = q.enqueue(requestJob(.oneShot, "behind", count: 1))
            let r = job.snapshot.pendingRequests
            q.recordSettlement(settlement(r[0], .completed))
            q.recordSettlement(settlement(r[1], .failed))
            q.recordSettlement(settlement(r[2], .completed))
            q.recordSettlement(settlement(r[1], .failed))
            q.markFailed(jobID: job.id, reason: "exited with code 1")
            let failed = q.job(id: job.id)!
            t.checkEqual(failed.snapshot.runOutcomes.count, 3, "RECOVERYFINAL_15 a duplicate settlement is recorded once")
            t.checkEqual(ProductionWorkPresenter.items(for: failed).map(\.state), [.completed, .failed, .completed],
                         "RECOVERYFINAL_25 an unknown failure leaves its siblings to finish")
            t.checkEqual(q.activeJob?.id, behind.id, "RECOVERYFINAL_20 the job behind starts")

            // A late settlement for the failed job arrives while `behind` is active.
            q.recordSettlement(settlement(r[1], .failed))
            t.checkEqual(q.job(id: behind.id)?.snapshot.runOutcomes.count, 0,
                         "RECOVERYFINAL_13 a late settlement never lands in the active job")
            q.recordSettlement(RunOutcomeRecord(runID: UUID(), outcome: .completed, attemptNumber: 1))
            t.checkEqual(q.job(id: behind.id)?.snapshot.runOutcomes.count, 0,
                         "RECOVERYFINAL_13 nor does a settlement nobody owns")
            q.markCompleted(jobID: behind.id)

            guard let retried = q.retry(jobID: job.id) else {
                t.check(false, "RECOVERYFINAL_2 Retry produced a job"); return
            }
            t.checkEqual(retried.snapshot.pendingRequests.map(\.id), [r[1].id], "RECOVERYFINAL_2 Retry runs only the failed work")
            t.checkEqual(retried.snapshot.pendingRequests.first?.parameters.seed, r[1].parameters.seed,
                         "RECOVERYFINAL_2 with its seed")
            t.checkEqual(retried.snapshot.pendingRequests.first?.attemptNumber, 2, "RECOVERYFINAL_2 as attempt 2")
            t.checkEqual(Set(retried.snapshot.runOutcomes.map(\.runID)), [r[0].id, r[2].id],
                         "RECOVERYFINAL_7 completed siblings stay authoritative")

            // The old attempt's settlement arrives after the retry is active.
            q.recordSettlement(settlement(r[1], .completed, attempt: 1))
            t.check(q.job(id: retried.id)?.snapshot.runOutcomes.contains { $0.runID == r[1].id } == false,
                    "RECOVERYFINAL_14 attempt 1's late settlement does not settle attempt 2")
            q.recordSettlement(settlement(r[1], .completed, attempt: 2))
            t.checkEqual(q.job(id: retried.id)?.snapshot.runOutcomes.first { $0.runID == r[1].id }?.attemptNumber, 2,
                         "RECOVERYFINAL_2 attempt 2's own settlement is recorded")
            t.checkEqual(q.job(id: job.id)?.state, .failed, "RECOVERYFINAL_3 the original is not resurrected")
        }
    }

    // RECOVERYFINAL_26 — how a drained Generate / One Shot job ends.
    t.suite("RECOVERYFINAL — a drained request job ends from its outcomes") {
        let job = requestJob(.generate, "ends", count: 3)
        let r = job.snapshot.pendingRequests
        func outcomes(_ states: [RunOutcomeRecord.Outcome], attempt: Int = 1) -> [RunOutcomeRecord] {
            zip(r, states).map { settlement($0, $1, attempt: attempt) }
        }
        t.checkEqual(RequestJobCompletion.failureReason(
            requests: r, outcomes: outcomes([.completed, .completed, .completed]), rendererError: nil), nil,
                     "RECOVERYFINAL_26 every work completed: the job completes")
        t.check(RequestJobCompletion.failureReason(
            requests: r, outcomes: outcomes([.completed, .failed, .completed]), rendererError: "boom") != nil,
                "RECOVERYFINAL_26 a failure the renderer still reports fails the job")

        // Work 2 failed; the user dismissed the error alert (which clears the
        // renderer's error) while works 1 and 3 went on to finish.
        let dismissed = RequestJobCompletion.failureReason(
            requests: r, outcomes: outcomes([.completed, .failed, .completed]), rendererError: nil)
        t.check(dismissed != nil,
                "RECOVERYFINAL_RED RECOVERYFINAL_26 a failed work fails the job even after its error alert was dismissed")
        t.checkEqual(dismissed, "exited with code 1", "RECOVERYFINAL_26 with that work's own reason")

        // Only this attempt's own outcomes count.
        var retried = r
        for i in retried.indices { retried[i].attemptNumber = 2 }
        let stale = [settlement(r[1], .failed, attempt: 1)] + [settlement(retried[0], .completed, attempt: 2),
                     settlement(retried[1], .completed, attempt: 2), settlement(retried[2], .completed, attempt: 2)]
        t.checkEqual(RequestJobCompletion.failureReason(requests: retried, outcomes: Array(stale.dropFirst()), rendererError: nil), nil,
                     "RECOVERYFINAL_26 a retry whose works all completed completes")
        t.checkEqual(RequestJobCompletion.failureReason(
            requests: [retried[1]], outcomes: [settlement(r[1], .failed, attempt: 1)], rendererError: nil), nil,
                     "RECOVERYFINAL_26 an earlier attempt's failure does not fail the retry")

        // Unchanged: a work closed out as interrupted (never settled) does not
        // by itself fail a job the renderer reports no error for.
        t.checkEqual(RequestJobCompletion.failureReason(
            requests: r, outcomes: outcomes([.completed, .interrupted, .completed]), rendererError: nil), nil,
                     "RECOVERYFINAL_26 an interrupted close-out keeps its existing meaning")

        // Once failed, it is visible and retryable.
        var ended = job
        ended.state = .failed
        ended.snapshot.runOutcomes = outcomes([.completed, .failed, .completed])
        t.check(ended.staysVisibleWhenTerminal && ended.canRetry,
                "RECOVERYFINAL_26 so the failed work stays visible with Retry")
    }

    t.suite("RECOVERYFINAL — preflight through the queue") {
        MainActor.assumeIsolated {
            final class Calls { var ensure = 0; var load = 0 }
            @MainActor func harness(modelLoad: Bool, onEnsure: (@MainActor (ProductionQueueService) -> Void)? = nil)
                -> (ProductionQueueService, ProductionQueueCoordinator, GenerationService, Calls) {
                let c = coordinator("pf-\(UUID())", runner: false)
                let queue = ProductionQueueService(coordinator: c,
                    assemblyLedger: AssemblyProcessLedger(fileURL: root.appendingPathComponent("\(UUID())-leases.json")))
                let service = GenerationService(historyManager: HistoryManager(
                    rootDirectory: root.appendingPathComponent(UUID().uuidString)))
                let calls = Calls()
                service.preflight = GenerationPreflight(
                    pythonPath: { "/scratch/python" },
                    ensurePythonReady: { _ in
                        calls.ensure += 1
                        if let onEnsure { await onEnsure(queue) }
                        return modelLoad ? (true, "", nil) : (false, "Python environment is missing mlx.", nil)
                    },
                    configurePython: { _ in },
                    loadModel: { _ in
                        calls.load += 1
                        throw LTXError.modelLoadFailed("Model X is not prepared locally.")
                    },
                    storage: { _, _ in .healthy(availableBytes: 1 << 40) })
                queue.attach(generationService: service)
                return (queue, c, service, calls)
            }

            // RECOVERYFINAL_3 / _17 / _18 / _20 — One Shot count 3, model not prepared.
            do {
                let (queue, c, _, calls) = harness(modelLoad: true)
                let job = queue.enqueue(requestJob(.oneShot, "load"))
                let behind = queue.enqueue(requestJob(.oneShot, "behind", count: 1))
                t.check(spin { c.job(id: behind.id)?.state.isTerminal == true },
                        "RECOVERYFINAL_20 both jobs end and the queue moves on")
                let ended = c.job(id: job.id)!
                t.checkEqual(ended.state, .failed, "RECOVERYFINAL_3 One Shot fails")
                t.checkEqual(ProductionWorkPresenter.items(for: ended).map(\.state), [.failed, .notRun, .notRun],
                             "RECOVERYFINAL_18 the batch-wide failure stops the siblings")
                t.checkEqual(ended.snapshot.runOutcomes.count, 3, "RECOVERYFINAL_17 each request settles exactly once")
                t.check(calls.load <= 2, "RECOVERYFINAL_18 the model load is not spun on")
            }

            // RECOVERYFINAL_26 — through the queue: work 1 fails, the user dismisses
            // the error alert, and work 2 leaves the renderer without failing.
            do {
                let c = coordinator("dismissed-\(UUID())", runner: false)
                let queue = ProductionQueueService(coordinator: c,
                    assemblyLedger: AssemblyProcessLedger(fileURL: root.appendingPathComponent("\(UUID())-leases.json")))
                let service = GenerationService(historyManager: HistoryManager(
                    rootDirectory: root.appendingPathComponent(UUID().uuidString)))
                final class Count { var ensure = 0 }
                let count = Count()
                service.preflight = GenerationPreflight(
                    pythonPath: { "/scratch/python" },
                    ensurePythonReady: { [weak service] _ in
                        count.ensure += 1
                        if count.ensure == 2 {
                            await MainActor.run {
                                service?.clearError()   // the alert's OK
                                service?.clearQueue()   // work 2 leaves the renderer
                            }
                        }
                        return (false, "Python environment is missing mlx.", nil)
                    },
                    configurePython: { _ in },
                    loadModel: { _ in true },
                    storage: { _, _ in .healthy(availableBytes: 1 << 40) })
                queue.attach(generationService: service)
                let job = queue.enqueue(requestJob(.generate, "dismissed", count: 2))
                t.check(spin { c.job(id: job.id)?.state.isTerminal == true }, "RECOVERYFINAL_26 the job ends")
                let ended = c.job(id: job.id)
                t.check(ended?.snapshot.runOutcomes.contains { $0.outcome == .failed } == true,
                        "RECOVERYFINAL_26 fixture: work 1's failure is recorded")
                t.checkEqual(service.error == nil, true, "RECOVERYFINAL_26 fixture: the renderer error was dismissed")
                t.checkEqual(ended?.state, .failed,
                             "RECOVERYFINAL_RED RECOVERYFINAL_26 a job with a failed work is not reported completed")
                t.check(ended?.staysVisibleWhenTerminal == true && ended?.canRetry == true,
                        "RECOVERYFINAL_26 and stays visible with Retry")
            }

            // RECOVERYFINAL_8 — cancelled while its checks run; the job behind runs.
            do {
                var cancelled: UUID?
                let (queue, c, _, _) = harness(modelLoad: false, onEnsure: { q in
                    if let id = cancelled { q.cancel(jobID: id); cancelled = nil }
                })
                let job = queue.enqueue(requestJob(.generate, "cancel", count: 2))
                cancelled = job.id
                let behind = queue.enqueue(requestJob(.oneShot, "after-cancel", count: 1))
                t.check(spin { c.job(id: behind.id)?.state.isTerminal == true }, "RECOVERYFINAL_8 the job behind the cancel runs")
                t.checkEqual(c.job(id: job.id)?.state, .cancelled, "RECOVERYFINAL_8 the cancelled job stays cancelled")
                t.check(c.job(id: job.id)?.snapshot.runOutcomes.allSatisfy { $0.outcome != .completed } == true,
                        "RECOVERYFINAL_17 nothing of the cancelled job is reported completed")
            }
        }
    }

    // MARK: Storyboard / Auto Movie

    /// Three works, work 1 finished, work 2 dispatched.
    func dispatchedWork2<Run: RunScopedShotExecution>(_ runs: [Run]) -> (runs: [Run], request: UUID) {
        var runs = runs
        StoryboardRunScheduler.recordCompletion(
            in: &runs[0], shotID: runs[0].orderedShots[0].id, takeID: UUID(), outputPath: "/tmp/work1.mp4")
        let request = UUID()
        runs[1].update(runs[1].orderedShots[0].id) {
            $0.state = .running; $0.dispatchedRequestID = request; $0.dispatchedTakeID = UUID()
        }
        return (runs, request)
    }

    func batchMatrix<Run: RunScopedShotExecution>(_ label: String, _ make: () -> [Run]) {
        let failure = RunOutcomeRecord(runID: UUID(), outcome: .failed, attemptNumber: 1,
                                       failureReason: "Model X is not prepared locally.")
        // C / RECOVERYFINAL_4 / _6 — work 2 fails locally after work 1: work 3 still runs.
        var local = dispatchedWork2(make())
        var failedLocal = failure; failedLocal.runID = local.request
        local.runs = StoryboardRunDriver.applySettlement(failedLocal, to: local.runs)!
        RunScopedDispatchDriver.stopUnstartedRunsAfterFailure(
            &local.runs, settlement: failedLocal, dispatchedIn: 1, error: .generationFailed("exited with code 1"))
        t.checkEqual(local.runs.map { $0.shotStates[0].state }, [.completed, .failed, .queued],
                     "RECOVERYFINAL_\(label == "Storyboard" ? 4 : 6) \(label): a local failure leaves work 3 to run")
        t.checkEqual(StoryboardRunDriver.nextDispatch(in: local.runs)?.runIndex, 2,
                     "RECOVERYFINAL_\(label == "Storyboard" ? 4 : 6) \(label): and work 3 is dispatched next")

        // E / RECOVERYFINAL_5 / _7 — work 2 fails deterministically: work 3 is not attempted, work 1 kept.
        var det = dispatchedWork2(make())
        var failedDet = failure; failedDet.runID = det.request
        det.runs = StoryboardRunDriver.applySettlement(failedDet, to: det.runs)!
        RunScopedDispatchDriver.stopUnstartedRunsAfterFailure(
            &det.runs, settlement: failedDet, dispatchedIn: 1, error: .modelLoadFailed("Model X is not prepared locally."))
        t.checkEqual(det.runs.map { $0.shotStates[0].state }, [.completed, .failed, .dependencyBlocked],
                     "RECOVERYFINAL_\(label == "Storyboard" ? 5 : 7) \(label): a batch-wide failure stops only unstarted work")
        t.checkEqual(det.runs[2].shotStates[0].notAttempted, true,
                     "RECOVERYFINAL_\(label == "Storyboard" ? 5 : 7) \(label): marked not attempted")
        t.checkEqual(det.runs[0].shotStates[0].state, .completed, "RECOVERYFINAL_7 \(label): the finished work stays completed")
        t.check(StoryboardRunDriver.nextDispatch(in: det.runs) == nil, "RECOVERYFINAL_19 \(label): nothing further is dispatched")

        // RECOVERYFINAL_15 — the same settlement again finds no running shot.
        t.check(StoryboardRunDriver.applySettlement(failedDet, to: det.runs) == nil,
                "RECOVERYFINAL_15 \(label): a duplicate settlement applies to nothing")
    }

    t.suite("RECOVERYFINAL — run-scoped batch matrix") {
        batchMatrix("Storyboard") {
            try! StoryboardRunSubmission.makeJob(project: project("storyboard"), workCount: 3, directorMode: "direct")
                .snapshot.storyboardRuns
        }
        batchMatrix("Auto Movie") {
            try! MovieRunSubmission.makeJob(project: project("hybrid"), workCount: 3, directorMode: "direct")
                .snapshot.movieRuns
        }

        // RECOVERYFINAL_19 — adversarial snapshots never read as "still running".
        let sb = try! StoryboardRunSubmission.makeJob(project: project("storyboard", shots: 2), workCount: 1, directorMode: "direct")
        var impossible = sb.snapshot.storyboardRuns
        impossible[0].update(impossible[0].orderedShots[0].id) { $0.state = .failed }
        impossible[0].update(impossible[0].orderedShots[1].id) { $0.state = .waitingForDependency }
        if case .noShotToDispatch(let runs) = RunScopedDispatchDriver.nextShot(
            in: impossible, takeID: UUID(), makeRequest: { _, _, _ in nil },
            classifyRefusal: { run, shot in RunDispatchRefusal.classify(run: run, shotID: shot) }) {
            t.check([.stalled, .settled(allCompleted: false)].contains(RunScopedDispatchDriver.storyboardCompletion(runs)),
                    "RECOVERYFINAL_19 unfinished work with nothing to dispatch ends the job")
        } else {
            t.check(false, "RECOVERYFINAL_19 unfinished work with nothing to dispatch ends the job")
        }
        var cancelledRun = sb.snapshot.storyboardRuns
        StoryboardRunScheduler.cancel(&cancelledRun[0])
        t.checkEqual(RunScopedDispatchDriver.storyboardCompletion(cancelledRun), .settled(allCompleted: false),
                     "RECOVERYFINAL_19 a cancelled run with cancelled shots is settled")
        var allDone = sb.snapshot.storyboardRuns
        for shot in allDone[0].orderedShots {
            StoryboardRunScheduler.recordCompletion(in: &allDone[0], shotID: shot.id, takeID: UUID(), outputPath: "/tmp/x.mp4")
        }
        t.checkEqual(RunScopedDispatchDriver.storyboardCompletion(allDone), .settled(allCompleted: true),
                     "RECOVERYFINAL_19 a job whose children are all terminal is settled")
        var movie = try! MovieRunSubmission.makeJob(project: project("hybrid"), workCount: 1, directorMode: "direct").snapshot.movieRuns
        StoryboardRunScheduler.recordCompletion(in: &movie[0], shotID: movie[0].orderedShots[0].id, takeID: UUID(), outputPath: "/tmp/y.mp4")
        movie[0].assembly.state = .cancelled
        t.checkEqual(RunScopedDispatchDriver.movieCompletion(movie), .stalled,
                     "RECOVERYFINAL_19 an assembly left cancelled with nothing running is stalled, not awaited")
    }

    // MARK: Assembly, app exit, crash and Restart composed

    t.suite("RECOVERYFINAL — crash, reap and Restart of one assembly") {
        MainActor.assumeIsolated {
            let storeA = root.appendingPathComponent("crash-A.json")
            let leases = AssemblyProcessLedger(fileURL: root.appendingPathComponent("crash-leases.json"))
            let clip = root.appendingPathComponent("crash-clip.mp4").path
            write(clip, "clip")

            // Session A: attempt 1 assembling through a real process.
            let a = ProductionQueueCoordinator(store: ProductionQueueStore(fileURL: storeA), restoreOnInit: false)
            let queueA = ProductionQueueService(coordinator: a, assemblyLedger: leases)
            final class Box: @unchecked Sendable {
                var controller: AssemblyProcessController?; var work = ""; var candidate = ""; var release2 = false
            }
            let box = Box()
            queueA.assembleOverride = { _, _, candidate, controller in
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ltx-run-assembly-\(UUID().uuidString)").path
                try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: work + "/concat.txt", contents: Data())
                FileManager.default.createFile(atPath: candidate, contents: Data("attempt 1 partial".utf8))
                box.work = work; box.candidate = candidate; box.controller = controller
                controller.noteWorkDirectory(work)
                try FinalAssemblyService.runFFmpeg(["-f", work + "/concat.txt"], ffmpeg: "/usr/bin/tail", controller: controller)
            }
            queueA.attach(generationService: GenerationService(historyManager: HistoryManager(
                rootDirectory: root.appendingPathComponent(UUID().uuidString))))
            var job = try! MovieRunSubmission.makeJob(project: project("hybrid"), workCount: 1, directorMode: "direct")
            StoryboardRunScheduler.recordCompletion(
                in: &job.snapshot.movieRuns[0], shotID: job.snapshot.movieRuns[0].orderedShots[0].id,
                takeID: UUID(), outputPath: clip)
            let original = queueA.enqueue(job)
            t.check(spin { box.controller?.hasRunningProcess == true }, "RECOVERYFINAL_11 attempt 1's process is running")
            workDirectories.append(box.work)
            // Wait for session A's queue file to say what a crash would leave.
            t.check(spin {
                ProductionQueueStore(fileURL: storeA).load().first { $0.id == original.id }?
                    .snapshot.movieRuns.first?.assembly.state == .running
            }, "RECOVERYFINAL_11 the running assembly is persisted")

            // "Crash": session B restores the persisted queue; A's process is still alive.
            let storeB = root.appendingPathComponent("crash-B.json")
            try? fm.copyItem(at: storeA, to: storeB)
            let b = ProductionQueueCoordinator(store: ProductionQueueStore(fileURL: storeB), restoreOnInit: true)
            t.checkEqual(b.job(id: original.id)?.state, .interrupted, "RECOVERYFINAL_12 the job is restored interrupted")
            t.checkEqual(b.job(id: original.id)?.snapshot.movieRuns[0].assembly.state, .running,
                         "RECOVERYFINAL_15 the persisted assembly still reads running")
            t.check(!b.acceptsAssemblyResult(jobID: original.id, runID: job.snapshot.movieRuns[0].id, attempt: 1),
                    "RECOVERYFINAL_15 which is not taken as live execution")

            let queueB = ProductionQueueService(coordinator: b, assemblyLedger: leases)
            final class Held: @unchecked Sendable { var started = false; var released = false }
            let held = Held()
            queueB.assembleOverride = { _, _, candidate, controller in
                held.started = true
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline, !held.released, !controller.isCancelled { usleep(1000) }
                try controller.checkNotCancelled()
                FileManager.default.createFile(atPath: candidate, contents: Data("attempt 2".utf8))
            }
            queueB.attach(generationService: GenerationService(historyManager: HistoryManager(
                rootDirectory: root.appendingPathComponent(UUID().uuidString))))

            // RECOVERYFINAL_12 — Restart first, so attempt 2 is running during the reap.
            guard let restarted = b.retry(jobID: original.id) else {
                t.check(false, "RECOVERYFINAL_12 Restart produced a job"); return
            }
            t.check(spin { held.started }, "RECOVERYFINAL_12 attempt 2 starts without waiting on attempt 1")

            // RECOVERYFINAL_11 — the launch-time reap, as a later app instance.
            final class Outcomes: @unchecked Sendable { var value: [(AssemblyProcessLease, AssemblyOrphanReaper.Outcome)]? }
            let outcomes = Outcomes()
            let later = UUID()
            Task { outcomes.value = await queueB.reapOrphanedAssemblies(currentAppInstanceID: later).map { ($0.lease, $0.outcome) } }
            t.check(spin { outcomes.value != nil }, "RECOVERYFINAL_11 the reap finishes")
            let byAttempt = Dictionary((outcomes.value ?? []).map { ($0.0.attempt, $0.1) }, uniquingKeysWith: { a, _ in a })
            t.checkEqual(byAttempt[1], .terminated, "RECOVERYFINAL_11 attempt 1's verified orphan is ended")
            t.checkEqual(byAttempt[2], .active, "RECOVERYFINAL_21 attempt 2, running now, is left alone")
            t.check(spin { box.controller?.hasRunningProcess == false }, "RECOVERYFINAL_11 attempt 1's process exits")
            t.check(!fm.fileExists(atPath: box.work), "RECOVERYFINAL_11 its work directory is removed")
            t.check(held.started && !held.released, "RECOVERYFINAL_21 attempt 2 is still running")

            held.released = true
            t.check(spin { b.job(id: restarted.id)?.state == .completed }, "RECOVERYFINAL_12 attempt 2 completes")
            let final = MovieAssemblyDriver.outputURL(runID: job.snapshot.movieRuns[0].id).path
            t.checkEqual(read(final), "attempt 2", "RECOVERYFINAL_22 the adopted film is attempt 2's")
            t.check(!fm.fileExists(atPath: box.candidate), "RECOVERYFINAL_21 attempt 1's candidate is gone")
            t.checkEqual(b.job(id: original.id)?.state, .interrupted, "RECOVERYFINAL_14 the original stays interrupted")

            // Session A's attempt finally reports — into its own, now-stale, coordinator.
            _ = spin { queueA.assemblyAttempts.isEmpty }
            t.checkEqual(read(final), "attempt 2", "RECOVERYFINAL_22 attempt 1's late result does not touch the adopted film")
            t.check(!b.applyAssemblyResult(jobID: restarted.id, runID: job.snapshot.movieRuns[0].id, attempt: 1,
                                          result: .completed(outputPath: box.candidate)),
                    "RECOVERYFINAL_14 an attempt-1 result cannot settle the restarted job")
            t.check(!b.applyAssemblyResult(jobID: restarted.id, runID: job.snapshot.movieRuns[0].id, attempt: 2,
                                          result: .completed(outputPath: final)),
                    "RECOVERYFINAL_16 a duplicate completion for attempt 2 is refused")
            t.check(leases.leases().isEmpty, "RECOVERYFINAL_11 no lease is left")

            // RECOVERYFINAL_9 / _10 / _20 — cancel, then quit, during later assemblies; the queue keeps moving.
            held.released = false; held.started = false
            var next = job
            next.id = UUID()
            next.snapshot.movieRuns = try! MovieRunSubmission.makeJob(project: project("hybrid"), workCount: 1, directorMode: "direct").snapshot.movieRuns
            StoryboardRunScheduler.recordCompletion(
                in: &next.snapshot.movieRuns[0], shotID: next.snapshot.movieRuns[0].orderedShots[0].id,
                takeID: UUID(), outputPath: clip)
            let cancelMe = queueB.enqueue(next)
            t.check(spin { held.started }, "RECOVERYFINAL_9 the next assembly starts")
            queueB.cancel(jobID: cancelMe.id)
            t.check(spin { queueB.assemblyAttempts.isEmpty }, "RECOVERYFINAL_9 cancelling stops it")
            t.checkEqual(b.job(id: cancelMe.id)?.state, .cancelled, "RECOVERYFINAL_9 and the job stays cancelled")

            held.started = false
            var another = next
            another.id = UUID()
            another.snapshot.movieRuns = try! MovieRunSubmission.makeJob(project: project("hybrid"), workCount: 1, directorMode: "direct").snapshot.movieRuns
            StoryboardRunScheduler.recordCompletion(
                in: &another.snapshot.movieRuns[0], shotID: another.snapshot.movieRuns[0].orderedShots[0].id,
                takeID: UUID(), outputPath: clip)
            _ = queueB.enqueue(another)
            t.check(spin { held.started }, "RECOVERYFINAL_20 the job after a cancel runs")
            t.check(queueB.stopAssembliesForAppExit(timeout: 3), "RECOVERYFINAL_10 a quit stops the running assembly")
            t.check(leases.leases().isEmpty, "RECOVERYFINAL_10 and leaves no lease")
            _ = spin { queueB.assemblyAttempts.isEmpty }
            t.check(fm.fileExists(atPath: clip), "RECOVERYFINAL_22 the source clip survives all of it")
        }
    }

    // MARK: Project-driven assembly

    t.suite("RECOVERYFINAL — project-driven assembly is owned like a run's") {
        guard let ffmpeg = FinalAssemblyService.ffmpegPath() else {
            t.check(true, "ffmpeg unavailable — project-driven assembly checks skipped"); return
        }
        // Two clips of different sizes force the re-encoding path, and a long
        // first clip keeps it busy long enough to observe.
        func makeClip(_ name: String, size: String, seconds: Int) -> String? {
            let path = root.appendingPathComponent(name).path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-y", "-f", "lavfi", "-i", "testsrc=size=\(size):rate=30", "-t", "\(seconds)",
                           "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", path]
            p.standardOutput = Pipe(); p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            return p.terminationStatus == 0 ? path : nil
        }
        guard let long = makeClip("long.mp4", size: "1280x720", seconds: 120),
              let short = makeClip("short.mp4", size: "640x360", seconds: 1) else {
            t.check(false, "LEGACYASM fixture clips could not be made"); return
        }
        var film = FilmProject(title: "legacy")
        for (i, path) in [long, short].enumerated() {
            var shot = Shot(index: i, title: "S\(i)", summary: "x")
            var take = Take(shotID: shot.id, modelID: "m", seed: i, promptSnapshot: "p",
                            settingsSnapshot: .default, requestedWidth: 1280, requestedHeight: 720,
                            fps: 30, requestedDuration: 1, status: .completed)
            take.outputPath = path
            shot.takes = [take]
            shot.selectedTakeID = take.id
            film.shots.append(shot)
        }
        film.settings.width = 1280
        film.settings.height = 720
        let output = root.appendingPathComponent("\(film.id.uuidString)_final.mp4").path
        write(output, "previous final movie")

        final class Result: @unchecked Sendable { var error: Error?; var done = false; var finishedAt = Date.distantFuture }
        let result = Result()
        Thread.detachNewThread {
            do { _ = try FinalAssemblyService.assembleTracked(project: film, outputPath: output) }
            catch { result.error = error }
            result.finishedAt = Date()
            result.done = true
        }
        func lease() -> AssemblyProcessLease? {
            AssemblyProcessLedger.shared.leases().first { $0.jobID == film.id && $0.pid != nil }
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, lease() == nil, !result.done { usleep(20_000) }
        let recorded = lease()
        t.check(recorded != nil, "LEGACYASM_RED the project-driven assembly's ffmpeg is recorded with a lease")
        if let recorded, let pid = recorded.pid, case .identity(let live) = LiveProcessInspector().inspect(pid: pid) {
            t.check(AssemblyOrphanReaper.isVerified(live, for: recorded),
                    "LEGACYASM_1 its process can be proven from the lease")
            t.check(recorded.workDirectoryPath.map(AssemblyOrphanReaper.isAssemblyWorkDirectory) == true,
                    "LEGACYASM_1 naming its own work directory")
            t.checkEqual(recorded.candidatePath, output, "LEGACYASM_1 the only file it names is the project's final movie")
        }

        let stopAt = Date()
        let stopped = MainActor.assumeIsolated {
            ProductionQueueService(coordinator: coordinator("legacy-exit", runner: false),
                                   assemblyLedger: AssemblyProcessLedger(fileURL: root.appendingPathComponent("legacy-exit.json")))
                .stopAssembliesForAppExit(timeout: 3)
        }
        let waitUntil = Date().addingTimeInterval(4)
        while Date() < waitUntil, !result.done { usleep(20_000) }
        t.check(recorded != nil && stopped && result.done && result.finishedAt.timeIntervalSince(stopAt) < 3.5,
                "LEGACYASM_RED a quit stops the project-driven assembly while it is running")
        var cancelled = false
        if case .cancelled? = result.error as? FinalAssemblyService.AssemblyError { cancelled = true }
        t.check(cancelled, "LEGACYASM_2 it ends as cancelled")
        t.checkEqual(read(output), "previous final movie", "LEGACYASM_3 the existing final movie is untouched")
        t.check(AssemblyProcessLedger.shared.leases().allSatisfy { $0.jobID != film.id }, "LEGACYASM_2 and no lease is left")

        // Whatever happened, wait for it before leaving.
        let cleanup = Date().addingTimeInterval(90)
        while Date() < cleanup, !result.done { usleep(50_000) }

        // LEGACYASM_4 — a crashed session's project-driven lease is reaped like a run's,
        // and the final movie it names is never removed.
        let work = fm.temporaryDirectory.appendingPathComponent("ltx-assembly-\(UUID().uuidString)").path
        try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        workDirectories.append(work)
        var crashed = AssemblyProcessLease(jobID: film.id, runID: UUID(), attempt: 1, ownerAppInstanceID: UUID(),
                                           candidatePath: output, outputPath: output)
        crashed.workDirectoryPath = work
        crashed.pid = nil
        let ledger = AssemblyProcessLedger(fileURL: root.appendingPathComponent("legacy-crash.json"))
        ledger.upsert(crashed)
        let outcome = AssemblyOrphanReaper.reconcile(ledger: ledger, isActive: { _ in false }).map(\.outcome)
        t.checkEqual(outcome, [.noProcess], "LEGACYASM_4 a crashed project-driven attempt is reconciled")
        t.check(!fm.fileExists(atPath: work), "LEGACYASM_4 its work directory is removed")
        t.checkEqual(read(output), "previous final movie", "LEGACYASM_4 the final movie it names is kept")
        let lookalike = fm.temporaryDirectory.appendingPathComponent("ltx-assemblyX-\(UUID().uuidString)").path
        try? fm.createDirectory(atPath: lookalike, withIntermediateDirectories: true)
        workDirectories.append(lookalike)
        t.check(!AssemblyOrphanReaper.isAssemblyWorkDirectory(lookalike),
                "LEGACYASM_4 a similarly named directory is not an assembly work directory")
    }
}
