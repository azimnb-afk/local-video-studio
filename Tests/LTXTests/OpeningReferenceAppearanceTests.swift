import Foundation
@testable import LTXVideoGeneratorCore

func runOpeningReferenceAppearanceTests(_ t: TestKit) {

    // The exact failure this feature exists to stop, reproduced from the real
    // persisted run: the Opening Reference showed a navy-uniformed adventurer
    // while the Director's auto-created Bible said "Beige trench coat, dark
    // jeans, boots", and every compiled prompt carried the wrong costume.
    let seenInImage: OpeningReferenceAppearance = {
        var a = OpeningReferenceAppearance()
        a.status = .analysed
        a.sourceRelativePath = "Assets/OpeningReference/opening.png"
        a.faceVisible = true
        a.subjectCount = 1
        a.hairDescription = "brown hair in a high ponytail with side bangs"
        a.clothingDescription = "navy blue sailor-style vest over a white shirt"
        a.outerwear = "cream hooded cape"
        a.accessories = "brown leather belt with pouches"
        a.distinctiveTraits = "gold emblem on the collar"
        a.analysisModel = "test-vision"

        a.sceneEnvironment = "night train platform"
        a.sceneLighting = "dim overhead lights"
        a.subjectState = "standing still"
        a.keyObjects = "blue suitcase"
        return a
    }()

    func directorPlaceholder() -> BibleCharacter {
        var c = BibleCharacter(name: "Character1")
        c.defaultCostume = "Beige trench coat, dark jeans, boots"
        return c
    }

    t.suite("Opening reference appearance — image evidence beats a Director guess") {
        let placeholder = directorPlaceholder()
        t.check(!EffectiveAppearanceResolver.isUserAuthored(placeholder),
                "a name-and-costume-only entry is recognised as auto-generated")

        let resolved = EffectiveAppearanceResolver.resolve(
            existing: placeholder, isUserAuthored: false, appearance: seenInImage)
        t.checkEqual(resolved.costumeOrigin, .openingReference,
                     "D-071: the image supersedes the Director's invented costume")
        t.check(!resolved.costume.lowercased().contains("beige trench"),
                "D-071: the wrong costume is gone")
        t.check(resolved.costume.lowercased().contains("navy"),
                "D-071: the costume now describes what the image shows")
        t.checkEqual(resolved.hairOrigin, .openingReference, "hair comes from the image")
        t.checkEqual(resolved.accessoriesOrigin, .openingReference,
                     "accessories come from the image")

        // …and the same through the Bible-level entry point.
        var bible = CharacterBible()
        bible.characters = [placeholder]
        let synced = OpeningReferenceSync.apply(appearance: seenInImage, to: bible)
        t.check(!synced.characters[0].defaultCostume.lowercased().contains("beige trench"),
                "D-071: sync removes the contradictory costume from the Bible")
    }

    t.suite("Opening reference appearance — user-authored data is never overwritten") {
        var authored = BibleCharacter(name: "Adventurer Heroine")
        authored.defaultCostume = "Navy sailor uniform, cream cape"
        authored.appearance.faceDescription = "cute, smiling"
        authored.appearance.hair = "brown ponytail"
        t.check(EffectiveAppearanceResolver.isUserAuthored(authored),
                "an entry carrying authored appearance detail is recognised as the user's")

        var contradicting = seenInImage
        contradicting.clothingDescription = "grey tracksuit"
        contradicting.outerwear = ""
        contradicting.hairDescription = "short blonde bob"
        let resolved = EffectiveAppearanceResolver.resolve(
            existing: authored, isUserAuthored: true, appearance: contradicting)
        t.checkEqual(resolved.costume, "Navy sailor uniform, cream cape",
                     "user costume survives a contradicting analysis")
        t.checkEqual(resolved.costumeOrigin, .userAuthored, "and is reported as user-authored")
        t.checkEqual(resolved.hair, "brown ponytail", "user hair survives too")

        // A locked trait or a reference asset alone is enough to count as the
        // user's, even with no prose.
        var locked = BibleCharacter(name: "X")
        locked.lockedTraits = [.hair]
        t.check(EffectiveAppearanceResolver.isUserAuthored(locked),
                "locked traits mark an entry as user-authored")
    }

    t.suite("Opening reference appearance — missing fields fall back safely") {
        var partial = OpeningReferenceAppearance()
        partial.status = .analysed
        partial.subjectCount = 1
        partial.clothingDescription = "navy vest"
        // hair not visible in the frame
        var placeholder = directorPlaceholder()
        placeholder.appearance.hair = "long red hair"
        let resolved = EffectiveAppearanceResolver.resolve(
            existing: placeholder, isUserAuthored: false, appearance: partial)
        t.checkEqual(resolved.costumeOrigin, .openingReference, "visible costume is taken")
        t.checkEqual(resolved.hair, "long red hair",
                     "a field the image does not show keeps its previous value")
        t.checkEqual(resolved.hairOrigin, .directorGenerated,
                     "and is reported as the Director's, not as image evidence")
    }

    t.suite("Opening reference appearance — vision failures invent nothing") {
        let unusable: [OpeningReferenceAppearance.Status] = [.unavailable, .failed, .ambiguous]
        for status in unusable {
            var a = seenInImage
            a.status = status
            var bible = CharacterBible()
            bible.characters = [directorPlaceholder()]
            let synced = OpeningReferenceSync.apply(appearance: a, to: bible)
            t.checkEqual(synced.characters[0].defaultCostume,
                         "Beige trench coat, dark jeans, boots",
                         "\(status.rawValue): nothing is applied and nothing is invented")
        }
        let none = OpeningReferenceSync.apply(appearance: nil, to: {
            var b = CharacterBible(); b.characters = [directorPlaceholder()]; return b
        }())
        t.checkEqual(none.characters[0].defaultCostume, "Beige trench coat, dark jeans, boots",
                     "no analysis at all leaves the Bible untouched")

        let unavailable = OpeningReferenceAppearanceAnalyzer.unavailable(
            sourceRelativePath: "Assets/OpeningReference/x.png")
        t.checkEqual(unavailable.status, .unavailable, "unavailable is a status, not an error")
        t.check(unavailable.costumeSummary.isEmpty, "and carries no invented costume")
    }

    t.suite("Opening reference appearance — response parsing") {
        let good = """
        {"hairDescription":"brown ponytail","clothingDescription":"navy vest",
         "outerwear":"cream cape","accessories":"leather belt",
         "silhouetteDescription":"slim","distinctiveTraits":"gold emblem",
         "sceneEnvironment":"night train platform","sceneLighting":"dim overhead lights",
         "subjectState":"standing still","keyObjects":"blue suitcase",
         "faceVisible":true,"subjectCount":1}
        """
        let parsed = OpeningReferenceAppearanceAnalyzer.appearance(
            fromResponse: good, sourceRelativePath: "p.png", model: "m")
        t.checkEqual(parsed.status, .analysed, "a clean single-subject answer is usable")
        t.checkEqual(parsed.costumeSummary, "navy vest, cream cape",
                     "costume summary joins clothing and outerwear")
        t.check(parsed.faceVisible, "face visibility is carried through")

        t.checkEqual(parsed.sceneEnvironment, "night train platform", "sceneEnvironment is parsed")
        t.checkEqual(parsed.sceneLighting, "dim overhead lights", "sceneLighting is parsed")
        t.checkEqual(parsed.subjectState, "standing still", "subjectState is parsed")
        t.checkEqual(parsed.keyObjects, "blue suitcase", "keyObjects is parsed")

        // Models like to wrap JSON in prose or fences.
        let fenced = "Here you go:\n```json\n" + good + "\n```"
        t.checkEqual(
            OpeningReferenceAppearanceAnalyzer.appearance(
                fromResponse: fenced, sourceRelativePath: "p.png", model: "m").status,
            .analysed, "JSON wrapped in prose is still read")

        t.checkEqual(
            OpeningReferenceAppearanceAnalyzer.appearance(
                fromResponse: "I cannot help with that.",
                sourceRelativePath: "p.png", model: "m").status,
            .failed, "a non-JSON answer fails safely")

        let empty = """
        {"hairDescription":"","clothingDescription":"","outerwear":"","accessories":"",
         "silhouetteDescription":"","distinctiveTraits":"",
         "sceneEnvironment":"","sceneLighting":"","subjectState":"","keyObjects":"",
         "faceVisible":false,"subjectCount":1}
        """
        t.checkEqual(
            OpeningReferenceAppearanceAnalyzer.appearance(
                fromResponse: empty, sourceRelativePath: "p.png", model: "m").status,
            .failed, "an answer describing nothing is not evidence")

        let crowd = """
        {"hairDescription":"brown","clothingDescription":"coat","outerwear":"",
         "accessories":"","silhouetteDescription":"","distinctiveTraits":"",
         "sceneEnvironment":"street","sceneLighting":"","subjectState":"","keyObjects":"",
         "faceVisible":true,"subjectCount":3}
        """
        let ambiguous = OpeningReferenceAppearanceAnalyzer.appearance(
            fromResponse: crowd, sourceRelativePath: "p.png", model: "m")
        t.checkEqual(ambiguous.status, .ambiguous,
                     "several people means no confident protagonist")
        t.check(!ambiguous.isUsable, "and an ambiguous analysis is never merged")
    }

    t.suite("Opening reference appearance — replace and clear invalidate derived state") {
        var project = FilmProject(title: "M")
        project.openingReferenceImage = OpeningReferenceImage(
            projectRelativePath: "Assets/OpeningReference/first.png",
            originalFilename: "first.png", mimeType: "image/png", fileSizeBytes: 1)
        project.openingReferenceAppearance = seenInImage  // points at opening.png

        t.check(OpeningReferenceSync.isStale(
            appearance: project.openingReferenceAppearance,
            for: project.openingReferenceImage),
                "analysis of a different file is stale")
        OpeningReferenceSync.invalidateIfStale(project: &project)
        t.check(project.openingReferenceAppearance == nil,
                "Replace: a stale appearance is dropped rather than reused")

        // Matching path stays.
        var matched = FilmProject(title: "M")
        matched.openingReferenceImage = OpeningReferenceImage(
            projectRelativePath: "Assets/OpeningReference/opening.png",
            originalFilename: "opening.png", mimeType: "image/png", fileSizeBytes: 1)
        matched.openingReferenceAppearance = seenInImage
        OpeningReferenceSync.invalidateIfStale(project: &matched)
        t.check(matched.openingReferenceAppearance != nil,
                "an appearance that still describes the attached image is kept")

        // Clear.
        var cleared = matched
        cleared.openingReferenceImage = nil
        OpeningReferenceSync.invalidateIfStale(project: &cleared)
        t.check(cleared.openingReferenceAppearance == nil,
                "Clear: removing the image removes the derived appearance")
    }

    t.suite("Opening reference appearance — persistence and legacy decode") {
        var project = FilmProject(title: "Round trip")
        project.openingReferenceAppearance = seenInImage
        let data = try! JSONEncoder().encode(project)
        let decoded = try! JSONDecoder().decode(FilmProject.self, from: data)
        t.checkEqual(decoded.openingReferenceAppearance, seenInImage,
                     "appearance survives a save/load round trip")

        // A project written before this feature has no such key at all.
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "openingReferenceAppearance")
        let legacyData = try! JSONSerialization.data(withJSONObject: object)
        let legacy = try! JSONDecoder().decode(FilmProject.self, from: legacyData)
        t.check(legacy.openingReferenceAppearance == nil,
                "legacy projects decode with no derived appearance")
        t.checkEqual(legacy.title, "Round trip", "and are otherwise intact")

        // A project with OpeningReferenceAppearance but missing the new scene evidence fields
        var appearanceObject = try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(seenInImage)) as! [String: Any]
        appearanceObject.removeValue(forKey: "sceneEnvironment")
        appearanceObject.removeValue(forKey: "sceneLighting")
        appearanceObject.removeValue(forKey: "subjectState")
        appearanceObject.removeValue(forKey: "keyObjects")

        let legacyAppearanceData = try! JSONSerialization.data(withJSONObject: appearanceObject)
        let legacyAppearance = try! JSONDecoder().decode(OpeningReferenceAppearance.self, from: legacyAppearanceData)

        t.checkEqual(legacyAppearance.sceneEnvironment, "", "Missing sceneEnvironment decodes to empty string (default)")
        t.checkEqual(legacyAppearance.sceneLighting, "", "Missing sceneLighting decodes to empty string (default)")
        t.checkEqual(legacyAppearance.subjectState, "", "Missing subjectState decodes to empty string (default)")
        t.checkEqual(legacyAppearance.keyObjects, "", "Missing keyObjects decodes to empty string (default)")
        t.checkEqual(legacyAppearance.clothingDescription, "navy blue sailor-style vest over a white shirt", "Other fields decode correctly")
    }

    t.suite("Opening reference appearance — seeding gives the Director no room to invent") {
        let seeded = OpeningReferenceSync.seedBible(from: seenInImage, existing: CharacterBible())
        t.checkEqual(seeded.characters.count, 1, "an empty Bible is seeded from the image")
        t.check(seeded.characters[0].defaultCostume.lowercased().contains("navy"),
                "the seeded costume is what the image shows")
        t.check(seeded.characters[0].appearance.hair.lowercased().contains("ponytail"),
                "the seeded hair is what the image shows")

        // A Bible the user already populated is left alone.
        var existing = CharacterBible()
        var mine = BibleCharacter(name: "Mine")
        mine.defaultCostume = "red coat"
        existing.characters = [mine]
        let untouched = OpeningReferenceSync.seedBible(from: seenInImage, existing: existing)
        t.checkEqual(untouched.characters[0].defaultCostume, "red coat",
                     "seeding never displaces characters that already exist")

        t.checkEqual(OpeningReferenceSync.seedBible(from: nil, existing: CharacterBible())
                        .characters.count, 0,
                     "no analysis seeds nothing")
    }

    t.suite("Opening reference appearance — scene evidence is not merged into CharacterBible") {
        let seeded = OpeningReferenceSync.seedBible(from: seenInImage, existing: CharacterBible())
        t.checkEqual(seeded.characters.count, 1, "an empty Bible is seeded from the image")

        // CharacterBible characters shouldn't contain the scene evidence (environment/lighting)
        t.check(!seeded.characters[0].appearance.compactVisualSummary.contains("night train platform"),
                "scene environment should not leak into character appearance")
        t.check(!seeded.characters[0].appearance.compactVisualSummary.contains("dim overhead lights"),
                "scene lighting should not leak into character appearance")
    }
}
