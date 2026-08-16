import SwiftUI

/// Preferences tab for advanced models, multi custom model profiles, experimental feature flags, and Compatibility Lab.
struct ModelsAndFeaturesPreferences: View {
    @AppStorage(FeatureFlag.customModelsV1.userDefaultsKey) private var flagCustomModels = FeatureFlag.customModelsV1.defaultEnabled
    @AppStorage(FeatureFlag.modelRegistryV1.userDefaultsKey) private var flagModelRegistry = FeatureFlag.modelRegistryV1.defaultEnabled
    @AppStorage(FeatureFlag.derivedModelsV1.userDefaultsKey) private var flagDerivedModels = FeatureFlag.derivedModelsV1.defaultEnabled
    @AppStorage(FeatureFlag.autoQualityV1.userDefaultsKey) private var flagAutoQuality = FeatureFlag.autoQualityV1.defaultEnabled
    @AppStorage(FeatureFlag.directorV1.userDefaultsKey) private var flagDirector = FeatureFlag.directorV1.defaultEnabled
    @AppStorage(FeatureFlag.filmProjectV1.userDefaultsKey) private var flagFilmProject = FeatureFlag.filmProjectV1.defaultEnabled
    @AppStorage(FeatureFlag.storyboardV1.userDefaultsKey) private var flagStoryboard = FeatureFlag.storyboardV1.defaultEnabled
    @AppStorage(FeatureFlag.localAPIv1.userDefaultsKey) private var flagLocalAPI = FeatureFlag.localAPIv1.defaultEnabled

    @State private var profiles: [CustomModelProfile] = []
    @State private var editingProfile: CustomModelProfile? = nil
    @State private var isShowingAddSheet = false
    @State private var profileToDelete: CustomModelProfile? = nil
    @StateObject private var runtimeManager = LTX2MLXRuntimeManager.shared

