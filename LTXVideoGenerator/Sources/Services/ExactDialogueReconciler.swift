import Foundation

/// One exact user-supplied dialogue line extracted from a brief. `id` is
/// deterministic from extraction order ("D1", "D2", ...) — never a UUID —
/// so the same brief always yields the same IDs across repair attempts and
/// protocol negotiation. IDs exist only for Director semantic planning and
/// reconciliation; they are never exposed in a renderer prompt.
struct ExplicitDialogueSource: Equatable {
    var id: String
    var text: String
}

/// Conservative, fixed speech-verb vocabulary used only to decide whether a
/// quoted span is spoken dialogue rather than signage, a title, or other
/// on-screen text. Intentionally small and literal — this is not NLP/semantic
/// classification. When no marker is found, the quote is not treated as
/// dialogue: the policy fails conservative rather than guessing.
private enum SpeechContext {
    /// Checked immediately after a `「」`/`『』` closing quote — Japanese
    /// reports speech with the quotative "と" directly followed by a speech
    /// verb stem (covers common conjugations: 言う/言った/言って, etc.).
    /// Kanji-only by design: a hiragana labeling construction such as
    /// "「赤」という色" ("the color called red") does not match "言".
    static let japaneseVerbStems = ["言", "話", "喋", "叫", "尋ね", "答え", "つぶや", "ささや"]

    /// Checked immediately before an opening quote — English narrates speech
    /// with the verb first ('she says "..."'), unlike Japanese.
    static let englishVerbs: Set<String> = [
        "says", "said", "speaks", "spoke", "asks", "asked",
        "replies", "replied", "shouts", "shouted", "whispers", "whispered"
    ]

    static func hasJapaneseSpeechMarker(after closingIndex: String.Index, in text: String) -> Bool {
        guard closingIndex < text.endIndex else { return false }
        let tail = text[closingIndex...].drop { $0 == "、" || $0 == "," || $0.isWhitespace }
        guard tail.first == "と" else { return false }
        let afterTo = tail.dropFirst()
        // The verb need not be the very next character: ordinary Japanese
        // allows a short adverbial phrase between the quotative "と" and the
        // verb (「こんにちは」と日本語で話す — "says ... in Japanese"). Search the
        // rest of the clause instead of requiring immediate adjacency, but
        // stop at the next sentence boundary so a verb from a later,
        // unrelated sentence can never match.
        let clauseEnd = afterTo.firstIndex { "。！？\n".contains($0) } ?? afterTo.endIndex
        let clause = afterTo[afterTo.startIndex..<clauseEnd]
        return japaneseVerbStems.contains { clause.contains($0) }
    }

    static func hasEnglishSpeechMarker(before openingIndex: String.Index, in text: String) -> Bool {
        let head = text[text.startIndex..<openingIndex]
        let word = head
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .last
            .map { $0.lowercased() } ?? ""
        return englishVerbs.contains(word)
    }
}

/// Preserves the user's own exact quoted dialogue text through Director
/// planning. The Director model — Structured JSON or Text Protocol, One
/// Shot or Auto Movie — may decide WHERE dialogue goes (which shot, which
/// speaker, ordering among multiple lines), but it must never become the
/// source of truth for WHAT the user explicitly asked a character to say: a
/// model may punctuate, translate, or paraphrase a line it is only supposed
/// to relay.
enum ExactDialogueReconciler {

    /// Every exact span of user-quoted text in the brief, in the order it
    /// appears, with no speech-context filtering. `「」`, `『』`, straight
    /// `"..."`, and curly "..." are all recognized. Only the delimiter
    /// characters are removed — everything between them, including internal
    /// punctuation and whitespace, is kept character-for-character. Kept as
    /// a low-level primitive; `extractExplicitDialogueSources` is what
    /// reconciliation actually uses, since not every quote is spoken
    /// dialogue (a sign, a title, on-screen text).
    static func extractQuotedDialogue(from brief: String) -> [String] {
        rawQuoteMatches(in: brief).map(\.text)
    }

