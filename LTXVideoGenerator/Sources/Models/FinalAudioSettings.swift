import Foundation

/// A user-imported audio file applied once, after Final Assembly, as the
/// whole movie's background music. Mirrors `OpeningReferenceImage`'s
/// project-managed-asset shape: a project-relative path only, never an
/// external absolute path, so the project stays portable and self-contained.
struct FinalAudioAsset: Codable, Equatable {
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
    var bgmAsset: FinalAudioAsset?
    var bgmVolume: Double = 0.25
    var fadeInSeconds: Double = 0
    var fadeOutSeconds: Double = 0

    var ambienceEnabled: Bool = false
    var ambienceAsset: FinalAudioAsset?
    var ambienceVolume: Double = 0.20
    var ambienceFadeInSeconds: Double = 0
    var ambienceFadeOutSeconds: Double = 0

    var isBGMActive: Bool { bgmEnabled && bgmAsset != nil }
    var isAmbienceActive: Bool { ambienceEnabled && ambienceAsset != nil }
    var isActive: Bool { isBGMActive || isAmbienceActive }

    enum CodingKeys: String, CodingKey {
        case bgmEnabled, bgmAsset, bgmVolume, fadeInSeconds, fadeOutSeconds
        case ambienceEnabled, ambienceAsset, ambienceVolume, ambienceFadeInSeconds, ambienceFadeOutSeconds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bgmEnabled = try container.decodeIfPresent(Bool.self, forKey: .bgmEnabled) ?? false
        bgmAsset = try container.decodeIfPresent(FinalAudioAsset.self, forKey: .bgmAsset)
        bgmVolume = try container.decodeIfPresent(Double.self, forKey: .bgmVolume) ?? 0.25
        fadeInSeconds = try container.decodeIfPresent(Double.self, forKey: .fadeInSeconds) ?? 0
        fadeOutSeconds = try container.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? 0

        ambienceEnabled = try container.decodeIfPresent(Bool.self, forKey: .ambienceEnabled) ?? false
        ambienceAsset = try container.decodeIfPresent(FinalAudioAsset.self, forKey: .ambienceAsset)
        ambienceVolume = try container.decodeIfPresent(Double.self, forKey: .ambienceVolume) ?? 0.20
        ambienceFadeInSeconds = try container.decodeIfPresent(Double.self, forKey: .ambienceFadeInSeconds) ?? 0
        ambienceFadeOutSeconds = try container.decodeIfPresent(Double.self, forKey: .ambienceFadeOutSeconds) ?? 0
    }
}
