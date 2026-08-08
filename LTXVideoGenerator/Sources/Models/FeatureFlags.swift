import Foundation

/// Independent on/off switches for the director-extension feature set.
/// GUI-first defaults: user-facing features (registry, auto quality, director,
/// film projects, storyboard) ship enabled so they are reachable from the GUI
/// out of the box; anything involving unverified models, adult content,
/// unverified backends, or network listeners stays opt-in.
/// Turning every flag OFF (Preferences → Models & Features) always restores
/// the exact legacy official generation path.
enum FeatureFlag: String, CaseIterable {
    case modelRegistryV1
    case derivedModelsV1
    case adultModelsV1
    case autoQualityV1
    case lowRAMAdapterV1
    case directorV1
    case filmProjectV1
    case storyboardV1
    case localAPIv1

    var userDefaultsKey: String { "featureFlag.\(rawValue)" }

    /// Value used when the user has never touched the flag.
    var defaultEnabled: Bool {
        switch self {
        case .modelRegistryV1, .autoQualityV1, .directorV1, .filmProjectV1, .storyboardV1:
            return true
        case .derivedModelsV1, .adultModelsV1, .lowRAMAdapterV1, .localAPIv1:
            return false
        }
    }
}

enum FeatureFlags {
    static func isEnabled(_ flag: FeatureFlag, userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: flag.userDefaultsKey) == nil {
            return flag.defaultEnabled
        }
        return userDefaults.bool(forKey: flag.userDefaultsKey)
    }

    static func set(_ flag: FeatureFlag, enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: flag.userDefaultsKey)
    }

    /// Rollback: disable every experimental flag, restoring the legacy path.
    static func disableAll(userDefaults: UserDefaults = .standard) {
        for flag in FeatureFlag.allCases {
            userDefaults.set(false, forKey: flag.userDefaultsKey)
        }
    }
}
