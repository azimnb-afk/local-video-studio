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
    /// Version of the comparator that produced this verdict. `nil` means it
    /// predates versioning. Comparator semantics can change — this is what
    /// lets an old verdict be safely recomputed from already-persisted
    /// evidence rather than trusted as still accurate. See
    /// `OpeningReferenceSync.refreshConsistencyIfOutdated`.
    var resolverVersion: Int?

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

    /// Bumped whenever comparator semantics change enough that an old
    /// persisted verdict might no longer be accurate. A version mismatch
    /// triggers an offline recompute from already-persisted evidence — see
    /// `OpeningReferenceSync.refreshConsistencyIfOutdated`. Never a new
    /// Vision call, and canonical Character Bible data is never touched.
    ///
    /// v2: Accessories compares by recognised object, not by whole-field
    /// colour bag — a colour word near "flag" no longer gets compared against
    /// an unrelated colour word near "belt". Added gold/golden normalisation.
    static let currentVersion = 2

    /// Mutually exclusive colour words. Two different entries from this set on
    /// the same field is the one thing we treat as a real contradiction.
    static let colourTerms: Set<String> = [
        "black", "brown", "blonde", "blond", "red", "auburn", "ginger", "grey",
        "gray", "white", "silver", "blue", "navy", "green", "purple", "pink",
        "orange", "yellow", "cream", "beige", "tan", "burgundy", "teal",
        "gold", "golden",
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
        ["gold", "golden"],
    ]

    /// Recognised garment/accessory nouns, used only to tell "same object"
    /// from "different object" apart — not a costume taxonomy. Two
    /// descriptions that both mention "flag" can be compared; a "flag" and a
    /// "belt" cannot. Colour proximity to an unrelated noun is exactly what
    /// produced a real false Accessories conflict: a canonical "flag (blue…)"
    /// read as contradicting an observed "brown belt", though a flag and a
    /// belt are not the same thing.
    static let accessoryObjectTerms: Set<String> = [
        "flag", "ribbon", "bow", "belt", "cape", "coat", "jacket", "shirt",
        "blouse", "vest", "skirt", "pants", "trousers", "boots", "shoes",
        "hat", "glasses", "necklace", "earrings", "sword", "spear", "bag", "watch",
    ]

    static func compare(
        character: BibleCharacter,
        appearance: OpeningReferenceAppearance?,
        now: Date = Date()
    ) -> CharacterOpeningConsistency {
        var result = CharacterOpeningConsistency()
        result.resolverVersion = currentVersion
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
            compareAccessoryField(
                canonical: character.accessories,
                observed: appearance.accessories),
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

    /// Accessories compares by *object*, not by whole-field colour bag. The
    /// old approach found any colour word anywhere in the field and matched
    /// it against any colour word anywhere in the other field — which read
    /// "flag (blue with gold star emblem)" against "brown leather belt" as a
    /// colour contradiction, though a flag and a belt are not the same thing.
    ///
    /// A verdict now requires the same recognised object on both sides;
    /// differing attributes on that shared object are the only thing counted
    /// as a contradiction. No shared recognised object → unknown, regardless
    /// of what colours are present on either side.
    private static func compareAccessoryField(
        canonical: String, observed: String
    ) -> CharacterOpeningConsistency.FieldComparison {
        var comparison = CharacterOpeningConsistency.FieldComparison(
            field: "Accessories", verdict: .unknown,
            canonical: canonical.trimmingCharacters(in: .whitespacesAndNewlines),
            observed: observed.trimmingCharacters(in: .whitespacesAndNewlines))

        let canonicalObjects = objectColourMentions(in: canonical)
        let observedObjects = objectColourMentions(in: observed)
        let sharedObjects = Set(canonicalObjects.keys).intersection(observedObjects.keys)
        guard !sharedObjects.isEmpty else { return comparison }

        var sawMatch = false
        var sawConflict = false
        for object in sharedObjects {
            let canonicalColours = canonicalObjects[object] ?? []
            let observedColours = observedObjects[object] ?? []
            // Neither side described a colour for this object: its presence
            // on both sides is not a contradiction, but it is not positive
            // evidence of a match either — skip it rather than guess.
            guard !canonicalColours.isEmpty, !observedColours.isEmpty else { continue }
            if canonicalColours.contains(where: { c in
                observedColours.contains { areEquivalent(c, $0) }
            }) {
                sawMatch = true
            } else {
                sawConflict = true
            }
        }
        if sawConflict {
            comparison.verdict = .conflict
        } else if sawMatch {
            comparison.verdict = .match
        }
        return comparison
    }

    /// Maps each recognised object mentioned in `text` to the colour words
    /// found in the same clause. Splits on sentence/list punctuation rather
    /// than a fixed word window, because these fields are written as comma-
    /// or period-separated item lists ("flag (blue…), sword/spear (…)") — the
    /// punctuation boundary is a more reliable "same item" signal than raw
    /// token proximity.
    private static func objectColourMentions(in text: String) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: ",.;"))
        for clause in clauses {
            let words = clause.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            let objects = words.filter { accessoryObjectTerms.contains($0) }
            guard !objects.isEmpty else { continue }
            let colours = Set(words.filter { colourTerms.contains($0) })
            for object in objects {
                result[object, default: []].formUnion(colours)
            }
        }
        return result
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
