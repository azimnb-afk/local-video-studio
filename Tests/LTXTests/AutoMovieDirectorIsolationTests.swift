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

// ============================================================================
// HISTORICAL REFERENCE (90ed66a) — TEST-ONLY NON-CIRCULAR REPLICA
// Derived strictly from git show 90ed66a:LTXVideoGenerator/Sources/Services/StoryboardDirector.swift
// DOES NOT call current directorEnabled:true internally.
// DOES NOT call StructuralMoviePlanner.
// ============================================================================
private final class HistoricalHybridCoordinator_90ed66a {
    private let director: StoryboardDirector

    init(director: StoryboardDirector) {
        self.director = director
    }

    func makeProject(
        projectID: UUID = UUID(),
        title: String,
        brief: String,
        settings: ProjectSettings,
        characterBible: CharacterBible = CharacterBible(),
        openingSceneEvidence: OpeningReferenceAppearance? = nil,
        handle: DirectorPlanningHandle? = nil,
        progressCallback: ((DirectorPlanningPhase, String) -> Void)? = nil
    ) async throws -> (project: FilmProject, violations: [ContinuityEngine.Violation], providerName: String) {
        var (project, violations, providerName) = try await director.makeProject(
            projectID: projectID, title: title, brief: brief,
            settings: settings, characterBible: characterBible,
            openingSceneEvidence: openingSceneEvidence,
            capabilityAwarePlanning: true,
            handle: handle,
            progressCallback: progressCallback
        )
        let target = min(60, max(5, settings.targetDurationSeconds ?? 20))
        let desiredCount = min(12, max(1, Int(ceil(target / 5))))
        if project.shots.count == 1, desiredCount > 1, let source = project.shots.first {
            let scales = AutoMovieBeatPlanner.shotScales(count: desiredCount)
            let angles = AutoMovieBeatPlanner.cameraAngles(count: desiredCount)
            let movements = AutoMovieBeatPlanner.cameraMovements(count: desiredCount)
            var shots: [Shot] = []
            var state = source.continuityBefore ?? ContinuitySnapshot()
            for index in 0..<desiredCount {
                var shot = source
                shot.id = UUID()
                shot.index = index
                shot.title = AutoMovieBeatPlanner.title(index: index, count: desiredCount)
                shot.summary = AutoMovieBeatPlanner.beatSummary(
                    brief: source.summary, index: index, count: desiredCount
                )
                shot.camera.shotScale = scales[index]
                shot.camera.angle = angles[index]
                shot.camera.movement = movements[index]
                shot.continuityBefore = state
                shot.takes = []
                shot.selectedTakeID = nil
                shot.continuityMode = index == 0 ? .cut : .continueFromPrevious
                shot.continuityImageRelativePath = nil
                shot.continuitySourceTakeID = nil
                shot.continuityBlockedReason = nil
                shot.originalCameraScale = nil
                shot.capabilityAdjustmentReason = nil
                shots.append(shot)

                if let next = try? ContinuityEngine.apply(changes: shot.explicitChanges, to: state) {
                    state = next
                }
            }
            project.shots = shots
        }

        project.shots = AutoMovieDurationPlanner.normalize(
            shots: project.shots,
            targetDurationSeconds: target,
            fps: settings.fps
        )
        project.shots = ContinuityReconciler.reconcile(shots: project.shots)
        project.workflowMode = "hybrid"
        for index in project.shots.indices {
            CharacterPromptPipeline.recompilePlan(project: &project, shotIndex: index)
        }
        return (project, violations, providerName)
    }
}

// ============================================================================
// POISON / SPY DIRECTOR PROVIDER FOR ZERO-LLM STRUCTURAL PROOF
// ============================================================================
private final class PoisonDirectorProvider: DirectorProvider {
    let name = "poison-director-provider"
    private(set) var invocationCount = 0

    func isAvailable() async -> Bool {
        invocationCount += 1
        return true
    }

    func complete(system: String, prompt: String) async throws -> String {
        invocationCount += 1
        throw PoisonDirectorError.poisonProviderInvoked
    }

