import Foundation
@testable import LTXVideoGeneratorCore

/// Auto Movie V2.1 quality hardening: focused deterministic coverage for the
/// specific gaps found while auditing the accepted, real-generation-tested
/// V2 pipeline (appearance-preservation anchor, purpose-driven camera-angle
/// repair, consultedKnowledgeIDs wiring, unknown explicitChanges diagnostics).
func runQualityHardeningTests(_ t: TestKit) {

    t.suite("Quality hardening A/B — appearance preservation vs explicit change") {
        func state(_ id: UUID, costume: String) -> ContinuityEngine.ResolvedCharacterState {
            ContinuityEngine.ResolvedCharacterState(
                id: id, name: "Character1", appearance: CharacterAppearance(),
                currentCostume: costume, accessories: "", continuityNotes: "", lockedTraits: [])
        }
        let id = UUID()

        // A. No explicit change: the generic preservation anchor survives,
        // with no specific costume text (that is exactly D-071's failure mode).
        let unchanged = ContinuationPromptPolicy.changeFocusedContext(
            before: [state(id, costume: "navy sailor vest")],
            after: [state(id, costume: "navy sailor vest")])
        t.check(unchanged.contains(ContinuationPromptPolicy.unchangedAppearanceStatement),
                "A: an unchanged CONTINUE shot carries the generic appearance-preservation anchor")
        t.check(!unchanged.lowercased().contains("navy"),
                "A: the anchor never restates the specific costume text")

        // B. An explicit change is still described, and the generic
        // preservation anchor does NOT also appear (it would contradict the
        // change it is supposed to protect against).
        let changed = ContinuationPromptPolicy.changeFocusedContext(
            before: [state(id, costume: "navy sailor vest")],
            after: [state(id, costume: "beige trench coat")])
        t.check(changed.lowercased().contains("beige trench coat"),
                "B: an explicit costume change is still described")
        t.check(!changed.contains(ContinuationPromptPolicy.unchangedAppearanceStatement),
                "B: the preservation anchor never overrides a real, intended change")
    }

    t.suite("Quality hardening C/D — purpose-driven camera-angle repair") {
        // C. A generic "eye-level" default on an Establishing/Reveal shot is
        // nudged toward a purpose-appropriate alternative.
        t.checkEqual(AutoMoviePurposePlanner.nudgedAngle(current: "eye-level", purpose: .establish), "high",
                     "C: a generic eye-level default is nudged for an Establishing shot")
        t.checkEqual(AutoMoviePurposePlanner.nudgedAngle(current: "eye-level", purpose: .reveal), "high",
                     "C: a generic eye-level default is nudged for a Reveal shot")
        // Performance/Reaction/Action/Detail/Transition/Dialogue stay put —
        // this is purpose-driven variation, not "vary every angle."
        for purpose: ShotPurpose in [.performance, .reaction, .action, .detail, .transition, .dialogue] {
            t.checkEqual(AutoMoviePurposePlanner.nudgedAngle(current: "eye-level", purpose: purpose), "eye-level",
                         "C: \(purpose.rawValue) keeps eye-level — not every purpose is nudged")
        }

        // D. A specific, meaningful angle the Director/user actually chose
        // (low/high/overhead) is never overwritten, for any purpose.
        for angle in ["low", "high", "overhead"] {
            t.checkEqual(AutoMoviePurposePlanner.nudgedAngle(current: angle, purpose: .establish), angle,
                         "D: an explicit '\(angle)' angle is preserved exactly, never overwritten")
            t.checkEqual(AutoMoviePurposePlanner.nudgedAngle(current: angle, purpose: .reveal), angle,
                         "D: an explicit '\(angle)' angle is preserved exactly for Reveal too")
        }
    }

    t.suite("Quality hardening E — consultedKnowledgeIDs wiring and persistence") {
        let brief = "A young woman walks along a beach, the wind moving her hair. She stops, turns toward the camera, and gives a small smile."
        let expectedIDs = AutoMovieKnowledgeBase.retrieve(for: brief).map(\.id)
        t.check(!expectedIDs.isEmpty, "E: sanity check — this brief actually matches real knowledge entries")

        let coordinator = HybridProjectCoordinator(
            director: StoryboardDirector(providers: [TemplateStoryboardProvider()]))
        let settings = ProjectSettings(targetDurationSeconds: 15)
        let sem = DispatchSemaphore(value: 0)
        var madeProject: FilmProject?
        Task {
            madeProject = try? await coordinator.makeProject(title: "Knowledge ID Test", brief: brief, settings: settings).project
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        guard let project = madeProject, let firstShot = project.shots.first else {
            t.check(false, "E: makeProject must succeed for the wiring test to mean anything")
            return
        }
        t.checkEqual(firstShot.consultedKnowledgeIDs, expectedIDs,
                     "E: the real retrieved IDs for this brief are wired onto the shot, not left empty")

        // Round-trip: the field survives a real project save/load, unaffected
        // by anything else in the encode/decode path.
        let data = try? JSONEncoder().encode(firstShot)
        let decoded = data.flatMap { try? JSONDecoder().decode(Shot.self, from: $0) }
        t.checkEqual(decoded?.consultedKnowledgeIDs, expectedIDs,
                     "E: consultedKnowledgeIDs survives a Codable round-trip")

        // Deterministic ordering: the same brief always returns IDs in the
        // same order (retrieve() is a pure, deterministic function).
        let secondCall = AutoMovieKnowledgeBase.retrieve(for: brief).map(\.id)
        t.checkEqual(expectedIDs, secondCall, "E: retrieval order is deterministic across calls")
    }

    t.suite("Quality hardening F/G — explicitChanges: unknown vs known keys") {
        // F. An unknown/invented key is detected (throws), never silently
        // mutates continuity state, and the caller's fallback-to-previous-
        // state behavior means no partial/invented state survives.
        let before = ContinuitySnapshot()
        do {
            _ = try ContinuityEngine.apply(changes: ["camera=tilting up to sunset"], to: before)
            t.check(false, "F: an unknown explicitChanges key must be detected, not silently accepted")
        } catch ContinuityEngine.DirectiveError.malformed(let directive) {
            t.checkEqual(directive, "camera=tilting up to sunset",
                         "F: the malformed directive is reported so the diagnostic names the actual bad key")
        } catch {
            t.check(false, "F: unexpected error type: \(error)")
        }

        // The same real, observed case from an actual Director response: a
        // plausible-looking but non-schema compound key.
        do {
            _ = try ContinuityEngine.apply(changes: ["characterCondition:CharacterID_1=Smiling"], to: before)
            t.check(false, "F: an invented compound key (characterCondition:, not condition:) must also be detected")
        } catch ContinuityEngine.DirectiveError.malformed {
            t.check(true, "F: invented compound key correctly detected as malformed")
        } catch {
            t.check(false, "F: unexpected error type: \(error)")
        }

        // G. Known keys are completely unaffected — same behavior as before
        // this investigation started.
        let afterKnown = try? ContinuityEngine.apply(changes: ["location=an old stone library"], to: before)
        t.checkEqual(afterKnown?.location, "an old stone library",
                     "G: a known explicitChanges key still applies exactly as before")
        let afterOutfit = try? ContinuityEngine.apply(
            changes: ["outfit:Elena=red leather jacket"], to: before)
        t.checkEqual(afterOutfit?.characterOutfit["Elena"], "red leather jacket",
                     "G: a known compound key (outfit:) still applies exactly as before")
    }
}
