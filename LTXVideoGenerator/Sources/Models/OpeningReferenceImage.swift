import Foundation

/// A scene-like still that becomes the first frame of an Auto Movie's opening
/// shot.
///
/// This is a different idea from `CharacterAnchor`, and the two are kept apart
/// deliberately. A Character Anchor points at a Character Bible asset — usually
/// a figure extracted from a character sheet, standing on a flat background.
/// Measurement showed that such a plate becomes the opening frame verbatim, and
/// that its costume and face are not carried into the shot that follows.
///
/// An Opening Reference Image is the user saying "start the movie from *this
/// frame*". The backend conditions on it exactly the way an explicit Starting
/// Image works, so the closer the picture already is to a real movie frame —
/// character, wardrobe, place, light — the better the result, and the more
/// there is for the continuity chain to carry into shots 2, 3 and 4.
///
/// Stored as a project-managed copy. The external original is never moved,
/// never modified, and never persisted as an absolute path, so a project keeps
/// working after the source file is moved or renamed.
struct OpeningReferenceImage: Codable, Equatable {

    /// Path relative to the project directory. Its presence is what makes the
    /// reference active — there is no separate enabled flag to fall out of sync
    /// with it.
    var projectRelativePath: String

    /// Shown in the UI so the user can tell which picture this is without
    /// opening it. Never used to resolve the file.
    var originalFilename: String?

    var importedAt: Date = Date()

    var mimeType: String?

    var fileSizeBytes: Int64?
}

/// Why a configured Opening Reference cannot be used. Surfaced rather than
/// swallowed: a user who chose a specific opening frame must not silently get a
/// text-to-video stranger instead.
enum OpeningReferenceIssue: String, Codable, Equatable, Error {
    case fileMissing

    var message: String {
        switch self {
        case .fileMissing:
            return "The opening reference image file is missing from this project."
        }
    }
}