    func terminate() async {}
}

private enum PoisonDirectorError: Error, Equatable {
    case poisonProviderInvoked
}

// ============================================================================
// COMPARISON UTILITIES
// ============================================================================
private func assertProjectsMatchNonCircular(
    historical: FilmProject,
    current: FilmProject,
    t: TestKit,
    fixtureName: String
) {
    // 1. Project-level invariants
    t.checkEqual(current.workflowMode, historical.workflowMode, "\(fixtureName): workflowMode matches (\(historical.workflowMode ?? "nil"))")
    t.checkEqual(current.settings.modelID, historical.settings.modelID, "\(fixtureName): modelID matches (\(historical.settings.modelID))")
    t.checkEqual(current.settings.width, historical.settings.width, "\(fixtureName): width matches (\(historical.settings.width))")
    t.checkEqual(current.settings.height, historical.settings.height, "\(fixtureName): height matches (\(historical.settings.height))")
    t.checkEqual(current.settings.fps, historical.settings.fps, "\(fixtureName): fps matches (\(historical.settings.fps))")
    t.checkEqual(current.settings.targetDurationSeconds, historical.settings.targetDurationSeconds, "\(fixtureName): targetDurationSeconds matches")
    t.checkEqual(current.directorProvider, historical.directorProvider, "\(fixtureName): directorProvider matches (\(historical.directorProvider ?? "nil"))")
    t.checkEqual(current.planningMode, historical.planningMode, "\(fixtureName): planningMode matches (\(historical.planningMode ?? "nil"))")
    t.checkEqual(current.characterBible.characters.count, historical.characterBible.characters.count, "\(fixtureName): bible characters count matches")

    // 2. Shot-level invariants
    t.checkEqual(current.shots.count, historical.shots.count, "\(fixtureName): shots count matches (\(historical.shots.count))")

    for i in 0..<min(current.shots.count, historical.shots.count) {
        let curShot = current.shots[i]
        let histShot = historical.shots[i]

        t.checkEqual(curShot.index, histShot.index, "\(fixtureName) [Shot \(i)]: index matches")
        t.checkEqual(curShot.title, histShot.title, "\(fixtureName) [Shot \(i)]: title matches (\(histShot.title))")
        t.checkEqual(curShot.summary, histShot.summary, "\(fixtureName) [Shot \(i)]: summary matches")
        t.checkEqual(curShot.compiledPrompt, histShot.compiledPrompt, "\(fixtureName) [Shot \(i)]: compiledPrompt matches")
        t.checkEqual(curShot.baseCompiledPrompt, histShot.baseCompiledPrompt, "\(fixtureName) [Shot \(i)]: baseCompiledPrompt matches")
        t.check(abs(curShot.durationSeconds - histShot.durationSeconds) < 0.0001, "\(fixtureName) [Shot \(i)]: durationSeconds matches (\(histShot.durationSeconds)s)")
        t.checkEqual(curShot.continuityMode, histShot.continuityMode, "\(fixtureName) [Shot \(i)]: continuityMode matches")
        t.checkEqual(curShot.plannedContinuityMode, histShot.plannedContinuityMode, "\(fixtureName) [Shot \(i)]: plannedContinuityMode matches")
        t.checkEqual(curShot.shotPurpose, histShot.shotPurpose, "\(fixtureName) [Shot \(i)]: shotPurpose matches")
        t.checkEqual(curShot.actionBeatCount, histShot.actionBeatCount, "\(fixtureName) [Shot \(i)]: actionBeatCount matches")
        t.checkEqual(curShot.endStateSummary, histShot.endStateSummary, "\(fixtureName) [Shot \(i)]: endStateSummary matches")
        t.checkEqual(curShot.camera.shotScale, histShot.camera.shotScale, "\(fixtureName) [Shot \(i)]: camera.shotScale matches")
        t.checkEqual(curShot.camera.angle, histShot.camera.angle, "\(fixtureName) [Shot \(i)]: camera.angle matches")
        t.checkEqual(curShot.camera.movement, histShot.camera.movement, "\(fixtureName) [Shot \(i)]: camera.movement matches")
        t.checkEqual(curShot.characterIDs, histShot.characterIDs, "\(fixtureName) [Shot \(i)]: characterIDs matches")
        t.checkEqual(curShot.takes.count, histShot.takes.count, "\(fixtureName) [Shot \(i)]: takes count matches")
        t.checkEqual(curShot.selectedTakeID, histShot.selectedTakeID, "\(fixtureName) [Shot \(i)]: selectedTakeID matches")
    }
}

