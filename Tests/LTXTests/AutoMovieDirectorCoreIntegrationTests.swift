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

private func makeDeterministicDirector() -> StoryboardDirector {
    StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
}

func runAutoMovieDirectorCoreIntegrationTests(_ t: TestKit) {
    t.suite("Auto Movie Director Core Integration — Phase 3C-2") {

        // ====================================================================
        // PHASE A: DIRECTOR ON CHARACTERIZATION TESTS
        // ====================================================================

        // 1. Director ON multi-shot fixture parity
        runAsyncTest {
            let coordinator = HybridProjectCoordinator(director: makeDeterministicDirector())
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 15
            settings.fps = 24
            settings.modelID = "ltx-2"

            let result = try await coordinator.makeProject(
                title: "ON Multi-Shot Test",
                brief: "A detective walks into a dim office. She sits behind the desk and opens a locked drawer.",
                settings: settings,
                directorEnabled: true
            )
            t.check(result.project.shots.count >= 1, "1. Director ON produces shots")
            t.checkEqual(result.project.workflowMode, "hybrid", "1. Director ON workflowMode is hybrid")
            t.checkEqual(result.project.settings.modelID, "ltx-2", "1. Director ON modelID preserved")
        }

        // 2. Single-shot ON → AutoMovieBeatPlanner expansion
        runAsyncTest {
            let coordinator = HybridProjectCoordinator(director: makeDeterministicDirector())
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 20
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "ON Single-Shot Expansion Test",
                brief: "A runner crosses the finish line.",
                settings: settings,
                directorEnabled: true
            )
            t.check(result.project.shots.count >= 1, "2. Single-shot ON executes and expands")
        }

        // 3. ON duration parity (normalized sum equals target)
        runAsyncTest {
            let coordinator = HybridProjectCoordinator(director: makeDeterministicDirector())
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 25
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "ON Duration Test",
                brief: "An astronaut enters the capsule. He checks controls. The rocket launches.",
                settings: settings,
                directorEnabled: true
            )
            let totalDuration = result.project.shots.reduce(0.0) { $0 + $1.durationSeconds }
            t.check(abs(totalDuration - 25.0) <= 1.5, "3. Director ON total duration close to 25s target")
        }

        // 4. ON transition parity (Shot 0 is cut)
        runAsyncTest {
            let coordinator = HybridProjectCoordinator(director: makeDeterministicDirector())
            let settings = ProjectSettings()

            let result = try await coordinator.makeProject(
                title: "ON Transition Test",
                brief: "Scene 1: Morning in Paris. Scene 2: Evening in Tokyo.",
                settings: settings,
                directorEnabled: true
            )
            t.checkEqual(result.project.shots.first?.continuityMode, .cut, "4. Shot 1 is CUT")
        }

        // 5. ON prompt parity (compiledPrompt is populated via CharacterPromptPipeline)
        runAsyncTest {
            let coordinator = HybridProjectCoordinator(director: makeDeterministicDirector())
            let settings = ProjectSettings()

            let result = try await coordinator.makeProject(
                title: "ON Prompt Test",
                brief: "A scientist observes glowing crystals under a microscope.",
                settings: settings,
                directorEnabled: true
            )
            if let shot = result.project.shots.first {
                t.check(!shot.compiledPrompt.isEmpty, "5. Director ON compiledPrompt is generated")
            }
        }

        // 6. ON model parity (modelID preserved)
        runAsyncTest {
            let coordinator = HybridProjectCoordinator(director: makeDeterministicDirector())
            var settings = ProjectSettings()
            settings.modelID = "custom-ltx-v2"

            let result = try await coordinator.makeProject(
                title: "ON Custom Model Test",
                brief: "A drone flies over mountains.",
                settings: settings,
                directorEnabled: true
            )
            t.checkEqual(result.project.settings.modelID, "custom-ltx-v2", "6. Custom model ID preserved")
        }

        // 7. ON FilmProject settings parity
        runAsyncTest {
            let coordinator = HybridProjectCoordinator(director: makeDeterministicDirector())
            var settings = ProjectSettings()
            settings.width = 512
            settings.height = 768
            settings.fps = 30

            let result = try await coordinator.makeProject(
                title: "ON Settings Test",
                brief: "Vertical video test action.",
                settings: settings,
                directorEnabled: true
            )
            t.checkEqual(result.project.settings.width, 512, "7. Width preserved")
            t.checkEqual(result.project.settings.height, 768, "7. Height preserved")
            t.checkEqual(result.project.settings.fps, 30, "7. FPS preserved")
        }

        // 8. ON shot count parity
        runAsyncTest {
            let coordinator = HybridProjectCoordinator(director: makeDeterministicDirector())
            let settings = ProjectSettings()

            let result = try await coordinator.makeProject(
                title: "ON Shot Count Test",
                brief: "Action one. Action two.",
                settings: settings,
                directorEnabled: true
            )
            t.check(result.project.shots.count >= 1, "8. ON shot count test runs")
        }

        // ====================================================================
        // PHASE B: DIRECTOR OFF TESTS
        // ====================================================================

        // 1. One English sentence → 1 Shot
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 5
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "OFF 1 Shot Test",
                brief: "A lone sailboat drifts on a calm sea at sunset.",
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 1, "OFF-1. Exactly 1 shot created")
            t.checkEqual(result.project.shots[0].summary, "A lone sailboat drifts on a calm sea at sunset.", "OFF-1. Summary is literal")
            t.checkEqual(result.project.shots[0].compiledPrompt, "A lone sailboat drifts on a calm sea at sunset.", "OFF-1. compiledPrompt is literal")
            t.checkEqual(result.project.shots[0].continuityMode, .cut, "OFF-1. Shot 1 is CUT")
            t.checkEqual(result.providerName, "Direct", "OFF-1. providerName is Direct")
        }

        // 2. Three English sentences → 3 Shots
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 20
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "OFF 3 Shot Test",
                brief: "The chef chops fresh herbs. She tosses them into a hot pan. Steam rises with an enticing aroma.",
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 3, "OFF-2. Exactly 3 shots created")
            t.checkEqual(result.project.shots[0].summary, "The chef chops fresh herbs.", "OFF-2. Shot 1 literal prompt")
            t.checkEqual(result.project.shots[0].continuityMode, .cut, "OFF-2. Shot 1 is CUT")
            t.checkEqual(result.project.shots[1].summary, "She tosses them into a hot pan.", "OFF-2. Shot 2 literal prompt")
            t.checkEqual(result.project.shots[1].continuityMode, .continueFromPrevious, "OFF-2. Shot 2 is CONTINUE")
            t.checkEqual(result.project.shots[2].summary, "Steam rises with an enticing aroma.", "OFF-2. Shot 3 literal prompt")
            t.checkEqual(result.project.shots[2].continuityMode, .continueFromPrevious, "OFF-2. Shot 3 is CONTINUE")
        }

        // 3. Three Japanese sentences → 3 Shots
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 15
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "OFF 3 Shot Japanese Test",
                brief: "侍が刀を抜く。敵を見据える。一閃して納刀する。",
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 3, "OFF-3. Exactly 3 Japanese shots created")
            t.checkEqual(result.project.shots[0].summary, "侍が刀を抜く。", "OFF-3. Shot 1 literal Japanese")
            t.checkEqual(result.project.shots[0].continuityMode, .cut, "OFF-3. Shot 1 is CUT")
            t.checkEqual(result.project.shots[1].summary, "敵を見据える。", "OFF-3. Shot 2 literal Japanese")
            t.checkEqual(result.project.shots[1].continuityMode, .continueFromPrevious, "OFF-3. Shot 2 is CONTINUE")
            t.checkEqual(result.project.shots[2].summary, "一閃して納刀する。", "OFF-3. Shot 3 literal Japanese")
            t.checkEqual(result.project.shots[2].continuityMode, .continueFromPrevious, "OFF-3. Shot 3 is CONTINUE")
        }

        // 4. Two paragraphs → expected CUT / CONTINUE
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 24
            settings.fps = 24

            let prompt = """
            A man reads a book in the library. He closes it quietly.

            He walks outside into the rain. He opens an umbrella.
            """
            let result = try await coordinator.makeProject(
                title: "OFF Paragraph Test",
                brief: prompt,
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 4, "OFF-4. Exactly 4 shots created")
            t.checkEqual(result.project.shots[0].continuityMode, .cut, "OFF-4. Shot 1 is CUT")
            t.checkEqual(result.project.shots[1].continuityMode, .continueFromPrevious, "OFF-4. Shot 2 is CONTINUE")
            t.checkEqual(result.project.shots[2].continuityMode, .cut, "OFF-4. Shot 3 (new paragraph) is CUT")
            t.checkEqual(result.project.shots[3].continuityMode, .continueFromPrevious, "OFF-4. Shot 4 is CONTINUE")
        }

        // 5. Explicit CUT
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            let prompt = """
            Looking through the telescope.
            [CUT]
            A distant nebula glows in deep space.
            """
            let result = try await coordinator.makeProject(
                title: "OFF Explicit CUT Test",
                brief: prompt,
                settings: ProjectSettings(),
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 2, "OFF-5. 2 shots created")
            t.checkEqual(result.project.shots[1].continuityMode, .cut, "OFF-5. Shot 2 is CUT via explicit marker")
            t.checkEqual(result.project.shots[1].summary, "A distant nebula glows in deep space.", "OFF-5. Marker stripped")
        }

        // 6. Explicit CONTINUE
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            let prompt = """
            Shot 1:
            The racecar accelerates down the straightaway.

            [CONTINUE]
            Shot 2:
            The car drifts smoothly through the hairpin turn.
            """
            let result = try await coordinator.makeProject(
                title: "OFF Explicit CONTINUE Test",
                brief: prompt,
                settings: ProjectSettings(),
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 2, "OFF-6. 2 shots created")
            t.checkEqual(result.project.shots[1].continuityMode, .continueFromPrevious, "OFF-6. Shot 2 is CONTINUE via explicit marker")
            t.checkEqual(result.project.shots[1].summary, "The car drifts smoothly through the hairpin turn.", "OFF-6. Marker stripped")
        }

        // 7. Sentinel raw prompt preservation (no camera/lighting/dialogue/bible injection)
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            let sentinel = """
            DIRECT_AUTO_MOVIE_INTEGRATION_SENTINEL_101.
            subject walks left.
            subject stops.
            """
            let result = try await coordinator.makeProject(
                title: "OFF Sentinel Test",
                brief: sentinel,
                settings: ProjectSettings(),
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 3, "OFF-7. 3 shots created")
            t.checkEqual(result.project.shots[0].compiledPrompt, "DIRECT_AUTO_MOVIE_INTEGRATION_SENTINEL_101.", "OFF-7. Shot 1 exact verbatim")
            t.checkEqual(result.project.shots[1].compiledPrompt, "subject walks left.", "OFF-7. Shot 2 exact verbatim")
            t.checkEqual(result.project.shots[2].compiledPrompt, "subject stops.", "OFF-7. Shot 3 exact verbatim")

            for shot in result.project.shots {
                t.check(!shot.compiledPrompt.contains("camera"), "OFF-7. No camera injected")
                t.check(!shot.compiledPrompt.contains("lighting"), "OFF-7. No lighting injected")
                t.check(!shot.compiledPrompt.contains("says:"), "OFF-7. No dialogue injected")
                t.check(!shot.compiledPrompt.contains("Opening"), "OFF-7. No Opening injected")
                t.check(!shot.compiledPrompt.contains("Development"), "OFF-7. No Development injected")
                t.check(!shot.compiledPrompt.contains("Resolution"), "OFF-7. No Resolution injected")
            }
        }

        // 8, 9, 10, 11, 12. Strict zero-LLM / zero creative pipeline contract
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            let result = try await coordinator.makeProject(
                title: "OFF Zero LLM Test",
                brief: "First action. Second action.",
                settings: ProjectSettings(),
                directorEnabled: false
            )
            t.checkEqual(result.providerName, "Direct", "OFF-8. Provider is Direct")
            t.checkEqual(result.project.directorProvider, "Direct", "OFF-8. directorProvider is Direct")
            t.checkEqual(result.project.planningMode, "Direct (No Director)", "OFF-8. planningMode is Direct (No Director)")
        }

        // 13. Equal duration allocation
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 30
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "OFF Equal Duration Test",
                brief: "Shot one action. Shot two action. Shot three action.",
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 3, "OFF-13. 3 shots created")
            let shots = result.project.shots
            if shots.count == 3 {
                // 30s across 3 shots at 24fps: 90 units total -> 30 units each (241 frames = 10.0s)
                t.checkEqual(shots[0].durationSeconds, 10.0, "OFF-13. Shot 1 is exactly 10.0s")
                t.checkEqual(shots[1].durationSeconds, 10.0, "OFF-13. Shot 2 is exactly 10.0s")
                t.checkEqual(shots[2].durationSeconds, 10.0, "OFF-13. Shot 3 is exactly 10.0s")
            }
        }

        // 14. Deterministic remainder allocation
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 15
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "OFF Remainder Duration Test",
                brief: "First action here. Second action here.",
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 2, "OFF-14. 2 shots created")
            let shots = result.project.shots
            if shots.count == 2 {
                // 15s at 24fps = 360 frames = 45 units -> 23 units (7.666s) and 22 units (7.333s)
                t.checkEqual(shots[0].durationSeconds, Double(23 * 8) / 24.0, "OFF-14. Shot 0 gets remainder unit")
                t.checkEqual(shots[1].durationSeconds, Double(22 * 8) / 24.0, "OFF-14. Shot 1 gets base units")
                let sum = shots[0].durationSeconds + shots[1].durationSeconds
                t.check(abs(sum - 15.0) < 0.001, "OFF-14. Total duration is exactly 15.0s")
            }
        }

        // 15. Capacity success
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 28
            settings.fps = 24

            let result = try await coordinator.makeProject(
                title: "OFF Capacity Success Test",
                brief: "Action 1. Action 2. Action 3.",
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 3, "OFF-15. 28s with 3 shots is within capacity (3x10s = 30s)")
        }

        // 16. Capacity fail-closed (1 shot, 30s requested -> throws)
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 30
            settings.fps = 24

            var caught = false
            do {
                _ = try await coordinator.makeProject(
                    title: "OFF Capacity Fail Test",
                    brief: "Single long action that cannot fit in one 10s shot.",
                    settings: settings,
                    directorEnabled: false
                )
            } catch StructuralMoviePlannerError.exceedsDurationCapacity {
                caught = true
            } catch {}
            t.check(caught, "OFF-16. Exceeding capacity throws exceedsDurationCapacity (Fail-Closed)")
        }

        // 17. No Director ON fallback on error
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var caught = false
            do {
                _ = try await coordinator.makeProject(
                    title: "OFF Empty Test",
                    brief: "",
                    settings: ProjectSettings(),
                    directorEnabled: false
                )
            } catch StructuralMoviePlannerError.emptyPrompt {
                caught = true
            } catch {}
            t.check(caught, "OFF-17. Empty prompt fails closed without falling back to Director ON")
        }

        // 18, 19. One model ID across all shots, no auto engine switching
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.modelID = "test-custom-backend"

            let result = try await coordinator.makeProject(
                title: "OFF Model ID Test",
                brief: "Action 1. Action 2.",
                settings: settings,
                directorEnabled: false
            )
            t.checkEqual(result.project.settings.modelID, "test-custom-backend", "OFF-18. Project settings modelID matches")
        }

        // 20, 21. CUT and CONTINUE preserved
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            let prompt = "First action.\n[CUT]\nSecond action.\n[CONTINUE]\nThird action."
            let result = try await coordinator.makeProject(
                title: "OFF Transitions Test",
                brief: prompt,
                settings: ProjectSettings(),
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 3, "OFF-20. 3 shots created")
            t.checkEqual(result.project.shots[0].continuityMode, .cut, "OFF-20. Shot 1 is CUT")
            t.checkEqual(result.project.shots[1].continuityMode, .cut, "OFF-20. Shot 2 is CUT")
            t.checkEqual(result.project.shots[2].continuityMode, .continueFromPrevious, "OFF-21. Shot 3 is CONTINUE")
        }

        // 22, 23. FilmProject created, shot count == segment count
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            let result = try await coordinator.makeProject(
                title: "OFF FilmProject Test",
                brief: "One. Two. Three. Four.",
                settings: ProjectSettings(),
                directorEnabled: false
            )
            t.checkEqual(result.project.shots.count, 4, "OFF-23. Shot count matches segment count (4)")
            t.checkEqual(result.project.workflowMode, "hybrid", "OFF-22. workflowMode is hybrid")
        }

        // 24. Compatible with ProductionJob(.autoMovie)
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 5
            let result = try await coordinator.makeProject(
                title: "OFF ProductionJob Test",
                brief: "An action takes place.",
                settings: settings,
                directorEnabled: false
            )
            var snapshot = ProductionJobSnapshot()
            snapshot.projectID = result.project.id
            snapshot.brief = "An action takes place."
            snapshot.modelID = result.project.settings.modelID
            let job = ProductionJob(kind: .autoMovie, title: result.project.title, snapshot: snapshot)
            t.checkEqual(job.kind, .autoMovie, "OFF-24. Compatible with ProductionJob(.autoMovie)")
            t.checkEqual(job.title, "OFF ProductionJob Test", "OFF-24. Project title matches")
        }

        // 25. Existing conditioning metadata preserved
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var bible = CharacterBible()
            let character = BibleCharacter(name: "Elena")
            bible.characters = [character]

            let result = try await coordinator.makeProject(
                title: "OFF Bible Test",
                brief: "Elena enters the room. She looks around.",
                settings: ProjectSettings(),
                characterBible: bible,
                directorEnabled: false
            )
            t.checkEqual(result.project.characterBible.characters.first?.name, "Elena", "OFF-25. CharacterBible preserved")
        }

        // 26. No 361-frame One Shot allowance leaks into Auto Movie (capped at 241 frames)
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.targetDurationSeconds = 60
            settings.fps = 24

            let prompt = (1...6).map { "Shot \($0) action." }.joined(separator: " ")
            let result = try await coordinator.makeProject(
                title: "OFF 241 Frame Ceiling Test",
                brief: prompt,
                settings: settings,
                directorEnabled: false
            )
            for shot in result.project.shots {
                t.check(shot.durationSeconds <= 10.001, "OFF-26. No shot exceeds 10.0s / 241 frames ceiling")
            }
        }

        // 27. H3 duration policy capacity check
        runAsyncTest {
            let coordinator = HybridProjectCoordinator()
            var settings = ProjectSettings()
            settings.modelID = MiniMaxH3Configuration.modelID
            settings.targetDurationSeconds = 25 // 2 shots with H3 (max ~9.54s each = ~19.08s cap)
            settings.fps = 24

            var caught = false
            do {
                _ = try await coordinator.makeProject(
                    title: "OFF H3 Capacity Test",
                    brief: "First action. Second action.",
                    settings: settings,
                    directorEnabled: false
                )
            } catch StructuralMoviePlannerError.exceedsDurationCapacity {
                caught = true
            } catch {}
            t.check(caught, "OFF-27. H3 capacity correctly caps at H3 maximum (~9.54s per shot)")
        }
    }
}
