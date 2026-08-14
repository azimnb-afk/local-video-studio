import Foundation
@testable import LTXVideoGeneratorCore

private func runAsyncProbe(_ block: @escaping () async throws -> Void) {
    let sem = DispatchSemaphore(value: 0)
    var testError: Error?
    Task {
        do {
            try await block()
        } catch {
            testError = error
        }
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    if let testError {
        fatalError("Real Director probe failed: \(testError)")
    }
}

func runRealDirectorPlanningCancellationAcceptanceProbe(_ t: TestKit) {
    t.suite("REAL LOCAL DIRECTOR RUNTIME ACCEPTANCE — 35B Model & Safe Cancellation") {

        let envService = DirectorEnvironmentService()

        runAsyncProbe {
            let snapshot = await envService.refresh(mode: .localAI)
            guard let model = snapshot.effectiveModel else {
                print("⚠️ [SKIP] No local AI model available for real Director runtime acceptance.")
                return
            }
            print("🎬 [PROBE BASELINE] Target Director Model: \(model)")

            // =================================================================
            // CASE A: Real 35B Planning Cancellation
            // =================================================================
            print("\n--- [CASE A] Starting Real 35B Planning with Cancellation ---")
            let handleA = DirectorPlanningHandle()
            let directorA = StoryboardDirector(requestedMode: .localAI)
            let coordinatorA = HybridProjectCoordinator(director: directorA)

            var phasesA: [DirectorPlanningPhase] = []
            var messagesA: [String] = []

            let startTimeA = Date()
            var cancelTriggeredTime: Date?
            var cancelLatency: TimeInterval = 0

            // Background task to trigger cancellation after request is in-flight
            Task {
                // Wait until structured planning is underway
                for _ in 0..<100 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    if phasesA.contains(.structuredPlanning) {
                        // Let the 35B model start generating on Ollama
                        try? await Task.sleep(nanoseconds: 800_000_000) // 800ms
                        cancelTriggeredTime = Date()
                        print("🛑 [CASE A] Triggering handleA.cancel() while Ollama 35B is actively processing...")
                        handleA.cancel()
                        break
                    }
                }
            }

            var caughtErrorA: Error?
            do {
                _ = try await coordinatorA.makeProject(
                    title: "Case A Cancellation Movie",
                    brief: "A lone astronaut repairs an orbital antenna outside a damaged space station.",
                    settings: ProjectSettings(),
                    handle: handleA,
                    progressCallback: { phase, message in
                        phasesA.append(phase)
                        messagesA.append(message)
                        print("   [Phase] \(phase.rawValue): \(message)")
                    }
                )
            } catch {
                if let triggerTime = cancelTriggeredTime {
                    cancelLatency = Date().timeIntervalSince(triggerTime)
                }
                caughtErrorA = error
                print("🛑 [CASE A] Planning aborted with error: \(error) (Cancel latency: \(cancelLatency)s)")
            }

            t.checkEqual(caughtErrorA as? DirectorError, DirectorError.cancelled, "Case A threw DirectorError.cancelled")
            t.checkEqual(phasesA.last, .cancelled, "Case A final phase is .cancelled")
            t.check(cancelLatency < 3.0, "Case A cancellation stopped promptly within 3 seconds")

            // Verify fallback isolation: cancellation must not cause Text or Template execution
            let templateFallbackUsed = directorA.diagnostics.contains { $0.stage == .templateFallback }
            let textRetryAttempted = directorA.diagnostics.contains { $0.stage == .retryFailed }
            t.check(!templateFallbackUsed, "Case A did not trigger template fallback")
            t.check(!textRetryAttempted, "Case A did not trigger text protocol retry fallback")

            // Wait a brief moment to ensure Ollama server is completely quiet
            try? await Task.sleep(nanoseconds: 500_000_000)

            // =================================================================
            // CASE B: Real 35B Planning Retry to Full Completion
            // =================================================================
            print("\n--- [CASE B] Starting Real 35B Planning Retry to Completion ---")
            let handleB = DirectorPlanningHandle()
            let directorB = StoryboardDirector(requestedMode: .localAI)
            let coordinatorB = HybridProjectCoordinator(director: directorB)

            var phasesB: [DirectorPlanningPhase] = []
            var messagesB: [String] = []

            let startTimeB = Date()
            let (projectB, violationsB, providerNameB) = try await coordinatorB.makeProject(
                title: "Case B Completed Movie",
                brief: "A lone astronaut repairs an orbital antenna outside a damaged space station.",
                settings: ProjectSettings(),
                handle: handleB,
                progressCallback: { phase, message in
                    phasesB.append(phase)
                    messagesB.append(message)
                    print("   [Phase] \(phase.rawValue): \(message)")
                }
            )
            let totalTimeB = Date().timeIntervalSince(startTimeB)
            print("✅ [CASE B] Planning completed in \(totalTimeB)s: planned \(projectB.shots.count) shots via \(providerNameB)")

            t.checkEqual(providerNameB, "ollama", "Case B used Ollama provider")
            t.checkEqual(projectB.planningMode, "ai", "Case B planning mode is ai (not fallback)")
            t.checkEqual(projectB.effectiveDirectorMode, "localAI", "Case B effective mode is localAI")
            t.check(projectB.shots.count >= 2, "Case B created multiple valid shots")
            t.checkEqual(phasesB.last, .completed, "Case B final phase is .completed")

            // UI Safety Verifications
            for msg in (messagesA + messagesB) {
                t.check(!msg.contains("<think>"), "Progress messages do not contain <think>")
                t.check(!msg.contains("%"), "Progress messages do not contain fake percentages")
            }
        }
    }
}
