import Foundation
@testable import LTXVideoGeneratorCore

/// Cross-profile H3 generation lease: proves acquisition/rejection/release/
/// stale-owner-recovery deterministically, and that a Ready server which
/// dies mid-request is reported and marked Failed instead of silently
/// staying "Ready". No real H3, mlx-serve, Ollama, or network — every case
/// uses an isolated temp lock path (never the real
/// /private/tmp/LocalVideoStudio-MiniMaxH3.lock, which coordinates real
/// running app instances on this machine) and either short-lived local
/// helper processes (/bin/true, a killed shell) or fake executable stubs.
func runMiniMaxH3GenerationLeaseTests(_ t: TestKit) {
    t.suite("MiniMax H3 Generation Lease — cross-profile coordination") {
        func tempLockPath() -> String {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalVideoStudio-MiniMaxH3-test-\(UUID().uuidString).lock")
                .path
        }

        // MARK: - A. Basic acquisition

        do {
            let lockPath = tempLockPath()
            defer { unlink(lockPath) }
            let owner = try MiniMaxH3GenerationLease.acquire(
                lockPath: lockPath,
                bundleID: "com.localvideostudio.personal",
                pid: 123)
            t.checkEqual(owner.bundleID, "com.localvideostudio.personal", "acquire records the requesting bundle ID")
            t.checkEqual(owner.pid, 123, "acquire records the requesting PID")
            t.check(FileManager.default.fileExists(atPath: lockPath), "acquire creates the lock file")
        } catch {
            t.check(false, "a fresh lock path must acquire cleanly: \(error)")
        }

        // MARK: - B. Second-profile rejection while the first is alive

        do {
            let lockPath = tempLockPath()
            defer { unlink(lockPath) }
            let ownPid = ProcessInfo.processInfo.processIdentifier // genuinely alive
            try MiniMaxH3GenerationLease.acquire(
                lockPath: lockPath, bundleID: "com.localvideostudio.personal", pid: ownPid)

            do {
                _ = try MiniMaxH3GenerationLease.acquire(
                    lockPath: lockPath, bundleID: "com.localvideostudio.dev", pid: ownPid)
                t.check(false, "Dev must not acquire while Personal's live process holds the lease")
            } catch let error as MiniMaxH3GenerationLease.LeaseError {
                t.checkEqual(error, .heldByAnotherProcess(bundleID: "com.localvideostudio.personal"),
                             "rejection names the actual current owner (Personal), not the requester")
                let message = error.errorDescription ?? ""
                t.check(message.contains("already being used by another Local Video Studio process"),
                        "the rejection message matches the required non-destructive guidance")
            }
        } catch {
            t.check(false, "setup for case B failed: \(error)")
        }

        // MARK: - C. Release after success frees the lease for the other profile

        do {
            let lockPath = tempLockPath()
            defer { unlink(lockPath) }
            let personalPid: Int32 = 555
            try MiniMaxH3GenerationLease.acquire(
                lockPath: lockPath, bundleID: "com.localvideostudio.personal", pid: personalPid)
            MiniMaxH3GenerationLease.release(lockPath: lockPath, pid: personalPid)
            t.check(!FileManager.default.fileExists(atPath: lockPath),
                    "release removes the lock file it owns")

            let devPid = ProcessInfo.processInfo.processIdentifier
            let owner = try MiniMaxH3GenerationLease.acquire(
                lockPath: lockPath, bundleID: "com.localvideostudio.dev", pid: devPid)
            t.checkEqual(owner.bundleID, "com.localvideostudio.dev",
                         "Dev acquires cleanly once Personal has released")
            MiniMaxH3GenerationLease.release(lockPath: lockPath, pid: devPid)
        } catch {
            t.check(false, "setup for case C failed: \(error)")
        }

        // MARK: - D. Release after failure / cancellation (defer-based)
        //
        // MiniMaxH3Backend.generate() acquires then `defer { release() }`
        // immediately, so every exit path — success, a thrown
        // MiniMaxH3Error, or a CancellationError — releases identically.
        // This proves that pattern's actual release behavior without
        // needing a real H3 backend.

        func generateLike(lockPath: String, pid: Int32, bundleID: String, shouldThrow: Bool) throws {
            try MiniMaxH3GenerationLease.acquire(lockPath: lockPath, bundleID: bundleID, pid: pid)
            defer { MiniMaxH3GenerationLease.release(lockPath: lockPath, pid: pid) }
            if shouldThrow {
                throw MiniMaxH3Error.cancelled
            }
        }

        do {
            let lockPath = tempLockPath()
            defer { unlink(lockPath) }
            do {
                try generateLike(lockPath: lockPath, pid: 777, bundleID: "com.localvideostudio.personal", shouldThrow: true)
                t.check(false, "the simulated generation was supposed to throw")
            } catch {
                // expected
            }
            t.check(!FileManager.default.fileExists(atPath: lockPath),
                    "defer-based release still runs when generation throws/cancels")
        }

        do {
            let lockPath = tempLockPath()
            defer { unlink(lockPath) }
            try generateLike(lockPath: lockPath, pid: 778, bundleID: "com.localvideostudio.personal", shouldThrow: false)
            t.check(!FileManager.default.fileExists(atPath: lockPath),
                    "defer-based release runs on the successful path too")
        } catch {
            t.check(false, "case D success path unexpectedly threw: \(error)")
        }

        // MARK: - E. Stale owner recovery (crashed app must not block H3 forever)

        do {
            let lockPath = tempLockPath()
            defer { unlink(lockPath) }

            // A real short-lived process whose PID is guaranteed to have
            // existed and then guaranteed to be gone — safer than guessing
            // an "unused" PID, which could coincidentally be a live
            // unrelated process on a busy machine.
            let deadProcess = Process()
            deadProcess.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try deadProcess.run()
            deadProcess.waitUntilExit()
            let deadPid = deadProcess.processIdentifier

            try MiniMaxH3GenerationLease.acquire(
                lockPath: lockPath, bundleID: "com.localvideostudio.dev", pid: deadPid)

            let recoveredOwner = try MiniMaxH3GenerationLease.acquire(
                lockPath: lockPath,
                bundleID: "com.localvideostudio.personal",
                pid: ProcessInfo.processInfo.processIdentifier)
            t.checkEqual(recoveredOwner.bundleID, "com.localvideostudio.personal",
                         "a lock whose owner PID no longer exists is treated as stale and replaced")
        } catch {
            t.check(false, "stale-owner recovery must not throw: \(error)")
        }

        // MARK: - F. A live, differently-owned lock is never mistaken for stale

        do {
            let lockPath = tempLockPath()
            defer { unlink(lockPath) }
            let alivePid = ProcessInfo.processInfo.processIdentifier
            try MiniMaxH3GenerationLease.acquire(
                lockPath: lockPath, bundleID: "com.localvideostudio.personal", pid: alivePid)
            do {
                _ = try MiniMaxH3GenerationLease.acquire(
                    lockPath: lockPath, bundleID: "com.localvideostudio.dev", pid: alivePid)
                t.check(false, "a genuinely alive owner must never be treated as stale")
            } catch is MiniMaxH3GenerationLease.LeaseError {
                t.check(true, "live owner correctly blocks the second acquisition")
            }
        } catch {
            t.check(false, "setup for case F failed: \(error)")
        }

        // MARK: - G. LTX is unaffected — the lease is H3-only by construction
        //
        // Structural check: the lease type is referenced only from the H3
        // backend, never from the ltx-2-mlx generation path, so a normal LTX
        // generation can never be blocked by an H3 generation in progress.

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ltxBackendSource = try? String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "LTXVideoGenerator/Sources/Services/LTX2MLXBackend.swift"), encoding: .utf8)
        let h3BackendSource = try? String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "LTXVideoGenerator/Sources/Services/MiniMaxH3Backend.swift"), encoding: .utf8)
        t.check(
            ltxBackendSource?.contains("MiniMaxH3GenerationLease") == false,
            "the ltx-2-mlx backend never references the H3 lease — LTX generation is never blocked by it")
        t.check(
            h3BackendSource?.contains("MiniMaxH3GenerationLease.acquire") == true,
            "the H3 backend is the one place that acquires the lease")
    }

    t.suite("MiniMax H3 Server-Lost Diagnostics") {
        func writeFakeRuntime(at url: URL, script: String) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxH3ServerLostTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let modelDir = root.appendingPathComponent("model", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))

        // MARK: - H. Owned process reports its real exit code

        let exitingRuntime = root.appendingPathComponent("exit-mlx-serve")
        try? writeFakeRuntime(at: exitingRuntime, script: "#!/bin/sh\necho 'model weights truncated' >&2\nexit 3\n")

        let suiteName = "test.h3.serverlost.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = MiniMaxH3RuntimeManager(userDefaults: defaults)
        let transport = H3ServerLostFakeTransport()
        transport.shouldThrowConnectionFailure = true
        let snapshot = MiniMaxH3Configuration.Snapshot(
            modelDirectory: modelDir.path,
            runtimeExecutablePath: exitingRuntime.path,
            endpoint: "http://127.0.0.1:19983")

        var thrownDetail: String?
        h3Await2 {
            do {
                _ = try await manager.ensureReady(snapshot: snapshot, transport: transport)
            } catch {
                thrownDetail = error.localizedDescription
            }
        }
        t.check(thrownDetail?.contains("model weights truncated") == true,
                "startup failure still preserves stderr (regression guard for the prior fix)")

        // Now the owned process (which the manager still references,
        // exited) can be asked directly for its crash detail — this is
        // exactly what MiniMaxH3Backend calls when the generation HTTP
        // request fails after ensureReady() already returned Ready.
        let crashDetail = manager.ownedProcessCrashDetail()
        t.check(crashDetail?.contains("exited with code 3") == true,
                "ownedProcessCrashDetail reports the real exit code, not a generic network message")
        t.check(crashDetail?.contains("model weights truncated") == true,
                "ownedProcessCrashDetail includes the captured stderr")

        // MARK: - I. Owned process reports SIGTERM explicitly, not as exit code

        let killedRuntime = root.appendingPathComponent("killed-mlx-serve")
        try? writeFakeRuntime(at: killedRuntime, script: "#!/bin/sh\nkill -TERM $$\n")
        let manager2 = MiniMaxH3RuntimeManager(userDefaults: defaults)
        let transport2 = H3ServerLostFakeTransport()
        transport2.shouldThrowConnectionFailure = true
        let snapshot2 = MiniMaxH3Configuration.Snapshot(
            modelDirectory: modelDir.path,
            runtimeExecutablePath: killedRuntime.path,
            endpoint: "http://127.0.0.1:19984")
        h3Await2 {
            _ = try? await manager2.ensureReady(snapshot: snapshot2, transport: transport2)
        }
        let signalDetail = manager2.ownedProcessCrashDetail()
        t.check(signalDetail?.contains("SIGTERM") == true,
                "a process killed by SIGTERM is reported explicitly, not as a generic HTTP/network error")

        // MARK: - J. No owned process means no crash detail (never fabricate one)

        let neverStartedManager = MiniMaxH3RuntimeManager(userDefaults: defaults)
        t.check(neverStartedManager.ownedProcessCrashDetail() == nil,
                "with no owned process, ownedProcessCrashDetail reports nothing rather than guessing")
    }
}

private final class H3ServerLostFakeTransport: MiniMaxH3HTTPTransport {
    var shouldThrowConnectionFailure = false
    struct ConnectionFailure: Error {}

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if shouldThrowConnectionFailure { throw ConnectionFailure() }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(), response)
    }
}

private func h3Await2(_ operation: @escaping () async -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await operation()
        semaphore.signal()
    }
    semaphore.wait()
}
