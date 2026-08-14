import Foundation
@testable import LTXVideoGeneratorCore

private func runAsyncTest(_ block: @escaping () async throws -> Void) {
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
        fatalError("Async test failed: \(testError)")
    }
}

final class CancellableMockProvider: DirectorProvider {
    let name = "ollama"
    var modelIdentifier: String?
    var isFallbackProvider: Bool { false }

    var onJSONRequest: (() -> Void)?
    var onTextRequest: (() -> Void)?

    var jsonReply: String?
    var textReply: String?

    private(set) var jsonRequests = 0
    private(set) var textRequests = 0
    private(set) var terminateCalls = 0

    init(jsonReply: String? = nil, textReply: String? = nil, modelIdentifier: String? = nil) {
        self.jsonReply = jsonReply
        self.textReply = textReply
        self.modelIdentifier = modelIdentifier ?? "cancellation-mock-\(UUID().uuidString)"
    }

    func isAvailable() async -> Bool { true }
    func terminate() async { terminateCalls += 1 }

    func complete(system: String, prompt: String) async throws -> String {
        try await complete(system: system, prompt: prompt, expectsJSON: true)
    }

    func complete(system: String, prompt: String, expectsJSON: Bool) async throws -> String {
        if expectsJSON {
            jsonRequests += 1
            onJSONRequest?()
            if let jsonReply {
                return jsonReply
            }
            throw DirectorError.noResponse("no json reply")
        } else {
            textRequests += 1
            onTextRequest?()
            if let textReply {
                return textReply
            }
            throw DirectorError.noResponse("no text reply")
        }
    }
}

final class SpyTemplateProvider: DirectorProvider {
    let name = "template"
    var modelIdentifier: String? { nil }
    var isFallbackProvider: Bool { true }
    private(set) var invocations = 0

    func isAvailable() async -> Bool { true }
    func terminate() async {}

    func complete(system: String, prompt: String) async throws -> String {
        try await complete(system: system, prompt: prompt, expectsJSON: true)
    }

    func complete(system: String, prompt: String, expectsJSON: Bool) async throws -> String {
        invocations += 1
        return try await TemplateStoryboardProvider().complete(system: system, prompt: prompt, expectsJSON: expectsJSON)
    }
}

private let validStructuredJSON = """
{
  "logline": "A detective examines clues in a dimly lit office.",
  "shots": [
    {
      "title": "Office Entrance",
      "summary": "Detective enters the office.",
      "durationSeconds": 4,
      "shotScale": "wide",
      "angle": "eye-level",
      "movement": "track",
      "continuity": "cut"
    },
    {
      "title": "Desk Inspection",
      "summary": "Detective examines papers on the desk.",
      "durationSeconds": 5,
      "shotScale": "close-up",
      "angle": "high-angle",
      "movement": "static",
      "continuity": "continue"
    }
  ]
}
"""

private let validTextProtocol = """
LOGLINE: A detective examines clues in a dimly lit office.
SHOT 1
ACTION: Detective enters the dim office.
CAMERA: Wide shot, tracking forward.
MOTION_TEMPO: NORMAL
CAMERA_TEMPO: NORMAL
PLAYBACK_STYLE: REAL_TIME
CONTINUITY: CUT
SHOT 2
ACTION: Detective inspects the desk for evidence.
CAMERA: Close-up shot, static camera.
MOTION_TEMPO: SLOW
CAMERA_TEMPO: STATIC
PLAYBACK_STYLE: REAL_TIME
CONTINUITY: CONTINUE
"""

