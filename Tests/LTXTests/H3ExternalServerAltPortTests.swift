import Foundation
@testable import LTXVideoGeneratorCore

/// Regression cover for FIX_H3_EXTERNAL_SERVER_COEXISTENCE_AND_AUTOMATIC_
/// ALT_PORT_ROUTING (2026-09-18).
///
/// Product scenario this exists for: in normal use, an existing external H3
/// server (e.g. a long-running process the user started by hand — PID 94710
/// in the real reported case) sits on the *configured* endpoint
/// (`minimaxH3Endpoint`, default `http://127.0.0.1:11236`) serving one H3
/// tier. Selecting a *different* tier and pressing Generate must not touch
/// that server — but it must also not just fail. `MiniMaxH3RuntimeManager.
/// ensureReady` now prepares a second, app-owned-only server on a separate
/// loopback port (`MiniMaxH3AlternatePortAllocator`) for exactly this case,
/// and returns the endpoint it actually used so the caller
/// (`MiniMaxH3Backend.generate`) POSTs there — never back at the configured/
/// external endpoint.
///
/// Architecture recap (see doc comments at the definitions for the full
/// reasoning):
///   Configured endpoint   — the single user setting (`minimaxH3Endpoint`),
///                            used for external-server detection.
///   Active/prepared endpoint — what THIS generation call actually uses,
///                            returned by `ensureReady` as `MiniMaxH3RuntimeStatus.
///                            endpoint` and threaded through
///                            `MiniMaxH3Backend.effectiveEndpoint`. Can differ
///                            from the configured endpoint; never written
///                            back into `UserDefaults` (no global mutation,
///                            no residue, no readiness misclassification for
///                            other requests).
///
/// These tests never touch a real port the running test host might have
/// something on: the "external" server in every case is a real subprocess
/// this file starts itself (never registered as app-owned, exactly the
/// shape PID 94710 has — alive, listening, but with no managed-server
/// record and no in-memory `ownedProcess` reference), and the "alternate"
/// endpoint is allocated for real by `MiniMaxH3AlternatePortAllocator`
/// against whatever is actually free on the test machine.
func runH3ExternalServerAltPortTests(_ t: TestKit) {

    func writeSleepyRuntime(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexec sleep 300\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    func writeFailingRuntime(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 'error: intentional test failure' >&2\nexit 1\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    /// Fails its first invocation exactly like a lost bind race (exits
    /// immediately, mimicking mlx-serve losing a TOCTOU port collision),
    /// then succeeds on every invocation after — simulating "the first
    /// allocated port turned out to be taken by something else between the
    /// allocator's check and the actual bind; the next allocated port works
    /// fine." The same script path is reused for every retry attempt (this
    /// manager always launches `snapshot.runtimeExecutablePath` as-is), so a
    /// counter file — not the port number — is what makes the first attempt
    /// fail and the rest succeed.
    func writeFlakyOnFirstAttemptRuntime(at url: URL, counterFile: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        COUNT=$(cat "\(counterFile.path)" 2>/dev/null || echo 0)
        COUNT=$((COUNT + 1))
        echo "$COUNT" > "\(counterFile.path)"
        if [ "$COUNT" -eq 1 ]; then
          echo 'error: address already in use' >&2
          exit 1
        fi
        exec sleep 300
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    func makeModelDir(_ root: URL, name: String) throws -> String {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        return dir.path
    }
    func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
    /// Starts a real, live process standing in for an external H3 server
    /// (e.g. PID 94710) — never registered via `startOwnedServer`, so it has
    /// no managed-server record and no in-memory `ownedProcess` reference,
    /// exactly like a process this app never started.
    func startForeignProcess(runtime: URL) throws -> Process {
        let process = Process()
        process.executableURL = runtime
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    // A free loopback port reserved for the "external" server in every test
    // below, picked once via the real allocator so it can never collide
    // with whatever the alt-port allocator later finds free either.
    func reserveTestPort() -> Int {
        MiniMaxH3AlternatePortAllocator.firstAvailablePort(
            excluding: [], isFree: MiniMaxH3AlternatePortAllocator.isPortFreeOnLoopback) ?? 19860
    }

    // =====================================================================
    // Pure allocator tests — no sockets, no processes, fully deterministic.
    // =====================================================================
    t.suite("MiniMaxH3AlternatePortAllocator — pure allocation") {
        // EXTERNAL_ALT_6: a colliding candidate port is skipped in favor of
        // the next free one.
        let range = MiniMaxH3AlternatePortAllocator.candidateRange
        let first = range.lowerBound
        let second = first + 1
        let taken: Set<Int> = [] // not excluded by config, but "not free"
        let picked = MiniMaxH3AlternatePortAllocator.firstAvailablePort(
            excluding: taken,
            isFree: { $0 != first }) // simulate: first candidate is occupied
        t.checkEqual(picked, second,
                     "EXTERNAL_ALT_6 a taken first candidate is skipped; the allocator picks the next free port")

        // Explicit exclusion (e.g. the configured endpoint's own port, even
        // if it happened to fall in the candidate range) is also honored.
        let pickedExcludingBoth = MiniMaxH3AlternatePortAllocator.firstAvailablePort(
            excluding: [first, second],
            isFree: { _ in true })
        t.checkEqual(pickedExcludingBoth, first + 2,
                     "explicit exclusion (e.g. the configured endpoint's port) is honored even when technically free")

        // Exhausted range -> nil, never a silent wraparound to an excluded
        // or occupied port.
        let exhausted = MiniMaxH3AlternatePortAllocator.firstAvailablePort(
            excluding: [], isFree: { _ in false })
        t.check(exhausted == nil, "an exhausted candidate range returns nil rather than guessing")

        // allocate(excludingEndpoint:) parses the port out of the endpoint
        // URL and excludes exactly that one — proven against the real
        // bind-based checker, since nothing in the candidate range is
        // occupied on a clean test host.
        let realAllocation = MiniMaxH3AlternatePortAllocator.allocate(
            excludingEndpoint: "http://127.0.0.1:\(range.lowerBound)")
        t.check(realAllocation != nil, "the real allocator finds a free port on a clean host")
        t.check(realAllocation != range.lowerBound,
                "the real allocator never returns the port explicitly excluded via the configured endpoint")
    }

    // =====================================================================
    // effectiveEndpoint — the single most important routing decision: which
    // endpoint a generation request actually POSTs to.
    // =====================================================================
    t.suite("MiniMaxH3Backend.effectiveEndpoint — request routing") {
        let configured = "http://127.0.0.1:11236"
        let alternate = "http://127.0.0.1:11305"

        // EXTERNAL_ALT_8 (most important): when ensureReady prepared a
        // different endpoint than the configured one, the backend must use
        // THAT endpoint — never fall back to the configured/external one.
        let preparedAlt = MiniMaxH3RuntimeStatus(
            state: .ready, ownership: .appOwned, detail: "Ready",
            loadedModelID: "some-model", endpoint: alternate)
        t.checkEqual(MiniMaxH3Backend.effectiveEndpoint(configured: configured, prepared: preparedAlt), alternate,
                     "EXTERNAL_ALT_8 a prepared alternate endpoint is used for the actual request, not the configured one")
        t.check(MiniMaxH3Backend.effectiveEndpoint(configured: configured, prepared: preparedAlt) != configured,
                "EXTERNAL_ALT_8 the effective endpoint is explicitly NOT the configured/external endpoint in this case")

        // The ordinary case: ensureReady prepared the configured endpoint
        // itself (Case A/B/C — unchanged), so that's what's used.
        let preparedSame = MiniMaxH3RuntimeStatus(
            state: .ready, ownership: .appOwned, detail: "Ready",
            loadedModelID: "some-model", endpoint: configured)
        t.checkEqual(MiniMaxH3Backend.effectiveEndpoint(configured: configured, prepared: preparedSame), configured,
                     "the configured endpoint is used unchanged when ensureReady prepared it directly")

        // Defensive fallback: an (unexpected) empty prepared endpoint never
        // produces an empty request URL — falls back to configured rather
        // than POSTing nowhere.
        let preparedEmpty = MiniMaxH3RuntimeStatus(state: .ready, ownership: nil, detail: "Ready", loadedModelID: nil)
        t.checkEqual(MiniMaxH3Backend.effectiveEndpoint(configured: configured, prepared: preparedEmpty), configured,
                     "an empty prepared endpoint falls back to the configured one rather than routing nowhere")
    }

    // =====================================================================
    // Integration: ensureReady's real behavior when the configured endpoint
    // has a genuine external process with the wrong model loaded.
    // =====================================================================
    t.suite("ensureReady — external server coexistence (real subprocesses)") {

        // EXTERNAL_ALT_1: external Efficient-equivalent server, Quality
        // selected -> external untouched, Quality prepared on an alternate
        // app-owned endpoint, generation endpoint = alternate.
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("H3ExternalAlt-1-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let foreignRuntime = root.appendingPathComponent("foreign-mlx-serve")
            try writeSleepyRuntime(at: foreignRuntime)
            let altRuntime = root.appendingPathComponent("alt-mlx-serve")
            try writeSleepyRuntime(at: altRuntime)
            let modelDir = try makeModelDir(root, name: "quality-model")

            let externalPort = reserveTestPort()
            let externalEndpoint = "http://127.0.0.1:\(externalPort)"
            let foreignProcess = try startForeignProcess(runtime: foreignRuntime)
            defer { if foreignProcess.isRunning { foreignProcess.terminate() } } // test cleanup only
            let foreignPID = foreignProcess.processIdentifier

            let suite = "H3ExternalAlt-1-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let recordURL = root.appendingPathComponent("managed_server.json")
            let manager = MiniMaxH3RuntimeManager(userDefaults: defaults, managedServerRecordURL: recordURL)

            t.checkEqual(manager.ownership(for: externalEndpoint), .externallyRunning,
                         "EXTERNAL_ALT_1 the foreign process is correctly classified external, not app-owned")

            let hqID = MiniMaxH3Configuration.highQualityModelID
            let expectedHQID = MiniMaxH3Configuration.expectedServerModelIDs(for: hqID).first!
            let transport = H3PortAwareFakeTransport(externalPort: externalPort)
            transport.externalModelEntries = [["id": "standard-tier-model", "loaded": true, "state": "ready"]]
            // The alternate endpoint "finishes loading" shortly after the
            // owned process is started — simulating the fake server coming up.
            transport.scheduleAlternateReady(after: 300_000_000, modelID: expectedHQID)

            let configuredSnapshot = MiniMaxH3Configuration.Snapshot(
                modelDirectory: modelDir, runtimeExecutablePath: altRuntime.path,
                endpoint: externalEndpoint, targetModelID: hqID)

            var result: MiniMaxH3RuntimeStatus?
            var thrown: Error?
            h3AltAwait {
                do {
                    result = try await manager.ensureReady(snapshot: configuredSnapshot, transport: transport)
                } catch {
                    thrown = error
                }
            }

            t.check(thrown == nil, "EXTERNAL_ALT_1 preparing Quality on an alternate endpoint succeeds (got: \(String(describing: thrown)))")
            t.checkEqual(result?.state, .ready, "EXTERNAL_ALT_1 Quality ends Ready")
            t.check(result?.endpoint != nil && result?.endpoint != externalEndpoint,
                    "EXTERNAL_ALT_1 QUALITY_REQUEST_ENDPOINT is a real alternate endpoint, not the external/configured one (got: \(result?.endpoint ?? "nil"))")
            t.check(processAlive(foreignPID), "EXTERNAL_ALT_1 EXTERNAL_PID_UNCHANGED — the foreign process is still alive")
            t.checkEqual(manager.ownership(for: externalEndpoint), .externallyRunning,
                         "EXTERNAL_ALT_1 the external endpoint is still classified external — this manager never claimed it")
            if let altEndpoint = result?.endpoint {
                t.check(MiniMaxH3Configuration.endpointURL(altEndpoint)?.port != externalPort,
                        "EXTERNAL_ALT_1 QUALITY_APP_OWNED_PORT differs from EXTERNAL_PORT")
            }
            manager.stopOwnedServer() // cleanup: tear down only the alt-endpoint process this manager owns
        }

        // EXTERNAL_ALT_2: same shape, for Reference.
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("H3ExternalAlt-2-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let foreignRuntime = root.appendingPathComponent("foreign-mlx-serve")
            try writeSleepyRuntime(at: foreignRuntime)
            let altRuntime = root.appendingPathComponent("alt-mlx-serve")
            try writeSleepyRuntime(at: altRuntime)
            let modelDir = try makeModelDir(root, name: "reference-model")

            let externalPort = reserveTestPort()
            let externalEndpoint = "http://127.0.0.1:\(externalPort)"
            let foreignProcess = try startForeignProcess(runtime: foreignRuntime)
            defer { if foreignProcess.isRunning { foreignProcess.terminate() } }
            let foreignPID = foreignProcess.processIdentifier

            let suite = "H3ExternalAlt-2-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let recordURL = root.appendingPathComponent("managed_server.json")
            let manager = MiniMaxH3RuntimeManager(userDefaults: defaults, managedServerRecordURL: recordURL)

            let refID = MiniMaxH3Configuration.referenceModelID
            let expectedRefID = MiniMaxH3Configuration.expectedServerModelIDs(for: refID).first!
            let transport = H3PortAwareFakeTransport(externalPort: externalPort)
            transport.externalModelEntries = [["id": "standard-tier-model", "loaded": true, "state": "ready"]]
            transport.scheduleAlternateReady(after: 300_000_000, modelID: expectedRefID)

            let configuredSnapshot = MiniMaxH3Configuration.Snapshot(
                modelDirectory: modelDir, runtimeExecutablePath: altRuntime.path,
                endpoint: externalEndpoint, targetModelID: refID)

            var result: MiniMaxH3RuntimeStatus?
            var thrown: Error?
            h3AltAwait {
                do {
                    result = try await manager.ensureReady(snapshot: configuredSnapshot, transport: transport)
                } catch {
                    thrown = error
                }
            }

            t.check(thrown == nil, "EXTERNAL_ALT_2 preparing Reference on an alternate endpoint succeeds (got: \(String(describing: thrown)))")
            t.checkEqual(result?.state, .ready, "EXTERNAL_ALT_2 Reference ends Ready")
            t.check(result?.endpoint != nil && result?.endpoint != externalEndpoint,
                    "EXTERNAL_ALT_2 REFERENCE_REQUEST_ENDPOINT is a real alternate endpoint, not the external/configured one")
            t.check(processAlive(foreignPID), "EXTERNAL_ALT_2 EXTERNAL_PID_UNCHANGED — the foreign process is still alive")
            manager.stopOwnedServer()
        }

        // EXTERNAL_ALT_3 / EXTERNAL_ALT_4: the external PID is identical
        // before and after, and receives no signal, across a *sequence* of
        // two different-tier generations (Quality then Reference) against
        // the same external server.
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("H3ExternalAlt-34-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let foreignRuntime = root.appendingPathComponent("foreign-mlx-serve")
            try writeSleepyRuntime(at: foreignRuntime)
            let altRuntime = root.appendingPathComponent("alt-mlx-serve")
            try writeSleepyRuntime(at: altRuntime)
            let hqModelDir = try makeModelDir(root, name: "hq-model")
            let refModelDir = try makeModelDir(root, name: "ref-model")

            let externalPort = reserveTestPort()
            let externalEndpoint = "http://127.0.0.1:\(externalPort)"
            let foreignProcess = try startForeignProcess(runtime: foreignRuntime)
            defer { if foreignProcess.isRunning { foreignProcess.terminate() } }
            let foreignPID = foreignProcess.processIdentifier

            let suite = "H3ExternalAlt-34-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let recordURL = root.appendingPathComponent("managed_server.json")
            let manager = MiniMaxH3RuntimeManager(userDefaults: defaults, managedServerRecordURL: recordURL)

            let hqID = MiniMaxH3Configuration.highQualityModelID
            let refID = MiniMaxH3Configuration.referenceModelID
            let transport = H3PortAwareFakeTransport(externalPort: externalPort)
            transport.externalModelEntries = [["id": "standard-tier-model", "loaded": true, "state": "ready"]]

            // Generation 1: Quality.
            transport.scheduleAlternateReady(
                after: 300_000_000, modelID: MiniMaxH3Configuration.expectedServerModelIDs(for: hqID).first!)
            let hqSnapshot = MiniMaxH3Configuration.Snapshot(
                modelDirectory: hqModelDir, runtimeExecutablePath: altRuntime.path,
                endpoint: externalEndpoint, targetModelID: hqID)
            h3AltAwait { _ = try? await manager.ensureReady(snapshot: hqSnapshot, transport: transport) }
            t.check(processAlive(foreignPID), "EXTERNAL_ALT_3 external PID alive after generation 1 (Quality)")

            // Generation 2: Reference — a DIFFERENT tier, while the external
            // server is still sitting on the same wrong (Standard) model,
            // AND the alt-port server from generation 1 is still up and
            // still serving Quality until this app stops/restarts it.
            transport.setAlternateModelPresent(
                modelID: MiniMaxH3Configuration.expectedServerModelIDs(for: hqID).first!)
            transport.scheduleAlternateReady(
                after: 300_000_000, modelID: MiniMaxH3Configuration.expectedServerModelIDs(for: refID).first!)
            let refSnapshot = MiniMaxH3Configuration.Snapshot(
                modelDirectory: refModelDir, runtimeExecutablePath: altRuntime.path,
                endpoint: externalEndpoint, targetModelID: refID)
            var result2: MiniMaxH3RuntimeStatus?
            h3AltAwait { result2 = try? await manager.ensureReady(snapshot: refSnapshot, transport: transport) }

            t.checkEqual(result2?.state, .ready, "EXTERNAL_ALT_3/4 generation 2 (Reference) also succeeds via the alternate endpoint")
            t.check(processAlive(foreignPID),
                    "EXTERNAL_ALT_3 EXTERNAL_PID_UNCHANGED — the same external PID is still alive after two different-tier generations")
            t.checkEqual(manager.ownership(for: externalEndpoint), .externallyRunning,
                         "EXTERNAL_ALT_4 the external endpoint was never claimed by this manager across either generation")
            manager.stopOwnedServer()

            // EXTERNAL_ALT_5: app-owned alt server cleanup leaves external
            // running.
            t.check(processAlive(foreignPID),
                    "EXTERNAL_ALT_5 after stopOwnedServer() (which only ever tears down THIS manager's alt-endpoint process), the external process remains alive")
        }

        // EXTERNAL_ALT_7: alternate runtime start failure -> external
        // untouched, clear error thrown (not a hang, not a silent no-op).
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("H3ExternalAlt-7-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let foreignRuntime = root.appendingPathComponent("foreign-mlx-serve")
            try writeSleepyRuntime(at: foreignRuntime)
            let brokenAltRuntime = root.appendingPathComponent("broken-mlx-serve")
            try writeFailingRuntime(at: brokenAltRuntime)
            let modelDir = try makeModelDir(root, name: "model")

            let externalPort = reserveTestPort()
            let externalEndpoint = "http://127.0.0.1:\(externalPort)"
            let foreignProcess = try startForeignProcess(runtime: foreignRuntime)
            defer { if foreignProcess.isRunning { foreignProcess.terminate() } }
            let foreignPID = foreignProcess.processIdentifier

            let suite = "H3ExternalAlt-7-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let recordURL = root.appendingPathComponent("managed_server.json")
            let manager = MiniMaxH3RuntimeManager(userDefaults: defaults, managedServerRecordURL: recordURL)

            let hqID = MiniMaxH3Configuration.highQualityModelID
            let transport = H3PortAwareFakeTransport(externalPort: externalPort)
            transport.externalModelEntries = [["id": "standard-tier-model", "loaded": true, "state": "ready"]]
            // Never scheduled ready — the broken runtime exits immediately,
            // so the alternate endpoint never comes up regardless.

            let configuredSnapshot = MiniMaxH3Configuration.Snapshot(
                modelDirectory: modelDir, runtimeExecutablePath: brokenAltRuntime.path,
                endpoint: externalEndpoint, targetModelID: hqID)

            var thrown: Error?
            h3AltAwait {
                do {
                    _ = try await manager.ensureReady(snapshot: configuredSnapshot, transport: transport)
                    t.check(false, "EXTERNAL_ALT_7 a broken alternate runtime must not silently succeed")
                } catch {
                    thrown = error
                }
            }
            t.check(thrown != nil, "EXTERNAL_ALT_7 a clear error is thrown when the alternate runtime fails to start")
            t.check(processAlive(foreignPID),
                    "EXTERNAL_ALT_7 the external server is completely unaffected by an alternate-endpoint startup failure")
        }

        // EXTERNAL_ALT_9: the small, bounded TOCTOU-race retry added during
        // the preview.26 release audit. A first allocated port "loses the
        // race" (the process exits immediately, exactly like mlx-serve
        // failing to bind) — ensureReady must retry with a different port
        // rather than failing outright, and must still never touch the
        // external server while doing so.
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("H3ExternalAlt-9-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let foreignRuntime = root.appendingPathComponent("foreign-mlx-serve")
            try writeSleepyRuntime(at: foreignRuntime)
            let flakyAltRuntime = root.appendingPathComponent("flaky-mlx-serve")
            let counterFile = root.appendingPathComponent("attempt-count.txt")
            try writeFlakyOnFirstAttemptRuntime(at: flakyAltRuntime, counterFile: counterFile)
            let modelDir = try makeModelDir(root, name: "model")

            let externalPort = reserveTestPort()
            let externalEndpoint = "http://127.0.0.1:\(externalPort)"
            let foreignProcess = try startForeignProcess(runtime: foreignRuntime)
            defer { if foreignProcess.isRunning { foreignProcess.terminate() } }
            let foreignPID = foreignProcess.processIdentifier

            let suite = "H3ExternalAlt-9-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let recordURL = root.appendingPathComponent("managed_server.json")
            let manager = MiniMaxH3RuntimeManager(userDefaults: defaults, managedServerRecordURL: recordURL)

            let hqID = MiniMaxH3Configuration.highQualityModelID
            let expectedHQID = MiniMaxH3Configuration.expectedServerModelIDs(for: hqID).first!
            let transport = H3PortAwareFakeTransport(externalPort: externalPort)
            transport.externalModelEntries = [["id": "standard-tier-model", "loaded": true, "state": "ready"]]
            transport.scheduleAlternateReady(after: 300_000_000, modelID: expectedHQID)
            // Tie "ready" to the REAL script's own attempt counter (not just
            // elapsed time) so this test actually proves the retry ran the
            // script a second time — a fixed delay alone can't distinguish
            // "the first, failed attempt happened to still be within the
            // window" from "a real second attempt occurred."
            transport.alternateReadinessGate = {
                (try? String(contentsOf: counterFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "2"
            }

            let configuredSnapshot = MiniMaxH3Configuration.Snapshot(
                modelDirectory: modelDir, runtimeExecutablePath: flakyAltRuntime.path,
                endpoint: externalEndpoint, targetModelID: hqID)

            var result: MiniMaxH3RuntimeStatus?
            var thrown: Error?
            h3AltAwait {
                do {
                    result = try await manager.ensureReady(snapshot: configuredSnapshot, transport: transport)
                } catch {
                    thrown = error
                }
            }

            t.check(thrown == nil, "EXTERNAL_ALT_9 a lost bind race on the first port is retried, not surfaced as a failure (got: \(String(describing: thrown)))")
            t.checkEqual(result?.state, .ready, "EXTERNAL_ALT_9 the retried attempt succeeds and ends Ready")
            let attemptCount = (try? String(contentsOf: counterFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            t.checkEqual(attemptCount, "2", "EXTERNAL_ALT_9 exactly one retry happened (attempt 1 failed, attempt 2 succeeded) — not a silent single try, not a runaway loop")
            t.check(processAlive(foreignPID),
                    "EXTERNAL_ALT_9 the external server is untouched by the retry")
            manager.stopOwnedServer()
        }
    }
}

/// Fake transport that answers differently depending on which port a
/// request targets — required to distinguish "the untouched external
/// endpoint" from "the newly prepared alternate endpoint" in the same test.
/// A port-agnostic fake (as used elsewhere in this test suite) cannot
/// exercise this scenario: it would answer both endpoints identically.
private final class H3PortAwareFakeTransport: MiniMaxH3HTTPTransport {
    private let lock = NSLock()
    let externalPort: Int
    var externalModelEntries: [[String: Any]] = []
    private var alternateModelEntries: [[String: Any]] = []
    /// Extra precondition for the alternate-port "ready" response, checked
    /// on every request rather than a fixed delay — for tests where a fixed
    /// delay could race ahead of a real, externally-verifiable signal (e.g.
    /// EXTERNAL_ALT_9's real retry-attempt counter). When set, the
    /// alternate endpoint answers `.cannotConnectToHost` (exactly like
    /// nothing being up yet) until this returns true, even if
    /// `alternateModelEntries` was already populated.
    var alternateReadinessGate: (() -> Bool)?

    init(externalPort: Int) {
        self.externalPort = externalPort
    }

    /// Simulates "the alternate app-owned server finishes loading its model
    /// a short time after being started" — mirrors the real staged-startup
    /// timing `startAndPoll`'s 1s poll loop expects to observe eventually.
    /// Does NOT touch the current interim state before the delay elapses:
    /// for a fresh transport that's "nothing listening yet" (the default,
    /// matching a real not-yet-started process); for a transport an earlier
    /// call already pointed at a *different* model via
    /// `setAlternateModelPresent`, that "wrong model present" read stays
    /// true until this transition fires — exactly the real shape of "the
    /// alt-port server from a previous generation is still up and still
    /// serving the old tier until this app stops and restarts it."
    func scheduleAlternateReady(after nanoseconds: UInt64, modelID: String) {
        Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            self.lock.lock()
            self.alternateModelEntries = [["id": modelID, "loaded": true, "state": "ready"]]
            self.lock.unlock()
        }
    }

    /// Simulates "an app-owned server from an earlier generation is still
    /// running at the alternate endpoint, serving a different model" —
    /// synchronous, no delay, matching that this is already-established
    /// state at the moment a new generation call probes it.
    func setAlternateModelPresent(modelID: String) {
        lock.lock()
        alternateModelEntries = [["id": modelID, "loaded": true, "state": "ready"]]
        lock.unlock()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let port = request.url?.port else { throw URLError(.cannotConnectToHost) }
        let path = request.url?.path ?? ""
        let entries: [[String: Any]]
        if port == externalPort {
            entries = externalModelEntries
        } else {
            lock.lock()
            let alt = alternateModelEntries
            lock.unlock()
            guard !alt.isEmpty else { throw URLError(.cannotConnectToHost) } // "not listening yet"
            if let gate = alternateReadinessGate, !gate() {
                throw URLError(.cannotConnectToHost) // scheduled, but the real precondition isn't true yet
            }
            entries = alt
        }
        let object: Any = path.hasSuffix("/health")
            ? ["status": "ok"]
            : ["data": entries]
        let data = try JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}

private func h3AltAwait(_ operation: @escaping () async -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await operation()
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 30)
}
