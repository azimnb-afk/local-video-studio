import Foundation
@testable import LTXVideoGeneratorCore

/// Cancelling an Auto Movie job must stop its final assembly, and the files
/// that assembly was writing must not outlive it.
///
/// The assembly ran ffmpeg from a detached task with no handle: cancelling the
/// job stopped the renderer and marked the job cancelled while ffmpeg kept
/// going. The late result was already refused (3fecf93), but by then the movie
/// had been written straight to the run's `final.mp4` — a path every attempt
/// of that run shares — so a cancelled attempt left an orphan movie behind, or
/// overwrote the movie a later attempt had just finished.
///
/// The queue cases drive the real `ProductionQueueService` with only the
/// assembler replaced (`assembleOverride`), so no ffmpeg runs. The process
/// cases run `/bin/sleep` and `/usr/bin/false` through the shipping
/// `runFFmpeg`. Waiting spins the main run loop, bounded by a turn count.
func runAssemblyProcessCancellationTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AsmProc-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default

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

    // MARK: A stand-in assembler the test holds open

    /// What one assembly call does once it is let go.
    enum Behavior {
        /// Stops as soon as its attempt is cancelled, leaving `partial` (if any)
        /// where ffmpeg was writing, and reports the stop as ffmpeg would.
        case obeysCancel(partial: String?)
        /// Takes no notice of cancellation: finishes the movie when released.
        case finishesWhenReleased(String)
        /// Finishes the movie as soon as it starts.
        case succeeds(String)
        /// A genuine failure after writing part of the movie.
        case fails(partial: String)
    }

    final class Gate: @unchecked Sendable {
        struct Call { let jobID: UUID?; let output: String; let controller: AssemblyProcessController }
        private let lock = NSLock()
        private var calls: [Call] = []
        private var released: Set<Int> = []
        private var finished: Set<Int> = []
        private var behaviors: [Behavior] = []

        func plan(_ behavior: Behavior) { lock.lock(); behaviors.append(behavior); lock.unlock() }
        func release(_ index: Int) { lock.lock(); released.insert(index); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
        func call(_ index: Int) -> Call? {
            lock.lock(); defer { lock.unlock() }
            return calls.indices.contains(index) ? calls[index] : nil
        }
        func isFinished(_ index: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return finished.contains(index) }

        func assemble(output: String, controller: AssemblyProcessController) throws {
            lock.lock()
            let index = calls.count
            calls.append(Call(jobID: nil, output: output, controller: controller))
            let behavior = behaviors.indices.contains(index) ? behaviors[index] : .succeeds("movie")
            lock.unlock()
            defer { lock.lock(); finished.insert(index); lock.unlock() }

            func isReleased() -> Bool { lock.lock(); defer { lock.unlock() }; return released.contains(index) }
            func put(_ text: String) {
                FileManager.default.createFile(atPath: output, contents: Data(text.utf8))
            }
            let deadline = Date().addingTimeInterval(10)
            switch behavior {
            case .succeeds(let movie):
                put(movie)
            case .obeysCancel(let partial):
                while Date() < deadline, !controller.isCancelled, !isReleased() { usleep(1000) }
                if let partial { put(partial) }
                throw FinalAssemblyService.AssemblyError.ffmpegFailed("Exiting normally, received signal 15.")
            case .finishesWhenReleased(let movie):
                while Date() < deadline, !isReleased() { usleep(1000) }
                put(movie)
            case .fails(let partial):
                put(partial)
                throw FinalAssemblyService.AssemblyError.ffmpegFailed("Invalid data found when processing input")
            }
        }
    }

    // MARK: Harness

    let clipDir = root.appendingPathComponent("clips", isDirectory: true)
    try? fm.createDirectory(at: clipDir, withIntermediateDirectories: true)

    /// A one-work movie whose shots have all rendered, so admitting it goes
    /// straight to final assembly.
    func renderedMovie(_ title: String) -> ProductionJob {
        var p = FilmProject(title: title)
        p.workflowMode = "hybrid"
        p.shots = [Shot(index: 0, title: "One", compiledPrompt: "one"),
                   Shot(index: 1, title: "Two", compiledPrompt: "two")]
        p.settings.modelID = "ltx23_distilled_q4"
        var job = try! MovieRunSubmission.makeJob(project: p, workCount: 1, directorMode: "direct")
        for i in job.snapshot.movieRuns.indices {
            for shot in job.snapshot.movieRuns[i].orderedShots {
                let clip = clipDir.appendingPathComponent("\(title)-\(shot.index).mp4").path
                write(clip, "clip \(title) \(shot.index)")
                job.snapshot.movieRuns[i].update(shot.id) {
                    $0.state = .completed; $0.takeID = UUID(); $0.outputPath = clip
                }
            }
        }
        return job
    }

    t.suite("Assembly cancellation — through the production queue") {
        MainActor.assumeIsolated {
            @MainActor func harness() -> (ProductionQueueService, ProductionQueueCoordinator, Gate) {
                let coordinator = ProductionQueueCoordinator(
                    store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(UUID()).json")),
                    restoreOnInit: false)
                let queue = ProductionQueueService(coordinator: coordinator)
                let gate = Gate()
                queue.assembleOverride = { _, _, output, controller in
                    try gate.assemble(output: output, controller: controller)
                }
                queue.attach(generationService: GenerationService(historyManager: HistoryManager(
                    rootDirectory: root.appendingPathComponent(UUID().uuidString))))
                return (queue, coordinator, gate)
            }
            func finalPath(_ c: ProductionQueueCoordinator, _ id: UUID) -> String {
                MovieAssemblyDriver.outputURL(runID: c.job(id: id)!.snapshot.movieRuns[0].id).path
            }
            func runDirectoryContents(_ c: ProductionQueueCoordinator, _ id: UUID) -> [String] {
                let dir = URL(fileURLWithPath: finalPath(c, id)).deletingLastPathComponent().path
                return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            }

            // Files no assembly may ever remove: the rendered clips, a History
            // video, and an unrelated file next to the run's movie.
            let historyVideo = root.appendingPathComponent("History/videos/kept.mp4").path
            write(historyVideo, "history")

            // ASSEMBLYPROC_1 / _2 / _3 / _8 / _14 / _15 — cancel while ffmpeg is running.
            do {
                let (queue, coordinator, gate) = harness()
                gate.plan(.obeysCancel(partial: "partial"))
                let job = queue.enqueue(renderedMovie("cancel"))
                t.check(spin { gate.count == 1 }, "ASSEMBLYPROC_1 the assembly starts")
                let neighbour = root.appendingPathComponent("unrelated.txt").path
                write(neighbour, "keep")
                let sibling = URL(fileURLWithPath: finalPath(coordinator, job.id))
                    .deletingLastPathComponent().appendingPathComponent("notes.txt").path
                write(sibling, "keep")

                // ASSEMBLYPROC_2 — cancelling a different job leaves this attempt alone.
                let other = queue.enqueue(renderedMovie("waiting"))
                queue.cancel(jobID: other.id)
                t.check(gate.call(0)?.controller.isCancelled == false,
                        "ASSEMBLYPROC_2 cancelling another job does not stop this assembly")

                queue.cancel(jobID: job.id)
                t.check(spin { gate.call(0)?.controller.isCancelled == true },
                        "ASSEMBLYCANCEL_RED ASSEMBLYPROC_1 cancelling the job stops its running assembly")
                // ASSEMBLYPROC_13 — cancelling again is harmless.
                queue.cancel(jobID: job.id)
                gate.release(0)
                t.check(spin { gate.isFinished(0) && queue.assemblyAttempts.isEmpty },
                        "ASSEMBLYPROC_1 the stopped assembly returns")
                _ = spin(maxTurns: 20) { false }
                let cancelled = coordinator.job(id: job.id)
                t.checkEqual(cancelled?.state, .cancelled, "ASSEMBLYPROC_8 the job stays cancelled")
                t.check(cancelled?.snapshot.movieRuns[0].assembly.state != .completed,
                        "ASSEMBLYPROC_8 its assembly is not recorded completed")
                if let written = gate.call(0)?.output {
                    t.check(!fm.fileExists(atPath: written),
                            "ASSEMBLYPROC_3 the partial file the cancelled attempt wrote is removed")
                }
                t.check(!fm.fileExists(atPath: finalPath(coordinator, job.id)),
                        "ASSEMBLYPROC_3 no movie is left at the run's final path")
                let finishedAt = cancelled?.finishedAt
                _ = spin(maxTurns: 20) { false }
                t.checkEqual(coordinator.job(id: job.id)?.finishedAt, finishedAt,
                             "ASSEMBLYPROC_15 the cancelled job is not settled a second time")
                t.checkEqual(read(sibling), "keep", "ASSEMBLYPROC_20 a file beside the movie survives")
                t.checkEqual(read(neighbour), "keep", "ASSEMBLYPROC_20 an unrelated file survives")
            }

            // ASSEMBLYPROC_14 — cancelled before the attempt wrote anything.
            do {
                let (queue, coordinator, gate) = harness()
                gate.plan(.obeysCancel(partial: nil))
                let job = queue.enqueue(renderedMovie("empty"))
                t.check(spin { gate.count == 1 }, "ASSEMBLYPROC_14 the assembly starts")
                queue.cancel(jobID: job.id)
                gate.release(0)
                t.check(spin { gate.isFinished(0) && queue.assemblyAttempts.isEmpty },
                        "ASSEMBLYPROC_14 a stop with no output file is harmless")
                t.checkEqual(coordinator.job(id: job.id)?.state, .cancelled, "ASSEMBLYPROC_14 and the job stays cancelled")
            }

            // ASSEMBLYPROC_4 / _12 — cancelled, then ffmpeg finishes the movie anyway.
            do {
                let (queue, coordinator, gate) = harness()
                gate.plan(.finishesWhenReleased("late movie"))
                let job = queue.enqueue(renderedMovie("late"))
                t.check(spin { gate.count == 1 }, "ASSEMBLYPROC_4 the assembly starts")
                queue.cancel(jobID: job.id)
                gate.release(0)
                t.check(spin { gate.isFinished(0) && queue.assemblyAttempts.isEmpty }, "ASSEMBLYPROC_4 the late result arrives")
                _ = spin(maxTurns: 20) { false }
                t.checkEqual(coordinator.job(id: job.id)?.state, .cancelled,
                             "ASSEMBLYPROC_12 cancel-then-complete leaves the job cancelled")
                if let written = gate.call(0)?.output {
                    t.check(!fm.fileExists(atPath: written),
                            "ASSEMBLYPROC_4 the complete but unadopted movie is removed")
                }
                t.check(!fm.fileExists(atPath: finalPath(coordinator, job.id)),
                        "ASSEMBLYPROC_4 and never appears at the final path")
                t.checkEqual(coordinator.job(id: job.id)?.outputPath, nil,
                             "ASSEMBLYPROC_7 the late result gives the cancelled job no output")
            }

            // ASSEMBLYPROC_5 / _6 / _11 — a normal success, then a cancel that comes too late.
            do {
                let (queue, coordinator, gate) = harness()
                gate.plan(.succeeds("finished movie"))
                let job = queue.enqueue(renderedMovie("ok"))
                t.check(spin { coordinator.job(id: job.id)?.state == .completed },
                        "ASSEMBLYPROC_6 a normal assembly completes the job")
                let final = finalPath(coordinator, job.id)
                t.checkEqual(coordinator.job(id: job.id)?.outputPath, final,
                             "ASSEMBLYPROC_6 with the run's final path as its output")
                t.checkEqual(read(final), "finished movie", "ASSEMBLYPROC_6 holding the finished movie")
                t.checkEqual(runDirectoryContents(coordinator, job.id), ["final.mp4"],
                             "ASSEMBLYPROC_6 and nothing else left beside it")
                queue.cancel(jobID: job.id)
                _ = spin(maxTurns: 20) { false }
                t.checkEqual(coordinator.job(id: job.id)?.state, .completed,
                             "ASSEMBLYPROC_11 complete-then-cancel keeps the job completed")
                t.checkEqual(read(final), "finished movie", "ASSEMBLYPROC_5 the adopted movie survives the cancel")
            }

            // ASSEMBLYPROC_9 / _10 — attempt 1 is cancelled but keeps running; the
            // retry's attempt 2 finishes first; attempt 1 finishes afterwards.
            do {
                let (queue, coordinator, gate) = harness()
                gate.plan(.finishesWhenReleased("attempt 1"))
                gate.plan(.succeeds("attempt 2"))
                let job = queue.enqueue(renderedMovie("retry"))
                t.check(spin { gate.count == 1 }, "ASSEMBLYPROC_9 attempt 1 starts")
                queue.cancel(jobID: job.id)
                let retried = coordinator.retry(jobID: job.id)
                t.check(retried != nil, "ASSEMBLYPROC_9 the cancelled job can be retried")
                if let retried {
                    t.check(spin { coordinator.job(id: retried.id)?.state == .completed },
                            "ASSEMBLYPROC_9 attempt 2 completes")
                    let final = finalPath(coordinator, retried.id)
                    t.checkEqual(final, finalPath(coordinator, job.id), "ASSEMBLYPROC_9 both attempts share the run's final path")
                    t.checkEqual(coordinator.job(id: retried.id)?.snapshot.movieRuns[0].assembly.attemptNumber, 2,
                                 "ASSEMBLYPROC_9 as attempt 2")
                    t.check(gate.call(0)?.controller.isCancelled == true && gate.call(1)?.controller.isCancelled == false,
                            "ASSEMBLYPROC_10 only attempt 1 was told to stop")
                    gate.release(0)
                    t.check(spin { gate.isFinished(0) && queue.assemblyAttempts.isEmpty }, "ASSEMBLYPROC_10 attempt 1 returns late")
                    _ = spin(maxTurns: 20) { false }
                    t.checkEqual(read(final), "attempt 2",
                                 "ASSEMBLYPROC_10 attempt 1's late movie does not replace attempt 2's")
                    if let written = gate.call(0)?.output, written != final {
                        t.check(!fm.fileExists(atPath: written), "ASSEMBLYPROC_10 attempt 1's own file is removed")
                    }
                    t.checkEqual(coordinator.job(id: retried.id)?.state, .completed, "ASSEMBLYPROC_10 attempt 2's job stays completed")
                    t.checkEqual(coordinator.job(id: job.id)?.state, .cancelled, "ASSEMBLYPROC_10 attempt 1's job stays cancelled")
                }
            }

            // ASSEMBLYPROC_16 — the job behind a cancelled assembly runs its own.
            do {
                let (queue, coordinator, gate) = harness()
                gate.plan(.obeysCancel(partial: "partial"))
                gate.plan(.succeeds("next movie"))
                let first = queue.enqueue(renderedMovie("first"))
                let next = queue.enqueue(renderedMovie("next"))
                t.check(spin { gate.count == 1 }, "ASSEMBLYPROC_16 the first assembly starts")
                queue.cancel(jobID: first.id)
                gate.release(0)
                t.check(spin { coordinator.job(id: next.id)?.state == .completed },
                        "ASSEMBLYPROC_16 the next job starts and completes")
                t.check(gate.call(1)?.controller.isCancelled == false,
                        "ASSEMBLYPROC_16 its assembly is not stopped by the earlier cancel")
                t.checkEqual(read(finalPath(coordinator, next.id)), "next movie", "ASSEMBLYPROC_16 with its own movie")
            }

            // ASSEMBLYPROC_18 / _19 — a genuine failure keeps its meaning and its partial file goes.
            do {
                let (queue, coordinator, gate) = harness()
                gate.plan(.fails(partial: "broken"))
                let job = queue.enqueue(renderedMovie("broken"))
                t.check(spin { coordinator.job(id: job.id)?.state == .failed },
                        "ASSEMBLYPROC_18 a genuine assembly failure still fails the job")
                let run = coordinator.job(id: job.id)?.snapshot.movieRuns[0]
                t.checkEqual(run?.assembly.state, .failed, "ASSEMBLYPROC_18 the work's assembly is failed")
                t.check(run?.assembly.failureReason?.isEmpty == false, "ASSEMBLYPROC_18 with a reason")
                if let written = gate.call(0)?.output {
                    t.check(!fm.fileExists(atPath: written), "ASSEMBLYPROC_19 the failed attempt's partial file is removed")
                }
                t.check(!fm.fileExists(atPath: finalPath(coordinator, job.id)),
                        "ASSEMBLYPROC_19 and no movie is left at the final path")
            }

            // ASSEMBLYPROC_17 — cancelled after the assembly was dispatched but
            // before its task began: ffmpeg is never started.
            do {
                let (queue, coordinator, gate) = harness()
                let job = queue.enqueue(renderedMovie("early"))
                queue.cancel(jobID: job.id)
                _ = spin(maxTurns: 60) { false }
                t.checkEqual(gate.count, 0, "ASSEMBLYPROC_17 an assembly cancelled before it began never runs")
                t.checkEqual(coordinator.job(id: job.id)?.state, .cancelled, "ASSEMBLYPROC_17 and the job stays cancelled")
                t.check(queue.assemblyAttempts.isEmpty, "ASSEMBLYPROC_17 nothing is left registered")
            }

            let clips = ((try? fm.contentsOfDirectory(atPath: clipDir.path)) ?? [])
            t.checkEqual(clips.count, 20, "ASSEMBLYPROC_20 every rendered clip survives")
            t.checkEqual(read(historyVideo), "history", "ASSEMBLYPROC_20 the History video survives")
        }
    }

    // MARK: The attempt's own file

    t.suite("Assembly cancellation — an attempt's candidate file") {
        let runID = UUID()
        let runDir = root.appendingPathComponent("MovieRuns/\(runID.uuidString)", isDirectory: true)
        let output = runDir.appendingPathComponent("final.mp4").path
        let one = MovieAssemblyDriver.candidatePath(forOutput: output, attempt: 1)
        let two = MovieAssemblyDriver.candidatePath(forOutput: output, attempt: 2)
        t.check(one != two && one != output && two != output,
                "ASSEMBLYPROC_9 each attempt has its own file, distinct from the final movie")
        t.checkEqual(URL(fileURLWithPath: one).deletingLastPathComponent().path, runDir.path,
                     "ASSEMBLYPROC_9 beside the final movie, so adopting it is a rename")
        t.checkEqual(URL(fileURLWithPath: one).lastPathComponent, "final.attempt-1.candidate.mp4",
                     "ASSEMBLYPROC_9 named for its attempt")

        // Neighbours that share the directory, a prefix or the extension.
        let lookalikes = ["final.attempt-1.candidate.mp4.keep", "final.attempt-10.candidate.mp4",
                          "final.attempt-1.mp4", "other.mp4"].map { runDir.appendingPathComponent($0).path }
        for path in lookalikes { write(path, "keep") }
        let otherRunFinal = root.appendingPathComponent("MovieRuns/\(UUID().uuidString)/final.mp4").path
        write(otherRunFinal, "other run")

        // ASSEMBLYPROC_5 — adopting replaces the final movie and consumes the candidate.
        write(output, "old movie")
        write(two, "attempt 2")
        do { try MovieAssemblyDriver.adoptCandidate(two, as: output) } catch {
            t.check(false, "ASSEMBLYPROC_5 adoption threw \(error)")
        }
        t.checkEqual(read(output), "attempt 2", "ASSEMBLYPROC_5 the accepted attempt's movie becomes the final movie")
        t.check(!fm.fileExists(atPath: two), "ASSEMBLYPROC_5 and its candidate file is gone")

        // ASSEMBLYPROC_3 / _4 — discarding removes exactly the attempt's file.
        write(one, "attempt 1")
        MovieAssemblyDriver.discardCandidate(one, output: output)
        t.check(!fm.fileExists(atPath: one), "ASSEMBLYPROC_3 the unadopted attempt's file is removed")
        t.checkEqual(read(output), "attempt 2", "ASSEMBLYPROC_5 the adopted final movie survives")
        t.check(lookalikes.allSatisfy { read($0) == "keep" },
                "ASSEMBLYPROC_20 files that merely look alike are not touched")
        t.checkEqual(read(otherRunFinal), "other run", "ASSEMBLYPROC_20 another run's movie is not touched")

        // ASSEMBLYPROC_14 — nothing written, nothing to remove.
        MovieAssemblyDriver.discardCandidate(one, output: output)
        t.check(!fm.fileExists(atPath: one), "ASSEMBLYPROC_14 discarding a file never written is harmless")

        // ASSEMBLYPROC_20 — never the final movie, never a directory.
        MovieAssemblyDriver.discardCandidate(output, output: output)
        t.checkEqual(read(output), "attempt 2", "ASSEMBLYPROC_20 the final movie can never be discarded as a candidate")
        let folder = runDir.appendingPathComponent("folder.candidate.mp4", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        write(folder.appendingPathComponent("inside.mp4").path, "keep")
        MovieAssemblyDriver.discardCandidate(folder.path, output: output)
        t.checkEqual(read(folder.appendingPathComponent("inside.mp4").path), "keep",
                     "ASSEMBLYPROC_20 a directory is never removed, recursively or otherwise")
    }

    // MARK: The process itself

    t.suite("Assembly cancellation — the ffmpeg process") {
        /// Runs `runFFmpeg` off the main thread; returns the thrown error once it
        /// returns, or nil if it has not returned within `timeout`.
        func launch(_ args: [String], _ executable: String, _ controller: AssemblyProcessController,
                    until started: (() -> Bool)? = nil, then act: () -> Void = {},
                    timeout: TimeInterval) -> (returned: Bool, error: Error?) {
            final class Box: @unchecked Sendable { var error: Error? }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                do { try FinalAssemblyService.runFFmpeg(args, ffmpeg: executable, controller: controller) }
                catch { box.error = error }
                done.signal()
            }
            if let started {
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline, !started() { usleep(1000) }
            }
            act()
            let returned = done.wait(timeout: .now() + timeout) == .success
            return (returned, box.error)
        }

        // ASSEMBLYPROC_1 — cancel terminates the running process.
        let running = AssemblyProcessController()
        var sawRunning = false
        let stopped = launch(["4"], "/bin/sleep", running,
                             until: { running.hasRunningProcess },
                             then: { sawRunning = running.hasRunningProcess; running.cancel() },
                             timeout: 2)
        t.check(sawRunning, "ASSEMBLYPROC_1 the process is held by its attempt while it runs")
        t.check(stopped.returned, "ASSEMBLYCANCEL_RED ASSEMBLYPROC_1 cancel terminates the running process")
        t.check(!running.hasRunningProcess, "ASSEMBLYPROC_1 and it is released once it exits")

        // ASSEMBLYPROC_13 — a cancelled attempt never launches, and cancelling twice is harmless.
        let early = AssemblyProcessController()
        early.cancel(); early.cancel()
        let refused = launch(["4"], "/bin/sleep", early, timeout: 1)
        t.check(refused.returned && refused.error != nil,
                "ASSEMBLYPROC_13 an attempt cancelled before launch starts no process")

        // ASSEMBLYPROC_18 — a genuine non-zero exit is still an ffmpeg failure.
        let genuine = AssemblyProcessController()
        let failed = launch([], "/usr/bin/false", genuine, timeout: 2)
        var isFFmpegFailure = false
        if case .ffmpegFailed? = failed.error as? FinalAssemblyService.AssemblyError { isFFmpegFailure = true }
        t.check(failed.returned && isFFmpegFailure, "ASSEMBLYPROC_18 a real failure is reported as a failure, not a cancel")
    }
}
