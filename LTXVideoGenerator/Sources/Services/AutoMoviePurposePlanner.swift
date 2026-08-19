import Foundation

/// Infers `ShotPurpose` and derives purposeful camera guidance for Auto Movie.
///
/// Two responsibilities, kept together because they share one input (a shot's
/// summary/action text, dialogue, position in the sequence) and one goal:
/// stop camera movement and duration from being arbitrary by tying both to
/// *why the shot exists*, not just to what words appear in it.
///
/// Deterministic and local — no LLM call. This runs on EVERY shot regardless
/// of which Director tier produced it (Structured JSON, Text Protocol, or the
/// no-LLM Basic Template), so purpose-aware duration/camera planning works
/// even when the Director's own `purpose` field is absent or unparseable.
/// When the Director does supply a usable value, that value wins — this is a
/// fallback inference, not an override.
enum AutoMoviePurposePlanner {

    /// Resolves a shot's effective purpose: the Director's own stated value
    /// when it parses, otherwise a deterministic guess from the shot's text
    /// and position. Never fails — worst case, `.action` (the least specific,
    /// safest default already implied by treating everything as "something
    /// visibly happens").
    static func resolvePurpose(
        stated: String?,
        summary: String,
        dialogue: [OneShotPlan.DialogueLine],
        isFirstShot: Bool,
        isCut: Bool
    ) -> ShotPurpose {
        if let stated, let parsed = ShotPurpose(rawValue: stated.lowercased()) {
            return parsed
        }
        return infer(
            summary: summary, dialogue: dialogue,
            isFirstShot: isFirstShot, isCut: isCut
        )
    }

    /// Deterministic guess used both as the fallback above and directly by
    /// the Basic (no-LLM) Template path.
    static func infer(
        summary: String,
        dialogue: [OneShotPlan.DialogueLine],
        isFirstShot: Bool,
        isCut: Bool
    ) -> ShotPurpose {
        if !dialogue.isEmpty { return .dialogue }

        let lower = summary.lowercased()
        // A cut that opens a new place, or the movie's first shot, is
        // establishing unless the text is clearly about a person's face/state
        // (then it is a reveal — a character coming into view, not a place).
        if isFirstShot || isCut {
            if containsAny(lower, revealCues) { return .reveal }
            return .establish
        }
        if containsAny(lower, reactionCues) { return .reaction }
        if containsAny(lower, detailCues) && CapabilityAwareShotPlanner.describesFineManipulation(summary) {
            return .detail
        }
        if containsAny(lower, performanceCues) { return .performance }
        if containsAny(lower, transitionCues) { return .transition }
        return .action
    }

    /// A camera-movement suggestion that supports the shot's purpose, used to
    /// steer automatic (non-explicit-user) camera choice. Deliberately narrow:
    /// only nudges when the current movement is a generic default the planner
    /// itself is likely to have produced, never overrides a movement the
    /// brief or Director chose for a reason we cannot see from purpose alone.
    ///
    /// This intentionally excludes movements the product brief calls out as
    /// "dramatic" default-camera noise (orbit, fast zoom, handheld shake) from
    /// every purpose's suggestion set — those are never a *default* choice,
    /// only ever an explicit one the user/Director opted into on their own
    /// words, which this function never touches (see `nudge` guard below).
    static func purposefulMovement(for purpose: ShotPurpose) -> [String] {
        switch purpose {
        case .establish: return ["static", "pan", "dolly"]
        case .performance: return ["static", "slow push-in"]
        case .action: return ["track", "handheld"]
        case .reaction: return ["static", "slow push-in"]
        case .detail: return ["static"]
        case .transition: return ["pan", "dolly"]
        case .reveal: return ["dolly", "pan", "slow push-in"]
        case .dialogue: return ["static", "slow push-in"]
        }
    }

    /// Nudges `currentMovement` toward the purpose's supportive set, but only
    /// when the current value is one of the small number of generic defaults
    /// planners fall back to ("static"/"dolly"/"pan"/"track" with no other
    /// signal) — never when it names something more specific (e.g.
    /// "handheld follow", "slow push-in" already, or any value containing
    /// words like "orbit"/"zoom"/"shake" the user/Director chose on purpose.
    static func nudgedMovement(current: String, purpose: ShotPurpose) -> String {
        let genericDefaults: Set<String> = ["static", "pan", "tilt", "dolly", "track", "handheld"]
        let normalized = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard genericDefaults.contains(normalized) else { return current }
        let supportive = purposefulMovement(for: purpose)
        guard !supportive.contains(normalized) else { return current }
        return supportive.first ?? current
    }

    // MARK: - Keyword tables (English + light Japanese coverage, matching the
    // style already used by CapabilityAwareShotPlanner/CharacterContinuitySafetyPolicy)

    private static let reactionCues = [
        "reacts", "reaction", "notices", "realizes", "realises", "gasps",
        "flinches", "eyes widen", "looks up", "turns to look", "startled",
        "気づく", "驚く", "振り返る",
    ]
    private static let performanceCues = [
        "smiles", "smile", "pauses", "hesitates", "sighs", "gazes", "stares",
        "expression", "look toward camera", "looks at the camera", "tears up",
        "微笑む", "見つめる",
    ]
    private static let detailCues = [
        "close-up of", "close up of", "hand", "fingers", "object", "key",
        "detail of",
    ]
    private static let transitionCues = [
        "meanwhile", "later", "elsewhere", "cut to", "moments later",
    ]
    private static let revealCues = [
        "reveal", "revealed", "comes into view", "steps into frame",
        "appears", "emerges",
    ]

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
