import Foundation

/// Structured director output. LLM free text is never passed straight to
/// generation — it must land in this Codable first and validate.
struct OneShotPlan: Codable, Equatable {
    struct DialogueLine: Codable, Equatable {
        var speaker: String
        var text: String
        /// "native" (default) keeps the original language; "romanized" carries
        /// an optional fallback transliteration alongside.
        var language: String?
        var romanization: String?
        /// References an `ExplicitDialogueSource.id` (e.g. "D1") the Director
        /// chose to place in this shot. Set only when the model referenced a
        /// brief-supplied exact dialogue line rather than writing free text;
        /// `ExactDialogueReconciler` resolves it to the source's exact text
        /// before this ever reaches `PromptCompiler`. Absent for legacy
        /// plans and for shots with no explicit source to reference.
        var sourceId: String?
    }

    var camera: String              // framing + movement, e.g. "slow dolly-in, medium close-up"
    var action: String              // visible physical action, chronological
    var acting: String?             // performance/expression notes
    var motion: String?             // motion quality, pacing
    var lighting: String?           // light direction/mood
    var dialogue: [DialogueLine] = []
    var audioCues: [String] = []    // foley/sfx/ambience — no per-shot BGM
    var durationIntentSeconds: Double?

    /// Validation: a usable plan needs at least camera + action.
    var validationErrors: [String] {
        var errors: [String] = []
        if camera.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("camera is empty")
        }
        if action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("action is empty")
        }
        if let duration = durationIntentSeconds, duration <= 0 || duration > 20 {
            errors.append("durationIntentSeconds out of range (0, 20]")
        }
        return errors
    }

    var isValid: Bool { validationErrors.isEmpty }
}
