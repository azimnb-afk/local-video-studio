import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Region proposals

enum CharacterSheetRegionProposalOrigin: String, Codable, Equatable {
    case vision
    case manual
}

/// A transient, reviewable proposal. It is not CharacterBible truth and does
/// not create a file until the user confirms the Crop Review sheet.
struct CharacterSheetRegionProposal: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var type: CharacterReferenceAssetType
    var label: String
    var normalizedRect: NormalizedCropRect
    var notes: String = ""
    var origin: CharacterSheetRegionProposalOrigin
    var isUserAdjusted: Bool = false
    var isSelected: Bool = true

    var extractionMethod: CharacterReferenceExtractionMethod {
        switch (origin, isUserAdjusted) {
        case (.manual, _): return .manual
        case (.vision, true): return .visionProposedUserAdjusted
        case (.vision, false): return .visionProposed
        }
    }
}

// MARK: - Local semantic region localization

final class CharacterSheetRegionAnalyzer {
    static let systemPrompt = """
    This is one fictional character reference sheet. The same character may appear multiple times.
    Identify rectangular regions containing useful character references. Return only regions actually visible.
    Detect, when present: front full-body, side full-body, back full-body, face or close-up,
    individual expressions, and individual costume details. Do not include labels or decorative icons.

    Use a top-left coordinate grid from 0 to 1000 for the complete image:
    left/top is the upper-left edge and right/bottom is the lower-right edge.
    Do not return pixel coordinates. Do not return width/height. Do not invent missing views.
    The result is a best-effort proposal that a user will review before extraction.
    """

