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

func runAutoMovieDirectorFallbackTests(_ t: TestKit) {
    t.suite("Auto Movie Local AI Director Fallback & Protocol Resolution") {

        // 1. Structured JSON success
        runAsyncTest {
            let structuredJSON = """
            {
              "logline": "A woman catches a train.",
              "shots": [
                {
                  "title": "Departure",
                  "summary": "She runs to the platform.",
                  "durationSeconds": 4,
                  "shotScale": "wide",
                  "angle": "eye-level",
                  "movement": "track",
                  "continuity": "cut"
                },
                {
                  "title": "Boarding",
                  "summary": "She steps inside as doors close.",
                  "durationSeconds": 5,
                  "shotScale": "medium",
                  "angle": "eye-level",
                  "movement": "dolly",
                  "continuity": "continue"
                }
              ]
            }
            """
            let mock = ProtocolAwareMockProvider(jsonReply: structuredJSON, textReply: nil)
            let director = StoryboardDirector(providers: [mock, TemplateStoryboardProvider()], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)
            let (project, _, providerName) = try await coordinator.makeProject(
                title: "Test Movie",
                brief: "A woman catches a train.",
                settings: ProjectSettings()
            )

            t.checkEqual(providerName, "ollama", "Ollama provider used")
            t.checkEqual(project.planningMode, "ai", "Planning mode is ai")
            t.checkEqual(project.effectiveDirectorMode, "localAI", "Effective mode is localAI")
            t.checkEqual(project.directorProtocol, "structuredJSON", "Protocol is structuredJSON")
            t.checkEqual(project.fallbackReason, nil, "No fallback reason on success")
            t.check(project.shots.count >= 2, "Multiple shots planned")
        }

        // 2. Structured fails, Text Protocol succeeds -> MUST be Local AI, NOT Basic Fallback
        runAsyncTest {
            let invalidJSON = "{}"
            let validText = """
            LOGLINE: A woman rushes through the terminal and reaches her train just in time.
            SHOT 1
            ACTION: A woman sprints through the busy station corridor.
            CAMERA: Medium wide shot, tracking backwards fast.
            MOTION_TEMPO: FAST
            CAMERA_TEMPO: FAST
            PLAYBACK_STYLE: REAL_TIME
            CONTINUITY: CUT
            SHOT 2
            ACTION: She lunges forward and passes through the closing train doors.
            CAMERA: Medium close-up, static shot.
            MOTION_TEMPO: NORMAL
            CAMERA_TEMPO: STATIC
            PLAYBACK_STYLE: REAL_TIME
            CONTINUITY: CONTINUE
            SHOT 3
            ACTION: She rests against the train wall, catching her breath with a smile.
            CAMERA: Close-up, static shot.
            MOTION_TEMPO: SLOW
            CAMERA_TEMPO: STATIC
            PLAYBACK_STYLE: REAL_TIME
            CONTINUITY: CONTINUE
            """
            let mock = ProtocolAwareMockProvider(jsonReply: invalidJSON, textReply: validText)
            let director = StoryboardDirector(providers: [mock, TemplateStoryboardProvider()], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)
            let (project, _, providerName) = try await coordinator.makeProject(
                title: "Text Fallback Movie",
                brief: "A woman rushes to catch her train.",
                settings: ProjectSettings()
            )

            t.checkEqual(providerName, "ollama", "Local provider succeeded via Text Protocol")
            t.checkEqual(project.planningMode, "ai", "Planning mode is ai, NOT fallback")
            t.checkEqual(project.effectiveDirectorMode, "localAI", "Effective mode is localAI")
            t.checkEqual(project.directorProtocol, "textProtocol", "Recorded textProtocol as protocol")
            t.checkEqual(project.fallbackReason, nil, "No fallback reason on text protocol success")
            t.checkEqual(project.shots.count, 3, "Planned 3 scene-specific shots")
            t.check(project.shots[0].summary.contains("sprints through the busy station"), "Scene-specific action preserved")
            t.checkEqual(project.shots[1].continuityMode, .continueFromPrevious, "CONTINUE continuity preserved")
        }

        // 3. Structured fails and Text Protocol fails -> Basic Fallback with recorded reason
        runAsyncTest {
            let mock = ProtocolAwareMockProvider(jsonReply: "{}", textReply: "invalid garbage response with no markers")
            let director = StoryboardDirector(providers: [mock, TemplateStoryboardProvider()], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)
            let (project, _, providerName) = try await coordinator.makeProject(
                title: "Fallback Movie",
                brief: "A woman walks.",
                settings: ProjectSettings()
            )

            t.checkEqual(providerName, "template", "Template provider used on total failure")
            t.checkEqual(project.planningMode, "fallback", "Planning mode is fallback")
            t.checkEqual(project.effectiveDirectorMode, "basic", "Effective mode is basic")
            t.check(project.fallbackReason != nil, "Fallback reason recorded")
        }

        // 4. Intentional Basic mode -> NOT labeled fallback
        runAsyncTest {
            let director = StoryboardDirector(requestedMode: .basic)
            let coordinator = HybridProjectCoordinator(director: director)
            let (project, _, providerName) = try await coordinator.makeProject(
                title: "Basic Movie",
                brief: "A woman walks.",
                settings: ProjectSettings()
            )

            t.checkEqual(providerName, "template", "Template provider used")
            t.checkEqual(project.planningMode, "basic", "Planning mode is basic (not fallback)")
            t.checkEqual(project.effectiveDirectorMode, "basic", "Effective mode is basic")
            t.checkEqual(project.fallbackReason, nil, "No fallback reason on intentional basic")
        }

        // 5. FilmProject persistence roundtrip preserves all Director fields
        do {
            var project = FilmProject(id: UUID(), title: "Persistence Test")
            project.requestedDirectorMode = "localAI"
            project.effectiveDirectorMode = "localAI"
            project.planningMode = "ai"
            project.directorProvider = "ollama"
            project.directorModel = "qwen3.6-35b-uncensored:q4kp"
            project.directorProtocol = "textProtocol"
            project.fallbackReason = nil

            let data = try JSONEncoder().encode(project)
            let decoded = try JSONDecoder().decode(FilmProject.self, from: data)

            t.checkEqual(decoded.requestedDirectorMode, "localAI", "requestedDirectorMode roundtrips")
            t.checkEqual(decoded.effectiveDirectorMode, "localAI", "effectiveDirectorMode roundtrips")
            t.checkEqual(decoded.planningMode, "ai", "planningMode roundtrips")
            t.checkEqual(decoded.directorProvider, "ollama", "directorProvider roundtrips")
            t.checkEqual(decoded.directorModel, "qwen3.6-35b-uncensored:q4kp", "directorModel roundtrips")
            t.checkEqual(decoded.directorProtocol, "textProtocol", "directorProtocol roundtrips")
            t.checkEqual(decoded.fallbackReason, nil, "fallbackReason roundtrips")
        }

        // 6. Default URLSession timeout check
        do {
            let session = OllamaDirectorProvider.defaultSession
            t.checkEqual(session.configuration.timeoutIntervalForRequest, 300, "Ollama session timeout is 300 seconds")
            t.checkEqual(session.configuration.timeoutIntervalForResource, 300, "Ollama resource timeout is 300 seconds")
        }
    }
}
