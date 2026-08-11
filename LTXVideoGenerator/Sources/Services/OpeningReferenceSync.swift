import Foundation

/// Brings the Character Bible into agreement with the image the movie opens on.
///
/// The ordering here is the whole point. The Director used to run first and
/// invent a costume from the brief text; the Opening Reference was imported
/// afterwards, so the plan never saw it. This type exists to make
/// "analyse the image, *then* plan" the only available sequence.
enum OpeningReferenceSync {

    /// Applies image evidence to a Bible, returning the updated Bible.
    ///
    /// Auto-generated placeholder entries are superseded by what the image
    /// shows. Entries a person authored are left alone — an appearance the user
    /// typed outranks anything a model saw.
    static func apply(
        appearance: OpeningReferenceAppearance?,
        to bible: CharacterBible
    ) -> CharacterBible {
        guard let appearance, appearance.isUsable else { return bible }
        var updated = bible
        // With a single subject in the frame there is exactly one character the
        // evidence can belong to. With several, `status` is already `.ambiguous`
        // and we never get here.
        guard updated.characters.count == 1 else { return updated }
        let existing = updated.characters[0]
        updated.characters[0] = EffectiveAppearanceResolver.apply(
            to: existing,
            isUserAuthored: EffectiveAppearanceResolver.isUserAuthored(existing),
            appearance: appearance
        )
        return updated
    }

    /// A Bible seeded from image evidence, for the case where planning has not
    /// produced any character yet. Giving the Director a character that already
    /// matches the image stops it inventing a contradictory one.
    static func seedBible(
        from appearance: OpeningReferenceAppearance?,
        existing: CharacterBible
    ) -> CharacterBible {
        guard let appearance, appearance.isUsable, existing.characters.isEmpty else {
            return existing
        }
        var character = BibleCharacter(name: "Character1")
        character.defaultCostume = appearance.costumeSummary
        character.appearance.hair = appearance.hairDescription
        character.accessories = appearance.accessories
        character.appearance.distinguishingFeatures = [
            appearance.distinctiveTraits, appearance.silhouetteDescription,
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
        var seeded = existing
        seeded.characters = [character]
        return seeded
    }

    /// True when derived appearance no longer describes the attached image, so
    /// Replace and Clear cannot leave a previous costume in place.
    static func isStale(
        appearance: OpeningReferenceAppearance?,
        for image: OpeningReferenceImage?
    ) -> Bool {
        guard let appearance else { return false }
        guard let image else { return true }
        return appearance.sourceRelativePath != image.projectRelativePath
    }

    /// Drops derived appearance that no longer belongs to the attached image.
    static func invalidateIfStale(project: inout FilmProject) {
        if isStale(appearance: project.openingReferenceAppearance,
                   for: project.openingReferenceImage) {
            project.openingReferenceAppearance = nil
        }
    }
}
