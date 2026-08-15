import Foundation
@testable import LTXVideoGeneratorCore

func runCharacterContinuitySafetyTests(_ t: TestKit) {
    t.suite("Character Continuity Safety Tests") {

        // MARK: - Section 22: Face Absence Avoidance Guidance
        let structuredPrompt = StoryboardDirector.storyboardSystemPrompt
        t.check(structuredPrompt.contains("CHARACTER CONTINUITY SAFETY"), "Structured prompt contains safety header")
        t.check(structuredPrompt.contains("avoid prolonged face absence"), "Structured prompt guides against prolonged face absence")
        t.check(structuredPrompt.contains("split the shot BEFORE identity information is lost"), "Structured prompt instructs shot splitting before identity loss")

        let textSystem = DirectorPlanFormat.systemPrompt(for: .textProtocol, characterBible: CharacterBible())
        t.check(textSystem.contains("CHARACTER CONTINUITY SAFETY"), "Text Protocol system prompt contains safety guidance")
        t.check(textSystem.contains("avoid prolonged face absence"), "Text Protocol guides against prolonged face absence")

        let textTemplate = DirectorPlanFormat.textProtocolTemplate
        t.check(textTemplate.contains("CHARACTER CONTINUITY SAFETY"), "Text Protocol template contains safety guidance")
        t.check(textTemplate.contains("split shots before characters leave or disappear"), "Text Protocol template includes shot split directive")

        // MARK: - Section 23: Gradual Camera Change Guidance
        let instruction = CharacterContinuitySafetyPolicy.directorInstruction
        t.check(instruction.contains("Use gradual camera reframing"), "Instructs gradual camera reframing")
        t.check(instruction.contains("rather than extreme abrupt jumps"), "Warns against extreme abrupt jumps")

        let scales3 = AutoMovieBeatPlanner.shotScales(count: 3)
        t.checkEqual(scales3, ["wide", "medium", "close-up"], "3-beat movie uses gradual ladder progression")

        let scales4 = AutoMovieBeatPlanner.shotScales(count: 4)
        t.checkEqual(scales4, ["wide", "medium", "medium-close-up", "close-up"], "4-beat movie steps smoothly without extreme leaps")

        // MARK: - Section 24: User Intent Override
        let explicitBack = "Show only her back for the entire shot."
        t.check(CharacterContinuitySafetyPolicy.isExplicitUserIntentOverride(in: explicitBack), "Detects explicit back view intent")

        let explicitBehind = "A mysterious figure seen from behind only walking into fog."
        t.check(CharacterContinuitySafetyPolicy.isExplicitUserIntentOverride(in: explicitBehind), "Detects 'from behind only' intent")

        let explicitSilhouette = "A dancer in complete silhouette against the sunset."
        t.check(CharacterContinuitySafetyPolicy.isExplicitUserIntentOverride(in: explicitSilhouette), "Detects 'silhouette' intent")

        let explicitJapanese = "主人公の後ろ姿のみを映し続ける"
        t.check(CharacterContinuitySafetyPolicy.isExplicitUserIntentOverride(in: explicitJapanese), "Detects Japanese back-view intent")

        let normalBrief = "A woman walks down a corridor, turns to face the camera and smiles."
        t.check(!CharacterContinuitySafetyPolicy.isExplicitUserIntentOverride(in: normalBrief), "Normal face-forward action is not an override")

        // MARK: - Section 25: Identity Text Persistence without Prompt Inflation
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

        // MARK: - Section 26: Fallback Semantic Parity
        let structured = StoryboardDirector.storyboardSystemPrompt
        t.check(structured.contains("Keep face and identity evidence"), "Structured has face evidence guidance")

        let textSystem2 = DirectorPlanFormat.systemPrompt(for: .textProtocol, characterBible: CharacterBible())
        t.check(textSystem2.contains("Keep face/hair/costume visible"), "Text Protocol has face evidence guidance")

        let beatSummary = AutoMovieBeatPlanner.beatSummary(
            brief: "A detective inspects a vintage car",
            index: 1,
            count: 3
        )
        t.check(!beatSummary.isEmpty, "Beat planner produces active continuation without empty absence")
        t.check(!beatSummary.lowercased().contains("leaves the frame"), "Beat planner does not invent character departure")

        // MARK: - Section 27: Auto Movie Strict Sequential Continuity Regression
        let coordinator = HybridProjectCoordinator()
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

        // MARK: - Section 28: Storyboard Manual Workflow Regression
        var project = FilmProject(title: "Manual Film")
        var shot1 = Shot(index: 0, title: "Shot 1")
        shot1.continuityMode = .cut

        var shot2 = Shot(index: 1, title: "Shot 2")
        shot2.continuityMode = .continueFromPrevious

        var shot3 = Shot(index: 2, title: "Shot 3")
        shot3.continuityMode = .cut

        project.shots = [shot1, shot2, shot3]
        t.checkEqual(project.shots[0].continuityMode, .cut, "Manual shot 1 is cut")
        t.checkEqual(project.shots[1].continuityMode, .continueFromPrevious, "Manual shot 2 is continue")
        t.checkEqual(project.shots[2].continuityMode, .cut, "Manual shot 3 respects manual cut")
    }
}
