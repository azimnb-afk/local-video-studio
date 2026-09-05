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
    @StateObject private var readinessStore = ModelReadinessStore.shared
    @StateObject private var modelDownloads = ModelDownloadCoordinator.shared

    var body: some View {
        Form {
            MiniMaxH3RuntimePreferenceView()

            Section("LTX-2.5 Runtime") {
                LTX2MLXRuntimePreferenceView(manager: runtimeManager)
            }

            Section("Registered Models") {
                Text("All registered models are shown here. Generation pickers show only models marked Ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(ModelRegistry.shared.selectableModels()) { model in
                    let readiness = readinessStore.readiness(for: model.id)
                        ?? ModelReadiness(modelID: model.id, status: .checking, reason: nil)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.selectionDisplayName)
                            Spacer()
                            Text(readiness.status.shortDisplayName)
                                .font(.caption.bold())
                                .foregroundStyle(readiness.canGenerate ? .green : .orange)
                        }
                        Text(readiness.reason ?? model.runtime.backend)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if readiness.status == .notDownloaded && model.isOfficial {
                            modelDownloadControl(for: model)
                        }
                    }
                }

                Button("Refresh Model Status") {
                    Task { await readinessStore.refresh() }
                }
                .disabled(readinessStore.isRefreshing)
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
                    .filter { !$0.isOfficial && !MiniMaxH3Configuration.isMiniMaxH3(modelID: $0.id) }
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
            Task { await readinessStore.refreshIfNeeded() }
        }
        .sheet(item: $editingProfile) { profile in
            CustomModelProfileEditorSheet(
                profile: profile,
                isNew: false,
                onSave: { updated in
                    try? CustomModelProfileStore.updateProfile(updated)
                    reloadProfiles()
                    Task { await readinessStore.refresh() }
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
                    Task { await readinessStore.refresh() }
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
                    Task { await readinessStore.refresh() }
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

    @ViewBuilder
    private func modelDownloadControl(for model: ModelDescriptor) -> some View {
        switch modelDownloads.state {
        case .downloading(let progress, let message):
            ProgressView(value: progress ?? 0, total: 1.0)
            Text(progress.map { "Downloading… \(Int($0 * 100))%" } ?? message)
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            HStack(spacing: 8) {
                Button("Retry Download") {
                    Task {
                        await modelDownloads.startDownload(
                            repository: model.repository,
                            estimatedSizeGB: model.estimatedModelSizeGB)
                        await readinessStore.refresh()
                    }
                }
                Text(reason).font(.caption2).foregroundStyle(.red)
            }
        case .idle, .succeeded:
            Button("Download Model") {
                Task {
                    await modelDownloads.startDownload(
                        repository: model.repository,
                        estimatedSizeGB: model.estimatedModelSizeGB)
                    await readinessStore.refresh()
                }
            }
        }
    }
}

private struct MiniMaxH3RuntimePreferenceView: View {
    @AppStorage(MiniMaxH3Configuration.standardModelDirectoryKey) private var modelDirectory = ""
    @AppStorage(MiniMaxH3Configuration.highQualityModelDirectoryKey) private var hqModelDirectory = ""
    @AppStorage(MiniMaxH3Configuration.runtimeExecutablePathKey) private var runtimeExecutable = ""
    @AppStorage(MiniMaxH3Configuration.endpointKey) private var endpoint = MiniMaxH3Configuration.defaultEndpoint
    @State private var status = MiniMaxH3RuntimeStatus(
        state: .notConfigured,
        ownership: nil,
        detail: "Readiness has not been checked.",
        loadedModelID: nil)
    @State private var isChecking = false
    @State private var managedStatus: MiniMaxH3ManagedRuntimeStatus = .notInstalled
    @State private var installProgress = 0.0
    @State private var installStep = ""
    @State private var installError: String?

    var body: some View {
        Section("MiniMax H3 (Experimental)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Runtime")
                    .font(.caption.bold())
                HStack {
                    Circle()
                        .fill(managedStatusColor)
                        .frame(width: 8, height: 8)
                    Text(managedStatusLabel)
                        .font(.caption.bold())
                    Spacer()
                    Button(managedInstallButtonLabel, action: installManagedRuntime)
                        .disabled(isInstallingManagedRuntime)
                }
                if case .installing(let progress, let step) = managedStatus {
                    ProgressView(value: progress, total: 1.0)
                    Text(step)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !installStep.isEmpty {
                    Text(installStep)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let installError {
                    Text(installError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let managedStatusDetail {
                    Text(managedStatusDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let managedPath = managedStatus.executablePath {
                    Text(managedPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(runtimeAvailabilityDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("MiniMax H3 (標準・省メモリ)")
                    .font(.caption.bold())
                HStack {
                    Circle()
                        .fill(modelDirectory.isEmpty ? Color.secondary : Color.green)
                        .frame(width: 8, height: 8)
                    Text(modelDirectory.isEmpty ? "Not Configured" : "Configured")
                        .font(.caption.bold())
                    Spacer()
                    Button("Choose Folder…", action: chooseModelDirectory)
                }
                if !modelDirectory.isEmpty {
                    Text(modelDirectory)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("Standard model (4-bit DiT, ~33GB local pack). Faster generation, suitable for 32GB+ Macs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("MiniMax H3 High Quality (より高精細・48GB以上推奨)")
                    .font(.caption.bold())
                HStack {
                    Circle()
                        .fill(hqModelDirectory.isEmpty ? Color.secondary : Color.green)
                        .frame(width: 8, height: 8)
                    Text(hqModelDirectory.isEmpty ? "Not Configured" : "Configured")
                        .font(.caption.bold())
                    Spacer()
                    Button("Choose Folder…", action: chooseHQModelDirectory)
                }
                if !hqModelDirectory.isEmpty {
                    Text(hqModelDirectory)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("High Quality model (8-bit DiT, ~49GB local pack). この高品質モデルはメモリ使用量が多いため、48GB以上のMacを推奨します。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced External Runtime") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("mlx-serve Executable Override")
                        .font(.caption.bold())
                    HStack {
                        TextField("Managed runtime is used when this is empty", text: $runtimeExecutable)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose External…", action: chooseRuntime)
                        if !runtimeExecutable.isEmpty {
                            Button("Use Managed") {
                                runtimeExecutable = ""
                            }
                        }
                    }
                    Text("Optional. A compatible pre-existing localhost server may still be reused and remains externally owned.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Local Endpoint")
                    .font(.caption.bold())
                TextField(MiniMaxH3Configuration.defaultEndpoint, text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                Text("Localhost only. Fresh Personal installs use 11237; Dev uses 11236. The app never binds H3 to 0.0.0.0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.caption.bold())
                if let ownership = status.ownership {
                    Text(ownership == .externallyRunning ? "External server (reused)" : "App-owned server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await checkReadiness() }
                } label: {
                    if isChecking { ProgressView().controlSize(.small) }
                    Text("Check Readiness")
                }
                .disabled(isChecking)
            }
            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            BilingualSettingDescription(
                english: "Experimental local renderer with native audio. Best results use a Starting Image or Opening Reference; text-only generation remains available but may be less consistent. Continued shots can use the previous final frame, and longer sequences may gradually drift. REF2VA and Motion Context are not supported.",
                japanese: "ネイティブ音声に対応する実験的なローカルレンダラーです。開始画像またはOpening Referenceの使用を推奨します。テキストのみでも生成できますが、一貫性が低下する場合があります。継続Shotでは直前の最終フレームを利用でき、長いシーケンスでは徐々にドリフトする可能性があります。REF2VAとMotion Contextには非対応です。"
            )
        }
        .onAppear {
            managedStatus = MiniMaxH3ManagedRuntimeManager.shared.evaluateStatus()
            Task { await checkReadiness() }
        }
        .onChange(of: modelDirectory) { _, _ in configurationChanged() }
        .onChange(of: hqModelDirectory) { _, _ in configurationChanged() }
        .onChange(of: runtimeExecutable) { _, _ in configurationChanged() }
        .onChange(of: endpoint) { _, _ in configurationChanged() }
    }

    private var statusLabel: String {
        switch status.state {
        case .notConfigured: return "Not Configured"
        case .notRunning: return "Stopped"
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .wrongModel: return "Wrong Model"
        case .failed, .broken: return "Failed"
        }
    }

    private var statusColor: Color {
        switch status.state {
        case .ready: return .green
        case .starting, .notRunning, .notConfigured: return .orange
        case .wrongModel, .failed, .broken: return .red
        }
    }

    private var isInstallingManagedRuntime: Bool {
        if case .installing = managedStatus { return true }
        return false
    }

    private var managedStatusLabel: String {
        switch managedStatus {
        case .notInstalled: return "Not Installed"
        case .installing: return "Installing"
        case .ready(_, let manifest): return "Ready · v\(manifest.runtimeVersion)"
        case .updateRequired: return "Update Required"
        case .broken: return "Broken"
        }
    }

    private var managedStatusColor: Color {
        switch managedStatus {
        case .ready: return .green
        case .installing, .updateRequired: return .orange
        case .notInstalled: return .secondary
        case .broken: return .red
        }
    }

    private var managedStatusDetail: String? {
        switch managedStatus {
        case .updateRequired(let reason), .broken(let reason): return reason
        case .notInstalled, .installing, .ready: return nil
        }
    }

    private var managedInstallButtonLabel: String {
        switch managedStatus {
        case .notInstalled:
            return MiniMaxH3ManagedRuntimeManager.shared.hasBundledRuntimePayload
                ? "Install Runtime" : "Install Existing Bundle…"
        case .ready:
            return MiniMaxH3ManagedRuntimeManager.shared.hasBundledRuntimePayload
                ? "Reinstall Runtime" : "Reinstall…"
        case .installing: return "Installing…"
        case .updateRequired, .broken:
            return MiniMaxH3ManagedRuntimeManager.shared.hasBundledRuntimePayload
                ? "Repair Runtime" : "Repair from Bundle…"
        }
    }

    private var runtimeAvailabilityDescription: String {
        if MiniMaxH3ManagedRuntimeManager.shared.hasBundledRuntimePayload {
            return "The app includes the verified execution runtime. Install copies it into this profile's managed Runtime folder; no model is included or downloaded."
        }
        return "This development build has no embedded payload. You may install an existing local bundle; its source is copied, never moved or deleted."
    }

    private func configurationChanged() {
        UserDefaults.standard.set(
            MiniMaxH3RuntimeState.notConfigured.rawValue,
            forKey: MiniMaxH3Configuration.lastReadinessStateKey)
        UserDefaults.standard.set(
            MiniMaxH3Configuration.standardModelID,
            forKey: MiniMaxH3Configuration.lastReadinessModelIDKey)
        Task { await DependencyHealthManager.shared.refresh() }
    }

    @MainActor
    private func checkReadiness() async {
        isChecking = true
        let snapshot = MiniMaxH3Configuration.Snapshot(
            modelDirectory: modelDirectory.isEmpty ? nil : modelDirectory,
            runtimeExecutablePath: runtimeExecutable.isEmpty ? nil : runtimeExecutable,
            endpoint: endpoint,
            targetModelID: MiniMaxH3Configuration.standardModelID)
        status = await MiniMaxH3RuntimeManager.shared.status(snapshot: snapshot)
        UserDefaults.standard.set(
            status.state.rawValue,
            forKey: MiniMaxH3Configuration.lastReadinessStateKey)
        UserDefaults.standard.set(
            status.detail,
            forKey: MiniMaxH3Configuration.lastReadinessDetailKey)
        UserDefaults.standard.set(
            snapshot.targetModelID,
            forKey: MiniMaxH3Configuration.lastReadinessModelIDKey)
        isChecking = false
        await DependencyHealthManager.shared.refresh()
    }

    private func chooseModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Standard H3 Model"
        if panel.runModal() == .OK, let url = panel.url {
            modelDirectory = url.path
        }
    }

    private func chooseHQModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select High Quality H3 Model"
        if panel.runModal() == .OK, let url = panel.url {
            hqModelDirectory = url.path
        }
    }

    private func chooseRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select mlx-serve"
        if panel.runModal() == .OK, let url = panel.url {
            runtimeExecutable = url.path
        }
    }

    private func installManagedRuntime() {
        if MiniMaxH3ManagedRuntimeManager.shared.hasBundledRuntimePayload {
            beginManagedRuntimeInstallation(source: nil)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Install Runtime Bundle"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        beginManagedRuntimeInstallation(source: source)
    }

    private func beginManagedRuntimeInstallation(source: URL?) {
        installError = nil
        installProgress = 0.05
        installStep = "Validating local runtime bundle"
        managedStatus = .installing(progress: installProgress, step: installStep)
        Task {
            do {
                let progressHandler: @Sendable (Double, String) -> Void = { progress, step in
                    Task { @MainActor in
                        installProgress = progress
                        installStep = step
                        managedStatus = .installing(progress: progress, step: step)
                    }
                }
                let manifest: MiniMaxH3ManagedRuntimeManifest
                if let source {
                    manifest = try await MiniMaxH3ManagedRuntimeManager.shared.install(
                        from: source, progress: progressHandler)
                } else {
                    manifest = try await MiniMaxH3ManagedRuntimeManager.shared.installBundled(
                        progress: progressHandler)
                }
                await MainActor.run {
                    runtimeExecutable = ""
                    managedStatus = .ready(
                        executablePath: MiniMaxH3ManagedRuntimeManager.shared.managedExecutableURL.path,
                        manifest: manifest)
                    installStep = "Runtime installed and verified. License classification: \(manifest.licenseClassification.rawValue)."
                }
                await checkReadiness()
            } catch {
                await MainActor.run {
                    installError = error.localizedDescription
                    managedStatus = MiniMaxH3ManagedRuntimeManager.shared.evaluateStatus()
                }
            }
        }
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
        .onAppear {
            // `manager.status` is seeded optimistically at init (file-existence
            // check only, no capability probe) so app launch never blocks on a
            // subprocess call. Refresh here so a runtime that's present on disk
            // but missing a newly-required capability is never shown as Ready
            // before an actual probe has run.
            if !isInstalling {
                manager.refreshStatus()
            }
        }
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
