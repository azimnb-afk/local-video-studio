import Foundation

/// How likely a planned shot is to render as intended on the local LTX profile.
///
/// Two levels on purpose. A numeric score would imply a precision the
/// measurements do not support, and nothing downstream needs more than
/// "leave it alone" versus "steer it toward something that generates".
enum ShotCapabilityRisk: String, Equatable {
    case normal
    case highRisk
}

/// Steers Auto Movie's planned shots toward framings and actions that the local
/// model actually produces, before any rendering starts.
///
/// This exists because of a measured failure, not a theory. A planned detail
/// insert ("extreme close-up of the key entering the lock") after an inherited
/// medium-wide frame did not reach its framing at any conditioning strength, and
/// — the decisive control — the same prompt with no inherited image at all did
/// not produce the insert either. So the shot was beyond what this profile
/// renders. The remaining lever is to not plan that shot.
///
/// Re-measured at the product profile (768x512, 121 frames), that conclusion
/// splits in two. A large *camera* move is fine: a medium-wide inherited frame
/// reframes cleanly to a close-up of the same person at the reframe strength.
/// Fine *object* interaction still fails at every strength. So this pass
/// constrains detail and manipulation, not framing change.
///
/// What this pass is NOT: it does not ban close-ups, it does not score
/// cinematography, and it never deletes a story beat. It keeps the Director's
/// narrative intent and changes how that intent is shown — a key still goes into
/// a lock, but as a visible action at body scale rather than as a macro insert.
///
/// Scope: Auto Movie (Sora 2-like) only. Generate, One Shot, Storyboard manual
/// planning and CharacterBible are untouched.
enum CapabilityAwareShotPlanner {

    /// The largest framing step the no-LLM beat ladder takes between two
    /// consecutive split beats.
    ///
    /// This is a smoothness preference, not a feasibility limit — product-profile
    /// measurement showed larger jumps render fine at the reframe strength. It
    /// stays tied to the reframe threshold so a split movie's automatic camera
    /// progression keeps to steps the standard anchor can carry on its own.
    static var maxInheritedRankJump: Int { ContinuityStrengthResolver.reframeRankDistance - 1 }

    /// The tightest framing automatic planning will choose on its own when a
    /// shot has been flagged. `medium-close-up` still reads as a close shot of a
    /// person; it is the tightest rung that held together in the calibration.
    static let safestTightRank = 4

    /// Framing that keeps a multi-action chain visible.
    static let multiBeatRank = 3

    /// A shot at or above this many action clauses is asking for too much in one
    /// short take.
    static let maxVisibleBeats = 4

    /// What the pass did to one shot, kept for tests, scripts and the persisted
    /// per-shot reason.
    struct Adjustment: Equatable {
        var index: Int
        var risk: ShotCapabilityRisk
        var reasons: [String]
        var originalScale: String
        var effectiveScale: String
        var originalSummary: String
        var effectiveSummary: String
        /// True when the brief asked for this framing itself, so nothing was
        /// changed even though the shot is high risk.
        var honoursExplicitUserFraming: Bool
        /// True when the opening anchor rule edited this shot. Independent of
        /// `risk`: an opening that renders perfectly well can still hand a
        /// useless frame to the rest of the chain.
        var appliedOpeningAnchor: Bool = false

        var didChange: Bool {
            originalScale != effectiveScale || originalSummary != effectiveSummary
        }

        /// One line for a debug dump: original plan, why, effective plan.
        var explanation: String {
            var text = "shot \(index + 1): \(risk.rawValue)"
            if !reasons.isEmpty { text += " (" + reasons.joined(separator: "; ") + ")" }
            if appliedOpeningAnchor {
                text += " — opening anchor: subject kept readable for the chain"
                return text
            }
            if honoursExplicitUserFraming {
                text += " — left as planned, the brief asked for this framing"
            } else if didChange {
                text += " — \(originalScale) → \(effectiveScale)"
            } else {
                text += " — no change needed"
            }
            return text
        }
    }

