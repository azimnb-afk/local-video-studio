import Foundation
@testable import LTXVideoGeneratorCore

func runContinuationPromptPolicyTests(_ t: TestKit) {

    func state(
        _ id: UUID, name: String = "Character1",
        costume: String, accessories: String = "", notes: String = ""
    ) -> ContinuityEngine.ResolvedCharacterState {
        var appearance = CharacterAppearance()
        appearance.hair = "brown ponytail"
        return ContinuityEngine.ResolvedCharacterState(
            id: id, name: name, appearance: appearance,
            currentCostume: costume, accessories: accessories,
            continuityNotes: notes, lockedTraits: []
        )
    }

    t.suite("Continuation prompt policy — style selection") {
        t.checkEqual(ContinuationPromptPolicy.style(for: .continueFromPrevious), .changeFocused,
                     "a CONTINUE shot starts from a real frame, so it describes the change")
        t.checkEqual(ContinuationPromptPolicy.style(for: .cut), .descriptive,
                     "a CUT has no source frame and still describes the character")
        t.checkEqual(ContinuationPromptPolicy.style(for: .auto), .descriptive,
                     "auto stays descriptive: it may resolve to a cut at generation time")
        t.checkEqual(ContinuationPromptPolicy.style(for: nil), .descriptive,
                     "an unset mode stays descriptive")
    }

    t.suite("Continuation prompt policy — unchanged appearance is not restated") {
        let id = UUID()
        let before = [state(id, costume: "navy sailor vest, cream cape")]
        let after = [state(id, costume: "navy sailor vest, cream cape")]
        let context = ContinuationPromptPolicy.changeFocusedContext(before: before, after: after)

        t.checkEqual(
            context,
            "\(ContinuationPromptPolicy.continuityStatement) \(ContinuationPromptPolicy.unchangedAppearanceStatement)",
            "D-071: an unchanged character contributes only the continuity statement plus the generic " +
            "unchanged-appearance anchor — never a restatement of specific costume text"
        )
        t.check(!context.lowercased().contains("navy"),
                "the costume the frame already shows is not restated")
        t.check(!context.contains("Current costume:"),
                "the appearance-reconstruction block is gone")
        t.check(!context.lowercased().contains("ponytail"),
                "hair visible in the frame is not restated")

        // The statement must not overclaim.
        for banned in ["face lock", "identity lock", "guaranteed"] {
            t.check(!context.lowercased().contains(banned),
                    "the continuity statement makes no '\(banned)' claim")
        }
    }

    t.suite("Continuation prompt policy — real changes still get described") {
        let id = UUID()
        let before = [state(id, costume: "navy sailor vest, cream cape")]
        let after = [state(id, costume: "beige trench coat")]
        let context = ContinuationPromptPolicy.changeFocusedContext(before: before, after: after)
        t.check(context.lowercased().contains("beige trench coat"),
                "an explicit wardrobe change is still described")
        t.check(context.contains("now wears"),
                "and is phrased as a change rather than a restatement")
        t.check(context.hasPrefix(ContinuationPromptPolicy.continuityStatement),
                "the continuity statement still leads")

        let accessories = ContinuationPromptPolicy.changeFocusedContext(
            before: [state(id, costume: "same", accessories: "")],
            after: [state(id, costume: "same", accessories: "a leather satchel")])
        t.check(accessories.lowercased().contains("leather satchel"),
                "a newly acquired accessory is described")

        let notes = ContinuationPromptPolicy.changeFocusedContext(
            before: [state(id, costume: "same", notes: "")],
            after: [state(id, costume: "same", notes: "her sleeve is torn")])
        t.check(notes.lowercased().contains("sleeve is torn"),
                "a state change such as damage is described")
    }

    t.suite("Continuation prompt policy — edge cases") {
        let id = UUID()
        t.checkEqual(ContinuationPromptPolicy.changeFocusedContext(before: [], after: []), "",
                     "a shot with no characters contributes no context")

        // A character appearing for the first time in a continuation has no
        // prior state; grounding it once is better than saying nothing.
        let fresh = ContinuationPromptPolicy.changeFocusedContext(
            before: [], after: [state(id, costume: "navy vest")])
        t.check(fresh.lowercased().contains("navy vest"),
                "a character with no prior state is described once")

        // Clearing a value must not be read as a change to empty.
        let cleared = ContinuationPromptPolicy.changeFocusedContext(
            before: [state(id, costume: "navy vest")],
            after: [state(id, costume: "")])
        t.checkEqual(
            cleared,
            "\(ContinuationPromptPolicy.continuityStatement) \(ContinuationPromptPolicy.unchangedAppearanceStatement)",
            "an emptied costume is treated as unknown, not as a change to nothing"
        )
    }

    t.suite("Continuation prompt policy — end to end through the compiler") {
        // A project shaped like the failing run: correct opening image, a
        // Director placeholder costume, and a continuation shot.
        var project = FilmProject(title: "CB")
        var character = BibleCharacter(name: "Character1")
        character.defaultCostume = "Beige trench coat, dark jeans, boots"
        project.characterBible.characters = [character]

        var cut = Shot(index: 0, title: "Open", summary: "She stands in the courtyard.")
        cut.continuityMode = .cut
        cut.characterIDs = [character.id]
        cut.baseCompiledPrompt = "A wide shot of the courtyard."

        var continuation = Shot(index: 1, title: "Closer", summary: "She looks back.")
        continuation.continuityMode = .continueFromPrevious
        continuation.characterIDs = [character.id]
        continuation.baseCompiledPrompt = "The camera moves closer as she looks back."

        project.shots = [cut, continuation]
        CharacterPromptPipeline.recompile(project: &project)

        let cutPrompt = project.shots[0].compiledPrompt
        let continuePrompt = project.shots[1].compiledPrompt

        t.check(cutPrompt.contains("Current costume:"),
                "CUT keeps the existing descriptive policy unchanged")
        t.check(!continuePrompt.contains("Current costume:"),
                "D-071: the CONTINUE prompt no longer carries a costume reconstruction")
        t.check(!continuePrompt.lowercased().contains("beige trench"),
                "D-071: the contradictory costume is absent from the CONTINUE prompt")
        t.check(continuePrompt.contains(ContinuationPromptPolicy.continuityStatement),
                "the CONTINUE prompt carries the compact continuity statement")
        t.check(continuePrompt.contains("The camera moves closer as she looks back."),
                "the camera and action delta survive untouched")
        t.check(cutPrompt.contains("A wide shot of the courtyard."),
                "the CUT prompt keeps its own base text")
    }

    t.suite("Continuation prompt policy — the Temporal Bridge is not affected") {
        // The bridge is not a shot and never passes through this pipeline; the
        // policy is reachable only from a Shot's continuity mode. Recorded
        // because applying continue-semantics to the bridge preserved the
        // character sheet as a physical panel in the scene (D-073).
        t.checkEqual(ContinuationPromptPolicy.style(for: .cut), .descriptive,
                     "bridge-style transformation work is never change-focused")
        t.check(ContinuationPromptPolicy.continuityStatement.contains("continue from the input frame"),
                "the continuity statement is explicitly about continuing, not transforming")
    }
}
