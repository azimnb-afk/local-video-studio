import Foundation

/// What the Opening Reference image actually *shows* about the protagonist.
///
/// This exists because the Director used to invent a costume from the brief
/// text alone and persist it as the Character Bible. A movie could therefore
/// open on a navy-uniformed adventurer while every compiled shot prompt said
/// "Current costume: Beige trench coat, dark jeans, boots" — the image and the
/// text disagreed, and over a shot the text won (D-071).
///
/// Only what is visible is recorded. Nothing is inferred: no shoes that are out
/// of frame, no age, no ethnicity, no identity.
struct OpeningReferenceAppearance: Codable, Equatable {

    enum Status: String, Codable {
        /// A single clear subject was described.
        case analysed
        /// Local Vision was not reachable, or no vision-capable model exists.
        case unavailable
        /// The model answered, but not with anything usable.
        case failed
        /// More than one person, or no confident primary subject. Deliberately
        /// **not** merged into the Bible — guessing which person is the
        /// protagonist is worse than saying nothing.
        case ambiguous
    }

    var status: Status = .unavailable
    /// Project-relative path of the analysed managed asset. Derived state is
    /// only trusted while it still points at the image currently attached.
    var sourceRelativePath: String = ""
    var faceVisible: Bool = false
    var hairDescription: String = ""
    var clothingDescription: String = ""
    var outerwear: String = ""
    var accessories: String = ""
    var silhouetteDescription: String = ""
    var distinctiveTraits: String = ""
    var subjectCount: Int = 0
    var analysisModel: String = ""
    var analysedAt: Date?
    var notes: String = ""

    var isUsable: Bool { status == .analysed }

    /// The costume line a prompt would carry, built only from what was seen.
    var costumeSummary: String {
        [clothingDescription, outerwear]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Short line for the UI.
    var statusDescription: String {
        switch status {
        case .analysed: return "Analysed locally"
        case .unavailable: return "Local Vision unavailable"
        case .failed: return "Could not be analysed"
        case .ambiguous: return "Several people visible — not applied"
        }
    }
}

// MARK: - Effective appearance

/// Decides what a character actually looks like for *this* movie.
///
/// Precedence, highest first:
///   1. explicit user-authored Bible appearance / costume
///   2. what the Opening Reference visibly shows
///   3. the Director's auto-generated guess
///   4. no claim at all
///
/// The rule that matters is (2) over (3): a guess derived from brief text must
/// never override the image the user actually chose to open on.
enum EffectiveAppearanceResolver {

    /// Per-field origin, so tests can assert *why* a value won rather than only
    /// that it did.
    enum Origin: String, Equatable {
        case userAuthored
        case openingReference
        case directorGenerated
        case none
    }

    struct Resolution: Equatable {
        var costume: String
        var costumeOrigin: Origin
        var hair: String
        var hairOrigin: Origin
        var accessories: String
        var accessoriesOrigin: Origin
        var distinguishingFeatures: String
        var distinguishingFeaturesOrigin: Origin
    }

    /// - Parameters:
    ///   - existing: the Bible entry as it stands.
    ///   - isUserAuthored: whether that entry came from a person rather than
    ///     from the Director. An auto-generated placeholder may be superseded;
    ///     something the user typed or imported may not.
    ///   - appearance: what the Opening Reference showed.
    static func resolve(
        existing: BibleCharacter,
        isUserAuthored: Bool,
        appearance: OpeningReferenceAppearance?
    ) -> Resolution {
        let reference = (appearance?.isUsable == true) ? appearance : nil

        func pick(user: String, fromReference: String) -> (String, Origin) {
            let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
            let seen = fromReference.trimmingCharacters(in: .whitespacesAndNewlines)
            // A user-authored value always wins, and so does any existing value
            // when there is no image evidence to replace it with.
            if isUserAuthored, !user.isEmpty { return (user, .userAuthored) }
            if !seen.isEmpty { return (seen, .openingReference) }
            if !user.isEmpty { return (user, .directorGenerated) }
            return ("", .none)
        }

        let costume = pick(user: existing.defaultCostume,
                           fromReference: reference?.costumeSummary ?? "")
        let hair = pick(user: existing.appearance.hair,
                        fromReference: reference?.hairDescription ?? "")
        let accessories = pick(user: existing.accessories,
                               fromReference: reference?.accessories ?? "")
        let features = pick(
            user: existing.appearance.distinguishingFeatures,
            fromReference: [reference?.distinctiveTraits ?? "",
                            reference?.silhouetteDescription ?? ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", "))

        return Resolution(
            costume: costume.0, costumeOrigin: costume.1,
            hair: hair.0, hairOrigin: hair.1,
            accessories: accessories.0, accessoriesOrigin: accessories.1,
            distinguishingFeatures: features.0, distinguishingFeaturesOrigin: features.1
        )
    }

    /// Applies the resolution to a Bible entry, returning the updated copy.
    static func apply(
        to character: BibleCharacter,
        isUserAuthored: Bool,
        appearance: OpeningReferenceAppearance?
    ) -> BibleCharacter {
        let resolution = resolve(
            existing: character, isUserAuthored: isUserAuthored, appearance: appearance)
        var updated = character
        updated.defaultCostume = resolution.costume
        updated.appearance.hair = resolution.hair
        updated.accessories = resolution.accessories
        updated.appearance.distinguishingFeatures = resolution.distinguishingFeatures
        return updated
    }

    /// A Bible entry is treated as user-authored when a person could plausibly
    /// have produced it: it carries reference assets, locked traits, or notes
    /// the Director never writes. The Director's seeding path sets only `name`
    /// and `defaultCostume`.
    static func isUserAuthored(_ character: BibleCharacter) -> Bool {
        if !character.referenceAssets.isEmpty { return true }
        if !character.lockedTraits.isEmpty { return true }
        let authored = [
            character.appearance.faceDescription, character.appearance.eyes,
            character.appearance.build, character.appearance.complexion,
            character.appearance.ageImpression, character.appearance.generalNotes,
            character.continuityNotes, character.personality, character.roleNotes,
            character.speakingStyle,
        ]
        return authored.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
