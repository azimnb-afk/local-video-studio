import Foundation
@testable import LTXVideoGeneratorCore

func runCharacterOpeningConsistencyTests(_ t: TestKit) {

    /// A character whose canonical appearance came from a character sheet.
    func sheetCharacter(
        hair: String = "brown hair in a high ponytail",
        costume: String = "navy sailor vest, white shirt, cream cape",
        accessories: String = "brown leather belt"
    ) -> BibleCharacter {
        var c = BibleCharacter(name: "Adventurer Heroine")
        c.appearance.hair = hair
        c.defaultCostume = costume
        c.accessories = accessories
        var sheet = CharacterReferenceAsset(type: .characterSheet, label: "Character Sheet")
        sheet.projectRelativePath = "Assets/Characters/x/sheet.png"
        c.referenceAssets = [sheet]
        return c
    }

    func opening(
        hair: String = "brown hair tied back in a ponytail",
        clothing: String = "navy vest over a white shirt",
        outerwear: String = "cream cape",
        accessories: String = "brown belt",
        subjects: Int = 1,
        status: OpeningReferenceAppearance.Status = .analysed
    ) -> OpeningReferenceAppearance {
        var a = OpeningReferenceAppearance()
        a.status = status
        a.sourceRelativePath = "Assets/OpeningReference/o.png"
        a.subjectCount = subjects
        a.faceVisible = true
        a.hairDescription = hair
        a.clothingDescription = clothing
        a.outerwear = outerwear
        a.accessories = accessories
        return a
    }

    t.suite("Character/Opening consistency — agreement") {
        // A. the sheet and the opening image describe the same character.
        let result = CharacterOpeningConsistencyResolver.compare(
            character: sheetCharacter(), appearance: opening())
        t.checkEqual(result.overallStatus, .match,
                     "A: matching sheet and opening reference read as consistent")
        t.check(result.conflicts.isEmpty, "A: and report no conflicts")
        t.checkEqual(result.openingSourceRelativePath, "Assets/OpeningReference/o.png",
                     "the verdict records which image it compared against")
        t.check(result.characterSheetAssetID != nil,
                "and which character sheet supplied the canonical side")
    }

    t.suite("Character/Opening consistency — real conflict") {
        // B. black bob and a red vest against a brown ponytail and navy vest.
        // Uses "vest" (not "jacket") deliberately: the sheet describes a
        // "vest", and Clothing colours must still catch a genuine same-garment
        // colour contradiction, not just any unrelated colour word.
        let result = CharacterOpeningConsistencyResolver.compare(
            character: sheetCharacter(),
            appearance: opening(hair: "black hair in a short bob",
                                clothing: "red vest", outerwear: ""))
        t.checkEqual(result.overallStatus, .conflict,
                     "B: a different hair colour and clothing colour is a conflict")
        let fields = Set(result.conflicts.map(\.field))
        t.check(fields.contains("Hair colour"), "B: the hair colour conflict is named")
        t.check(fields.contains("Clothing colours"), "B: the clothing conflict is named")
        t.check(result.summary.contains("Differs from the character sheet"),
                "B: the summary says what happened in plain words")
        t.check(result.isConflict, "B: and it is reportable as a conflict")
    }

    t.suite("Character/Opening consistency — absence of evidence is not conflict") {
        // C. the frame describes nothing comparable.
        let occluded = CharacterOpeningConsistencyResolver.compare(
            character: sheetCharacter(),
            appearance: opening(hair: "", clothing: "", outerwear: "", accessories: ""))
        t.checkEqual(occluded.overallStatus, .insufficientEvidence,
                     "C: an opening image with nothing describable cannot conflict")

        // Partial: hair comparable, clothing not.
        let partial = CharacterOpeningConsistencyResolver.compare(
            character: sheetCharacter(),
            appearance: opening(clothing: "", outerwear: "", accessories: ""))
        t.checkEqual(partial.overallStatus, .partial,
                     "C: some comparable fields and some silent ones read as partial")
        t.check(partial.conflicts.isEmpty, "C: and silence is never counted as a contradiction")

        // Shades of the same colour must not be reported as a contradiction.
        let shades = CharacterOpeningConsistencyResolver.compare(
            character: sheetCharacter(hair: "blonde hair"),
            appearance: opening(hair: "blond hair", clothing: "cream coat", outerwear: ""))
        t.check(!shades.isConflict,
                "C: blonde and blond are not a contradiction")
        let greys = CharacterOpeningConsistencyResolver.compare(
            character: sheetCharacter(hair: "grey hair"),
            appearance: opening(hair: "silver hair", clothing: "", outerwear: "", accessories: ""))
        t.check(!greys.isConflict, "C: grey and silver are not a contradiction")
    }

    t.suite("Character/Opening consistency — multi-view sheets and crowds") {
        // D. a sheet showing front/side/back is one character, and nothing in
        // the comparison counts depictions — only the opening frame's subjects.
        var multiView = sheetCharacter()
        var sheet = multiView.referenceAssets[0]
        sheet.detectedViews = ["front", "side", "back", "closeUp"]
        multiView.referenceAssets = [sheet]
        let result = CharacterOpeningConsistencyResolver.compare(
            character: multiView, appearance: opening())
        t.checkEqual(result.overallStatus, .match,
                     "D: a multi-view sheet is still one character, not a crowd conflict")

        // Several people in the *opening frame* is genuine ambiguity.
        let crowd = CharacterOpeningConsistencyResolver.compare(
            character: sheetCharacter(), appearance: opening(subjects: 3))
        t.checkEqual(crowd.overallStatus, .insufficientEvidence,
                     "several people in the opening image means no confident comparison")
        t.check(crowd.ambiguityReason.contains("3 people"),
                "and the reason says why")
    }

    t.suite("Character/Opening consistency — canonical data is never rewritten") {
        // E. a character carrying a sheet is user-authored evidence, so opening
        // observation cannot overwrite it. This is the rule that stops a
        // conflicting frame becoming the character's new identity.
        let character = sheetCharacter()
        t.check(EffectiveAppearanceResolver.isUserAuthored(character),
                "E: a character with reference assets counts as user-authored")
        let contradicting = opening(hair: "black bob", clothing: "red jacket", outerwear: "")
        let resolved = EffectiveAppearanceResolver.resolve(
            existing: character, isUserAuthored: true, appearance: contradicting)
        t.checkEqual(resolved.costume, "navy sailor vest, white shirt, cream cape",
                     "E: the sheet's costume survives a contradicting opening image")
        t.checkEqual(resolved.hair, "brown hair in a high ponytail",
                     "E: and so does the sheet's hair")
        t.checkEqual(resolved.costumeOrigin, .userAuthored,
                     "E: reported as canonical, not as scene observation")

        // F. with no canonical sheet, opening evidence still beats a Director
        // guess — the previously accepted behaviour must not regress.
        var placeholder = BibleCharacter(name: "Character1")
        placeholder.defaultCostume = "Beige trench coat, dark jeans, boots"
        t.check(!EffectiveAppearanceResolver.isUserAuthored(placeholder),
                "F: a Director placeholder is not user-authored")
        let overridden = EffectiveAppearanceResolver.resolve(
            existing: placeholder, isUserAuthored: false, appearance: opening())
        t.checkEqual(overridden.costumeOrigin, .openingReference,
                     "F: image evidence still supersedes a Director guess")
    }

    t.suite("Character/Opening consistency — evaluation, persistence and invalidation") {
        var project = FilmProject(title: "M")
        project.characterBible.characters = [sheetCharacter()]
        project.openingReferenceImage = OpeningReferenceImage(
            projectRelativePath: "Assets/OpeningReference/o.png",
            originalFilename: "o.png", mimeType: "image/png", fileSizeBytes: 1)
        project.openingReferenceAppearance = opening()

        OpeningReferenceSync.evaluateConsistency(project: &project)
        t.checkEqual(project.characterOpeningConsistency?.overallStatus, .match,
                     "evaluation stores a verdict for a sheet-backed character")

        // The opening reference remains the shot-1 source regardless (§12).
        let conflicted = CharacterOpeningConsistencyResolver.compare(
            character: sheetCharacter(),
            appearance: opening(hair: "black bob", clothing: "red jacket", outerwear: ""))
        t.check(conflicted.isConflict, "a conflicting pair is reported as a conflict")
        t.checkEqual(project.openingReferenceImage?.projectRelativePath,
                     "Assets/OpeningReference/o.png",
                     "§12: a conflict never detaches the user's opening image")

        // Round trip.
        let data = try! JSONEncoder().encode(project)
        let decoded = try! JSONDecoder().decode(FilmProject.self, from: data)
        t.checkEqual(decoded.characterOpeningConsistency?.overallStatus, .match,
                     "the verdict survives a save and reload")

        // G. Replace: a different opening image invalidates the verdict.
        var replaced = decoded
        replaced.openingReferenceImage = OpeningReferenceImage(
            projectRelativePath: "Assets/OpeningReference/new.png",
            originalFilename: "new.png", mimeType: "image/png", fileSizeBytes: 1)
        t.check(OpeningReferenceSync.isConsistencyStale(project: replaced),
                "G: a replaced opening reference makes the verdict stale")
        OpeningReferenceSync.invalidateIfStale(project: &replaced)
        t.check(replaced.characterOpeningConsistency == nil,
                "G: and it is dropped rather than shown against the wrong image")

        // H. Clear.
        var cleared = decoded
        cleared.openingReferenceImage = nil
        OpeningReferenceSync.invalidateIfStale(project: &cleared)
        t.check(cleared.characterOpeningConsistency == nil,
                "H: clearing the opening reference removes the verdict")

        // A new character sheet also invalidates.
        var resheeted = decoded
        var newSheet = CharacterReferenceAsset(type: .characterSheet, label: "Character Sheet")
        newSheet.projectRelativePath = "Assets/Characters/x/sheet2.png"
        resheeted.characterBible.characters[0].referenceAssets = [newSheet]
        t.check(OpeningReferenceSync.isConsistencyStale(project: resheeted),
                "a different character sheet makes the verdict stale")

        // J. no character sheet: the existing Opening Reference behaviour is
        // untouched and no verdict is invented.
        var noSheet = project
        noSheet.characterBible.characters[0].referenceAssets = []
        OpeningReferenceSync.evaluateConsistency(project: &noSheet)
        t.check(noSheet.characterOpeningConsistency == nil,
                "J: with no character sheet there is nothing to compare, so nothing is claimed")
        t.check(noSheet.openingReferenceAppearance != nil,
                "J: and the existing opening reference analysis is left intact")
    }

    t.suite("Character/Opening consistency — real analysed data does not false-alarm") {
        // Verbatim strings produced by the real local Vision runs: the
        // canonical side from the Adventurer Heroine character sheet analysis,
        // the observed side from the same opening still's appearance analysis.
        // The point of this case is that two independent model descriptions of
        // the *same* character must not be reported as a contradiction.
        var real = BibleCharacter(name: "Adventurer Heroine")
        real.appearance.hair = "Dark, pulled back into a ponytail"
        real.defaultCostume = "Navy blue pleated skirt with white stripes, white long-sleeve shirt with navy blue vest, brown leather accessories including belt with pouches and compass, knee-high black socks, and brown leather boots with buckles."
        real.accessories = "Brown leather belt with multiple pouches, Pocket watch/compass attached to belt, Brown leather gloves"
        var sheet = CharacterReferenceAsset(type: .characterSheet, label: "Character Sheet")
        sheet.projectRelativePath = "Assets/Characters/x/sheet.png"
        real.referenceAssets = [sheet]

        var observed = OpeningReferenceAppearance()
        observed.status = .analysed
        observed.sourceRelativePath = "Assets/OpeningReference/o.png"
        observed.subjectCount = 1
        observed.faceVisible = true
        observed.hairDescription = "Long hair, likely brown in color, visible under the hood/cape."
        observed.clothingDescription = "Wearing a blue and gold outfit consisting of a fitted bodice with vertical stripes, flared skirt, and dark tights."
        observed.outerwear = "A long, light-colored cape or cloak draped over the shoulders and back."
        observed.accessories = "Wearing what appears to be belts or straps around the waist area, with possible pouches or decorative elements attached."

        let verdict = CharacterOpeningConsistencyResolver.compare(
            character: real, appearance: observed)
        t.check(!verdict.isConflict,
                "real data: two descriptions of the same character are not a conflict")
        t.checkEqual(verdict.overallStatus, .partial,
                     "real data: comparable colours agree and the rest is honestly unclear")
        t.checkEqual(
            verdict.comparisons.first { $0.field == "Clothing colours" }?.verdict, .match,
            "real data: navy/blue is recognised as agreement")
        t.checkEqual(
            verdict.comparisons.first { $0.field == "Hair colour" }?.verdict, .unknown,
            "real data: \"Dark\" against \"brown\" is unknown, not a contradiction")
    }

    t.suite("Character/Opening consistency — accessories compare by object, not by colour bag") {
        func accessoriesVerdict(
            canonical: String, observed: String
        ) -> CharacterOpeningConsistency.FieldVerdict? {
            let result = CharacterOpeningConsistencyResolver.compare(
                character: sheetCharacter(accessories: canonical),
                appearance: opening(accessories: observed))
            return result.comparisons.first { $0.field == "Accessories" }?.verdict
        }

        // A. different objects — colour proximity to an unrelated noun must
        // never read as a contradiction. This is the exact shape of the real
        // false positive (D-089).
        t.checkEqual(accessoriesVerdict(canonical: "blue flag", observed: "brown belt"),
                     .unknown, "A: a blue flag and a brown belt are different objects — unknown")

        // B. same object, genuinely different colour.
        t.checkEqual(accessoriesVerdict(canonical: "blue flag", observed: "red flag"),
                     .conflict, "B: the same flag in two different colours is a real conflict")

        // C. gold/golden normalisation.
        t.checkEqual(accessoriesVerdict(canonical: "gold necklace", observed: "golden necklace"),
                     .match, "C: gold and golden are the same colour")

        // D. existing near-colour equivalence still applies within an object.
        t.checkEqual(accessoriesVerdict(canonical: "blue ribbon", observed: "navy ribbon"),
                     .match, "D: navy and blue are already treated as equivalent")

        // E. absence must not read as contradiction.
        t.checkEqual(accessoriesVerdict(canonical: "a silver sword", observed: "no sword visible"),
                     .unknown, "E: an object with no comparable colour on the other side is unknown")

        // F. same accessory, same colour.
        t.checkEqual(accessoriesVerdict(canonical: "black leather belt", observed: "black belt"),
                     .match, "F: the same accessory in the same colour matches")

        // G. different known accessories.
        t.checkEqual(accessoriesVerdict(canonical: "black belt", observed: "gold necklace"),
                     .unknown, "G: two different recognised accessories — unknown")

        // H. no recognised object on either side.
        t.checkEqual(accessoriesVerdict(canonical: "a strange trinket",
                                        observed: "a mysterious ornament"),
                     .unknown, "H: nothing recognisable to compare — unknown")
    }

    t.suite("Character/Opening consistency — real 旗の子 regression (D-089)") {
        // Verbatim strings from the actual persisted project that surfaced the
        // bug: a canonical "flag (blue with gold star emblem), sword/spear
        // (metallic with ornate hilt)" was read as conflicting with an
        // observed "Brown leather belt… Ornate golden knee-high boots." merely
        // because "blue" and "brown" both appeared somewhere in the field — a
        // flag and a belt are not the same object.
        var character = BibleCharacter(name: "Elara Starborne")
        character.appearance.hair = "black hair tied in a ponytail"
        character.defaultCostume = "A dark blue, high-collared coat that extends to mid-thigh length, adorned with gold trim and patterns. White undershirt visible at the collar and cuffs. Pleated white skirt of medium length. Brown leather belt with multiple pouches or compartments. Ornate shoulder pads featuring a star design in bronze color. Knee-high brown leather boots with buckles. A blue cape attached to the back of the coat, decorated with gold patterns. The character holds a flag on a pole."
        character.accessories = "flag (blue with gold star emblem), sword/spear (metallic with ornate hilt)"
        var sheet = CharacterReferenceAsset(type: .characterSheet, label: "Character Sheet")
        sheet.projectRelativePath = "Assets/Characters/x/sheet.png"
        character.referenceAssets = [sheet]

        var observed = OpeningReferenceAppearance()
        observed.status = .analysed
        observed.subjectCount = 1
        observed.faceVisible = true
        observed.hairDescription = "Long dark hair styled in a ponytail"
        observed.clothingDescription = "White shirt or blouse worn underneath the outer garment."
        observed.outerwear = "Dark blue coat with a white pleated skirt-like bottom section."
        observed.accessories = "Brown leather belt or sash worn around the waist. Ornate golden knee-high boots."

        let result = CharacterOpeningConsistencyResolver.compare(
            character: character, appearance: observed)

        t.checkEqual(
            result.comparisons.first { $0.field == "Hair colour" }?.verdict, .unknown,
            "\"black\" against \"dark\" is not comparable — unknown, unchanged from before the fix")
        t.checkEqual(
            result.comparisons.first { $0.field == "Hairstyle" }?.verdict, .match,
            "ponytail matches, unchanged from before the fix")
        t.checkEqual(
            result.comparisons.first { $0.field == "Clothing colours" }?.verdict, .match,
            "dark blue matches, unchanged from before the fix")
        t.checkEqual(
            result.comparisons.first { $0.field == "Accessories" }?.verdict, .unknown,
            "D-089: flag and belt are different objects — no longer a false conflict")
        t.checkEqual(result.overallStatus, .partial,
                     "D-089: the fixed Accessories verdict changes the real project's overall "
                     + "status from conflict to partial")
        t.check(!result.isConflict, "D-089: the real project no longer reports a false conflict")
    }

    t.suite("Character/Opening consistency — resolver version and stale recompute") {
        var character = BibleCharacter(name: "Elara Starborne")
        character.defaultCostume = "dark blue coat"
        character.accessories = "flag (blue with gold star emblem)"
        var sheet = CharacterReferenceAsset(type: .characterSheet, label: "Character Sheet")
        sheet.projectRelativePath = "Assets/Characters/x/sheet.png"
        character.referenceAssets = [sheet]

        var observedAppearance = OpeningReferenceAppearance()
        observedAppearance.status = .analysed
        observedAppearance.sourceRelativePath = "Assets/OpeningReference/o.png"
        observedAppearance.subjectCount = 1
        observedAppearance.faceVisible = true
        observedAppearance.clothingDescription = "dark blue coat"
        observedAppearance.accessories = "brown belt"

        var project = FilmProject(title: "Stale")
        project.characterBible.characters = [character]
        project.openingReferenceImage = OpeningReferenceImage(
            projectRelativePath: "Assets/OpeningReference/o.png",
            originalFilename: "o.png", mimeType: "image/png", fileSizeBytes: 1)
        project.openingReferenceAppearance = observedAppearance

        // Simulate a verdict computed by the old (pre-fix) comparator: the
        // same false Accessories conflict, and no resolverVersion recorded —
        // exactly what a project persisted before this fix contains.
        var stale = CharacterOpeningConsistencyResolver.compare(
            character: character, appearance: observedAppearance)
        stale.resolverVersion = nil
        stale.comparisons = stale.comparisons.map { comparison in
            var c = comparison
            if c.field == "Accessories" { c.verdict = .conflict }
            return c
        }
        stale.overallStatus = .conflict
        project.characterOpeningConsistency = stale

        let changed = OpeningReferenceSync.refreshConsistencyIfOutdated(project: &project)
        t.check(changed, "an outdated verdict is recomputed")
        t.checkEqual(project.characterOpeningConsistency?.overallStatus, .partial,
                     "and the recomputed result reflects current comparator semantics")
        t.checkEqual(project.characterOpeningConsistency?.resolverVersion,
                     CharacterOpeningConsistencyResolver.currentVersion,
                     "the refreshed verdict is stamped with the current version")

        // No canonical data was touched by the recompute.
        t.checkEqual(project.characterBible.characters[0].defaultCostume, "dark blue coat",
                     "recomputing consistency never mutates the Character Bible")
        t.checkEqual(project.openingReferenceAppearance?.accessories, "brown belt",
                     "or the persisted Opening Reference analysis — no new Vision call is made")

        // Calling again on an already-current verdict does nothing.
        let evaluatedAtBefore = project.characterOpeningConsistency?.evaluatedAt
        let changedAgain = OpeningReferenceSync.refreshConsistencyIfOutdated(project: &project)
        t.check(!changedAgain, "a verdict already at the current version is not recomputed")
        t.checkEqual(project.characterOpeningConsistency?.evaluatedAt, evaluatedAtBefore,
                     "and is left byte-for-byte alone")

        // A project with no consistency at all is a no-op, not an error.
        var empty = FilmProject(title: "Empty")
        t.check(!OpeningReferenceSync.refreshConsistencyIfOutdated(project: &empty),
                "a project with no verdict has nothing to refresh")
    }

    t.suite("Character/Opening consistency — Auto Movie visibility") {
        // This is intentionally a small source-composition guard. The view is
        // a SwiftUI implementation detail outside the core test target, while
        // this ordering is a product requirement: users must see the verdict
        // before the plan that could start a long render.
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let storyboardURL = repositoryRoot
            .appendingPathComponent("LTXVideoGenerator/Sources/Views/StoryboardView.swift")
        let storyboardSource = try? String(contentsOf: storyboardURL, encoding: .utf8)
        let consistencyIndex = storyboardSource?.range(of: "CharacterOpeningConsistencySection(project: project)")
        let planIndex = storyboardSource?.range(of: "AutoMoviePlanPreviewSection(project: project)")
        t.check(consistencyIndex != nil && planIndex != nil,
                "Auto Movie composes both the consistency summary and plan preview")
        if let consistencyIndex, let planIndex, let storyboardSource {
            t.check(consistencyIndex.lowerBound < planIndex.lowerBound,
                    "the consistency summary is composed above Planned Shots")
            let legacyStart = storyboardSource.range(of: "struct OpeningReferenceSection")?.lowerBound
            if let legacyStart {
                let legacySource = String(storyboardSource[legacyStart...])
                t.check(!legacySource.contains("characterOpeningConsistency"),
                        "Opening Reference no longer buries a duplicate consistency verdict")
            }
        }
    }

    t.suite("Character/Opening consistency — unusable analysis fails safely") {
        // I. malformed or unavailable vision output must not produce a verdict.
        for status: OpeningReferenceAppearance.Status in [.unavailable, .failed, .ambiguous] {
            let result = CharacterOpeningConsistencyResolver.compare(
                character: sheetCharacter(), appearance: opening(status: status))
            t.checkEqual(result.overallStatus, .insufficientEvidence,
                         "I: \(status.rawValue) analysis yields no verdict")
            t.check(!result.isConflict, "I: \(status.rawValue) never reads as a conflict")
        }
        let none = CharacterOpeningConsistencyResolver.compare(
            character: sheetCharacter(), appearance: nil)
        t.checkEqual(none.overallStatus, .insufficientEvidence,
                     "I: no analysis at all yields no verdict")
    }
}