func runDirectorPlanningCancellationTests(_ t: TestKit) {
    t.suite("Director Planning Live Progress & Safe Cancellation") {

        // 1. Structured planning cancellation: MUST NOT fall back to Text or Template
        runAsyncTest {
            let mock = CancellableMockProvider()
            let templateSpy = SpyTemplateProvider()
            let handle = DirectorPlanningHandle()

            mock.onJSONRequest = {
                handle.cancel()
            }

            var recordedPhases: [DirectorPlanningPhase] = []
            let director = StoryboardDirector(providers: [mock, templateSpy], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)

            var caughtError: Error?
            do {
                _ = try await coordinator.makeProject(
                    title: "Cancel Test",
                    brief: "A detective examines clues.",
                    settings: ProjectSettings(),
                    handle: handle,
                    progressCallback: { phase, _ in
                        recordedPhases.append(phase)
                    }
                )
            } catch {
                caughtError = error
            }

            t.checkEqual(caughtError as? DirectorError, DirectorError.cancelled, "Throws DirectorError.cancelled on structured cancel")
            t.checkEqual(mock.textRequests, 0, "Text protocol was never invoked after structured cancellation")
            t.checkEqual(templateSpy.invocations, 0, "Template fallback was never invoked after structured cancellation")
            t.check(mock.terminateCalls > 0, "Provider terminated cleanly on cancellation")
            t.checkEqual(recordedPhases.last, .cancelled, "Final notified phase is cancelled")
        }

        // 2. Text protocol planning cancellation: MUST NOT fall back to Template
        runAsyncTest {
            let mock = CancellableMockProvider(jsonReply: nil, textReply: nil)
            let templateSpy = SpyTemplateProvider()
            let handle = DirectorPlanningHandle()

            mock.onTextRequest = {
                handle.cancel()
            }

            var recordedPhases: [DirectorPlanningPhase] = []
            let director = StoryboardDirector(providers: [mock, templateSpy], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)

            var caughtError: Error?
            do {
                _ = try await coordinator.makeProject(
                    title: "Cancel Test 2",
                    brief: "A detective examines clues.",
                    settings: ProjectSettings(),
                    handle: handle,
                    progressCallback: { phase, _ in
                        recordedPhases.append(phase)
                    }
                )
            } catch {
                caughtError = error
            }

            t.checkEqual(caughtError as? DirectorError, DirectorError.cancelled, "Throws DirectorError.cancelled on text protocol cancel")
            t.checkEqual(templateSpy.invocations, 0, "Template fallback was never invoked after text protocol cancellation")
            t.check(mock.terminateCalls > 0, "Provider terminated cleanly on cancellation")
            t.check(recordedPhases.contains(.textProtocolPlanning), "Transitioned through text protocol planning phase")
            t.checkEqual(recordedPhases.last, .cancelled, "Final notified phase is cancelled")
        }

        // 3. Structured fails -> Text succeeds (Existing fallback contract preserved)
        runAsyncTest {
            let mock = CancellableMockProvider(jsonReply: nil, textReply: validTextProtocol)
            let templateSpy = SpyTemplateProvider()
            let handle = DirectorPlanningHandle()

            var recordedPhases: [DirectorPlanningPhase] = []
            let director = StoryboardDirector(providers: [mock, templateSpy], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)

            let (project, _, providerName) = try await coordinator.makeProject(
                title: "Text Success Movie",
                brief: "A detective examines clues.",
                settings: ProjectSettings(),
                handle: handle,
                progressCallback: { phase, _ in
                    recordedPhases.append(phase)
                }
            )

            t.checkEqual(providerName, "ollama", "Ollama used via text protocol")
            t.checkEqual(project.planningMode, "ai", "Planning mode is ai")
            t.checkEqual(project.effectiveDirectorMode, "localAI", "Effective mode is localAI")
            t.checkEqual(project.directorProtocol, "textProtocol", "Director protocol is textProtocol")
            t.checkEqual(templateSpy.invocations, 0, "Template fallback was not invoked")
            t.checkEqual(recordedPhases.last, .completed, "Final notified phase is completed")
        }

        // 4. Structured fails -> Text fails -> Basic Fallback (Existing fallback contract preserved)
        runAsyncTest {
            let mock = CancellableMockProvider(jsonReply: nil, textReply: nil)
            let templateSpy = SpyTemplateProvider()
            let handle = DirectorPlanningHandle()

            let director = StoryboardDirector(providers: [mock, templateSpy], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)

            let (project, _, providerName) = try await coordinator.makeProject(
                title: "Fallback Movie",
                brief: "A detective examines clues.",
                settings: ProjectSettings(),
                handle: handle
            )

            t.checkEqual(providerName, "template", "Template provider used when all local protocols fail")
            t.checkEqual(project.planningMode, "fallback", "Planning mode is fallback")
            t.checkEqual(project.effectiveDirectorMode, "basic", "Effective mode is basic")
            t.checkEqual(templateSpy.invocations, 1, "Template fallback was invoked once")
        }

        // 5. Retry after cancellation: next run succeeds normally with fresh handle
        runAsyncTest {
            let mock = CancellableMockProvider(jsonReply: validStructuredJSON)
            let templateSpy = SpyTemplateProvider()

            // Run 1: Cancelled immediately
            let handle1 = DirectorPlanningHandle()
            handle1.cancel()
            let director = StoryboardDirector(providers: [mock, templateSpy], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)

            var run1Error: Error?
            do {
                _ = try await coordinator.makeProject(
                    title: "Run 1",
                    brief: "A detective examines clues.",
                    settings: ProjectSettings(),
                    handle: handle1
                )
            } catch {
                run1Error = error
            }
            t.checkEqual(run1Error as? DirectorError, DirectorError.cancelled, "Run 1 was cancelled immediately")

            // Run 2: Fresh handle succeeds
            let handle2 = DirectorPlanningHandle()
            let (project2, _, providerName2) = try await coordinator.makeProject(
                title: "Run 2",
                brief: "A detective examines clues.",
                settings: ProjectSettings(),
                handle: handle2
            )

            t.checkEqual(providerName2, "ollama", "Run 2 succeeded with Ollama")
            t.checkEqual(project2.planningMode, "ai", "Run 2 planning mode is ai")
            t.check(project2.shots.count >= 2, "Run 2 planned multiple shots")
        }

        // 6. Idempotent cancellation and post-completion safety
        do {
            let handle = DirectorPlanningHandle()
            t.checkEqual(handle.isCancelled, false, "Initial handle is not cancelled")
            handle.cancel()
            t.checkEqual(handle.isCancelled, true, "Handle marked cancelled after cancel()")
            handle.cancel() // Double cancel
            t.checkEqual(handle.isCancelled, true, "Handle remains cancelled after second cancel()")
        }

        // 7. Live progress phase sequence check
        runAsyncTest {
            let mock = CancellableMockProvider(jsonReply: validStructuredJSON)
            let director = StoryboardDirector(providers: [mock, TemplateStoryboardProvider()], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)
            var phases: [DirectorPlanningPhase] = []

            _ = try await coordinator.makeProject(
                title: "Phase Check",
                brief: "A detective examines clues.",
                settings: ProjectSettings(),
                progressCallback: { phase, _ in
                    phases.append(phase)
                }
            )

            t.check(phases.contains(.preparing), "Contains preparing phase")
            t.check(phases.contains(.structuredPlanning), "Contains structuredPlanning phase")
            t.check(phases.contains(.parsing), "Contains parsing phase")
            t.check(phases.contains(.applying), "Contains applying phase")
            t.checkEqual(phases.last, .completed, "Final phase is completed")
        }
    }
}
