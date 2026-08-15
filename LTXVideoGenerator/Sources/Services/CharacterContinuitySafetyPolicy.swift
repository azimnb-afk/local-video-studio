import Foundation

/// Directs Auto Movie shot planning to reduce character identity drift across takes.
///
/// Diffusion models are prone to identity drift when a character's face disappears
/// for extended periods or when framing jumps abruptly. This policy guides the
/// Director to plan shots that keep facial and clothing evidence accessible,
/// split shots before prolonged identity loss, use gradual reframing, and maintain
/// concise visual identity descriptions across shots without altering generation architecture.
public enum CharacterContinuitySafetyPolicy {

    /// Detailed instruction injected into the Director system / planning prompts for Structured JSON.
    public static let directorInstruction = """
    CHARACTER CONTINUITY SAFETY (AUTO MOVIE):
    For character-driven stories, design shots to preserve recognizable visual identity across sequential takes:
    1. Keep face and identity evidence (hair, face, key clothing) visible whenever possible; avoid prolonged face absence, long full-back-only shots, or long empty-frame intervals within a continuous sequence.
    2. If a character must leave the frame, turn away, or be obscured, split the shot BEFORE identity information is lost, ending the shot while the character is still identifiable so downstream continuation remains grounded.
    3. Re-establish clear face and upper-body framing early in subsequent shots after any reframing or orientation change.
    4. Use gradual camera reframing (e.g. medium -> medium-close-up or medium-wide -> medium) rather than extreme abrupt jumps (e.g. extreme wide to extreme close-up).
    5. Focus the sequence on one cohesive location and continuous action; do not attempt massive multi-location scene jumps in one continuous Auto Movie.
    6. Explicit user intent always wins: if the user explicitly asks for a back view, silhouette, full exit, or extreme wide shot, respect that request.
    """

    /// Compact instruction for short templates (Text Protocol and repair turns).
    public static let compactDirectorInstruction = """
    CHARACTER CONTINUITY SAFETY: Keep face/hair/costume visible across shots; avoid prolonged face absence; split shots before characters leave or disappear; use gradual camera reframing; explicit user intent overrides these rules.
    """

    private static let explicitIntentPatterns: [String] = [
        "show only her back", "show only his back", "show only their back",
        "from behind only", "back view only", "facing away entirely",
        "silhouette only", "complete silhouette", "silhouette of", "silhouette",
        "leaves frame completely", "leaves the frame completely",
        "walks away into distance", "extreme wide only", "never show face",
        "顔を見せない", "後ろ姿のみ", "背中のみ", "シルエットのみ", "完全に画面外"
    ]

    /// Detects if the user explicitly asked for shot conditions that would otherwise
    /// be discouraged by the continuity safety heuristics (Rule 15: USER INTENT MUST WIN).
    public static func isExplicitUserIntentOverride(in text: String) -> Bool {
        let normalized = text.lowercased()
        return explicitIntentPatterns.contains { normalized.contains($0) }
    }

    /// Evaluates whether an action summary describes a prolonged absence or full departure.
    public static func isProlongedDisappearance(_ summary: String) -> Bool {
        let lower = summary.lowercased()
        let exitPhrases = [
            "leaves the frame completely",
            "leaves frame completely",
            "leaves the frame and disappears",
            "leaves frame and disappears",
            "leaves frame, camera stays on empty",
            "walks out of view for a long time",
            "completely disappears from view",
            "vacant empty hallway for several seconds"
        ]
        return exitPhrases.contains { lower.contains($0) }
    }

    /// Rewrites a prolonged disappearance summary to end while the subject remains identifiable,
    /// fulfilling Rule 2 (Split before identity information is lost).
    public static func safeContinuitySummary(_ summary: String) -> String {
        var text = summary
        let exitReplacements: [(pattern: String, replacement: String)] = [
            ("leaves the frame completely, the camera stays on the empty corridor", "approaches the corridor exit, keeping facial and clothing features visible before the shot ends"),
            ("leaves the frame completely", "approaches the frame boundary while remaining visible"),
            ("leaves the frame and disappears", "moves toward the frame edge while remaining identifiable"),
            ("leaves frame, camera stays on empty", "moves forward while keeping identity evidence in frame"),
            ("completely disappears from view", "moves toward the exit with visible identity cues"),
            ("vacant empty hallway for several seconds", "active subject in the corridor")
        ]
        for (pattern, replacement) in exitReplacements {
            if let range = text.range(of: pattern, options: .caseInsensitive) {
                text.replaceSubrange(range, with: replacement)
            }
        }
        return text
    }
}
