import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageConditioningPreparationError: Error, Equatable, LocalizedError {
    case invalidTarget
    case missingSource
    case invalidSource
    case imageWriteFailed

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "The effective generation canvas is invalid."
        case .missingSource:
            return "The selected conditioning image is unavailable."
        case .invalidSource:
            return "The selected conditioning image could not be decoded."
        case .imageWriteFailed:
            return "The aspect-correct conditioning image could not be written."
        }
    }
}

/// Integral source-space geometry for an aspect-preserving scale-to-fill.
/// Cropping before the uniform resize is mathematically equivalent to resizing
/// then cropping, while making the exact retained source pixels auditable.
struct ImageConditioningGeometry: Equatable {
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    let cropX: Int
    let cropY: Int
    let cropWidth: Int
    let cropHeight: Int

    var scale: Double { Double(targetWidth) / Double(cropWidth) }
    var cropRect: CGRect {
        CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
    }

    var isExactCanvas: Bool {
        sourceWidth == targetWidth && sourceHeight == targetHeight
    }

    static func scaleToFill(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> Self {
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else {
            throw ImageConditioningPreparationError.invalidTarget
        }
        if sourceWidth == targetWidth, sourceHeight == targetHeight {
            return Self(
                sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                targetWidth: targetWidth, targetHeight: targetHeight,
                cropX: 0, cropY: 0, cropWidth: sourceWidth, cropHeight: sourceHeight
            )
        }

        let divisor = greatestCommonDivisor(targetWidth, targetHeight)
        let ratioWidth = targetWidth / divisor
        let ratioHeight = targetHeight / divisor
        let sourceIsWider = sourceWidth * targetHeight > sourceHeight * targetWidth
        let units = sourceIsWider ? sourceHeight / ratioHeight : sourceWidth / ratioWidth
        guard units > 0 else { throw ImageConditioningPreparationError.invalidSource }

        let cropWidth = units * ratioWidth
        let cropHeight = units * ratioHeight
        return Self(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            cropX: (sourceWidth - cropWidth) / 2,
            cropY: (sourceHeight - cropHeight) / 2,
            cropWidth: cropWidth,
            cropHeight: cropHeight
        )
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
    }
}

struct PreparedImageConditioning: Equatable {
    enum Mode: String, Equatable {
        case reusedExactCanvas
        case aspectPreservingFillCrop
    }

    let sourceURL: URL
    let preparedURL: URL
    let geometry: ImageConditioningGeometry
    let mode: Mode
    let preparationSeconds: TimeInterval

    var isDerived: Bool { mode == .aspectPreservingFillCrop }
}

/// The single backend-facing image geometry boundary for official LTX I2V.
/// Canonical user assets remain untouched and continue to feed appearance /
/// prompt analysis; only the path handed to the video backend is prepared.
final class ImageConditioningPreparer {
    static let shared = ImageConditioningPreparer()

    let cacheDirectory: URL
    private let fileManager: FileManager

    init(cacheDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            self.cacheDirectory = AppStorageDirectory.cacheDirectory
        }
    }

    /// Uses the model-aware generation dimensions, including any Auto Quality
    /// fallback profile or alignment grid required by the target backend.
    func prepare(request: GenerationRequest) throws -> PreparedImageConditioning? {
        guard let rawPath = request.sourceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else { return nil }
        let alignment = ModelAwareResolutionAlignment.align(
            requestedWidth: request.parameters.width,
            requestedHeight: request.parameters.height,
            modelID: request.modelId,
            isContinuation: request.isContinuation
        )
        let targetWidth = alignment.generation.width
        let targetHeight = alignment.generation.height
        return try prepare(
            sourceURL: URL(fileURLWithPath: rawPath),
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
    }

    func prepare(
        sourceURL: URL,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> PreparedImageConditioning {
        let started = Date()
        guard targetWidth > 0, targetHeight > 0 else {
            throw ImageConditioningPreparationError.invalidTarget
        }
        let source = sourceURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: source.path) else {
            throw ImageConditioningPreparationError.missingSource
        }

        let image = try orientedImage(from: source)
        let geometry = try ImageConditioningGeometry.scaleToFill(
            sourceWidth: image.width,
            sourceHeight: image.height,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        if geometry.isExactCanvas {
            invalidate(sourceURL: source)
            return PreparedImageConditioning(
                sourceURL: source,
                preparedURL: source,
                geometry: geometry,
                mode: .reusedExactCanvas,
                preparationSeconds: Date().timeIntervalSince(started)
            )
        }

        let sourceData: Data
        do { sourceData = try Data(contentsOf: source, options: .mappedIfSafe) }
        catch { throw ImageConditioningPreparationError.missingSource }

        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            throw ImageConditioningPreparationError.imageWriteFailed
        }
        let pathKey = Self.sha256(Data(source.path.utf8))
        let contentKey = Self.sha256(sourceData)
        let sourcePrefix = "\(pathKey)-"
        let filename = "\(sourcePrefix)\(contentKey)-\(targetWidth)x\(targetHeight).png"
        let destination = cacheDirectory.appendingPathComponent(filename)
        removeCachedVariants(prefix: sourcePrefix, keeping: destination)

        if !fileManager.fileExists(atPath: destination.path) {
            guard let cropped = image.cropping(to: geometry.cropRect),
                  let resized = Self.resize(cropped, width: targetWidth, height: targetHeight) else {
                throw ImageConditioningPreparationError.invalidSource
            }
            let temporary = cacheDirectory.appendingPathComponent(".\(UUID().uuidString).conditioning")
            do {
                try Self.writePNG(resized, to: temporary)
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: destination)
                }
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw ImageConditioningPreparationError.imageWriteFailed
            }
        }

        return PreparedImageConditioning(
            sourceURL: source,
            preparedURL: destination,
            geometry: geometry,
            mode: .aspectPreservingFillCrop,
            preparationSeconds: Date().timeIntervalSince(started)
        )
    }

    /// Replacement, clear, source-content change and resolution change all use
    /// the standardized source-path key, so a stale derivative is never reused.
    func invalidate(sourceURL: URL) {
        let source = sourceURL.standardizedFileURL
        let prefix = "\(Self.sha256(Data(source.path.utf8)))-"
        removeCachedVariants(prefix: prefix, keeping: nil)
    }

    private func removeCachedVariants(prefix: String, keeping: URL?) {
        let files = (try? fileManager.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file != keeping {
            try? fileManager.removeItem(at: file)
        }
    }

    private func orientedImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw ImageConditioningPreparationError.invalidSource
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let oriented = CIImage(cgImage: raw).oriented(forExifOrientation: orientation)
        let extent = oriented.extent.integral
        guard extent.width > 0, extent.height > 0,
              let output = CIContext(options: [.cacheIntermediates: false])
                .createCGImage(oriented, from: extent) else {
            throw ImageConditioningPreparationError.invalidSource
        }
        return output
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw ImageConditioningPreparationError.imageWriteFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageConditioningPreparationError.imageWriteFailed
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
