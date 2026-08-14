import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import LTXVideoGeneratorCore

func runImageConditioningPreparerTests(_ t: TestKit) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-conditioning-\(UUID().uuidString)", isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let preparer = ImageConditioningPreparer(cacheDirectory: cache)

    func writePNG(_ url: URL, width: Int, height: Int, color: NSColor) throws {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ImageConditioningPreparationError.imageWriteFailed }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else { throw ImageConditioningPreparationError.imageWriteFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageConditioningPreparationError.imageWriteFailed
        }
    }

    func dimensions(_ url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    func cornerIsGreen(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let points = [(0, 0), (image.width - 1, 0), (0, image.height - 1),
                      (image.width - 1, image.height - 1)]
        return points.allSatisfy { point in
            guard let color = bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB) else {
                return false
            }
            return color.greenComponent > 0.8
                && color.redComponent < 0.2
                && color.blueComponent < 0.2
        }
    }

    t.suite("Image conditioning — integral scale-to-fill geometry") {
        let historical = try ImageConditioningGeometry.scaleToFill(
            sourceWidth: 1672, sourceHeight: 941, targetWidth: 768, targetHeight: 512)
        t.checkEqual(historical.cropX, 131, "1672x941 crop is horizontally centered")
        t.checkEqual(historical.cropY, 0, "1672x941 loses only the integral bottom remainder")
        t.checkEqual(historical.cropWidth, 1410, "historical crop width matches Condition A")
        t.checkEqual(historical.cropHeight, 940, "historical crop height matches Condition A")
        t.checkEqual(historical.cropWidth * historical.targetHeight,
                     historical.cropHeight * historical.targetWidth,
                     "crop and target have exactly the same aspect ratio")

        let portrait = try ImageConditioningGeometry.scaleToFill(
            sourceWidth: 400, sourceHeight: 800, targetWidth: 768, targetHeight: 512)
        t.checkEqual(portrait.cropX, 0, "portrait fill retains centered source width")
        t.checkEqual(portrait.cropY, 267, "portrait fill crops vertically from center")
        t.checkEqual(portrait.cropWidth, 399, "portrait crop uses the largest integral 3:2 width")
        t.checkEqual(portrait.cropHeight, 266, "portrait crop uses the largest integral 3:2 height")

        let exact = try ImageConditioningGeometry.scaleToFill(
            sourceWidth: 768, sourceHeight: 512, targetWidth: 768, targetHeight: 512)
        t.check(exact.isExactCanvas, "an exact source canvas is a geometry no-op")
        t.checkEqual(exact.cropRect, CGRect(x: 0, y: 0, width: 768, height: 512),
                     "exact canvas retains every source pixel")
    }

    t.suite("Image conditioning — pixels, cache and source preservation") {
        let wide = root.appendingPathComponent("wide.png")
        try writePNG(wide, width: 1672, height: 941, color: .green)
        let originalBytes = try Data(contentsOf: wide)
        let first = try preparer.prepare(sourceURL: wide, targetWidth: 768, targetHeight: 512)
        t.check(first.isDerived, "arbitrary-aspect source creates a derived conditioning PNG")
        t.checkEqual(dimensions(first.preparedURL)?.0, 768, "derived width is exact")
        t.checkEqual(dimensions(first.preparedURL)?.1, 512, "derived height is exact")
        t.check(first.preparedURL.pathExtension == "png", "derived conditioning format is PNG")
        t.check(cornerIsGreen(first.preparedURL), "all output corners contain source pixels; no bars/padding")
        t.checkEqual(try Data(contentsOf: wide), originalBytes, "canonical source bytes are unmodified")

        let again = try preparer.prepare(sourceURL: wide, targetWidth: 768, targetHeight: 512)
        t.checkEqual(again.preparedURL, first.preparedURL, "same source/target resolves deterministically")
        t.checkEqual(try Data(contentsOf: again.preparedURL), try Data(contentsOf: first.preparedURL),
                     "deterministic prepared bytes are reused")

        let lower = try preparer.prepare(sourceURL: wide, targetWidth: 512, targetHeight: 320)
        t.checkEqual(dimensions(lower.preparedURL)?.0, 512, "resolution change prepares new effective width")
        t.checkEqual(dimensions(lower.preparedURL)?.1, 320, "resolution change prepares new effective height")
        t.check(!FileManager.default.fileExists(atPath: first.preparedURL.path),
                "resolution change invalidates the stale derivative")

        try writePNG(wide, width: 1672, height: 941, color: .blue)
        let changed = try preparer.prepare(sourceURL: wide, targetWidth: 768, targetHeight: 512)
        t.check(changed.preparedURL != lower.preparedURL,
                "source-content change resolves to a new derivative")
        t.check(!FileManager.default.fileExists(atPath: lower.preparedURL.path),
                "source-content change removes the prior derivative")
        preparer.invalidate(sourceURL: wide)
        t.check(!FileManager.default.fileExists(atPath: changed.preparedURL.path),
                "explicit Replace/Clear invalidation removes the derivative")
    }

    t.suite("Image conditioning — exact canvas and safe failures") {
        let exactURL = root.appendingPathComponent("continuity.png")
        try writePNG(exactURL, width: 768, height: 512, color: .green)
        let bytes = try Data(contentsOf: exactURL)
        let exact = try preparer.prepare(sourceURL: exactURL, targetWidth: 768, targetHeight: 512)
        t.checkEqual(exact.mode, .reusedExactCanvas,
                     "same-size continuity frame receives no composition-changing transform")
        t.checkEqual(exact.preparedURL, exactURL.standardizedFileURL,
                     "exact source path is handed through unchanged")
        t.checkEqual(try Data(contentsOf: exactURL), bytes, "exact source remains byte-identical")

        let missing = root.appendingPathComponent("missing.png")
        t.checkThrows(ImageConditioningPreparationError.missingSource,
                      "missing source fails before backend generation") {
            _ = try preparer.prepare(sourceURL: missing, targetWidth: 768, targetHeight: 512)
        }
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        t.checkThrows(ImageConditioningPreparationError.invalidSource,
                      "invalid image fails before backend generation") {
            _ = try preparer.prepare(sourceURL: invalid, targetWidth: 768, targetHeight: 512)
        }
        t.checkThrows(ImageConditioningPreparationError.invalidTarget,
                      "invalid effective target fails safely") {
            _ = try preparer.prepare(sourceURL: exactURL, targetWidth: 0, targetHeight: 512)
        }
    }

    t.suite("Image conditioning — request boundary and Opening Reference flow") {
        let arbitrary = root.appendingPathComponent("arbitrary.png")
        try writePNG(arbitrary, width: 1000, height: 1000, color: .green)
        for source in ["generate", "oneShot", "storyboard", "hybrid"] {
            var parameters = GenerationParameters.default
            parameters.width = 790
            parameters.height = 530
            let request = GenerationRequest(
                prompt: "p", sourceImagePath: arbitrary.path,
                parameters: parameters, generationSource: source)
            let prepared = try preparer.prepare(request: request)
            t.checkEqual(prepared?.geometry.targetWidth, 768,
                         "\(source) uses backend-effective 64-pixel width")
            t.checkEqual(prepared?.geometry.targetHeight, 512,
                         "\(source) uses backend-effective 64-pixel height")
        }

        let store = FilmProjectStore(
            projectsDirectory: root.appendingPathComponent("projects", isDirectory: true))
        var project = FilmProject(title: "Aspect Fix Production Flow")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        var shot = Shot(index: 0, title: "Shot 1", summary: "Opening")
        shot.compiledPrompt = "A commander raises her flag."
        project.shots = [shot]
        project.settings.width = 768
        project.settings.height = 512
        store.save(project)

        let external = root.appendingPathComponent("opening-1672x941.png")
        try writePNG(external, width: 1672, height: 941, color: .green)
        let externalBytes = try Data(contentsOf: external)
        let imported = try store.importOpeningReferenceImage(from: external, projectID: project.id)
        project.openingReferenceImage = imported
        var appearance = OpeningReferenceAppearance()
        appearance.sourceRelativePath = imported.projectRelativePath
        project.openingReferenceAppearance = appearance
        store.save(project)

        let requests = try TakeGenerationCoordinator(store: store).planTakes(
            projectID: project.id, shotID: shot.id, count: 1, baseSeed: 462344237)
        guard let request = requests.first,
              let production = try preparer.prepare(request: request) else {
            t.check(false, "Opening Reference request did not prepare"); return
        }
        t.check(request.sourceImagePath?.contains("Assets/OpeningReference") == true,
                "project request retains the canonical Opening Reference path")
        t.checkEqual(production.preparedURL.deletingLastPathComponent().standardizedFileURL,
                     cache.standardizedFileURL,
                     "backend-facing path is the injected derived conditioning cache")
        t.checkEqual(production.geometry.cropRect,
                     CGRect(x: 131, y: 0, width: 1410, height: 940),
                     "production flow uses the calibrated Condition A crop geometry")
        t.checkEqual(dimensions(production.preparedURL)?.0, 768,
                     "backend-facing Opening Reference width is exact")
        t.checkEqual(dimensions(production.preparedURL)?.1, 512,
                     "backend-facing Opening Reference height is exact")
        t.checkEqual(try Data(contentsOf: external), externalBytes,
                     "external user source remains untouched")
        t.checkEqual(store.project(id: project.id)?.openingReferenceImage?.projectRelativePath,
                     imported.projectRelativePath,
                     "project continues to display/manage the canonical original")
        t.checkEqual(store.project(id: project.id)?.openingReferenceAppearance?.sourceRelativePath,
                     imported.projectRelativePath,
                     "Vision appearance truth remains tied to the canonical original")
    }
}
