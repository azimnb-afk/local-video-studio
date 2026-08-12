import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import LTXVideoGeneratorCore

func runGenerationSourceDiagnosticsTests(_ t: TestKit) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-source-diagnostics-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func writePNG(_ url: URL, width: Int = 768, height: Int = 512) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
           ) else { throw ImageConditioningPreparationError.imageWriteFailed }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageConditioningPreparationError.imageWriteFailed
        }
    }

    func makeProject(_ name: String, shots: Int = 1) -> (FilmProjectStore, FilmProject) {
        let store = FilmProjectStore(projectsDirectory: root.appendingPathComponent(name, isDirectory: true))
        var project = FilmProject(title: name)
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        project.shots = (0..<shots).map { index in
            var shot = Shot(index: index, title: "Shot \(index + 1)")
            shot.compiledPrompt = "A diagnostic test shot."
            shot.continuityMode = index == 0 ? .cut : .continueFromPrevious
            return shot
        }
        store.save(project)
        return (store, project)
    }

    t.suite("Generation source diagnostics — immutable queue snapshots") {
        // T2V has no source path but records an unambiguous historical source.
        let (textStore, textProject) = makeProject("text")
        let textRequests = try? TakeGenerationCoordinator(store: textStore).planTakes(
            projectID: textProject.id, shotID: textProject.shots[0].id, count: 1, baseSeed: 1)
        let textSnapshot = textStore.project(id: textProject.id)?.shots[0].takes.last?.generationSourceDiagnostics
        t.checkEqual(textRequests?.first?.isImageToVideo, false, "T2V request stays T2V")
        t.checkEqual(textSnapshot?.effectiveSource, LTXContinuitySource.none,
                     "T2V snapshot names Text to video")
        t.checkEqual(textSnapshot?.actualVideoMode, .textToVideo, "T2V snapshot records actual mode")
        t.check(textSnapshot?.sourceFilename == nil, "T2V snapshot has no image filename")

        // Explicit Starting Image wins and is represented by a stable relative
        // project path rather than the private absolute path.
        let (explicitStore, explicitProject) = makeProject("explicit")
        let characterID = UUID(), assetID = UUID()
        let assetDirectory = explicitStore.characterAssetsDirectory(
            projectID: explicitProject.id, characterID: characterID)
        try? FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        let explicitImage = assetDirectory.appendingPathComponent("front.png")
        try? writePNG(explicitImage)
        var explicitSaved = explicitStore.project(id: explicitProject.id)!
        var character = BibleCharacter(id: characterID, name: "Maya")
        character.referenceAssets = [CharacterReferenceAsset(
            id: assetID, type: .front,
            projectRelativePath: "Assets/Characters/\(characterID.uuidString)/front.png"
        )]
        explicitSaved.characterBible.characters = [character]
        explicitSaved.shots[0].startingImageReferenceAssetID = assetID
        explicitStore.save(explicitSaved)
        _ = try? TakeGenerationCoordinator(store: explicitStore).planTakes(
            projectID: explicitSaved.id, shotID: explicitSaved.shots[0].id, count: 1, baseSeed: 2)
        let explicitSnapshot = explicitStore.project(id: explicitSaved.id)?.shots[0].takes.last?.generationSourceDiagnostics
        t.checkEqual(explicitSnapshot?.effectiveSource, .explicitStartingImage,
                     "explicit source snapshot retains existing precedence")
        t.checkEqual(explicitSnapshot?.actualVideoMode, .imageToVideo,
                     "explicit source snapshot records I2V")
        t.checkEqual(explicitSnapshot?.sourceProjectRelativePath,
                     "Assets/Characters/\(characterID.uuidString)/front.png",
                     "snapshot persists only the project-relative source path")

        // Opening Reference and Character Anchor retain their distinct logical
        // source terms even though both travel through the same I2V bridge.
        let (openingStore, openingProject) = makeProject("opening")
        let externalOpening = root.appendingPathComponent("opening.png")
        try? writePNG(externalOpening)
        if let imported = try? openingStore.importOpeningReferenceImage(
            from: externalOpening, projectID: openingProject.id
        ), var saved = openingStore.project(id: openingProject.id) {
            saved.openingReferenceImage = imported
            openingStore.save(saved)
        }
        _ = try? TakeGenerationCoordinator(store: openingStore).planTakes(
            projectID: openingProject.id, shotID: openingProject.shots[0].id, count: 1, baseSeed: 3)
        t.checkEqual(openingStore.project(id: openingProject.id)?.shots[0].takes.last?.generationSourceDiagnostics?.effectiveSource,
                     .openingReference, "Opening Reference has its own snapshot source")

        let (anchorStore, anchorProject) = makeProject("anchor")
        let anchorCharacterID = UUID(), anchorAssetID = UUID()
        let anchorDirectory = anchorStore.characterAssetsDirectory(
            projectID: anchorProject.id, characterID: anchorCharacterID)
        try? FileManager.default.createDirectory(at: anchorDirectory, withIntermediateDirectories: true)
        try? writePNG(anchorDirectory.appendingPathComponent("front.png"))
        var anchorSaved = anchorStore.project(id: anchorProject.id)!
        var anchorCharacter = BibleCharacter(id: anchorCharacterID, name: "Anchor")
        anchorCharacter.referenceAssets = [CharacterReferenceAsset(
            id: anchorAssetID, type: .front,
            projectRelativePath: "Assets/Characters/\(anchorCharacterID.uuidString)/front.png"
        )]
        anchorSaved.characterBible.characters = [anchorCharacter]
        anchorSaved.characterAnchor.isEnabled = true
        anchorSaved.characterAnchor.characterID = anchorCharacterID
        anchorSaved.characterAnchor.referenceAssetID = anchorAssetID
        anchorStore.save(anchorSaved)
        _ = try? TakeGenerationCoordinator(store: anchorStore).planTakes(
            projectID: anchorSaved.id, shotID: anchorSaved.shots[0].id, count: 1, baseSeed: 4)
        t.checkEqual(anchorStore.project(id: anchorSaved.id)?.shots[0].takes.last?.generationSourceDiagnostics?.effectiveSource,
                     .characterAnchor, "Character Anchor has its own snapshot source")
    }

    t.suite("Generation source diagnostics — continuation and preparation") {
        let (store, project) = makeProject("continuity", shots: 2)
        let continuityDirectory = store.continuityAssetsDirectory(projectID: project.id)
        try? FileManager.default.createDirectory(at: continuityDirectory, withIntermediateDirectories: true)
        let continuityImage = continuityDirectory.appendingPathComponent("last-frame.png")
        try? writePNG(continuityImage, width: 1000, height: 1000)
        var saved = store.project(id: project.id)!
        var selected = Take(
            shotID: saved.shots[0].id, modelID: "m", seed: 1,
            promptSnapshot: "p", settingsSnapshot: .default,
            requestedWidth: 768, requestedHeight: 512,
            fps: 24, requestedDuration: 5, status: .completed
        )
        selected.generationCompletedAt = Date()
        saved.shots[0].takes = [selected]
        saved.shots[0].selectedTakeID = selected.id
        saved.shots[1].continuityImageRelativePath = "Assets/Continuity/last-frame.png"
        saved.shots[1].continuitySourceTakeID = selected.id
        store.save(saved)
        let requests = try? TakeGenerationCoordinator(store: store).planTakes(
            projectID: saved.id, shotID: saved.shots[1].id, count: 1, baseSeed: 5)
        guard let request = requests?.first else {
            t.check(false, "continuation request was planned"); return
        }
        var snapshot = store.project(id: saved.id)?.shots[1].takes.last?.generationSourceDiagnostics
        t.checkEqual(snapshot?.effectiveSource, .inheritedLastFrame,
                     "continuation snapshot records last frame")
        t.checkEqual(snapshot?.continuitySourceShotID, saved.shots[0].id,
                     "continuation snapshot records source Shot")
        t.checkEqual(snapshot?.continuitySourceTakeID, selected.id,
                     "continuation snapshot records source Take")
        t.checkEqual(snapshot?.continuityTakeSelectionReason, .selectedTake,
                     "continuation snapshot records selection reason")

        let preparer = ImageConditioningPreparer(
            cacheDirectory: root.appendingPathComponent("conditioning-cache", isDirectory: true))
        if let prepared = try? preparer.prepare(request: request) {
            TakeGenerationCoordinator(store: store).recordImagePreparation(
                request: request, preparedConditioning: prepared)
        } else {
            t.check(false, "preparation succeeds for a valid continuity frame")
        }
        snapshot = store.project(id: saved.id)?.shots[1].takes.last?.generationSourceDiagnostics
        t.checkEqual(snapshot?.imagePreparation?.originalWidth, 1000,
                     "snapshot records original image width")
        t.checkEqual(snapshot?.imagePreparation?.effectiveWidth, 768,
                     "snapshot records backend-effective width")
        t.checkEqual(snapshot?.imagePreparation?.effectiveHeight, 512,
                     "snapshot records backend-effective height")
        t.checkEqual(snapshot?.imagePreparation?.mode, .scaleToFillCenterCrop,
                     "snapshot records the existing center-crop preparation")

        // Adding a refresh anchor changes only the reported winning source.
        var refreshed = store.project(id: saved.id)!
        refreshed.shots[1].identityRefreshAnchorRelativePath = "Assets/Continuity/last-frame.png"
        refreshed.shots[1].identityRefreshAnchorOrigin = .reusedPriorRefresh
        refreshed.shots[1].identityRefreshAnchorSourceShotID = refreshed.shots[0].id
        refreshed.shots[1].identityRefreshSourceTakeID = selected.id
        store.save(refreshed)
        _ = try? TakeGenerationCoordinator(store: store).planTakes(
            projectID: refreshed.id, shotID: refreshed.shots[1].id, count: 1, baseSeed: 6)
        let refreshSnapshot = store.project(id: refreshed.id)?.shots[1].takes.last?.generationSourceDiagnostics
        t.checkEqual(refreshSnapshot?.effectiveSource, .identityRefreshAnchor,
                     "refresh anchor snapshot records the actual winning source")
        t.checkEqual(refreshSnapshot?.refreshAnchorOrigin, .reusedPriorRefresh,
                     "refresh snapshot records reuse provenance")
    }

    t.suite("Generation source diagnostics — legacy Take compatibility") {
        var modern = Take(
            shotID: UUID(), modelID: "m", seed: 1, promptSnapshot: "p",
            settingsSnapshot: .default, requestedWidth: 768, requestedHeight: 512,
            fps: 24, requestedDuration: 5
        )
        modern.generationSourceDiagnostics = GenerationSourceDiagnostics(
            requestedContinuityMode: .cut, effectiveSource: .none,
            actualVideoMode: .textToVideo, sourceFilename: nil,
            sourceProjectRelativePath: nil, continuitySourceShotID: nil,
            continuitySourceTakeID: nil, continuityTakeSelectionReason: nil,
            refreshAnchorOrigin: nil, refreshAnchorSourceShotID: nil,
            refreshAnchorSourceTakeID: nil, imagePreparation: nil, recordedAt: Date()
        )
        guard var object = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(modern)) as? [String: Any] else {
            t.check(false, "modern Take encodes for legacy simulation"); return
        }
        object.removeValue(forKey: "generationSourceDiagnostics")
        guard let legacyData = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? JSONDecoder().decode(Take.self, from: legacyData) else {
            t.check(false, "legacy Take decodes without diagnostics"); return
        }
        t.check(decoded.generationSourceDiagnostics == nil,
                "legacy Take safely reports diagnostics unavailable")
    }
}
