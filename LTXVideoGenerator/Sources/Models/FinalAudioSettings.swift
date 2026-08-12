import Foundation

/// A user-imported audio file applied once, after Final Assembly, as the
/// whole movie's background music. Mirrors `OpeningReferenceImage`'s
/// project-managed-asset shape: a project-relative path only, never an
/// external absolute path, so the project stays portable and self-contained.
struct FinalBGMAsset: Codable, Equatable {
    /// Path relative to the project directory. Its presence is what makes the
    /// asset resolvable — there is no separate "file exists" flag to fall out
    /// of sync with it.
    var projectRelativePath: String

    /// Shown in the UI so the user can tell which file this is without
    /// opening it. Never used to resolve the file.
    var originalFilename: String?

    var importedAt: Date = Date()
    var mimeType: String?
    var fileSizeBytes: Int64?
}

/// Project-level "one BGM for the whole movie" settings, applied once after
/// Final Assembly — never injected into any Shot's compiled prompt and never
/// used to re-generate per-shot audio. Absent in every project written before
/// this feature; those decode with `bgmEnabled == false`, which reproduces
/// their exact previous Final Assembly output (no BGM mix pass at all).
struct FinalAudioSettings: Codable, Equatable {
    var bgmEnabled: Bool = false
    var bgmAsset: FinalBGMAsset?

    /// Linear multiplier (0.0-1.0), matching the existing ffmpeg `volume=`
    /// filter convention already used for background music in
    /// `AudioService.swift` (0.3 alone, 0.2 ducked under voiceover) rather
    /// than introducing a separate dB convention.
    var bgmVolume: Double = 0.25

    var fadeInSeconds: Double = 0
    var fadeOutSeconds: Double = 0

    /// True only when there is something to actually mix. A leftover
    /// `bgmEnabled == true` with no asset (e.g. the asset was somehow
    /// removed from disk) must not attempt a mix with nothing to mix.
    var isActive: Bool { bgmEnabled && bgmAsset != nil }
}
