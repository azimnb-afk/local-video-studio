import Foundation

/// Independent on/off switches for the director-extension feature set.
/// All flags default OFF: with every flag disabled the app behaves exactly like
/// the legacy official LTX generation path.
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
}

enum FeatureFlags {
    static func isEnabled(_ flag: FeatureFlag, userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: flag.userDefaultsKey)
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
