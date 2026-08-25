import Foundation
import AppKit

/// Manages project-level identity anchor import, model-aware preparation, and caching.
///
/// Invariants:
/// - The original user-imported anchor is immutable source-of-truth.
/// - Generated frames NEVER become a new master ProjectIdentityAnchor.
/// - Preparation respects ModelAwareResolutionAlignment without non-uniform stretch.
/// - Cache keys are model-aware and invalidate automatically on replacement or deletion.
final class PreparedIdentityAnchorService: @unchecked Sendable {
    static let shared = PreparedIdentityAnchorService()

    static let preparationPolicyVersion = "v1"

    init() {}

    /// Imports a user-supplied image as the immutable project identity anchor.
    func importAnchor(
        sourceURL: URL,
        projectID: UUID,
        characterName: String? = nil,
        store: FilmProjectStore = .shared
    ) throws -> ProjectIdentityAnchor {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NSError(domain: "PreparedIdentityAnchorService", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Source image not found: \(sourceURL.path)"
            ])
        }

        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let relativePath = "Assets/Anchors/identity-original-\(id.uuidString).\(ext)"

        guard let destinationURL = store.managedProjectAssetURL(projectID: projectID, relativePath: relativePath) else {
            throw NSError(domain: "PreparedIdentityAnchorService", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to resolve managed project destination for anchor."
            ])
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        var originalWidth: Int? = nil
        var originalHeight: Int? = nil
        if let probe = MediaProbe.probe(path: destinationURL.path) {
            originalWidth = probe.width
            originalHeight = probe.height
        } else if let image = NSImage(contentsOf: destinationURL) {
            if let rep = image.representations.first {
                originalWidth = rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width)
                originalHeight = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height)
            }
        }

        return ProjectIdentityAnchor(
            id: id,
            projectRelativePath: relativePath,
            characterName: characterName,
            createdTimestamp: Date(),
            originalWidth: originalWidth,
            originalHeight: originalHeight
        )
    }

    /// Computes a deterministic, model-aware cache key.
    func cacheKey(
        anchorID: UUID,
        modelID: String?,
        generationWidth: Int,
        generationHeight: Int
    ) -> String {
        let cleanModel = (modelID ?? "default")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "anchor_\(anchorID.uuidString)_\(cleanModel)_\(generationWidth)x\(generationHeight)_\(Self.preparationPolicyVersion).png"
    }

    /// Prepares the anchor image for the target model canvas and returns the prepared file URL.
    func prepareAnchor(
        anchor: ProjectIdentityAnchor,
        projectID: UUID,
        requestedWidth: Int,
        requestedHeight: Int,
        modelID: String?,
        store: FilmProjectStore = .shared
    ) throws -> URL {
        guard let originalURL = store.managedProjectAssetURL(projectID: projectID, relativePath: anchor.projectRelativePath),
              FileManager.default.fileExists(atPath: originalURL.path) else {
            throw NSError(domain: "PreparedIdentityAnchorService", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Original anchor image missing: \(anchor.projectRelativePath)"
            ])
        }

        let alignment = ModelAwareResolutionAlignment.align(
            requestedWidth: requestedWidth,
            requestedHeight: requestedHeight,
            modelID: modelID
        )
        let genWidth = alignment.generation.width
        let genHeight = alignment.generation.height

        let key = cacheKey(
            anchorID: anchor.id,
            modelID: modelID,
            generationWidth: genWidth,
            generationHeight: genHeight
        )
        let relativePreparedPath = "Assets/Anchors/Prepared/\(key)"

        guard let preparedURL = store.managedProjectAssetURL(projectID: projectID, relativePath: relativePreparedPath) else {
            throw NSError(domain: "PreparedIdentityAnchorService", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Cannot resolve prepared asset URL in project."
            ])
        }

        if FileManager.default.fileExists(atPath: preparedURL.path),
           let probe = MediaProbe.probe(path: preparedURL.path),
           probe.width == genWidth, probe.height == genHeight {
            return preparedURL
        }

        let preparedDir = preparedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: preparedDir, withIntermediateDirectories: true)

        let conditioning = try ImageConditioningPreparer.shared.prepare(
            sourceURL: originalURL,
            targetWidth: genWidth,
            targetHeight: genHeight
        )

        if FileManager.default.fileExists(atPath: preparedURL.path) {
            try? FileManager.default.removeItem(at: preparedURL)
        }
        try FileManager.default.copyItem(at: conditioning.preparedURL, to: preparedURL)

        return preparedURL
    }

    /// Cleans up all prepared cache variants for a given anchor ID.
    func invalidatePreparedCache(
        anchorID: UUID,
        projectID: UUID,
        store: FilmProjectStore = .shared
    ) {
        guard let preparedBaseURL = store.managedProjectAssetURL(
            projectID: projectID,
            relativePath: "Assets/Anchors/Prepared"
        ) else { return }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: preparedBaseURL.path) else { return }
        let prefix = "anchor_\(anchorID.uuidString)_"
        for file in files where file.hasPrefix(prefix) {
            let fullPath = preparedBaseURL.appendingPathComponent(file).path
            try? FileManager.default.removeItem(atPath: fullPath)
        }
    }

    /// Completely removes an anchor and its prepared cache from managed storage.
    func removeAnchor(
        anchor: ProjectIdentityAnchor,
        projectID: UUID,
        store: FilmProjectStore = .shared
    ) {
        invalidatePreparedCache(anchorID: anchor.id, projectID: projectID, store: store)
        if let originalURL = store.managedProjectAssetURL(projectID: projectID, relativePath: anchor.projectRelativePath) {
            try? FileManager.default.removeItem(at: originalURL)
        }
    }
}
