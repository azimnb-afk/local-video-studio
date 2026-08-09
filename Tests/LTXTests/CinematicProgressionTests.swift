import Foundation
@testable import LTXVideoGeneratorCore

/// Auto Movie cinematic progression: consecutive shots must advance the action
/// and vary the camera, while continuity keeps the world consistent without
/// pinning the framing. Continuity strength and every non-Auto-Movie surface
/// must be untouched by this work.
func runCinematicProgressionTests(_ t: TestKit) {

    t.suite("Cinematic progression — beat planner") {
        // E. The no-LLM fallback must not emit the same action for every shot.
        let brief = "A young woman walks toward an old stone library."
        let count = 4
        let summaries = (0..<count).map {
            AutoMovieBeatPlanner.beatSummary(brief: brief, index: $0, count: count)
        }
        t.checkEqual(Set(summaries).count, count, "E: every beat has a distinct action")
        t.checkEqual(summaries[0], brief, "opening beat carries the brief for text-to-video")
        t.check(!summaries[1].contains("story beat"), "no numbered restatement of the brief")
        t.check(summaries.last?.contains("final") == true, "closing beat resolves the action")
        // Continuing beats stay short: the inherited frame already carries the scene.
        for summary in summaries.dropFirst() {
            t.check(summary.count < brief.count + 40, "continuing beat stays concise")
            t.check(!summary.contains("stone library"), "continuing beat does not restate the set")
        }

        // Camera follows the beat and varies between consecutive shots.
        let scales = AutoMovieBeatPlanner.shotScales(count: count)
        let movements = AutoMovieBeatPlanner.cameraMovements(count: count)
        t.checkEqual(scales.count, count, "one scale per shot")
        t.checkEqual(movements.count, count, "one movement per shot")
        t.checkEqual(scales.first, "wide", "opening establishes")
        t.checkEqual(scales.last, "close-up", "closing sits closer on the action")
        var adjacentScaleRepeats = 0
        for i in 1..<count where scales[i] == scales[i - 1] { adjacentScaleRepeats += 1 }
        t.checkEqual(adjacentScaleRepeats, 0, "no two consecutive shots share a scale")

        // D. Deliberate stillness is still available.
        let angles = AutoMovieBeatPlanner.cameraAngles(count: count)
        var adjacentAngleRuns = 0
        for i in 2..<count where angles[i] == angles[i - 1] && angles[i - 1] == angles[i - 2] { adjacentAngleRuns += 1 }
        t.checkEqual(adjacentAngleRuns, 0, "no three consecutive shots share an angle")
        t.check(movements.contains("static"), "D: a static camera remains part of the vocabulary")
        t.check(movements.contains { $0 != "static" }, "movement is used where the beat calls for it")

        // A single-shot movie degrades sensibly.
        t.checkEqual(AutoMovieBeatPlanner.shotScales(count: 1), ["medium"], "single shot keeps a neutral scale")
        t.checkEqual(AutoMovieBeatPlanner.beatSummary(brief: brief, index: 0, count: 1), brief,
                     "single shot keeps the brief")
    }

    t.suite("Cinematic progression — repeated action detection") {
        func shot(_ index: Int, _ summary: String, scale: String = "medium",
                  angle: String = "eye-level", movement: String = "static") -> Shot {
            var s = Shot(index: index, title: "S\(index)", summary: summary)
            s.camera = CameraPlan(shotScale: scale, angle: angle, movement: movement)
            return s
        }

        // The exact failure this work fixes: identical action, numbered.
        let repeated = [
            shot(0, "A woman walks toward the library — story beat 1 of 3"),
            shot(1, "A woman walks toward the library — story beat 2 of 3"),
            shot(2, "A woman walks toward the library — story beat 3 of 3"),
        ]
        let repeatWarnings = ContinuityEngine.repeatedActionWarnings(shots: repeated)
        t.check(repeatWarnings.count >= 2, "numbered restatements are flagged as repeated actions")
        t.check(repeatWarnings.allSatisfy { $0.severity == .warning },
                "repetition is a warning, not a hard error")

        // Reworded but same leading verb is still flagged.
        let reworded = [
            shot(0, "A woman walks toward the library"),
            shot(1, "The same woman walks closer to the library"),
        ]
        t.check(!ContinuityEngine.repeatedActionWarnings(shots: reworded).isEmpty,
                "same leading verb across consecutive shots is flagged")

        // A genuinely progressing sequence is clean.
        let progressing = [
            shot(0, "A woman walks toward the library", scale: "wide", movement: "slow push-in"),
            shot(1, "She reaches the entrance", scale: "medium", angle: "low", movement: "tracking"),
            shot(2, "She pulls the door open", scale: "close-up", movement: "static"),
        ]
        t.check(ContinuityEngine.repeatedActionWarnings(shots: progressing).isEmpty,
                "a progressing sequence produces no repetition warnings")
        t.check(ContinuityEngine.monotonyWarnings(shots: progressing).isEmpty,
                "a progressing sequence produces no monotony warnings")

        // The planner's own output must pass its own checker.
        let planned = (0..<4).map { index -> Shot in
            var s = Shot(index: index, title: AutoMovieBeatPlanner.title(index: index, count: 4),
                         summary: AutoMovieBeatPlanner.beatSummary(brief: "A car sits at the roadside.", index: index, count: 4))
            s.camera = CameraPlan(
                shotScale: AutoMovieBeatPlanner.shotScales(count: 4)[index],
                angle: AutoMovieBeatPlanner.cameraAngles(count: 4)[index],
                movement: AutoMovieBeatPlanner.cameraMovements(count: 4)[index]
            )
            return s
        }
        t.check(ContinuityEngine.repeatedActionWarnings(shots: planned).isEmpty,
                "planner output has no repeated actions")
        t.check(ContinuityEngine.monotonyWarnings(shots: planned).isEmpty,
                "planner output has no monotonous camera runs")

        // Normalization helpers behave sensibly.
        t.checkEqual(ContinuityEngine.normalizedAction("A Woman Walks!  — story beat 2 of 3"),
                     "a woman walks", "counter suffix is stripped for comparison")
        t.checkEqual(ContinuityEngine.actionVerb("the same woman reaches the entrance"), "reaches",
                     "leading articles and subject words are skipped")
    }

    t.suite("Cinematic progression — prompt compilation") {
        // B. Distinct camera plans survive compilation into distinct prompts.
        let planA = OneShotPlan(camera: "wide shot, eye-level angle, slow push-in camera",
                                action: "A woman walks toward the library.")
        let planB = OneShotPlan(camera: "close-up shot, eye-level angle, static camera",
                                action: "She pulls the door open.")
        let a = PromptCompiler.compile(plan: planA)
        let b = PromptCompiler.compile(plan: planB)
        t.check(a != b, "B: different shots compile to different prompts")
        t.check(a.contains("wide") && a.contains("push-in"), "B: opening camera plan survives compilation")
        t.check(b.contains("close-up"), "B: closing camera plan survives compilation")

        // C. The action text survives compilation.
        t.check(a.contains("walks toward the library"), "C: shot action survives compilation")
        t.check(b.contains("pulls the door open"), "C: progressed action survives compilation")

        // D. An explicitly requested static camera is preserved, not rewritten.
        t.check(b.contains("static"), "D: an intentional static camera is preserved")

        // A. Continuity context describes the world, never the framing.
        var state = ContinuitySnapshot()
        state.location = "old stone library entrance"
        state.timeOfDay = "late afternoon"
        state.lighting = "warm low sun"
        let context = ContinuityEngine.promptContext(for: state)
        t.check(context.contains("old stone library entrance"), "A: continuity keeps the location")
        t.check(context.contains("warm low sun"), "A: continuity keeps the lighting")
        let framingLockPhrases = [
            "same composition", "same framing", "identical framing",
            "maintain the same", "exactly the same", "same camera position",
        ]
        for phrase in framingLockPhrases {
            t.check(!context.lowercased().contains(phrase),
                    "A: continuity text does not lock framing ('\(phrase)')")
        }
    }

    t.suite("Cinematic progression — director instructions") {
        let prompt = StoryboardDirector.storyboardSystemPrompt
        t.check(prompt.contains("NEW visible state"), "director must require a new visible state per shot")
        t.check(prompt.lowercased().contains("never restate"), "director must forbid restating the previous action")
        t.check(prompt.lowercased().contains("do not keep the same framing")
                || prompt.lowercased().contains("not keep the same framing"),
                "director separates world continuity from framing")
        t.check(prompt.lowercased().contains("static camera is correct"),
                "director keeps a static camera valid when the beat calls for it")
        t.check(prompt.lowercased().contains("outside to inside"),
                "director prefers a cut for a genuine scene change")
        // The continuity rule from the previous phase must survive.
        t.check(prompt.lowercased().contains("do not mark every shot"),
                "director is told not to cut everything, so continuity can engage")
        t.check(prompt.contains("shot 2 \"continue\""),
                "director has a worked example showing a continuation")
        t.check(prompt.contains("When unsure, use \"cut\""), "conservative cut rule retained")
        t.check(prompt.contains("The first shot is always \"cut\""), "first shot still cuts")
    }

    t.suite("Cinematic progression — unrelated behaviour unchanged") {
        // G. Continuity strength is untouched by this work.
        t.checkEqual(AutoMovieRunCoordinator.continuityImageStrength, 0.8,
                     "G: inherited continuity frames still use the calibrated 0.8")
        // H/I/J. Every explicit/manual surface keeps exact-first-frame behaviour.
        t.checkEqual(GenerationParameters.default.imageStrength, 1.0,
                     "H/I/J: explicit and manual image paths keep strength 1.0")

        // J. A storyboard shot's own camera plan is never rewritten by the
        // Auto Movie planner: the planner is a pure function used only by the
        // Auto Movie split path.
        var manual = Shot(index: 1, title: "User shot", summary: "She waits by the window.")
        manual.camera = CameraPlan(shotScale: "medium", angle: "low", movement: "static")
        let compiled = PromptCompiler.compile(plan: OneShotPlan(
            camera: "\(manual.camera.shotScale) shot, \(manual.camera.angle) angle, \(manual.camera.movement) camera",
            action: manual.summary
        ))
        t.check(compiled.contains("medium") && compiled.contains("low") && compiled.contains("static"),
                "J: a user's own camera plan compiles unchanged")
        t.check(compiled.contains("waits by the window"), "J: a user's own action compiles unchanged")
    }
}
