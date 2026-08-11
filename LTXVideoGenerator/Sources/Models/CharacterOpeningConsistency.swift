import Foundation

/// Compares what a Character Sheet says the character *is* against what the
/// Opening Reference shows them looking like *in this scene*.
///
/// The two are different kinds of evidence and the app had no way to say so.
/// A Character Sheet is canonical identity; an Opening Reference is one moment —
/// a coat taken off, wet hair, a different angle. Treating the second as if it
/// redefined the first is how a movie ends up with the wrong character
/// described in every prompt (D-071).
///
/// This type only *reports*. It never rewrites canonical data and never changes
/// which image the first shot starts from.
struct CharacterOpeningConsistency: Codable, Equatable {

    enum Status: String, Codable {
        /// Every field with evidence on both sides agreed.
        case match
        /// Some fields agreed; others could not be compared.
        case partial
        /// At least one field positively contradicted the sheet.
        case conflict
        /// Not enough evidence on one or both sides to say anything.
        case insufficientEvidence
    }

    /// A single field's verdict. `unknown` is a first-class answer: refusing to
    /// guess is what keeps a partially visible frame from being read as a
    /// contradiction.
    enum FieldVerdict: String, Codable {
        case match, conflict, unknown
    }

    struct FieldComparison: Codable, Equatable {
        var field: String
        var verdict: FieldVerdict
        /// What the Character Sheet claimed, for the detail view.
        var canonical: String = ""
        /// What the Opening Reference showed.
        var observed: String = ""
    }

    var overallStatus: Status = .insufficientEvidence
    var comparisons: [FieldComparison] = []
    /// Managed path of the Opening Reference this compared against, so a
    /// Replace or Clear cannot leave a stale verdict behind.
    var openingSourceRelativePath: String = ""
    /// The Character Sheet asset the canonical side came from.
    var characterSheetAssetID: UUID?
    var characterID: UUID?
    var evaluatedAt: Date?
    /// Set when the sheet or the frame was too ambiguous to compare.
    var ambiguityReason: String = ""

    var conflicts: [FieldComparison] { comparisons.filter { $0.verdict == .conflict } }

    var summary: String {
        switch overallStatus {
        case .match: return "Consistent with the character sheet"
        case .partial: return "Mostly consistent — some details unclear"
        case .conflict:
            let names = conflicts.map(\.field).joined(separator: ", ")
            return "Differs from the character sheet: \(names)"
        case .insufficientEvidence: return "Not enough visible detail to compare"
        }
    }

    /// Only a positive contradiction is worth interrupting the user for.
    var isConflict: Bool { overallStatus == .conflict }
}

// MARK: - Comparison

/// Compares canonical identity evidence with scene observation.
///
/// Deliberately conservative and vocabulary-based rather than semantic: it only
/// reports a conflict when both sides name a recognised value from the *same*
/// mutually-exclusive set — two different hair colours, say. Anything else is
/// `unknown`. A false "conflict" would train the user to ignore the warning,
/// which is worse than staying quiet.
enum CharacterOpeningConsistencyResolver {

    /// Mutually exclusive colour words. Two different entries from this set on
    /// the same field is the one thing we treat as a real contradiction.
    static let colourTerms: Set<String> = [
        "black", "brown", "blonde", "blond", "red", "auburn", "ginger", "grey",
        "gray", "white", "silver", "blue", "navy", "green", "purple", "pink",
        "orange", "yellow", "cream", "beige", "tan", "burgundy", "teal",
    ]

    /// Hair length/shape words that cannot both be true at once.
    static let hairStyleTerms: Set<String> = [
        "ponytail", "bob", "braid", "braids", "bun", "pigtails", "twintails",
        "buzzcut", "shaved", "dreadlocks", "afro",
    ]

    /// Colour words that describe closely related shades. Treating these as a
    /// contradiction produces noise, not signal.
    static let equivalentColours: [Set<String>] = [
        ["blonde", "blond", "yellow"],
        ["grey", "gray", "silver"],
        ["brown", "auburn", "ginger"],
        ["cream", "beige", "white", "tan"],
        ["navy", "blue"],
    ]

    static func compare(
        character: BibleCharacter,
        appearance: OpeningReferenceAppearance?,
        now: Date = Date()
    ) -> CharacterOpeningConsistency {
        var result = CharacterOpeningConsistency()
        result.characterID = character.id
        result.evaluatedAt = now
        result.characterSheetAssetID = character.referenceAssets
            .first { $0.type == .characterSheet }?.id

        guard let appearance, appearance.isUsable else {
            result.overallStatus = .insufficientEvidence
            result.ambiguityReason = "The opening reference has no usable appearance analysis."
            return result
        }
        result.openingSourceRelativePath = appearance.sourceRelativePath

        // Several people in the opening frame means we cannot say which one the
        // sheet describes. Refusing is safer than mapping the wrong person.
        if appearance.subjectCount > 1 {
            result.overallStatus = .insufficientEvidence
            result.ambiguityReason =
                "\(appearance.subjectCount) people are visible in the opening reference."
            return result
        }

        result.comparisons = [
            compareField("Hair colour",
                         canonical: character.appearance.hair,
                         observed: appearance.hairDescription,
                         vocabulary: colourTerms),
            compareField("Hairstyle",
                         canonical: character.appearance.hair,
                         observed: appearance.hairDescription,
                         vocabulary: hairStyleTerms),
            compareField("Clothing colours",
                         canonical: character.defaultCostume,
                         observed: appearance.costumeSummary,
                         vocabulary: colourTerms),
            compareField("Accessories",
                         canonical: character.accessories,
                         observed: appearance.accessories,
                         vocabulary: colourTerms),
        ]

        let verdicts = result.comparisons.map(\.verdict)
        if verdicts.contains(.conflict) {
            result.overallStatus = .conflict
        } else if verdicts.allSatisfy({ $0 == .unknown }) {
            result.overallStatus = .insufficientEvidence
            result.ambiguityReason = "No comparable detail was described on both sides."
        } else if verdicts.contains(.unknown) {
            result.overallStatus = .partial
        } else {
            result.overallStatus = .match
        }
        return result
    }

    private static func compareField(
        _ name: String, canonical: String, observed: String, vocabulary: Set<String>
    ) -> CharacterOpeningConsistency.FieldComparison {
        var comparison = CharacterOpeningConsistency.FieldComparison(
            field: name, verdict: .unknown,
            canonical: canonical.trimmingCharacters(in: .whitespacesAndNewlines),
            observed: observed.trimmingCharacters(in: .whitespacesAndNewlines))
        let canonicalTerms = terms(in: canonical, vocabulary: vocabulary)
        let observedTerms = terms(in: observed, vocabulary: vocabulary)
        // Either side silent on this field means there is nothing to compare.
        guard !canonicalTerms.isEmpty, !observedTerms.isEmpty else { return comparison }

        if canonicalTerms.contains(where: { canonicalTerm in
            observedTerms.contains { areEquivalent(canonicalTerm, $0) }
        }) {
            comparison.verdict = .match
        } else {
            comparison.verdict = .conflict
        }
        return comparison
    }

    private static func terms(in text: String, vocabulary: Set<String>) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return Set(words).intersection(vocabulary)
    }

    private static func areEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        return equivalentColours.contains { $0.contains(lhs) && $0.contains(rhs) }
    }
}
