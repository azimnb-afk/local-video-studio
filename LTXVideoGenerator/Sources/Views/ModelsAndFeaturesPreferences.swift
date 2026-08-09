import SwiftUI

/// Preferences tab for the director-extension feature set: Adult Content Mode,
/// experimental feature flags, and Compatibility Lab status for derived models.
struct ModelsAndFeaturesPreferences: View {
    @AppStorage(ModelRegistry.adultModeUserDefaultsKey) private var adultContentMode = false
    @AppStorage(FeatureFlag.modelRegistryV1.userDefaultsKey) private var flagModelRegistry = FeatureFlag.modelRegistryV1.defaultEnabled
    @AppStorage(FeatureFlag.derivedModelsV1.userDefaultsKey) private var flagDerivedModels = FeatureFlag.derivedModelsV1.defaultEnabled
    @AppStorage(FeatureFlag.adultModelsV1.userDefaultsKey) private var flagAdultModels = FeatureFlag.adultModelsV1.defaultEnabled
    @AppStorage(FeatureFlag.autoQualityV1.userDefaultsKey) private var flagAutoQuality = FeatureFlag.autoQualityV1.defaultEnabled
    @AppStorage(FeatureFlag.directorV1.userDefaultsKey) private var flagDirector = FeatureFlag.directorV1.defaultEnabled
    @AppStorage(FeatureFlag.filmProjectV1.userDefaultsKey) private var flagFilmProject = FeatureFlag.filmProjectV1.defaultEnabled
    @AppStorage(FeatureFlag.storyboardV1.userDefaultsKey) private var flagStoryboard = FeatureFlag.storyboardV1.defaultEnabled
    @AppStorage(FeatureFlag.localAPIv1.userDefaultsKey) private var flagLocalAPI = FeatureFlag.localAPIv1.defaultEnabled

    var body: some View {
        Form {
            Section("Adult Content Mode") {
                Toggle("Adult Content Mode", isOn: $adultContentMode)
                    .help("Off by default. When off, adult-verified models are never auto-selected and are rejected even when requested explicitly (enforced in the service and API layers, not just here).")
                BilingualSettingDescription(
                    english: "Intended solely for consenting-adult use of adult-verified local models. Enabling this never bypasses model or content safety mechanisms.",
                    japanese: "成人同士の合意に基づき、adult-verified local modelsを使用する場合のみを対象とします。有効にしてもModelやコンテンツの安全機構を回避することはありません。"
                )
            }

            Section("Experimental Features") {
                Toggle("Model Registry", isOn: $flagModelRegistry)
                    .help("Route generation through the model registry and adapter layer. Off = legacy official path.")
                Toggle("Derived Models (Compatibility Lab)", isOn: $flagDerivedModels)
                Toggle("Adult-capable Models", isOn: $flagAdultModels)
                    .disabled(!flagDerivedModels)
                Toggle("Auto Quality", isOn: $flagAutoQuality)
                Toggle("One Shot Director", isOn: $flagDirector)
                Toggle("Film Projects (Shots & Takes)", isOn: $flagFilmProject)
                    .disabled(!flagModelRegistry)
                Toggle("Storyboard", isOn: $flagStoryboard)
                    .disabled(!flagFilmProject)
                Toggle("Local REST API v1", isOn: $flagLocalAPI)
                BilingualSettingDescription(
                    english: "GUI features (registry, auto quality, director, projects, storyboard) are on by default; unverified models, adult content and the local API stay opt-in. Turning everything off restores exactly the legacy official generation path.",
                    japanese: "GUI機能（registry、auto quality、Director、projects、Storyboard）は標準で有効です。未検証Model、adult content、local APIはユーザーが明示的に有効にします。すべてオフにすると従来の公式生成経路へ戻ります。"
                )
            }

            Section("Compatibility Lab") {
                let lab = CompatibilityLab.shared
                let labModels = ModelRegistry.shared.descriptors.values
                    .filter { !$0.isOfficial }
                    .sorted { $0.id < $1.id }
                if labModels.isEmpty {
                    Text("No derived models registered.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(labModels) { model in
                        let report = lab.report(for: model.id)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(model.displayName)
                                Spacer()
                                Text(report.allPassed ? "Verified" : "Unverified")
                                    .font(.caption.bold())
                                    .foregroundStyle(report.allPassed ? .green : .orange)
                            }
                            Text("Gate: \(report.summary) — weights are never downloaded automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                BilingualSettingDescription(
                    english: "Derived models stay unverified until every gate check passes (license, provenance, pinned revision, manifest, backend load, T2V/I2V/audio smoke, unload, memory benchmark, classification evidence). Unverified models cannot generate.",
                    japanese: "Derived modelsは、license・provenance・固定revision・manifest・backend load・T2V/I2V/audio smoke・unload・memory benchmark・classification evidenceの全確認を通るまで未検証のままです。未検証Modelでは生成できません。"
                )
            }
        }
        .formStyle(.grouped)
    }
}
