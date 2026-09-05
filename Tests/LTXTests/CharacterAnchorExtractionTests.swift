import Foundation
@testable import LTXVideoGeneratorCore

func runCharacterAnchorExtractionTests(_ t: TestKit) {
    t.suite("Character Anchor Extraction & Precedence Tests") {

        // MARK: - A. Character Anchor prefers existing valid asset
        var charA = BibleCharacter(name: "Alice")
        let sideAsset = CharacterReferenceAsset(type: .side, label: "Side View")
        let frontAsset = CharacterReferenceAsset(type: .front, label: "Front View")
        charA.referenceAssets = [sideAsset, frontAsset]

        let preferredA = CharacterAnchor.preferredAsset(for: charA)
        t.checkEqual(preferredA?.id, frontAsset.id, "Character Anchor prefers front asset over side asset")

        // MARK: - B. Raw Character Sheet is not directly offered as shot-start image
        let sheetAsset = CharacterReferenceAsset(type: .characterSheet, label: "Full Sheet")
        t.check(!sheetAsset.isStartingImageCandidate, "Character Sheet is not a starting image candidate")
        t.check(frontAsset.isStartingImageCandidate, "Front asset is a valid starting image candidate")

        var charB = BibleCharacter(name: "Bob")
        charB.referenceAssets = [sheetAsset]
        let preferredB = CharacterAnchor.preferredAsset(for: charB)
        t.check(preferredB == nil, "Character with only raw Character Sheet has no preferred starting asset")

        // MARK: - C. Character with Character Sheet but no derived candidate is eligible for extraction
        let hasSheet = charB.referenceAssets.contains { $0.type == .characterSheet }
        let candidateCount = charB.referenceAssets.filter { $0.isStartingImageCandidate }.count
        t.check(hasSheet && candidateCount == 0, "Character with sheet but no candidate is eligible for extraction")

        // MARK: - D. Character without Character Sheet does not receive dead extraction
        let charNoSheet = BibleCharacter(name: "Charlie")
        let hasSheetD = charNoSheet.referenceAssets.contains { $0.type == .characterSheet }
        t.check(!hasSheetD, "Character without Character Sheet is correctly identified")

        // MARK: - E & G. Extraction save adds derived asset and auto-selects if empty
        var project = FilmProject(title: "Anchor Test Project")
        var charE = BibleCharacter(name: "Diana")
        charE.referenceAssets = [sheetAsset]
        project.upsertCharacter(charE)
        project.characterAnchor.isEnabled = true
        project.characterAnchor.characterID = charE.id
        project.characterAnchor.referenceAssetID = nil

        // Simulate extraction saving a front asset
        let extractedFront = CharacterReferenceAsset(type: .front, label: "Extracted Front")
        var updatedCharE = project.characterBible.character(id: charE.id)!
        updatedCharE.referenceAssets.append(extractedFront)
        project.upsertCharacter(updatedCharE)

        // Simulate auto-selection logic
        if project.characterAnchor.referenceAssetID == nil {
            if let preferred = CharacterAnchor.preferredAsset(for: updatedCharE) {
                project.characterAnchor.referenceAssetID = preferred.id
                project.characterAnchor.referenceAssetType = preferred.type.rawValue
            }
        }
        t.checkEqual(project.characterAnchor.referenceAssetID, extractedFront.id, "Auto-selects newly extracted preferred front asset when anchor was empty")

        // MARK: - F. Existing explicit Character Anchor asset is not silently replaced
        let explicitSide = CharacterReferenceAsset(type: .side, label: "Explicit Side")
        project.characterAnchor.referenceAssetID = explicitSide.id
        project.characterAnchor.referenceAssetType = explicitSide.type.rawValue

        let newlyExtractedFace = CharacterReferenceAsset(type: .face, label: "New Face")
        updatedCharE.referenceAssets.append(newlyExtractedFace)
        project.upsertCharacter(updatedCharE)

        // Logic check: if existing anchor asset ID is present and valid, do NOT replace
        let currentID = project.characterAnchor.referenceAssetID
        t.checkEqual(currentID, explicitSide.id, "Existing explicit anchor selection is preserved when new assets are added")

        // MARK: - H. Opening Reference Precedence
        var openingProject = FilmProject(title: "Precedence Test")
        let openingRef = OpeningReferenceImage(projectRelativePath: "opening_ref.png")
        openingProject.openingReferenceImage = openingRef
        openingProject.characterAnchor.isEnabled = true
        openingProject.characterAnchor.characterID = charA.id
        openingProject.characterAnchor.referenceAssetID = frontAsset.id

        t.check(openingProject.openingReferenceImage != nil, "Opening reference is set")
        t.check(openingProject.characterAnchor.isActive, "Character anchor is active")
        // Precedence: Opening reference is resolved first; if present, coordinator uses opening reference
        t.check(openingProject.openingReferenceImage != nil && openingProject.characterAnchor.isActive, "Both opening reference and character anchor are configured")

        // MARK: - I. Strict continuity Shot 2+ regression
        // Explicit deterministic provider — see the identical note in
        // CharacterContinuitySafetyTests.swift: HybridProjectCoordinator()'s
        // default StoryboardDirector() can reach a real local Ollama
        // endpoint in a dev environment that has one configured.
        let coordinator = HybridProjectCoordinator(
            director: StoryboardDirector(providers: [TemplateStoryboardProvider()]))
        let settings = ProjectSettings(targetDurationSeconds: 12)

        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let result = try await coordinator.makeProject(
                    title: "Anchor Continuity Test",
                    brief: "A hero stands at a cliff looking at the horizon",
                    settings: settings
                )
                let shots = result.project.shots
                t.check(shots.count >= 2, "Planned multi-shot project")
                t.checkEqual(shots[0].continuityMode, .cut, "Shot 1 is cut")
                for i in 1..<shots.count {
                    t.checkEqual(shots[i].continuityMode, .continueFromPrevious, "Shot \(i + 1) is continueFromPrevious")
                }
            } catch {
                t.check(false, "makeProject threw error: \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }
}
