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
        // The consistency verdict describes one specific pairing of sheet and
        // opening image. Replace or Clear either side and it no longer
        // describes anything.
        if isConsistencyStale(project: project) {
            project.characterOpeningConsistency = nil
        }
    }

    /// True when a stored verdict no longer matches the attached opening
    /// reference or the character sheet it was computed from.
    static func isConsistencyStale(project: FilmProject) -> Bool {
        guard let consistency = project.characterOpeningConsistency else { return false }
        guard let image = project.openingReferenceImage else { return true }
        if consistency.openingSourceRelativePath != image.projectRelativePath { return true }
        guard let characterID = consistency.characterID,
              let character = project.characterBible.character(id: characterID) else { return true }
        let currentSheetID = character.referenceAssets.first { $0.type == .characterSheet }?.id
        return consistency.characterSheetAssetID != currentSheetID
    }

    /// Recomputes the verdict for the movie's single character, when there is
    /// one. Reporting only — nothing canonical is changed here.
    static func evaluateConsistency(project: inout FilmProject) {
        guard let appearance = project.openingReferenceAppearance,
              appearance.isUsable,
              project.characterBible.characters.count == 1,
              let character = project.characterBible.characters.first else {
            project.characterOpeningConsistency = nil
            return
        }
        // Nothing canonical to compare against without a sheet: the existing
        // Opening Reference sync already governs that case on its own.
        guard character.referenceAssets.contains(where: { $0.type == .characterSheet }) else {
            project.characterOpeningConsistency = nil
            return
        }
        project.characterOpeningConsistency = CharacterOpeningConsistencyResolver.compare(
            character: character, appearance: appearance)
    }

    /// Re-derives the verdict from already-persisted evidence when the
    /// comparator's version has moved on since it was last computed.
    ///
    /// Comparator logic can improve (D-089: Accessories false positive) after
    /// a verdict is already sitting in a saved project. Both evidence sides —
    /// the Character Sheet analysis and the Opening Reference analysis — are
    /// already persisted, so this is a pure, offline recompute: no Vision
    /// call, no LTX generation, and canonical Character Bible data is never
    /// touched, only the derived verdict.
    ///
    /// Safe to call on every project load: a verdict already at the current
    /// version is left untouched, so this does no unnecessary work.
    ///
    /// - Returns: whether the persisted verdict changed.
    @discardableResult
    static func refreshConsistencyIfOutdated(project: inout FilmProject) -> Bool {
        guard let existing = project.characterOpeningConsistency,
              existing.resolverVersion != CharacterOpeningConsistencyResolver.currentVersion
        else { return false }
        evaluateConsistency(project: &project)
        return project.characterOpeningConsistency != existing
    }
}
