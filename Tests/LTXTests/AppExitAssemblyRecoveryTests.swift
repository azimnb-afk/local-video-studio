import Foundation
@testable import LTXVideoGeneratorCore

/// Quitting the app during an Auto Movie final assembly must not leave ffmpeg
/// running, and the next launch must not wait on, or adopt, what that attempt
/// left behind.
///
/// Measured before this change, with a parent that launches ffmpeg exactly as
/// `runFFmpeg` does (`Process`, piped stdout/stderr): whether the parent exits
/// normally or is killed, ffmpeg is re-parented to launchd and keeps encoding
/// at full CPU. The app's only termination hook stopped the MiniMax server.
///
/// On the next launch the job is restored `interrupted` with its assembly
/// still `running`. Nothing waits on that — no result is accepted for a job
/// that is not running, and Restart turns it into a new attempt — but if the
/// app died after an attempt had written its candidate and before adopting it,
/// that file was never removed.
func runAppExitAssemblyRecoveryTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppExit-\(UUID().uuidString)", isDirectory: true)
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

    /// The assembly calls a test starts, each able to be let go.
    final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var controllers: [AssemblyProcessController] = []
        private var released = false
        var obeysCancel = true
        var body: ((String, AssemblyProcessController) throws -> Void)?

        var count: Int { lock.lock(); defer { lock.unlock() }; return controllers.count }
        func controller(_ i: Int) -> AssemblyProcessController? {
            lock.lock(); defer { lock.unlock() }
            return controllers.indices.contains(i) ? controllers[i] : nil
        }
        func release() { lock.lock(); released = true; lock.unlock() }
        private var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }

        func assemble(_ output: String, _ controller: AssemblyProcessController) throws {
            lock.lock(); controllers.append(controller); lock.unlock()
            if let body { return try body(output, controller) }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !isReleased, !(obeysCancel && controller.isCancelled) { usleep(1000) }
            try controller.checkNotCancelled()
            FileManager.default.createFile(atPath: output, contents: Data("film".utf8))
        }
    }

    let clipDir = root.appendingPathComponent("clips", isDirectory: true)
    try? fm.createDirectory(at: clipDir, withIntermediateDirectories: true)

    func renderedMovie(_ title: String) -> ProductionJob {
        var p = FilmProject(title: title)
        p.workflowMode = "hybrid"
        p.shots = [Shot(index: 0, title: "One", compiledPrompt: "one")]
        p.settings.modelID = "ltx23_distilled_q4"
        var job = try! MovieRunSubmission.makeJob(project: p, workCount: 1, directorMode: "direct")
        let shot = job.snapshot.movieRuns[0].orderedShots[0]
        let clip = clipDir.appendingPathComponent("\(title).mp4").path
        write(clip, "clip \(title)")
        StoryboardRunScheduler.recordCompletion(
            in: &job.snapshot.movieRuns[0], shotID: shot.id, takeID: UUID(), outputPath: clip)
        return job
    }

    t.suite("App exit — in-flight assemblies are stopped") {
        MainActor.assumeIsolated {
            @MainActor func harness(_ held: Held) -> (ProductionQueueService, ProductionQueueCoordinator) {
                let c = ProductionQueueCoordinator(
                    store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(UUID()).json")),
                    restoreOnInit: false)
                let queue = ProductionQueueService(coordinator: c)
                queue.assembleOverride = { _, _, output, controller in try held.assemble(output, controller) }
                queue.attach(generationService: GenerationService(historyManager: HistoryManager(
                    rootDirectory: root.appendingPathComponent(UUID().uuidString))))
                return (queue, c)
            }

            // APPEXIT_4 — nothing running: returns at once.
            do {
                let (queue, _) = harness(Held())
                let start = Date()
                t.check(queue.stopAssembliesForAppExit(timeout: 3), "APPEXIT_4 with no assembly running, exit stops nothing")
                t.check(Date().timeIntervalSince(start) < 0.5, "APPEXIT_4 and does not wait")
            }

            // APPEXIT_1 — an assembly in flight is told to stop, and exit waits for it.
            do {
                let held = Held()
                let (queue, _) = harness(held)
                _ = queue.enqueue(renderedMovie("exit"))
                t.check(spin { held.count == 1 }, "APPEXIT_1 the assembly starts")
                let start = Date()
                let stopped = queue.stopAssembliesForAppExit(timeout: 3)
                t.check(held.controller(0)?.isCancelled == true,
                        "APPEXIT_RED APPEXIT_1 quitting stops the running assembly")
                t.check(stopped, "APPEXIT_1 exit sees the attempt return")
                t.check(Date().timeIntervalSince(start) < 2, "APPEXIT_1 promptly")
                held.release()
                _ = spin { queue.assemblyAttempts.isEmpty }
            }

            // APPEXIT_2 — through the shipping runFFmpeg: the real child process ends.
            do {
                let held = Held()
                held.body = { _, controller in
                    try FinalAssemblyService.runFFmpeg(["30"], ffmpeg: "/bin/sleep", controller: controller)
                }
                let (queue, _) = harness(held)
                _ = queue.enqueue(renderedMovie("process"))
                t.check(spin { held.controller(0)?.hasRunningProcess == true }, "APPEXIT_2 the child process is running")
                let start = Date()
                let stopped = queue.stopAssembliesForAppExit(timeout: 3)
                t.check(stopped && held.controller(0)?.hasRunningProcess == false,
                        "APPEXIT_RED APPEXIT_2 quitting ends the assembly's child process")
                t.check(Date().timeIntervalSince(start) < 2, "APPEXIT_2 without waiting out the timeout")
                held.controller(0)?.cancel()
                _ = spin { queue.assemblyAttempts.isEmpty }
            }

            // APPEXIT_3 — an attempt that does not return cannot hold the quit.
            do {
                let held = Held()
                held.obeysCancel = false
                let (queue, _) = harness(held)
                _ = queue.enqueue(renderedMovie("stuck"))
                t.check(spin { held.count == 1 }, "APPEXIT_3 the assembly starts")
                let start = Date()
                t.check(!queue.stopAssembliesForAppExit(timeout: 0.3), "APPEXIT_3 exit reports the attempt still running")
                t.check(Date().timeIntervalSince(start) < 1, "APPEXIT_3 and gives up at its bound")
                held.release()
                _ = spin { queue.assemblyAttempts.isEmpty }
            }
        }

        // APPEXIT_11 — the app's termination hook is what calls it.
        let source = (try? String(contentsOfFile: "LTXVideoGenerator/Sources/LTXVideoGeneratorApp.swift",
                                  encoding: .utf8)) ?? ""
        if let start = source.range(of: "func applicationWillTerminate("),
           let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) {
            let body = source[start.lowerBound..<end.lowerBound]
            t.check(body.contains("stopAssembliesForAppExit"),
                    "APPEXIT_RED APPEXIT_11 applicationWillTerminate stops in-flight assemblies")
            t.check(body.contains("stopOwnedServer"), "APPEXIT_11 and still stops the owned MiniMax server")
        } else {
            t.check(false, "APPEXIT_11 could not locate applicationWillTerminate")
        }
    }

    t.suite("App exit — the next launch recovers the assembly") {
        MainActor.assumeIsolated {
            let storeURL = root.appendingPathComponent("restore.json")

            // The session that quit: a movie assembling its second attempt.
            let before = ProductionQueueCoordinator(store: ProductionQueueStore(fileURL: storeURL), restoreOnInit: false)
            before.runner = { _ in .started }
            let job = before.enqueue(renderedMovie("quit"))
            var runs = before.job(id: job.id)!.snapshot.movieRuns
            _ = MovieAssemblyDriver.freezeClips(in: &runs[0])
            let final = MovieAssemblyDriver.outputURL(runID: runs[0].id).path
            runs[0].assembly.state = .running
            runs[0].assembly.attemptNumber = 2
            runs[0].assembly.outputPath = final
            before.updateMovieRuns(jobID: job.id, runs: runs)
            let runID = runs[0].id

            // What the dead attempts left beside the movie.
            let stale2 = MovieAssemblyDriver.candidatePath(forOutput: final, attempt: 2)
            let stale1 = MovieAssemblyDriver.candidatePath(forOutput: final, attempt: 1)
            write(stale2, "complete but never adopted")
            write(stale1, "older")
            let dir = URL(fileURLWithPath: final).deletingLastPathComponent()
            let lookalikes = ["final.attempt-2.candidate.mp4.keep", "final.attempt-20.candidate.mp4", "notes.txt"]
                .map { dir.appendingPathComponent($0).path }
            for path in lookalikes { write(path, "keep") }
            let otherRun = MovieAssemblyDriver.outputURL(runID: UUID()).path
            write(otherRun, "other run's film")
            let otherCandidate = MovieAssemblyDriver.candidatePath(forOutput: otherRun, attempt: 1)
            write(otherCandidate, "other run's candidate")

            // APPEXIT_5 — the next launch.
            let after = ProductionQueueCoordinator(store: ProductionQueueStore(fileURL: storeURL), restoreOnInit: true)
            let restored = after.job(id: job.id)
            t.checkEqual(restored?.state, .interrupted, "APPEXIT_5 the job is restored interrupted")
            t.checkEqual(after.activeJobID, nil, "APPEXIT_5 and nothing is active")
            t.check(!after.acceptsAssemblyResult(jobID: job.id, runID: runID, attempt: 2),
                    "APPEXIT_5 no result is awaited for the dead attempt")
            t.check(!after.applyAssemblyResult(jobID: job.id, runID: runID, attempt: 2,
                                               result: .completed(outputPath: stale2)),
                    "APPEXIT_9 a result claiming the dead attempt is refused")
            if let restored {
                // Per-work rows are shown for two or more works.
                var twoWorks = restored
                var sibling = restored.snapshot.movieRuns[0]
                sibling.id = UUID()
                sibling.batchIndex = 1
                twoWorks.snapshot.movieRuns.append(sibling)
                t.checkEqual(ProductionWorkPresenter.items(for: twoWorks).map(\.state), [.interrupted, .interrupted],
                             "APPEXIT_5 an assembling work reads interrupted, not assembling")
                t.check(restored.staysVisibleWhenTerminal && restored.restartWouldDoWork,
                        "APPEXIT_5 and stays visible with a Restart that has work to do")
                t.checkEqual(restored.outputPath, nil, "APPEXIT_7 the job has no output")
            }
            t.check(!fm.fileExists(atPath: final), "APPEXIT_7 no film was adopted")

            // APPEXIT_6 / _7 / _8 — Restart.
            let queue = ProductionQueueService(coordinator: after)
            let held = Held()
            held.body = { output, _ in
                FileManager.default.createFile(atPath: output, contents: Data("attempt 3".utf8))
            }
            queue.assembleOverride = { _, _, output, controller in try held.assemble(output, controller) }
            queue.attach(generationService: GenerationService(historyManager: HistoryManager(
                rootDirectory: root.appendingPathComponent(UUID().uuidString))))
            guard let restarted = after.retry(jobID: job.id) else {
                t.check(false, "APPEXIT_6 Restart produced a job"); return
            }
            t.check(spin { after.job(id: restarted.id)?.state == .completed }, "APPEXIT_6 the restarted assembly completes")
            let run = after.job(id: restarted.id)?.snapshot.movieRuns[0]
            t.checkEqual(run?.assembly.attemptNumber, 3, "APPEXIT_6 as attempt 3")
            t.checkEqual(run?.shotStates.map(\.attemptNumber), [1], "APPEXIT_6 without re-rendering its shot")
            t.checkEqual(read(final), "attempt 3", "APPEXIT_7 the film is the new attempt's, never the stale candidate")
            t.check(!fm.fileExists(atPath: stale2),
                    "APPEXIT_RED APPEXIT_7 the dead attempt's candidate is removed")
            t.check(!fm.fileExists(atPath: stale1), "APPEXIT_7 so is an older attempt's")
            t.check(lookalikes.allSatisfy { read($0) == "keep" }, "APPEXIT_8 look-alike files are untouched")
            t.checkEqual(read(otherRun), "other run's film", "APPEXIT_8 another run's film is untouched")
            t.checkEqual(read(otherCandidate), "other run's candidate", "APPEXIT_8 and so is its candidate")
            t.check(fm.fileExists(atPath: clipDir.appendingPathComponent("quit.mp4").path),
                    "APPEXIT_8 the rendered clip is untouched")
            t.check(!after.applyAssemblyResult(jobID: restarted.id, runID: runID, attempt: 2,
                                               result: .completed(outputPath: stale2)),
                    "APPEXIT_9 the dead attempt cannot settle the restarted job")
            t.checkEqual(after.job(id: job.id)?.state, .interrupted, "APPEXIT_9 the original stays interrupted")

            // APPEXIT_10 — the queue keeps moving afterwards.
            let next = queue.enqueue(renderedMovie("next"))
            t.check(spin { after.job(id: next.id)?.state == .completed }, "APPEXIT_10 the next job runs and completes")
        }
    }
}