    /// A 0...1000 edge grid matches the tested local VLM's localization wire
    /// convention. It is converted immediately to persisted 0...1 x/y/w/h.
    static let outputSchema: [String: Any] = {
        let coordinate: [String: Any] = ["type": "number", "minimum": 0, "maximum": 1000]
        let edgeRect: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "left": coordinate, "top": coordinate,
                "right": coordinate, "bottom": coordinate,
            ],
            "required": ["left", "top", "right", "bottom"],
        ]
        let region: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "type": [
                    "type": "string",
                    "enum": ["face", "front", "side", "back", "expression", "costumeDetail", "other"],
                ],
                "label": ["type": "string"],
                "rect": edgeRect,
                "notes": ["type": "string"],
            ],
            "required": ["type", "label", "rect", "notes"],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": ["regions": ["type": "array", "items": region]],
            "required": ["regions"],
        ]
    }()

    private let provider: CharacterSheetVisionProvider
    private let generationIsActive: () async -> Bool

    init(
        provider: CharacterSheetVisionProvider,
        generationIsActive: @escaping () async -> Bool = { false }
    ) {
        self.provider = provider
        self.generationIsActive = generationIsActive
    }

    func analyze(
        imageData: Data,
        imageWidth: Int,
        imageHeight: Int
    ) async throws -> [CharacterSheetRegionProposal] {
        guard !(await generationIsActive()) else {
            throw CharacterSheetAnalysisError.generationInProgress
        }
        guard await provider.isAvailable() else {
            throw CharacterSheetAnalysisError.localVisionUnavailable
        }

        var previousInvalidResponse: String?
        var lastError: Error = CharacterSheetAnalysisError.analysisFailed("Reference localization failed.")
        for attempt in 0...1 {
            do {
                let prompt: String
                if attempt == 0 {
                    prompt = "Locate useful character reference panels and return the required JSON only."
                } else {
                    let previous = String((previousInvalidResponse ?? "No completion text was returned.").prefix(8_000))
                    prompt = """
                    Rewrite the previous invalid localization result into the required schema.
                    Preserve only visible image regions. Return JSON only.
                    PREVIOUS INVALID OUTPUT:
                    \(previous)
                    """
                }
                let response = try await provider.complete(
                    imageData: imageData,
                    system: Self.systemPrompt,
                    prompt: prompt,
                    outputSchema: Self.outputSchema
                )
                previousInvalidResponse = response
                let proposals = try Self.parse(
                    response: response,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight
                )
                await provider.terminate()
                return proposals
            } catch {
                lastError = error
            }
        }
        await provider.terminate()
        throw lastError
    }

    static func parse(
        response: String,
        imageWidth: Int,
        imageHeight: Int,
        minimumPixelDimension: Int = 32
    ) throws -> [CharacterSheetRegionProposal] {
        guard imageWidth > 0, imageHeight > 0 else {
            throw CharacterSheetAnalysisError.invalidImage
        }
        guard let object = StructuredJSONUtilities.firstJSONObject(in: response),
              let data = StructuredJSONUtilities.removingTrailingCommas(from: object).data(using: .utf8) else {
            throw CharacterSheetAnalysisError.invalidJSON("No region JSON object was found.")
        }
        let wire: WireResult
        do { wire = try JSONDecoder().decode(WireResult.self, from: data) }
        catch { throw CharacterSheetAnalysisError.invalidSchema("Reference regions did not match the required schema.") }

        let proposals = wire.regions.compactMap { region -> CharacterSheetRegionProposal? in
            guard let edges = region.rect.normalizedEdges,
                  edges.left.isFinite, edges.top.isFinite,
                  edges.right.isFinite, edges.bottom.isFinite,
                  edges.left >= 0, edges.top >= 0,
                  edges.right <= 1.000_1, edges.bottom <= 1.000_1,
                  edges.right > edges.left,
                  edges.bottom > edges.top else { return nil }
            let normalized = NormalizedCropRect(
                x: quantized(edges.left),
                y: quantized(edges.top),
                width: quantized(edges.right - edges.left),
                height: quantized(edges.bottom - edges.top)
            ).validated()
            guard let normalized,
                  normalized.width * Double(imageWidth) >= Double(minimumPixelDimension),
                  normalized.height * Double(imageHeight) >= Double(minimumPixelDimension) else { return nil }
            let rawType = CharacterReferenceAssetType(rawValue: region.type)
            let type = CharacterReferenceAssetType.knownTypes.contains(rawType) && rawType != .characterSheet
                ? rawType : .other
            return CharacterSheetRegionProposal(
                type: type,
                label: region.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? type.referenceDisplayName : region.label,
                normalizedRect: normalized,
                notes: region.notes,
                origin: .vision
            )
        }
        guard !proposals.isEmpty else {
            throw CharacterSheetAnalysisError.invalidSchema("Local Vision returned no usable reference regions.")
        }
        return proposals
    }

    private static func quantized(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    private struct WireResult: Decodable { var regions: [WireRegion] }
    private struct WireRegion: Decodable {
        var type: String
        var label: String
        var rect: WireRect
        var notes: String
    }
    private struct WireRect: Decodable {
        var left: Double
        var top: Double
        var right: Double
        var bottom: Double
        var usedXYWH: Bool

        private enum CodingKeys: String, CodingKey {
            case left, top, right, bottom, x, y, width, height
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let left = try container.decodeIfPresent(Double.self, forKey: .left),
               let top = try container.decodeIfPresent(Double.self, forKey: .top),
               let right = try container.decodeIfPresent(Double.self, forKey: .right),
               let bottom = try container.decodeIfPresent(Double.self, forKey: .bottom) {
                self.left = left
                self.top = top
                self.right = right
                self.bottom = bottom
                usedXYWH = false
                return
            }
            left = try container.decode(Double.self, forKey: .x)
            top = try container.decode(Double.self, forKey: .y)
            right = try container.decode(Double.self, forKey: .width)
            bottom = try container.decode(Double.self, forKey: .height)
            usedXYWH = true
        }

        /// The tested VLM commonly emits a 0...1000 top-left edge grid even
        /// when field names drift to x/y/width/height. If it emits true 0...1
        /// x/y/size values, those are normalized without endpoint ambiguity.
        var normalizedEdges: (left: Double, top: Double, right: Double, bottom: Double)? {
            let maximum = max(left, top, right, bottom)
            if usedXYWH && maximum <= 1.000_1 {
                return (left, top, left + right, top + bottom)
            }
            let scale = maximum <= 1.000_1 ? 1.0 : 1000.0
            return (left / scale, top / scale, right / scale, bottom / scale)
        }
    }
}

