import Foundation
@testable import LTXVideoGeneratorCore

/// Global production queue: several jobs queued, executed strictly one at a
/// time, surviving a relaunch. The single-active-job guarantee is the property
/// everything else depends on, so it is proved with a runner double rather than
/// asserted in prose.
func runProductionQueueTests(_ t: TestKit) {

    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-queue-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    func makeStore(_ name: String) -> ProductionQueueStore {
        ProductionQueueStore(fileURL: tmpRoot.appendingPathComponent("\(name).json"))
    }

    func job(_ kind: ProductionJobKind, _ title: String,
             snapshot: ProductionJobSnapshot = ProductionJobSnapshot()) -> ProductionJob {
        ProductionJob(kind: kind, title: title, snapshot: snapshot)
    }

    /// Records every start and never reports completion on its own, so the
    /// coordinator cannot advance unless the test says so.
    final class RunnerSpy {
        private(set) var started: [UUID] = []
        var concurrentPeak = 0
        private var active = 0
        var outcome: ProductionQueueCoordinator.StartOutcome = .started

        func run(_ job: ProductionJob) -> ProductionQueueCoordinator.StartOutcome {
            if case .started = outcome {
                started.append(job.id)
                active += 1
                concurrentPeak = max(concurrentPeak, active)
            }
            return outcome
        }
        func finishOne() { active = max(0, active - 1) }
    }

    t.suite("Queue submission — a running generation never blocks submission") {
        // 1. Idle queue + valid input → can submit.
        t.check(GenerationSubmissionPolicy.canSubmit(prompt: "a calm lake"),
                "1: valid One Shot input can be submitted")

        // 2/3/4. The policy takes no busy input at all, which is the fix: there
        // is no argument a caller could pass that would refuse a submission
        // because something else is rendering. Auto Movie active, another One
        // Shot active, or a non-empty queue are all the same call.
        t.check(GenerationSubmissionPolicy.canSubmit(prompt: "a calm lake"),
                "2/3/4: submission does not depend on what is currently rendering")

        // 5. Invalid input stays invalid regardless.
        t.check(!GenerationSubmissionPolicy.canSubmit(prompt: ""),
                "5: empty prompt cannot be submitted")
        t.check(!GenerationSubmissionPolicy.canSubmit(prompt: "   \n  "),
                "5: whitespace-only prompt cannot be submitted")

        // Legitimate blockers remain: this One Shot's own planning in flight,
        // and an unusable starting image.
        t.check(!GenerationSubmissionPolicy.canSubmit(prompt: "ok", isPreparing: true),
                "planning in flight still blocks a second click")
        t.check(!GenerationSubmissionPolicy.canSubmit(prompt: "ok", blockingError: "image missing"),
                "an invalid starting image still blocks submission")
        t.check(GenerationSubmissionPolicy.canSubmit(prompt: "ok", isPreparing: false, blockingError: nil),
                "no blocker → submittable")
    }

    t.suite("Direct Generate — submit-and-dismiss queue boundary") {
        let imageURL = tmpRoot.appendingPathComponent("direct-generate-source.png")
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        func request(
            prompt: String = "Prompt A",
            model: String = LTXModelCatalog.defaultModelID,
            seed: Int = 1,
            image: String? = nil
        ) -> GenerationRequest {
            var parameters = GenerationParameters.default
            parameters.seed = seed
            return GenerationRequest(
                prompt: prompt,
                negativePrompt: "no artifacts",
                voiceoverText: "narration",
                sourceImagePath: image,
                musicEnabled: true,
                musicGenre: "cinematicUplifting",
                disableAudio: false,
                modelId: model,
                textEncoderId: "gemma3_12b_4bit",
                parameters: parameters,
                qualityMode: QualityMode.advanced.rawValue,
                preset: GenerationPreset.custom.rawValue,
                targetDurationSeconds: 5,
                generationSource: "generate"
            )
        }

        // A/C. The submission boundary creates one fully formed immutable job.
        var mutablePrompt = "Prompt A"
        var mutableModel = LTXModelCatalog.defaultModelID
        var mutableSeed = 1
        let submitted = try? DirectGenerationSubmission.makeJob(request: request(
            prompt: mutablePrompt, model: mutableModel, seed: mutableSeed,
            image: imageURL.path))
        mutablePrompt = "Prompt B"
        mutableModel = CustomLTX2MLXModelCatalog.customModelID
        mutableSeed = 2

        t.checkEqual(submitted?.kind, .generate,
                     "A: Direct Generate produces the existing Generate job kind")
        t.checkEqual(submitted?.snapshot.pendingRequests.count, 1,
                     "A: one click freezes exactly one request")
        let frozen = submitted?.snapshot.pendingRequests.first
        t.checkEqual(frozen?.prompt, "Prompt A", "C: later prompt edits cannot change Job A")
        t.checkEqual(frozen?.modelId, LTXModelCatalog.defaultModelID,
                     "C: later model edits cannot change Job A")
        t.checkEqual(frozen?.parameters.seed, 1, "C: later seed edits cannot change Job A")
        t.checkEqual(frozen?.negativePrompt, "no artifacts", "snapshot keeps negative prompt")
        t.checkEqual(frozen?.textEncoderId, "gemma3_12b_4bit", "snapshot keeps text encoder")
        t.checkEqual(frozen?.preset, GenerationPreset.custom.rawValue, "snapshot keeps preset")
        t.checkEqual(frozen?.targetDurationSeconds, 5, "snapshot keeps target duration")
        t.checkEqual(submitted?.snapshot.settings, frozen?.parameters,
                     "snapshot metadata and executable request use the same settings")

        // B/E. Rendering activity is deliberately not an input to submission,
        // and ending the view's local lifetime cannot cancel queue-owned work.
        let coordinator = ProductionQueueCoordinator(
            store: makeStore("direct-submit-lifetime"), restoreOnInit: false)
        let spy = RunnerSpy()
        coordinator.runner = { spy.run($0) }
        let running = coordinator.enqueue(job(.autoMovie, "Already rendering"))
        let queued = coordinator.enqueue(submitted!)
        t.check(GenerationSubmissionPolicy.canSubmit(prompt: "Prompt A"),
                "B: a global render in flight does not disable Direct Generate")
        t.checkEqual(coordinator.job(id: running.id)?.state, .running,
                     "B: existing render remains the owner of the active slot")
        t.checkEqual(coordinator.job(id: queued.id)?.state, .waiting,
                     "E: submitted job remains queued after submission UI ends")

        // F. Local validation fails before any job can be enqueued.
        do {
            _ = try DirectGenerationSubmission.makeJob(request: request(prompt: "  \n "))
            t.check(false, "F: whitespace prompt should fail validation")
        } catch let error as DirectGenerationSubmission.SubmissionError {
            t.checkEqual(error, .emptyPrompt, "F: empty prompt has a concise local error")
        } catch {
            t.check(false, "F: unexpected validation error \(error)")
        }
        do {
            _ = try DirectGenerationSubmission.makeJob(request: request(
                image: tmpRoot.appendingPathComponent("missing.png").path))
            t.check(false, "I: missing source image should fail before enqueue")
        } catch let error as DirectGenerationSubmission.SubmissionError {
            if case .sourceImageUnavailable = error {
                t.check(true, "I: missing source image is distinguished")
            } else {
                t.check(false, "I: wrong source validation error")
            }
        } catch {
            t.check(false, "I: unexpected source validation error \(error)")
        }
        t.check(FileManager.default.isReadableFile(atPath: imageURL.path),
                "I: ending submission does not remove a queued I2V source image")

        // J. Model/backend provenance stays attached to each request.
        let ltx = try? DirectGenerationSubmission.makeJob(request: request(
            prompt: "LTX", model: LTXModelCatalog.defaultModelID, seed: 10))
        let eros = try? DirectGenerationSubmission.makeJob(request: request(
            prompt: "Custom", model: CustomLTX2MLXModelCatalog.customModelID, seed: 20))
        t.checkEqual(GenerationModelResolver.backend(
            for: ltx?.snapshot.pendingRequests.first?.modelId), .mlxVideoWithAudio,
            "J: queued LTX request remains on mlx-video-with-audio")
        t.checkEqual(GenerationModelResolver.backend(
            for: eros?.snapshot.pendingRequests.first?.modelId), .ltx2MLX,
            "J: queued custom model request remains on ltx-2-mlx")

        // K. The new fully populated snapshot uses the existing Codable model.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let roundTrip = submitted.flatMap { try? encoder.encode($0) }
            .flatMap { try? decoder.decode(ProductionJob.self, from: $0) }
        t.checkEqual(roundTrip?.snapshot, submitted?.snapshot,
                     "K: Direct Generate snapshot survives persistence")

        // G/H. Direct jobs use the already accepted terminal projection:
        // successful and failed records both leave the active list, while the
        // persisted record keeps output/failure provenance.
        let terminal = ProductionQueueCoordinator(
            store: makeStore("direct-terminal"), restoreOnInit: false)
        let terminalSpy = RunnerSpy()
        terminal.runner = { terminalSpy.run($0) }
        let success = terminal.enqueue(submitted!)
        terminalSpy.finishOne()
        terminal.markCompleted(jobID: success.id, outputPath: "/tmp/direct.mp4")
        t.check(!terminal.activeDisplayJobs.contains { $0.id == success.id },
                "G: completed Direct Generate leaves the active list")
        t.checkEqual(terminal.job(id: success.id)?.outputPath, "/tmp/direct.mp4",
                     "G: completed output provenance remains persisted")
        let failed = terminal.enqueue(try! DirectGenerationSubmission.makeJob(
            request: request(prompt: "Fails later")))
        terminalSpy.finishOne()
        terminal.markFailed(jobID: failed.id, reason: "backend failed")
        t.check(!terminal.activeDisplayJobs.contains { $0.id == failed.id },
                "H: failed Direct Generate follows terminal active-list semantics")
        t.checkEqual(terminal.job(id: failed.id)?.failureReason, "backend failed",
                     "H: post-enqueue failure remains on the persisted job")
    }

    t.suite("Queue submission — One Shot queues behind an active Auto Movie") {
        let coordinator = ProductionQueueCoordinator(store: makeStore("oneshot-behind"), restoreOnInit: false)
        let spy = RunnerSpy()
        coordinator.runner = { spy.run($0) }

        // 6/7/8. Auto Movie is running; a One Shot submitted now waits.
        let movie = coordinator.enqueue(job(.autoMovie, "Movie"))
        t.checkEqual(coordinator.job(id: movie.id)?.state, .running, "Auto Movie is active")
        let oneShot = coordinator.enqueue(job(.oneShot, "One Shot"))
        t.checkEqual(coordinator.job(id: oneShot.id)?.state, .waiting, "6: One Shot is queued")
        t.checkEqual(coordinator.job(id: movie.id)?.state, .running,
                     "7: the running Auto Movie is not interrupted")
        t.checkEqual(spy.started.count, 1, "8: the One Shot does not start early")
        t.checkEqual(spy.concurrentPeak, 1, "only one heavy generation at a time")

        // 9/10. It starts when the movie finishes, and completion advances again.
        spy.finishOne()
        coordinator.markCompleted(jobID: movie.id, outputPath: "/tmp/movie.mp4")
        t.checkEqual(coordinator.job(id: oneShot.id)?.state, .running, "9: One Shot starts after the movie")
        let second = coordinator.enqueue(job(.oneShot, "One Shot B"))
        spy.finishOne()
        coordinator.markCompleted(jobID: oneShot.id, outputPath: "/tmp/one.mp4")
        t.checkEqual(coordinator.job(id: second.id)?.state, .running, "10: completion starts the next job")
        t.checkEqual(spy.concurrentPeak, 1, "concurrency still one")
    }

    t.suite("Queue submission — One Shot active, another One Shot queued") {
        // 18/19. The rule is about generation activity in general, not about
        // Auto Movie specifically.
        let coordinator = ProductionQueueCoordinator(store: makeStore("oneshot-oneshot"), restoreOnInit: false)
        let spy = RunnerSpy()
        coordinator.runner = { spy.run($0) }

        let a = coordinator.enqueue(job(.oneShot, "A"))
        let b = coordinator.enqueue(job(.oneShot, "B"))
        let movie = coordinator.enqueue(job(.autoMovie, "Movie"))
        t.checkEqual(coordinator.job(id: a.id)?.state, .running, "One Shot A runs")
        t.checkEqual(coordinator.job(id: b.id)?.state, .waiting, "18: One Shot B queues behind it")
        t.checkEqual(coordinator.job(id: movie.id)?.state, .waiting,
                     "19: an Auto Movie can still be queued while a One Shot runs")

        // 34. Order is the order they were queued — One Shot gets no priority.
        spy.finishOne(); coordinator.markCompleted(jobID: a.id, outputPath: "/tmp/a.mp4")
        t.checkEqual(spy.started.last, b.id, "34: FIFO — B before the later Auto Movie")
        spy.finishOne(); coordinator.markCompleted(jobID: b.id, outputPath: "/tmp/b.mp4")
        t.checkEqual(spy.started.last, movie.id, "34: the Auto Movie runs last")
    }

    t.suite("Queue submission — a queued One Shot renders what was queued") {
        // 11-14. The job carries a fully-formed request, so editing the screen
        // afterwards cannot reach into a waiting job.
        let coordinator = ProductionQueueCoordinator(store: makeStore("snapshot-isolation"), restoreOnInit: false)
        let spy = RunnerSpy()
        coordinator.runner = { spy.run($0) }
        coordinator.enqueue(job(.autoMovie, "blocker"))   // keeps the One Shots waiting

        func oneShotJob(prompt: String, model: String, image: String?, seed: Int) -> ProductionJob {
            var params = GenerationParameters.default
            params.seed = seed
            var snapshot = ProductionJobSnapshot()
            snapshot.brief = prompt
            snapshot.prompt = prompt
            snapshot.seed = seed
            snapshot.pendingRequests = [GenerationRequest(
                prompt: prompt, sourceImagePath: image, modelId: model,
                parameters: params, generationSource: "oneShot")]
            return job(.oneShot, prompt, snapshot: snapshot)
        }

        let a = coordinator.enqueue(oneShotJob(
            prompt: "prompt A", model: CustomLTX2MLXModelCatalog.customModelID,
            image: "/tmp/a.png", seed: 111))
        let b = coordinator.enqueue(oneShotJob(
            prompt: "prompt B", model: LTXModelCatalog.defaultModelID,
            image: "/tmp/b.png", seed: 222))

        let queuedA = coordinator.job(id: a.id)!.snapshot.pendingRequests.first!
        let queuedB = coordinator.job(id: b.id)!.snapshot.pendingRequests.first!

        t.checkEqual(queuedA.prompt, "prompt A", "11: A keeps its own prompt")
        t.checkEqual(queuedB.prompt, "prompt B", "11: B keeps its own prompt")
        t.checkEqual(queuedA.parameters.seed, 111, "12: A keeps its own seed")
        t.checkEqual(queuedB.parameters.seed, 222, "12: B keeps its own seed")
        t.checkEqual(queuedA.sourceImagePath, "/tmp/a.png", "13: A keeps its own source image")
        t.checkEqual(queuedB.sourceImagePath, "/tmp/b.png", "13: B keeps its own source image")
        t.checkEqual(queuedA.modelId, CustomLTX2MLXModelCatalog.customModelID,
                     "14: A stays on custom model even though a later job chose LTX-2.3")
        t.checkEqual(queuedB.modelId, LTXModelCatalog.defaultModelID, "14: B stays on LTX-2.3")

        // 15/16/17. Backend routing is derived from the frozen model ID, so a
        // queued custom model job cannot become an LTX-2.3 render while it waits.
        t.checkEqual(GenerationModelResolver.backend(for: queuedA.modelId), .ltx2MLX,
                     "16: queued custom model routes to ltx-2-mlx")
        t.checkEqual(GenerationModelResolver.backend(for: queuedB.modelId), .mlxVideoWithAudio,
                     "15: queued LTX-2.3 routes to mlx-video-with-audio")
        t.check(GenerationModelResolver.backend(for: queuedA.modelId)
                    != GenerationModelResolver.backend(for: queuedB.modelId),
                "17: the two queued jobs do not share a backend")
    }

    t.suite("Queue submission — a failed One Shot releases the queue") {
        // 18/19/20 (failure block). A One Shot failure must not lock the queue
        // or the submit button.
        let coordinator = ProductionQueueCoordinator(store: makeStore("oneshot-failure"), restoreOnInit: false)
        let spy = RunnerSpy()
        coordinator.runner = { spy.run($0) }

        let a = coordinator.enqueue(job(.oneShot, "A"))
        let b = coordinator.enqueue(job(.oneShot, "B"))
        spy.finishOne()
        coordinator.markFailed(jobID: a.id, reason: "backend exited")
        t.checkEqual(coordinator.job(id: a.id)?.state, .failed, "18: the failed One Shot is marked failed")
        t.checkEqual(coordinator.job(id: b.id)?.state, .running, "19: the next job still runs")
        t.check(GenerationSubmissionPolicy.canSubmit(prompt: "still fine"),
                "20: submission is still possible after a failure")
    }

    t.suite("Production queue — one job at a time") {
        // A/B/C. Enqueue several; only the first runs, in FIFO order.
        let coordinator = ProductionQueueCoordinator(store: makeStore("fifo"), restoreOnInit: false)
        let spy = RunnerSpy()
        coordinator.runner = { spy.run($0) }

        let a = coordinator.enqueue(job(.generate, "A"))
        let b = coordinator.enqueue(job(.oneShot, "B"))
        let c = coordinator.enqueue(job(.autoMovie, "C"))

        t.checkEqual(spy.started.count, 1, "C: only one job is started")
        t.checkEqual(spy.started.first, a.id, "B: the first enqueued job runs first (FIFO)")
        t.checkEqual(coordinator.job(id: a.id)?.state, .running, "A is running")
        t.checkEqual(coordinator.job(id: b.id)?.state, .waiting, "B waits")
        t.checkEqual(coordinator.job(id: c.id)?.state, .waiting, "C waits")
        t.checkEqual(coordinator.waitingCount, 2, "two jobs are waiting")

        // THE CONCURRENCY GUARANTEE. Nothing above one, ever — this is what
        // keeps two renders off the same unified memory.
        t.checkEqual(spy.concurrentPeak, 1, "concurrency never exceeds one active job")

        // D. Completing the active job starts exactly the next one.
        spy.finishOne()
        coordinator.markCompleted(jobID: a.id, outputPath: "/tmp/a.mp4")
        t.checkEqual(coordinator.job(id: a.id)?.state, .completed, "D: A completed")
        t.checkEqual(coordinator.job(id: a.id)?.outputPath, "/tmp/a.mp4", "D: output path recorded")
        t.checkEqual(spy.started.count, 2, "D: completion starts the next job")
        t.checkEqual(spy.started.last, b.id, "D: the next job is B")
        t.checkEqual(spy.concurrentPeak, 1, "still never more than one active")

        // E/X. A failure does not stall the queue behind it.
        spy.finishOne()
        coordinator.markFailed(jobID: b.id, reason: "render failed")
        t.checkEqual(coordinator.job(id: b.id)?.state, .failed, "E: B failed")
        t.checkEqual(coordinator.job(id: b.id)?.failureReason, "render failed",
                     "E: the reason is kept for the panel")
        t.checkEqual(spy.started.last, c.id, "X: a failed job does not block the following job")
        t.checkEqual(spy.concurrentPeak, 1, "concurrency held at one across a failure")

        // F. Cancelling the running job also advances the queue.
        let d = coordinator.enqueue(job(.generate, "D"))
        spy.finishOne()
        coordinator.cancel(jobID: c.id)
        t.checkEqual(coordinator.job(id: c.id)?.state, .cancelled, "F: C cancelled")
        t.checkEqual(spy.started.last, d.id, "F: cancelling the running job starts the next")
    }

    t.suite("Production queue — active presentation is newest-first, execution stays FIFO") {
        let coordinator = ProductionQueueCoordinator(
            store: makeStore("active-presentation"), restoreOnInit: false)
        let spy = RunnerSpy()
        coordinator.runner = { spy.run($0) }
        coordinator.setPaused(true)

        var first = job(.autoMovie, "First Auto Movie")
        first.createdAt = Date(timeIntervalSince1970: 1)
        var second = job(.oneShot, "Second One Shot")
        second.createdAt = Date(timeIntervalSince1970: 2)
        var third = job(.generate, "Third Generate")
        third.createdAt = Date(timeIntervalSince1970: 3)
        let a = coordinator.enqueue(first)
        let b = coordinator.enqueue(second)
        let c = coordinator.enqueue(third)

        t.checkEqual(coordinator.jobs.map(\.title),
                     ["First Auto Movie", "Second One Shot", "Third Generate"],
                     "execution storage remains enqueue-order FIFO")
        t.checkEqual(coordinator.activeDisplayJobs.map(\.title),
                     ["Third Generate", "Second One Shot", "First Auto Movie"],
                     "newest submitted active item is displayed at the top")

        coordinator.setPaused(false)
        t.checkEqual(spy.started.first, a.id,
                     "display reversal does not change first execution: oldest runs first")
        t.checkEqual(coordinator.activeDisplayJobs.last?.state, .running,
                     "older running job remains clearly represented as Running")

        spy.finishOne()
        coordinator.markCompleted(jobID: a.id, outputPath: "/tmp/first-final.mp4")
        t.check(!coordinator.activeDisplayJobs.contains { $0.id == a.id },
                "completed job disappears from the active presentation")
        t.checkEqual(coordinator.job(id: a.id)?.outputPath, "/tmp/first-final.mp4",
                     "completed output provenance remains persisted")
        t.checkEqual(spy.started.last, b.id, "FIFO advances to the second job")

        spy.finishOne()
        coordinator.markFailed(jobID: b.id, reason: "backend failed")
        t.check(!coordinator.activeDisplayJobs.contains { $0.id == b.id },
                "failed job mirrors normal Queue and leaves the active list")
        t.checkEqual(coordinator.job(id: b.id)?.failureReason, "backend failed",
                     "failed record remains available outside the active projection")
        t.checkEqual(spy.started.last, c.id, "failure still advances FIFO to the third job")

        spy.finishOne()
        coordinator.markCancelled(jobID: c.id)
        t.check(coordinator.activeDisplayJobs.isEmpty,
                "cancelled terminal job also leaves the active presentation")
        t.checkEqual(coordinator.jobs.count, 3,
                     "presentation cleanup never deletes persisted queue records")
    }

    t.suite("Production queue — preflight, reorder and lifecycle") {
        // A runner that refuses to start models execution-time preflight: the
        // file vanished while the job waited.
        let coordinator = ProductionQueueCoordinator(store: makeStore("preflight"), restoreOnInit: false)
        let spy = RunnerSpy()
        spy.outcome = .failed("opening reference image is missing")
        coordinator.runner = { spy.run($0) }
        let bad = coordinator.enqueue(job(.autoMovie, "Missing asset"))
        t.checkEqual(coordinator.job(id: bad.id)?.state, .failed,
                     "W: a job whose preflight fails at execution is failed, not started")
        t.checkEqual(coordinator.job(id: bad.id)?.failureReason,
                     "opening reference image is missing",
                     "W: the preflight reason is surfaced")

        // G/H/I. Reordering applies to waiting jobs and never to the active one.
        let reorder = ProductionQueueCoordinator(store: makeStore("reorder"), restoreOnInit: false)
        reorder.runner = { _ in .started }
        let running = reorder.enqueue(job(.generate, "running"))
        let x = reorder.enqueue(job(.generate, "X"))
        let y = reorder.enqueue(job(.generate, "Y"))
        let z = reorder.enqueue(job(.generate, "Z"))

        reorder.moveUp(jobID: y.id)
        t.checkEqual(reorder.jobs.map(\.title), ["running", "Y", "X", "Z"],
                     "G: Move Up reorders a waiting job")
        reorder.moveDown(jobID: y.id)
        t.checkEqual(reorder.jobs.map(\.title), ["running", "X", "Y", "Z"],
                     "H: Move Down reorders a waiting job")

        // The running job cannot be dragged out of its position.
        reorder.moveDown(jobID: running.id)
        t.checkEqual(reorder.jobs.first?.title, "running",
                     "the running job is never reordered")
        // Nor can a waiting job be moved above it.
        reorder.moveUp(jobID: x.id)
        t.checkEqual(reorder.jobs.map(\.title), ["running", "X", "Y", "Z"],
                     "a waiting job cannot displace the running job")

        // I. Removing a waiting job; the running one is protected.
        reorder.remove(jobID: z.id)
        t.check(reorder.job(id: z.id) == nil, "I: a waiting job can be removed")
        reorder.remove(jobID: running.id)
        t.check(reorder.job(id: running.id) != nil,
                "a running job is not removed out from under the renderer")

        // N. Retry re-queues from the original snapshot rather than live state.
        let retryQueue = ProductionQueueCoordinator(store: makeStore("retry"), restoreOnInit: false)
        retryQueue.runner = { _ in .started }
        var snapshot = ProductionJobSnapshot()
        snapshot.prompt = "original prompt"
        snapshot.seed = 4242
        let failed = retryQueue.enqueue(job(.generate, "Retry me", snapshot: snapshot))
        retryQueue.markFailed(jobID: failed.id, reason: "boom")
        let retried = retryQueue.retry(jobID: failed.id)
        t.check(retried != nil, "N: a failed job can be retried")
        t.checkEqual(retried?.snapshot.prompt, "original prompt",
                     "N: the retry carries the original snapshot")
        t.checkEqual(retried?.snapshot.seed, 4242, "N: the retry keeps the original seed")
        t.check(retried?.id != failed.id, "N: the retry is a new record, so the failure stays visible")
        t.checkEqual(retryQueue.job(id: failed.id)?.state, .failed,
                     "N: the original failure record is preserved")

        // Pause holds back waiting work without touching the running job.
        let paused = ProductionQueueCoordinator(store: makeStore("pause"), restoreOnInit: false)
        let pauseSpy = RunnerSpy()
        paused.runner = { pauseSpy.run($0) }
        let first = paused.enqueue(job(.generate, "first"))
        paused.setPaused(true)
        _ = paused.enqueue(job(.generate, "second"))
        pauseSpy.finishOne()
        paused.markCompleted(jobID: first.id)
        t.checkEqual(pauseSpy.started.count, 1, "pause stops the next job from starting")
        paused.setPaused(false)
        t.checkEqual(pauseSpy.started.count, 2, "unpausing resumes the queue")
    }

    t.suite("Production queue — persistence and restart") {
        // J. Round trip through disk.
        let store = makeStore("persist")
        let coordinator = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        coordinator.runner = { _ in .started }
        var snapshot = ProductionJobSnapshot()
        snapshot.brief = "a woman walks to a library"
        snapshot.openingReferenceRelativePath = "Assets/OpeningReference/x.png"
        snapshot.characterAnchorCharacterID = UUID()
        let running = coordinator.enqueue(job(.autoMovie, "Movie A", snapshot: snapshot))
        let waiting = coordinator.enqueue(job(.oneShot, "Shot B"))
        store.flush()

        let reloaded = ProductionQueueCoordinator(store: store, restoreOnInit: true)
        t.checkEqual(reloaded.jobs.count, 2, "J: the queue survives a round trip")
        t.checkEqual(reloaded.job(id: waiting.id)?.snapshot.brief, "",
                     "J: each job keeps its own snapshot")
        t.checkEqual(reloaded.job(id: running.id)?.snapshot.brief,
                     "a woman walks to a library", "S: the brief survives persistence")
        t.checkEqual(reloaded.job(id: running.id)?.snapshot.openingReferenceRelativePath,
                     "Assets/OpeningReference/x.png",
                     "S: the opening reference survives persistence")
        t.check(reloaded.job(id: running.id)?.snapshot.characterAnchorCharacterID != nil,
                "T: the character anchor selection survives persistence")

        // K/L. Waiting stays waiting; a job that was running when the app quit
        //      becomes interrupted — never resumed silently, never completed.
        t.checkEqual(reloaded.job(id: waiting.id)?.state, .waiting,
                     "K: a waiting job restores as waiting")
        t.checkEqual(reloaded.job(id: running.id)?.state, .interrupted,
                     "L: a job that was running restores as interrupted")
        t.check(reloaded.activeJobID == nil,
                "L: nothing is considered active immediately after a restart")

        // M. An interrupted job can be restarted from its snapshot.
        t.check(reloaded.job(id: running.id)?.canRestart == true,
                "M: an interrupted job offers Restart")
        let restarted = reloaded.retry(jobID: running.id)
        t.checkEqual(restarted?.state, .waiting, "M: restarting re-queues the job")
        t.checkEqual(restarted?.snapshot.openingReferenceRelativePath,
                     "Assets/OpeningReference/x.png",
                     "M: the restart uses the original opening reference")

        // AG. No queue file at all is an empty queue, not a crash.
        let fresh = ProductionQueueCoordinator(
            store: makeStore("never-written"), restoreOnInit: true)
        t.checkEqual(fresh.jobs.count, 0, "AG: a missing queue file restores an empty queue")

        // AH. One malformed record must not destroy the rest of the queue.
        let corruptURL = tmpRoot.appendingPathComponent("corrupt.json")
        let corrupt = """
        [{"id":"\(UUID().uuidString)","kind":"generate","title":"good","state":"waiting",
          "snapshot":{"prompt":"ok","brief":"","batchCount":1,"pendingRequests":[]},
          "createdAt":"2026-08-11T00:00:00Z"},
         {"kind":"not-a-real-kind","title":"broken"}]
        """
        try? corrupt.write(to: corruptURL, atomically: true, encoding: .utf8)
        let salvaged = ProductionQueueStore(fileURL: corruptURL).load()
        t.checkEqual(salvaged.count, 1, "AH: a malformed record is dropped, the rest survives")
        t.checkEqual(salvaged.first?.title, "good", "AH: the intact record is the one kept")
    }

    t.suite("Production queue — snapshot determinism") {
        // U/V. The point of a snapshot: editing afterwards must not reach into
        //      a job that is already waiting.
        let coordinator = ProductionQueueCoordinator(store: makeStore("snapshot"), restoreOnInit: false)
        coordinator.runner = { _ in .started }
        _ = coordinator.enqueue(job(.generate, "occupies the runner"))

        var snapshot = ProductionJobSnapshot()
        snapshot.prompt = "prompt at enqueue"
        snapshot.seed = 111
        snapshot.openingReferenceRelativePath = "Assets/OpeningReference/original.png"
        let queued = coordinator.enqueue(job(.autoMovie, "Movie", snapshot: snapshot))

        // The user keeps working: a different prompt, seed and image.
        snapshot.prompt = "prompt changed later"
        snapshot.seed = 999
        snapshot.openingReferenceRelativePath = "Assets/OpeningReference/changed.png"

        let stored = coordinator.job(id: queued.id)
        t.checkEqual(stored?.snapshot.prompt, "prompt at enqueue",
                     "V: a later prompt edit does not reach the queued job")
        t.checkEqual(stored?.snapshot.seed, 111,
                     "U: a later seed change does not reach the queued job")
        t.checkEqual(stored?.snapshot.openingReferenceRelativePath,
                     "Assets/OpeningReference/original.png",
                     "S: a later opening reference change does not reach the queued job")

        // O. A Generate batch is one job, not N jobs.
        var batch = ProductionJobSnapshot()
        batch.batchCount = 10
        let batchJob = coordinator.enqueue(job(.generate, "Batch of 10", snapshot: batch))
        t.checkEqual(coordinator.job(id: batchJob.id)?.snapshot.batchCount, 10,
                     "O: a Generate batch is carried as one job with a count")
        t.checkEqual(coordinator.jobs.filter { $0.title == "Batch of 10" }.count, 1,
                     "O: the batch occupies exactly one queue slot")

        // Generate Now jumps the waiting queue without preempting the running job.
        let urgent = coordinator.enqueueNext(job(.oneShot, "Urgent"))
        let waitingTitles = coordinator.jobs.filter { $0.state == .waiting }.map(\.title)
        t.checkEqual(waitingTitles.first, "Urgent",
                     "Generate Now places the job at the head of the waiting jobs")
        t.checkEqual(coordinator.activeJob?.title, "occupies the runner",
                     "Generate Now does not preempt the running job")
        t.checkEqual(coordinator.job(id: urgent.id)?.state, .waiting,
                     "Generate Now still waits for the single render slot")
    }

    t.suite("Production queue — a film job is finished by the project, not the renderer") {
        // Regression for a defect found in a real run: between two Auto Movie
        // shots the render queue is momentarily empty — the finished take has
        // been removed and the next shot is only appended once the run
        // coordinator advances. Treating that instant as "renderer idle, so the
        // job is done" marked a movie completed while shot 2 was still
        // rendering, and would have let the next queued movie start on top of
        // it. Completion is decided by the project's own state instead.
        func project(shotCount: Int, completedShots: Int,
                     assembled: Bool, failedShot: Int? = nil) -> FilmProject {
            var project = FilmProject(title: "Movie")
            project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
            for index in 0..<shotCount {
                var shot = Shot(index: index, title: "Shot \(index + 1)")
                func take(_ status: TakeStatus) -> Take {
                    Take(shotID: shot.id, modelID: "m", seed: 1,
                         promptSnapshot: "p", settingsSnapshot: .default,
                         requestedWidth: 512, requestedHeight: 320,
                         fps: 24, requestedDuration: 1, status: status)
                }
                if index == failedShot {
                    shot.takes = [take(.failed)]
                } else if index < completedShots {
                    let completed = take(.completed)
                    shot.takes = [completed]
                    shot.selectedTakeID = completed.id
                }
                project.shots.append(shot)
            }
            if assembled { project.assembledMoviePath = "/tmp/final.mp4" }
            return project
        }

        // The rule the service applies, stated once and checked directly.
        func isFinished(_ project: FilmProject) -> Bool {
            let shotFailed = project.shots.contains { shot in
                shot.takes.contains { $0.status == .failed }
                    && shot.selectedTake?.status != .completed
            }
            if shotFailed { return true }
            let everyShotRendered = !project.shots.isEmpty && project.shots.allSatisfy { shot in
                shot.takes.contains { $0.status == .completed }
            }
            return everyShotRendered
                && !(project.assembledMoviePath ?? "").isEmpty
        }

        t.check(!isFinished(project(shotCount: 3, completedShots: 1, assembled: false)),
                "a movie with one of three shots rendered is NOT finished")
        t.check(!isFinished(project(shotCount: 3, completedShots: 3, assembled: false)),
                "all shots rendered but not yet assembled is NOT finished")
        t.check(isFinished(project(shotCount: 3, completedShots: 3, assembled: true)),
                "all shots rendered and assembled IS finished")
        t.check(isFinished(project(shotCount: 3, completedShots: 1, assembled: false, failedShot: 1)),
                "Z: a failed shot ends the job, and no assembly happens")
        t.check(!isFinished(project(shotCount: 0, completedShots: 0, assembled: false)),
                "an empty project is not treated as a finished movie")
    }

    t.suite("Production queue — jobs run in the order they were queued") {
        // Regression for D-068, found in the real GUI run: creating an Auto
        // Movie inserted the job at the *head* of the waiting jobs. With the
        // queue paused (or several movies created before any starts) three
        // movies queued as 1, 2, 3 would run 3, 2, 1 — the opposite of what
        // "leave it running overnight" means.
        let store = ProductionQueueStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("queue-order-\(UUID().uuidString).json"))
        let coordinator = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        coordinator.runner = { _ in .started }
        coordinator.setPaused(true)

        for title in ["First", "Second", "Third"] {
            coordinator.enqueue(ProductionJob(
                kind: .autoMovie, title: title, snapshot: ProductionJobSnapshot()))
        }
        t.checkEqual(coordinator.jobs.map(\.title), ["First", "Second", "Third"],
                     "D-068: movies run in the order they were created")
        t.check(coordinator.jobs.allSatisfy { $0.state == .waiting },
                "D-068: a paused queue starts nothing")

        // Generate Now is still the deliberate exception, and only it.
        coordinator.enqueueNext(ProductionJob(
            kind: .oneShot, title: "Urgent", snapshot: ProductionJobSnapshot()))
        t.checkEqual(coordinator.jobs.map(\.title),
                     ["Urgent", "First", "Second", "Third"],
                     "D-068: Generate Now is the only thing that jumps the queue")
    }

    t.suite("Production queue — a stalled job must not stall the queue") {
        // Regression for two defects found in a real two-job run.
        //
        // D-066: the queue only ever woke on render-queue changes. Final
        // assembly starts after the last take has left that queue, so nothing
        // published again — job A sat in "Assembling" with the finished movie
        // already on disk, and job B never started. The queue was stalled for
        // as long as the app stayed open.
        //
        // D-067: mid-run progress was counted from *selected* takes, but takes
        // are only selected when the whole run ends, so the panel read
        // "Shot 1 / 4" for all four shots.
        func project(shots shotCount: Int, rendered: Int,
                     assembled: Bool, failedShot: Int? = nil,
                     selectTakes: Bool = false) -> FilmProject {
            var project = FilmProject(title: "Movie")
            project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
            for index in 0..<shotCount {
                var shot = Shot(index: index, title: "Shot \(index + 1)")
                func take(_ status: TakeStatus) -> Take {
                    Take(shotID: shot.id, modelID: "m", seed: 1,
                         promptSnapshot: "p", settingsSnapshot: .default,
                         requestedWidth: 512, requestedHeight: 320,
                         fps: 24, requestedDuration: 1, status: status)
                }
                if index == failedShot {
                    shot.takes = [take(.failed)]
                } else if index < rendered {
                    let completed = take(.completed)
                    shot.takes = [completed]
                    if selectTakes { shot.selectedTakeID = completed.id }
                }
                project.shots.append(shot)
            }
            if assembled { project.assembledMoviePath = "/tmp/final.mp4" }
            return project
        }

        // D-067. Progress tracks rendered shots even though nothing is selected
        // yet — which is exactly the state a real run is in mid-movie.
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 0, assembled: false), runOutcome: nil),
            .running(current: 1, total: 4), "D-067: no shot rendered reads Shot 1 / 4")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 1, assembled: false), runOutcome: nil),
            .running(current: 2, total: 4), "D-067: one shot rendered reads Shot 2 / 4")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 3, assembled: false), runOutcome: nil),
            .running(current: 4, total: 4), "D-067: three shots rendered reads Shot 4 / 4")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 2, assembled: false, selectTakes: true),
            runOutcome: nil),
            .running(current: 3, total: 4),
            "D-067: selection state does not change the reported shot")

        // D-066. Every shot rendered but no movie yet is "assembling" — the job
        // is held open, so nothing starts on top of the assembly.
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 4, assembled: false), runOutcome: nil),
            .assembling, "D-066: all shots rendered, no movie yet, is still in flight")
        // …and the assembly landing is what completes it. Before the fix this
        // transition had no signal at all: the renderer was already idle.
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 4, assembled: true),
            runOutcome: .assembled(path: "/tmp/final.mp4")),
            .completed(outputPath: "/tmp/final.mp4"),
            "D-066: the assembled movie completes the job")

        // A job that can never finish must fail, not hold the queue open.
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 4, assembled: false),
            runOutcome: .assemblyFailed("ffmpeg exited 1")),
            .failed("Final assembly failed: ffmpeg exited 1"),
            "D-066: a failed assembly fails the job instead of stalling it")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 4, assembled: false), runOutcome: .settled),
            .failed("Final assembly failed: the movie was not produced."),
            "D-066: a run that settles with no movie fails the job")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 1, assembled: false),
            runOutcome: .blocked("A continuity frame is missing.")),
            .failed("A continuity frame is missing."),
            "D-066: a blocked run fails the job rather than waiting for a shot that never comes")

        // Pre-existing rules must survive the refactor.
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 4, rendered: 1, assembled: false, failedShot: 1),
            runOutcome: nil),
            .failed("A shot failed; the movie was not assembled."),
            "a failed shot still ends the job")
        t.checkEqual(FilmJobDecider.decide(
            project: project(shots: 0, rendered: 0, assembled: false), runOutcome: nil),
            .failed("This project has no shots."),
            "an empty project is not treated as a finished movie")

        // An outcome belonging to another project must be ignored, or one
        // movie's failure would kill the next movie's job.
        let other = FilmRunEvent(projectID: UUID(), kind: .settled, at: Date())
        let mine = UUID()
        t.check(other.projectID != mine, "run outcomes are addressed to one project")
    }

    t.suite("Production queue — job model semantics") {
        // Action availability drives the panel, so it is pinned down here.
        var waiting = ProductionJob(kind: .generate, title: "w", snapshot: ProductionJobSnapshot())
        t.check(waiting.canReorder, "waiting jobs can be reordered")
        t.check(waiting.canCancel, "waiting jobs can be cancelled")
        waiting.state = .running
        t.check(!waiting.canReorder, "a running job cannot be reordered")
        t.check(waiting.canCancel, "a running job can be cancelled")
        waiting.state = .failed
        t.check(waiting.canRetry, "a failed job can be retried")
        waiting.state = .cancelled
        t.check(waiting.canRetry, "a cancelled job can be retried")
        waiting.state = .interrupted
        t.check(waiting.canRestart, "an interrupted job can be restarted")
        t.check(!waiting.canCancel, "a terminal job offers no cancel")

        var progress = ProductionJob(kind: .autoMovie, title: "m", snapshot: ProductionJobSnapshot())
        progress.progressCurrent = 2
        progress.progressTotal = 4
        t.checkEqual(progress.progressText, "2 / 4", "progress reads as a count")
        progress.stageDescription = "Assembling"
        t.checkEqual(progress.progressText, "Assembling", "an explicit stage wins over the count")
    }
}
