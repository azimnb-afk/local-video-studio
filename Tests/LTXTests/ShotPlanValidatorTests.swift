import Foundation
@testable import LTXVideoGeneratorCore

/// Auto Movie V2 — structural repair (splitting an overloaded shot draft)
/// and the deterministic post-plan validator. Both are advisory/best-effort:
/// neither blocks generation, and the repair runs at most once per plan.
func runShotPlanValidatorTests(_ t: TestKit) {

    t.suite("Director structural repair — overloaded shot split") {
        // A. A shot naming four or more clause-separated actions is split
        // into two shots at its middle clause boundary.
        let busyDraft = StoryboardDirector.StoryboardDraft(
            logline: "Test",
            shots: [
                StoryboardDirector.ShotPlanDraft(
                    title: "Busy",
                    summary: "She grabs her keys, opens the door, steps outside, and locks it behind her.",
                    durationSeconds: 8, continuity: "cut"
                ),
            ]
        )
        let repaired = StoryboardDirector.repairOverloadedShots(busyDraft).draft
        t.checkEqual(repaired.shots.count, 2, "A: an overloaded shot becomes two shots")
        t.check(repaired.shots[0].summary.contains("grabs her keys"), "A: first half opens the arc")
        t.check(repaired.shots[1].summary.contains("locks it"), "A: second half resolves the arc")
        t.checkEqual(repaired.shots[1].continuity, "continue", "A: the second half is always Continue")
        t.checkEqual(repaired.shots[0].continuity, "cut", "A: the first half keeps the original continuity")
        let totalDuration = (repaired.shots[0].durationSeconds ?? 0) + (repaired.shots[1].durationSeconds ?? 0)
        t.check(abs(totalDuration - 8) < 0.01, "A: split halves still sum to the original duration")

        // B. A simple, single-clause shot is left completely alone.
        let simpleDraft = StoryboardDirector.StoryboardDraft(
            logline: "Test",
            shots: [
                StoryboardDirector.ShotPlanDraft(title: "Calm", summary: "She smiles.", durationSeconds: 5),
            ]
        )
        let untouched = StoryboardDirector.repairOverloadedShots(simpleDraft).draft
        t.checkEqual(untouched.shots.count, 1, "B: a simple shot is not split")
        t.checkEqual(untouched.shots[0].summary, "She smiles.", "B: an unaffected shot is byte-for-byte unchanged")
    }

    t.suite("ShotPlanValidator — deterministic checks") {
        func shot(
            summary: String = "Something happens.",
            durationSeconds: Double = 5,
            movement: String = "static",
            shotScale: String = "medium",
            continuityMode: ShotContinuityMode? = .continueFromPrevious,
            endStateSummary: String? = nil,
            dialogue: [ShotDialogueLine] = [],
            title: String = "Shot"
        ) -> Shot {
            var s = Shot(index: 0, title: title, summary: summary, durationSeconds: durationSeconds)
            s.camera = CameraPlan(shotScale: shotScale, angle: "eye-level", movement: movement)
            s.continuityMode = continuityMode
            s.endStateSummary = endStateSummary
            s.audio = AudioPlan(dialogue: dialogue, sfx: [])
            return s
        }

        // C. Four or more actions in one shot is flagged.
        let overloaded = shot(summary: "She grabs her keys, opens the door, steps outside, and locks it behind her.")
        let overloadViolations = ShotPlanValidator.validate(shots: [overloaded], brief: "")
        t.check(overloadViolations.contains { $0.message.contains("separate actions") },
                "C: an overloaded shot is flagged")

        // D. A simple shot produces no action-overload finding.
        let simple = shot(summary: "She smiles.")
        t.check(!ShotPlanValidator.validate(shots: [simple], brief: "")
                    .contains { $0.message.contains("separate actions") },
                "D: a simple shot is not flagged for overload")

        // E. A static camera combined with a showy move in the same
        // instruction is a contradiction.
        let contradictory = shot(movement: "static camera that suddenly does a rapid crane move")
        t.check(ShotPlanValidator.validate(shots: [contradictory], brief: "")
                    .contains { $0.message.contains("static/locked") },
                "E: a static+showy-move camera instruction is flagged")

        // F. A locked camera with an ordinary move is not flagged.
        let plainCamera = shot(movement: "static")
        t.check(!ShotPlanValidator.validate(shots: [plainCamera], brief: "")
                    .contains { $0.message.contains("static/locked") },
                "F: an ordinary static camera is not flagged")

        // G. Dialogue in a shot under three seconds is flagged.
        let rushedDialogue = shot(
            durationSeconds: 2,
            dialogue: [ShotDialogueLine(speaker: "A", text: "Wait for me!")]
        )
        t.check(ShotPlanValidator.validate(shots: [rushedDialogue], brief: "")
                    .contains { $0.message.contains("short for a shot with spoken dialogue") },
                "G: dialogue with too little time is flagged")

        // H. The same dialogue with enough duration is not flagged.
        let comfortableDialogue = shot(
            durationSeconds: 6,
            dialogue: [ShotDialogueLine(speaker: "A", text: "Wait for me!")]
        )
        t.check(!ShotPlanValidator.validate(shots: [comfortableDialogue], brief: "")
                    .contains { $0.message.contains("short for a shot with spoken dialogue") },
                "H: dialogue with sufficient duration is not flagged")

        // I. An unrecognized shot scale is flagged; a recognized one is not.
        let badScale = shot(shotScale: "dramatic-hero-shot")
        t.check(ShotPlanValidator.validate(shots: [badScale], brief: "")
                    .contains { $0.message.contains("not a recognized framing") },
                "I: an unrecognized shot scale is flagged")
        t.check(!ShotPlanValidator.validate(shots: [shot(shotScale: "medium-close-up")], brief: "")
                    .contains { $0.message.contains("not a recognized framing") },
                "I: a recognized shot scale is not flagged")

        // J. A Continue shot whose text describes arriving somewhere new is
        // flagged; the same text on a Cut shot is not.
        let missingCut = shot(summary: "She arrives at the old library.", continuityMode: .continueFromPrevious)
        t.check(ShotPlanValidator.validate(shots: [missingCut], brief: "")
                    .contains { $0.message.contains("usually calls for Cut") },
                "J: Continue with a location-change cue is flagged")
        let correctlyCut = shot(summary: "She arrives at the old library.", continuityMode: .cut)
        t.check(!ShotPlanValidator.validate(shots: [correctlyCut], brief: "")
                    .contains { $0.message.contains("usually calls for Cut") },
                "J: the same text marked Cut is not flagged")

        // K. A leaked protocol marker in visible text is flagged as an error.
        let contaminated = shot(title: "LOGLINE: stray marker")
        let contaminationViolations = ShotPlanValidator.validate(shots: [contaminated], brief: "")
        t.check(contaminationViolations.contains {
            $0.message.contains("unparsed protocol marker") && $0.severity == .error
        }, "K: a leaked protocol marker is flagged as an error")

        // L. An explicit brief dialogue line never placed in any shot is
        // flagged; the same line placed in a shot is not.
        let briefWithExplicitLine = "The teacher says \"Please open your books.\""
        let noDialogueShot = shot()
        t.check(ShotPlanValidator.validate(shots: [noDialogueShot], brief: briefWithExplicitLine)
                    .contains { $0.message.contains("was not placed in any shot") },
                "L: an unplaced explicit dialogue line is flagged")
        let placedDialogueShot = shot(
            dialogue: [ShotDialogueLine(speaker: "Teacher", text: "Please open your books.")]
        )
        t.check(!ShotPlanValidator.validate(shots: [placedDialogueShot], brief: briefWithExplicitLine)
                    .contains { $0.message.contains("was not placed in any shot") },
                "L: the same line placed in a shot is not flagged")
    }

    t.suite("End state — Scene IR field reaches the compiled prompt") {
        // M. A shot with an ending state renders it as a closing sentence.
        let plan = OneShotPlan(
            camera: "medium shot", action: "She walks to the window.",
            endState: "standing still, looking out at the rain"
        )
        let compiled = PromptCompiler.compile(plan: plan)
        t.check(compiled.contains("By the end of the shot: standing still, looking out at the rain"),
                "M: endState becomes an explicit closing sentence")

        // N. A shot with no ending state adds no such sentence.
        let noEndState = OneShotPlan(camera: "medium shot", action: "She walks to the window.")
        t.check(!PromptCompiler.compile(plan: noEndState).contains("By the end of the shot"),
                "N: absent endState adds nothing — never a fabricated default")

        // O. endStateSummary survives a Shot Codable round-trip (persisted
        // projects must not silently lose Quality V1 planning metadata).
        var original = Shot(index: 0, title: "T", summary: "S")
        original.endStateSummary = "she has come to a stop"
        original.shotPurpose = .performance
        original.actionBeatCount = 2
        let data = try? JSONEncoder().encode(original)
        let decoded = data.flatMap { try? JSONDecoder().decode(Shot.self, from: $0) }
        t.checkEqual(decoded?.endStateSummary, original.endStateSummary, "O: endStateSummary round-trips")
        t.checkEqual(decoded?.shotPurpose, original.shotPurpose, "O: shotPurpose round-trips")
        t.checkEqual(decoded?.actionBeatCount, original.actionBeatCount, "O: actionBeatCount round-trips")
    }

    t.suite("ShotOutcomeEvaluator — deferred (P2) parser, interface only") {
        // P. A well-formed response decodes into a real verdict.
        let id = UUID()
        let good = ShotOutcomeEvaluator.verdict(
            fromResponse: #"{"subjectPresent":true,"majorCorruption":false,"actionPlausible":true,"endStateMatch":"match"}"#,
            shotID: id, model: "test-model"
        )
        t.checkEqual(good.status, .assessed, "P: a well-formed response is assessed")
        t.checkEqual(good.endStateMatch, .match, "P: endStateMatch decodes")
        t.check(!good.suggestsRetry, "P: a clean verdict never suggests a retry")

        // Q. Garbage input fails closed rather than guessing a verdict.
        let bad = ShotOutcomeEvaluator.verdict(fromResponse: "not json", shotID: id, model: "test-model")
        t.checkEqual(bad.status, .failed, "Q: unparseable text yields .failed, not a guessed verdict")
        t.check(!bad.suggestsRetry, "Q: a failed assessment never itself triggers a retry")

        // R. Corruption is the one signal this deliberately narrow interface flags.
        let corrupted = ShotOutcomeEvaluator.verdict(
            fromResponse: #"{"subjectPresent":true,"majorCorruption":true,"actionPlausible":false,"endStateMatch":"mismatch"}"#,
            shotID: id, model: "test-model"
        )
        t.check(corrupted.suggestsRetry, "R: visible corruption suggests a retry")
    }
}