// MARK: - Original-image extraction

final class CharacterReferenceExtractionService {
    enum ExtractionError: Error, Equatable, LocalizedError {
        case invalidSource
        case invalidCrop
        case cropTooSmall
        case imageWriteFailed

        var errorDescription: String? {
            switch self {
            case .invalidSource: return "The project-owned Character Sheet could not be decoded."
            case .invalidCrop: return "A selected reference crop is outside the Character Sheet."
            case .cropTooSmall: return "A selected reference crop is too small to save."
            case .imageWriteFailed: return "A reference image could not be written. No metadata was saved."
            }
        }
    }

    private let store: FilmProjectStore
    private let minimumPixelDimension: Int

    init(store: FilmProjectStore = .shared, minimumPixelDimension: Int = 32) {
        self.store = store
        self.minimumPixelDimension = minimumPixelDimension
    }

    /// Extracts a batch transactionally from the visually oriented ORIGINAL.
    /// No analysis JPEG is accepted by this API; callers resolve the managed
    /// source sheet URL and pass it explicitly.
    func extract(
        proposals: [CharacterSheetRegionProposal],
        sourceAsset: CharacterReferenceAsset,
        sourceURL: URL,
        projectID: UUID,
        characterID: UUID,
        analysisProvider: String?,
        analysisModel: String?
    ) throws -> [CharacterReferenceAsset] {
        let selected = proposals.filter(\.isSelected)
        guard !selected.isEmpty else { return [] }
        let original = try Self.orientedOriginalImage(from: sourceURL)
        let sourceWidth = original.width
        let sourceHeight = original.height
        let referencesDirectory = store.characterAssetsDirectory(projectID: projectID, characterID: characterID)
            .appendingPathComponent("References", isDirectory: true)
        try FileManager.default.createDirectory(at: referencesDirectory, withIntermediateDirectories: true)

        var staged: [(temporary: URL, destination: URL, asset: CharacterReferenceAsset)] = []
        var moved: [URL] = []
        do {
            for proposal in selected {
                guard let normalized = proposal.normalizedRect.validated() else {
                    throw ExtractionError.invalidCrop
                }
                let pixelRect = try Self.pixelRect(
                    for: normalized,
                    imageWidth: sourceWidth,
                    imageHeight: sourceHeight,
                    minimumPixelDimension: minimumPixelDimension
                )
                guard let cropped = original.cropping(to: pixelRect) else {
                    throw ExtractionError.invalidCrop
                }
                let assetID = UUID()
                let filename = "\(assetID.uuidString).png"
                let destination = referencesDirectory.appendingPathComponent(filename)
                let temporary = referencesDirectory.appendingPathComponent(".\(UUID().uuidString).extracting")
                try Self.writePNG(cropped, to: temporary)
                let relativePath = "Assets/Characters/\(characterID.uuidString)/References/\(filename)"
                let asset = CharacterReferenceAsset(
                    id: assetID,
                    type: proposal.type,
                    label: proposal.label,
                    projectRelativePath: relativePath,
                    originalFilename: filename,
                    notes: proposal.notes,
                    mimeType: "image/png",
                    pixelWidth: cropped.width,
                    pixelHeight: cropped.height,
                    fileSizeBytes: nil,
                    analysisProvider: proposal.origin == .vision ? analysisProvider : nil,
                    analysisModel: proposal.origin == .vision ? analysisModel : nil,
                    analyzedAt: proposal.origin == .vision ? Date() : nil,
                    sourceAssetID: sourceAsset.id,
                    sourceCropRect: normalized,
                    sourceImageWidth: sourceWidth,
                    sourceImageHeight: sourceHeight,
                    extractionMethod: proposal.extractionMethod,
                    isUserAdjusted: proposal.isUserAdjusted
                )
                staged.append((temporary, destination, asset))
            }
            for item in staged {
                guard !FileManager.default.fileExists(atPath: item.destination.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.moveItem(at: item.temporary, to: item.destination)
                moved.append(item.destination)
            }
            return staged.map { item in
                var asset = item.asset
                asset.fileSizeBytes = (try? item.destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map(Int64.init)
                return asset
            }
        } catch {
            for item in staged { try? FileManager.default.removeItem(at: item.temporary) }
            for url in moved { try? FileManager.default.removeItem(at: url) }
            if error is ExtractionError { throw error }
            throw ExtractionError.imageWriteFailed
        }
    }

    /// Converts top-left normalized visual coordinates into CGImage crop
    /// pixel coordinates without resizing or upscaling. CGImage cropping uses
    /// top-left raster coordinates even though CGContext drawing is commonly
    /// described with a bottom-left user-space origin.
    static func pixelRect(
        for rect: NormalizedCropRect,
        imageWidth: Int,
        imageHeight: Int,
        minimumPixelDimension: Int = 1
    ) throws -> CGRect {
        guard let rect = rect.validated(), imageWidth > 0, imageHeight > 0 else {
            throw ExtractionError.invalidCrop
        }
        let left = lowerPixelBoundary(rect.x, dimension: imageWidth)
        let top = lowerPixelBoundary(rect.y, dimension: imageHeight)
        let right = upperPixelBoundary(rect.x + rect.width, dimension: imageWidth)
        let bottom = upperPixelBoundary(rect.y + rect.height, dimension: imageHeight)
        let width = max(0, right - left)
        let height = max(0, bottom - top)
        guard width >= Double(minimumPixelDimension), height >= Double(minimumPixelDimension) else {
            throw ExtractionError.cropTooSmall
        }
        return CGRect(
            x: left,
            y: top,
            width: width,
            height: height
        )
    }

    static func orientedOriginalImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let rawImage = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw ExtractionError.invalidSource
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let image = CIImage(cgImage: rawImage).oriented(forExifOrientation: orientation)
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0,
              let output = CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: extent) else {
            throw ExtractionError.invalidSource
        }
        return output
    }

