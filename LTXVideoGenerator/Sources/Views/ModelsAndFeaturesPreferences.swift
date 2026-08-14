import SwiftUI

/// Preferences tab for advanced models, experimental feature flags, and Compatibility Lab.
struct ModelsAndFeaturesPreferences: View {
    @AppStorage(ModelRegistry.customSourceModeUserDefaultsKey) private var customSourceModeRaw = CustomModelSourceMode.huggingFace.rawValue
    @AppStorage(ModelRegistry.customRepositoryUserDefaultsKey) private var customRepo = ""
    @AppStorage(ModelRegistry.customLocalPathUserDefaultsKey) private var customLocalPath = ""
    @AppStorage(FeatureFlag.modelRegistryV1.userDefaultsKey) private var flagModelRegistry = FeatureFlag.modelRegistryV1.defaultEnabled
    @AppStorage(FeatureFlag.derivedModelsV1.userDefaultsKey) private var flagDerivedModels = FeatureFlag.derivedModelsV1.defaultEnabled
    @AppStorage(FeatureFlag.customModelsV1.userDefaultsKey) private var flagCustomModels = FeatureFlag.customModelsV1.defaultEnabled
    @AppStorage(FeatureFlag.autoQualityV1.userDefaultsKey) private var flagAutoQuality = FeatureFlag.autoQualityV1.defaultEnabled
    @AppStorage(FeatureFlag.directorV1.userDefaultsKey) private var flagDirector = FeatureFlag.directorV1.defaultEnabled
    @AppStorage(FeatureFlag.filmProjectV1.userDefaultsKey) private var flagFilmProject = FeatureFlag.filmProjectV1.defaultEnabled
    @AppStorage(FeatureFlag.storyboardV1.userDefaultsKey) private var flagStoryboard = FeatureFlag.storyboardV1.defaultEnabled
    @AppStorage(FeatureFlag.localAPIv1.userDefaultsKey) private var flagLocalAPI = FeatureFlag.localAPIv1.defaultEnabled

    private var customSourceMode: CustomModelSourceMode {
        get { CustomModelSourceMode(rawValue: customSourceModeRaw) ?? .huggingFace }
        set { customSourceModeRaw = newValue.rawValue }
    }

    var body: some View {
        Form {
            Section("Custom LTX-2 MLX Model") {
                Toggle("Enable Custom LTX-2 MLX Model Support", isOn: $flagCustomModels)
                    .help("Enable user-supplied custom models running on the ltx-2-mlx backend.")

                Picker("Model Source", selection: $customSourceModeRaw) {
                    Text("Hugging Face Repository").tag(CustomModelSourceMode.huggingFace.rawValue)
                    Text("Existing Local Model").tag(CustomModelSourceMode.local.rawValue)
                }
                .pickerStyle(.segmented)

                if customSourceMode == .huggingFace {
                    TextField("Hugging Face Repo (e.g. organization/model-name)", text: $customRepo)
                        .textFieldStyle(.roundedBorder)
                    BilingualSettingDescription(
                        english: "Configure a custom model from Hugging Face. Model weights are resolved from cache or downloaded on request.",
                        japanese: "Hugging Face のカスタムモデルを設定します。モデル重みはキャッシュまたは明示的な要求時に取得されます。"
                    )
                } else {
                    HStack {
                        TextField("Local Model Directory", text: $customLocalPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseLocalModel() }
                    }
                    BilingualSettingDescription(
                        english: "Select an existing local model or Hugging Face cache snapshot folder directly without redownloading.",
                        japanese: "ローカルにある既存のモデルフォルダまたはスナップショットを直接選択します（再ダウンロード不要）。"
                    )
                }
            }

            Section("Experimental Features") {
                Toggle("Model Registry", isOn: $flagModelRegistry)
                    .help("Route generation through the model registry and adapter layer. Off = legacy official path.")
                Toggle("Derived Models (Compatibility Lab)", isOn: $flagDerivedModels)
                Toggle("Auto Quality", isOn: $flagAutoQuality)
                Toggle("One Shot Director", isOn: $flagDirector)
                Toggle("Film Projects (Shots & Takes)", isOn: $flagFilmProject)
                    .disabled(!flagModelRegistry)
                Toggle("Storyboard", isOn: $flagStoryboard)
                    .disabled(!flagFilmProject)
                Toggle("Local REST API v1", isOn: $flagLocalAPI)
                BilingualSettingDescription(
                    english: "Core features (registry, auto quality, director, projects, storyboard) are enabled by default. Turning everything off restores exactly the legacy official generation path.",
                    japanese: "主要機能（registry、auto quality、Director、projects、Storyboard）は標準で有効です。すべてオフにすると従来の公式生成経路へ戻ります。"
                )
            }

            Section("Compatibility Lab") {
                let lab = CompatibilityLab.shared
                let labModels = ModelRegistry.shared.descriptors.values
                    .filter { !$0.isOfficial }
                    .sorted { $0.id < $1.id }
                if labModels.isEmpty {
                    Text("No custom models registered.")
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
                    english: "Custom models are verified before generation (license, provenance, pinned revision, manifest, backend load, T2V/I2V/audio smoke, unload, memory benchmark).",
                    japanese: "カスタムモデルは生成前に検証されます（ライセンス、構成、固定リビジョン、マニフェスト、バックエンド読み込み、テスト生成、メモリ）。"
                )
            }
        }
        .formStyle(.grouped)
    }

    private func chooseLocalModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the local model directory or snapshot folder"
        panel.prompt = "Choose"

        let defaultHub = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        if FileManager.default.fileExists(atPath: defaultHub.path) {
            panel.directoryURL = defaultHub
        }

        if panel.runModal() == .OK, let url = panel.url {
            customLocalPath = url.path
        }
    }
}
