import Foundation

/// How an Auto Movie opening shot uses its Character Anchor image.
///
/// The anchor deliberately reuses the **same conditioning strength as an
/// explicit user Starting Image** rather than inventing a weaker one, because
/// weakening it was measured and made the result worse, not better.
///
/// Measured at the product profile (768x512, 121 frames, one prompt, one seed,
/// only strength varying) with a character-sheet extraction as the reference:
///
/// - 1.00 — the opening frame is the reference image, cleanly, then the shot
///   moves into the scene.
/// - 0.45 — the opening frame is still the reference, now slightly degraded.
/// - 0.25 / 0.15 — the opening frame is a smeared, torn version of the
///   reference; lowering the strength corrupts the plate instead of replacing
///   it with a scene.
///
/// In every case the costume and face of the reference were not carried into
/// the body of the shot. So there is no strength at which a flat character-sheet
/// plate becomes a good opening frame — and given that, a clean first frame is
/// strictly better than a mangled one. See BENCHMARK_RESULTS.
enum CharacterAnchorPolicy {

    /// Same as an explicit Starting Image: the chosen picture is the frame the
    /// shot begins on. Reusing the value keeps one behaviour for "an image the
    /// user picked", rather than two that differ for no measured reason.
    static let openingImageStrength: Double = 1.0

    /// Applies to the first shot only; every later shot inherits from the shot
    /// before it, exactly as it did before this feature existed.
    static let appliesToShotIndex = 0
}