    // MARK: - Vocabulary

    /// Framing language that belongs to the camera fields, not to the action.
    /// Stripped from the action text so the prompt stops asking twice for a
    /// framing the pass has already decided.
    ///
    /// Compared with hyphens flattened to spaces, so "extreme close-up of",
    /// "extreme-close-up of" and "extreme close up of" are all one phrase.
    private static let framingPrefixes: [String] = (
        ShotScaleLadder.scales.flatMap { scale -> [String] in
            ["\(scale) of ", "\(scale) on ", "\(scale) shot of ", "\(scale) shot on "]
        } + [
            "macro shot of ", "macro of ", "insert shot of ", "insert of ",
            "detail shot of ", "detail of ", "cutaway to ",
        ]
    ).map { $0.replacingOccurrences(of: "-", with: " ") }

    /// Words that push the model toward detail it cannot resolve at this size.
    private static let miniaturizers = [
        "tiny", "small", "minute", "microscopic", "miniature", "fine",
        "narrow", "thin", "delicate",
    ]

    /// Verbs describing manipulation that only reads at macro scale.
    private static let fineActionVerbs = [
        "insert", "inserts", "inserting",
        "press", "presses", "pressing",
        "align", "aligns", "aligning",
        "twist", "twists", "twisting",
        "slot", "slots", "slotting",
        "thread", "threads", "threading",
        "pinch", "pinches", "pinching",
        "flick", "flicks", "flicking",
        "tap", "taps", "tapping",
    ]

    /// Body parts that make an action a manipulation rather than a movement.
    private static let manipulators = [
        "finger", "fingers", "fingertip", "fingertips", "thumb",
        "hand", "hands", "knuckle", "nail",
    ]

    /// Framing the user asked for in their own words. Present in the brief, this
    /// is intent rather than a planner guess, and the pass stands down.
    private static let explicitFramingRequests: [String] = [
        "extreme close-up", "extreme closeup", "extreme close up",
        "macro shot", "macro lens", "insert shot", "detail shot",
        "クローズアップ", "アップ", "寄りの画", "マクロ",
    ]

    // MARK: - Entry point

    /// Applies the pass to a Director draft. Returns the effective shots and one
    /// adjustment record per shot, in the same order.
    ///
    /// `brief` is read only to detect framing the user asked for explicitly.
    static func plan(
        shots: [StoryboardDirector.ShotPlanDraft],
        brief: String
    ) -> (shots: [StoryboardDirector.ShotPlanDraft], adjustments: [Adjustment]) {
        let userAskedForTightFraming = briefRequestsTightFraming(brief)
        // A single-shot draft is the input to beat splitting, not a shot as it
        // will be rendered, so its action chain is a duration question that the
        // splitter answers — not a shot-design problem for this pass.
        let isSplitCandidate = shots.count == 1

        var effective: [StoryboardDirector.ShotPlanDraft] = []
        var adjustments: [Adjustment] = []

        // The opening shot is the only one with no frame to inherit, and its
        // final frame is what the whole chain inherits. An opening that puts
        // nobody usable on screen cannot be recovered by any later shot, so it
        // gets one narrow correction regardless of how it renders on its own.
        let openingAsksForTinySubject = !shots.isEmpty
            && opensWithMiniaturizedSubject(shots[0].summary)
            && !opensWithMiniaturizedSubject(brief)

        for (index, draft) in shots.enumerated() {
            let previous = effective.last
            let scale = draft.shotScale ?? "medium"
            let reasons = risks(
                previous: previous,
                current: draft,
                mayInherit: index > 0 && mayInheritFrame(previous: previous, current: draft),
                allowBeatRule: !isSplitCandidate
            )

            let anchorApplies = index == 0 && openingAsksForTinySubject

            guard !reasons.isEmpty else {
                var opening = draft
                if anchorApplies { opening.summary = openingAnchorSummary(draft.summary) }
                effective.append(opening)
                adjustments.append(Adjustment(
                    index: index, risk: .normal, reasons: [],
                    originalScale: scale, effectiveScale: scale,
                    originalSummary: draft.summary, effectiveSummary: opening.summary,
                    honoursExplicitUserFraming: false,
                    appliedOpeningAnchor: anchorApplies
                ))
                continue
            }

            guard !userAskedForTightFraming else {
                // The brief named this kind of framing. Recorded as risky, but
                // deliberately left alone: an automatic policy should not delete
                // a visual choice the user made themselves.
                effective.append(draft)
                adjustments.append(Adjustment(
                    index: index, risk: .highRisk, reasons: reasons,
                    originalScale: scale, effectiveScale: scale,
                    originalSummary: draft.summary, effectiveSummary: draft.summary,
                    honoursExplicitUserFraming: true
                ))
                continue
            }

            var adjusted = draft
            adjusted.shotScale = saferScale(
                previous: previous, current: draft, reasons: reasons
            )
            adjusted.summary = saferSummary(draft.summary, reasons: reasons)
            if anchorApplies { adjusted.summary = openingAnchorSummary(adjusted.summary) }
            effective.append(adjusted)
            adjustments.append(Adjustment(
                index: index, risk: .highRisk, reasons: reasons,
                originalScale: scale, effectiveScale: adjusted.shotScale ?? scale,
                originalSummary: draft.summary, effectiveSummary: adjusted.summary,
                honoursExplicitUserFraming: false,
                appliedOpeningAnchor: anchorApplies
            ))
        }
        return (effective, adjustments)
    }

