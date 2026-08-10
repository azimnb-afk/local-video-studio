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
