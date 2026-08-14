import Foundation

/// Decides how a shot's character context should be written.
///
/// A CUT or an opening shot has no previous frame, so the prompt has to say who
/// is on screen. A CONTINUE shot begins from the last frame of the shot before
/// it — the character, the clothes, the place and the light are *already in the
/// image*. Restating them makes the text compete with the picture, and a
/// measured run showed the text winning: a movie opened on a navy-uniformed
/// adventurer while every prompt said "Current costume: Beige trench coat, dark
/// jeans, boots", and the costume drifted toward the text within one shot
/// (D-071, D-072).
///
/// So a CONTINUE prompt carries one compact continuity statement plus whatever
/// genuinely *changes* — and nothing else.
///
/// This is deliberately **not** applied to the Temporal Bridge. There the input
/// is a character sheet that has to be destroyed, and telling the model to keep
/// everything consistent with it preserved the sheet as a physical panel in the
/// scene (D-073). Transform and continue are opposite instructions.
enum ContinuationPromptPolicy {

    enum Style: Equatable {
        /// Full appearance description. Opening shots, cuts, one-shots, T2V.
        case descriptive
        /// Continuity statement plus explicit changes only.
        case changeFocused
    }

    /// The image the shot starts from decides the style, not the shot index:
    /// a CONTINUE shot is exactly the case where a previous frame exists.
    ///
    /// `auto` stays descriptive. The run coordinator resolves it to continue or
    /// cut at generation time, and a prompt that assumed a source frame it does
    /// not get would be a continuation with nothing to continue from.
    static func style(for mode: ShotContinuityMode?) -> Style {
        switch mode {
        case .continueFromPrevious: return .changeFocused
        case .cut, .auto, .none: return .descriptive
        }
    }

    /// One compact statement. No "Face Lock", no "same person guaranteed" — the
    /// app does not claim identity guarantees it cannot make.
    static let continuityStatement =
        "The same subject and the existing visual state continue from the input frame."

    /// Builds the character context for a CONTINUE shot.
    ///
    /// - Parameters:
    ///   - before: character state entering the shot.
    ///   - after: character state once this shot's explicit changes are applied.
    ///
    /// Only fields that actually differ between the two are described. A shot
    /// that changes nothing about the character contributes no appearance text
    /// at all; a shot that genuinely changes the costume still says so, because
    /// suppressing a real story beat would be its own bug.
    static func changeFocusedContext(
        before: [ContinuityEngine.ResolvedCharacterState],
        after: [ContinuityEngine.ResolvedCharacterState]
    ) -> String {
        guard !after.isEmpty else { return "" }
        var parts = [continuityStatement]

        for state in after {
            let previous = before.first { $0.id == state.id }
            var changes: [String] = []

            if let previous, differs(previous.currentCostume, state.currentCostume) {
                changes.append("now wears \(state.currentCostume.cleaned)")
            } else if previous == nil, !state.currentCostume.cleaned.isEmpty {
                // No prior state to compare against: describing the costume once
                // is better than leaving a continuation ungrounded.
                changes.append("wears \(state.currentCostume.cleaned)")
            }
            if let previous, differs(previous.accessories, state.accessories) {
                changes.append("carries \(state.accessories.cleaned)")
            }
            if let previous, differs(previous.continuityNotes, state.continuityNotes),
               !state.continuityNotes.cleaned.isEmpty {
                changes.append(state.continuityNotes.cleaned.prefix160)
            }

            if !changes.isEmpty {
                parts.append("\(state.name) \(changes.joined(separator: ", ")).")
            }
        }
        return parts.joined(separator: " ")
    }

    private static func differs(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.cleaned.lowercased()
        let b = rhs.cleaned.lowercased()
        return a != b && !b.isEmpty
    }
}

private extension String {
    /// Local trimming helper: `trimmed` on String is fileprivate to the prompt
    /// compiler, and this policy deliberately does not reach into it.
    var cleaned: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var prefix160: String { count <= 160 ? self : String(prefix(160)) + "…" }
}