    // MARK: - Risk

    /// Every reason this shot is hard to render, empty when it is fine.
    static func risks(
        previous: StoryboardDirector.ShotPlanDraft?,
        current: StoryboardDirector.ShotPlanDraft,
        mayInherit: Bool,
        allowBeatRule: Bool = true
    ) -> [String] {
        var reasons: [String] = []
        let currentRank = ShotScaleLadder.rank(of: current.shotScale ?? "medium")

        // A large framing jump used to be treated as a capability risk here,
        // on the strength of a calibration that measured 25-frame (1.04 s)
        // shots. Re-measured at the product profile — 768x512, 121 frames — a
        // medium-wide inherited frame reframes cleanly to a close-up at the
        // reframe strength of 0.5, keeping the person, wardrobe and set. So a
        // large camera move is no longer classed as risky, and clamping it here
        // was actively harmful: shrinking the jump to two rungs made the
        // strength resolver choose the standard 0.8, which is the one setting
        // that does NOT reframe at this resolution, so the shot got neither the
        // planned framing nor the strength that would have delivered it.
        //
        // What did NOT survive re-measurement is fine object interaction, which
        // still fails at every strength. That is what the rules below constrain.

        // B. A detail insert: the tightest rung on the ladder, which the
        //    calibration could not reach from an inherited frame and which the
        //    text-to-video control did not produce either.
        if currentRank == ShotScaleLadder.tightestRank {
            reasons.append("detail-insert framing (\(current.shotScale ?? ""))")
        }

        // C. Fine manipulation: a hand or finger operating something small. The
        //    beat is fine; asking the model to resolve the mechanism is not.
        if describesFineManipulation(current.summary) {
            reasons.append("fine hand/object manipulation")
        }

        // D. Too much in one short take. Splitting is not this pass's job, but
        //    it can at least stop the frame tightening around a chain of beats.
        if allowBeatRule {
            let beats = visibleBeatCount(in: current.summary)
            if beats >= maxVisibleBeats {
                reasons.append("\(beats) action beats in one short shot")
            }
        }
        return reasons
    }