    private static func lowerPixelBoundary(_ normalized: Double, dimension: Int) -> Double {
        let scaled = normalized * Double(dimension)
        let nearest = scaled.rounded()
        return abs(scaled - nearest) < 0.000_001 ? nearest : floor(scaled)
    }

    private static func upperPixelBoundary(_ normalized: Double, dimension: Int) -> Double {
        let scaled = normalized * Double(dimension)
        let nearest = scaled.rounded()
        return abs(scaled - nearest) < 0.000_001 ? nearest : ceil(scaled)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw ExtractionError.imageWriteFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExtractionError.imageWriteFailed
        }
    }
}

// MARK: - Efficient managed image previews

enum CharacterReferenceThumbnailLoader {
    static func image(from url: URL, maxPixelDimension: Int = 320) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

extension CharacterReferenceAssetType {
    var referenceDisplayName: String {
        switch self {
        case .characterSheet: return "Character Sheet"
        case .face: return "Face / Close-Up"
        case .front: return "Front"
        case .side: return "Side"
        case .back: return "Back"
        case .expression: return "Expression"
        case .costumeDetail: return "Costume Detail"
        case .other: return "Other"
        default: return rawValue
        }
    }

    static let extractableTypes: [Self] = [
        .face, .front, .side, .back, .expression, .costumeDetail, .other,
    ]
}
