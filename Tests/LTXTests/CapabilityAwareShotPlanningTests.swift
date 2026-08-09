import Foundation
@testable import LTXVideoGeneratorCore

/// Capability-Aware Shot Planning: Auto Movie steers a plan toward shots the
/// local profile actually renders, before anything is generated. The narrative
/// beat always survives; only how it is shown may change.
func runCapabilityAwarePlanningTests(_ t: TestKit) {

    typealias Draft = StoryboardDirector.ShotPlanDraft

    func draft(
        _ title: String = "Shot",
        summary: String = "She walks toward the door.",
        scale: String = "medium",
        angle: String = "eye-level",
        movement: String = "static",
        continuity: String? = "continue",
        explicitChanges: [String] = []
    ) -> Draft {
        Draft(
            title: title, summary: summary, durationSeconds: 5,
            shotScale: scale, angle: angle, movement: movement,
            lighting: "soft natural lighting", dialogue: [], audioCues: [],
            explicitChanges: explicitChanges, characterIDs: nil, characterNames: nil,
            continuity: continuity
        )
    }

    /// Runs the pass over a plan and returns the effective scales.
    func scales(_ drafts: [Draft], brief: String = "a short scene") -> [String] {
        CapabilityAwareShotPlanner.plan(shots: drafts, brief: brief)
            .shots.map { $0.shotScale ?? "" }
    }

    t.suite("Capability-aware planning — risk classification") {
        // A. A large reframe into a detail insert, with fine object action.
        let a = CapabilityAwareShotPlanner.risks(
            previous: draft(scale: "medium-wide"),
            current: draft(summary: "Her fingers insert the key into the tiny lock.",
                           scale: "extreme-close-up"),
            mayInherit: true
        )
        t.check(!a.isEmpty, "A: medium-wide → extreme-close-up with fine object action is high risk")
        t.check(a.contains { $0.contains("reframe") }, "A: the reframe is named as a reason")
        t.check(a.contains { $0.hasPrefix("detail-insert") }, "A: the detail framing is named")
        t.check(a.contains { $0.hasPrefix("fine ") }, "A: the fine manipulation is named")

        // B. A one-rung step is fine.
        t.check(CapabilityAwareShotPlanner.risks(
            previous: draft(scale: "wide"),
            current: draft(scale: "medium-wide"), mayInherit: true
        ).isEmpty, "B: wide → medium-wide is supported")

        // C. So is a normal tightening.
        t.check(CapabilityAwareShotPlanner.risks(
            previous: draft(scale: "medium"),
            current: draft(scale: "medium-close-up"), mayInherit: true
        ).isEmpty, "C: medium → medium-close-up is supported")

        // D. Angle alone changes nothing about how much of the subject fills
        //    the frame, so it is never a capability problem.
        t.check(CapabilityAwareShotPlanner.risks(
            previous: draft(scale: "medium", angle: "eye-level"),
            current: draft(scale: "medium", angle: "low"), mayInherit: true
        ).isEmpty, "D: an angle change alone is supported")

        // E. Neither is movement.
        t.check(CapabilityAwareShotPlanner.risks(
            previous: draft(scale: "medium", movement: "static"),
            current: draft(scale: "medium", movement: "handheld"), mayInherit: true
        ).isEmpty, "E: a movement change alone is supported")

        // A two-rung jump is deliberately still allowed: the point is to stay
        // below the reframe threshold, not to freeze the camera.
        t.check(CapabilityAwareShotPlanner.risks(
            previous: draft(scale: "wide"),
            current: draft(scale: "medium"), mayInherit: true
        ).isEmpty, "two rungs stays supported")

        // Close-ups are not banned. A close-up reached from a medium shot is a
        // two-rung step and stays exactly as the Director planned it.
        t.checkEqual(
            scales([draft(scale: "medium-close-up"),
                    draft(summary: "Her expression changes.", scale: "close-up")]),
            ["medium-close-up", "close-up"],
            "a face close-up after a medium-close-up is left alone"
        )
    }

    t.suite("Capability-aware planning — safer effective plan") {
        // F. A high-risk detail insert is planned at a framing that renders.
        let plan = CapabilityAwareShotPlanner.plan(
            shots: [
                draft(summary: "She reaches the door.", scale: "medium-wide"),
                draft(summary: "Extreme close-up of the key entering the tiny lock.",
                      scale: "extreme-close-up"),
            ],
            brief: "a woman reaches a door and unlocks it"
        )
        let effective = plan.shots[1]
        t.checkEqual(effective.shotScale, "medium-close-up",
                     "F: the detail insert is planned at medium-close-up instead")
        t.check(ShotScaleLadder.rank(of: effective.shotScale ?? "")!
                - ShotScaleLadder.rank(of: "medium-wide")!
                <= CapabilityAwareShotPlanner.maxInheritedRankJump,
                "F: the effective framing is within one capability step of the inherited frame")

        // G. The narrative action survives: the key and the lock are still there.
        let lowered = effective.summary.lowercased()
        t.check(lowered.contains("key"), "G: the key survives the rewrite")
        t.check(lowered.contains("lock"), "G: the lock survives the rewrite")
        t.check(!lowered.contains("extreme close-up"),
                "G: the macro framing request is dropped from the action text")
        t.check(!lowered.contains("tiny"), "G: the miniaturizing qualifier is dropped")
        t.check(effective.summary.contains("body scale"),
                "G: the action is asked for at a visible scale")

        // The record explains what happened and why.
        let adjustment = plan.adjustments[1]
        t.checkEqual(adjustment.risk, .highRisk, "F: the shot is recorded as high risk")
        t.checkEqual(adjustment.originalScale, "extreme-close-up",
                     "F: the Director's original framing is kept in the record")
        t.check(adjustment.explanation.contains("extreme-close-up → medium-close-up"),
                "F: the explanation names both plans")

        // H. An explicit scene transition is left alone, and its framing is not
        //    clamped: nothing is inherited across a cut.
        let transition = CapabilityAwareShotPlanner.plan(
            shots: [
                draft(summary: "She steps through the doorway of the old library.",
                      scale: "close-up"),
                draft(summary: "Interior of the reading room, seen from the entrance.",
                      scale: "extreme-wide", continuity: "cut",
                      explicitChanges: ["location=library interior"]),
            ],
            brief: "a woman enters a library"
        )
        t.checkEqual(transition.shots[1].shotScale, "extreme-wide",
                     "H: an establishing shot after an explicit scene change keeps its framing")
        t.checkEqual(transition.adjustments[1].risk, .normal,
                     "H: a real cut is not a capability problem")
        t.check(!CapabilityAwareShotPlanner.mayInheritFrame(
            previous: draft(summary: "She waits outside in the courtyard."),
            current: draft(summary: "Interior of the hallway.", continuity: "cut")
        ), "H: crossing a threshold is treated as a genuine cut")
    }

    t.suite("Capability-aware planning — fine actions stay generic") {
        // I. Inserting something into something small becomes a visible action.
        let keyPlan = CapabilityAwareShotPlanner.plan(
            shots: [draft(summary: "His hand inserts the key into the narrow lock.",
                          scale: "extreme-close-up", continuity: "cut")],
            brief: "someone opens a gate"
        )
        t.checkEqual(keyPlan.shots[0].shotScale, "medium-close-up",
                     "I: the insert is planned at a renderable framing")
        t.check(keyPlan.shots[0].summary.lowercased().contains("key"),
                "I: the unlock beat survives")

        // J. The same mechanism, with no shared words, on a different action.
        let buttonPlan = CapabilityAwareShotPlanner.plan(
            shots: [draft(summary: "Her fingertip presses the tiny switch on the panel.",
                          scale: "extreme-close-up", continuity: "cut")],
            brief: "an engineer starts a machine"
        )
        t.checkEqual(buttonPlan.shots[0].shotScale, "medium-close-up",
                     "J: a different fine action is handled by the same rule")
        t.check(buttonPlan.shots[0].summary.lowercased().contains("switch"),
                "J: the activation beat survives")
        t.check(!buttonPlan.shots[0].summary.lowercased().contains("tiny"),
                "J: the miniaturizer is dropped here too")

        // The rule is about manipulation, not about the verb: a subject who
        // "presses on" through a forest is walking, not operating anything.
        t.check(!CapabilityAwareShotPlanner.describesFineManipulation(
            "She presses on along the forest path toward the shrine."
        ), "a movement verb without a hand or a small object is not fine manipulation")
        t.check(CapabilityAwareShotPlanner.describesFineManipulation(
            "He threads the delicate wire through the loop with his thumb."
        ), "an unrelated fine action is still detected")

        // Too many beats in one short shot keeps the frame wide enough to
        // show them, and never deletes any of them.
        let busy = draft(
            summary: "She approaches the car, stops, takes out the keys, opens the door, and gets inside.",
            scale: "close-up"
        )
        t.check(CapabilityAwareShotPlanner.visibleBeatCount(in: busy.summary) >= 4,
                "a five-action chain is counted as too many beats")
        let busyPlan = CapabilityAwareShotPlanner.plan(
            shots: [draft(scale: "medium-wide"), busy], brief: "a person gets into a car"
        )
        t.checkEqual(busyPlan.shots[1].shotScale, "medium",
                     "a crowded shot is not framed tighter than medium")
        t.check(busyPlan.shots[1].summary.contains("takes out the keys"),
                "no action is deleted from a crowded shot")
        t.check(busyPlan.shots[1].summary.contains("one continuous action"),
                "a crowded shot is asked for as one continuous action")
    }

    t.suite("Capability-aware planning — explicit user intent") {
        // A framing the user asked for themselves is left alone, and recorded.
        let userPlan = CapabilityAwareShotPlanner.plan(
            shots: [draft(scale: "medium-wide"),
                    draft(summary: "The key enters the lock.", scale: "extreme-close-up")],
            brief: "a woman unlocks a door, ending on an extreme close-up of the lock"
        )
        t.checkEqual(userPlan.shots[1].shotScale, "extreme-close-up",
                     "an explicitly requested extreme close-up is not rewritten")
        t.checkEqual(userPlan.shots[1].summary, "The key enters the lock.",
                     "the action text of a user-requested framing is untouched")
        t.checkEqual(userPlan.adjustments[1].risk, .highRisk,
                     "the shot is still recorded as high risk")
        t.check(userPlan.adjustments[1].honoursExplicitUserFraming,
                "the record says the framing came from the user")
        t.check(CapabilityAwareShotPlanner.briefRequestsTightFraming("マクロで鍵を映す"),
                "an explicit Japanese framing request is recognised")
        t.check(!CapabilityAwareShotPlanner.briefRequestsTightFraming(
            "a woman walks to a library and unlocks the door"
        ), "an ordinary brief is not read as a framing request")
    }

    t.suite("Capability-aware planning — shared ladder and policy agreement") {
        // The two passes must not disagree about what a large reframe is.
        t.checkEqual(CapabilityAwareShotPlanner.maxInheritedRankJump,
                     ContinuityStrengthResolver.reframeRankDistance - 1,
                     "the largest planned jump sits just below the reframe threshold")
        t.checkEqual(ShotScaleLadder.rank(of: "medium-wide"),
                     ContinuityStrengthResolver.rank(ofScale: "medium-wide"),
                     "both passes rank scales with the same ladder")
        t.checkEqual(ShotScaleLadder.name(atRank: 99), "extreme-close-up",
                     "a rank past the end clamps to the tightest scale")
        t.checkEqual(ShotScaleLadder.name(atRank: -4), "extreme-wide",
                     "a rank before the start clamps to the widest scale")

        // Anything the planner leaves in place stays a standard continuation,
        // so the looser anchor becomes the fallback it was meant to be.
        let planned = CapabilityAwareShotPlanner.plan(
            shots: [draft(scale: "wide"),
                    draft(summary: "Extreme close-up of the key in the lock.",
                          scale: "extreme-close-up")],
            brief: "a woman unlocks a door"
        ).shots
        var previousShot = Shot(index: 0)
        previousShot.camera = CameraPlan(shotScale: planned[0].shotScale ?? "")
        var currentShot = Shot(index: 1)
        currentShot.camera = CameraPlan(shotScale: planned[1].shotScale ?? "")
        t.checkEqual(ContinuityStrengthResolver.policy(previous: previousShot, current: currentShot),
                     .standard,
                     "a capability-planned boundary no longer needs the reframe anchor")

        // The split-beat ladder obeys the same bound at every length.
        for count in 1...12 {
            let ladder = AutoMovieBeatPlanner.shotScales(count: count)
            var ok = true
            for index in 1..<max(ladder.count, 1) {
                guard let a = ShotScaleLadder.rank(of: ladder[index - 1]),
                      let b = ShotScaleLadder.rank(of: ladder[index]) else { continue }
                if abs(b - a) > CapabilityAwareShotPlanner.maxInheritedRankJump { ok = false }
            }
            t.check(ok, "split beats for \(count) shots stay within one capability step")
        }
    }

    t.suite("Capability-aware planning — scope and compatibility") {
        // O/P. The calibrated strengths are untouched by this change.
        t.checkEqual(AutoMovieRunCoordinator.continuityImageStrength, 0.8,
                     "O: standard continuity strength is still 0.8")
        t.checkEqual(AutoMovieRunCoordinator.reframeContinuityImageStrength, 0.5,
                     "P: the reframe fallback is still 0.5")

        // Q. Reconciliation still ignores framing entirely.
        func sceneShot(_ index: Int, scale: String) -> Shot {
            var shot = Shot(index: index, title: "Shot \(index + 1)",
                            summary: "She stands in the same courtyard.")
            shot.camera = CameraPlan(shotScale: scale)
            shot.continuityMode = .cut
            var state = ContinuitySnapshot()
            state.location = "courtyard"
            state.characterOutfit = ["Elara": "grey coat"]
            shot.continuityBefore = state
            return shot
        }
        let wideThenTight = ContinuityReconciler.reconcile(
            shots: [sceneShot(0, scale: "wide"), sceneShot(1, scale: "extreme-close-up")]
        )
        let wideThenNear = ContinuityReconciler.reconcile(
            shots: [sceneShot(0, scale: "wide"), sceneShot(1, scale: "medium-wide")]
        )
        t.checkEqual(wideThenTight[1].continuityMode, wideThenNear[1].continuityMode,
                     "Q: the framing of a shot does not change its cut/continue decision")
        t.checkEqual(wideThenTight[1].continuityMode, .continueFromPrevious,
                     "Q: a proven continuous scene is still promoted")

        // R. A project persisted before these fields existed still decodes, and
        //    reports no capability adjustment.
        let legacy = """
        {"index":2,"title":"Legacy","summary":"An old shot","durationSeconds":5,
         "camera":{"shotScale":"extreme-close-up","angle":"eye-level","movement":"static","composition":""},
         "audio":{"dialogue":[],"footsteps":false,"foley":[],"sfx":[],"ambience":""},
         "explicitChanges":[],"characterIDs":[],"compiledPrompt":"old prompt","takes":[]}
        """
        if let data = legacy.data(using: .utf8),
           let shot = try? JSONDecoder().decode(Shot.self, from: data) {
            t.checkEqual(shot.camera.shotScale, "extreme-close-up",
                         "R: an old shot keeps the framing it was saved with")
            t.check(shot.originalCameraScale == nil,
                    "R: an old shot reports no original framing")
            t.check(shot.capabilityAdjustmentReason == nil,
                    "R: an old shot reports no capability adjustment")
        } else {
            t.check(false, "R: a pre-capability shot still decodes")
        }

        // A round trip keeps both new fields.
        var adjusted = Shot(index: 0, title: "Adjusted", summary: "She unlocks the door.")
        adjusted.camera = CameraPlan(shotScale: "medium-close-up")
        adjusted.originalCameraScale = "extreme-close-up"
        adjusted.capabilityAdjustmentReason = "shot 1: highRisk (detail-insert framing)"
        if let data = try? JSONEncoder().encode(adjusted),
           let decoded = try? JSONDecoder().decode(Shot.self, from: data) {
            t.checkEqual(decoded.originalCameraScale, "extreme-close-up",
                         "the Director's original framing survives a round trip")
            t.checkEqual(decoded.capabilityAdjustmentReason, adjusted.capabilityAdjustmentReason,
                         "the capability reason survives a round trip")
        } else {
            t.check(false, "an adjusted shot round-trips")
        }
    }

    t.suite("Capability-aware planning — other surfaces are untouched") {
        // A plan the Director could return for any workflow: a risky detail
        // insert reached by a four-rung jump.
        let riskyPlan = """
        {"logline":"a woman unlocks a door","synopsis":"","setting":"","tone":"",
         "shots":[
           {"title":"Approach","summary":"She walks up to the door.","durationSeconds":5,
            "shotScale":"medium-wide","angle":"eye-level","movement":"track",
            "lighting":"soft light","continuity":"cut"},
           {"title":"Unlock","summary":"Extreme close-up of her fingers inserting the key into the tiny lock.",
            "durationSeconds":5,"shotScale":"extreme-close-up","angle":"eye-level","movement":"static",
            "lighting":"soft light","continuity":"continue"}
         ]}
        """
        let brief = "a woman walks to a door and unlocks it"

        // M. Storyboard plans the Director's shots verbatim.
        let storyboardSemaphore = DispatchSemaphore(value: 0)
        Task {
            let director = StoryboardDirector(providers: [MockDirectorProvider(responses: [riskyPlan])])
            do {
                let (project, _, _) = try await director.makeProject(title: "Manual", brief: brief)
                t.checkEqual(project.shots[1].camera.shotScale, "extreme-close-up",
                             "M: Storyboard keeps the Director's framing")
                t.check(project.shots[1].summary.lowercased().contains("extreme close-up"),
                        "M: Storyboard keeps the Director's action text")
                t.check(project.shots[1].capabilityAdjustmentReason == nil,
                        "M: Storyboard records no capability adjustment")
                t.check(project.shots[1].compiledPrompt.lowercased().contains("extreme-close-up"),
                        "M: the Storyboard prompt still asks for the planned framing")
            } catch {
                t.check(false, "M: Storyboard planning threw \(error)")
            }
            storyboardSemaphore.signal()
        }
        storyboardSemaphore.wait()

        // The same plan through Auto Movie is steered instead.
        let autoMovieSemaphore = DispatchSemaphore(value: 0)
        Task {
            let director = StoryboardDirector(providers: [MockDirectorProvider(responses: [riskyPlan])])
            let hybrid = HybridProjectCoordinator(director: director)
            do {
                var settings = ProjectSettings()
                settings.targetDurationSeconds = 10
                let (project, _, _) = try await hybrid.makeProject(
                    title: "Auto Movie", brief: brief, settings: settings
                )
                t.checkEqual(project.shots.count, 2, "Auto Movie kept the Director's two shots")
                t.checkEqual(project.shots[1].camera.shotScale, "medium-close-up",
                             "Auto Movie plans the insert at a renderable framing")
                t.checkEqual(project.shots[1].originalCameraScale, "extreme-close-up",
                             "Auto Movie keeps the Director's original framing on the shot")
                t.check(project.shots[1].capabilityAdjustmentReason?.contains("highRisk") == true,
                        "Auto Movie records why the plan changed")
                t.check(project.shots[1].summary.lowercased().contains("key"),
                        "the unlock beat survives into the Auto Movie shot")
                t.check(project.shots[1].compiledPrompt.lowercased().contains("medium-close-up"),
                        "the compiled prompt asks for the effective framing")
                t.check(!project.shots[1].compiledPrompt.lowercased().contains("extreme close-up"),
                        "the compiled prompt no longer asks for a macro insert")
                t.checkEqual(project.shots[1].continuityMode, .continueFromPrevious,
                             "the reframed shot is still a continuation")
            } catch {
                t.check(false, "Auto Movie planning threw \(error)")
            }
            autoMovieSemaphore.signal()
        }
        autoMovieSemaphore.wait()

        // N. The Basic (no-LLM) path gets the same policy, so feasibility does
        //    not depend on whether a local model was available.
        let basicSemaphore = DispatchSemaphore(value: 0)
        Task {
            let director = StoryboardDirector(providers: [TemplateStoryboardProvider()])
            let hybrid = HybridProjectCoordinator(director: director)
            do {
                var settings = ProjectSettings()
                settings.targetDurationSeconds = 20
                let (project, _, _) = try await hybrid.makeProject(
                    title: "Basic", brief: "a person approaches a parked car and gets inside",
                    settings: settings
                )
                var ok = true
                for index in 1..<project.shots.count {
                    guard let a = ShotScaleLadder.rank(of: project.shots[index - 1].camera.shotScale),
                          let b = ShotScaleLadder.rank(of: project.shots[index].camera.shotScale)
                    else { continue }
                    if abs(b - a) > CapabilityAwareShotPlanner.maxInheritedRankJump { ok = false }
                }
                t.check(ok, "N: the Basic fallback plan also stays within one capability step")
                t.check(project.shots.allSatisfy { !$0.compiledPrompt.isEmpty },
                        "N: the Basic fallback still compiles every prompt")
            } catch {
                t.check(false, "N: Basic planning threw \(error)")
            }
            basicSemaphore.signal()
        }
        basicSemaphore.wait()

        // K/L. Generate and One Shot never route through the capability pass:
        //      the shot-level compiler is the only thing they share, and it is
        //      unchanged.
        let oneShot = PromptCompiler.compile(plan: OneShotPlan(
            camera: "extreme-close-up shot, eye-level angle, static camera",
            action: "Extreme close-up of the key entering the tiny lock.",
            lighting: "warm light", dialogue: [], audioCues: [],
            durationIntentSeconds: 5
        ))
        t.check(oneShot.lowercased().contains("extreme-close-up"),
                "K/L: One Shot and Generate still compile the framing they were given")
        t.check(oneShot.lowercased().contains("tiny"),
                "K/L: no capability rewriting happens outside Auto Movie")
    }
}