    /// Whether this boundary is likely to carry the previous shot's frame.
    ///
    /// Deliberately generous: reconciliation runs later and promotes unmarked
    /// boundaries inside one scene, so assuming inheritance unless the story has
    /// visibly moved matches what generation will do. An explicit scene change
    /// or a step across a threshold is exactly what reconciliation refuses to
    /// promote, so those are treated as genuine cuts here too.
    static func mayInheritFrame(
        previous: StoryboardDirector.ShotPlanDraft?,
        current: StoryboardDirector.ShotPlanDraft
    ) -> Bool {
        guard let previous else { return false }
        if (current.continuity ?? "").lowercased() == "continue" { return true }
        let hasSceneDirective = (current.explicitChanges ?? []).contains { change in
            ContinuityReconciler.sceneChangeDirectives.contains { change.hasPrefix($0) }
        }
        if hasSceneDirective { return false }
        return !SceneThreshold.crosses(
            previous.summary + " " + previous.title,
            current.summary + " " + current.title
        )
    }

    /// True when the action is a hand or finger operating something, rather than
    /// a movement of the whole subject.
    static func describesFineManipulation(_ summary: String) -> Bool {
        let words = tokens(of: summary)
        let hasFineVerb = words.contains { fineActionVerbs.contains($0) }
        guard hasFineVerb else { return false }
        let hasManipulator = words.contains { manipulators.contains($0) }
        let hasMiniaturizer = words.contains { miniaturizers.contains($0) }
        // A verb alone is not enough — "presses on toward the gate" is a walk.
        // It becomes fine manipulation when a hand does it, or when the thing
        // being operated is described as small.
        return hasManipulator || hasMiniaturizer
    }

