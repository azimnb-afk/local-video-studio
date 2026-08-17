import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import LTXVideoGeneratorCore

func runSourceImageOrientationTests(_ t: TestKit) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-source-orientation-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func writeImage(_ url: URL, width: Int, height: Int, orientation: Int? = nil) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let type = orientation == nil ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFOrientation: orientation]
            properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    let portrait = root.appendingPathComponent("portrait.png")
    let landscape = root.appendingPathComponent("landscape.png")
    let square = root.appendingPathComponent("square.png")
    let exifPortrait = root.appendingPathComponent("exif-portrait.jpg")
    try? writeImage(portrait, width: 108, height: 192)
    try? writeImage(landscape, width: 192, height: 108)
    try? writeImage(square, width: 128, height: 128)
    try? writeImage(exifPortrait, width: 120, height: 80, orientation: 6)

    let history = HistoricalSuccessStore(storeURL: root.appendingPathComponent("history.json"))
    let engine = AutoQualityEngine(
        history: history,
        hardware: HardwareProfile(
            modelIdentifier: "OrientationTestMac1,1",
            chipDescription: "Test",
            physicalMemoryGB: 48
        )
    )
    let memory = MemorySnapshot(
        physicalBytes: 48 * 1_073_741_824,
        approximateAvailableBytes: 32 * 1_073_741_824,
        swapUsedBytes: 0,
        swapTotalBytes: 0,
        thermalState: "nominal",
        capturedAt: Date()
    )

    func request(
        source: URL?,
        generationSource: String = "generate",
        modelID: String = LTXModelCatalog.defaultModelID,
        preset: GenerationPreset = .standard,
        parameters: GenerationParameters = .default,
        orientation: SourceImageOrientation? = nil
    ) -> GenerationRequest {
        GenerationRequest(
            prompt: "Orientation test",
            sourceImagePath: source?.path,
            presetResolutionOrientation: orientation,
            modelId: modelID,
            parameters: parameters,
            qualityMode: preset.qualityMode.rawValue,
            preset: preset.rawValue,
            generationSource: generationSource
        )
    }

    func resolve(_ request: GenerationRequest) throws -> GenerationRequest {
        try GenerationSettingsResolver.resolve(
            request: request, engine: engine, snapshot: memory).request
    }

    t.suite("Source image orientation — decoded classification") {
        t.checkEqual(SourceImageOrientationResolver.resolve(url: portrait), .portrait,
                     "portrait pixels classify as portrait")
        t.checkEqual(SourceImageOrientationResolver.resolve(url: landscape), .landscape,
                     "landscape pixels classify as landscape")
        t.checkEqual(SourceImageOrientationResolver.resolve(url: square), .square,
                     "square pixels remain square")
        t.checkEqual(SourceImageOrientationResolver.resolve(path: nil), .none,
                     "missing source has no orientation")
        t.checkEqual(SourceImageOrientationResolver.resolve(url: exifPortrait), .portrait,
                     "EXIF-rotated landscape pixels classify by portrait visual orientation")
    }

    t.suite("Source image orientation — preset, Custom and idempotence") {
        let portraitRequest = request(source: portrait)
        let portraitResolved = try resolve(portraitRequest)
        t.checkEqual(portraitResolved.parameters.width, 512, "A: portrait Standard uses canonical short side")
        t.checkEqual(portraitResolved.parameters.height, 768, "A: portrait Standard uses canonical long side")
        t.checkEqual(portraitResolved.preset, GenerationPreset.standard.rawValue,
                     "orientation does not create or mutate the requested preset")
        t.checkEqual(portraitResolved.presetResolutionOrientation, .portrait,
                     "resolved visual orientation is frozen into the request")

        let landscapeResolved = try resolve(request(source: landscape))
        t.checkEqual(landscapeResolved.parameters.width, 768, "B: landscape restores canonical long side")
        t.checkEqual(landscapeResolved.parameters.height, 512, "B: landscape restores canonical short side")

        let squareResolved = try resolve(request(source: square))
        t.checkEqual(squareResolved.parameters.width, 768, "C: square keeps canonical width")
        t.checkEqual(squareResolved.parameters.height, 512, "C: square keeps canonical height")

        let noSourceResolved = try resolve(request(source: nil))
        t.checkEqual(noSourceResolved.parameters.width, 768, "D/H: removing source restores canonical width")
        t.checkEqual(noSourceResolved.parameters.height, 512, "D/H: removing source restores canonical height")

        var customParameters = GenerationParameters.default
        customParameters.width = 1024
        customParameters.height = 576
        let custom = try resolve(request(
            source: portrait, preset: .custom, parameters: customParameters))
        t.checkEqual(custom.parameters.width, 1024, "E: Custom width is explicit and unchanged")
        t.checkEqual(custom.parameters.height, 576, "E: Custom height is explicit and unchanged")

        var repeated = portraitResolved
        for _ in 0..<10 { repeated = try resolve(repeated) }
        t.checkEqual(repeated.parameters.width, 512, "F: ten resolver passes never ping-pong width")
        t.checkEqual(repeated.parameters.height, 768, "F: ten resolver passes never ping-pong height")

        let replacement = try resolve(request(source: landscape))
        t.checkEqual(replacement.parameters.width, 768, "G: replacement landscape re-derives canonical width")
        t.checkEqual(replacement.parameters.height, 512, "G: replacement landscape re-derives canonical height")

        let data = try JSONEncoder().encode(portraitResolved)
        let reopened = try JSONDecoder().decode(GenerationRequest.self, from: data)
        t.checkEqual(reopened.presetResolutionOrientation, .portrait,
                     "queue/reopen persistence preserves frozen orientation")
        t.checkEqual(try resolve(reopened).parameters, portraitResolved.parameters,
                     "persistence cycle remains idempotent")
    }

    t.suite("Source image orientation — queue snapshot and workflow sharing") {
        let raw = request(source: portrait)
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = [raw]
        let job = ProductionJob(kind: .generate, title: "Direct portrait", snapshot: snapshot)
        let frozen = ProductionQueueService.freezingPresetResolution(in: job)
        let frozenRequest = try XCTUnwrap(frozen.snapshot.pendingRequests.first)
        t.check(frozenRequest.parameters.width < frozenRequest.parameters.height,
                "I: Direct Generate queue snapshot freezes a portrait canvas")
        t.checkEqual(frozen.snapshot.settings, frozenRequest.parameters,
                     "I: queue-visible settings are the exact frozen effective settings")

        try writeImage(portrait, width: 192, height: 108)
        let resolvedAfterReplacement = try resolve(frozenRequest)
        t.checkEqual(resolvedAfterReplacement.presetResolutionOrientation, .portrait,
                     "I: later source replacement cannot mutate queued orientation")
        t.check(resolvedAfterReplacement.parameters.width < resolvedAfterReplacement.parameters.height,
                "I: execution-time profile resolution still honors the frozen portrait canvas")
        try writeImage(portrait, width: 108, height: 192)

        for source in ["generate", "oneShot", "storyboard", "hybrid"] {
            let resolved = try resolve(request(source: portrait, generationSource: source))
            t.checkEqual(resolved.parameters.width, 512,
                         "\(source) uses the one shared portrait resolver")
            t.checkEqual(resolved.parameters.height, 768,
                         "\(source) preserves the shared portrait canvas")
        }
    }

    t.suite("Source image orientation — Auto Movie project and conditioning") {
        let store = FilmProjectStore(
            projectsDirectory: root.appendingPathComponent("auto-movie", isDirectory: true))
        var project = FilmProject(title: "Portrait Opening")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.settings.applyPreset(.standard)
        project.shots = (0..<2).map { index in
            var shot = Shot(index: index, title: "Shot \(index + 1)")
            shot.compiledPrompt = "A portrait movie shot."
            shot.continuityMode = .cut
            return shot
        }
        store.save(project)
        let imported = try store.importOpeningReferenceImage(from: portrait, projectID: project.id)
        project = try XCTUnwrap(store.project(id: project.id))
        project.openingReferenceImage = imported
        store.save(project)

        let coordinator = TakeGenerationCoordinator(store: store)
        let first = try XCTUnwrap(try coordinator.planTakes(
            projectID: project.id, shotID: project.shots[0].id, count: 1, baseSeed: 10).first)
        let second = try XCTUnwrap(try coordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 11).first)
        t.checkEqual(first.presetResolutionOrientation, .portrait,
                     "K: Opening Reference establishes project portrait orientation")
        t.checkEqual(second.presetResolutionOrientation, .portrait,
                     "K/N: later CUT shot retains Auto Movie/Hybrid project orientation")
        let firstResolved = try resolve(first)
        let secondResolved = try resolve(second)
        t.checkEqual(firstResolved.parameters.width, 512, "K: opening Shot request is portrait")
        t.checkEqual(secondResolved.parameters.width, 512, "K: all movie Shot requests stay portrait")

        let preparer = ImageConditioningPreparer(
            cacheDirectory: root.appendingPathComponent("conditioning", isDirectory: true))
        let prepared = try XCTUnwrap(preparer.prepare(request: firstResolved))
        t.checkEqual(prepared.geometry.targetWidth, 512,
                     "L: orientation resolves before ImageConditioning target width")
        t.checkEqual(prepared.geometry.targetHeight, 768,
                     "L: conditioning uses the portrait target height")
        t.checkEqual(prepared.geometry.cropWidth * prepared.geometry.targetHeight,
                     prepared.geometry.cropHeight * prepared.geometry.targetWidth,
                     "L: portrait conditioning remains aspect-preserving scale-to-fill")
    }

    t.suite("Source image orientation — Storyboard project and backends") {
        let store = FilmProjectStore(
            projectsDirectory: root.appendingPathComponent("storyboard", isDirectory: true))
        var project = FilmProject(title: "Storyboard portrait")
        project.settings.applyPreset(.standard)
        project.shots = (0..<2).map { index in
            var shot = Shot(index: index, title: "Shot \(index + 1)")
            shot.compiledPrompt = "A storyboard shot."
            shot.continuityMode = .cut
            return shot
        }
        store.save(project)
        let characterID = UUID(), assetID = UUID()
        let directory = store.characterAssetsDirectory(projectID: project.id, characterID: characterID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let managed = directory.appendingPathComponent("portrait.png")
        try writeImage(managed, width: 108, height: 192)
        var character = BibleCharacter(id: characterID, name: "Portrait Character")
        character.referenceAssets = [CharacterReferenceAsset(
            id: assetID,
            type: .front,
            projectRelativePath: "Assets/Characters/\(characterID.uuidString)/portrait.png"
        )]
        project.characterBible.characters = [character]
        project.shots[1].startingImageReferenceAssetID = assetID
        store.save(project)

        let coordinator = TakeGenerationCoordinator(store: store)
        let textShot = try XCTUnwrap(try coordinator.planTakes(
            projectID: project.id, shotID: project.shots[0].id, count: 1, baseSeed: 20).first)
        let imageShot = try XCTUnwrap(try coordinator.planTakes(
            projectID: project.id, shotID: project.shots[1].id, count: 1, baseSeed: 21).first)
        t.checkEqual(textShot.presetResolutionOrientation, .portrait,
                     "M: first explicit Storyboard image establishes project orientation")
        t.checkEqual(imageShot.presetResolutionOrientation, .portrait,
                     "M: per-shot source does not alternate assembled movie orientation")
        t.checkEqual(try resolve(textShot).parameters.width, 512,
                     "M: text-only sibling uses project portrait canvas")
        t.checkEqual(try resolve(imageShot).parameters.width, 512,
                     "M: image-conditioned sibling uses the same portrait canvas")

        let official = try resolve(request(
            source: portrait, modelID: LTXModelCatalog.defaultModelID))
        let custom = try resolve(request(
            source: portrait, modelID: ModelRegistry.customModelID))
        t.checkEqual(official.parameters.width, custom.parameters.width,
                     "O/P: LTX-2.3 and Custom MLX model receive identical portrait width")
        t.checkEqual(official.parameters.height, custom.parameters.height,
                     "O/P: LTX-2.3 and Custom MLX model receive identical portrait height")
        t.checkEqual(GenerationModelResolver.backend(for: official.modelId), .mlxVideoWithAudio,
                     "O: official backend routing is unchanged")
        t.checkEqual(GenerationModelResolver.backend(for: custom.modelId), .ltx2MLX,
                     "P: Custom MLX model routes to ltx2MLX")
    }

    // MARK: - Custom preset inherits the oriented preset size
    //
    // Custom keeps whatever dimensions it is given (the `.advanced` early
    // return in GenerationSettingsResolver.resolve), which is correct: an
    // explicit user size must win over automatic orientation. The bug was that
    // the Auto Movie sheet *entered* Custom carrying a hardcoded 768x512
    // landscape default, so a user who only toggled Audio silently converted a
    // portrait Opening Reference into a landscape movie. These pin the seed
    // that the sheet now carries across that transition.
    t.suite("Custom preset seeding follows source orientation") {
        func seeded(
            preset: GenerationPreset,
            orientation: SourceImageOrientation,
            modelID: String = LTXModelCatalog.defaultModelID,
            audioEnabled: Bool = true
        ) -> (width: Int, height: Int)? {
            GenerationSettingsResolver.orientedPresetDimensions(
                preset: preset, orientation: orientation, modelID: modelID,
                audioEnabled: audioEnabled, engine: engine, snapshot: memory)
        }

        // PORTRAIT SOURCE + AUTO PRESET -> portrait
        if let p = seeded(preset: .standard, orientation: .portrait) {
            t.check(p.height > p.width,
                    "portrait source seeds a portrait Custom size (\(p.width)x\(p.height))")
        } else {
            t.check(false, "standard preset must yield seed dimensions for a portrait source")
        }

        // LANDSCAPE SOURCE + AUTO PRESET -> landscape (no regression)
        if let l = seeded(preset: .standard, orientation: .landscape) {
            t.check(l.width > l.height,
                    "landscape source seeds a landscape Custom size (\(l.width)x\(l.height))")
        } else {
            t.check(false, "standard preset must yield seed dimensions for a landscape source")
        }

        // The two orientations are the same canvas, transposed.
        if let p = seeded(preset: .standard, orientation: .portrait),
           let l = seeded(preset: .standard, orientation: .landscape) {
            t.checkEqual(p.width, l.height, "portrait width equals landscape height")
            t.checkEqual(p.height, l.width, "portrait height equals landscape width")
        }

        // No source image: the preset's own landscape base is kept.
        if let n = seeded(preset: .standard, orientation: .none) {
            t.check(n.width >= n.height, "no orientation keeps the preset's own base size")
        }

        // Every non-custom preset participates, not just Standard.
        for preset in [GenerationPreset.quickPreview, .standard, .highQuality] {
            if let p = seeded(preset: preset, orientation: .portrait) {
                t.check(p.height > p.width,
                        "\(preset.displayName) seeds portrait for a portrait source")
            } else {
                t.check(false, "\(preset.displayName) must yield seed dimensions")
            }
        }

        // Custom has no preset size to inherit, so it must not invent one.
        t.check(seeded(preset: .custom, orientation: .portrait) == nil,
                "Custom yields no seed (its size is the user's explicit choice)")

        // PORTRAIT SOURCE + LTX-2.5 -> portrait, same as LTX-2.3.
        let ltx25 = seeded(preset: .standard, orientation: .portrait,
                           modelID: ModelRegistry.customModelID)
        let ltx23 = seeded(preset: .standard, orientation: .portrait,
                           modelID: LTXModelCatalog.defaultModelID)
        if let ltx25, let ltx23 {
            t.checkEqual(ltx25.width, ltx23.width, "LTX-2.5 seeds the same portrait width")
            t.checkEqual(ltx25.height, ltx23.height, "LTX-2.5 seeds the same portrait height")
            t.check(ltx25.height > ltx25.width, "LTX-2.5 portrait source seeds portrait")
        } else {
            t.check(false, "both models must yield seed dimensions")
        }

        // Audio OFF is what forces Custom in the sheet; it must not itself
        // change the orientation of the seed.
        if let on = seeded(preset: .standard, orientation: .portrait, audioEnabled: true),
           let off = seeded(preset: .standard, orientation: .portrait, audioEnabled: false) {
            t.check(on.height > on.width && off.height > off.width,
                    "Audio ON and OFF both seed portrait for a portrait source")
        }

        // An explicit Custom size is never re-derived: resolve() must return it
        // untouched even when the source is portrait.
        var explicit = GenerationParameters.default
        explicit.width = 768
        explicit.height = 512
        if let kept = try? resolve(request(
            source: portrait, preset: .custom, parameters: explicit)) {
            t.checkEqual(kept.parameters.width, 768,
                         "explicit Custom width survives a portrait source")
            t.checkEqual(kept.parameters.height, 512,
                         "explicit Custom height survives a portrait source")
        } else {
            t.check(false, "custom request must resolve")
        }
    }
}

/// Small optional unwrap helper for the dependency-free test executable.
private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CocoaError(.coderValueNotFound) }
    return value
}
