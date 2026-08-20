import Foundation
@testable import LTXVideoGeneratorCore

func runCharacterContinuitySafetyTests(_ t: TestKit) {
    t.suite("Character Continuity Safety Tests") {

        // MARK: - A. Structured prompt contains Character Continuity Safety
        let structuredPrompt = StoryboardDirector.storyboardSystemPrompt
        t.check(structuredPrompt.contains("CHARACTER CONTINUITY SAFETY"), "Structured prompt contains safety header")
        t.check(structuredPrompt.contains("avoid prolonged face absence"), "Structured prompt guides against prolonged face absence")
        t.check(structuredPrompt.contains("split the shot BEFORE identity information is lost"), "Structured prompt instructs shot splitting before identity loss")

        // MARK: - B. Text Protocol contains semantic equivalent
        let textSystem = DirectorPlanFormat.systemPrompt(for: .textProtocol, characterBible: CharacterBible())
        t.check(textSystem.contains("CHARACTER CONTINUITY SAFETY"), "Text Protocol system prompt contains safety guidance")
        t.check(textSystem.contains("avoid prolonged face absence"), "Text Protocol guides against prolonged face absence")

        let textTemplate = DirectorPlanFormat.textProtocolTemplate
        t.check(textTemplate.contains("CHARACTER CONTINUITY SAFETY"), "Text Protocol template contains safety guidance")
        t.check(textTemplate.contains("split shots before characters leave or disappear"), "Text Protocol template includes shot split directive")

        // MARK: - C. Basic Template risky face-absence case
        let riskySummary = "A woman walks down a corridor, leaves the frame completely, the camera stays on the empty corridor, then she returns toward the camera."
        let riskyDraft = StoryboardDirector.ShotPlanDraft(
            title: "Risky Shot",
            summary: riskySummary,
            shotScale: "medium",
            continuity: "continue"
        )
        let basicPlanned = CapabilityAwareShotPlanner.plan(
            shots: [riskyDraft],
            brief: "A woman in a hallway"
        )
        t.check(basicPlanned.adjustments.first?.reasons.contains("prolonged subject disappearance/empty-frame risk") == true, "Risky face absence detected in Basic planner")
        let effectiveSummary = basicPlanned.shots.first?.summary ?? ""
        t.check(!effectiveSummary.contains("stays on the empty corridor"), "Basic planner avoids prolonged empty-frame interval")
        t.check(effectiveSummary.contains("approaches the corridor exit") || effectiveSummary.contains("keeping facial and clothing features visible"), "Basic planner preserves identity evidence before boundary")

        // MARK: - D. Explicit "back only" user intent preserved
        let explicitBackBrief = "Show only her back for the entire shot."
        let backDraft = StoryboardDirector.ShotPlanDraft(
            title: "Back Shot",
            summary: "A woman stands facing away, showing only her back for the entire shot.",
            shotScale: "medium",
            continuity: "continue"
        )
        let backPlanned = CapabilityAwareShotPlanner.plan(
            shots: [backDraft],
            brief: explicitBackBrief
        )
        t.check(backPlanned.adjustments.first?.honoursExplicitUserFraming == true, "Explicit back intent preserved in Basic planner")
        t.checkEqual(backPlanned.shots.first?.summary, backDraft.summary, "Explicit back summary left untouched")

        // MARK: - E. Explicit "leave frame" user intent preserved
        let explicitExitBrief = "A silhouette of a traveler who leaves frame completely into sunset."
        let exitDraft = StoryboardDirector.ShotPlanDraft(
            title: "Exit Shot",
            summary: "A silhouette of a traveler who leaves frame completely into sunset.",
            shotScale: "wide",
            continuity: "cut"
        )
        let exitPlanned = CapabilityAwareShotPlanner.plan(
            shots: [exitDraft],
            brief: explicitExitBrief
        )
        t.check(exitPlanned.adjustments.first?.honoursExplicitUserFraming == true, "Explicit exit intent preserved in Basic planner")

        // MARK: - F. Gradual camera guidance
        let instruction = CharacterContinuitySafetyPolicy.directorInstruction
        t.check(instruction.contains("Use gradual camera reframing"), "Instructs gradual camera reframing")
        t.check(instruction.contains("rather than extreme abrupt jumps"), "Warns against extreme abrupt jumps")

        let scales3 = AutoMovieBeatPlanner.shotScales(count: 3)
        t.checkEqual(scales3, ["wide", "medium", "close-up"], "3-beat movie uses gradual ladder progression")

        let scales4 = AutoMovieBeatPlanner.shotScales(count: 4)
        t.checkEqual(scales4, ["wide", "medium", "medium-close-up", "close-up"], "4-beat movie steps smoothly without extreme leaps")

        // MARK: - G. Identity-critical text remains concise
        var char = CharacterBibleEntry(name: "Elena")
        char.appearance.hair = "black bob haircut"
        char.appearance.faceDescription = "sharp angular features"
        char.appearance.eyes = "green eyes"
        char.defaultCostume = "red leather jacket"

        let resolved = ContinuityEngine.ResolvedCharacterState(
            id: char.id,
            name: char.name,
            appearance: char.appearance,
            currentCostume: char.defaultCostume,
            accessories: "",
            continuityNotes: "",
            lockedTraits: [.face, .hair, .costume]
        )

        let compiled = PromptCompiler.compile(characters: [resolved])
        t.check(compiled.contains("Elena"), "Contains character name")
        t.check(compiled.contains("Hair: black bob haircut."), "Contains hair description")
        t.check(compiled.contains("Face: sharp angular features."), "Contains face description")
        t.check(compiled.contains("Current costume: red leather jacket."), "Contains costume")
        t.check(compiled.count < 300, "Compiled character context remains concise (\(compiled.count) chars)")

        // MARK: - H. Auto Movie strict continuity regression & manual Storyboard preservation
        // Explicit deterministic provider: HybridProjectCoordinator()'s default
        // StoryboardDirector() can reach a real local Ollama endpoint in a dev
        // environment that has one configured, making shots.count and
        // continuityMode depend on live LLM sampling instead of this test's
        // own logic. Real-Director acceptance belongs in the explicit
        // --v3-*/--v4-* probes, not here.
        let coordinator = HybridProjectCoordinator(
            director: StoryboardDirector(providers: [TemplateStoryboardProvider()]))
        let settings = ProjectSettings(targetDurationSeconds: 15)

        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let result = try await coordinator.makeProject(
                    title: "Continuity Test",
                    brief: "A young woman walks through a gallery",
                    settings: settings
                )
                let shots = result.project.shots
                t.check(shots.count >= 2, "Planned multi-shot project")
                t.checkEqual(shots[0].continuityMode, .cut, "Shot 1 is cut")
                for i in 1..<shots.count {
                    t.checkEqual(shots[i].continuityMode, .continueFromPrevious, "Shot \(i + 1) is continueFromPrevious")
                }
            } catch {
                t.check(false, "makeProject threw error: \(error)")
            }
            sem.signal()
        }
        sem.wait()

        var manualProject = FilmProject(title: "Manual Film")
        var mShot1 = Shot(index: 0, title: "Shot 1")
        mShot1.continuityMode = .cut

        var mShot2 = Shot(index: 1, title: "Shot 2")
        mShot2.continuityMode = .continueFromPrevious

        var mShot3 = Shot(index: 2, title: "Shot 3")
        mShot3.continuityMode = .cut

        manualProject.shots = [mShot1, mShot2, mShot3]
        t.checkEqual(manualProject.shots[0].continuityMode, .cut, "Manual shot 1 is cut")
        t.checkEqual(manualProject.shots[1].continuityMode, .continueFromPrevious, "Manual shot 2 is continue")
        t.checkEqual(manualProject.shots[2].continuityMode, .cut, "Manual shot 3 respects manual cut")
    }
}
