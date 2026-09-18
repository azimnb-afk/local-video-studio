import Foundation
@testable import LTXVideoGeneratorCore

/// Regression cover for FIX_H3_GENERATION_AFTER_MODEL_SWITCH (2026-09-18).
///
/// Bug: once the Generate/One Shot picker started showing all three H3 tiers
/// regardless of runtime readiness (a prior fix), selecting a tier that
/// wasn't the one currently loaded on the shared runtime and pressing
/// Generate opened the Setup Wizard instead of starting generation — even
/// though `MiniMaxH3RuntimeManager.ensureReady` already knew how to stop an
/// app-owned wrong-model server and start the requested one. The request was
/// never enqueued, so that existing logic was never reached.
///
/// Root cause: `DefaultModelChecker.checkVideoModel()`'s H3 branch mapped
/// `.wrongModel` straight to `SetupStatus.invalid` unconditionally, which
/// makes `DependencyHealthManager.canStartGeneration == false` and routes
/// every Generate press to the Setup Wizard sheet before a job is ever built.
///
/// Fix: that branch is extracted into `DefaultModelChecker.
/// classifyH3SetupStatus(state:readiness:ownership:activeGenerationOwner:
/// detail:)`, a pure function (not a mirror — `checkVideoModel()` calls it),
/// which now also returns `.ready` for `.wrongModel` exactly when
/// `MiniMaxH3RuntimeManager.canSafelyPrepareWrongModel` says the running
/// server is provably app-owned and no H3 generation is currently in
/// flight — the same two facts `ensureReady`'s own switch logic already
/// depends on. `ModelReadinessStatus.canGenerate` / `ModelReadiness.status`
/// are UNCHANGED: a wrong-model tier still reports "Wrong Model" everywhere
/// readiness is displayed (picker status suffix, sidebar, Settings). Only
/// the Generate-button preflight gate changed.
func runH3GenerateAfterSwitchTests(_ t: TestKit) {
    let standardID = MiniMaxH3Configuration.standardModelID
    let hqID = MiniMaxH3Configuration.highQualityModelID
    let refID = MiniMaxH3Configuration.referenceModelID

    func ready(_ modelID: String) -> ModelReadiness {
        ModelReadiness(modelID: modelID, status: .ready, reason: nil)
    }
    func wrongModel(_ modelID: String) -> ModelReadiness {
        ModelReadiness(modelID: modelID, status: .serverModelMismatch, reason: "The running H3 server has a different model loaded.")
    }
    func serverNotRunning(_ modelID: String) -> ModelReadiness {
        ModelReadiness(modelID: modelID, status: .serverNotRunning, reason: "starts when generation begins")
    }
    func notConfigured(_ modelID: String) -> ModelReadiness {
        ModelReadiness(modelID: modelID, status: .notConfigured, reason: "Choose the local H3 model folder in Settings.")
    }
    let owner = MiniMaxH3GenerationLease.Owner(pid: 4242, bundleID: "com.localvideostudio.personal", startedAt: Date())

    // =====================================================================
    // Pure predicate: MiniMaxH3RuntimeManager.canSafelyPrepareWrongModel
    // =====================================================================
    t.suite("canSafelyPrepareWrongModel — pure predicate") {
        t.checkEqual(
            MiniMaxH3RuntimeManager.canSafelyPrepareWrongModel(ownership: .appOwned, activeGenerationOwner: nil),
            true, "app-owned + no active generation -> safe to prepare")
        t.checkEqual(
            MiniMaxH3RuntimeManager.canSafelyPrepareWrongModel(ownership: .appOwned, activeGenerationOwner: owner),
            false, "app-owned but a generation is in flight -> NOT safe (never yank a running job's runtime)")
        // FIX_H3_EXTERNAL_SERVER_COEXISTENCE_AND_AUTOMATIC_ALT_PORT_ROUTING
        // (2026-09-18): external+wrongModel is no longer an unconditional
        // block. ensureReady never touches the external server either way —
        // it now has a second strategy (a separate, app-owned-only
        // alternate endpoint) for exactly this case, so the Generate-gate
        // decision only needs to ask "is a generation already in flight?"
        t.checkEqual(
            MiniMaxH3RuntimeManager.canSafelyPrepareWrongModel(ownership: .externallyRunning, activeGenerationOwner: nil),
            true, "external server -> safe to attempt: ensureReady routes to a separate app-owned alternate endpoint, never touching the external one")
        t.checkEqual(
            MiniMaxH3RuntimeManager.canSafelyPrepareWrongModel(ownership: .externallyRunning, activeGenerationOwner: owner),
            false, "external + a generation already in flight -> NOT safe (an alt-endpoint prepare must not race a running job either)")
    }

    // =====================================================================
    // Pure decision: DefaultModelChecker.classifyH3SetupStatus
    // Directly exercises the exact function checkVideoModel() calls.
    // =====================================================================
    t.suite("classifyH3SetupStatus — Generate-gate decision") {

        // H3_GENERATE_SWITCH_1: Efficient Ready, Efficient selected -> straight to generation path
        do {
            let status = DefaultModelChecker.classifyH3SetupStatus(
                state: .ready, readiness: ready(standardID),
                ownership: .appOwned, activeGenerationOwner: nil,
                detail: "Ready")
            t.checkEqual(status, .ready, "H3_GENERATE_SWITCH_1 the currently-loaded, Ready tier proceeds straight through")
        }

        // H3_GENERATE_SWITCH_2: Efficient Ready loaded, Quality selected ->
        // NOT early-rejected; proceeds to the runtime-preparation path
        // (app-owned case: the shared server is one this app started).
        do {
            let status = DefaultModelChecker.classifyH3SetupStatus(
                state: .wrongModel, readiness: wrongModel(hqID),
                ownership: .appOwned, activeGenerationOwner: nil,
                detail: "A server is healthy, but the expected H3 model is not ready.")
            t.checkEqual(status, .ready,
                         "H3_GENERATE_SWITCH_2 Wrong Model on an app-owned server does not early-reject; ensureReady may prepare it")
        }

        // H3_GENERATE_SWITCH_3: same, for Reference.
        do {
            let status = DefaultModelChecker.classifyH3SetupStatus(
                state: .wrongModel, readiness: wrongModel(refID),
                ownership: .appOwned, activeGenerationOwner: nil,
                detail: "A server is healthy, but the expected H3 model is not ready.")
            t.checkEqual(status, .ready,
                         "H3_GENERATE_SWITCH_3 Wrong Model on an app-owned server does not early-reject Reference either")
        }

        // H3_GENERATE_SWITCH_4: no server at all -> the existing idle-H3 path
        // (unchanged by this fix) still lets ensureReady start it from scratch.
        do {
            let status = DefaultModelChecker.classifyH3SetupStatus(
                state: .notRunning, readiness: serverNotRunning(standardID),
                ownership: .externallyRunning, activeGenerationOwner: nil,
                detail: "No MiniMax H3 server is listening at http://127.0.0.1:11236.")
            t.checkEqual(status, .ready,
                         "H3_GENERATE_SWITCH_4 no server at all still proceeds to ensureReady (pre-existing behavior, unchanged)")
        }

        // H3_GENERATE_SWITCH_5 (decision half — see the integration suite
        // below for the actual stop+restart): app-owned wrong model is
        // .ready regardless of which two H3 tiers are involved.
        do {
            let status = DefaultModelChecker.classifyH3SetupStatus(
                state: .wrongModel, readiness: wrongModel(standardID),
                ownership: .appOwned, activeGenerationOwner: nil,
                detail: "A server is healthy, but the expected H3 model is not ready.")
            t.checkEqual(status, .ready, "H3_GENERATE_SWITCH_5 app-owned wrong-model switch is allowed through")
        }
        // ...but never while a generation is actually in flight (this
        // profile's own job, or another Local Video Studio process's).
        do {
            let status = DefaultModelChecker.classifyH3SetupStatus(
                state: .wrongModel, readiness: wrongModel(hqID),
                ownership: .appOwned, activeGenerationOwner: owner,
                detail: "A server is healthy, but the expected H3 model is not ready.")
            t.checkEqual(status, .invalid("A server is healthy, but the expected H3 model is not ready."),
                         "H3_GENERATE_SWITCH_5b a generation in flight blocks the auto-switch, never yanking a running job's runtime")
        }

        // H3_GENERATE_SWITCH_6 / EXTERNAL_ALT: external server with the wrong
        // model loaded -> now allowed through (2026-09-18 alt-port routing
        // fix). ensureReady never touches this server; see
        // H3ExternalServerAltPortTests.swift for the real stop-free,
        // signal-free, alternate-endpoint integration coverage.
        do {
            let status = DefaultModelChecker.classifyH3SetupStatus(
                state: .wrongModel, readiness: wrongModel(hqID),
                ownership: .externallyRunning, activeGenerationOwner: nil,
                detail: "A server is healthy, but the expected H3 model is not ready.")
            t.checkEqual(status, .ready,
                         "H3_GENERATE_SWITCH_6 an externally-owned wrong-model server no longer early-rejects; ensureReady routes to an alternate app-owned endpoint")
        }

        // H3_GENERATE_SWITCH_7: model path missing -> correctly stops
        // generation (unaffected by this fix).
        do {
            let status = DefaultModelChecker.classifyH3SetupStatus(
                state: .notConfigured, readiness: notConfigured(refID),
                ownership: .externallyRunning, activeGenerationOwner: nil,
                detail: "Choose the local H3 model folder in Settings.")
            t.checkEqual(status, .missing("Choose the local H3 model folder in Settings."),
                         "H3_GENERATE_SWITCH_7 a genuinely unconfigured model still stops generation with actionable guidance")
        }

        // H3_GENERATE_SWITCH_8: a real runtime failure (.failed/.broken)
        // still surfaces as an error, app-owned or not — this fix only
        // widens the .wrongModel case, never .failed/.broken.
        do {
            let appOwnedFailed = DefaultModelChecker.classifyH3SetupStatus(
                state: .failed, readiness: ModelReadiness(modelID: standardID, status: .serverUnhealthy, reason: nil),
                ownership: .appOwned, activeGenerationOwner: nil,
                detail: "The mlx-serve process exited before becoming ready: error: FileNotFound")
            t.checkEqual(appOwnedFailed, .invalid("The mlx-serve process exited before becoming ready: error: FileNotFound"),
                         "H3_GENERATE_SWITCH_8 a runtime-prepare failure is a real error even when app-owned")
        }

        // Regression: .ready and the pre-existing .starting/.broken paths are untouched.
        t.checkEqual(
            DefaultModelChecker.classifyH3SetupStatus(
                state: .ready, readiness: ready(standardID), ownership: .appOwned, activeGenerationOwner: nil, detail: "Ready"),
            .ready, "an already-Ready model is unaffected")
        t.checkEqual(
            DefaultModelChecker.classifyH3SetupStatus(
                state: .starting, readiness: ModelReadiness(modelID: standardID, status: .serverUnhealthy, reason: "starting"),
                ownership: .appOwned, activeGenerationOwner: nil, detail: "The H3 server is still starting."),
            .missing("starting"), "a starting server is unaffected (still Setup-blocking, not an early reject bug)")
    }

    // =====================================================================
    // Integration: ensureReady's actual stop+restart / no-touch behavior,
    // using real subprocesses (fake mlx-serve scripts) and a fake transport
    // so no real model weights or network server are needed.
    // =====================================================================
    t.suite("ensureReady — real subprocess ownership behavior") {
        func writeSleepyRuntime(at url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexec sleep 300\n".utf8).write(to: url)
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

        // ---- H3_GENERATE_SWITCH_5 / APP_OWNED_SERVER_CAN_BE_MANAGED ----
        // An app-owned server with the wrong model loaded is safely stopped
        // and replaced, and ensureReady succeeds for the newly-selected tier.
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("H3SwitchTests-appOwned-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let runtime = root.appendingPathComponent("mlx-serve")
            try writeSleepyRuntime(at: runtime)
            let oldModelDir = try makeModelDir(root, name: "old-model")
            let newModelDir = try makeModelDir(root, name: "new-model")

            let suite = "H3SwitchTests-appOwned-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let recordURL = root.appendingPathComponent("managed_server.json")
            let manager = MiniMaxH3RuntimeManager(userDefaults: defaults, managedServerRecordURL: recordURL)

            let endpoint = "http://127.0.0.1:19851"
            // Establish an app-owned server for the OLD tier directly (mirrors
            // what an earlier ensureReady(standard) call would have left behind).
            try manager.startOwnedServer(runtime: runtime.path, model: oldModelDir, endpoint: endpoint)
            guard let oldPID = manager.ownedServerPID else {
                t.check(false, "H3_GENERATE_SWITCH_5 setup: the old app-owned server actually started")
                return
            }
            t.checkEqual(manager.ownership(for: endpoint), .appOwned,
                         "H3_GENERATE_SWITCH_5 the server this test just started is recognized as app-owned")
            t.check(processAlive(oldPID), "H3_GENERATE_SWITCH_5 setup: the old owned process is alive before the switch")

            // Fake transport: reports the OLD model as loaded (wrong for the
            // tier we're about to request), then — simulating the new
            // process finishing its (here, instant) startup — flips to
            // report the NEW tier's expected model as ready.
            let transport = H3SwitchFakeTransport()
            transport.modelEntries = [["id": "old-tier-model", "loaded": true, "state": "ready"]]
            let newTargetID = MiniMaxH3Configuration.highQualityModelID
            let expectedNewID = MiniMaxH3Configuration.expectedServerModelIDs(for: newTargetID).first!
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                transport.modelEntries = [["id": expectedNewID, "loaded": true, "state": "ready"]]
            }

            let snapshot = MiniMaxH3Configuration.Snapshot(
                modelDirectory: newModelDir, runtimeExecutablePath: runtime.path,
                endpoint: endpoint, targetModelID: newTargetID)

            var result: MiniMaxH3RuntimeStatus?
            var thrown: Error?
            h3SwitchAwait {
                do {
                    result = try await manager.ensureReady(snapshot: snapshot, transport: transport)
                } catch {
                    thrown = error
                }
            }

            t.check(thrown == nil, "H3_GENERATE_SWITCH_5 the app-owned switch completes without throwing (got: \(String(describing: thrown)))")
            t.checkEqual(result?.state, .ready, "H3_GENERATE_SWITCH_5 the new tier ends Ready")
            t.check(!processAlive(oldPID), "APP_OWNED_SERVER_CAN_BE_MANAGED the old owned process was actually terminated, not leaked")
            if let newPID = manager.ownedServerPID {
                t.check(processAlive(newPID), "H3_GENERATE_SWITCH_5 a fresh owned process is running for the new tier")
                t.check(newPID != oldPID, "H3_GENERATE_SWITCH_5 the new process is not the same PID as the old one")
                // Cleanup: this manager instance still thinks it owns this
                // process, so stopOwnedServer() safely tears it down.
                manager.stopOwnedServer()
            }
        }

        // H3_GENERATE_SWITCH_6's *integration* half (a foreign/external
        // wrong-model server) moved to H3ExternalServerAltPortTests.swift's
        // EXTERNAL_ALT suite as of FIX_H3_EXTERNAL_SERVER_COEXISTENCE_AND_
        // AUTOMATIC_ALT_PORT_ROUTING (2026-09-18): the old expectation here
        // (ensureReady throws for that case) was superseded by the alt-port
        // routing fix, and asserting the new behavior needs a port-aware
        // fake transport (this file's H3SwitchFakeTransport answers every
        // port identically, which can't distinguish "the untouched external
        // endpoint" from "the newly prepared alternate one") — see that
        // file's EXTERNAL_ALT_1/2/3/4/5/8 for the equivalent, corrected
        // coverage (external never touched, alt endpoint prepared instead
        // of an error).
    }
}

/// Isolated fake transport for this file (the H3Tests.swift one is file-private).
private final class H3SwitchFakeTransport: MiniMaxH3HTTPTransport {
    var healthStatus = 200
    var healthObject: [String: Any] = ["status": "ok"]
    var modelsStatus = 200
    var modelEntries: [[String: Any]] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let object: Any
        let status: Int
        if path.hasSuffix("/health") {
            object = healthObject
            status = healthStatus
        } else {
            object = ["data": modelEntries]
            status = modelsStatus
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}

private func h3SwitchAwait(_ operation: @escaping () async -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await operation()
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 15)
}
