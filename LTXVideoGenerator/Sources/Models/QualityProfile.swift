import Foundation

enum QualityMode: String, Codable, CaseIterable {
    case auto
    case high
    case compact
    case advanced   // user-controlled parameters, Auto Quality does not touch them
}

/// The user-facing generation choice shared by Generate, One Shot,
/// Storyboard and Hybrid. `QualityMode` remains the internal execution
/// strategy; views must not duplicate this mapping.
enum GenerationPreset: String, Codable, CaseIterable, Identifiable {
    case quickPreview
    case standard
    case highQuality
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quickPreview: return "Quick Preview"
        case .standard: return "Standard"
        case .highQuality: return "High Quality"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .quickPreview: return "Fast, low-load review render"
        case .standard: return "Recommended; adapts safely to this Mac"
        case .highQuality: return "Highest quality with automatic fallback"
        case .custom: return "Manual resolution, frames, FPS and steps"
        }
    }

    var qualityMode: QualityMode {
        switch self {
        case .quickPreview: return .compact
        case .standard: return .auto
        case .highQuality: return .high
        case .custom: return .advanced
        }
    }

    static func resolving(presetRaw: String?, qualityModeRaw: String?) -> GenerationPreset {
        if let presetRaw, let preset = GenerationPreset(rawValue: presetRaw) {
            return preset
        }
        switch qualityModeRaw.flatMap(QualityMode.init(rawValue:)) {
        case .compact: return .quickPreview
        case .high: return .highQuality
        case .advanced: return .custom
        case .auto, .none: return .standard
        }
    }
}

/// A concrete, orderable generation profile. Profiles form a ladder; Auto
/// Quality walks down the ladder on failure and records successes per
/// hardware signature.
struct QualityProfile: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var width: Int
    var height: Int
    var numFrames: Int
    var numInferenceSteps: Int
    var fps: Int
    var audioEnabled: Bool
    var vaeTilingMode: String
    /// Estimated peak unified-memory footprint in GB. Seeded from Phase 0
    /// measurements; refined by actual benchmark history over time.
    var estimatedPeakGB: Double
    /// Ladder position: higher rank = higher quality.
    var rank: Int

    func applied(to parameters: GenerationParameters) -> GenerationParameters {
        var params = parameters
        params.width = width
        params.height = height
        params.numFrames = numFrames
        params.numInferenceSteps = numInferenceSteps
        params.fps = fps
        params.vaeTilingMode = vaeTilingMode
        return params
    }
}

enum QualityProfileLadder {
    /// Measured anchors (M4 Pro 48GB, ltx23_distilled_q4 + gemma-3-12b-4bit):
    /// 512x320x25f audio ON ≈ 23.7GB peak; audio OFF ≈ 17.2GB peak.
    /// Larger profiles are Calculated (scaled), not Measured — refined by history.
    static let compact0 = QualityProfile(
        id: "C0", displayName: "Compact (minimum)",
        width: 512, height: 320, numFrames: 25, numInferenceSteps: 15, fps: 24,
        audioEnabled: false, vaeTilingMode: "aggressive",
        estimatedPeakGB: 17.5, rank: 0
    )
    static let compact1 = QualityProfile(
        id: "C1", displayName: "Compact (2s)",
        width: 512, height: 320, numFrames: 49, numInferenceSteps: 15, fps: 24,
        audioEnabled: false, vaeTilingMode: "aggressive",
        estimatedPeakGB: 19.0, rank: 1
    )
    static let compact2 = QualityProfile(
        id: "C2", displayName: "Compact (2.7s)",
        width: 512, height: 320, numFrames: 65, numInferenceSteps: 15, fps: 24,
        audioEnabled: false, vaeTilingMode: "aggressive",
        estimatedPeakGB: 20.5, rank: 2
    )
    static let compactAudio = QualityProfile(
        id: "C3", displayName: "Compact + audio",
        width: 512, height: 320, numFrames: 49, numInferenceSteps: 15, fps: 24,
        audioEnabled: true, vaeTilingMode: "aggressive",
        estimatedPeakGB: 25.5, rank: 3
    )
    static let standard = QualityProfile(
        id: "S0", displayName: "Standard",
        width: 768, height: 512, numFrames: 73, numInferenceSteps: 25, fps: 24,
        audioEnabled: true, vaeTilingMode: "auto",
        estimatedPeakGB: 30.0, rank: 4
    )
    static let high = QualityProfile(
        id: "H0", displayName: "High",
        width: 768, height: 512, numFrames: 121, numInferenceSteps: 30, fps: 24,
        audioEnabled: true, vaeTilingMode: "auto",
        estimatedPeakGB: 34.0, rank: 5
    )

    static let all: [QualityProfile] = [compact0, compact1, compact2, compactAudio, standard, high]

    static func profile(id: String) -> QualityProfile? {
        all.first { $0.id == id }
    }

    /// Profiles at or below the given rank, highest first (fallback order).
    static func descending(fromRank rank: Int) -> [QualityProfile] {
        all.filter { $0.rank <= rank }.sorted { $0.rank > $1.rank }
    }
}
