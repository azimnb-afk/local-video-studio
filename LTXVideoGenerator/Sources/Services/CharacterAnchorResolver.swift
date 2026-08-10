import Foundation

/// Turns a project's `CharacterAnchor` into the concrete image the opening shot
/// conditions on, or into a reason it cannot.
///
/// Resolution deliberately fails loudly. A missing reference means the movie
/// would open with a different-looking protagonist than the user chose, which
/// is precisely the outcome this feature exists to prevent, so the run is
/// blocked rather than quietly falling back to text-to-video.
enum CharacterAnchorResolver {

    struct Resolved: Equatable {
        var characterName: String
        var assetID: UUID
        var assetType: CharacterReferenceAssetType
        var fileURL: URL
    }

    enum Outcome: Equatable {
        /// Not enabled, or enabled but never configured — ordinary text-to-video.
        case inactive
        case resolved(Resolved)
        case unavailable(CharacterAnchorIssue)
    }

    /// The scene-like Opening Reference Image, when one is configured.
    ///
    /// Kept in the same resolver so the opening shot has exactly one place that
    /// answers "what image, if any, does this movie start from", and so the
    /// precedence between the two is stated once rather than re-derived at each
    /// call site.
    static func resolveOpeningReference(
        project: FilmProject,
        store: FilmProjectStore = .shared
    ) -> Result<URL, OpeningReferenceIssue>? {
        guard let reference = project.openingReferenceImage else { return nil }
        guard let url = store.managedProjectAssetURL(
                  projectID: project.id, relativePath: reference.projectRelativePath),
              FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.fileMissing)
        }
        return .success(url)
    }

    static func resolve(
        project: FilmProject,
        store: FilmProjectStore = .shared
    ) -> Outcome {
        let anchor = project.characterAnchor
        guard anchor.isActive,
              let characterID = anchor.characterID,
              let assetID = anchor.referenceAssetID else {
            return .inactive
        }
        guard let character = project.characterBible.character(id: characterID) else {
            return .unavailable(.characterMissing)
        }
        guard let asset = character.referenceAssets.first(where: { $0.id == assetID }) else {
            return .unavailable(.assetMissing)
        }
        guard let relativePath = asset.projectRelativePath,
              let url = store.managedCharacterAssetURL(
                  projectID: project.id, relativePath: relativePath),
              FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable(.fileMissing)
        }
        return .resolved(Resolved(
            characterName: character.name,
            assetID: assetID,
            assetType: asset.type,
            fileURL: url
        ))
    }

    /// Convenience for the UI: the issue to show, or nil when the anchor is
    /// either inactive or usable.
    static func issue(project: FilmProject, store: FilmProjectStore = .shared) -> CharacterAnchorIssue? {
        if case .unavailable(let issue) = resolve(project: project, store: store) {
            return issue
        }
        return nil
    }
}
