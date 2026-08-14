import SwiftUI

struct BilingualSettingDescription: View {
    let english: String
    let japanese: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(english)
            Text(japanese)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PreferencesView: View {
    @AppStorage("pythonPath") private var pythonPath = ""
    @AppStorage("outputDirectory") private var outputDirectory = ""
    @AppStorage("autoLoadModel") private var autoLoadModel = false
    @AppStorage("keepCompletedInQueue") private var keepCompletedInQueue = false
    @State private var elevenLabsApiKey = KeychainCredentialStore.shared.elevenLabsApiKey
    @AppStorage("defaultAudioSource") private var defaultAudioSource = "elevenlabs"
    @AppStorage("enableGemmaPromptEnhancement") private var enableGemmaPromptEnhancement = false
    @AppStorage("saveAudioTrackSeparately") private var saveAudioTrackSeparately = false
    @AppStorage(LTXModelCatalog.selectedModelIDKey) private var selectedModelID = LTXModelCatalog.defaultModelID
    @AppStorage(LTXTextEncoderCatalog.selectedTextEncoderIDKey) private var selectedTextEncoderID = LTXTextEncoderCatalog.defaultTextEncoderID
    @AppStorage(LTXTextEncoderCatalog.customTextEncoderRepoKey) private var customTextEncoderRepo = ""
    @AppStorage(LTX2MLXRuntime.executablePathKey) private var ltx2mlxExecutablePath = ""
    @AppStorage("adultContentModeEnabled") private var adultContentModeEnabled = false

    @State private var pythonStatus: (success: Bool, message: String)?
    @State private var pythonDetails: PythonDetails?
    @State private var isValidating = false
    @State private var isDetecting = false
    @State private var isInstalling = false
    @State private var detectedPaths: [String] = []
    @State private var showPathPicker = false
    @State private var installMessage: String?
    @State private var isTestingElevenLabs = false
    @State private var elevenLabsTestResult: (success: Bool, message: String)?
    @State private var showResetConfirm = false

    private var selectedModel: LTXModel {
        LTXModelCatalog.resolvedModel(id: selectedModelID)
    }

    private var selectedTextEncoder: LTXTextEncoder {
        LTXTextEncoderCatalog.resolvedTextEncoder(id: selectedTextEncoderID)
    }

    private var selectedTextEncoderJapaneseTips: String? {
        switch selectedTextEncoderID {
        case "gemma3_12b_bf16":
            return "品質を優先する標準設定です。テキストエンコード時に多くのメモリを使用します。"
        case "gemma3_4b_bf16":
            return "12B bf16よりメモリ使用量が少なく、32 GB Macで品質とメモリのバランスを取りやすい設定です。"
        case "gemma3_12b_4bit":
            return "16 GB Macや、12B bf16 Text Encoderがシステムに強制終了される場合に推奨します。"
        default:
            return nil
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "Version \(version) (Build \(build))"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            BilingualPageHeader(
                title: "Settings",
                englishDescription: "Configure generation, models, local AI, and application behavior.",
                japaneseDescription: "動画生成・モデル・ローカルAI・アプリの動作を設定します。"
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .layoutPriority(1)
            Divider()
            TabView {
            // General
            Form {
                Section("Python Environment") {
                    HStack {
                        TextField("Python Path", text: $pythonPath)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Browse...") {
                            selectPythonPath()
                        }
                        
                        Button("Auto Detect") {
                            detectPython()
                        }
                        .disabled(isDetecting)
                    }
                    
                    // Path type indicator
                    if !pythonPath.isEmpty {
                        let pathType = PythonEnvironment.shared.detectPathType(pythonPath)
                        HStack {
                            Image(systemName: pathTypeIcon(pathType))
                                .foregroundStyle(pathTypeColor(pathType))
                            Text(pathTypeDescription(pathType))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Status display
                    if isValidating || isDetecting || isInstalling {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text(isDetecting ? "Searching for Python installations..." : 
                                 isInstalling ? "Installing MLX packages..." :
                                 "Validating Python setup...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let status = pythonStatus {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top) {
                                Image(systemName: status.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(status.success ? .green : .red)
                                Text(status.message)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            
                            // Show details if available
                            if let details = pythonDetails {
                                VStack(alignment: .leading, spacing: 2) {
                                    if !details.executablePath.isEmpty {
                                        Text("Executable: \(details.executablePath)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if details.hasMLX {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.seal.fill")
                                                .foregroundStyle(.green)
                                            Text("MLX Ready")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        }
                                        .padding(.leading, 20)
                                    }
                                }
                                .padding(.leading, 20)
                                
                                // Offer to install missing packages
                                if !details.missingPackages.isEmpty {
                                    let isVenv = PythonEnvironment.shared.isVirtualEnvironment(details.executablePath)
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        if isVenv {
                                            // Can install directly to venv
                                            Text("Install/upgrade required packages:")
                                                .font(.caption.bold())
                                            
                                            HStack {
                                                Text("pip install -U \(details.missingPackages.joined(separator: " "))")
                                                    .font(.caption.monospaced())
                                                    .textSelection(.enabled)
                                                    .padding(6)
                                                    .background(Color.secondary.opacity(0.1))
                                                    .cornerRadius(4)
                                                
                                                Button("Install/Upgrade") {
                                                    installMissingPackages(pythonPath: details.executablePath, packages: details.missingPackages, upgrade: true)
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .disabled(isInstalling)
                                            }
                                        } else {
                                            // System Python - need to create venv first
                                            HStack(alignment: .top, spacing: 8) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .foregroundStyle(.orange)
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text("System Python Detected")
                                                        .font(.caption.bold())
                                                    BilingualSettingDescription(
                                                        english: "This Python doesn't allow global pip installs. Create a virtual environment to install packages.",
                                                        japanese: "このPythonではglobal pip installを利用できません。packageを導入するにはvirtual environmentを作成してください。"
                                                    )
                                                }
                                            }
                                            
                                            Button("Create Virtual Environment & Install") {
                                                createVenvAndInstall(basePython: details.executablePath, packages: details.missingPackages)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(isInstalling)
                                            
                                            BilingualSettingDescription(
                                                english: "This will create ~/ltx-venv and install packages there",
                                                japanese: "~/ltx-venvを作成し、その中へpackageをインストールします。"
                                            )
                                        }
                                    }
                                    .padding(.top, 4)
                                }

                                // Offer explicit upgrade action for outdated packages
                                if !details.packagesNeedingUpgrade.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Upgrade required packages:")
                                            .font(.caption.bold())

                                        HStack {
                                            Text("pip install -U \(details.packagesNeedingUpgrade.joined(separator: " "))")
                                                .font(.caption.monospaced())
                                                .textSelection(.enabled)
                                                .padding(6)
                                                .background(Color.secondary.opacity(0.1))
                                                .cornerRadius(4)

                                            Button("Upgrade") {
                                                installMissingPackages(pythonPath: details.executablePath, packages: details.packagesNeedingUpgrade, upgrade: true)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(isInstalling)
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            
                            // Show install result
                            if let msg = installMessage {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    
                    HStack {
                        Button("Validate Setup") {
                            validatePython()
                        }
                        .disabled(isValidating || pythonPath.isEmpty)
                        
                        if !detectedPaths.isEmpty {
                            Button("Show Detected (\(detectedPaths.count))") {
                                showPathPicker = true
                            }
                        }
                    }
                    
                    BilingualSettingDescription(
                        english: "Supports both Python executable (e.g., /opt/homebrew/bin/python3) and dylib paths. Auto Detect will search common locations including Homebrew, pyenv, conda, and virtualenvs.",
                        japanese: "Python実行ファイルとdylibのパスに対応しています。Auto DetectはHomebrew、pyenv、conda、virtualenvなどの一般的な場所を検索します。"
                    )
                }
                
                Section("Model") {
                    Picker("Model", selection: $selectedModelID) {
                        ForEach(LTXModelCatalog.all) { model in
                            Text("\(model.displayName) (\(model.downloadSize))").tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "waveform.badge.checkmark")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedModel.displayName)
                                .font(.caption.bold())
                            BilingualSettingDescription(
                                english: "Uses \(selectedModel.repo) (\(selectedModel.downloadSize) download). Model cached in ~/.cache/huggingface/",
                                japanese: "\(selectedModel.repo)を使用します（ダウンロード容量: \(selectedModel.downloadSize)）。Modelは~/.cache/huggingface/に保存されます。"
                            )
                        }
                    }
                    .padding(.vertical, 4)

                    if let qualityWarning = selectedModel.qualityWarning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(qualityWarning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Custom LTX-2 MLX models run on a second local runtime.
                    if FeatureFlags.isEnabled(.customModelsV1) {
                        Divider()
                        CustomLTX2MLXRuntimeSection(executablePath: $ltx2mlxExecutablePath)
                    }

                    Picker("Text Encoder", selection: $selectedTextEncoderID) {
                        ForEach(LTXTextEncoderCatalog.all) { textEncoder in
                            Text("\(textEncoder.displayName) (\(textEncoder.downloadSize))").tag(textEncoder.id)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "textformat.abc")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedTextEncoder.displayName)
                                .font(.caption.bold())
                            BilingualSettingDescription(
                                english: "Uses \(selectedTextEncoder.repo) for generation prompt encoding.",
                                japanese: "生成プロンプトのエンコードに\(selectedTextEncoder.repo)を使用します。"
                            )
                            if let tips = selectedTextEncoder.tips,
                               let japaneseTips = selectedTextEncoderJapaneseTips {
                                BilingualSettingDescription(
                                    english: tips,
                                    japanese: japaneseTips
                                )
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if let qualityWarning = selectedTextEncoder.qualityWarning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(qualityWarning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if selectedTextEncoderID == "custom" {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Custom text encoder repo (Hugging Face id)")
                                .font(.caption.bold())
                            TextField("e.g. mlx-community/gemma-3-12b-it-4bit", text: $customTextEncoderRepo)
                                .textFieldStyle(.roundedBorder)
                            BilingualSettingDescription(
                                english: "The app does not download weights until you run a generation. Use any MLX-compatible Gemma repo your Python environment supports.",
                                japanese: "生成を実行するまでweightsはダウンロードされません。現在のPython環境が対応するMLX互換Gemma repoを指定してください。"
                            )
                        }
                    }
                    
                    Toggle("Auto-load model on startup", isOn: $autoLoadModel)
                }
                .onChange(of: selectedModelID) { _, _ in
                    // A newly selected model is very likely not downloaded yet.
                    // Re-check dependency health now so the setup dashboard and
                    // Generate button reflect the new selection immediately,
                    // instead of showing stale status from before the change.
                    Task { await DependencyHealthManager.shared.refresh() }
                }
                .onChange(of: selectedTextEncoderID) { _, _ in
                    // A different selection invalidates any Download/Failed
                    // state left over from the previous encoder — it must not
                    // leak into the newly selected one's setup row.
                    TextEncoderDownloadCoordinator.shared.resetForNewSelection()
                    Task { await DependencyHealthManager.shared.refresh() }
                }
                .onChange(of: customTextEncoderRepo) { _, _ in
                    if selectedTextEncoderID == "custom" {
                        TextEncoderDownloadCoordinator.shared.resetForNewSelection()
                        Task { await DependencyHealthManager.shared.refresh() }
                    }
                }

                Section("Storage") {
                    HStack {
                        TextField("Output Directory", text: $outputDirectory)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Browse...") {
                            selectOutputDirectory()
                        }
                        
                        Button("Open") {
                            openOutputDirectory()
                        }
                    }
                    
                    BilingualSettingDescription(
                        english: "Leave empty to use default location in Application Support",
                        japanese: "空欄の場合はApplication Support内の標準保存先を使用します。"
                    )
                }

                Section("Reset") {
                    HStack {
                        Button(role: .destructive) {
                            showResetConfirm = true
                        } label: {
                            Label("Reset to Defaults…", systemImage: "arrow.counterclockwise")
                        }
                        Spacer()
                    }
                    BilingualSettingDescription(
                        english: "Clears persisted prompt, generation parameters, audio toggles, and model selections. Python path, output directory, and ElevenLabs API key are kept.",
                        japanese: "保存済みのプロンプト、生成パラメータ、音声設定、Model選択を消去します。Python path、出力先、ElevenLabs API Keyは保持されます。"
                    )
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gear")
            }
            
            // Generation
            Form {
                Section("Queue") {
                    Toggle("Keep completed items in queue", isOn: $keepCompletedInQueue)
                }

                Section("Output") {
                    Toggle("Save audio track separately", isOn: $saveAudioTrackSeparately)
                        .help("When on, keeps a .wav file alongside each video. Default: off (audio only in mp4).")
                    BilingualSettingDescription(
                        english: "When on, keeps a .wav file alongside each video. Default: off (audio only in mp4).",
                        japanese: "オンにすると、動画と一緒に.wav音声ファイルも保存します。標準ではオフで、音声はmp4内にのみ保存されます。"
                    )
                }

                Section("Prompt Enhancement") {
                    Toggle("Enable Prompt Enhancement", isOn: $enableGemmaPromptEnhancement)
                        .help("When on, Gemma rewrites your prompt with vivid details (lighting, camera, audio) before generation. Use Preview in the prompt view to see the enhanced prompt first.")
                    BilingualSettingDescription(
                        english: "Uses Gemma to rewrite prompts with vivid details for better video generation. First run downloads ~7GB. If enhancement fails, generation automatically continues with your original prompt.",
                        japanese: "Gemmaがプロンプトへ具体的な描写を加え、動画生成向けに書き直します。初回使用時に約7 GBをダウンロードします。処理に失敗した場合は元のプロンプトで生成を続行します。"
                    )
                }
                
                Section("Defaults") {
                    BilingualSettingDescription(
                        english: "Default generation parameters can be set via Presets",
                        japanese: "標準の生成パラメータはPresetsから設定できます。"
                    )
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Generation", systemImage: "wand.and.stars")
            }

            DirectorPreferencesView()
                .tabItem {
                    Label("Director", systemImage: "movieclapper")
                }

            CharacterSheetAnalysisPreferencesView()
                .tabItem {
                    Label("Analysis", systemImage: "photo.on.rectangle.angled")
                }

            // Audio
            Form {
                Section("ElevenLabs API") {
                    SecureField("API Key", text: $elevenLabsApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: elevenLabsApiKey) { _, newValue in
                            KeychainCredentialStore.shared.setElevenLabsApiKey(newValue)
                        }
                        .onAppear {
                            elevenLabsApiKey = KeychainCredentialStore.shared.elevenLabsApiKey
                        }
                    
                    HStack {
                        if isTestingElevenLabs {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Testing connection...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let result = elevenLabsTestResult {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? .green : .red)
                            Text(result.message)
                                .font(.caption)
                        }
                        
                        Spacer()
                        
                        Button("Test Connection") {
                            testElevenLabsConnection()
                        }
                        .disabled(elevenLabsApiKey.isEmpty || isTestingElevenLabs)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get your API key from [elevenlabs.io](https://elevenlabs.io)")
                        Text("API Keyは[elevenlabs.io](https://elevenlabs.io)で取得できます。")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
                Section("Default Audio Source") {
                    Picker("Default Source", selection: $defaultAudioSource) {
                        Text("ElevenLabs (Cloud)").tag("elevenlabs")
                        Text("MLX Audio (Local)").tag("mlx-audio")
                    }
                    .pickerStyle(.radioGroup)
                    
                    BilingualSettingDescription(
                        english: "ElevenLabs requires an API key but provides high-quality voices. MLX Audio runs locally on your Mac.",
                        japanese: "ElevenLabsはAPI Keyが必要ですが、高品質な音声を利用できます。MLX AudioはMac上でローカル実行されます。"
                    )
                }
                
                Section("MLX Audio") {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Local Text-to-Speech")
                                .font(.caption.bold())
                            BilingualSettingDescription(
                                english: "MLX Audio runs entirely on your Mac using Apple Silicon. No API key required, but requires the mlx-audio Python package to be installed.",
                                japanese: "MLX AudioはApple Siliconを使用してMac上で実行されます。API Keyは不要ですが、Python環境にmlx-audio packageが必要です。"
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Audio", systemImage: "waveform")
            }

            // Models & Features (director extensions)
            ModelsAndFeaturesPreferences()
                .tabItem {
                    Label("Models & Features", systemImage: "square.stack.3d.up")
                }

            // About
            VStack(spacing: 20) {
                Image(systemName: "film.stack")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue.gradient)
                
                Text("Local Video Studio")
                    .font(.title)
                    .bold()
                
                Text(appVersionText)
                    .foregroundStyle(.secondary)
                
                Divider()
                    .frame(width: 200)
                
                VStack(spacing: 8) {
                    Text("Native AI Video Studio for Apple Silicon")
                    Link("https://github.com/Lightricks/LTX-2",
                         destination: URL(string: "https://github.com/Lightricks/LTX-2")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                
                Spacer()
            }
            .padding(40)
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
            }
        }
        .frame(width: 550, height: 450)
        .sheet(isPresented: $showPathPicker) {
            DetectedPathsView(paths: detectedPaths, selectedPath: $pythonPath, isPresented: $showPathPicker)
        }
        .alert("Reset to defaults?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                SessionSettings.resetAll()
            }
        } message: {
            Text("This clears the persisted prompt, generation parameters, audio settings, prompt-enhancement toggles, and model/text-encoder selections. Python path, output directory, and ElevenLabs API key are preserved.")
        }
    }
    
    private func pathTypeIcon(_ type: PythonEnvironment.PythonPathType) -> String {
        switch type {
        case .executable: return "terminal"
        case .dylib: return "shippingbox"
        case .unknown: return "questionmark.circle"
        }
    }
    
    private func pathTypeColor(_ type: PythonEnvironment.PythonPathType) -> Color {
        switch type {
        case .executable: return .blue
        case .dylib: return .purple
        case .unknown: return .orange
        }
    }
    
    private func pathTypeDescription(_ type: PythonEnvironment.PythonPathType) -> String {
        switch type {
        case .executable: return "Python executable"
        case .dylib: return "Python dynamic library"
        case .unknown: return "Unknown path type - will attempt validation"
        }
    }
    
    private func selectPythonPath() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select Python executable (python3) or library (libpython*.dylib)"
        panel.prompt = "Select"
        
        // Start in a reasonable location
        if let homeDir = FileManager.default.urls(for: .userDirectory, in: .localDomainMask).first {
            panel.directoryURL = homeDir
        }
        
        if panel.runModal() == .OK, let url = panel.url {
            pythonPath = url.path
            pythonStatus = nil
            pythonDetails = nil
        }
    }
    
    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }
    
    private func openOutputDirectory() {
        let path = outputDirectory.isEmpty
            ? AppStorageDirectory.videosDirectory.path
            : outputDirectory
        
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
    
    private func detectPython() {
        isDetecting = true
        pythonStatus = nil
        pythonDetails = nil
        
        Task {
            // First, discover all Python installations
            let discovered = PythonEnvironment.shared.discoverPythonPaths()
            
            // Then try to auto-detect the best one
            let (bestPath, result) = await PythonEnvironment.shared.autoDetectPython()
            
            await MainActor.run {
                detectedPaths = discovered
                
                if let path = bestPath {
                    pythonPath = path
                }
                
                pythonStatus = (result.success, result.message)
                pythonDetails = result.details
                isDetecting = false
            }
        }
    }
    
    private func validatePython() {
        isValidating = true
        pythonStatus = nil
        pythonDetails = nil
        installMessage = nil
        
        Task {
            // Use safe subprocess validation - won't crash
            let result = await PythonEnvironment.shared.validateWithSubprocess(
                path: pythonPath,
                automaticInstallAndUpgrade: false
            )
            
            await MainActor.run {
                pythonStatus = (result.success, result.message)
                pythonDetails = result.details
                isValidating = false
                
                // If validation succeeded and we have details, configure for PythonKit
                if result.success, let details = result.details {
                    PythonEnvironment.shared.configureForPythonKit(details: details)
                    PythonEnvironment.shared.applyValidatedDetailsForGeneration(path: pythonPath, details: details)
                }
            }
        }
    }
    
    private func installMissingPackages(pythonPath: String, packages: [String], upgrade: Bool = false) {
        isInstalling = true
        installMessage = nil
        
        Task {
            let result = await PythonEnvironment.shared.installPackages(
                pythonExecutable: pythonPath,
                packages: packages,
                upgrade: upgrade
            )
            
            await MainActor.run {
                isInstalling = false
                
                if result.success {
                    installMessage = upgrade ? "Upgrade successful! Re-validating..." : "Installation successful! Re-validating..."
                    validatePython()
                } else {
                    installMessage = upgrade ? "Upgrade failed: \(result.message)" : "Install failed: \(result.message)"
                }
            }
        }
    }
    
    private func createVenvAndInstall(basePython: String, packages: [String]) {
        isInstalling = true
        installMessage = "Creating virtual environment..."
        
        Task {
            let venvPath = PythonEnvironment.shared.getRecommendedVenvPath()
            let createResult = await PythonEnvironment.shared.createVirtualEnvironment(basePython: basePython, venvPath: venvPath)
            
            if createResult.success, let venvPython = createResult.pythonPath {
                await MainActor.run {
                    installMessage = "Venv created! Installing packages..."
                }
                
                // Install packages to the new venv
                let installResult = await PythonEnvironment.shared.installPackages(pythonExecutable: venvPython, packages: packages)
                
                await MainActor.run {
                    isInstalling = false
                    
                    if installResult.success {
                        // Update the Python path to use the new venv
                        pythonPath = venvPython
                        installMessage = "Virtual environment created and packages installed! Re-validating..."
                        validatePython()
                    } else {
                        installMessage = "Venv created but package install failed: \(installResult.message)"
                    }
                }
            } else {
                await MainActor.run {
                    isInstalling = false
                    installMessage = "Failed to create venv: \(createResult.message)"
                }
            }
        }
    }
    
    private func testElevenLabsConnection() {
        isTestingElevenLabs = true
        elevenLabsTestResult = nil
        
        Task {
            do {
                let url = URL(string: "https://api.elevenlabs.io/v1/user")!
                var request = URLRequest(url: url)
                request.setValue(elevenLabsApiKey, forHTTPHeaderField: "xi-api-key")
                
                let (data, response) = try await URLSession.shared.data(for: request)
                
                await MainActor.run {
                    isTestingElevenLabs = false
                    
                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 {
                            // Try to parse user info
                            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let subscription = json["subscription"] as? [String: Any],
                               let characterCount = subscription["character_count"] as? Int,
                               let characterLimit = subscription["character_limit"] as? Int {
                                elevenLabsTestResult = (true, "Connected! \(characterCount)/\(characterLimit) characters used")
                            } else {
                                elevenLabsTestResult = (true, "Connected successfully!")
                            }
                        } else if httpResponse.statusCode == 401 {
                            elevenLabsTestResult = (false, "Invalid API key")
                        } else {
                            elevenLabsTestResult = (false, "Error: HTTP \(httpResponse.statusCode)")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isTestingElevenLabs = false
                    elevenLabsTestResult = (false, "Connection failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Storyboard Director

private struct DirectorPreferencesView: View {
    @AppStorage(DirectorMode.userDefaultsKey) private var modeRaw = DirectorMode.auto.rawValue
    @AppStorage(DirectorEnvironmentService.modelUserDefaultsKey) private var directorModel = ""

    @State private var snapshot = DirectorSetupSnapshot.checking(mode: .auto)
    @State private var isRefreshing = false
    @State private var isTesting = false
    @State private var testResult: (success: Bool, message: String)?
    @State private var showAdvanced = false

    private let environment = DirectorEnvironmentService()

    private var mode: DirectorMode {
        DirectorMode(rawValue: modeRaw) ?? .auto
    }

    private var modeJapaneseDetail: String {
        switch mode {
        case .auto: return "推奨設定です。"
        case .localAI: return "インストール済みのローカルModelを使用します。"
        case .basic: return "追加設定なしで使用できます。"
        }
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { directorModel.isEmpty ? (snapshot.effectiveModel ?? "") : directorModel },
            set: { directorModel = $0; testResult = nil }
        )
    }

    var body: some View {
        Form {
            Section("Director Mode") {
                Picker("Mode", selection: $modeRaw) {
                    ForEach(DirectorMode.allCases) { mode in
                        Text(mode == .auto ? "Auto (Recommended)" : mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                BilingualSettingDescription(
                    english: mode.detail,
                    japanese: modeJapaneseDetail
                )
            }

            Section("Local AI") {
                HStack {
                    statusLabel
                    Spacer()
                    if isRefreshing { ProgressView().controlSize(.small) }
                }

                if mode != .basic {
                    Picker("Director Model", selection: modelSelection) {
                        if snapshot.installedModels.isEmpty {
                            Text("No installed models").tag("")
                        } else {
                            ForEach(snapshot.installedModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    .disabled(snapshot.installedModels.isEmpty || isRefreshing)

                    HStack {
                        Button("Refresh Models") { Task { await refresh() } }
                            .disabled(isRefreshing || isTesting)
                        Button("Test") { Task { await testConnection() } }
                            .disabled(snapshot.effectiveModel == nil || isRefreshing || isTesting)
                        if isTesting { ProgressView().controlSize(.small) }
                    }

                    if let testResult {
                        Label(testResult.message,
                              systemImage: testResult.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(testResult.success ? .green : .orange)
                    }
                } else {
                    BilingualSettingDescription(
                        english: "Storyboard planning works without a Local AI model.",
                        japanese: "Local AI ModelがなくてもStoryboardのプランニングを利用できます。"
                    )
                }
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Endpoint", value: OllamaDirectorEnvironmentClient.endpoint.absoluteString)
                    LabeledContent("Technical Status", value: snapshot.technicalStatus)
                    LabeledContent("Installed Models", value: "\(snapshot.installedModels.count)")
                }
                .font(.caption)
                .textSelection(.enabled)
                .padding(.top, 6)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onChange(of: modeRaw) { _, _ in
            testResult = nil
            Task { await refresh() }
        }
        .onChange(of: directorModel) { _, _ in
            testResult = nil
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch snapshot.availability {
        case .checking:
            Label("Checking…", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .localAIReady(let model):
            VStack(alignment: .leading, spacing: 2) {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(model).font(.caption).foregroundStyle(.secondary)
            }
        case .basicOnly:
            Label("Basic Director — Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .localAIModelMissing:
            Label("Model Not Available — Basic Director is ready", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .localAIServerUnavailable:
            Label("Not Running — Basic Director is ready", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @MainActor
    private func refresh() async {
        isRefreshing = true
        snapshot = await environment.refresh(mode: mode)
        isRefreshing = false
    }

    @MainActor
    private func testConnection() async {
        isTesting = true
        // Negotiates which planning protocol this model can actually drive and
        // caches it, so Auto Movie starts with a protocol already known to
        // work. Users are told the outcome, not the mechanism.
        let (model, capability) = await environment.testCompatibility()
        switch capability {
        case .ready(let planProtocol):
            let name = model.map { " (\($0))" } ?? ""
            testResult = (true, "Local AI Director is ready\(name) — protocol: \(planProtocol.displayName).")
        case .incompatible:
            testResult = (false, "This model replied but could not produce a usable plan in any supported format, so Auto Movie would use the Basic Director. Try a different Local AI model.")
        case .unavailable:
            testResult = (false, "Local AI could not be reached. Basic Director remains available.")
        }
        isTesting = false
        await refresh()
    }
}

// MARK: - Character Sheet Analysis

private struct CharacterSheetAnalysisPreferencesView: View {
    @AppStorage(CharacterSheetAnalysisMode.userDefaultsKey)
    private var modeRaw = CharacterSheetAnalysisMode.auto.rawValue
    @AppStorage(CharacterSheetVisionEnvironmentService.modelUserDefaultsKey)
    private var visionModel = ""

    @State private var snapshot = CharacterSheetVisionSnapshot(
        requestedMode: .auto, effectiveMode: .manual, installedVisionModels: [],
        configuredModel: nil, effectiveModel: nil, fallbackReason: nil
    )
    @State private var isRefreshing = false
    @State private var showAdvanced = false
    private let environment = CharacterSheetVisionEnvironmentService()

    private var mode: CharacterSheetAnalysisMode {
        CharacterSheetAnalysisMode(rawValue: modeRaw) ?? .auto
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { visionModel.isEmpty ? (snapshot.effectiveModel ?? "") : visionModel },
            set: { visionModel = $0 }
        )
    }

    var body: some View {
        Form {
            Section("Character Sheet Analysis") {
                Picker("Mode", selection: $modeRaw) {
                    ForEach(CharacterSheetAnalysisMode.allCases) { mode in
                        Text(mode == .auto ? "Auto (Recommended)" : mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                BilingualSettingDescription(
                    english: "Auto uses a compatible installed local Vision model when available. Otherwise Character Sheet import continues with manual review.",
                    japanese: "Autoは対応するインストール済みLocal Vision Modelがあれば使用します。利用できない場合も、Character Sheetの読み込みを手動レビューで続行できます。"
                )
            }

            Section("Local Analysis") {
                HStack {
                    statusLabel
                    Spacer()
                    if isRefreshing { ProgressView().controlSize(.small) }
                }
                if mode != .manual {
                    Picker("Vision Model", selection: modelSelection) {
                        if snapshot.installedVisionModels.isEmpty {
                            Text("No compatible installed models").tag("")
                        } else {
                            ForEach(snapshot.installedVisionModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    .disabled(snapshot.installedVisionModels.isEmpty || isRefreshing)
                    Button("Refresh") { Task { await refresh() } }
                        .disabled(isRefreshing)
                }
                BilingualSettingDescription(
                    english: "Models are detected by their reported Vision capability. This app never downloads one automatically.",
                    japanese: "Modelが申告するVision capabilityに基づいて検出します。このアプリがModelを自動ダウンロードすることはありません。"
                )
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent("Endpoint", value: OllamaCharacterSheetVisionEnvironmentClient.endpoint.absoluteString)
                    LabeledContent("Compatible Models", value: "\(snapshot.installedVisionModels.count)")
                    LabeledContent("Director Model Setting", value: "Separate")
                }
                .font(.caption).textSelection(.enabled).padding(.top, 6)
            }

            Section("Privacy & Capability") {
                BilingualSettingDescription(
                    english: "Character Sheets stay local. Analysis creates editable text candidates; it does not provide face recognition, identity conditioning, or a same-person guarantee.",
                    japanese: "Character Sheetはローカルに保持されます。解析は編集可能なテキスト候補を作成しますが、顔認識・identity conditioning・同一人物の保証は行いません。"
                )
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onChange(of: modeRaw) { _, _ in Task { await refresh() } }
        .onChange(of: visionModel) { _, _ in Task { await refresh() } }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isRefreshing {
            Label("Checking…", systemImage: "clock").foregroundStyle(.secondary)
        } else if snapshot.effectiveMode == .localVision, let model = snapshot.effectiveModel {
            VStack(alignment: .leading, spacing: 2) {
                Label("Local Analysis Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(model).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Label("Manual Review Available", systemImage: "pencil.circle.fill").foregroundStyle(.orange)
        }
    }

    @MainActor
    private func refresh() async {
        isRefreshing = true
        snapshot = await environment.refresh(mode: mode)
        isRefreshing = false
    }
}

// MARK: - Detected Paths Picker View

struct DetectedPathsView: View {
    let paths: [String]
    @Binding var selectedPath: String
    @Binding var isPresented: Bool
    
    @State private var validationResults: [String: (success: Bool, version: String?)] = [:]
    @State private var isValidating = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Detected Python Installations")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    isPresented = false
                }
            }
            .padding()
            
            Divider()
            
            // List of paths
            if paths.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Python installations found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(paths, id: \.self) { path in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortPath(path))
                                .font(.body)
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        
                        Spacer()
                        
                        if let result = validationResults[path] {
                            if result.success {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    if let version = result.version {
                                        Text(version)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        } else if isValidating {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        
                        Button("Select") {
                            selectedPath = path
                            isPresented = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 600, height: 400)
        .task {
            await validateAllPaths()
        }
    }
    
    private func shortPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count > 3 {
            // Show last 3 components
            return ".../" + components.suffix(3).joined(separator: "/")
        }
        return path
    }
    
    private func validateAllPaths() async {
        isValidating = true
        
        for path in paths {
            let result = await PythonEnvironment.shared.validateWithSubprocess(
                path: path,
                automaticInstallAndUpgrade: false
            )
            await MainActor.run {
                validationResults[path] = (result.success, result.details?.version)
            }
        }
        
        await MainActor.run {
            isValidating = false
        }
    }
}

#if !SPM_BUILD
#Preview {
    PreferencesView()
}
#endif

/// Readiness for the second generation backend (`ltx-2-mlx`).
///
/// Runtime and model get their own rows on purpose: "Not ready" must
/// distinguish between missing runtime executable and missing weights. Neither
/// row ever starts a download on its own.
struct CustomLTX2MLXRuntimeSection: View {
    @Binding var executablePath: String
    @StateObject private var downloads = CustomModelDownloadCoordinator.shared
    @AppStorage(ModelRegistry.customRepositoryUserDefaultsKey) private var customRepo = ""

    private var model: LTXModel { CustomLTX2MLXModelCatalog.customModel() }

    private var readiness: LTX2MLXRuntime.Readiness {
        LTX2MLXRuntime.readiness(repository: model.repo)
    }

    var body: some View {
        let state = readiness
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.displayName) — \(GenerationBackendKind.ltx2MLX.displayName)")
                .font(.caption.bold())

            statusRow(
                title: "Runtime",
                isReady: state.runtime.isReady,
                readyDetail: "Ready",
                missingDetail: state.runtime.detail
            )
            HStack {
                TextField("Path to the ltx-2-mlx executable", text: $executablePath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseExecutable() }
            }

            statusRow(
                title: "Custom Model Repo",
                isReady: state.model.isReady,
                readyDetail: "Ready: \(model.repo)",
                missingDetail: modelStatusDetail
            )
            HStack {
                TextField("Hugging Face repository (e.g. organization/model-name)", text: $customRepo)
                    .textFieldStyle(.roundedBorder)
            }
            if !state.model.isReady && !model.repo.isEmpty && !model.repo.contains("user-supplied") {
                modelDownloadControl
            }
            BilingualSettingDescription(
                english: "Download with: hf download \(model.repo). Cached in ~/.cache/huggingface/.",
                japanese: "ダウンロード方法: hf download \(model.repo)。~/.cache/huggingface/に保存されます。"
            )

            if !state.canGenerate {
                Text("Generation with \(model.displayName) needs both the runtime and model weights.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var modelStatusDetail: String {
        switch downloads.state {
        case .idle:
            return "Missing — download required for \(model.repo)"
        case .downloading(let progress, let message):
            if let progress {
                return "Downloading… \(Int(progress * 100))% — \(message)"
            }
            return "Downloading… \(message)"
        case .succeeded:
            return "Downloaded"
        case .failed(let reason):
            return "Download failed — \(reason)"
        }
    }

    @ViewBuilder
    private var modelDownloadControl: some View {
        switch downloads.state {
        case .idle, .succeeded:
            Button("Download Model (\(model.downloadSize))") {
                Task { await downloads.startDownload(repository: model.repo) }
            }
        case .downloading:
            ProgressView().controlSize(.small)
        case .failed:
            Button("Retry Download") {
                Task { await downloads.retry(repository: model.repo) }
            }
        }
    }

    @ViewBuilder
    private func statusRow(title: String, isReady: Bool, readyDetail: String, missingDetail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold())
                Text(isReady ? readyDetail : missingDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the ltx-2-mlx executable"
        if panel.runModal() == .OK, let url = panel.url {
            executablePath = url.path
        }
    }
}

// Backward-compatibility alias
typealias TenErosRuntimeSection = CustomLTX2MLXRuntimeSection
