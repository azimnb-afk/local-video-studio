import Foundation

/// How an Auto Movie opening shot uses its Opening Reference Image.
///
/// The same 1.0 an explicit Starting Image uses: the picture the user chose is
/// the frame the shot begins on. The Character Anchor calibration established
/// that lowering this value does not turn a conditioning image into an
/// identity-only hint — it corrupts the image instead — so there is no reason
/// to treat a deliberately scene-like still more weakly than any other frame
/// the user picked.
enum OpeningReferencePolicy {

    static let openingImageStrength: Double = 1.0

    /// First shot only. Shots 2+ inherit from the shot before them, unchanged.
    static let appliesToShotIndex = 0
}
