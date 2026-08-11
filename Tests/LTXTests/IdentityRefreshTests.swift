import Foundation
@testable import LTXVideoGeneratorCore

func runIdentityRefreshTests(_ t: TestKit) {

    func assessment(
        scale: IdentitySourceAssessment.SubjectScale = .medium,
        face: IdentitySourceAssessment.Visibility = .clear,
        orientation: IdentitySourceAssessment.Orientation = .front,
        present: Bool = true,
        status: IdentitySourceAssessment.Status = .assessed
    ) -> IdentitySourceAssessment {
        var a = IdentitySourceAssessment()
        a.status = status
        a.subjectPresent = present
        a.subjectCount = present ? 1 : 0
        a.subjectScale = scale
        a.faceVisibility = face
        a.subjectOrientation = orientation
        a.hairVisibility = face
        a.costumeVisibility = .clear
        return a
    }

    t.suite("Identity refresh — what the next shot needs") {
        for scale in ["close-up", "extreme close-up", "medium-close-up", "closeup"] {
            t.checkEqual(IdentityDetailRequirement.from(shotScale: scale), .faceCritical,
                         "\"\(scale)\" needs facial detail")
        }
        for scale in ["wide", "extreme wide", "wide shot", "establishing", "long shot"] {
            t.checkEqual(IdentityDetailRequirement.from(shotScale: scale), .low,
                         "\"\(scale)\" does not depend on facial detail")
        }
        t.checkEqual(IdentityDetailRequirement.from(shotScale: "medium"), .moderate,
                     "a plain medium shot sits in between")
        t.checkEqual(IdentityDetailRequirement.from(shotScale: "medium-wide"), .low,
                     "medium-wide reads as wide, not as close")
        t.checkEqual(IdentityDetailRequirement.from(shotScale: nil), .moderate,
                     "a missing shot scale is treated conservatively")
    }

    t.suite("Identity refresh — decision policy") {
        // A. good source + close shot → leave it alone. This is the case
        // controlled test D proved already works, so spending a whole
        // generation on it would be waste.
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(scale: .large, face: .clear, orientation: .front),
            hasExplicitStartingImage: false).isRefresh,
                "A: a clear front-on source needs no refresh even for a close-up")

        // B. back-facing + close shot → refresh. The exact production failure.
        t.check(IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(face: .none, orientation: .back),
            hasExplicitStartingImage: false).isRefresh,
                "B: a back-facing source before a close-up triggers a refresh")

        // C. tiny subject + close shot → refresh.
        t.check(IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(scale: .tiny, face: .partial, orientation: .front),
            hasExplicitStartingImage: false).isRefresh,
                "C: a tiny subject before a close-up triggers a refresh")

        // D/E. wide next shot → never refresh, however poor the source.
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .low,
            assessment: assessment(scale: .large, face: .clear),
            hasExplicitStartingImage: false).isRefresh,
                "D: a clear source before a wide shot needs no refresh")
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .low,
            assessment: assessment(scale: .tiny, face: .none, orientation: .back),
            hasExplicitStartingImage: false).isRefresh,
                "E: even a poor source needs no refresh when the next shot is wide")

        // F. medium framing is not close enough to be worth a generation.
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .moderate,
            assessment: assessment(face: .none, orientation: .back),
            hasExplicitStartingImage: false).isRefresh,
                "F: a medium shot does not trigger a refresh on its own")

        // G. the user's own choice always wins.
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(face: .none, orientation: .back),
            hasExplicitStartingImage: true).isRefresh,
                "G: an explicit starting image is never overridden by auto refresh")

        // H. no usable assessment → conservative, do nothing.
        for status: IdentitySourceAssessment.Status in [.unavailable, .failed] {
            t.check(!IdentityRefreshPolicy.decide(
                requirement: .faceCritical,
                assessment: assessment(face: .none, orientation: .back, status: status),
                hasExplicitStartingImage: false).isRefresh,
                    "H: \(status.rawValue) vision leaves continuity alone rather than guessing")
        }
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical, assessment: nil,
            hasExplicitStartingImage: false).isRefresh,
                "H: no assessment at all leaves continuity alone")
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(present: false),
            hasExplicitStartingImage: false).isRefresh,
                "H: a frame with no subject is not refreshed")

        // Small-but-clear is fine; small-and-unclear is not.
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(scale: .small, face: .clear),
            hasExplicitStartingImage: false).isRefresh,
                "a small subject with a clear face is still usable")
        t.check(IdentityRefreshPolicy.decide(
            requirement: .faceCritical,
            assessment: assessment(scale: .small, face: .partial),
            hasExplicitStartingImage: false).isRefresh,
                "a small subject with a partial face is not")
    }

    t.suite("Identity refresh — anchor selection") {
        t.checkEqual(
            IdentityAnchorSelector.select(
                previousRefreshPaths: [], openingReferenceRelativePath: "Assets/OpeningReference/o.png"),
            .openingReference(relativePath: "Assets/OpeningReference/o.png"),
            "C: the opening reference is used when nothing better exists")

        t.checkEqual(
            IdentityAnchorSelector.select(
                previousRefreshPaths: ["Assets/IdentityRefresh/a.png", "Assets/IdentityRefresh/b.png"],
                openingReferenceRelativePath: "Assets/OpeningReference/o.png"),
            .previousRefresh(relativePath: "Assets/IdentityRefresh/b.png"),
            "B: the most recent refresh anchor is preferred over the opening reference")

        t.checkEqual(
            IdentityAnchorSelector.select(previousRefreshPaths: [], openingReferenceRelativePath: nil),
            .none,
            "E: with no anchor at all, selection reports none rather than inventing one")
        t.checkEqual(
            IdentityAnchorSelector.select(previousRefreshPaths: [], openingReferenceRelativePath: ""),
            .none,
            "an empty opening reference path is not an anchor")

        // D. a raw character sheet is never offered as a final scene anchor —
        // it is not part of the selectable set at all.
        let anchors: [IdentityAnchorSelector.Anchor] = [
            .previousRefresh(relativePath: "x"), .openingReference(relativePath: "y"), .none,
        ]
        t.checkEqual(anchors.count, 3,
                     "D: only scene-like anchors are selectable; a character sheet plate is not one")
    }

    t.suite("Identity refresh — assessment parsing") {
        let good = """
        {"subjectPresent":true,"subjectCount":1,"subjectScale":"tiny",
         "faceVisibility":"none","hairVisibility":"partial",
         "costumeVisibility":"clear","subjectOrientation":"back"}
        """
        let parsed = IdentitySourceAssessor.assessment(
            fromResponse: good, sourceRelativePath: "p.png", model: "m")
        t.checkEqual(parsed.status, .assessed, "a well-formed answer is assessed")
        t.checkEqual(parsed.subjectScale, .tiny, "scale is read")
        t.checkEqual(parsed.faceVisibility, .none, "face visibility is read")
        t.checkEqual(parsed.subjectOrientation, .back, "orientation is read")
        t.check(IdentityRefreshPolicy.decide(
            requirement: .faceCritical, assessment: parsed,
            hasExplicitStartingImage: false).isRefresh,
                "and that assessment drives a refresh, end to end")

        t.checkEqual(
            IdentitySourceAssessor.assessment(
                fromResponse: "sorry", sourceRelativePath: "p.png", model: "m").status,
            .failed, "a non-JSON answer fails safely")
        t.checkEqual(
            IdentitySourceAssessor.unavailable(sourceRelativePath: "p.png").status,
            .unavailable, "unavailable is a status rather than an error")

        // Unknown enum values must degrade, not crash or silently become risky.
        let odd = """
        {"subjectPresent":true,"subjectCount":1,"subjectScale":"gigantic",
         "faceVisibility":"maybe","hairVisibility":"clear",
         "costumeVisibility":"clear","subjectOrientation":"upside-down"}
        """
        let degraded = IdentitySourceAssessor.assessment(
            fromResponse: odd, sourceRelativePath: "p.png", model: "m")
        t.checkEqual(degraded.subjectScale, .unknown, "an unknown scale becomes unknown")
        t.checkEqual(degraded.faceVisibility, .unknown, "an unknown visibility becomes unknown")
        t.check(!IdentityRefreshPolicy.decide(
            requirement: .faceCritical, assessment: degraded,
            hasExplicitStartingImage: false).isRefresh,
                "unknown values do not trigger a refresh — ambiguity stays conservative")
    }

    t.suite("Identity refresh — persistence and staleness") {
        var project = FilmProject(title: "M")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        var shot1 = Shot(index: 0, title: "One")
        let take = Take(shotID: shot1.id, modelID: "m", seed: 1,
                        promptSnapshot: "p", settingsSnapshot: .default,
                        requestedWidth: 768, requestedHeight: 512,
                        fps: 24, requestedDuration: 5, status: .completed)
        shot1.takes = [take]
        shot1.selectedTakeID = take.id
        var shot2 = Shot(index: 1, title: "Two")
        shot2.identityRefreshAnchorRelativePath = "Assets/IdentityRefresh/shot-002-x.png"
        shot2.identityRefreshSourceTakeID = take.id
        shot2.identityRefreshNote = "Identity Refresh: applied"
        project.shots = [shot1, shot2]

        // A/B. round trip.
        let data = try! JSONEncoder().encode(project)
        let decoded = try! JSONDecoder().decode(FilmProject.self, from: data)
        t.checkEqual(decoded.shots[1].identityRefreshAnchorRelativePath,
                     "Assets/IdentityRefresh/shot-002-x.png",
                     "A/B: the refresh anchor survives a save and reload")
        t.checkEqual(decoded.shots[1].identityRefreshSourceTakeID, take.id,
                     "and remembers which take it was derived from")

        // C/D. a retake upstream makes the anchor stale.
        var retaken = decoded
        let newTake = Take(shotID: retaken.shots[0].id, modelID: "m", seed: 2,
                           promptSnapshot: "p", settingsSnapshot: .default,
                           requestedWidth: 768, requestedHeight: 512,
                           fps: 24, requestedDuration: 5, status: .completed)
        retaken.shots[0].takes = [newTake]
        retaken.shots[0].selectedTakeID = newTake.id
        IdentityRefreshService.invalidateStaleAnchor(shotIndex: 1, in: &retaken)
        t.check(retaken.shots[1].identityRefreshAnchorRelativePath == nil,
                "C/D: a retake upstream invalidates the dependent refresh anchor")
        t.check(retaken.shots[1].identityRefreshNote == nil,
                "and clears its note, so no stale explanation is shown")

        // An unchanged take keeps the anchor.
        var unchanged = decoded
        IdentityRefreshService.invalidateStaleAnchor(shotIndex: 1, in: &unchanged)
        t.checkEqual(unchanged.shots[1].identityRefreshAnchorRelativePath,
                     "Assets/IdentityRefresh/shot-002-x.png",
                     "an anchor from the current take is kept")

        // F. legacy projects decode with no refresh state.
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        var shots = object["shots"] as! [[String: Any]]
        shots[1].removeValue(forKey: "identityRefreshAnchorRelativePath")
        shots[1].removeValue(forKey: "identityRefreshSourceTakeID")
        shots[1].removeValue(forKey: "identityRefreshNote")
        object["shots"] = shots
        let legacy = try! JSONDecoder().decode(
            FilmProject.self, from: try! JSONSerialization.data(withJSONObject: object))
        t.check(legacy.shots[1].identityRefreshAnchorRelativePath == nil,
                "F: a project written before this feature decodes with no anchor")
        t.checkEqual(legacy.shots.count, 2, "and is otherwise intact")
    }

    t.suite("Identity refresh — the generator is a transformation, not a continuation") {
        var shot = Shot(index: 2, title: "Closer")
        shot.camera = CameraPlan(shotScale: "medium-close-up", angle: "eye-level", movement: "slow push-in")
        let prompt = LTXTemporalRefreshGenerator.prompt(for: shot)
        t.check(prompt.contains("medium-close-up"),
                "the refresh prompt asks for the target framing")
        t.check(prompt.lowercased().contains("face becomes clearly visible"),
                "and explicitly asks for the face the next shot needs")
        t.check(!prompt.contains(ContinuationPromptPolicy.continuityStatement),
                "it does not use the CONTINUE policy: preserving the state is the opposite of the goal (D-073)")
        for banned in ["face lock", "identity lock", "guaranteed"] {
            t.check(!prompt.lowercased().contains(banned),
                    "the refresh prompt makes no '\(banned)' claim")
        }
        t.checkEqual(LTXTemporalRefreshGenerator.frameCount, 49,
                     "the preparation clip uses a valid 8n+1 frame count")
        t.check(LTXTemporalRefreshGenerator.frameCount % 8 == 1,
                "49 is 8n+1, which this backend requires")
        t.checkEqual(LTXTemporalRefreshGenerator.preferredPercent, 80,
                     "the anchor frame is taken from part-way through, not the end")
    }
}
