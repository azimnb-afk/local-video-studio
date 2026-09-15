import Foundation
@testable import LTXVideoGeneratorCore

/// An assembly ffmpeg left running by a crashed or force-quit session is ended
/// on the next launch — but only when it is provably that process.
///
/// A child launched through `Process` outlives the app: measured, it is
/// re-parented to launchd and keeps encoding. A clean quit now stops it
/// (0e0c73e); a crash runs no code at all. Nothing recorded which process an
/// attempt had started, so the next launch could not tell the orphan from
/// anything else.
///
/// Each in-flight attempt now keeps a lease: its job, run and attempt, the
/// session that owns it, its exact files, and the PID with the kernel's own
/// identity for it — start time to the microsecond, owner, resolved
/// executable, full argument vector. At launch a lease from another session is
/// reconciled by reading that one PID. It is signalled only if every field
/// matches and the arguments name the attempt's own work directory; its files
/// are removed only once nothing of it is left running.
///
/// Real processes are `/usr/bin/tail -f`, which runs until signalled and whose
/// argument vector carries a path; PID reuse is simulated with a stub
/// inspector, since a real reuse cannot be arranged.
func runOrphanAssemblyReaperTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OrphanReap-\(UUID().uuidString)", isDirectory: true)
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
    /// A work directory exactly where `assembleFrozen` makes one.
    func makeWorkDirectory() -> String {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltx-run-assembly-\(UUID().uuidString)").path
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        write(dir + "/concat.txt", "file 'clip.mp4'")
        workDirectories.append(dir)
        return dir
    }
    func ledger(_ name: String) -> AssemblyProcessLedger {
        AssemblyProcessLedger(fileURL: root.appendingPathComponent("\(name)-leases.json"))
    }
    func finalPath() -> String {
        root.appendingPathComponent("MovieRuns/\(UUID().uuidString)/final.mp4").path
    }
    func tail(_ path: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        p.arguments = ["-f", path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
        return p
    }
    func waitExit(_ p: Process, _ seconds: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, p.isRunning { usleep(10_000) }
        return !p.isRunning
    }

    // MARK: A stub inspector for what cannot be arranged for real

    final class StubInspector: ProcessInspecting {
        var processes: [Int32: ProcessInspection] = [:]
        var survives: Set<Int32> = []
        private(set) var inspected: [Int32] = []
        private(set) var terminated: [Int32] = []
        func inspect(pid: Int32) -> ProcessInspection {
            inspected.append(pid)
            return processes[pid] ?? .absent
        }
        func terminate(pid: Int32) -> Bool {
            terminated.append(pid)
            if !survives.contains(pid) { processes[pid] = .absent }
            return true
        }
    }

    func identity(workDirectory: String, start: UInt64 = 1_789_000_000, micro: UInt64 = 500) -> ProcessIdentity {
        ProcessIdentity(
            startSeconds: start, startMicroseconds: micro, userID: getuid(),
            executablePath: "/opt/homebrew/Cellar/ffmpeg/8.0/bin/ffmpeg",
            arguments: ["/opt/homebrew/bin/ffmpeg", "-y", "-f", "concat", "-safe", "0",
                        "-i", workDirectory + "/concat.txt", "-c", "copy", workDirectory + "/concatenated.mp4"])
    }

    /// A previous session's lease for attempt `attempt`, with its candidate on disk.
    func previousLease(pid: Int32? = 4242, attempt: Int = 1, owner: UUID = UUID()) -> AssemblyProcessLease {
        let final = finalPath()
        let work = makeWorkDirectory()
        let candidate = MovieAssemblyDriver.candidatePath(forOutput: final, attempt: attempt)
        write(candidate, "unadopted attempt \(attempt)")
        var lease = AssemblyProcessLease(
            jobID: UUID(), runID: UUID(), attempt: attempt, ownerAppInstanceID: owner,
            candidatePath: candidate, outputPath: final)
        lease.workDirectoryPath = work
        lease.pid = pid
        lease.identity = identity(workDirectory: work)
        return lease
    }

    func reconcile(_ l: AssemblyProcessLedger, _ inspector: ProcessInspecting,
                   current: UUID = UUID(), timeout: TimeInterval = 0.2,
                   isActive: @escaping (AssemblyProcessLease) -> Bool = { _ in false })
        -> [AssemblyOrphanReaper.Outcome] {
        AssemblyOrphanReaper.reconcile(ledger: l, currentAppInstanceID: current, isActive: isActive,
                                       inspector: inspector, terminationTimeout: timeout).map(\.outcome)
    }
    final class Outcomes: @unchecked Sendable { var value: [AssemblyOrphanReaper.Outcome]? }

    // MARK: Ownership proof

    t.suite("Orphan reaper — only a proven process is signalled") {
        // ORPHANREAP_1 — verified: signalled, then its exact files go.
        do {
            let l = ledger("verified"); let stub = StubInspector()
            let lease = previousLease()
            stub.processes[4242] = .identity(lease.identity!)
            l.upsert(lease)
            t.checkEqual(reconcile(l, stub), [.terminated], "ORPHANREAP_1 a verified previous-session process is ended")
            t.checkEqual(stub.terminated, [4242], "ORPHANREAP_1 by SIGTERM to exactly its PID")
            t.check(!fm.fileExists(atPath: lease.candidatePath), "ORPHANREAP_10 its unadopted candidate is removed")
            t.check(!fm.fileExists(atPath: lease.workDirectoryPath!), "ORPHANREAP_10 and its work directory")
            t.check(l.leases().isEmpty, "ORPHANREAP_1 and the lease is settled")
            t.checkEqual(stub.inspected.allSatisfy { $0 == 4242 }, true, "ORPHANREAP_22 only the recorded PID is read")
        }

        // ORPHANREAP_2 / _3 / _4 / _24 / _6 — anything short of a full match.
        func refused(_ label: String, _ change: (inout ProcessInspection, AssemblyProcessLease) -> Void) {
            let l = ledger(label); let stub = StubInspector()
            let lease = previousLease()
            var live = ProcessInspection.identity(lease.identity!)
            change(&live, lease)
            stub.processes[4242] = live
            l.upsert(lease)
            t.checkEqual(reconcile(l, stub), [.unverified], "\(label) is not proven")
            t.checkEqual(stub.terminated, [], "\(label) is never signalled")
            t.check(fm.fileExists(atPath: lease.candidatePath) && fm.fileExists(atPath: lease.workDirectoryPath!),
                    "ORPHANREAP_11 \(label): files a possible live writer uses are left")
        }
        func edit(_ live: inout ProcessInspection, _ mutate: (inout ProcessIdentity) -> Void) {
            if case .identity(var id) = live { mutate(&id); live = .identity(id) }
        }
        refused("ORPHANREAP_2 same PID, different start time") { live, _ in edit(&live) { $0.startMicroseconds += 1 } }
        refused("ORPHANREAP_2 same PID, different start second") { live, _ in edit(&live) { $0.startSeconds += 1 } }
        refused("ORPHANREAP_3 same PID, different executable") { live, _ in edit(&live) { $0.executablePath = "/usr/bin/tail" } }
        refused("ORPHANREAP_4 same PID, arguments for another attempt") { live, _ in
            edit(&live) { $0.arguments[$0.arguments.count - 1] = "/tmp/ltx-run-assembly-other/concatenated.mp4" }
        }
        refused("ORPHANREAP_4 same PID, one argument fewer") { live, _ in edit(&live) { $0.arguments.removeLast() } }
        refused("ORPHANREAP_24 an innocent process that reused the PID") { live, _ in
            live = .identity(ProcessIdentity(startSeconds: 1_789_999_999, startMicroseconds: 1, userID: getuid(),
                                             executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                                             arguments: ["/Applications/Safari.app/Contents/MacOS/Safari"]))
        }
        refused("ORPHANREAP_24 another user's process under the PID") { live, _ in edit(&live) { $0.userID = getuid() &+ 1 } }
        refused("ORPHANREAP_6 a process that cannot be read") { live, _ in live = .unreadable }

        // ORPHANREAP_6 — a lease whose own record cannot prove ownership.
        do {
            let l = ledger("no-identity"); let stub = StubInspector()
            var lease = previousLease()
            stub.processes[4242] = .identity(lease.identity!)
            lease.identity = nil
            l.upsert(lease)
            t.checkEqual(reconcile(l, stub), [.unverified], "ORPHANREAP_6 no recorded identity: not proven")
            var noWork = previousLease()
            stub.processes[4242] = .identity(noWork.identity!)
            noWork.workDirectoryPath = nil
            l.upsert(noWork)
            t.checkEqual(reconcile(l, stub), [.unverified], "ORPHANREAP_6 arguments not tied to a recorded work directory: not proven")
            t.checkEqual(stub.terminated, [], "ORPHANREAP_6 neither is signalled")
        }

        // Launched but never identified: the session died in between.
        do {
            let l = ledger("launching"); let stub = StubInspector()
            var lease = previousLease(pid: nil)
            lease.launching = true
            l.upsert(lease)
            t.checkEqual(reconcile(l, stub), [.unidentifiedLaunch], "ORPHANREAP_6 an unidentified launch is not signalled")
            t.checkEqual(stub.inspected, [], "ORPHANREAP_6 nor is any PID guessed at")
            t.check(fm.fileExists(atPath: lease.candidatePath) && fm.fileExists(atPath: lease.workDirectoryPath!),
                    "ORPHANREAP_11 and its files are left, since it may still be writing")
        }

        // Signalled but still running: no escalation, lease kept.
        do {
            let l = ledger("survives"); let stub = StubInspector()
            let lease = previousLease()
            stub.processes[4242] = .identity(lease.identity!)
            stub.survives = [4242]
            l.upsert(lease)
            t.checkEqual(reconcile(l, stub), [.survivedTermination], "ORPHANREAP_1 a process that ignores SIGTERM is reported")
            t.checkEqual(stub.terminated, [4242], "ORPHANREAP_23 signalled once, never escalated")
            t.check(fm.fileExists(atPath: lease.workDirectoryPath!), "ORPHANREAP_11 its files stay while it runs")
            t.checkEqual(l.leases().count, 1, "ORPHANREAP_1 and its lease is kept for the next launch")
        }
    }

    t.suite("Orphan reaper — dead processes, other attempts, adopted output") {
        // ORPHANREAP_5 — the PID is gone: already dead, exact files removed.
        do {
            let l = ledger("gone"); let stub = StubInspector()
            let lease = previousLease()
            l.upsert(lease)
            t.checkEqual(reconcile(l, stub), [.noProcess], "ORPHANREAP_5 a PID with no process is already dead")
            t.checkEqual(stub.terminated, [], "ORPHANREAP_5 nothing is signalled")
            t.check(!fm.fileExists(atPath: lease.candidatePath) && !fm.fileExists(atPath: lease.workDirectoryPath!),
                    "ORPHANREAP_10 its exact files are removed")
            t.check(l.leases().isEmpty, "ORPHANREAP_5 and the lease is settled")

            // Between two processes: none running.
            let idle = previousLease(pid: nil)
            l.upsert(idle)
            t.checkEqual(reconcile(l, stub), [.noProcess], "ORPHANREAP_5 a session that died between processes left none running")
            t.check(!fm.fileExists(atPath: idle.workDirectoryPath!), "ORPHANREAP_10 its work directory is removed")
        }

        // ORPHANREAP_17 — reconciling twice.
        do {
            let l = ledger("twice"); let stub = StubInspector()
            let lease = previousLease()
            stub.processes[4242] = .identity(lease.identity!)
            l.upsert(lease)
            _ = reconcile(l, stub)
            t.checkEqual(reconcile(l, stub), [], "ORPHANREAP_17 a second launch finds nothing left to do")
            t.checkEqual(stub.terminated, [4242], "ORPHANREAP_17 and signals nothing again")
        }

        // ORPHANREAP_7 / _8 / _9 — this session's attempt 2 beside the dead session's attempt 1.
        do {
            let l = ledger("attempts"); let stub = StubInspector()
            let current = UUID()
            let old = previousLease(pid: 111, attempt: 1)
            var new = previousLease(pid: 222, attempt: 2, owner: current)
            new.jobID = UUID(); new.runID = old.runID
            stub.processes[111] = .identity(old.identity!)
            stub.processes[222] = .identity(new.identity!)
            l.upsert(old); l.upsert(new)
            let outcomes = reconcile(l, stub, current: current)
            t.checkEqual(outcomes, [.terminated, .currentInstance], "ORPHANREAP_8 only attempt 1 is reaped")
            t.checkEqual(stub.terminated, [111], "ORPHANREAP_8 attempt 2's process is never signalled")
            t.checkEqual(stub.inspected.contains(222), false, "ORPHANREAP_7 this session's process is not even inspected")
            t.check(fm.fileExists(atPath: new.candidatePath) && fm.fileExists(atPath: new.workDirectoryPath!),
                    "ORPHANREAP_9 attempt 2's candidate and work directory are untouched")
            t.checkEqual(l.leases(), [new], "ORPHANREAP_9 and its lease stays")

            // A previous-session lease this session is running again right now.
            let active = previousLease(pid: 333)
            stub.processes[333] = .identity(active.identity!)
            l.upsert(active)
            let result = reconcile(l, stub, current: current, isActive: { $0.jobID == active.jobID })
            t.check(result.contains(.active) && !stub.terminated.contains(333),
                    "ORPHANREAP_8 an attempt active in this session is never reaped")
        }

        // Paths another lease still needs are not removed, even for a dead attempt.
        do {
            let l = ledger("shared"); let stub = StubInspector()
            let current = UUID()
            let mine = previousLease(pid: 555, owner: current)
            var stale = previousLease(pid: nil)
            stale.workDirectoryPath = mine.workDirectoryPath
            stale.candidatePath = mine.candidatePath
            l.upsert(mine); l.upsert(stale)
            _ = reconcile(l, stub, current: current)
            t.check(fm.fileExists(atPath: mine.candidatePath) && fm.fileExists(atPath: mine.workDirectoryPath!),
                    "ORPHANREAP_9 a path a protected lease names is never removed")
        }

        // ORPHANREAP_12 — adopted output.
        do {
            let l = ledger("adopted"); let stub = StubInspector()
            var lease = previousLease()
            write(lease.outputPath, "adopted film")
            try? fm.removeItem(atPath: lease.candidatePath)
            l.upsert(lease)
            _ = reconcile(l, stub)
            t.check(fm.contents(atPath: lease.outputPath) == Data("adopted film".utf8),
                    "ORPHANREAP_12 an adopted film is never removed")
            lease = previousLease()
            write(lease.outputPath, "adopted film")
            lease.candidatePath = lease.outputPath
            l.upsert(lease)
            _ = reconcile(l, stub)
            t.check(fm.fileExists(atPath: lease.outputPath), "ORPHANREAP_12 even when a lease names it as the candidate")
        }

        // ORPHANREAP_22 — a work directory the lease names but assembly did not make.
        do {
            let l = ledger("foreign-dir"); let stub = StubInspector()
            var lease = previousLease()
            let foreign = root.appendingPathComponent("Projects", isDirectory: true).path
            write(foreign + "/keep.txt", "user file")
            lease.workDirectoryPath = foreign
            l.upsert(lease)
            _ = reconcile(l, stub)
            t.check(fm.fileExists(atPath: foreign + "/keep.txt"),
                    "ORPHANREAP_22 only an assembly work directory in the temporary directory is ever removed")
        }

        // ORPHANREAP_22 / _23 — the reaper cannot list or kill by name.
        let source = (try? String(contentsOfFile: "LTXVideoGenerator/Sources/Services/FinalAssemblyService.swift",
                                  encoding: .utf8)) ?? ""
        if let start = source.range(of: "// MARK: - Orphaned assembly processes") {
            let section = String(source[start.lowerBound...])
            for forbidden in ["contentsOfDirectory", "enumerator(", "subpaths", "glob"] {
                t.check(!section.contains(forbidden), "ORPHANREAP_22 no directory listing (\(forbidden))")
            }
            for forbidden in ["killall", "pkill", "proc_listpids", "KERN_PROC_ALL", "SIGKILL", "/bin/ps"] {
                t.check(!section.contains(forbidden), "ORPHANREAP_23 no process-wide lookup or kill (\(forbidden))")
            }
        } else {
            t.check(false, "ORPHANREAP_22 could not locate the reaper source")
        }
    }

    // MARK: Real processes

    t.suite("Orphan reaper — a real attempt's process") {
        MainActor.assumeIsolated {
            let l = ledger("real")
            let coordinator = ProductionQueueCoordinator(
                store: ProductionQueueStore(fileURL: root.appendingPathComponent("real-queue.json")),
                restoreOnInit: false)
            let queue = ProductionQueueService(coordinator: coordinator, assemblyLedger: l)
            queue.attach(generationService: GenerationService(historyManager: HistoryManager(
                rootDirectory: root.appendingPathComponent(UUID().uuidString))))

            final class Box: @unchecked Sendable { var controller: AssemblyProcessController?; var work = ""; var candidate = "" }
            let box = Box()
            queue.assembleOverride = { _, _, candidate, controller in
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ltx-run-assembly-\(UUID().uuidString)").path
                try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: work + "/concat.txt", contents: Data())
                FileManager.default.createFile(atPath: candidate, contents: Data("partial".utf8))
                box.work = work; box.candidate = candidate
                controller.noteWorkDirectory(work)
                box.controller = controller
                try FinalAssemblyService.runFFmpeg(["-f", work + "/concat.txt"], ffmpeg: "/usr/bin/tail", controller: controller)
            }

            let control = tail(root.appendingPathComponent("control.txt").path)
            write(root.appendingPathComponent("control.txt").path, "")

            var p = FilmProject(title: "real")
            p.workflowMode = "hybrid"
            p.shots = [Shot(index: 0, title: "One", compiledPrompt: "one")]
            var job = try! MovieRunSubmission.makeJob(project: p, workCount: 1, directorMode: "direct")
            let clip = root.appendingPathComponent("real-clip.mp4").path
            write(clip, "clip")
            StoryboardRunScheduler.recordCompletion(
                in: &job.snapshot.movieRuns[0], shotID: job.snapshot.movieRuns[0].orderedShots[0].id,
                takeID: UUID(), outputPath: clip)
            let enqueued = queue.enqueue(job)
            t.check(spin { box.controller?.hasRunningProcess == true }, "ORPHANREAP_1 the attempt's process is running")
            workDirectories.append(box.work)

            // ORPHANREAP_RED — what a crash would leave on disk.
            let leases = l.leases()
            t.checkEqual(leases.count, 1, "ORPHANREAP_RED the running attempt has a persisted lease")
            if let lease = leases.first, let pid = lease.pid,
               case .identity(let live) = LiveProcessInspector().inspect(pid: pid) {
                t.check(AssemblyOrphanReaper.isVerified(live, for: lease),
                        "ORPHANREAP_RED its process can be proven from the lease alone")
                t.checkEqual(lease.attempt, 1, "ORPHANREAP_RED for exactly this attempt")
                t.checkEqual(lease.jobID, enqueued.id, "ORPHANREAP_RED of exactly this job")
                t.checkEqual(lease.workDirectoryPath, box.work, "ORPHANREAP_RED naming its own work directory")
                t.checkEqual(lease.candidatePath, box.candidate, "ORPHANREAP_RED and its own candidate")

                // ORPHANREAP_24 — the same live PID with a start time one microsecond off.
                var reused = lease
                reused.identity?.startMicroseconds += 1
                let probe = ledger("real-reuse")
                probe.upsert(reused)
                t.checkEqual(reconcile(probe, LiveProcessInspector()), [.unverified],
                             "ORPHANREAP_24 a real live process whose start time does not match is not signalled")
                t.check(box.controller?.hasRunningProcess == true, "ORPHANREAP_24 and keeps running")
            } else {
                t.check(false, "ORPHANREAP_RED its process can be proven from the lease alone")
            }

            // ORPHANREAP_7 — the running session never reaps its own attempt,
            // not even when asked as if it were a later launch.
            let asLater = UUID()
            let outcomes = Outcomes()
            Task { outcomes.value = await queue.reapOrphanedAssemblies(currentAppInstanceID: asLater).map(\.outcome) }
            _ = spin { outcomes.value != nil }
            t.checkEqual(outcomes.value ?? [], leases.isEmpty ? [] : [.active], "ORPHANREAP_7 an attempt running in this session is never reaped")
            t.check(box.controller?.hasRunningProcess == true, "ORPHANREAP_7 and its process keeps running")

            // ORPHANREAP_1 — the next launch after a crash: nothing active, another session.
            let reaped = reconcile(l, LiveProcessInspector(), current: asLater, timeout: 3)
            t.checkEqual(reaped, [.terminated], "ORPHANREAP_1 the verified orphan is ended")
            t.check(spin { box.controller?.hasRunningProcess == false }, "ORPHANREAP_1 its process exits")
            t.check(!fm.fileExists(atPath: box.work), "ORPHANREAP_10 its exact work directory is removed")
            t.check(control.isRunning, "UNRELATED_PROCESS_PRESERVED an unrelated process is untouched")
            _ = spin { queue.assemblyAttempts.isEmpty }
            t.check(l.leases().isEmpty, "ORPHANREAP_1 no lease is left")

            box.controller?.cancel()
            _ = spin { queue.assemblyAttempts.isEmpty }
            control.terminate()
            _ = waitExit(control)
        }
    }

    // MARK: Lease lifecycle in normal operation

    t.suite("Orphan reaper — leases end with their attempts") {
        MainActor.assumeIsolated {
            final class Hold: @unchecked Sendable {
                var mode = "succeed"; var released = false; var started = false
            }
            @MainActor func harness(_ name: String, _ hold: Hold) -> (ProductionQueueService, ProductionQueueCoordinator, AssemblyProcessLedger) {
                let l = ledger(name)
                let c = ProductionQueueCoordinator(
                    store: ProductionQueueStore(fileURL: root.appendingPathComponent("\(name)-queue.json")),
                    restoreOnInit: false)
                let queue = ProductionQueueService(coordinator: c, assemblyLedger: l)
                queue.assembleOverride = { _, _, output, controller in
                    hold.started = true
                    let deadline = Date().addingTimeInterval(10)
                    while Date() < deadline, !hold.released, !controller.isCancelled { usleep(1000) }
                    try controller.checkNotCancelled()
                    if hold.mode == "fail" { throw FinalAssemblyService.AssemblyError.ffmpegFailed("broken") }
                    FileManager.default.createFile(atPath: output, contents: Data("film".utf8))
                }
                queue.attach(generationService: GenerationService(historyManager: HistoryManager(
                    rootDirectory: root.appendingPathComponent(UUID().uuidString))))
                return (queue, c, l)
            }
            func movie(_ title: String) -> ProductionJob {
                var p = FilmProject(title: title)
                p.workflowMode = "hybrid"
                p.shots = [Shot(index: 0, title: "One", compiledPrompt: "one")]
                var job = try! MovieRunSubmission.makeJob(project: p, workCount: 1, directorMode: "direct")
                let clip = root.appendingPathComponent("\(title)-\(UUID().uuidString).mp4").path
                write(clip, "clip")
                StoryboardRunScheduler.recordCompletion(
                    in: &job.snapshot.movieRuns[0], shotID: job.snapshot.movieRuns[0].orderedShots[0].id,
                    takeID: UUID(), outputPath: clip)
                return job
            }

            for (mode, label) in [("succeed", "ORPHANREAP_13 success"), ("fail", "ORPHANREAP_14 failure")] {
                let hold = Hold(); hold.mode = mode
                let (queue, c, l) = harness(mode, hold)
                let job = queue.enqueue(movie(mode))
                t.check(spin { hold.started }, "\(label): the assembly starts")
                t.checkEqual(l.leases().count, 1, "ORPHANREAP_RED \(label): a lease exists while it runs")
                hold.released = true
                t.check(spin { c.job(id: job.id)?.state.isTerminal == true }, "\(label): the job settles")
                t.check(l.leases().isEmpty, "\(label): the lease is cleared")
            }

            do {
                let hold = Hold()
                let (queue, c, l) = harness("cancel", hold)
                let job = queue.enqueue(movie("cancel"))
                t.check(spin { hold.started }, "ORPHANREAP_15 the assembly starts")
                queue.cancel(jobID: job.id)
                t.check(spin { queue.assemblyAttempts.isEmpty }, "ORPHANREAP_15 the cancelled attempt returns")
                t.check(l.leases().isEmpty, "ORPHANREAP_15 cancellation clears the lease")
                t.checkEqual(c.job(id: job.id)?.state, .cancelled, "ORPHANREAP_15 the job stays cancelled")
            }

            do {
                let hold = Hold()
                let (queue, _, l) = harness("exit", hold)
                _ = queue.enqueue(movie("exit"))
                t.check(spin { hold.started }, "ORPHANREAP_16 the assembly starts")
                t.check(queue.stopAssembliesForAppExit(timeout: 3), "ORPHANREAP_16 a clean quit sees the attempt return")
                t.check(l.leases().isEmpty, "ORPHANREAP_16 and its lease is already cleared, before the app goes")
                _ = spin { queue.assemblyAttempts.isEmpty }
            }
        }
    }

    // MARK: The queue around a launch-time reap

    t.suite("Orphan reaper — the queue is untouched") {
        MainActor.assumeIsolated {
            let storeURL = root.appendingPathComponent("launch-queue.json")
            let before = ProductionQueueCoordinator(store: ProductionQueueStore(fileURL: storeURL), restoreOnInit: false)
            before.runner = { _ in .started }
            var p = FilmProject(title: "crashed")
            p.workflowMode = "hybrid"
            p.shots = [Shot(index: 0, title: "One", compiledPrompt: "one")]
            var job = try! MovieRunSubmission.makeJob(project: p, workCount: 1, directorMode: "direct")
            let clip = root.appendingPathComponent("crashed.mp4").path
            write(clip, "clip")
            StoryboardRunScheduler.recordCompletion(
                in: &job.snapshot.movieRuns[0], shotID: job.snapshot.movieRuns[0].orderedShots[0].id,
                takeID: UUID(), outputPath: clip)
            let queued = before.enqueue(job)
            var runs = before.job(id: queued.id)!.snapshot.movieRuns
            _ = MovieAssemblyDriver.freezeClips(in: &runs[0])
            runs[0].assembly.state = .running
            runs[0].assembly.outputPath = MovieAssemblyDriver.outputURL(runID: runs[0].id).path
            before.updateMovieRuns(jobID: queued.id, runs: runs)

            let l = ledger("launch")
            var lease = previousLease(pid: nil)
            lease.jobID = queued.id; lease.runID = runs[0].id; lease.attempt = 1
            l.upsert(lease)

            let historyRoot = root.appendingPathComponent("launch-history", isDirectory: true)
            write(historyRoot.appendingPathComponent("videos/kept.mp4").path, "history video")
            func historyFiles() -> [String] {
                (fm.enumerator(atPath: historyRoot.path)?.allObjects as? [String] ?? []).sorted()
            }

            let after = ProductionQueueCoordinator(store: ProductionQueueStore(fileURL: storeURL), restoreOnInit: true)
            let queue = ProductionQueueService(coordinator: after, assemblyLedger: l)
            queue.assembleOverride = { _, _, output, _ in
                FileManager.default.createFile(atPath: output, contents: Data("restarted film".utf8))
            }
            queue.attach(generationService: GenerationService(historyManager: HistoryManager(rootDirectory: historyRoot)))
            let historyBefore = historyFiles()
            let restored = after.job(id: queued.id)

            let outcomes = Outcomes()
            Task { outcomes.value = await queue.reapOrphanedAssemblies(currentAppInstanceID: UUID()).map(\.outcome) }
            t.check(spin { outcomes.value != nil }, "ORPHANREAP_19 the launch-time reap finishes")
            t.checkEqual(outcomes.value ?? [], [.noProcess], "ORPHANREAP_19 the crashed attempt is reconciled")
            t.checkEqual(after.job(id: queued.id), restored, "ORPHANREAP_19 the job is exactly as restored")
            t.checkEqual(after.job(id: queued.id)?.state, .interrupted, "ORPHANREAP_19 still interrupted")
            t.checkEqual(historyFiles(), historyBefore, "ORPHANREAP_18 History is unchanged")
            t.check(!fm.fileExists(atPath: MovieAssemblyDriver.outputURL(runID: runs[0].id).path),
                    "ORPHANREAP_19 nothing was adopted")

            // ORPHANREAP_20 — Restart still works.
            guard let restarted = after.retry(jobID: queued.id) else {
                t.check(false, "ORPHANREAP_20 Restart produced a job"); return
            }
            t.check(spin { after.job(id: restarted.id)?.state == .completed }, "ORPHANREAP_20 the restarted assembly completes")
            t.checkEqual(after.job(id: restarted.id)?.snapshot.movieRuns[0].assembly.attemptNumber, 2,
                         "ORPHANREAP_20 as attempt 2")

            // ORPHANREAP_21 — and the job after it.
            var nextProject = p
            nextProject.title = "next"
            var next = try! MovieRunSubmission.makeJob(project: nextProject, workCount: 1, directorMode: "direct")
            StoryboardRunScheduler.recordCompletion(
                in: &next.snapshot.movieRuns[0], shotID: next.snapshot.movieRuns[0].orderedShots[0].id,
                takeID: UUID(), outputPath: clip)
            let nextJob = queue.enqueue(next)
            t.check(spin { after.job(id: nextJob.id)?.state == .completed }, "ORPHANREAP_21 the next job completes")
            t.check(l.leases().isEmpty, "ORPHANREAP_21 and no lease is left behind")
        }
    }
}