// ============================================================================
// TEST SUITE ENTRY POINT
// ============================================================================
func runAutoMovieDirectorIsolationTests(_ t: TestKit) {
    t.suite("Auto Movie Director Isolation & Non-Circular Parity — Phase 3C-2.1") {

        // --------------------------------------------------------------------
        // PART A: NON-CIRCULAR DIRECTOR ON PARITY AGAINST 90ED66A
        // --------------------------------------------------------------------

        // Fixture A: Normal multi-shot deterministic Director ON project
        runAsyncTest {
            let director1 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let director2 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let historical = HistoricalHybridCoordinator_90ed66a(director: director1)
            let current = HybridProjectCoordinator(director: director2)

            var settings = ProjectSettings()
            settings.targetDurationSeconds = 15
            settings.fps = 24
            settings.modelID = "ltx-2"
            let prompt = "Scene 1: An old train arrives at the station at night.\nScene 2: Passengers step onto the snowy platform."

            let histRes = try await historical.makeProject(
                title: "Fixture A Multi-Shot",
                brief: prompt,
                settings: settings
            )
            let curRes = try await current.makeProject(
                title: "Fixture A Multi-Shot",
                brief: prompt,
                settings: settings,
                directorEnabled: true
            )

            assertProjectsMatchNonCircular(
                historical: histRes.project,
                current: curRes.project,
                t: t,
                fixtureName: "Fixture A (Multi-Shot)"
            )
            t.checkEqual(curRes.providerName, histRes.providerName, "Fixture A: providerName matches")
            t.checkEqual(curRes.violations.count, histRes.violations.count, "Fixture A: violations count matches")
        }

        // Fixture B: Single-shot provider result that triggers AutoMovieBeatPlanner expansion
        runAsyncTest {
            let director1 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let director2 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let historical = HistoricalHybridCoordinator_90ed66a(director: director1)
            let current = HybridProjectCoordinator(director: director2)

            var settings = ProjectSettings()
            settings.targetDurationSeconds = 20
            settings.fps = 24
            let prompt = "A lone eagle glides gracefully over vast mountain ridges."

            let histRes = try await historical.makeProject(
                title: "Fixture B Single-Shot Expansion",
                brief: prompt,
                settings: settings
            )
            let curRes = try await current.makeProject(
                title: "Fixture B Single-Shot Expansion",
                brief: prompt,
                settings: settings,
                directorEnabled: true
            )

            assertProjectsMatchNonCircular(
                historical: histRes.project,
                current: curRes.project,
                t: t,
                fixtureName: "Fixture B (Single-Shot Expansion)"
            )
            t.check(curRes.project.shots.count >= 3, "Fixture B: expanded to multiple shots")
        }

        // Fixture C: Explicit CUT / continuity-related project
        runAsyncTest {
            let director1 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let director2 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let historical = HistoricalHybridCoordinator_90ed66a(director: director1)
            let current = HybridProjectCoordinator(director: director2)

            var settings = ProjectSettings()
            settings.targetDurationSeconds = 12
            settings.fps = 24
            let prompt = "Shot 1: In the laboratory.\n[CUT]\nShot 2: Exterior of the facility in heavy storm."

            let histRes = try await historical.makeProject(
                title: "Fixture C Continuity",
                brief: prompt,
                settings: settings
            )
            let curRes = try await current.makeProject(
                title: "Fixture C Continuity",
                brief: prompt,
                settings: settings,
                directorEnabled: true
            )

            assertProjectsMatchNonCircular(
                historical: histRes.project,
                current: curRes.project,
                t: t,
                fixtureName: "Fixture C (Continuity)"
            )
        }

        // Fixture D: Custom model ID
        runAsyncTest {
            let director1 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let director2 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let historical = HistoricalHybridCoordinator_90ed66a(director: director1)
            let current = HybridProjectCoordinator(director: director2)

            var settings = ProjectSettings()
            settings.modelID = "custom-special-model-v1"
            settings.targetDurationSeconds = 15
            settings.fps = 24
            let prompt = "A cyberpunk drone flies between towering neon skyscrapers."

            let histRes = try await historical.makeProject(
                title: "Fixture D Custom Model",
                brief: prompt,
                settings: settings
            )
            let curRes = try await current.makeProject(
                title: "Fixture D Custom Model",
                brief: prompt,
                settings: settings,
                directorEnabled: true
            )

            assertProjectsMatchNonCircular(
                historical: histRes.project,
                current: curRes.project,
                t: t,
                fixtureName: "Fixture D (Custom Model)"
            )
            t.checkEqual(curRes.project.settings.modelID, "custom-special-model-v1", "Fixture D: custom model ID matches")
        }

        // Fixture E: Non-default resolution / fps
        runAsyncTest {
            let director1 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let director2 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let historical = HistoricalHybridCoordinator_90ed66a(director: director1)
            let current = HybridProjectCoordinator(director: director2)

            var settings = ProjectSettings()
            settings.width = 1024
            settings.height = 576
            settings.fps = 30
            settings.targetDurationSeconds = 25
            let prompt = "A runner sprinting in slow motion down the street."

            let histRes = try await historical.makeProject(
                title: "Fixture E Resolution/FPS",
                brief: prompt,
                settings: settings
            )
            let curRes = try await current.makeProject(
                title: "Fixture E Resolution/FPS",
                brief: prompt,
                settings: settings,
                directorEnabled: true
            )

            assertProjectsMatchNonCircular(
                historical: histRes.project,
                current: curRes.project,
                t: t,
                fixtureName: "Fixture E (Resolution/FPS)"
            )
            t.checkEqual(curRes.project.settings.width, 1024, "Fixture E: width is 1024")
            t.checkEqual(curRes.project.settings.height, 576, "Fixture E: height is 576")
            t.checkEqual(curRes.project.settings.fps, 30, "Fixture E: fps is 30")
        }

        // Fixture F: Character Bible fixture
        runAsyncTest {
            let director1 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let director2 = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
            let historical = HistoricalHybridCoordinator_90ed66a(director: director1)
            let current = HybridProjectCoordinator(director: director2)

            var bible = CharacterBible()
            let character = BibleCharacter(name: "Elena", lockedTraits: [.face, .hair])
            bible.characters = [character]

            var settings = ProjectSettings()
            settings.targetDurationSeconds = 15
            settings.fps = 24
            let prompt = "Elena enters the abandoned library and discovers an ancient book."

            let histRes = try await historical.makeProject(
                title: "Fixture F Character Bible",
                brief: prompt,
                settings: settings,
                characterBible: bible
            )
            let curRes = try await current.makeProject(
                title: "Fixture F Character Bible",
                brief: prompt,
                settings: settings,
                characterBible: bible,
                directorEnabled: true
            )

            assertProjectsMatchNonCircular(
                historical: histRes.project,
                current: curRes.project,
                t: t,
                fixtureName: "Fixture F (Character Bible)"
            )
            t.checkEqual(curRes.project.characterBible.characters.first?.name, "Elena", "Fixture F: character name preserved")
        }

        // --------------------------------------------------------------------
        // PART B: ZERO-LLM STRUCTURAL PROOF VIA POISON DIRECTOR
        // --------------------------------------------------------------------

        // 1. Success path: Poison Director provider invocation count is strictly 0
        runAsyncTest {
            let poisonProvider = PoisonDirectorProvider()
            let poisonDirector = StoryboardDirector(providers: [poisonProvider], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: poisonDirector)

            var settings = ProjectSettings()
            settings.targetDurationSeconds = 15
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "Poison OFF Success Test",
                brief: "A lone sailboat drifts on a calm sea. The sun sets over the horizon.",
                settings: settings,
                directorEnabled: false
            )

            t.checkEqual(poisonProvider.invocationCount, 0, "POISON_DIRECTOR_INVOCATIONS (Success Path) is exactly 0")
            t.checkEqual(result.providerName, "Direct", "OFF route returned providerName Direct")
            t.checkEqual(result.project.directorProvider, "Direct", "OFF route set project.directorProvider to Direct")
            t.checkEqual(result.project.shots.count, 2, "OFF route created exactly 2 shots")
        }

        // 2. Empty prompt error path: Poison Director is untouched (0 calls) & fails closed
        runAsyncTest {
            let poisonProvider = PoisonDirectorProvider()
            let poisonDirector = StoryboardDirector(providers: [poisonProvider], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: poisonDirector)

            var caughtExpectedError = false
            do {
                _ = try await coordinator.makeProject(
                    title: "Poison OFF Empty Prompt Test",
                    brief: "   \n\t  ",
                    settings: ProjectSettings(),
                    directorEnabled: false
                )
            } catch StructuralMoviePlannerError.emptyPrompt {
                caughtExpectedError = true
            } catch {}

            t.check(caughtExpectedError, "Empty prompt threw StructuralMoviePlannerError.emptyPrompt")
            t.checkEqual(poisonProvider.invocationCount, 0, "POISON_DIRECTOR_INVOCATIONS (Empty Prompt) is exactly 0")
        }

        // 3. Over 12 structural segments error path: Poison Director is untouched (0 calls) & fails closed
        runAsyncTest {
            let poisonProvider = PoisonDirectorProvider()
            let poisonDirector = StoryboardDirector(providers: [poisonProvider], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: poisonDirector)

            var settings = ProjectSettings()
            settings.targetDurationSeconds = 60
            settings.fps = 24

            let prompt13Shots = (1...13).map { "Beat number \($0) takes place here." }.joined(separator: " ")

            var caughtExpectedError = false
            do {
                _ = try await coordinator.makeProject(
                    title: "Poison OFF Over 12 Shots Test",
                    brief: prompt13Shots,
                    settings: settings,
                    directorEnabled: false
                )
            } catch StructuralMoviePlannerError.exceedsMaximumShots(let count, _) {
                caughtExpectedError = (count == 13)
            } catch {}

            t.check(caughtExpectedError, "13 shots threw StructuralMoviePlannerError.exceedsMaximumShots(13)")
            t.checkEqual(poisonProvider.invocationCount, 0, "POISON_DIRECTOR_INVOCATIONS (Over 12 Shots) is exactly 0")
        }

        // 4. Duration capacity exceeded error path: Poison Director is untouched (0 calls) & fails closed
        runAsyncTest {
            let poisonProvider = PoisonDirectorProvider()
            let poisonDirector = StoryboardDirector(providers: [poisonProvider], requestedMode: .localAI)
            let coordinator = HybridProjectCoordinator(director: poisonDirector)

            var settings = ProjectSettings()
            settings.targetDurationSeconds = 30 // 1 shot, max 10s -> capacity 10s < 30s
            settings.fps = 24

            let prompt1Shot = "A solitary monk meditates upon the high mountain peak in tranquility."

            var caughtExpectedError = false
            do {
                _ = try await coordinator.makeProject(
                    title: "Poison OFF Capacity Failure Test",
                    brief: prompt1Shot,
                    settings: settings,
                    directorEnabled: false
                )
            } catch StructuralMoviePlannerError.exceedsDurationCapacity(let requested, let maxCap) {
                caughtExpectedError = (abs(requested - 30.0) < 0.001 && abs(maxCap - 10.0) < 0.001)
            } catch {}

            t.check(caughtExpectedError, "Capacity error threw StructuralMoviePlannerError.exceedsDurationCapacity")
            t.checkEqual(poisonProvider.invocationCount, 0, "POISON_DIRECTOR_INVOCATIONS (Capacity Failure) is exactly 0")
        }
    }
}
