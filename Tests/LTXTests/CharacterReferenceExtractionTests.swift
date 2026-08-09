import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import LTXVideoGeneratorCore

func runCharacterReferenceExtractionTests(_ t: TestKit) {
    t.suite("Reference region schema and validation") {
        let response = """
        {"regions":[
          {"type":"front","label":"Front","rect":{"left":100,"top":50,"right":350,"bottom":600},"notes":""},
          {"type":"side","label":"Side","rect":{"left":380,"top":50,"right":570,"bottom":600},"notes":""},
          {"type":"back","label":"Back","rect":{"left":600,"top":50,"right":850,"bottom":600},"notes":""},
          {"type":"face","label":"Close-Up","rect":{"left":700,"top":620,"right":950,"bottom":900},"notes":""},
          {"type":"expression","label":"Smile","rect":{"left":50,"top":650,"right":180,"bottom":780},"notes":""},
          {"type":"expression","label":"Surprised","rect":{"left":200,"top":650,"right":330,"bottom":780},"notes":""},
          {"type":"costumeDetail","label":"Belt","rect":{"left":50,"top":820,"right":180,"bottom":970},"notes":""},
          {"type":"costumeDetail","label":"Boots","rect":{"left":200,"top":820,"right":330,"bottom":970},"notes":""},
          {"type":"futurePanel","label":"Future","rect":{"left":400,"top":820,"right":550,"bottom":970},"notes":""}
        ]}
        """
        do {
            let proposals = try CharacterSheetRegionAnalyzer.parse(
                response: response, imageWidth: 1086, imageHeight: 1448
            )
            t.checkEqual(proposals.filter { $0.type == .front }.count, 1, "Front region decodes")
            t.checkEqual(proposals.filter { $0.type == .side }.count, 1, "Side region decodes")
            t.checkEqual(proposals.filter { $0.type == .back }.count, 1, "Back region decodes")
            t.checkEqual(proposals.filter { $0.type == .face }.count, 1, "Face region decodes")
            t.checkEqual(proposals.filter { $0.type == .expression }.count, 2, "multiple Expressions decode")
            t.checkEqual(proposals.filter { $0.type == .costumeDetail }.count, 2, "multiple Costume Details decode")
            t.checkEqual(proposals.last?.type, .other, "unknown region type is safely retained as Other")
            t.checkEqual(proposals.first?.normalizedRect,
                         NormalizedCropRect(x: 0.1, y: 0.05, width: 0.25, height: 0.55),
                         "0...1000 wire edges normalize to top-left x/y/w/h")
        } catch { t.check(false, "valid region schema threw \(error)") }

        do {
            let unitGridDrift = """
            {"regions":[{"type":"front","label":"Front","rect":{"x":123,"y":50,"width":386,"height":584},"notes":""}]}
            """
            let drifted = try CharacterSheetRegionAnalyzer.parse(
                response: unitGridDrift, imageWidth: 1086, imageHeight: 1448
            )
            t.checkEqual(drifted.first?.normalizedRect,
                         NormalizedCropRect(x: 0.123, y: 0.05, width: 0.263, height: 0.534),
                         "observed 0...1000 x/y/edge field drift is normalized")
            let trueNormalized = """
            {"regions":[{"type":"face","label":"Face","rect":{"x":0.1,"y":0.2,"width":0.3,"height":0.4},"notes":""}]}
            """
            t.checkEqual(try CharacterSheetRegionAnalyzer.parse(
                response: trueNormalized, imageWidth: 1086, imageHeight: 1448
            ).first?.normalizedRect,
            NormalizedCropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            "true normalized x/y/size response is supported")
        } catch { t.check(false, "bounded field normalization threw \(error)") }

        let invalidRegions = """
        {"regions":[
          {"type":"front","label":"negative","rect":{"left":-1,"top":0,"right":100,"bottom":100},"notes":""},
          {"type":"side","label":"outside","rect":{"left":900,"top":0,"right":1001,"bottom":100},"notes":""},
          {"type":"back","label":"zero","rect":{"left":100,"top":100,"right":100,"bottom":200},"notes":""},
          {"type":"face","label":"tiny","rect":{"left":1,"top":1,"right":2,"bottom":2},"notes":""},
          {"type":"expression","label":"valid","rect":{"left":100,"top":100,"right":300,"bottom":300},"notes":""}
        ]}
        """
        do {
            let proposals = try CharacterSheetRegionAnalyzer.parse(
                response: invalidRegions, imageWidth: 1086, imageHeight: 1448
            )
            t.checkEqual(proposals.count, 1, "negative, out-of-bounds, zero, and tiny regions are rejected")
            t.checkEqual(proposals.first?.label, "valid", "valid region survives mixed invalid response")
        } catch { t.check(false, "mixed validation threw \(error)") }

        t.check(NormalizedCropRect(x: -0.1, y: 0, width: 0.5, height: 0.5).validated() == nil,
                "negative normalized rect rejected")
        t.check(NormalizedCropRect(x: 0, y: 0, width: 0, height: 0.5).validated() == nil,
                "zero-size normalized rect rejected")
        t.check(NormalizedCropRect(x: 0.8, y: 0, width: 0.3, height: 0.5).validated() == nil,
                "normalized rect beyond bounds rejected")
        t.checkEqual(
            NormalizedCropRect(x: 0.5, y: 0.5, width: 0.500_05, height: 0.500_05).validated(),
            NormalizedCropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            "tiny floating overflow is safely clamped"
        )
    }

    t.suite("Normalized top-left crop mapping") {
        do {
            let portrait = try CharacterReferenceExtractionService.pixelRect(
                for: NormalizedCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                imageWidth: 1086, imageHeight: 1448
            )
            t.checkEqual(portrait, CGRect(x: 271, y: 362, width: 544, height: 724),
                         "1086x1448 center crop maps with vertical inversion")
            let landscape = try CharacterReferenceExtractionService.pixelRect(
                for: NormalizedCropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                imageWidth: 1600, imageHeight: 900
            )
            t.checkEqual(landscape, CGRect(x: 160, y: 180, width: 480, height: 360),
                         "landscape mapping uses top-left visual coordinates")
            t.checkEqual(try CharacterReferenceExtractionService.pixelRect(
                for: .fullImage, imageWidth: 640, imageHeight: 480
            ), CGRect(x: 0, y: 0, width: 640, height: 480), "full-image crop maps exactly")
            t.checkEqual(try CharacterReferenceExtractionService.pixelRect(
                for: NormalizedCropRect(x: 0.75, y: 0.75, width: 0.25, height: 0.25),
                imageWidth: 400, imageHeight: 200
            ), CGRect(x: 300, y: 150, width: 100, height: 50), "edge crop stays inside image")

            var userAdjusted = CharacterSheetRegionProposal(
                type: .face, label: "Face",
                normalizedRect: NormalizedCropRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
                origin: .vision, isUserAdjusted: true
            )
            t.checkEqual(userAdjusted.extractionMethod, .visionProposedUserAdjusted,
                         "user-adjusted provenance is distinct")
            userAdjusted.origin = .manual
            t.checkEqual(userAdjusted.extractionMethod, .manual, "manual provenance is distinct")
            t.check(abs(userAdjusted.normalizedRect.width / userAdjusted.normalizedRect.height - 2.0 / 3.0) < 0.000_001,
                    "crop aspect ratio is preserved")
        } catch { t.check(false, "mapping threw \(error)") }
    }

    t.suite("Original-image PNG extraction and persistence") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXReferenceExtractionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sourceURL = root.appendingPathComponent("quadrants.png")
            try writeQuadrantPNG(to: sourceURL)
            let sourceBefore = try Data(contentsOf: sourceURL)
            let store = FilmProjectStore(projectsDirectory: root.appendingPathComponent("Projects"))
            let projectID = UUID()
            let characterID = UUID()
            let imported = try store.importCharacterSheet(
                from: sourceURL, projectID: projectID, characterID: characterID
            )
            guard let sourcePath = imported.projectRelativePath,
                  let managedSource = store.managedCharacterAssetURL(
                    projectID: projectID, relativePath: sourcePath
                  ) else {
                t.check(false, "managed test source resolved")
                return
            }
            let proposals = [
                CharacterSheetRegionProposal(
                    type: .front, label: "Top Left",
                    normalizedRect: NormalizedCropRect(x: 0, y: 0, width: 0.5, height: 0.5),
                    origin: .vision
                ),
                CharacterSheetRegionProposal(
                    type: .expression, label: "Bottom Right",
                    normalizedRect: NormalizedCropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
                    origin: .manual, isUserAdjusted: true
                ),
            ]
            let assets = try CharacterReferenceExtractionService(
                store: store, minimumPixelDimension: 4
            ).extract(
                proposals: proposals,
                sourceAsset: imported,
                sourceURL: managedSource,
                projectID: projectID,
                characterID: characterID,
                analysisProvider: "mock",
                analysisModel: "vision-test"
            )
            t.checkEqual(assets.count, 2, "batch extraction returns all selected references")
            t.check(assets.allSatisfy { $0.mimeType == "image/png" }, "derived references are lossless PNG")
            t.check(assets.allSatisfy { $0.pixelWidth == 50 && $0.pixelHeight == 50 },
                    "derived references retain native crop dimensions without upscaling")
            t.check(assets.allSatisfy { $0.sourceAssetID == imported.id }, "source Character Sheet UUID persists")
            t.check(assets.allSatisfy { $0.sourceCropRect != nil }, "normalized crop provenance persists")
            t.checkEqual(assets.first?.extractionMethod, .visionProposed, "Vision extraction provenance persists")
            t.checkEqual(assets.last?.extractionMethod, .manual, "manual extraction provenance persists")
            let URLs = assets.compactMap { asset in
                asset.projectRelativePath.flatMap {
                    store.managedCharacterAssetURL(projectID: projectID, relativePath: $0)
                }
            }
            t.check(URLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                    "every derived project-owned file exists")
            t.checkEqual(try Data(contentsOf: sourceURL), sourceBefore, "external original is unchanged")
            t.checkEqual(try Data(contentsOf: managedSource), sourceBefore, "project-owned original is unchanged")

            let firstImage = try CharacterReferenceExtractionService.orientedOriginalImage(from: URLs[0])
            t.check(pixelRGBA(firstImage, x: 20, y: 20).red > 200,
                    "top-left visual crop contains the expected red quadrant")

            let character = BibleCharacter(name: "Maya", referenceAssets: [imported] + assets)
            var project = FilmProject(id: projectID, title: "References")
            project.characterBible.characters = [character]
            try store.saveThrowing(project)
            let reloaded = FilmProjectStore(projectsDirectory: root.appendingPathComponent("Projects"))
                .project(id: projectID)?.characterBible.characters.first
            t.checkEqual(reloaded?.referenceAssets.count, 3, "derived asset metadata reloads")
            t.checkEqual(reloaded?.referenceAssets.last?.sourceAssetID, imported.id,
                         "source relation reloads")

            try FileManager.default.removeItem(at: managedSource)
            t.check(FileManager.default.fileExists(atPath: URLs[0].path),
                    "derived reference remains usable when source sheet is missing")
            t.checkEqual(reloaded?.referenceAssets.first(where: { $0.type == .front })?.label,
                         "Top Left", "missing source does not invalidate derived metadata")
        } catch { t.check(false, "extraction/persistence threw \(error)") }
    }

    t.suite("Orientation and failure safety") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXReferenceOrientationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let rotatedURL = root.appendingPathComponent("rotated.jpg")
            try writeOrientedJPEG(to: rotatedURL)
            let oriented = try CharacterReferenceExtractionService.orientedOriginalImage(from: rotatedURL)
            t.checkEqual(oriented.width, 20, "EXIF orientation swaps visual width")
            t.checkEqual(oriented.height, 40, "EXIF orientation swaps visual height")

            let storeRoot = root.appendingPathComponent("BlockedProjects")
            try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
            let store = FilmProjectStore(projectsDirectory: storeRoot)
            let projectID = UUID()
            let characterID = UUID()
            let source = CharacterReferenceAsset(type: .characterSheet, projectRelativePath: "source.png")
            let blockedCharacterPath = store.characterAssetsDirectory(projectID: projectID, characterID: characterID)
            try FileManager.default.createDirectory(at: blockedCharacterPath.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("blocked".utf8).write(to: blockedCharacterPath)
            do {
                _ = try CharacterReferenceExtractionService(store: store, minimumPixelDimension: 4).extract(
                    proposals: [CharacterSheetRegionProposal(
                        type: .face, label: "Face", normalizedRect: .fullImage, origin: .manual
                    )],
                    sourceAsset: source,
                    sourceURL: rotatedURL,
                    projectID: projectID,
                    characterID: characterID,
                    analysisProvider: nil,
                    analysisModel: nil
                )
                t.check(false, "write failure was expected")
            } catch {
                t.check(true, "write failure is surfaced")
            }
            t.check(!FileManager.default.fileExists(
                atPath: blockedCharacterPath.appendingPathComponent("References").path
            ), "write failure leaves no dangling derived files")
        } catch { t.check(false, "orientation/failure fixture threw \(error)") }
    }
}

private func writeQuadrantPNG(to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
    context.setFillColor(NSColor.yellow.cgColor); context.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
    context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 50, width: 50, height: 50))
    context.setFillColor(NSColor.green.cgColor); context.fill(CGRect(x: 50, y: 50, width: 50, height: 50))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
          ) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

private func writeOrientedJPEG(to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(NSColor.purple.cgColor); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
          ) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6],
        kCGImageDestinationLossyCompressionQuality: 1.0,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

private func pixelRGBA(_ image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    let representation = NSBitmapImageRep(cgImage: image)
    let color = representation.colorAt(x: x, y: y) ?? .clear
    return (
        UInt8(max(0, min(255, Int(color.redComponent * 255)))),
        UInt8(max(0, min(255, Int(color.greenComponent * 255)))),
        UInt8(max(0, min(255, Int(color.blueComponent * 255)))),
        UInt8(max(0, min(255, Int(color.alphaComponent * 255))))
    )
}
