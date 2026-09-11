import Foundation
@testable import LTXVideoGeneratorCore

/// Regression tests for the ModelStatusView crash: SwiftUI's body reached
/// `LTX2MLXRuntimeManager.probeCapabilities`, which ran `Process.waitUntilExit()`
/// on the main thread and spun a nested run loop inside the view update.
///
/// Every probe here launches a real stub `python3` (a shell script) that
/// appends one line per invocation to a count file, so spawn counts are
/// measured independently of the cache's own counters. The test harness runs
/// on the main thread, which is exactly the thread the fix must never block.
func runLTX2MLXCapabilityProbeTests(_ t: TestKit) {
    let required = LTX2MLXRuntimeManifest.requiredCapabilities
    let goodJSON = "{\"capabilities\": [\(required.map { "\"\($0)\"" }.joined(separator: ", "))]}"

    /// A runtime directory: bin/ltx-2-mlx (stub) + bin/python3 (scripted).
    struct StubRuntime {
        let root: URL
        let executable: URL
        let python: URL
        let countFile: URL
        var spawns: Int {
            ((try? String(contentsOf: countFile, encoding: .utf8)) ?? "")
                .split(separator: "\n").count
        }
    }

    func makeRuntime(_ pythonBody: String, rawPython: String? = nil) throws -> StubRuntime {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx2mlx-probe-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let exe = bin.appendingPathComponent("ltx-2-mlx")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
        let count = root.appendingPathComponent("spawns.txt")
        let python = bin.appendingPathComponent("python3")
        let script = rawPython ?? "#!/bin/sh\necho spawn >> '\(count.path)'\n\(pythonBody)\n"
        try Data(script.utf8).write(to: python)
        for file in [exe, python] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return StubRuntime(root: root, executable: exe, python: python, countFile: count)
    }

    func makeDefaults(override path: String) -> (UserDefaults, String) {
        let name = "test.ltx2mlx.probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(path, forKey: LTX2MLXRuntimeManager.overrideExecutableKey)
        return (defaults, name)
    }

    /// Runs `body` on a real background thread. (`DispatchQueue.global().sync`
    /// may execute on the calling thread, which would defeat the point.)
    func offMain<T>(_ body: @escaping () -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result = body()
            done.signal()
        }
        done.wait()
        return result!
    }

    func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    func isChecking(_ status: LTX2MLXRuntimeStatus) -> Bool {
        if case .checking = status { return true }
        return false
    }

    func isBroken(_ status: LTX2MLXRuntimeStatus) -> Bool {
        if case .broken = status { return true }
        return false
    }

    t.suite("CRASHPROBE — ModelStatusView never probes synchronously on the main thread") {
        t.check(Thread.isMainThread, "precondition: the test harness runs on the main thread")

        // CRASHPROBE_1: the real sidebar resolver path (ModelStatusView.displayInfo)
        // against a runtime whose probe takes 2 s must return immediately.
        let slow = try makeRuntime("sleep 2\necho '\(goodJSON)'")
        defer { try? FileManager.default.removeItem(at: slow.root) }
        let (defaults1, suite1) = makeDefaults(override: slow.executable.path)
        defer { defaults1.removePersistentDomain(forName: suite1) }

        var info: ActiveModelDisplayResolver.DisplayInfo?
        let resolveTime = elapsed {
            info = ActiveModelDisplayResolver.resolve(
                modelID: ModelRegistry.customModelID, userDefaults: defaults1)
        }
        t.check(resolveTime < 0.5,
                "CRASHPROBE_1: sidebar resolver returns without waiting on the 2 s probe (took \(String(format: "%.3f", resolveTime)) s)")
        t.checkEqual(info?.statusText, "Checking…", "CRASHPROBE_1: sidebar shows Checking… while the runtime is verified")
        t.check(info?.isReady == false, "CRASHPROBE_1: an unverified runtime is never shown Ready")

        let verified = offMain { LTX2MLXRuntime.runtimeReadiness(userDefaults: defaults1) }
        t.check(verified.isReady, "CRASHPROBE_1: once the background probe finishes the runtime is Ready")
        t.checkEqual(slow.spawns, 1, "CRASHPROBE_1: main-thread read + background read shared one probe")

        // CRASHPROBE_2: a main-thread status read on an unprobed runtime.
        let fresh = try makeRuntime("sleep 1\necho '\(goodJSON)'")
        defer { try? FileManager.default.removeItem(at: fresh.root) }
        let (defaults2, suite2) = makeDefaults(override: fresh.executable.path)
        defer { defaults2.removePersistentDomain(forName: suite2) }
        let manager2 = LTX2MLXRuntimeManager(fileManager: .default, userDefaults: defaults2)
        var mainStatus: LTX2MLXRuntimeStatus = .notInstalled
        let mainTime = elapsed { mainStatus = manager2.evaluateStatus() }
        t.check(isChecking(mainStatus), "CRASHPROBE_2: main-thread read reports .checking, not a probed result")
        t.check(mainTime < 0.5, "CRASHPROBE_2: main-thread read does not wait (took \(String(format: "%.3f", mainTime)) s)")
        t.check(!mainStatus.isReady, "CRASHPROBE_2: .checking is not Ready (fail closed)")
        t.checkEqual(mainStatus.executablePath, nil, "CRASHPROBE_2: .checking exposes no executable to launch")
        _ = offMain { manager2.evaluateStatus() }
        t.checkEqual(manager2.capabilityProbeCache.mainThreadLaunchCount, 0,
                     "CRASHPROBE_2 / PHASE 12: no probe process was launched on the main thread")
    }

    t.suite("CRASHPROBE — in-flight dedup, cache reuse and invalidation") {
        let runtime = try makeRuntime("sleep 1\necho '\(goodJSON)'")
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let (defaults, suite) = makeDefaults(override: runtime.executable.path)
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LTX2MLXRuntimeManager(fileManager: .default, userDefaults: defaults)

        // CRASHPROBE_3: 10 refreshes for the same runtime while one probe runs —
        // five from the main thread, five concurrent background waiters.
        for _ in 0..<5 { _ = manager.evaluateStatus() }
        let group = DispatchGroup()
        let results = NSMutableArray()
        for _ in 0..<5 {
            group.enter()
            DispatchQueue.global().async {
                let status = manager.evaluateStatus()
                objc_sync_enter(results); results.add(status.isReady); objc_sync_exit(results)
                group.leave()
            }
        }
        group.wait()
        t.checkEqual(runtime.spawns, 1, "CRASHPROBE_3: 10 refreshes for one runtime spawned exactly 1 probe process")
        t.checkEqual(manager.capabilityProbeCache.launchCount, 1, "CRASHPROBE_3: cache agrees — one launch")
        t.check(results.allSatisfy { ($0 as? Bool) == true }, "CRASHPROBE_3: every background waiter got the verified result")

        // CRASHPROBE_4: after completion, answers come from the cache.
        for _ in 0..<20 { _ = manager.evaluateStatus() }
        let cachedMain = manager.evaluateStatus()
        t.check(cachedMain.isReady, "CRASHPROBE_4: main-thread read returns the cached Ready result")
        let cachedTime = elapsed { _ = manager.evaluateStatus() }
        t.check(cachedTime < 0.1, "CRASHPROBE_4: cached read is immediate")
        t.checkEqual(runtime.spawns, 1, "CRASHPROBE_4: no re-probe on cached reads")

        // CRASHPROBE_5: runtime path change → a different runtime is probed;
        // switching back reuses the first runtime's cached result.
        let other = try makeRuntime("echo '\(goodJSON)'")
        defer { try? FileManager.default.removeItem(at: other.root) }
        defaults.set(other.executable.path, forKey: LTX2MLXRuntimeManager.overrideExecutableKey)
        t.check(isChecking(manager.evaluateStatus()), "CRASHPROBE_5: new runtime path is not answered from the old path's cache")
        t.check(offMain { manager.evaluateStatus() }.isReady, "CRASHPROBE_5: new runtime path verified")
        t.checkEqual(other.spawns, 1, "CRASHPROBE_5: new runtime path probed once")
        defaults.set(runtime.executable.path, forKey: LTX2MLXRuntimeManager.overrideExecutableKey)
        t.check(manager.evaluateStatus().isReady, "CRASHPROBE_5: returning to the first path reuses its cached result")
        t.checkEqual(runtime.spawns, 1, "CRASHPROBE_5: first path not re-probed")

        // Same path, runtime replaced on disk (Install/Update/Repair recreates it).
        try FileManager.default.removeItem(at: runtime.python)
        try Data("#!/bin/sh\necho spawn >> '\(runtime.countFile.path)'\necho '{\"capabilities\": []}'\n".utf8)
            .write(to: runtime.python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.python.path)
        t.check(isChecking(manager.evaluateStatus()), "CRASHPROBE_5: a replaced runtime at the same path invalidates the cache")
        let replaced = offMain { manager.evaluateStatus() }
        t.check(!replaced.isReady, "CRASHPROBE_5: the replaced runtime's real (empty) capabilities are used")
        t.checkEqual(runtime.spawns, 2, "CRASHPROBE_5: the replaced runtime was probed exactly once more")

        // CRASHPROBE_6: model/config changes that don't touch the runtime do not
        // re-probe; install-style invalidation does.
        defaults.set(other.executable.path, forKey: LTX2MLXRuntimeManager.overrideExecutableKey)
        let modelDir = FileManager.default.temporaryDirectory.appendingPathComponent("ltx2mlx-model-\(UUID().uuidString)")
        defaults.set(modelDir.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        defaults.set(CustomModelSourceMode.local.rawValue, forKey: ModelRegistry.customSourceModeUserDefaultsKey)
        let withModel = offMain {
            (runtime: LTX2MLXRuntime.runtimeReadiness(userDefaults: defaults, manager: manager),
             model: LTX2MLXRuntime.modelReadiness(userDefaults: defaults))
        }
        t.check(withModel.runtime.isReady, "CRASHPROBE_6: runtime stays verified across a model-folder change")
        t.check(!withModel.model.isReady, "CRASHPROBE_6: model readiness is still evaluated live (missing folder → not ready)")
        t.checkEqual(other.spawns, 1, "CRASHPROBE_6: a model/config change does not re-probe the runtime")
        manager.invalidateCapabilityCache()
        t.check(offMain { manager.evaluateStatus() }.isReady, "CRASHPROBE_6: invalidated runtime re-verified")
        t.checkEqual(other.spawns, 2, "CRASHPROBE_6: invalidation (install/update) forces exactly one re-probe")

        // CRASHPROBE_12: explicit Refresh re-probes even an unchanged runtime.
        _ = manager.refreshStatus(forceProbe: true)
        _ = offMain { manager.evaluateStatus() }
        t.checkEqual(other.spawns, 3, "CRASHPROBE_12: explicit Refresh performs a fresh probe")
        _ = manager.refreshStatus()
        _ = offMain { manager.evaluateStatus() }
        t.checkEqual(other.spawns, 3, "CRASHPROBE_12: a plain (non-forced) refresh reuses the cache")
        t.checkEqual(manager.capabilityProbeCache.mainThreadLaunchCount, 0,
                     "PHASE 12: no probe process launched on the main thread in this suite")
    }

    t.suite("CRASHPROBE — failures fail closed and never crash or block") {
        func statusFor(_ runtime: StubRuntime, timeout: TimeInterval? = nil) -> (main: LTX2MLXRuntimeStatus, background: LTX2MLXRuntimeStatus, manager: LTX2MLXRuntimeManager, suite: String) {
            let (defaults, suite) = makeDefaults(override: runtime.executable.path)
            let manager = LTX2MLXRuntimeManager(fileManager: .default, userDefaults: defaults, probeTimeout: timeout)
            let main = manager.evaluateStatus()
            let background = offMain { manager.evaluateStatus() }
            return (main, background, manager, suite)
        }

        // CRASHPROBE_7: interpreter cannot be started.
        let unlaunchable = try makeRuntime("", rawPython: "#!/nonexistent/interpreter/for/ltx2mlx\n")
        defer { try? FileManager.default.removeItem(at: unlaunchable.root) }
        let r7 = statusFor(unlaunchable)
        defer { UserDefaults().removePersistentDomain(forName: r7.suite) }
        t.check(isBroken(r7.background), "CRASHPROBE_7: launch failure → .broken, no crash (\(r7.background.displayMessage))")
        t.check(!r7.background.isReady, "CRASHPROBE_7: launch failure is not Ready")

        // CRASHPROBE_8: non-zero exit, even when it printed valid-looking JSON.
        let nonzero = try makeRuntime("echo '\(goodJSON)'\nexit 3")
        defer { try? FileManager.default.removeItem(at: nonzero.root) }
        let r8 = statusFor(nonzero)
        defer { UserDefaults().removePersistentDomain(forName: r8.suite) }
        t.check(isBroken(r8.background) && !r8.background.isReady,
                "CRASHPROBE_8: non-zero exit fails closed (\(r8.background.displayMessage))")

        // CRASHPROBE_8 (managed tier): the on-disk manifest claims every
        // capability, but a failed probe must NOT fall back to it (the old
        // behaviour did, i.e. failed open).
        let managedDefaultsName = "test.ltx2mlx.probe.managed.\(UUID().uuidString)"
        let managedDefaults = UserDefaults(suiteName: managedDefaultsName)!
        defer { managedDefaults.removePersistentDomain(forName: managedDefaultsName) }
        let managed = LTX2MLXRuntimeManager(fileManager: .default, userDefaults: managedDefaults)
        try? FileManager.default.removeItem(at: managed.managedRuntimeDirectory)
        defer { try? FileManager.default.removeItem(at: managed.managedRuntimeDirectory) }
        let managedBin = managed.managedExecutableURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: managed.managedExecutableURL)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: managedBin.appendingPathComponent("python3"))
        for f in [managed.managedExecutableURL.path, managedBin.appendingPathComponent("python3").path] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f)
        }
        try JSONEncoder().encode(LTX2MLXRuntimeManifest()).write(to: managed.manifestURL)
        let managedStatus = offMain { managed.evaluateStatus() }
        t.check(!managedStatus.isReady,
                "CRASHPROBE_8: managed runtime with a full on-disk manifest but a failing probe is NOT Ready (\(managedStatus.displayMessage))")
        let verification = offMain {
            managed.probeCapabilities(executablePath: managed.managedExecutableURL.path, fallbackManifest: LTX2MLXRuntimeManifest())
        }
        t.check(!verification.isCompatible, "CRASHPROBE_8: install verification cannot pass on a failed probe")

        // CRASHPROBE_9: a hung probe is bounded and never blocks the main thread.
        let hung = try makeRuntime("sleep 60")
        defer { try? FileManager.default.removeItem(at: hung.root) }
        let (hungDefaults, hungSuite) = makeDefaults(override: hung.executable.path)
        defer { hungDefaults.removePersistentDomain(forName: hungSuite) }
        let hungManager = LTX2MLXRuntimeManager(fileManager: .default, userDefaults: hungDefaults, probeTimeout: 1)
        var hungMain: LTX2MLXRuntimeStatus = .notInstalled
        let hungMainTime = elapsed { hungMain = hungManager.evaluateStatus() }
        t.check(hungMainTime < 0.5 && isChecking(hungMain),
                "CRASHPROBE_9: main thread answers immediately while the probe hangs (\(String(format: "%.3f", hungMainTime)) s)")
        var hungBackground: LTX2MLXRuntimeStatus = .notInstalled
        let hungBackgroundTime = elapsed { hungBackground = offMain { hungManager.evaluateStatus() } }
        t.check(isBroken(hungBackground), "CRASHPROBE_9: timeout → .broken (\(hungBackground.displayMessage))")
        t.check(hungBackgroundTime < 8, "CRASHPROBE_9: timeout is bounded (\(String(format: "%.1f", hungBackgroundTime)) s for a 1 s limit)")
        let orphan = Process()
        orphan.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        orphan.arguments = ["-f", hung.python.path]
        orphan.standardOutput = Pipe()
        try orphan.run(); orphan.waitUntilExit()
        t.check(orphan.terminationStatus != 0, "CRASHPROBE_9: the timed-out probe process was terminated")
        let spawnsAfterTimeout = hung.spawns
        for _ in 0..<10 { _ = hungManager.evaluateStatus() }
        t.checkEqual(hung.spawns, spawnsAfterTimeout, "CRASHPROBE_9: a cached failure does not respawn on redraws")

        // CRASHPROBE_10: malformed and empty output.
        let malformed = try makeRuntime("echo 'Traceback (most recent call last): not json'")
        defer { try? FileManager.default.removeItem(at: malformed.root) }
        let r10 = statusFor(malformed)
        defer { UserDefaults().removePersistentDomain(forName: r10.suite) }
        t.check(isBroken(r10.background), "CRASHPROBE_10: malformed output → .broken, no crash")
        let empty = try makeRuntime("true")
        defer { try? FileManager.default.removeItem(at: empty.root) }
        let r10b = statusFor(empty)
        defer { UserDefaults().removePersistentDomain(forName: r10b.suite) }
        t.check(isBroken(r10b.background), "CRASHPROBE_10: empty output → .broken, no crash")
        let wrongShape = try makeRuntime("echo '{\"capabilities\": \"all\"}'")
        defer { try? FileManager.default.removeItem(at: wrongShape.root) }
        let r10c = statusFor(wrongShape)
        defer { UserDefaults().removePersistentDomain(forName: r10c.suite) }
        t.check(isBroken(r10c.background), "CRASHPROBE_10: wrong JSON shape → .broken, no crash")

        for m in [r7.manager, r8.manager, r10.manager, r10b.manager, r10c.manager, hungManager, managed] {
            t.checkEqual(m.capabilityProbeCache.mainThreadLaunchCount, 0,
                         "PHASE 12: failure-path probes never launched on the main thread")
        }
    }

    t.suite("CRASHPROBE — 50 view renders spawn one probe") {
        // CRASHPROBE_11: 50 sidebar renders (the exact resolver ModelStatusView
        // calls) before and after the probe completes.
        let runtime = try makeRuntime("sleep 1\necho '\(goodJSON)'")
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let (defaults, suite) = makeDefaults(override: runtime.executable.path)
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = LTX2MLXRuntimeManager.shared.capabilityProbeCache.launchCount
        var slowest: TimeInterval = 0
        for _ in 0..<50 {
            slowest = max(slowest, elapsed {
                _ = ActiveModelDisplayResolver.resolve(modelID: ModelRegistry.customModelID, userDefaults: defaults)
            })
        }
        _ = offMain { LTX2MLXRuntime.runtimeReadiness(userDefaults: defaults) }
        for _ in 0..<50 {
            slowest = max(slowest, elapsed {
                _ = ActiveModelDisplayResolver.resolve(modelID: ModelRegistry.customModelID, userDefaults: defaults)
            })
        }
        t.checkEqual(runtime.spawns, 1, "CRASHPROBE_11: 100 sidebar renders spawned exactly 1 probe process")
        t.checkEqual(LTX2MLXRuntimeManager.shared.capabilityProbeCache.launchCount - before, 1,
                     "CRASHPROBE_11: shared manager launched once")
        t.check(slowest < 0.25, "CRASHPROBE_11: slowest render \(String(format: "%.3f", slowest)) s — never waits on the probe")
        t.checkEqual(LTX2MLXRuntimeManager.shared.capabilityProbeCache.mainThreadLaunchCount, 0,
                     "PHASE 12: shared manager never launched a probe on the main thread")
    }

    t.suite("CRASHPROBE — probe path contains no synchronous process wait") {
        let source = (try? String(contentsOfFile: "LTXVideoGenerator/Sources/Services/LTX2MLXRuntimeManager.swift", encoding: .utf8)) ?? ""
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
        func region(_ from: String, _ to: String) -> String {
            guard let a = code.range(of: from), let b = code.range(of: to, range: a.upperBound..<code.endIndex) else { return "" }
            return String(code[a.lowerBound..<b.lowerBound])
        }
        let probePath = region("func capabilityProbe(", "static let capabilityProbeScript")
        let cachePath = region("final class LTX2MLXCapabilityProbeCache", "\u{0}__end__")
            + code[(code.range(of: "final class LTX2MLXCapabilityProbeCache")?.lowerBound ?? code.endIndex)...]
        t.check(!probePath.isEmpty && !cachePath.isEmpty, "source regions located")
        t.check(!probePath.contains("waitUntilExit") && !cachePath.contains("waitUntilExit"),
                "CRASHPROBE_1: the capability probe path has no Process.waitUntilExit()")
        let resolver = (try? String(contentsOfFile: "LTXVideoGenerator/Sources/Services/ActiveModelDisplayResolver.swift", encoding: .utf8)) ?? ""
        t.check(!resolver.contains("Process(") && !resolver.contains("waitUntilExit"),
                "CRASHPROBE_1: the sidebar resolver launches no process itself")
    }
}
