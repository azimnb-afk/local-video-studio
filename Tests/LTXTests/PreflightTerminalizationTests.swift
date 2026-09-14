import Foundation
import Combine
@testable import LTXVideoGeneratorCore

/// Every request the renderer accepts must reach exactly one terminal outcome,
/// including when it fails before any backend is launched.
///
/// The renderer's readiness checks — Python not configured, Python environment
/// invalid, not enough disk space, model failed to load — marked the request
/// failed and returned without settling it, so the production queue never
/// heard the run end. A failed model load did not even mark it failed: the
/// request stayed pending and was picked straight back up, loading the model
/// again and again.
///
/// These drive the real `GenerationService` (and, for the queue cases, the real
/// `ProductionQueueService`) with only `GenerationPreflight` stubbed, so no
/// Python and no render is involved. Waiting spins the main run loop until a
/// condition holds, bounded by a turn count — never a fixed delay.
func runPreflightTerminalizationTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Preflight-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let params = GenerationParameters(
        numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
        numFrames: 81, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1)

    @MainActor
    func spin(maxTurns: Int = 300, until done: () -> Bool) -> Bool {
        for _ in 0..<maxTurns {
            if done() { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return done()
    }

    /// Counters for what the stubbed checks were asked to do.
    final class Calls { var ensure = 0; var load = 0 }

    enum Failure { case pythonNotConfigured, environmentInvalid, diskBlocked, modelLoad }

    func preflight(_ failure: Failure, _ calls: Calls, onEnsure: (@MainActor () -> Void)? = nil) -> GenerationPreflight {
        GenerationPreflight(
            pythonPath: { failure == .pythonNotConfigured ? nil : "/scratch/python" },
            ensurePythonReady: { _ in
                calls.ensure += 1
                if let onEnsure { await onEnsure() }
                return failure == .environmentInvalid
                    ? (false, "Python environment is missing mlx.", nil) : (true, "", nil)
            },
            configurePython: { _ in },
            loadModel: { _ in
                calls.load += 1
                if failure == .modelLoad { throw LTXError.modelLoadFailed("Model X is not prepared locally.") }
                return true
            },
            storage: { _, _ in
                failure == .diskBlocked
                    ? .critical(availableBytes: 1, requiredBytes: 10, message: "Not enough disk space for generation")
                    : .healthy(availableBytes: 1 << 40)
            })
    }

    /// A batch of `count` requests exactly as a Generate/One Shot submission
    /// stamps them.
    func batch(count: Int, attempt: Int? = nil) -> [GenerationRequest] {
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = CandidateExpander.expand(
            GenerationRequest(prompt: "p", modelId: "ltx23_distilled_q4", parameters: params), count: count)
        var requests = RunProvenanceStamper.stamp(
            ProductionJob(kind: .generate, title: "g", snapshot: snapshot)).snapshot.pendingRequests
        if let attempt { for i in requests.indices { requests[i].attemptNumber = attempt } }
        return requests
    }

    // MARK: Renderer alone

    t.suite("Preflight — a request that never reaches a backend still settles once") {
        MainActor.assumeIsolated {
            @MainActor func run(_ failure: Failure, count: Int = 1, attempt: Int? = nil,
                     onEnsure: (@MainActor (GenerationService) -> Void)? = nil)
                -> (service: GenerationService, calls: Calls, settled: [RunOutcomeRecord], requests: [GenerationRequest]) {
                let service = GenerationService(historyManager: HistoryManager(
                    rootDirectory: root.appendingPathComponent(UUID().uuidString)))
                let calls = Calls()
                service.preflight = preflight(failure, calls, onEnsure: onEnsure.map { f in { @MainActor in f(service) } })
                var settled: [RunOutcomeRecord] = []
                let sub = service.$lastRunSettlement.compactMap { $0 }.sink { settled.append($0) }
                let requests = batch(count: count, attempt: attempt)
                service.addBatch(requests)
                // Done when the renderer is idle, or when the same failure has
                // been retried — the loop this suite exists to catch.
                _ = spin { (!service.isProcessing && service.queue.isEmpty) || calls.load > count }
                if !service.queue.isEmpty { service.clearQueue() }   // never leave a spinning loop behind
                _ = spin { !service.isProcessing }
                sub.cancel()
                return (service, calls, settled, requests)
            }

            // PREFLIGHTTERM_1..4 — each early failure yields exactly one settlement.
            for (failure, label, expected) in [
                (Failure.pythonNotConfigured, "PREFLIGHTTERM_1 Python not configured", LTXError.pythonNotConfigured),
                (.environmentInvalid, "PREFLIGHTTERM_2 invalid Python environment",
                 LTXError.generationFailed("Python environment is missing mlx.")),
                (.diskBlocked, "PREFLIGHTTERM_3 disk-space preflight",
                 LTXError.generationFailed("Not enough disk space for generation")),
                (.modelLoad, "PREFLIGHTTERM_4 model load failed",
                 LTXError.modelLoadFailed("Model X is not prepared locally.")),
            ] {
                let r = run(failure)
                let mine = r.settled.filter { $0.runID == r.requests[0].id }
                t.checkEqual(mine.count, 1, "\(label): exactly one settlement")
                t.checkEqual(mine.first?.outcome, .failed, "\(label): and it is failed")
                t.checkEqual(mine.first?.failureReason, expected.localizedDescription,
                             "\(label): carrying the typed error's reason")
                t.checkEqual(r.service.error, expected, "\(label): the typed error is kept")
                t.check(r.service.queue.isEmpty, "\(label): nothing is left queued")
                t.checkEqual(r.service.currentRequest, nil, "PREFLIGHTTERM_20 \(label): no request is recorded as running")
            }

            // PREFLIGHTTERM_5 / _6 — the model-load failure is not retried by itself.
            let load = run(.modelLoad)
            t.checkEqual(load.calls.load, 1, "PREFLIGHTTERM_6 the failing model load is attempted once")
            t.check(!load.service.queue.contains { $0.id == load.requests[0].id && $0.status == .pending },
                    "PREFLIGHTTERM_5 the request does not stay pending")

            // PREFLIGHTTERM_13 — a batch-wide failure stops matching siblings.
            let wide = run(.modelLoad, count: 3)
            t.checkEqual(wide.calls.load, 1, "PREFLIGHTTERM_13 one model load for a 3-work batch")
            t.checkEqual(wide.settled.count, 3, "PREFLIGHTTERM_13 every work settles")
            t.checkEqual(wide.settled.filter { $0.notAttempted == true }.count, 2,
                         "PREFLIGHTTERM_13 the two siblings are not attempted")

            // PREFLIGHTTERM_14 — an unknown/local failure lets every work try.
            let local = run(.environmentInvalid, count: 3)
            t.checkEqual(local.calls.ensure, 3, "PREFLIGHTTERM_14 each work runs its own check")
            t.checkEqual(local.settled.filter { $0.notAttempted == true }.count, 0,
                         "PREFLIGHTTERM_14 no sibling is skipped")
            t.checkEqual(Set(local.settled.map(\.runID)), Set(local.requests.map(\.id)),
                         "PREFLIGHTTERM_14 and each settles once")
            let disk = run(.diskBlocked, count: 3)
            t.checkEqual(disk.settled.filter { $0.notAttempted == true }.count, 0,
                         "PREFLIGHTTERM_14 a disk-space failure is not treated as batch-wide")

            // PREFLIGHTTERM_17 — identity is preserved.
            let third = run(.pythonNotConfigured, attempt: 3)
            t.checkEqual(third.settled.first?.attemptNumber, 3, "PREFLIGHTTERM_17 the attempt number is kept")

            // PREFLIGHTTERM_7 — nothing reports the same run twice across the
            // batch stop, the failure and the queue cleanup.
            t.checkEqual(wide.settled.count, Set(wide.settled.map { "\($0.runID)#\($0.attemptNumber)" }).count,
                         "PREFLIGHTTERM_7 no request attempt is settled twice")

            // PREFLIGHTTERM_8 — cancelled while its checks were running: the
            // cancellation ends it, the failure does not settle it again.
            let raced = run(.environmentInvalid, onEnsure: { $0.clearQueue() })
            t.checkEqual(raced.settled.count, 0, "PREFLIGHTTERM_8 a request cancelled during preflight is not also settled failed")
            t.check(!raced.service.isProcessing, "PREFLIGHTTERM_8 and the renderer is released")

            // NO_SPIN_GUARD — after a terminal preflight failure the renderer
            // either picks a different request or goes idle; never the same one.
            let other = run(.modelLoad, count: 1)
            t.check(!other.service.isProcessing && other.calls.load == 1,
                    "NO_SPIN_GUARD the failed request is never selected again")
        }
    }

    // MARK: Through the production queue

    t.suite("Preflight — the production queue settles and moves on") {
        MainActor.assumeIsolated {
            @MainActor func harness(_ failure: Failure) -> (ProductionQueueService, ProductionQueueCoordinator, GenerationService, Calls) {
                let coordinator = ProductionQueueCoordinator(
                    store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(UUID()).json")),
                    restoreOnInit: false)
                let queue = ProductionQueueService(coordinator: coordinator)
                let service = GenerationService(historyManager: HistoryManager(
                    rootDirectory: root.appendingPathComponent(UUID().uuidString)))
                let calls = Calls()
                service.preflight = preflight(failure, calls)
                queue.attach(generationService: service)
                return (queue, coordinator, service, calls)
            }
            func requestJob(_ kind: ProductionJobKind, count: Int) -> ProductionJob {
                var snapshot = ProductionJobSnapshot()
                snapshot.pendingRequests = CandidateExpander.expand(
                    GenerationRequest(prompt: "p", modelId: "ltx23_distilled_q4", parameters: params), count: count)
                snapshot.batchCount = count
                return ProductionJob(kind: kind, title: "\(kind)", snapshot: snapshot)
            }
            func project(_ mode: String) -> FilmProject {
                var p = FilmProject(title: "pf")
                p.workflowMode = mode
                p.shots = [Shot(index: 0, title: "S", compiledPrompt: "s")]
                p.settings.modelID = "ltx23_distilled_q4"
                return p
            }
            @MainActor func settle(_ coordinator: ProductionQueueCoordinator, _ id: UUID, _ service: GenerationService,
                        _ calls: Calls) -> Bool {
                let ok = spin(maxTurns: 600) { coordinator.job(id: id)?.state.isTerminal == true || calls.load > 12 }
                if !service.queue.isEmpty { service.clearQueue() }
                return ok
            }

            // PREFLIGHTTERM_9 / _15 / _16 — Generate count 3, model not prepared.
            let (gq, gc, gs, gcalls) = harness(.modelLoad)
            let generate = gq.enqueue(requestJob(.generate, count: 3))
            let behind = gq.enqueue(ProductionJob(kind: .oneShot, title: "behind",
                                                  snapshot: requestJob(.oneShot, count: 1).snapshot))
            t.check(settle(gc, generate.id, gs, gcalls), "PREFLIGHTTERM_9 the Generate job reaches a terminal state")
            t.checkEqual(gc.job(id: generate.id)?.state, .failed, "PREFLIGHTTERM_9 as failed")
            t.checkEqual(gcalls.load <= 2, true, "PREFLIGHTTERM_6 the model load is not spun on")
            if let finished = gc.job(id: generate.id) {
                t.checkEqual(ProductionWorkPresenter.items(for: finished).map(\.state), [.failed, .notRun, .notRun],
                             "PREFLIGHTTERM_15 作品 1 失敗, 作品 2/3 未実行")
                t.checkEqual(Set(finished.snapshot.runOutcomes.map(\.runID)), Set(finished.snapshot.pendingRequests.map(\.id)),
                             "PREFLIGHTTERM_19 every outcome in the job is its own")
            }
            t.check(spin(maxTurns: 600) { gc.job(id: behind.id)?.state.isTerminal == true },
                    "PREFLIGHTTERM_16 the next job starts and settles too")
            t.checkEqual(gc.job(id: behind.id)?.snapshot.runOutcomes.map(\.runID),
                         gc.job(id: behind.id)?.snapshot.pendingRequests.map(\.id),
                         "PREFLIGHTTERM_19 the next job holds only its own outcome")
            if !gs.queue.isEmpty { gs.clearQueue() }

            // PREFLIGHTTERM_18 — Retry settles a new attempt, not the old one.
            if let retried = gc.retry(jobID: generate.id) {
                _ = gq
                t.check(settle(gc, retried.id, gs, gcalls), "PREFLIGHTTERM_18 the retry settles")
                t.check(gc.job(id: retried.id)?.snapshot.runOutcomes.allSatisfy { $0.attemptNumber == 2 } == true,
                        "PREFLIGHTTERM_18 with attempt-2 outcomes")
                t.check(gc.job(id: generate.id)?.snapshot.runOutcomes.allSatisfy { $0.attemptNumber == 1 } == true,
                        "PREFLIGHTTERM_18 and the original keeps its attempt-1 outcomes")
            } else {
                t.check(false, "PREFLIGHTTERM_18 Retry produced a job")
            }

            // PREFLIGHTTERM_10 — One Shot, an unknown/local failure: all works try, job ends.
            let (oq, oc, os, ocalls) = harness(.environmentInvalid)
            let oneShot = oq.enqueue(requestJob(.oneShot, count: 3))
            t.check(settle(oc, oneShot.id, os, ocalls), "PREFLIGHTTERM_10 the One Shot job reaches a terminal state")
            t.checkEqual(ocalls.ensure, 3, "PREFLIGHTTERM_10 every work is tried")

            // PREFLIGHTTERM_11 — Storyboard 作品数 3, model not prepared. Before,
            // the shot stayed running forever with nothing to settle it.
            let (sq, sc, ss, scalls) = harness(.modelLoad)
            let sb = sq.enqueue(try! StoryboardRunSubmission.makeJob(project: project("storyboard"),
                                                                     workCount: 3, directorMode: "direct"))
            t.check(settle(sc, sb.id, ss, scalls), "PREFLIGHTTERM_11 the Storyboard job reaches a terminal state")
            let sruns = (sc.job(id: sb.id)?.snapshot.storyboardRuns ?? []).sorted { $0.batchIndex < $1.batchIndex }
            t.checkEqual(sruns.map { $0.shotStates[0].state }, [.failed, .dependencyBlocked, .dependencyBlocked],
                         "PREFLIGHTTERM_11 work 1 fails, works 2 and 3 are stopped")
            t.check(sruns.allSatisfy { $0.shotStates.allSatisfy { $0.state != .running && $0.dispatchedRequestID == nil } },
                    "PREFLIGHTTERM_11 no shot is left running on a request that cannot settle")

            // PREFLIGHTTERM_12 — Auto Movie, unknown/local failure: every work tries, job ends.
            let (mq, mc, ms, mcalls) = harness(.environmentInvalid)
            let movie = mq.enqueue(try! MovieRunSubmission.makeJob(project: project("hybrid"),
                                                                   workCount: 2, directorMode: "direct"))
            t.check(settle(mc, movie.id, ms, mcalls), "PREFLIGHTTERM_12 the Auto Movie job reaches a terminal state")
            t.checkEqual(mcalls.ensure, 2, "PREFLIGHTTERM_12 both works are tried")
            t.check((mc.job(id: movie.id)?.snapshot.movieRuns ?? []).allSatisfy {
                $0.shotStates.allSatisfy { $0.state == .failed } },
                "PREFLIGHTTERM_12 each shot is recorded failed")
        }
    }
}
