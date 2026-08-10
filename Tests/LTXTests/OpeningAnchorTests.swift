import Foundation
@testable import LTXVideoGeneratorCore

/// Opening Shot Anchor: the first Auto Movie shot has no frame to inherit, and
/// its final frame is what the whole chain inherits. The one correction made
/// here — removing language that shrinks the protagonist — is the only
/// intervention the calibration supported; composition guidance and dictated
/// ending states were both tested and neither beat it.
func runOpeningAnchorTests(_ t: TestKit) {

    typealias Draft = StoryboardDirector.ShotPlanDraft

    func draft(
        _ title: String = "Shot",
        summary: String,
        scale: String = "wide",
        continuity: String? = "cut"
    ) -> Draft {
        Draft(
            title: title, summary: summary, durationSeconds: 5,
            shotScale: scale, angle: "eye-level", movement: "track",
            lighting: "soft natural lighting", dialogue: [], audioCues: [],
            explicitChanges: [], characterIDs: nil, characterNames: nil,
            continuity: continuity
        )
    }

    let tinyOpening = "Elara walks steadily down the stone path toward the library entrance, her figure small against the towering walls."
    let brief = "a young woman walks toward an old stone library and unlocks the door"

    t.suite("Opening anchor — the measured correction") {
        // M. The opening no longer asks for a tiny protagonist, which is what
        //    produced an unusable anchor frame for the rest of the chain.
        let plan = CapabilityAwareShotPlanner.plan(
            shots: [draft(summary: tinyOpening),
                    draft(summary: "Elara arrives at the doors and stops.",
                          scale: "medium-wide", continuity: "continue")],
            brief: brief
        )
        t.checkEqual(plan.shots[0].summary,
                     "Elara walks steadily down the stone path toward the library entrance.",
                     "M: the miniaturizing clause is dropped from the opening")
        t.check(plan.adjustments[0].appliedOpeningAnchor,
                "M: the adjustment is recorded as an opening anchor")
        t.check(plan.adjustments[0].explanation.contains("opening anchor"),
                "M: the reason names the opening anchor")

        // G. The narrative action survives untouched.
        let lowered = plan.shots[0].summary.lowercased()
        t.check(lowered.contains("walks"), "G: the action survives")
        t.check(lowered.contains("library entrance"), "G: the destination survives")

        // O. Camera scale is never changed by this rule — a wide establishing
        //    shot stays wide, and extreme-wide stays extreme-wide.
        t.checkEqual(plan.shots[0].shotScale, "wide",
                     "O: a wide establishing opening keeps its scale")
        let extremeWide = CapabilityAwareShotPlanner.plan(
            shots: [draft(summary: tinyOpening, scale: "extreme-wide")], brief: brief
        )
        t.checkEqual(extremeWide.shots[0].shotScale, "extreme-wide",
                     "O: an extreme-wide opening keeps its scale")

        // P. Nothing instructs the subject to face the camera, and no ending
        //    state is dictated: both were tested and neither beat plain removal.
        let effective = plan.shots[0].summary.lowercased()
        t.check(!effective.contains("toward the camera"),
                "P: the subject is not turned toward the camera")
        t.check(!effective.contains("facing"), "P: no facing instruction is added")
        t.check(!effective.contains("ends with"), "P: no ending state is dictated")
        t.check(!effective.contains("clearly visible"),
                "P: no composition guidance is added")

        // A. Only the first shot is touched.
        let laterTiny = CapabilityAwareShotPlanner.plan(
            shots: [draft(summary: "Elara steps onto the path."),
                    draft(summary: tinyOpening, scale: "wide", continuity: "continue")],
            brief: brief
        )
        t.checkEqual(laterTiny.shots[1].summary, tinyOpening,
                     "A: a later shot keeps its wording")
        t.check(!laterTiny.adjustments[1].appliedOpeningAnchor,
                "A: the anchor is not recorded for a later shot")

        // N. An opening with no miniaturizing language is left alone entirely.
        let clean = "Elara walks along the colonnade toward the entrance."
        let untouched = CapabilityAwareShotPlanner.plan(
            shots: [draft(summary: clean)], brief: brief
        )
        t.checkEqual(untouched.shots[0].summary, clean,
                     "N: an already-usable opening is unchanged")
        t.check(!untouched.adjustments[0].appliedOpeningAnchor,
                "N: no anchor adjustment is recorded")

        // The rule generalises past the library case it was measured on.
        for (summary, kept) in [
            ("A courier walks toward the parked car, dwarfed by the tower behind him.", "parked car"),
            ("A hiker approaches the shrine, a tiny figure against the mountainside.", "shrine"),
        ] {
            let general = CapabilityAwareShotPlanner.plan(
                shots: [draft(summary: summary)], brief: "someone approaches something"
            )
            t.check(general.shots[0].summary.contains(kept),
                    "the destination survives in: \(kept)")
            t.check(!CapabilityAwareShotPlanner
                .opensWithMiniaturizedSubject(general.shots[0].summary),
                    "the miniaturizing phrase is gone in: \(kept)")
        }
    }

    t.suite("Opening anchor — intent, scope and compatibility") {
        // F/Q. When the brief itself asks for the small-figure look, the user
        //      said it deliberately and it is preserved.
        let userWanted = CapabilityAwareShotPlanner.plan(
            shots: [draft(summary: tinyOpening)],
            brief: "open on a tiny figure against a vast stone library, then she unlocks the door"
        )
        t.checkEqual(userWanted.shots[0].summary, tinyOpening,
                     "F/Q: an explicitly requested small-figure opening is preserved")
        t.check(!userWanted.adjustments[0].appliedOpeningAnchor,
                "F/Q: no anchor adjustment is applied over user intent")

        // H. The rule edits text only, so the cut/continue decision for the
        //    following boundary is untouched.
        func shot(_ index: Int, summary: String) -> Shot {
            var s = Shot(index: index, title: "Shot \(index + 1)", summary: summary)
            s.camera = CameraPlan(shotScale: "wide")
            s.continuityMode = .cut
            var state = ContinuitySnapshot()
            state.location = "library forecourt"
            state.characterOutfit = ["Elara": "grey coat"]
            s.continuityBefore = state
            return s
        }
        let withClause = ContinuityReconciler.reconcile(
            shots: [shot(0, summary: tinyOpening), shot(1, summary: "She reaches the doors.")]
        )
        let withoutClause = ContinuityReconciler.reconcile(
            shots: [shot(0, summary: "Elara walks toward the library entrance."),
                    shot(1, summary: "She reaches the doors.")]
        )
        t.checkEqual(withClause[1].continuityMode, withoutClause[1].continuityMode,
                     "H: removing the clause does not change the continuity decision")

        // I/J. Strengths are untouched by this round.
        t.checkEqual(AutoMovieRunCoordinator.continuityImageStrength, 0.8,
                     "I: standard continuity strength is still 0.8")
        t.checkEqual(AutoMovieRunCoordinator.reframeContinuityImageStrength, 0.5,
                     "J: the reframe fallback is still 0.5")

        // B/C/D/E. Every non-Auto-Movie surface is untouched: they never run
        //          the capability pass at all, and the shared compiler keeps
        //          whatever wording it is handed.
        let compiled = PromptCompiler.compile(plan: OneShotPlan(
            camera: "wide shot, eye-level angle, track camera",
            action: tinyOpening, lighting: "soft light", dialogue: [], audioCues: [],
            durationIntentSeconds: 5
        ))
        t.check(compiled.contains("figure small"),
                "B/C/D: One Shot, Generate and Storyboard keep the planned wording")

        // K. A project saved before this rule existed still decodes.
        let legacy = """
        {"index":0,"title":"Legacy opening","summary":"\(tinyOpening)","durationSeconds":5,
         "camera":{"shotScale":"wide","angle":"eye-level","movement":"track","composition":""},
         "audio":{"dialogue":[],"footsteps":false,"foley":[],"sfx":[],"ambience":""},
         "explicitChanges":[],"characterIDs":[],"compiledPrompt":"old","takes":[]}
        """
        if let data = legacy.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Shot.self, from: data) {
            t.checkEqual(decoded.summary, tinyOpening,
                         "K: an old opening keeps the wording it was saved with")
            t.check(decoded.capabilityAdjustmentReason == nil,
                    "K: an old shot reports no capability adjustment")
        } else {
            t.check(false, "K: a pre-anchor shot still decodes")
        }
    }
}
