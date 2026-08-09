import Foundation
@testable import LTXVideoGeneratorCore

func runStartingImageUXTests(_ t: TestKit) {
    t.suite("CharacterBible Phase 6B — Production UX & Safety") {

        // 1. AspectMismatchCalculator
        let portraitToLandscape = AspectMismatchCalculator.hasAspectMismatch(
            sourceWidth: 287,
            sourceHeight: 774,
            targetWidth: 768,
            targetHeight: 512
        )
        t.check(portraitToLandscape, "Portrait source to landscape target triggers aspect mismatch warning")

        let landscapeToPortrait = AspectMismatchCalculator.hasAspectMismatch(
            sourceWidth: 768,
            sourceHeight: 512,
            targetWidth: 512,
            targetHeight: 768
        )
        t.check(landscapeToPortrait, "Landscape source to portrait target triggers aspect mismatch warning")

        let identical = AspectMismatchCalculator.hasAspectMismatch(
            sourceWidth: 768,
            sourceHeight: 512,
            targetWidth: 768,
            targetHeight: 512
        )
        t.check(!identical, "Identical aspect ratio does not trigger warning")

        let smallDiff = AspectMismatchCalculator.hasAspectMismatch(
            sourceWidth: 768,
            sourceHeight: 512,
            targetWidth: 768,
            targetHeight: 560
        )
        t.check(!smallDiff, "Small aspect ratio difference (<20%) does not trigger warning")

        let largeDiff = AspectMismatchCalculator.hasAspectMismatch(
            sourceWidth: 768,
            sourceHeight: 512,
            targetWidth: 768,
            targetHeight: 400
        )
        t.check(largeDiff, "Large aspect ratio difference (>=20%) triggers warning")

        let missing = AspectMismatchCalculator.hasAspectMismatch(
            sourceWidth: nil,
            sourceHeight: nil,
            targetWidth: 768,
            targetHeight: 512
        )
        t.check(!missing, "Missing dimensions do not crash or trigger false warning")

        // 2. CharacterTraitLock Production Display Names
        t.checkEqual(CharacterTraitLock.face.displayName, "Facial Features", "face trait label")
        t.checkEqual(CharacterTraitLock.hair.displayName, "Hair", "hair trait label")
        t.checkEqual(CharacterTraitLock.eyes.displayName, "Eyes", "eyes trait label")
        t.checkEqual(CharacterTraitLock.body.displayName, "Body Appearance", "body trait label")
        t.checkEqual(CharacterTraitLock.costume.displayName, "Costume", "costume trait label")
        t.checkEqual(CharacterTraitLock.accessories.displayName, "Accessories", "accessories trait label")

        // 3. Candidate Classification and Defaults
        let sheetAsset = CharacterReferenceAsset(type: .characterSheet, label: "Original Sheet")
        t.check(!sheetAsset.isStartingImageCandidate, "Character Sheet original is excluded from starting image candidates")

        let frontAsset = CharacterReferenceAsset(type: .front, label: "Front View")
        t.check(frontAsset.isStartingImageCandidate, "Front view is a valid starting image candidate")

        let newShot = Shot(index: 0, title: "Test Shot")
        t.check(newShot.startingImageReferenceAssetID == nil, "Default starting image for a new shot is None (nil)")

        // 4. Missing Starting Image Asset Preservation and Preflight Safety
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartingImageUXTests_\(UUID().uuidString)", isDirectory: true)
        let store = FilmProjectStore(projectsDirectory: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let characterID = UUID()
        let missingAssetID = UUID()
        let shotID = UUID()

        let frontAssetRef = CharacterReferenceAsset(
            id: missingAssetID,
            type: .front,
            label: "Front",
            projectRelativePath: "Assets/Characters/\(characterID.uuidString)/missing_front.png"
        )
        let character = BibleCharacter(id: characterID, name: "Maya", referenceAssets: [frontAssetRef])

        var project = FilmProject(title: "Test Project")
        project.characterBible = CharacterBible(characters: [character])
        project.shots = [Shot(id: shotID, index: 0, title: "Shot 1", startingImageReferenceAssetID: missingAssetID)]
        store.save(project)

        // Project load preserves user selection despite missing file on disk
        let reloaded = store.project(id: project.id)!
        t.checkEqual(reloaded.shots[0].startingImageReferenceAssetID, missingAssetID, "Missing asset ID is retained on project load")

        // Preflight throws CoordinatorError.startingImageUnavailable to block silent T2V fallback
        let coordinator = TakeGenerationCoordinator(store: store)
        do {
            _ = try coordinator.planTakes(projectID: project.id, shotID: project.shots[0].id, count: 1)
            t.check(false, "Expected startingImageUnavailable error when file is missing on disk")
        } catch TakeGenerationCoordinator.CoordinatorError.startingImageUnavailable(let id) {
            t.checkEqual(id, missingAssetID, "Preflight correctly identifies missing asset ID")
        } catch {
            t.check(false, "Unexpected error: \(error)")
        }

        // Explicit user clear action resets selection to None
        project.setStartingImageAsset(nil, forShot: project.shots[0].id)
        t.check(project.shots[0].startingImageReferenceAssetID == nil, "User clear action resets starting image to None")
    }
}
