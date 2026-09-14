import Foundation
@testable import LTXVideoGeneratorCore

/// Which work of a multi-work job succeeded, failed, stopped or is still going.
///
/// Before this, a job of 作品数 N rendered as one state and one reason: a real
/// three-work Auto Movie with only work 2 failed showed "Failed" and a single
/// sentence, which reads as all three having failed. These pin the per-work
/// projection the queue row is handed, built through the production submission
/// paths for all four surfaces.
func runPerWorkQueueDisplayTests(_ t: TestKit) {

    typealias S = ProductionWorkDisplayItem.State

    func states(_ items: [ProductionWorkDisplayItem]) -> [S] { items.map(\.state) }

    func base() -> GenerationRequest {
        GenerationRequest(
            prompt: "p",
            parameters: GenerationParameters(
                numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
                numFrames: 81, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1))
    }

    /// Generate / One Shot count=N exactly as submitted: expanded, then stamped.
    func requestJob(_ kind: ProductionJobKind, count: Int) -> ProductionJob {
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = CandidateExpander.expand(base(), count: count)
        snapshot.batchCount = count
        return RunProvenanceStamper.stamp(
            ProductionJob(kind: kind, title: "\(kind) × \(count)", snapshot: snapshot))
    }

    func record(_ job: inout ProductionJob, _ index: Int, _ outcome: RunOutcomeRecord.Outcome,
                reason: String? = nil, output: String? = nil) {
        let request = job.snapshot.pendingRequests.first { $0.batchIndex == index }!
        job.snapshot.runOutcomes.append(RunOutcomeRecord(
            runID: request.id, outcome: outcome, attemptNumber: 1,
            outputPath: output, failureReason: reason))
    }

    func project(_ mode: String, shots: Int = 1) -> FilmProject {
        var p = FilmProject(title: "works")
        p.workflowMode = mode
        p.shots = (0..<shots).map { Shot(index: $0, title: "S\($0)", compiledPrompt: "s\($0)") }
        return p
    }

    func movieJob(count: Int) -> ProductionJob {
        try! MovieRunSubmission.makeJob(project: project("hybrid"), workCount: count, directorMode: "direct")
    }

    func storyboardJob(count: Int) -> ProductionJob {
        try! StoryboardRunSubmission.makeJob(project: project("storyboard"), workCount: count, directorMode: "direct")
    }

    func completeMovie(_ job: inout ProductionJob, _ i: Int) {
        let sid = job.snapshot.movieRuns[i].orderedShots[0].id
        job.snapshot.movieRuns[i].update(sid) { $0.state = .completed; $0.outputPath = "/tmp/shot-\(i).mp4" }
        job.snapshot.movieRuns[i].assembly.state = .completed
        job.snapshot.movieRuns[i].assembly.outputPath = "/tmp/film-\(i).mp4"
    }

    func failMovie(_ job: inout ProductionJob, _ i: Int, _ reason: String) {
        let sid = job.snapshot.movieRuns[i].orderedShots[0].id
        job.snapshot.movieRuns[i].update(sid) { $0.state = .failed; $0.failureReason = reason }
    }

    let privateReason = #"Generation failed: ltx-2-mlx exited with code 1. File "/Users/alice/Library/Application Support/x/cli.py", line 810"#
    let frozenReason = "開始画像が見つかりません（opening.png）。キュー追加後に移動または削除された可能性があります。選び直してください。"

    t.suite("Multi-work queue — which work did what") {

        // PERWORKUI_1 — a single work keeps today's row: no breakdown at all.
        t.checkEqual(ProductionWorkPresenter.items(for: movieJob(count: 1)), [],
                     "PERWORKUI_1 Auto Movie 作品数 1 gains no per-work rows")
        t.checkEqual(ProductionWorkPresenter.items(for: storyboardJob(count: 1)), [],
                     "PERWORKUI_1 Storyboard 作品数 1 gains none")
        t.checkEqual(ProductionWorkPresenter.items(for: requestJob(.generate, count: 1)), [],
                     "PERWORKUI_1 Generate count 1 gains none")

        // PERWORKUI_2 — all completed.
        var allDone = movieJob(count: 3)
        (0..<3).forEach { completeMovie(&allDone, $0) }
        allDone.state = .completed
        t.checkEqual(states(ProductionWorkPresenter.items(for: allDone)),
                     [.completed, .completed, .completed],
                     "PERWORKUI_2 three completed works")

        // PERWORKUI_3 / _4 / _5 / _6 / _19 — the reported shape: only work 2 failed.
        var partial = movieJob(count: 3)
        completeMovie(&partial, 0)
        failMovie(&partial, 1, frozenReason)
        completeMovie(&partial, 2)
        partial.state = .failed
        partial.failureReason = RunFailureSummary.reason(
            shotStates: partial.snapshot.movieRuns.flatMap(\.shotStates), fallback: "x")
        let partialItems = ProductionWorkPresenter.items(for: partial)
        t.checkEqual(states(partialItems), [.completed, .failed, .completed],
                     "PERWORKUI_3 only work 2 is marked failed")
        t.checkEqual(partialItems.map(\.failureReason), [nil, frozenReason, nil],
                     "PERWORKUI_4 the reason is attached to work 2 only")
        t.check(partialItems[0].state == .completed && partialItems[2].state == .completed,
                "PERWORKUI_5 successful siblings stay completed")
        t.checkEqual(partial.state, .failed, "PERWORKUI_6 fixture: the parent is failed")
        t.check(!partialItems.contains { $0.state == .failed && $0.index != 1 },
                "PERWORKUI_6 the failed parent does not overwrite completed works")
        t.checkEqual(partialItems.map(\.hasOutput), [true, false, true],
                     "PERWORKUI_19 completed works keep their output despite the sibling failure")
        t.check(ProductionWorkPresenter.parentReasonIsCoveredByWorks(partial, items: partialItems),
                "PERWORKUI_4 the parent reason is not printed again above the works")

        // PERWORKUI_7 / _8 — failed, interrupted and cancelled stay distinct.
        var interruptedJob = requestJob(.oneShot, count: 3)
        record(&interruptedJob, 0, .completed, output: "/tmp/a.mp4")
        interruptedJob.state = .interrupted
        let interruptedItems = ProductionWorkPresenter.items(for: interruptedJob)
        t.checkEqual(states(interruptedItems), [.completed, .interrupted, .interrupted],
                     "PERWORKUI_7 unfinished works of an interrupted job read as interrupted, not failed")
        var cancelledJob = requestJob(.oneShot, count: 3)
        record(&cancelledJob, 0, .completed, output: "/tmp/a.mp4")
        cancelledJob.state = .cancelled
        t.checkEqual(states(ProductionWorkPresenter.items(for: cancelledJob)),
                     [.completed, .cancelled, .cancelled],
                     "PERWORKUI_8 unfinished works of a cancelled job read as cancelled, not interrupted")

        // PERWORKUI_9 / _21 — live job: completed, running, waiting.
        var live = requestJob(.generate, count: 3)
        record(&live, 0, .completed, output: "/tmp/a.mp4")
        live.state = .running
        let rendering = live.snapshot.pendingRequests.first { $0.batchIndex == 1 }!.id
        t.checkEqual(states(ProductionWorkPresenter.items(for: live, activeRequestID: rendering)),
                     [.completed, .running, .waiting],
                     "PERWORKUI_21 completed / running / waiting map from the renderer's live request")
        t.checkEqual(states(ProductionWorkPresenter.items(for: live, activeRequestID: nil)),
                     [.completed, .waiting, .waiting],
                     "PERWORKUI_9 with nothing rendering this instant, unfinished works wait — no guess")
        var queued = requestJob(.generate, count: 3)
        queued.state = .waiting
        t.checkEqual(states(ProductionWorkPresenter.items(for: queued)), [.waiting, .waiting, .waiting],
                     "PERWORKUI_9 a waiting job's works all wait")

        // PERWORKUI_22 — completed / failed / interrupted together.
        var mixed = requestJob(.oneShot, count: 3)
        record(&mixed, 0, .completed, output: "/tmp/a.mp4")
        record(&mixed, 1, .failed, reason: "backend failed")
        record(&mixed, 2, .interrupted)
        mixed.state = .failed
        t.checkEqual(states(ProductionWorkPresenter.items(for: mixed)),
                     [.completed, .failed, .interrupted],
                     "PERWORKUI_22 completed, failed and interrupted render side by side")

        // PERWORKUI_10 / _16 — labels.
        t.checkEqual(partialItems.map(\.label), ["作品 1", "作品 2", "作品 3"],
                     "PERWORKUI_10 labels are 1-based")
        for item in partialItems {
            t.check(UUID(uuidString: item.label) == nil && !item.label.contains("-"),
                    "PERWORKUI_16 \(item.label) is not a raw UUID")
        }

        // PERWORKUI_15 — a work's own reason goes through the queue sanitizer.
        var leaky = requestJob(.generate, count: 3)
        record(&leaky, 1, .failed, reason: privateReason)
        leaky.state = .failed
        let leakyReason = ProductionWorkPresenter.items(for: leaky)[1].failureReason ?? ""
        t.check(!leakyReason.contains("/Users/") && !leakyReason.contains("alice"),
                "PERWORKUI_15 a work's reason has no private path")
        t.check(leakyReason.contains(#"File "…/cli.py", line 810"#),
                "PERWORKUI_15 and keeps the useful part")

        // PERWORKUI_20 — projection never writes back.
        let before = partial
        _ = ProductionWorkPresenter.items(for: partial)
        _ = ProductionWorkPresenter.parentReasonIsCoveredByWorks(partial, items: partialItems)
        t.checkEqual(partial, before, "PERWORKUI_20 the per-work projection does not mutate the job")
    }

    t.suite("Multi-work queue — each surface maps works by stable identity") {

        // PERWORKUI_11 — Generate count=3: request batchIndex, outcome by request id.
        var generate = requestJob(.generate, count: 3)
        t.checkEqual(generate.snapshot.pendingRequests.map(\.batchIndex), [0, 1, 2],
                     "PERWORKUI_11 fixture: stamped batch indices")
        record(&generate, 2, .completed, output: "/tmp/c.mp4")
        record(&generate, 0, .failed, reason: "first failed")
        generate.state = .running
        // Outcomes recorded out of order must not shift which work they describe.
        t.checkEqual(states(ProductionWorkPresenter.items(for: generate)),
                     [.failed, .waiting, .completed],
                     "PERWORKUI_11 Generate works map by request identity, not recording order")
        // An outcome that belongs to another job is ignored, as in real data.
        var polluted = generate
        polluted.snapshot.runOutcomes.append(RunOutcomeRecord(
            runID: UUID(), outcome: .completed, attemptNumber: 1, outputPath: "/tmp/other.mp4"))
        t.checkEqual(ProductionWorkPresenter.items(for: polluted), ProductionWorkPresenter.items(for: generate),
                     "PERWORKUI_11 a foreign outcome does not become a work")

        // PERWORKUI_12 — One Shot count=3.
        var oneShot = requestJob(.oneShot, count: 3)
        record(&oneShot, 1, .completed, output: "/tmp/b.mp4")
        oneShot.state = .interrupted
        t.checkEqual(states(ProductionWorkPresenter.items(for: oneShot)),
                     [.interrupted, .completed, .interrupted],
                     "PERWORKUI_12 One Shot works map by request identity")

        // PERWORKUI_13 — Storyboard 作品数 3: run batchIndex and derived shot state.
        var storyboard = storyboardJob(count: 3)
        let sb = storyboard.snapshot.storyboardRuns.sorted { $0.batchIndex < $1.batchIndex }
        t.checkEqual(sb.map(\.batchIndex), [0, 1, 2], "PERWORKUI_13 fixture: run batch indices")
        for run in sb {
            let i = storyboard.snapshot.storyboardRuns.firstIndex { $0.id == run.id }!
            let sid = run.orderedShots[0].id
            switch run.batchIndex {
            case 0: storyboard.snapshot.storyboardRuns[i].update(sid) { $0.state = .completed; $0.outputPath = "/tmp/s0.mp4" }
            case 1: storyboard.snapshot.storyboardRuns[i].update(sid) { $0.state = .running; $0.dispatchedRequestID = UUID() }
            default: break
            }
        }
        storyboard.state = .running
        t.checkEqual(states(ProductionWorkPresenter.items(for: storyboard)), [.completed, .running, .waiting],
                     "PERWORKUI_13 Storyboard works map by run batch index")
        storyboard.state = .interrupted
        t.checkEqual(states(ProductionWorkPresenter.items(for: storyboard)), [.completed, .interrupted, .interrupted],
                     "PERWORKUI_13 once the parent stops, an in-flight work is not shown as still rendering")

        // PERWORKUI_14 — Auto Movie 作品数 3, including an assembly failure.
        var movie = movieJob(count: 3)
        completeMovie(&movie, 0)
        let s1 = movie.snapshot.movieRuns[1].orderedShots[0].id
        movie.snapshot.movieRuns[1].update(s1) { $0.state = .completed; $0.outputPath = "/tmp/m1.mp4" }
        movie.snapshot.movieRuns[1].assembly.state = .failed
        movie.snapshot.movieRuns[1].assembly.failureReason = "ffmpeg failed"
        movie.state = .failed
        let movieItems = ProductionWorkPresenter.items(for: movie)
        t.checkEqual(states(movieItems), [.completed, .failed, .notRun],
                     "PERWORKUI_14 Auto Movie works map by run batch index")
        t.checkEqual(movieItems[1].failureReason, "ffmpeg failed",
                     "PERWORKUI_14 an assembly failure is that work's reason")
        t.check(!movieItems[1].hasOutput,
                "PERWORKUI_14 a work whose shots rendered but whose film did not is not completed")
    }

    t.suite("Multi-work queue — dismissal and Clear Failed are unchanged") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerWork-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = ProductionQueueCoordinator(
            store: ProductionQueueStore(fileURL: root.appendingPathComponent("q.json")),
            restoreOnInit: false)
        queue.setPaused(true)
        let multi = queue.enqueue(requestJob(.oneShot, count: 3))
        let other = queue.enqueue(requestJob(.generate, count: 2))
        let single = queue.enqueue(requestJob(.generate, count: 1))
        queue.markFailed(jobID: multi.id, reason: "backend failed")
        queue.markFailed(jobID: single.id, reason: "backend failed")

        // PERWORKUI_18 — one × removes the parent job, all its works with it,
        // and nothing else.
        queue.remove(jobID: multi.id)
        t.check(queue.job(id: multi.id) == nil, "PERWORKUI_18 dismissing the parent removes the job")
        t.checkEqual(queue.job(id: other.id)?.state, .waiting, "PERWORKUI_18 other jobs are untouched")

        // PERWORKUI_17 — Clear Failed still counts and clears parent jobs.
        t.checkEqual(queue.jobs.filter { $0.state == .failed }.count, 1,
                     "PERWORKUI_17 fixture: one failed parent left")
        queue.removeFailed()
        t.check(queue.job(id: single.id) == nil, "PERWORKUI_17 Clear Failed removes failed parents")
        t.checkEqual(queue.job(id: other.id)?.state, .waiting, "PERWORKUI_17 and leaves waiting work alone")
    }
}