    /// Explicit spoken dialogue only: a quoted span is included when it has
    /// a recognized speech-verb marker immediately adjacent to it (Japanese
    /// "と" + verb stem after the quote, or an English speech verb before
    /// it). Quoted signage, titles, or on-screen text without a speech
    /// marker is excluded. IDs are assigned in document order.
    static func extractExplicitDialogueSources(from brief: String) -> [ExplicitDialogueSource] {
        var sources: [ExplicitDialogueSource] = []
        var nextID = 1
        for match in rawQuoteMatches(in: brief) {
            let isSpeech = SpeechContext.hasJapaneseSpeechMarker(after: match.fullRange.upperBound, in: brief)
                || SpeechContext.hasEnglishSpeechMarker(before: match.fullRange.lowerBound, in: brief)
            guard isSpeech else { continue }
            sources.append(ExplicitDialogueSource(id: "D\(nextID)", text: match.text))
            nextID += 1
        }
        return sources
    }

    private struct QuoteMatch {
        var text: String
        var fullRange: Range<String.Index>
    }

    private static func rawQuoteMatches(in brief: String) -> [QuoteMatch] {
        let pattern = "「([^」]*)」|『([^』]*)』|\"([^\"]*)\"|\u{201C}([^\u{201D}]*)\u{201D}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsBrief = brief as NSString
        let matches = regex.matches(in: brief, range: NSRange(location: 0, length: nsBrief.length))
        var results: [QuoteMatch] = []
        for match in matches {
            guard let fullRange = Range(match.range, in: brief) else { continue }
            for group in 1...4 {
                let groupRange = match.range(at: group)
                guard groupRange.location != NSNotFound else { continue }
                results.append(QuoteMatch(text: nsBrief.substring(with: groupRange), fullRange: fullRange))
                break
            }
        }
        return results.sorted { $0.fullRange.lowerBound < $1.fullRange.lowerBound }
    }

    /// Reconciles a flat, already-ordered list of Director-planned dialogue
    /// lines (across however many shots, in shot/line order) against the
    /// brief's explicit dialogue sources. Returns a list of the same length
    /// and order; only `.text` may ever change — never `.speaker`, since
    /// speaker association is the Director's call, not the extractor's.
    ///
    /// Precedence:
    /// 1. Any line carrying a valid `sourceId` is resolved by that ID,
    ///    regardless of its position — this is what makes it safe for the
    ///    Director to place source D2 in Shot 1 and D1 in Shot 3. A line
    ///    whose `sourceId` does not match a known source is left completely
    ///    unchanged rather than guessed at (never mapped to a different
    ///    source). Once ANY line in the set carries a `sourceId`, every line
    ///    is resolved this way — mixing ID-based and positional guessing in
    ///    the same set would itself be a guess.
    /// 2. When no line carries a `sourceId` at all (legacy output, e.g. an
    ///    older local model or a plan produced before this feature), the
    ///    original count-based positional reconciliation applies: sources
    ///    map 1:1 onto planned lines only when the counts match exactly.
    /// 3. No explicit sources in the brief, or an unresolved case above:
    ///    the Director's own dialogue is left completely untouched.
    static func reconcile(dialogueLines: [OneShotPlan.DialogueLine], brief: String) -> [OneShotPlan.DialogueLine] {
        let sources = extractExplicitDialogueSources(from: brief)
        guard !sources.isEmpty else { return dialogueLines }

        if dialogueLines.contains(where: { $0.sourceId != nil }) {
            let sourceMap = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.text) })
            return dialogueLines.map { line in
                guard let id = line.sourceId, let text = sourceMap[id] else { return line }
                var resolved = line
                resolved.text = text
                return resolved
            }
        }

        guard sources.count == dialogueLines.count else { return dialogueLines }
        return zip(dialogueLines, sources).map { line, source in
            var reconciled = line
            reconciled.text = source.text
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
