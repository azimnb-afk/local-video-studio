import Foundation

/// Preserves the user's own exact quoted dialogue text through Director
/// planning. The Director model — Structured JSON or Text Protocol, One
/// Shot or Auto Movie — may decide WHERE dialogue goes (which shot, which
/// speaker, ordering among multiple lines), but it must never become the
/// source of truth for WHAT the user explicitly asked a character to say: a
/// model may punctuate, translate, or paraphrase a line it is only supposed
/// to relay.
///
/// Deliberately conservative: reconciliation only replaces model-produced
/// dialogue text when a *clear* structural correspondence exists — the same
/// number of user-quoted lines in the brief as Director-planned dialogue
/// lines, in the same order. A count mismatch is ambiguous (which planned
/// line maps to which quote is not decidable without guessing) and is left
/// completely untouched rather than partially reconciled, so a line can
/// never be silently reassigned to the wrong shot or the wrong quote.
enum ExactDialogueReconciler {

    /// Every exact span of user-quoted dialogue in the brief, in the order
    /// it appears. `「」`, `『』`, straight `"..."`, and curly "..." are all
    /// recognized. Only the delimiter characters are removed — everything
    /// between them, including internal punctuation and whitespace, is kept
    /// character-for-character.
    static func extractQuotedDialogue(from brief: String) -> [String] {
        let pattern = "「([^」]*)」|『([^』]*)』|\"([^\"]*)\"|\u{201C}([^\u{201D}]*)\u{201D}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsBrief = brief as NSString
        let matches = regex.matches(in: brief, range: NSRange(location: 0, length: nsBrief.length))
        var entries: [(location: Int, text: String)] = []
        for match in matches {
            for group in 1...4 {
                let range = match.range(at: group)
                guard range.location != NSNotFound else { continue }
                entries.append((location: match.range.location, text: nsBrief.substring(with: range)))
                break
            }
        }
        return entries.sorted { $0.location < $1.location }.map(\.text)
    }

    /// Reconciles a flat, already-ordered list of Director-planned dialogue
    /// lines (across however many shots, in shot/line order) against the
    /// brief's exact quoted sources. Returns a list of the same length and
    /// order; only `.text` may ever change — never `.speaker`, since speaker
    /// association is the Director's call, not the extractor's.
    static func reconcile(dialogueLines: [OneShotPlan.DialogueLine], brief: String) -> [OneShotPlan.DialogueLine] {
        let sources = extractQuotedDialogue(from: brief)
        // No explicit quoted dialogue in the brief: nothing to reconcile
        // against, existing Director behavior is unchanged.
        guard !sources.isEmpty else { return dialogueLines }
        guard sources.count == dialogueLines.count else { return dialogueLines }
        return zip(dialogueLines, sources).map { line, source in
            var reconciled = line
            reconciled.text = source
            return reconciled
        }
    }

    /// Multi-shot convenience for Auto Movie/Storyboard: flattens dialogue
    /// across every shot in shot order, reconciles once against the brief,
    /// then scatters the result back into each shot's own dialogue array
    /// without changing any shot's line count or order.
    static func reconcile(shots: [StoryboardDirector.ShotPlanDraft], brief: String) -> [StoryboardDirector.ShotPlanDraft] {
        let flat = shots.flatMap { $0.dialogue ?? [] }
        guard !flat.isEmpty else { return shots }
        let reconciled = reconcile(dialogueLines: flat, brief: brief)
        guard reconciled.count == flat.count else { return shots }
        var cursor = 0
        return shots.map { shot in
            guard let count = shot.dialogue?.count, count > 0 else { return shot }
            var updated = shot
            updated.dialogue = Array(reconciled[cursor..<(cursor + count)])
            cursor += count
            return updated
        }
    }
}
