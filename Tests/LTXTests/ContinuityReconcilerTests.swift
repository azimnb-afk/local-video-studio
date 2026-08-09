import Foundation
@testable import LTXVideoGeneratorCore

/// Continuity Reconciliation: promote a planned cut to a continuation only when
/// the Director's own metadata proves the scene, time, cast and action chain
/// carry over. Never demote, never touch the first shot, never overrule an
/// explicit scene change, and never treat a framing change as a scene change.
func runContinuityReconcilerTests(_ t: TestKit) {

    /// Builds a shot with explicit scene state, mirroring what the Director
    /// actually emits (initialState + explicitChanges applied per shot).
    func shot(
        _ index: Int,
        summary: String = "She moves through the scene.",
        location: String = "Courtyard path",
        time: String = "Late Afternoon",
        weather: String = "Clear",
        storyState: String = "",
        cast: [String] = ["Elara"],
        castIDs: [UUID] = [],
        changes: [String] = [],
        planned: ShotContinuityMode? = .cut,
        scale: String = "medium",
        angle: String = "eye-level",
        movement: String = "static"
    ) -> Shot {
        var state = ContinuitySnapshot()
        state.location = location
        state.timeOfDay = time
        state.weather = weather
        state.storyState = storyState
        for name in cast { state.characterOutfit[name] = "wool coat" }
        var s = Shot(index: index, title: "Shot \(index + 1)", summary: summary)
        s.continuityBefore = state
        s.characterIDs = castIDs
        s.explicitChanges = changes
        s.continuityMode = planned
        s.camera = CameraPlan(shotScale: scale, angle: angle, movement: movement)
        return s
    }

    func effective(_ shots: [Shot]) -> [ShotContinuityMode] {
        ContinuityReconciler.reconcile(shots: shots).map { $0.continuityMode ?? .auto }
    }

    t.suite("Continuity reconciliation — core promotion rules") {
        // A. Same character, location, time and action chain, Director said cut.
        let a = [shot(0), shot(1, summary: "She reaches the entrance.")]
        t.checkEqual(effective(a), [.cut, .continueFromPrevious],
                     "A: a proven continuous boundary is promoted")
        let decision = ContinuityReconciler.decisions(for: a)[1]
        t.check(decision.wasPromoted, "A: promotion is reported")
        t.check(decision.reason.contains("same cast") && decision.reason.contains("same location"),
                "A: the promotion reason names its evidence")

        // B. A location change is the Director moving the story.
        let b = [shot(0), shot(1, location: "Library interior", changes: ["location=Library interior"])]
        t.checkEqual(effective(b), [.cut, .cut], "B: a location change keeps its cut")

        // C. A time jump keeps its cut.
        let c = [shot(0), shot(1, time: "Night", changes: ["timeOfDay=Night"])]
        t.checkEqual(effective(c), [.cut, .cut], "C: a time jump keeps its cut")

        // D. A different cast keeps its cut.
        let d = [shot(0), shot(1, cast: ["Marcus"])]
        t.checkEqual(effective(d), [.cut, .cut], "D: a cast change keeps its cut")

        // E. Any explicit scene-change directive wins over the metadata.
        let e = [shot(0), shot(1, changes: ["weather=Storm"])]
        t.checkEqual(effective(e), [.cut, .cut], "E: an explicit scene change keeps its cut")

        // F/G. A framing change is NOT a scene change — this is the point of the
        // whole feature, since inheriting at 0.8 already frees the camera.
        let f = [shot(0, scale: "wide"), shot(1, scale: "extreme-close-up")]
        t.checkEqual(effective(f), [.cut, .continueFromPrevious],
                     "F: a shot-scale change still allows promotion")
        let g = [shot(0, movement: "dolly"), shot(1, angle: "low", movement: "static")]
        t.checkEqual(effective(g), [.cut, .continueFromPrevious],
                     "G: a camera movement/angle change still allows promotion")

        // H. The first shot can never continue.
        let h = [shot(0, planned: .continueFromPrevious), shot(1)]
        t.checkEqual(effective(h)[0], .cut, "H: the first shot is always a cut")

        // I. A planned continuation is never demoted.
        let i = [shot(0), shot(1, location: "Library interior",
                               changes: ["location=Library interior"],
                               planned: .continueFromPrevious)]
        t.checkEqual(effective(i)[1], .continueFromPrevious,
                     "I: the reconciler never demotes a planned continuation")
    }

    t.suite("Continuity reconciliation — boundaries and missing data") {
        // K. Exterior approach → exterior entrance, same cast and time.
        let k = [
            shot(0, summary: "She crosses the courtyard toward the doors."),
            shot(1, summary: "She stops at the doors and reaches for the handle."),
        ]
        t.checkEqual(effective(k), [.cut, .continueFromPrevious],
                     "K: two exterior beats of one approach are promoted")

        // L. Exterior → interior establishing keeps its cut even when the
        // metadata still names one building.
        let l = [
            shot(0, summary: "She stops at the doors in the courtyard."),
            shot(1, summary: "Interior establishing shot as she steps inside the hall."),
        ]
        t.checkEqual(effective(l), [.cut, .cut],
                     "L: crossing a threshold keeps its cut")
        t.check(ContinuityReconciler.decisions(for: l)[1].reason.contains("exterior to interior"),
                "L: the threshold crossing is the stated reason")

        // M. A detail insert of the same moment is a continuation: same place,
        // same cast, only the framing tightens.
        let m = [
            shot(0, summary: "She stops at the doors.", scale: "medium-wide"),
            shot(1, summary: "Her gloved hand turns the key in the lock.", scale: "extreme-close-up"),
        ]
        t.checkEqual(effective(m), [.cut, .continueFromPrevious],
                     "M: a detail insert of the same action is promoted")

        // N. A story-state jump in the same place keeps its cut.
        let n = [
            shot(0, storyState: "Approaching"),
            shot(1, storyState: "Departing", changes: ["storyState=Departing"]),
        ]
        t.checkEqual(effective(n), [.cut, .cut],
                     "N: a story-state jump keeps its cut")

        // O. Same wording, different character.
        let o = [
            shot(0, summary: "She reaches the entrance.", cast: ["Elara"]),
            shot(1, summary: "She reaches the entrance.", cast: ["Nadia"]),
        ]
        t.checkEqual(effective(o), [.cut, .cut],
                     "O: identical wording with a different cast keeps its cut")

        // P. Same character, different location.
        let p = [shot(0, location: "Courtyard path"), shot(1, location: "Rooftop")]
        t.checkEqual(effective(p), [.cut, .cut],
                     "P: the same character elsewhere keeps its cut")

        // Q. Missing metadata is not evidence of continuity.
        let q = [
            shot(0, location: "", time: "", weather: "", cast: []),
            shot(1, location: "", time: "", weather: "", cast: []),
        ]
        t.checkEqual(effective(q), [.cut, .cut],
                     "Q: absent metadata keeps the conservative cut")
        t.check(ContinuityReconciler.decisions(for: q)[1].reason.contains("no positive evidence"),
                "Q: the reason states that evidence was missing")

        // One signal alone is too weak.
        let locationOnly = [shot(0, cast: []), shot(1, cast: [])]
        t.checkEqual(effective(locationOnly), [.cut, .cut],
                     "same location without a confirmed cast is not promoted")
        let castOnly = [shot(0, location: ""), shot(1, location: "")]
        t.checkEqual(effective(castOnly), [.cut, .cut],
                     "same cast without a confirmed location is not promoted")

        // Bible-backed identifiers are preferred when present.
        let id = UUID()
        let bibleShots = [shot(0, cast: [], castIDs: [id]), shot(1, cast: [], castIDs: [id])]
        t.checkEqual(effective(bibleShots), [.cut, .continueFromPrevious],
                     "stable Bible identifiers are used as cast evidence")
        t.checkEqual(ContinuityReconciler.cast(of: bibleShots[0]), Set([id.uuidString]),
                     "Bible identifiers win over planner names")
    }

    t.suite("Continuity reconciliation — persistence and isolation") {
        // R. Projects saved before reconciliation still decode.
        let legacy = """
        {"id":"\(UUID().uuidString)","index":1,"title":"Legacy","summary":"s",
         "durationSeconds":5,"compiledPrompt":"p","continuityMode":"cut"}
        """.data(using: .utf8)!
        do {
            let decoded = try JSONDecoder().decode(Shot.self, from: legacy)
            t.checkEqual(decoded.continuityMode, .cut, "R: legacy shot keeps its stored mode")
            t.check(decoded.plannedContinuityMode == nil, "R: legacy shot has no planned mode")
            t.check(decoded.continuityReconciliationReason == nil, "R: legacy shot has no reason")
        } catch {
            t.check(false, "R: legacy shot failed to decode: \(error)")
        }

        // A promotion survives a round trip, so a reloaded project keeps the
        // same effective behaviour and stays explainable.
        let reconciled = ContinuityReconciler.reconcile(
            shots: [shot(0), shot(1, summary: "She reaches the entrance.")]
        )[1]
        do {
            let decoded = try JSONDecoder().decode(
                Shot.self, from: try JSONEncoder().encode(reconciled)
            )
            t.checkEqual(decoded.continuityMode, .continueFromPrevious,
                         "effective mode round-trips")
            t.checkEqual(decoded.plannedContinuityMode, .cut,
                         "the Director's original decision round-trips")
            t.check(decoded.continuityReconciliationReason?.isEmpty == false,
                    "the reason round-trips for later explanation")
        } catch {
            t.check(false, "reconciled shot failed to round-trip: \(error)")
        }

        // J. Storyboard is untouched: reconciliation runs only inside the Auto
        // Movie coordinator, so a manual storyboard shot keeps the user's cut.
        let manual = shot(1, planned: .cut)
        t.checkEqual(manual.continuityMode, .cut,
                     "J: a storyboard shot is not reconciled by construction")
        t.check(manual.plannedContinuityMode == nil,
                "J: an unreconciled shot records no planned mode")

        // The strength calibration and precedence from earlier phases stand.
        t.checkEqual(AutoMovieRunCoordinator.continuityImageStrength, 0.8,
                     "inherited frames still use the calibrated strength")
        t.checkEqual(GenerationParameters.default.imageStrength, 1.0,
                     "explicit and manual image paths keep exact-first-frame strength")
    }

    t.suite("Continuity reconciliation — real director plan shape") {
        // The shape actually observed from the local Director: one cast, an
        // opening location directive, then only position/prop/story changes.
        let plan = [
            shot(0, summary: "Elara walks the overgrown path toward the library entrance.",
                 changes: ["location=Courtyard path"], scale: "wide", movement: "dolly-back"),
            shot(1, summary: "Elara arrives at the massive wooden doors and looks up.",
                 changes: ["position:Elara=At the door"], scale: "medium-wide",
                 angle: "low", movement: "static"),
            shot(2, summary: "Her gloved hand pulls a key and inserts it into the rusted lock.",
                 changes: ["prop+:Keyring"], scale: "extreme-close-up", movement: "static"),
        ]
        let modes = effective(plan)
        t.checkEqual(modes[0], .cut, "opening shot stays a cut")
        t.checkEqual(modes[1], .continueFromPrevious, "arrival is promoted to a continuation")
        t.checkEqual(modes[2], .continueFromPrevious, "the insert is promoted to a continuation")
        // Shot 1 declares the opening location; that must not block shot 2,
        // whose own directives carry no scene change.
        t.check(ContinuityReconciler.decisions(for: plan)[1].wasPromoted,
                "an opening location directive does not block the next boundary")
    }
}
