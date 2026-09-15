import Foundation
import Combine
@testable import LTXVideoGeneratorCore

/// A render backend's process tree lives and dies with the render that owns it.
///
/// Measured before this change: LTXBridge (`python -c` wrapper → the
/// `mlx_video.generate_av` child) and LTX2MLX (the runtime CLI and the ffmpeg it
/// starts) survived the app. Cancel stopped only the process the app launched,
/// so anything that process had started kept running under launchd. After a
/// crash nothing stopped them at all: a quiet child lived until its next write
/// to a pipe nobody read, at full CPU. And Retry reuses the request id, which
/// was also the output file name — so a surviving attempt 1 wrote to the very
/// path attempt 2 was being adopted from.
///
/// Every process here is a disposable scratch process — `/bin/sh`, `sleep`,
/// `tail`, `/usr/bin/python3` — and every PID a test creates is cleaned up by
/// that PID. No existing user process is inspected or signalled.
func runRenderBackendParentDeathTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RenderOrphan-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fm = FileManager.default
    var created: [Int32] = []
    defer {
        for pid in created where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? fm.removeItem(at: root)
    }

    func spin(maxTurns: Int = 400, until done: () -> Bool) -> Bool {
        for _ in 0..<maxTurns {
            if done() { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return done()
    }
    func waitFor(_ seconds: TimeInterval, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if done() { return true }; usleep(20_000) }
        return done()
    }
    func alive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }
    func readPID(_ path: String) -> Int32? {
        (try? String(contentsOfFile: path, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    func read(_ path: String) -> String? {
        fm.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: The tree on cancel

    t.suite("RENDERORPHAN — cancel stops the whole render tree") {
        // RENDERORPHAN_2 — the real LTX2MLX launch path: a runtime that starts a
        // helper (as it starts ffmpeg), and a helper that ignores SIGTERM.
        do {
            let helperPID = root.appendingPathComponent("ltx2mlx-helper.pid").path
            let stubbornPID = root.appendingPathComponent("ltx2mlx-stubborn.pid").path
            let backend = LTX2MLXBackend()
            final class Done: @unchecked Sendable { var error: Error?; var finished = false }
            let done = Done()
            let script = "sleep 300 & echo $! > '\(helperPID)'; "
                + "sh -c \"trap '' TERM; exec sleep 301\" & echo $! > '\(stubbornPID)'; wait"
            Task.detached {
                do {
                    try await backend.run(executable: "/bin/sh", arguments: ["-c", script],
                                          environment: ["PATH": "/usr/bin:/bin"], progressHandler: { _, _ in })
                } catch { done.error = error }
                done.finished = true
            }
            t.check(waitFor(5) { readPID(helperPID) != nil && readPID(stubbornPID) != nil },
                    "RENDERORPHAN_2 the runtime and its helpers are running")
            let helper = readPID(helperPID) ?? -1, stubborn = readPID(stubbornPID) ?? -1
            created += [helper, stubborn]
            backend.cancelActiveGeneration()
            t.check(waitFor(5) { done.finished }, "RENDERORPHAN_2 the cancelled render returns")
            t.check(waitFor(3) { !alive(helper) }, "RENDERORPHAN_RED RENDERORPHAN_2 cancel stops a helper the runtime started")
            t.check(waitFor(12) { !alive(stubborn) }, "RENDERORPHAN_2 and, after the grace period, one that ignores SIGTERM")
            var cancelled = false
            if case .cancelled? = done.error as? LTXError { cancelled = true }
            t.check(cancelled, "RENDERORPHAN_2 the render reports cancelled")
        }

        // RENDERORPHAN_1 — LTXBridge's shape: a Python wrapper with the same
        // SIGTERM handler, its Popen child, and that child's own helper.
        if fm.isExecutableFile(atPath: "/usr/bin/python3") {
            let childPID = root.appendingPathComponent("bridge-child.pid").path
            let helperPID = root.appendingPathComponent("bridge-helper.pid").path
            let wrapper = """
            import subprocess, signal, sys
            child = subprocess.Popen(["/bin/sh", "-c", "sleep 300 & echo $! > '\(helperPID)'; wait"])
            open('\(childPID)', 'w').write(str(child.pid))
            def terminate(signum, frame):
                if child.poll() is None:
                    child.terminate()
                    try: child.wait(timeout=10)
                    except subprocess.TimeoutExpired: child.kill(); child.wait()
                raise SystemExit(130)
            signal.signal(signal.SIGTERM, terminate)
            child.wait()
            """
            // Launched exactly as LTXBridge.runPython launches a render.
            let savedGrace = RenderProcessSupervisor.graceSeconds
            RenderProcessSupervisor.graceSeconds = 1
            defer { RenderProcessSupervisor.graceSeconds = savedGrace }
            let tracker = ProcessCancellationTracker()
            let process = Process()
            process.standardOutput = Pipe(); process.standardError = Pipe()
            let control = RenderProcessSupervisor.configure(process, executable: "/usr/bin/python3", arguments: ["-c", wrapper])
            try? process.run()
            created.append(process.processIdentifier)
            tracker.register(process, handle: RenderProcessSupervisor.didLaunch(
                process, control: control, owner: nil,
                ledger: RenderProcessLedger(fileURL: root.appendingPathComponent("bridge-leases.json"))))
            t.check(waitFor(8) { readPID(helperPID) != nil && readPID(childPID) != nil },
                    "RENDERORPHAN_1 the wrapper, its child and the child's helper are running")
            let child = readPID(childPID) ?? -1, helper = readPID(helperPID) ?? -1
            created += [child, helper]
            tracker.cancel()
            t.check(waitFor(5) { !process.isRunning }, "RENDERORPHAN_1 the supervised wrapper exits")
            t.check(waitFor(3) { !alive(helper) }, "RENDERORPHAN_RED RENDERORPHAN_1 the helper the child started exits")
            t.check(waitFor(6) { !alive(child) }, "RENDERORPHAN_1 and a render child that outlasts SIGTERM is killed after the grace period")
            tracker.unregister(process)
        } else {
            t.check(true, "RENDERORPHAN_1 /usr/bin/python3 unavailable — skipped")
        }
    }

    // MARK: When the owner is gone

    /// A supervised render the way a backend launches one: a quiet tree (no
    /// output at all) with a helper, and a member that ignores SIGTERM.
    func launchQuietRender(_ name: String, owner: RenderProcessOwner?, ledger: RenderProcessLedger)
        -> (process: Process, handle: RenderProcessHandle, helper: Int32, stubborn: Int32) {
        let helperPID = root.appendingPathComponent("\(name)-helper.pid").path
        let stubbornPID = root.appendingPathComponent("\(name)-stubborn.pid").path
        let script = "sleep 300 & echo $! > '\(helperPID)'; "
            + "sh -c \"trap '' TERM; exec sleep 301\" & echo $! > '\(stubbornPID)'; "
            + (owner.map { "echo x > '\($0.stagingPath)'; " } ?? "") + "wait"
        let process = Process()
        process.standardOutput = Pipe(); process.standardError = Pipe()
        let control = RenderProcessSupervisor.configure(process, executable: "/bin/sh", arguments: ["-c", script])
        try? process.run()
        created.append(process.processIdentifier)
        let handle = RenderProcessSupervisor.didLaunch(process, control: control, owner: owner, ledger: ledger)
        _ = waitFor(5) { readPID(helperPID) != nil && readPID(stubbornPID) != nil }
        let helper = readPID(helperPID) ?? -1, stubborn = readPID(stubbornPID) ?? -1
        created += [helper, stubborn]
        return (process, handle, helper, stubborn)
    }
    func groupGone(_ pgid: Int32) -> Bool { killpg(pgid, 0) != 0 && errno == ESRCH }

    t.suite("RENDERORPHAN — the tree ends when its owner is gone") {
        let savedGrace = RenderProcessSupervisor.graceSeconds
        RenderProcessSupervisor.graceSeconds = 1
        defer { RenderProcessSupervisor.graceSeconds = savedGrace }

        // RENDERORPHAN_3 — the owner's end of the control pipe closes, as it does
        // when the app process dies, while the render writes nothing at all.
        do {
            let r = launchQuietRender("owner-gone", owner: nil, ledger: RenderProcessLedger(fileURL: root.appendingPathComponent("gone.json")))
            // A process the app starts afterwards must not keep the pipe open.
            let sibling = Process()
            sibling.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sibling.arguments = ["302"]
            try? sibling.run()
            created.append(sibling.processIdentifier)
            t.check(r.process.isRunning && alive(r.helper) && alive(r.stubborn), "RENDERORPHAN_3 the quiet render tree is running")
            let pgid = r.process.processIdentifier
            r.handle.finish()   // closes the control pipe; sends no signal
            t.check(waitFor(3) { !r.process.isRunning && !alive(r.helper) },
                    "RENDERORPHAN_RED RENDERORPHAN_3 with its owner gone, the render and its helper end without any output")
            t.check(waitFor(5) { !alive(r.stubborn) }, "RENDERORPHAN_3 a member ignoring SIGTERM is killed after the grace period")
            t.check(waitFor(3) { groupGone(pgid) }, "RENDERORPHAN_3 nothing of the group is left")
            t.check(sibling.isRunning, "RENDERORPHAN_4 an unrelated process the app started is untouched")
            sibling.terminate()
        }

        // Lease lifecycle: recorded while running, cleared on normal completion, no leftovers.
        do {
            let ledger = RenderProcessLedger(fileURL: root.appendingPathComponent("lifecycle.json"))
            let staging = RenderAttemptOutput.stagingPath(
                outputDirectory: root.appendingPathComponent("Videos"), requestID: UUID(), attempt: 1)
            try? fm.createDirectory(at: URL(fileURLWithPath: staging).deletingLastPathComponent(), withIntermediateDirectories: true)
            var request = GenerationRequest(prompt: "p", parameters: .default)
            request.attemptNumber = 1
            let owner = RenderProcessOwner(backend: "ltx2mlx", request: request, stagingPath: staging)
            let process = Process()
            process.standardOutput = Pipe(); process.standardError = Pipe()
            let control = RenderProcessSupervisor.configure(process, executable: "/bin/sh",
                                                            arguments: ["-c", "echo x > '\(staging)'; sleep 1"])
            try? process.run()
            created.append(process.processIdentifier)
            let tracker = ProcessCancellationTracker()
            tracker.register(process, handle: RenderProcessSupervisor.didLaunch(process, control: control, owner: owner, ledger: ledger))
            let lease = ledger.leases().first
            t.checkEqual(lease?.owner, owner, "RENDERORPHAN_3 a running render is recorded with its request, work and attempt")
            if let lease, case .identity(let live) = LiveProcessInspector().inspect(pid: lease.rootPID) {
                t.check(RenderOrphanReaper.isVerified(live, for: lease), "RENDERORPHAN_3 and a lease that proves its root")
            } else {
                t.check(false, "RENDERORPHAN_3 and a lease that proves its root")
            }
            let pgid = process.processIdentifier
            t.check(waitFor(5) { !process.isRunning }, "RENDERORPHAN_3 the render completes normally")
            tracker.unregister(process)
            t.check(ledger.leases().isEmpty, "RENDERORPHAN_3 its lease is cleared")
            t.check(waitFor(3) { groupGone(pgid) }, "RENDERORPHAN_3 and nothing of its group is left behind")
        }
    }

    t.suite("RENDERORPHAN — a later launch reaps only a proven render") {
        let savedGrace = RenderProcessSupervisor.graceSeconds
        // The watchers only act once their control pipe closes, which these
        // tests do themselves at the end.
        RenderProcessSupervisor.graceSeconds = 1
        defer { RenderProcessSupervisor.graceSeconds = savedGrace }
        let videos = root.appendingPathComponent("ReapVideos", isDirectory: true)
        func owner(_ attempt: Int = 1) -> RenderProcessOwner {
            var request = GenerationRequest(prompt: "p", parameters: .default)
            request.attemptNumber = attempt
            let staging = RenderAttemptOutput.stagingPath(outputDirectory: videos, requestID: request.id, attempt: attempt)
            try? fm.createDirectory(at: URL(fileURLWithPath: staging).deletingLastPathComponent(), withIntermediateDirectories: true)
            return RenderProcessOwner(backend: "ltxbridge", request: request, stagingPath: staging)
        }

        // RENDERORPHAN_3 — a previous session's render tree, root verified.
        do {
            let live = RenderProcessLedger(fileURL: root.appendingPathComponent("reap-live.json"))
            let o = owner()
            let r = launchQuietRender("reap", owner: o, ledger: live)
            guard var lease = live.leases().first else { t.check(false, "RENDERORPHAN_3 fixture lease"); return }
            lease.ownerAppInstanceID = UUID()
            let previous = RenderProcessLedger(fileURL: root.appendingPathComponent("reap-previous.json"))
            previous.upsert(lease)
            let outcome = RenderOrphanReaper.reconcile(ledger: previous, terminationTimeout: 1).map(\.outcome)
            t.checkEqual(outcome, [.terminated], "RENDERORPHAN_3 a verified previous-session render is ended")
            t.check(waitFor(3) { !r.process.isRunning && !alive(r.helper) && !alive(r.stubborn) },
                    "RENDERORPHAN_3 all of its tree, including a member ignoring SIGTERM")
            t.check(groupGone(lease.processGroupID), "RENDERORPHAN_3 its group is gone")
            t.check(!fm.fileExists(atPath: URL(fileURLWithPath: o.stagingPath).deletingLastPathComponent().path),
                    "RENDERORPHAN_3 its own staging output is removed")
            t.check(previous.leases().isEmpty, "RENDERORPHAN_3 and its lease is settled")
            r.handle.finish()
        }

        // RENDERORPHAN_4 — the same live PID with a start time one microsecond off.
        do {
            let live = RenderProcessLedger(fileURL: root.appendingPathComponent("mismatch-live.json"))
            let o = owner()
            let r = launchQuietRender("mismatch", owner: o, ledger: live)
            if var lease = live.leases().first {
                lease.ownerAppInstanceID = UUID()
                lease.identity.startMicroseconds += 1
                let previous = RenderProcessLedger(fileURL: root.appendingPathComponent("mismatch-previous.json"))
                previous.upsert(lease)
                t.checkEqual(RenderOrphanReaper.reconcile(ledger: previous, terminationTimeout: 1).map(\.outcome), [.unverified],
                             "RENDERORPHAN_4 a live process that is not the recorded launch is not proven")
                t.check(r.process.isRunning && alive(r.helper), "RENDERORPHAN_4 and is never signalled")
                t.check(fm.fileExists(atPath: o.stagingPath), "RENDERORPHAN_4 nor are its files touched")
            } else {
                t.check(false, "RENDERORPHAN_4 fixture lease")
            }
            let tracker = ProcessCancellationTracker()
            tracker.register(r.process, handle: r.handle)
            tracker.cancel()
            t.check(waitFor(5) { !alive(r.stubborn) && !r.process.isRunning }, "RENDERORPHAN_4 the render is still cancellable by its owner")
        }

        // Stubbed inspection for what cannot be arranged for real.
        final class Stub: ProcessInspecting, ProcessGroupSignalling {
            var processes: [Int32: ProcessInspection] = [:]
            var groups: Set<Int32> = []
            private(set) var signalled: [(Int32, Int32)] = []
            private(set) var inspected: [Int32] = []
            func inspect(pid: Int32) -> ProcessInspection { inspected.append(pid); return processes[pid] ?? .absent }
            func terminate(pid: Int32) -> Bool { false }
            func groupExists(_ pgid: Int32) -> Bool { groups.contains(pgid) }
            func signalGroup(_ pgid: Int32, _ signal: Int32) -> Bool {
                signalled.append((pgid, signal)); groups.remove(pgid); return true
            }
        }
        func stubLease(_ o: RenderProcessOwner, pid: Int32 = 7777, instance: UUID = UUID()) -> (RenderProcessLease, ProcessIdentity) {
            let identity = ProcessIdentity(startSeconds: 1_789_000_000, startMicroseconds: 42, userID: getuid(),
                                           executablePath: "/bin/bash",
                                           arguments: ["/bin/bash", "-c", RenderProcessSupervisor.script, RenderProcessSupervisor.marker,
                                                       "5", "/usr/bin/python3", "-c", "render to \(o.stagingPath)"])
            return (RenderProcessLease(owner: o, ownerAppInstanceID: instance, rootPID: pid, processGroupID: pid,
                                       identity: RenderProcessIdentity(identity), launchedAt: Date()), identity)
        }
        func reconcile(_ lease: RenderProcessLease, _ stub: Stub, current: UUID = UUID()) -> [RenderOrphanReaper.Outcome] {
            let ledger = RenderProcessLedger(fileURL: root.appendingPathComponent("stub-\(UUID()).json"))
            ledger.upsert(lease)
            return RenderOrphanReaper.reconcile(ledger: ledger, currentAppInstanceID: current, inspector: stub,
                                                groups: stub, terminationTimeout: 0.2).map(\.outcome)
        }
        do {
            // Root and group both gone: already dead; staging removed.
            let o = owner(); fm.createFile(atPath: o.stagingPath, contents: Data("late".utf8))
            let stub = Stub()
            t.checkEqual(reconcile(stubLease(o).0, stub), [.noProcess], "RENDERORPHAN_3 a render with nothing left is settled")
            t.check(!fm.fileExists(atPath: o.stagingPath), "RENDERORPHAN_3 and its staging output removed")
            t.check(stub.signalled.isEmpty, "RENDERORPHAN_4 without signalling anything")

            // Root gone, group still present: nothing proves whose it is.
            let o2 = owner(); fm.createFile(atPath: o2.stagingPath, contents: Data("x".utf8))
            let stub2 = Stub(); stub2.groups = [7777]
            t.checkEqual(reconcile(stubLease(o2).0, stub2), [.unverifiedGroup], "RENDERORPHAN_4 an unproven group is left alone")
            t.check(stub2.signalled.isEmpty && fm.fileExists(atPath: o2.stagingPath), "RENDERORPHAN_4 unsignalled, files kept")

            // PID reused by an unrelated process.
            let (lease3, identity3) = stubLease(owner())
            let stub3 = Stub(); stub3.groups = [7777]
            var other = identity3; other.executablePath = "/Applications/Safari.app/Contents/MacOS/Safari"
            stub3.processes[7777] = .identity(other)
            t.checkEqual(reconcile(lease3, stub3), [.unverified], "RENDERORPHAN_4 a reused PID is not the render")
            t.check(stub3.signalled.isEmpty, "RENDERORPHAN_4 and receives no signal")

            // Same identity but not launched as a supervisor for this attempt.
            let (lease4, identity4) = stubLease(owner())
            var unmarked = lease4
            var noMarker = identity4; noMarker.arguments.removeAll { $0 == RenderProcessSupervisor.marker }
            unmarked.identity = RenderProcessIdentity(noMarker)
            let stub4 = Stub(); stub4.groups = [7777]; stub4.processes[7777] = .identity(noMarker)
            t.checkEqual(reconcile(unmarked, stub4), [.unverified], "RENDERORPHAN_4 a process not launched as a render supervisor is not proven")

            // This session's own render is never inspected.
            let current = UUID()
            let (mine, identity5) = stubLease(owner(), instance: current)
            let stub5 = Stub(); stub5.groups = [7777]; stub5.processes[7777] = .identity(identity5)
            t.checkEqual(reconcile(mine, stub5, current: current), [.currentInstance], "RENDERORPHAN_4 this session's render is not reaped")
            t.check(stub5.inspected.isEmpty && stub5.signalled.isEmpty, "RENDERORPHAN_4 nor inspected")

            // Verified: SIGTERM to exactly its group.
            let (lease6, identity6) = stubLease(owner())
            let stub6 = Stub(); stub6.groups = [7777]; stub6.processes[7777] = .identity(identity6)
            t.checkEqual(reconcile(lease6, stub6), [.terminated], "RENDERORPHAN_3 a verified render is ended")
            t.check(stub6.signalled.count == 1 && stub6.signalled[0].0 == 7777 && stub6.signalled[0].1 == SIGTERM,
                    "RENDERORPHAN_4 by SIGTERM to its own group only")
        }
    }

    // MARK: MiniMax

    t.suite("RENDERORPHAN — MiniMax servers the app started, and ones it did not") {
        let server = root.appendingPathComponent("fake-mlx-serve").path
        fm.createFile(atPath: server, contents: Data("#!/bin/sh\nsleep 300\n".utf8),
                      attributes: [.posixPermissions: 0o755])
        let model = root.appendingPathComponent("model", isDirectory: true).path
        try? fm.createDirectory(atPath: model, withIntermediateDirectories: true)
        let endpoint = "http://127.0.0.1:\(Int.random(in: 40_000...49_000))"

        // RENDERORPHAN_9 — a server one session started is still this app's after a restart.
        let first = MiniMaxH3RuntimeManager()
        do { try first.startOwnedServer(runtime: server, model: model, endpoint: endpoint) } catch {
            t.check(false, "RENDERORPHAN_9 the scratch server starts: \(error)")
        }
        t.checkEqual(first.ownership(for: endpoint), .appOwned, "RENDERORPHAN_9 the session that started it owns it")
        let pid = first.ownedServerPID ?? -1
        created.append(pid)
        let second = MiniMaxH3RuntimeManager()
        t.checkEqual(second.ownership(for: endpoint), .appOwned,
                     "RENDERORPHAN_RED RENDERORPHAN_9 a later session recognises the server it started")
        second.stopOwnedServer()
        t.check(waitFor(5) { !alive(pid) }, "RENDERORPHAN_9 and stops it as its own")
        first.stopOwnedServer()

        // RENDERORPHAN_8 — a server nobody here started.
        let external = Process()
        external.executableURL = URL(fileURLWithPath: server)
        external.arguments = ["--serve"]
        try? external.run()
        created.append(external.processIdentifier)
        let otherEndpoint = "http://127.0.0.1:\(Int.random(in: 50_000...59_000))"
        let fresh = MiniMaxH3RuntimeManager()
        t.checkEqual(fresh.ownership(for: otherEndpoint), .externallyRunning, "RENDERORPHAN_8 an external server is not the app's")
        fresh.stopOwnedServer()
        t.check(!waitFor(1) { !external.isRunning }, "RENDERORPHAN_8 and stopping the app's servers leaves it running")

        // RENDERORPHAN_8 — a record that does not match the process under its PID.
        if case .identity(let identity) = LiveProcessInspector().inspect(pid: external.processIdentifier) {
            var tampered = identity
            tampered.startMicroseconds += 1
            let recordURL = root.appendingPathComponent("tampered-record.json")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let record = MiniMaxManagedServerRecord(pid: external.processIdentifier, identity: tampered,
                                                    endpoint: otherEndpoint, modelDirectory: model,
                                                    ownerAppInstanceID: UUID(), launchedAt: Date())
            try? encoder.encode(record).write(to: recordURL)
            let manager = MiniMaxH3RuntimeManager(managedServerRecordURL: recordURL)
            t.checkEqual(manager.ownership(for: otherEndpoint), .externallyRunning,
                         "RENDERORPHAN_8 a record that does not prove the running process does not make it the app's")
            manager.stopOwnedServer()
            t.check(!waitFor(1) { !external.isRunning }, "RENDERORPHAN_8 and it is not stopped")
        }
        external.terminate()
    }
}
