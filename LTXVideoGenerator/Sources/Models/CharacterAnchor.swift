import Foundation

/// An optional visual reference used to establish the protagonist in an Auto
/// Movie's **opening shot only**.
///
/// This is not identity lock. The backend takes a single conditioning image for
/// the first frame, so what this buys is a stronger starting point for the
/// appearance the continuity chain then carries forward — face, hair, clothing
/// and silhouette are more likely to persist, but nothing about the model
/// guarantees the same person.
///
/// Deliberately project-level rather than per-shot: it describes how the movie
/// begins, and resolving it at generation time keeps a single source of truth
/// for the whole run. Shot 2 onward inherit from the previous shot exactly as
/// before — the reference is never re-injected.
struct CharacterAnchor: Codable, Equatable {

    /// Off by default, and off for every project saved before this existed.
    var isEnabled: Bool = false

    /// Character in the project's own CharacterBible.
    var characterID: UUID?

    /// The specific reference asset to condition on. Held by identity rather
    /// than by type so re-analysing a sheet cannot silently swap the picture
    /// the user chose.
    var referenceAssetID: UUID?

    /// The type the asset had when it was chosen. Display only — asset identity
    /// is what resolves — but it keeps the UI honest after a reload.
    var referenceAssetType: String?

    var isConfigured: Bool { characterID != nil && referenceAssetID != nil }

    /// True when the anchor should actually supply an image.
    var isActive: Bool { isEnabled && isConfigured }

    /// Reference types offered for anchoring, best first.
    ///
    /// `front` leads because it carries face, hair, clothing and proportions in
    /// one frame at a framing a shot can move away from. `face` is offered but
    /// not preferred: it holds the face best and pulls the opening toward a
    /// close-up, which is a real cost for an establishing shot. A raw character
    /// sheet is deliberately absent — it is a multi-pose layout on a flat
    /// background, not a frame any shot should start from.
    static let offeredTypes: [CharacterReferenceAssetType] = [
        .front, .side, .back, .expression, .face, .costumeDetail,
    ]

    /// Default pick from what a character actually has, in preference order.
    static func preferredAsset(
        for character: BibleCharacter
    ) -> CharacterReferenceAsset? {
        for type in offeredTypes {
            if let match = character.referenceAssets.first(where: { $0.type == type }) {
                return match
            }
        }
        return nil
    }
}

/// Why an anchor could not supply an image. Surfaced rather than swallowed:
/// silently rendering a different-looking protagonist is the exact failure this
/// feature exists to avoid.
enum CharacterAnchorIssue: String, Codable, Equatable {
    case characterMissing
    case assetMissing
    case fileMissing

    var message: String {
        switch self {
        case .characterMissing:
            return "The anchored character is no longer in this project's Character Bible."
        case .assetMissing:
            return "The anchored reference image is no longer in this character's assets."
        case .fileMissing:
            return "The anchored reference image file is missing on disk."
        }
    }
}