    /// How many distinct visible actions the summary asks for.
    ///
    /// A blunt clause count: sentences, plus comma-separated clauses, which is
    /// how a chained action ("she stops, takes out the keys, opens the door")
    /// is actually written. It over-counts a heavily punctuated description,
    /// which is why the only consequences are a wider frame and an added note —
    /// never a deleted beat.
    static func visibleBeatCount(in summary: String) -> Int {
        var text = summary
        for separator in [", then ", " and then ", "; then ", ", and then "] {
            text = text.replacingOccurrences(of: separator, with: ".", options: .caseInsensitive)
        }
        return text
            .components(separatedBy: CharacterSet(charactersIn: ".;,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.rangeOfCharacter(from: .letters) != nil }
            .count
    }

    // MARK: - Rewrite

    /// The framing this shot will actually be planned at.
    static func saferScale(
        previous: StoryboardDirector.ShotPlanDraft?,
        current: StoryboardDirector.ShotPlanDraft,
        reasons: [String]
    ) -> String {
        let currentScale = current.shotScale ?? "medium"
        guard var target = ShotScaleLadder.rank(of: currentScale) else { return currentScale }

        if reasons.contains(where: { $0.hasPrefix("detail-insert") || $0.hasPrefix("fine ") }) {
            target = min(target, safestTightRank)
        }
        if reasons.contains(where: { $0.contains("action beats") }) {
            // Keep the frame wide enough to show the whole chain; never use this
            // rule to push a shot tighter than it was planned.
            target = min(target, multiBeatRank)
        }
        return ShotScaleLadder.name(atRank: target)
    }

    /// The action text this shot will actually be planned with.
    ///
    /// The beat survives verbatim. What is removed is the language that asks for
    /// a macro rendering of it, and what is added is a note that the action
    /// should stay visible at the scale the shot is now framed at.
    static func saferSummary(_ summary: String, reasons: [String]) -> String {
        var text = stripFramingPrefix(summary)
        text = removeMiniaturizers(from: text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = summary.trimmingCharacters(in: .whitespacesAndNewlines) }

        var directives: [String] = []
        if reasons.contains(where: { $0.hasPrefix("detail-insert") || $0.hasPrefix("fine ") }) {
            directives.append("The action stays clearly visible at body scale.")
        }
        if reasons.contains(where: { $0.contains("action beats") }) {
            directives.append("Show this as one continuous action.")
        }
        guard !directives.isEmpty else { return text }
        let terminated = text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?")
            ? text : text + "."
        return ([terminated] + directives).joined(separator: " ")
    }

    /// Removes a leading "extreme close-up of ", "macro shot of " and friends.
    /// Only a prefix is touched: framing named mid-sentence is part of a
    /// description the pass has no business rewriting.
    static func stripFramingPrefix(_ summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Flattening hyphens keeps the length identical, so an offset measured
        // on the probe is still valid on the original text.
        let lower = trimmed.lowercased().replacingOccurrences(of: "-", with: " ")
        for article in ["", "a ", "an ", "the "] {
            for phrase in framingPrefixes {
                let candidate = article + phrase
                guard lower.hasPrefix(candidate) else { continue }
                let rest = String(trimmed.dropFirst(candidate.count))
                return capitalizingFirstLetter(rest)
            }
        }
        return trimmed
    }

    /// Drops size adjectives that ask for detail the profile cannot resolve.
    static func removeMiniaturizers(from text: String) -> String {
        var result = text
        for word in miniaturizers {
            for variant in ["\(word) ", "\(word.capitalized) "] {
                result = result.replacingOccurrences(
                    of: "\\b\(NSRegularExpression.escapedPattern(for: variant))",
                    with: "",
                    options: [.regularExpression]
                )
            }
        }
        return result.replacingOccurrences(of: "  ", with: " ")
    }

    // MARK: - Opening anchor

    /// Phrases that shrink the protagonist inside the frame. These describe the
    /// subject's size on screen, not the world, so removing them does not change
    /// what happens in the shot — only how much of the frame the person occupies.
    private static let subjectMiniaturizingPhrases = [
        "figure small", "small figure", "tiny figure",
        "small against", "tiny against", "dwarfed by", "dwarfed against",
        "小さく", "小さな人影",
    ]

    /// Removes language that makes the protagonist tiny in the opening shot.
    ///
    /// Measured, not assumed. The Director's own opening summary contained "her
    /// figure small against the towering walls"; that shot rendered the subject
    /// as a few pixels walking away, and because the chain inherits the opening's
    /// final frame, shots 2-4 faithfully continued a composition with nobody
    /// usable in it. Deleting that one clause — with no other guidance added —
    /// produced an opening that ends with the subject large, centred and
    /// readable, and a following shot that keeps her.
    ///
    /// Deliberately narrow. Camera scale is untouched, so a wide or extreme-wide
    /// establishing shot stays exactly as planned; the subject is not turned
    /// toward the camera; no ending state is dictated. Explicit composition
    /// guidance and ending-state text were both tested and neither beat simple
    /// removal, so neither is added.
    static func openingAnchorSummary(_ summary: String) -> String {
        var text = summary
        for phrase in subjectMiniaturizingPhrases {
            guard text.range(of: phrase, options: .caseInsensitive) != nil else { continue }
            text = removeClause(containing: phrase, from: text)
        }
        return text
    }

    /// True when the opening asks for a visually tiny protagonist.
    static func opensWithMiniaturizedSubject(_ summary: String) -> Bool {
        subjectMiniaturizingPhrases.contains {
            summary.range(of: $0, options: .caseInsensitive) != nil
        }
    }

    /// Drops the comma-delimited clause that carries the phrase, keeping the
    /// rest of the sentence intact. Falls back to removing just the phrase when
    /// the clause is the whole sentence, so an action is never deleted.
    private static func removeClause(containing phrase: String, from text: String) -> String {
        let parts = text.components(separatedBy: ", ")
        if parts.count > 1 {
            let kept = parts.filter { $0.range(of: phrase, options: .caseInsensitive) == nil }
            if !kept.isEmpty, kept.count < parts.count {
                var result = kept.joined(separator: ", ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.hasSuffix(".") && !result.hasSuffix("!") && !result.hasSuffix("?") {
                    result += "."
                }
                return result
            }
        }
        return text.replacingOccurrences(of: phrase, with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Explicit user intent

    /// True when the brief itself names a tight framing, in English or Japanese.
    static func briefRequestsTightFraming(_ brief: String) -> Bool {
        let lower = brief.lowercased()
        return explicitFramingRequests.contains { lower.contains($0) }
    }

    // MARK: - Helpers

    private static func tokens(of text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
