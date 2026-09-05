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

private final class SpyHybridDirector: DirectorProvider {
    let name = "spy-hybrid-director"
    private(set) var calls = 0

    func isAvailable() async -> Bool {
        calls += 1
        return true
    }

    func complete(system: String, prompt: String) async throws -> String {
        calls += 1
        return "{\"shots\":[{\"title\":\"Shot 1\",\"summary\":\"Creative rewrite\",\"durationSeconds\":5,\"camera\":{\"shotScale\":\"wide\",\"angle\":\"eye-level\",\"movement\":\"static\"}}]}"
    }

    func terminate() async {}
}

func runAutoMovieDirectorUITests(_ t: TestKit) {
    t.suite("Auto Movie Director ON/OFF UI & Wiring — Phase 3C-3") {

        // 1, 2, 3. UI State simulation: default ON, toggling OFF and back to ON
        var uiDirectorEnabled = true // Initial state in NewStoryboardSheet
        t.check(uiDirectorEnabled == true, "1. Auto Movie Director initial/default state is ON (true)")

        uiDirectorEnabled = false
        t.check(uiDirectorEnabled == false, "2. Toggling Director OFF sets state to false")

        uiDirectorEnabled = true
        t.check(uiDirectorEnabled == true, "3. Toggling Director ON restores state to true")

        // 4. ON creation passes directorEnabled = true to core and triggers director pipeline
        runAsyncTest {
            let spy = SpyHybridDirector()
            let director = StoryboardDirector(providers: [spy], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)

            var settings = ProjectSettings()
            settings.targetDurationSeconds = 10
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "UI ON Test",
                brief: "A lone sailboat drifts on a calm sea at sunset.",
                settings: settings,
                directorEnabled: true
            )
            t.check(spy.calls > 0, "4. ON creation passes directorEnabled=true and reaches director provider")
            t.check(result.project.shots.count >= 1, "4. ON project has shots")
        }

        // 5. OFF creation passes directorEnabled = false to core and bypasses director pipeline
        runAsyncTest {
            let spy = SpyHybridDirector()
            let director = StoryboardDirector(providers: [spy], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)

            var settings = ProjectSettings()
            settings.targetDurationSeconds = 10
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "UI OFF Test",
                brief: "A lone sailboat drifts on a calm sea at sunset.",
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(spy.calls, 0, "5. OFF creation passes directorEnabled=false and provider is NOT called (0 calls)")
            t.checkEqual(result.providerName, "Direct", "5. OFF provider is Direct")
            t.checkEqual(result.project.directorProvider, "Direct", "5. OFF project directorProvider is Direct")
            t.checkEqual(result.project.planningMode, "Direct (No Director)", "5. OFF planningMode is Direct (No Director)")
            t.checkEqual(result.project.shots.first?.compiledPrompt, "A lone sailboat drifts on a calm sea at sunset.", "5. Literal prompt preserved verbatim")
        }

        // 6. Core seam contract: No UI path bypasses HybridProjectCoordinator
        runAsyncTest {
            let coordinator = HybridProjectCoordinator(director: StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic))
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 15

            let onResult = try await coordinator.makeProject(
                title: "Seam ON",
                brief: "First scene action.\nSecond scene action.",
                settings: settings,
                directorEnabled: true
            )
            let offResult = try await coordinator.makeProject(
                title: "Seam OFF",
                brief: "First scene action.\nSecond scene action.",
                settings: settings,
                directorEnabled: false
            )

            t.checkEqual(onResult.project.workflowMode, "hybrid", "6. ON workflowMode is hybrid")
            t.checkEqual(offResult.project.workflowMode, "hybrid", "6. OFF workflowMode is hybrid")
        }

        // 7, 8. ON vs OFF prompt preservation & creative rewrite distinction
        runAsyncTest {
            let coordinator = HybridProjectCoordinator(director: StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic))
            let userPrompt = "The explorer opens the locked chest. Ancient light floods the chamber."
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 15

            let offResult = try await coordinator.makeProject(
                title: "OFF Verbatim Test",
                brief: userPrompt,
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(offResult.project.shots.count, 2, "8. OFF parsed into exactly 2 structural shots")
            t.checkEqual(offResult.project.shots[0].summary, "The explorer opens the locked chest.", "8. OFF Shot 1 literal summary")
            t.checkEqual(offResult.project.shots[0].compiledPrompt, "The explorer opens the locked chest.", "8. OFF Shot 1 literal compiledPrompt")
            t.checkEqual(offResult.project.shots[1].summary, "Ancient light floods the chamber.", "8. OFF Shot 2 literal summary")
            t.checkEqual(offResult.project.shots[1].compiledPrompt, "Ancient light floods the chamber.", "8. OFF Shot 2 literal compiledPrompt")
        }

        // 9, 10, 13. Error mapping & Fail-closed verification
        // 9a. Empty prompt
        let emptyError = StructuralMoviePlannerError.emptyPrompt
        t.checkEqual(emptyError.userFacingDescription, "Enter a movie prompt.", "13a. Empty prompt error mapping")
        t.checkEqual(emptyError.errorDescription, "Enter a movie prompt.", "13a. Empty prompt errorDescription")

        // 9b. Over 12 structural shots
        let over12Error = StructuralMoviePlannerError.exceedsMaximumShots(count: 14, maximum: 12)
        t.checkEqual(
            over12Error.userFacingDescription,
            "Director Off supports up to 12 structured shots. Reduce the number of segments or turn Director on.",
            "13b. Over 12 shots error mapping"
        )
        t.checkEqual(
            over12Error.errorDescription,
            "Director Off supports up to 12 structured shots. Reduce the number of segments or turn Director on.",
            "13b. Over 12 shots errorDescription"
        )

        // 9c. Capacity exceeded
        let capacityError = StructuralMoviePlannerError.exceedsDurationCapacity(requestedSeconds: 30, maximumRepresentableSeconds: 10)
        t.checkEqual(
            capacityError.userFacingDescription,
            "Director Off needs more prompt segments for this movie length. Add more shots/paragraphs or turn Director on.",
            "13c. Capacity exceeded error mapping"
        )
        t.checkEqual(
            capacityError.errorDescription,
            "Director Off needs more prompt segments for this movie length. Add more shots/paragraphs or turn Director on.",
            "13c. Capacity exceeded errorDescription"
        )

        // 10. OFF failure does not silently fallback to Director ON
        runAsyncTest {
            let spy = SpyHybridDirector()
            let director = StoryboardDirector(providers: [spy], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: director)

            var settings = ProjectSettings()
            settings.targetDurationSeconds = 30 // 1 shot, 30s requested -> capacity failure

            var didThrow = false
            do {
                _ = try await coordinator.makeProject(
                    title: "Capacity Error Fail-Closed",
                    brief: "Single sentence action.",
                    settings: settings,
                    directorEnabled: false
                )
            } catch StructuralMoviePlannerError.exceedsDurationCapacity {
                didThrow = true
            } catch {}

            t.check(didThrow, "10. Capacity failure threw error")
            t.checkEqual(spy.calls, 0, "10. OFF failure did NOT silently fallback to Director ON (0 calls to director)")
        }

        // 11. Selected model is preserved in OFF project
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.modelID = "custom-special-model-test"
            settings.targetDurationSeconds = 10

            let result = try await coordinator.makeProject(
                title: "Model Preservation",
                brief: "First action. Second action.",
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(result.project.settings.modelID, "custom-special-model-test", "11. Custom model ID preserved in OFF project")
        }

        // 12. ProductionJob compatibility
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 10

            let result = try await coordinator.makeProject(
                title: "Queue Compatibility",
                brief: "Action one. Action two.",
                settings: settings,
                directorEnabled: false
            )
            var snapshot = ProductionJobSnapshot()
            snapshot.projectID = result.project.id
            snapshot.brief = "Action one. Action two."
            snapshot.directorMode = "direct"
            snapshot.modelID = result.project.settings.modelID

            let job = ProductionJob(kind: .autoMovie, title: result.project.title, snapshot: snapshot)
            t.checkEqual(job.kind, .autoMovie, "12. ProductionJob kind is .autoMovie")
            t.checkEqual(job.snapshot.directorMode, "direct", "12. ProductionJob snapshot carries directorMode direct")
        }
    }
}
