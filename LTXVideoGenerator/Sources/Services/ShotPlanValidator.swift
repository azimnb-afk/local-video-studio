import Foundation

/// Deterministic, advisory checks over a materialized plan, run once after
/// Director planning (and after `repairOverloadedShots`'s structural repair
/// has already had a chance to fix the one case it can). Every check here is
/// a plain, inspectable rule over already-resolved `Shot`/brief data — no
/// second LLM call, no network, nothing that can fail unpredictably. A
/// finding is reported as a `ContinuityEngine.Violation` exactly like the
/// existing continuity/monotony diagnostics, so it reaches the same place
/// those already do; nothing here blocks generation on its own.
///
/// This intentionally does not attempt "CUT reads the previous frame" or
/// similar checks: those are prevented by construction in the generation
/// pipeline (`TakeGenerationCoordinator.planTakes`/`LTXContinuityResolver`),
/// so a validator rule for them would just be dead code guarding against a
/// case the type system and execution order already rule out.
enum ShotPlanValidator {

    static func validate(shots: [Shot], brief: String) -> [ContinuityEngine.Violation] {
        var violations: [ContinuityEngine.Violation] = []
        violations.append(contentsOf: actionOverload(shots))
        violations.append(contentsOf: cameraContradiction(shots))
        violations.append(contentsOf: dialogueDuration(shots))
        violations.append(contentsOf: unsupportedShotScale(shots))
        violations.append(contentsOf: continueWithoutSceneReset(shots))
        violations.append(contentsOf: terminalTokenContamination(shots))
        violations.append(contentsOf: unplacedExplicitDialogue(shots, brief: brief))
        return violations
    }

    /// A shot still asking for `maxVisibleBeats` or more distinct actions
    /// after structural repair either had no clause separator to split on,
    /// or was produced after repair ran (e.g. a manually edited Storyboard
    /// shot) — either way it is worth flagging, not silently rendered.
    private static func actionOverload(_ shots: [Shot]) -> [ContinuityEngine.Violation] {
        shots.enumerated().compactMap { index, shot in
            let beats = CapabilityAwareShotPlanner.visibleBeatCount(in: shot.summary)
            guard beats >= CapabilityAwareShotPlanner.maxVisibleBeats else { return nil }
            return ContinuityEngine.Violation(
                severity: .warning,
                message: "Shot \(index + 1): reads as \(beats) separate actions in one shot; consider splitting it."
            )
        }
    }

    /// A locked-off/static camera combined with a large, showy move in the
    /// same instruction is a direct contradiction, not a stylistic choice —
    /// mirrors the product guidance that orbit/whip-pan/handheld-shake/rapid
    /// crane moves are never a default, only ever a deliberate one.
    private static func cameraContradiction(_ shots: [Shot]) -> [ContinuityEngine.Violation] {
        let showyMoves = ["orbit", "whip pan", "handheld shake", "dramatic zoom", "rapid crane", "crane move"]
        return shots.enumerated().compactMap { index, shot in
            let movement = shot.camera.movement.lowercased()
            guard movement.contains("static") || movement.contains("locked") else { return nil }
            guard let conflict = showyMoves.first(where: { movement.contains($0) }) else { return nil }
            return ContinuityEngine.Violation(
                severity: .warning,
                message: "Shot \(index + 1): camera movement names both a static/locked hold and '\(conflict)' at once."
            )
        }
    }

    /// A shot with a spoken line needs enough time for the line itself plus
    /// a beat of reaction (see AutoMovieKnowledgeBase "perf.dialogue-timing");
    /// below this floor the line cannot land before the shot ends.
    private static func dialogueDuration(_ shots: [Shot]) -> [ContinuityEngine.Violation] {
        shots.enumerated().compactMap { index, shot in
            guard !shot.audio.dialogue.isEmpty, shot.durationSeconds < 3 else { return nil }
            return ContinuityEngine.Violation(
                severity: .warning,
                message: "Shot \(index + 1): \(String(format: "%.1f", shot.durationSeconds))s is short for a shot with spoken dialogue."
            )
        }
    }

    /// A shot scale outside the documented vocabulary reaches the renderer
    /// as unrecognized free text rather than a known framing.
    private static func unsupportedShotScale(_ shots: [Shot]) -> [ContinuityEngine.Violation] {
        shots.enumerated().compactMap { index, shot in
            guard ShotScaleLadder.rank(of: shot.camera.shotScale) == nil else { return nil }
            return ContinuityEngine.Violation(
                severity: .warning,
                message: "Shot \(index + 1): shot scale '\(shot.camera.shotScale)' is not a recognized framing."
            )
        }
    }

    /// A shot marked Continue but whose own text describes arriving somewhere
    /// new reads as a location change without the Cut that should accompany
    /// one (see AutoMovieKnowledgeBase "cine.continuity.cut-reason").
    private static func continueWithoutSceneReset(_ shots: [Shot]) -> [ContinuityEngine.Violation] {
        let sceneResetCues = [
            "arrives at", "enters the", "steps into", "now in", "now at",
            "back home", "a different room", "elsewhere", "meanwhile", "later that",
        ]
        return shots.enumerated().compactMap { index, shot in
            guard shot.continuityMode == .continueFromPrevious else { return nil }
            let text = (shot.summary + " " + (shot.endStateSummary ?? "")).lowercased()
            guard let cue = sceneResetCues.first(where: { text.contains($0) }) else { return nil }
            return ContinuityEngine.Violation(
                severity: .warning,
                message: "Shot \(index + 1): marked Continue but text says '\(cue)', which usually calls for Cut."
            )
        }
    }

    /// Stray protocol markers in visible text mean a parser boundary leaked
    /// raw formatting through instead of catching it.
    private static func terminalTokenContamination(_ shots: [Shot]) -> [ContinuityEngine.Violation] {
        let markers = ["</think>", "```", "LOGLINE:", "CONTINUITY:", "DIALOGUE_REF:", "END_STATE:"]
        return shots.enumerated().compactMap { index, shot in
            let text = shot.title + " " + shot.summary
            guard let marker = markers.first(where: { text.contains($0) }) else { return nil }
            return ContinuityEngine.Violation(
                severity: .error,
                message: "Shot \(index + 1): visible text contains an unparsed protocol marker ('\(marker)')."
            )
        }
    }

    /// An exact dialogue line the user supplied in the brief that never made
    /// it into any shot's spoken lines. Checked by resolved text rather than
    /// source ID: the ID exists only for Director planning/reconciliation
    /// and is not retained on the persisted `Shot`.
    private static func unplacedExplicitDialogue(_ shots: [Shot], brief: String) -> [ContinuityEngine.Violation] {
        let sources = ExactDialogueReconciler.extractExplicitDialogueSources(from: brief)
        guard !sources.isEmpty else { return [] }
        let placedTexts = Set(shots.flatMap { $0.audio.dialogue.map(\.text) })
        return sources.compactMap { source in
            guard !placedTexts.contains(source.text) else { return nil }
            return ContinuityEngine.Violation(
                severity: .warning,
                message: "Explicit dialogue '\(source.text.prefix(40))' from the brief was not placed in any shot."
            )
        }
    }
}