    var body: some View {
        Form {
            Section("LTX-2.5 Runtime") {
                LTX2MLXRuntimePreferenceView(manager: runtimeManager)
            }

            Section("Custom Models") {
                Toggle("Enable Custom Model Profiles", isOn: $flagCustomModels)
                    .help("Enable user-supplied custom model profiles running on the ltx-2-mlx backend.")

                if flagCustomModels {
                    if profiles.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No custom models configured.")
                                .foregroundStyle(.secondary)
                            Button {
                                startAddProfile()
                            } label: {
                                Label("Add Custom Model", systemImage: "plus")
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(profiles) { profile in
                            profileRow(profile)
                        }

                        HStack {
                            Button {
                                startAddProfile()
                            } label: {
                                Label("Add Custom Model", systemImage: "plus")
                            }
                            .disabled(profiles.count >= CustomModelProfileStore.maxProfiles)

                            Spacer()

                            Text("\(profiles.count) / \(CustomModelProfileStore.maxProfiles) models")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }

                    BilingualSettingDescription(
                        english: "Configure up to 5 custom local model directories. References only — model files on disk are never modified or deleted.",
                        japanese: "最大5件のカスタムローカルモデルフォルダを設定できます（参照のみ管理し、ディスク上のファイルは削除・変更されません）。"
                    )
                }
            }

            Section("Experimental Features") {
                Toggle("Model Registry", isOn: $flagModelRegistry)
                    .help("Route generation through the model registry and adapter layer. Off = legacy official path.")
                Toggle("Derived Models (Compatibility Lab)", isOn: $flagDerivedModels)
                Toggle("Auto Quality", isOn: $flagAutoQuality)
                Toggle("One Shot Director", isOn: $flagDirector)
                Toggle("Film Projects (Shots & Takes)", isOn: filmProjectBinding)
                    .disabled(!flagModelRegistry)
                Toggle("Storyboard", isOn: storyboardBinding)
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
        .onAppear {
            reloadProfiles()
        }
        .sheet(item: $editingProfile) { profile in
            CustomModelProfileEditorSheet(
                profile: profile,
                isNew: false,
                onSave: { updated in
                    try? CustomModelProfileStore.updateProfile(updated)
                    reloadProfiles()
                    editingProfile = nil
                },
                onCancel: {
                    editingProfile = nil
                }
            )
        }
        .sheet(isPresented: $isShowingAddSheet) {
            CustomModelProfileEditorSheet(
                profile: CustomModelProfile(
                    displayName: "Custom Model \(profiles.count + 1)",
                    modelPath: ""
                ),
                isNew: true,
                onSave: { newProfile in
                    try? CustomModelProfileStore.addProfile(newProfile)
                    reloadProfiles()
                    isShowingAddSheet = false
                },
                onCancel: {
                    isShowingAddSheet = false
                }
            )
        }
        .confirmationDialog(
            "Remove this model from Local Video Studio?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Model", role: .destructive) {
                if let target = profileToDelete {
                    CustomModelProfileStore.removeProfile(id: target.id)
                    reloadProfiles()
                    profileToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                profileToDelete = nil
            }
        } message: {
            Text("The model files on disk will not be deleted.")
        }
    }

    private var filmProjectBinding: Binding<Bool> {
        Binding(
            get: { flagFilmProject && flagModelRegistry },
            set: { flagFilmProject = $0 }
        )
    }

    private var storyboardBinding: Binding<Bool> {
        Binding(
            get: { flagStoryboard && flagFilmProject },
            set: { flagStoryboard = $0 }
        )
    }

    @ViewBuilder
    private func profileRow(_ profile: CustomModelProfile) -> some View {
        let readiness = CustomModelProfileStore.readiness(for: profile)
        let abbreviatedPath = abbreviateHome(path: profile.modelPath)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(profile.displayName)
                            .font(.headline)
                        Text(profile.modelFamily == "LTX" ? "Custom LTX-2 MLX Model" : profile.modelFamily)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text(abbreviatedPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(readiness.isReady ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(readiness.isReady ? "Ready" : (readiness.detail.isEmpty ? "Not Ready" : readiness.detail))
                        .font(.caption)
                        .foregroundStyle(readiness.isReady ? .primary : .secondary)
                }

                HStack(spacing: 8) {
                    Button("Edit") {
                        editingProfile = profile
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        profileToDelete = profile
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func startAddProfile() {
        guard profiles.count < CustomModelProfileStore.maxProfiles else { return }
        isShowingAddSheet = true
    }

    private func reloadProfiles() {
        profiles = CustomModelProfileStore.loadProfiles()
    }

    private func abbreviateHome(path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// Focused sheet to add or edit a CustomModelProfile.
struct CustomModelProfileEditorSheet: View {
    @State var profile: CustomModelProfile
    let isNew: Bool
    let onSave: (CustomModelProfile) -> Void
    let onCancel: () -> Void

    @State private var displayName: String
    @State private var modelPath: String
    @State private var modelFamily: String

    init(
        profile: CustomModelProfile,
        isNew: Bool,
        onSave: @escaping (CustomModelProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.profile = profile
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _displayName = State(initialValue: profile.displayName)
        _modelPath = State(initialValue: profile.modelPath)
        _modelFamily = State(initialValue: profile.modelFamily)
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add Custom Model" : "Edit Custom Model")
                .font(.headline)
                .padding()

            Divider()

            Form {
                Section("Model Information") {
                    TextField("Display Name", text: $displayName)
                        .textFieldStyle(.roundedBorder)

                    Picker("Model Type", selection: $modelFamily) {
                        Text("Custom LTX-2 MLX Model").tag("LTX")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Model Folder", text: $modelPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") {
                                chooseFolder()
                            }
                        }
                        Text("Select the directory containing the model's .safetensors or .gguf files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    var updated = profile
                    updated.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.modelPath = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.modelFamily = modelFamily
                    onSave(updated)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 340)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the local model directory"
        panel.prompt = "Choose"

        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultModels = home.appendingPathComponent("Models")
        if FileManager.default.fileExists(atPath: defaultModels.path) {
            panel.directoryURL = defaultModels
        } else {
            let defaultHub = home.appendingPathComponent(".cache/huggingface/hub")
            if FileManager.default.fileExists(atPath: defaultHub.path) {
                panel.directoryURL = defaultHub
            }
        }

        if panel.runModal() == .OK, let url = panel.url {
            modelPath = url.path
        }
    }
}

/// View displaying the app-managed LTX-2.5 runtime state with install/update/repair actions.
struct LTX2MLXRuntimePreferenceView: View {
    @ObservedObject var manager: LTX2MLXRuntimeManager
    @State private var isInstalling = false
    @State private var installProgress: Double = 0.0
    @State private var installStep: String = ""
    @State private var errorMessage: String? = nil
    @State private var showOverrideSettings = false
    @AppStorage(LTX2MLXRuntimeManager.overrideExecutableKey) private var overridePath: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let currentStatus = manager.status

            HStack(spacing: 8) {
                switch currentStatus {
                case .ready:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Runtime: Ready")
                        .font(.headline)
                case .notInstalled:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                    Text("Runtime: Not Installed")
                        .font(.headline)
                case .installing:
                    ProgressView()
                        .controlSize(.small)
                    Text("Runtime: Installing…")
                        .font(.headline)
                case .outdated:
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Runtime: Update Required")
                        .font(.headline)
                case .broken:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Runtime: Issue Detected")
                        .font(.headline)
                }

                Spacer()

                switch currentStatus {
                case .notInstalled:
                    Button("Install LTX-2.5 Runtime") {
                        startInstallation()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                case .outdated:
                    Button("Update Runtime") {
                        startInstallation()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                case .broken:
                    Button("Repair Runtime") {
                        startInstallation()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                case .ready, .installing:
                    EmptyView()
                }
            }

            Text(currentStatus.displayMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if isInstalling {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: installProgress, total: 1.0)
                    Text(installStep)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            DisclosureGroup("Advanced Developer Override", isExpanded: $showOverrideSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Optionally specify an external ltx-2-mlx executable path for local development:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Path to ltx-2-mlx binary", text: $overridePath)
                            .textFieldStyle(.roundedBorder)
                        if !overridePath.isEmpty {
                            Button("Clear") {
                                overridePath = ""
                                manager.setOverrideExecutablePath(nil)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)

            BilingualSettingDescription(
                english: "Local Video Studio automatically manages an isolated LTX-2.5 runtime environment with Metal-optimized MLX and GGUF block streaming support.",
                japanese: "Local Video Studio は、Metal 最適化 MLX と GGUF ブロックストリーミングに対応した隔離 LTX-2.5 ランタイム環境を自動管理します。"
            )
        }
        .padding(.vertical, 4)
    }

    private func startInstallation() {
        isInstalling = true
        errorMessage = nil
        installProgress = 0.05
        installStep = "Starting…"

        Task {
            do {
                try await manager.installManagedRuntime { progress, step in
                    DispatchQueue.main.async {
                        self.installProgress = progress
                        self.installStep = step
                    }
                }
                DispatchQueue.main.async {
                    self.isInstalling = false
                    self.installStep = "Complete"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isInstalling = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
