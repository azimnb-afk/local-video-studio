import Foundation
@testable import LTXVideoGeneratorCore

func runStartingImageBridgeTests(_ t: TestKit) {
    t.suite("CharacterBible Phase 4 — Starting Image Bridge") {

        // 1. Persistence & Backward Compatibility
        let assetID = UUID()
        let shot = Shot(index: 0, title: "Test Shot", durationSeconds: 5, startingImageReferenceAssetID: assetID)
        t.checkEqual(shot.startingImageReferenceAssetID, assetID, "Shot stores startingImageReferenceAssetID")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try! encoder.encode(shot)
        let decodedShot = try! decoder.decode(Shot.self, from: data)
        t.checkEqual(decodedShot.startingImageReferenceAssetID, assetID, "Shot startingImageReferenceAssetID round-trips via JSON")

        // Backward compatibility: old shot JSON without field decodes cleanly to nil
        let legacyShotJSON = """
        {
            "id": "\(UUID().uuidString)",
            "index": 0,
            "title": "Legacy Shot",
            "summary": "Old shot without starting image",
            "durationSeconds": 5,
            "compiledPrompt": "A test prompt"
        }
        """.data(using: .utf8)!
        let decodedLegacy = try! decoder.decode(Shot.self, from: legacyShotJSON)
        t.check(decodedLegacy.startingImageReferenceAssetID == nil, "Legacy Shot decodes cleanly with nil startingImageReferenceAssetID")

        // 2. Asset Type Candidates & Display Labels
        let sheetAsset = CharacterReferenceAsset(type: .characterSheet, label: "Full Sheet")
        let frontAsset = CharacterReferenceAsset(type: .front, label: "Front View")
        let sideAsset = CharacterReferenceAsset(type: .side)
        let faceAsset = CharacterReferenceAsset(type: .face, label: "Face Close-Up")
        let expressionAsset = CharacterReferenceAsset(type: .expression)
        let costumeAsset = CharacterReferenceAsset(type: .costumeDetail)

        t.check(!sheetAsset.isStartingImageCandidate, "Character sheet original is excluded from starting image candidates")
        t.check(frontAsset.isStartingImageCandidate, "Front view is a valid starting image candidate")
        t.check(sideAsset.isStartingImageCandidate, "Side view is a valid starting image candidate")
        t.check(faceAsset.isStartingImageCandidate, "Face view is a valid starting image candidate")
        t.check(expressionAsset.isStartingImageCandidate, "Expression view is a valid starting image candidate")
        t.check(costumeAsset.isStartingImageCandidate, "Costume detail is a valid starting image candidate")

        t.checkEqual(frontAsset.displayLabel, "Front (Front View)", "Front asset display label contains type and custom label")
        t.checkEqual(sideAsset.displayLabel, "Side", "Side asset display label uses type displayName when custom label is empty")
        t.checkEqual(faceAsset.displayLabel, "Face / Close-Up (Face Close-Up)", "Face asset display label formats correctly")

        // 3. Asset Resolution in FilmProject
        let mayaCharacterID = UUID()
        let frontRef = CharacterReferenceAsset(
            id: UUID(),
            type: .front,
            label: "Front",
            projectRelativePath: "Assets/Characters/\(mayaCharacterID.uuidString)/front.png"
        )
        let sideRef = CharacterReferenceAsset(
            id: UUID(),
            type: .side,
            label: "Side",
            projectRelativePath: "Assets/Characters/\(mayaCharacterID.uuidString)/side.png"
        )
        let maya = BibleCharacter(
            id: mayaCharacterID,
            name: "Maya",
            referenceAssets: [sheetAsset, frontRef, sideRef]
        )

        var project = FilmProject(title: "Starting Image Test Project")
        project.characterBible.characters.append(maya)

        let found = project.findReferenceAsset(id: frontRef.id)
        t.check(found != nil, "findReferenceAsset finds reference asset by UUID")
        t.checkEqual(found?.character.name, "Maya", "Resolved asset character name matches")
        t.checkEqual(found?.asset.type, CharacterReferenceAssetType.front, "Resolved asset type matches")

        // 4. Request Assembly via TakeGenerationCoordinator
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartingImageTests_\(UUID().uuidString)", isDirectory: true)
        let store = FilmProjectStore(projectsDirectory: tempDir)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let charAssetsDir = store.characterAssetsDirectory(projectID: project.id, characterID: mayaCharacterID)
        try! FileManager.default.createDirectory(at: charAssetsDir, withIntermediateDirectories: true)

        let mockFrontFile = charAssetsDir.appendingPathComponent("front.png")
        try! "mock PNG bytes".data(using: .utf8)!.write(to: mockFrontFile)

        let updatedFrontRef = CharacterReferenceAsset(
            id: frontRef.id,
            type: .front,
            label: "Front",
            projectRelativePath: "Assets/Characters/\(mayaCharacterID.uuidString)/front.png"
        )
        project.characterBible.characters[0].referenceAssets = [updatedFrontRef]

        let shot1 = Shot(index: 0, title: "Shot 1", durationSeconds: 5, characterIDs: [mayaCharacterID], startingImageReferenceAssetID: frontRef.id)
        let shot2 = Shot(index: 1, title: "Shot 2", durationSeconds: 5, characterIDs: [mayaCharacterID], startingImageReferenceAssetID: nil)
        project.shots = [shot1, shot2]
        store.save(project)

        let coordinator = TakeGenerationCoordinator(store: store)

        // Test Shot 1 (with Starting Image)
        let requests1 = try! coordinator.planTakes(projectID: project.id, shotID: shot1.id, count: 1)
        t.checkEqual(requests1.count, 1, "planTakes creates 1 request for Shot 1")
        t.checkEqual(requests1[0].sourceImagePath, mockFrontFile.path, "Request sourceImagePath maps to project-owned front PNG")

        let reloadedProject1 = store.project(id: project.id)!
        t.checkEqual(reloadedProject1.shots[0].takes.count, 1, "Shot 1 has 1 take created")
        t.checkEqual(reloadedProject1.shots[0].takes[0].startingImageReferenceAssetID, frontRef.id, "Take records startingImageReferenceAssetID")
        t.checkEqual(reloadedProject1.shots[0].takes[0].sourceImagePath, mockFrontFile.path, "Take records sourceImagePath")

        // Test Shot 2 (No Starting Image -> T2V)
        let requests2 = try! coordinator.planTakes(projectID: project.id, shotID: shot2.id, count: 1)
        t.checkEqual(requests2.count, 1, "planTakes creates 1 request for Shot 2")
        t.check(requests2[0].sourceImagePath == nil, "Request sourceImagePath is nil for Shot 2 with no starting image")

        // 5. Preflight Failure / Missing File & Unknown Asset ID (No Silent T2V Fallback)
        let unknownAssetID = UUID()
        let shot3 = Shot(index: 2, title: "Shot 3", durationSeconds: 5, startingImageReferenceAssetID: unknownAssetID)
        project.shots.append(shot3)
        store.save(project)

        do {
            _ = try coordinator.planTakes(projectID: project.id, shotID: shot3.id, count: 1)
            t.check(false, "Expected startingImageNotFound error for unknown asset ID")
        } catch TakeGenerationCoordinator.CoordinatorError.startingImageNotFound(let id) {
            t.checkEqual(id, unknownAssetID, "Throws startingImageNotFound for unknown asset ID")
        } catch {
            t.check(false, "Unexpected error type: \(error)")
        }

        // Test missing file on disk
        let missingAssetID = UUID()
        let missingRef = CharacterReferenceAsset(
            id: missingAssetID,
            type: .side,
            label: "Missing Side Image",
            projectRelativePath: "Assets/Characters/\(mayaCharacterID.uuidString)/missing.png"
        )
        project.characterBible.characters[0].referenceAssets.append(missingRef)
        let shot4 = Shot(index: 3, title: "Shot 4", durationSeconds: 5, startingImageReferenceAssetID: missingAssetID)
        project.shots.append(shot4)
        store.save(project)

        do {
            _ = try coordinator.planTakes(projectID: project.id, shotID: shot4.id, count: 1)
            t.check(false, "Expected startingImageUnavailable error for missing file")
        } catch TakeGenerationCoordinator.CoordinatorError.startingImageUnavailable(let id) {
            t.checkEqual(id, missingAssetID, "Throws startingImageUnavailable when reference image file does not exist")
        } catch {
            t.check(false, "Unexpected error type: \(error)")
        }

        // 6. Character Rename & Asset Label Rename Safety
        let originalName = project.characterBible.characters[0].name
        project.characterBible.characters[0].name = "Renamed Heroine Maya"
        store.save(project)
        let foundAfterRename = project.findReferenceAsset(id: frontRef.id)
        t.check(foundAfterRename != nil, "Reference asset resolution remains stable after character rename")
        t.checkEqual(foundAfterRename?.character.name, "Renamed Heroine Maya", "Character rename updates display name")

        // Restore name
        project.characterBible.characters[0].name = originalName
        store.save(project)

        // 7. Delete Character & Asset Sanitation
        project.removeCharacter(id: mayaCharacterID)
        t.checkEqual(project.characterBible.characters.count, 0, "Character removed from Bible")
        t.check(project.shots[0].startingImageReferenceAssetID == nil, "Shot 1 startingImageReferenceAssetID cleared after character deletion")
        t.check(project.shots[3].startingImageReferenceAssetID == nil, "Shot 4 startingImageReferenceAssetID cleared after character deletion")

        // 8. Multiple Shots with Multiple Characters Mapping
        let rinID = UUID()
        let rinSideRef = CharacterReferenceAsset(
            id: UUID(),
            type: .side,
            label: "Side",
            projectRelativePath: "Assets/Characters/\(rinID.uuidString)/rin_side.png"
        )
        let rin = BibleCharacter(id: rinID, name: "Rin", referenceAssets: [rinSideRef])
        project.characterBible.characters = [maya, rin]

        let rinAssetsDir = store.characterAssetsDirectory(projectID: project.id, characterID: rinID)
        try! FileManager.default.createDirectory(at: rinAssetsDir, withIntermediateDirectories: true)
        let mockRinSideFile = rinAssetsDir.appendingPathComponent("rin_side.png")
        try! "mock Rin side PNG".data(using: .utf8)!.write(to: mockRinSideFile)

        let updatedRinSideRef = CharacterReferenceAsset(
            id: rinSideRef.id,
            type: .side,
            label: "Side",
            projectRelativePath: "Assets/Characters/\(rinID.uuidString)/rin_side.png"
        )
        project.characterBible.characters[1].referenceAssets = [updatedRinSideRef]

        var shotMayaFront = Shot(index: 0, title: "Shot 1", durationSeconds: 5, characterIDs: [mayaCharacterID], startingImageReferenceAssetID: frontRef.id)
        let shotMultiRin = Shot(index: 1, title: "Rin Shot", durationSeconds: 5, characterIDs: [rinID], startingImageReferenceAssetID: rinSideRef.id)
        project.shots = [shotMayaFront, shotMultiRin]
        store.save(project)

        let reqMaya = try! coordinator.planTakes(projectID: project.id, shotID: shotMayaFront.id, count: 1)
        let reqRin = try! coordinator.planTakes(projectID: project.id, shotID: shotMultiRin.id, count: 1)

        t.checkEqual(reqMaya[0].sourceImagePath, mockFrontFile.path, "Shot 1 correctly maps Maya's front image")
        t.checkEqual(reqRin[0].sourceImagePath, mockRinSideFile.path, "Shot 2 correctly maps Rin's side image")
        t.check(reqMaya[0].sourceImagePath != reqRin[0].sourceImagePath, "Requests for different shots/characters keep distinct image paths")
    }
}
