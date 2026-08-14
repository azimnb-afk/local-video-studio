import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var generationService: GenerationService
    @EnvironmentObject var historyManager: HistoryManager
    @EnvironmentObject var presetManager: PresetManager

    // Persisted across app launches (issue #51).
    @AppStorage(SessionSettings.promptKey) private var prompt = ""
    @AppStorage(SessionSettings.negativePromptKey) private var negativePrompt = ""
    @AppStorage(SessionSettings.voiceoverTextKey) private var voiceoverText = ""
    /// Runtime navigation belongs to SwiftUI state. UserDefaults supplies only
    /// the initial route and persistence; binding selection directly through
    /// `@AppStorage` lets a `-session.selectedTab ...` launch argument (the
    /// highest-priority NSArgumentDomain) overwrite every sidebar click for the
    /// lifetime of the process.
    @State private var navigation: SidebarNavigationState

    // GenerationParameters is a struct, so we persist it as JSON via UserDefaults
    // and bridge through a `@State` binding the children already expect.
    @State private var parameters: GenerationParameters = SessionSettings.loadParameters()
    @AppStorage("generationPreset") private var generationPresetRaw = GenerationPreset.standard.rawValue
    @State private var showError = false

    init() {
        _navigation = State(initialValue: SidebarNavigationState(
            persistedRawValue: UserDefaults.standard.string(forKey: SessionSettings.selectedTabKey)
        ))
    }

    enum Tab: String, CaseIterable {
        case generate = "Generate"
        case oneShot = "One Shot"
        case storyboard = "Storyboard / Director"
        case hybrid = "Auto Movie"
        case history = "Video Archive"

        var icon: String {
            switch self {
            case .generate: return "wand.and.stars"
            case .oneShot: return "camera.metering.center.weighted"
            case .storyboard: return "movieclapper"
            case .hybrid: return "sparkles.rectangle.stack"
            case .history: return "film.stack"
            }
        }

        var subtitle: String {
            switch self {
            case .generate: return "Create a single video"
            case .oneShot: return "One video from a short brief"
            case .storyboard: return "Manage multiple shots and takes"
            case .hybrid: return "Sora 2-like connected shots"
            case .history: return "Review generated videos"
            }
        }
    }

    /// Storyboard tab appears only while its feature flag is on.
    private var visibleTabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .oneShot: return FeatureFlags.isEnabled(.directorV1)
            case .storyboard, .hybrid: return FeatureFlags.isEnabled(.storyboardV1)
            default: return true
            }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            // Detail views embed AppKit-backed `HSplitView`s (Generate,
            // Storyboard, Video Archive, Character Reference). NSSplitView
            // reports its arranged subviews' intrinsic content height instead
            // of accepting the proposed viewport height, so the enclosing
            // NavigationSplitView was laid out at that intrinsic height
            // (measured: 1685pt inside a 948pt window). The oversized layout is
            // bottom-anchored, which pushed the top of BOTH columns above the
            // visible content area and hid the sidebar navigation entirely.
            // GeometryReader accepts the proposed size, and the explicit frame
            // makes the column report exactly the offered viewport, so an inner
            // split view can no longer inflate the window layout.
            GeometryReader { proxy in
                detailContent
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        // Issue #52: relax the hard minimum so the window can shrink on small
        // displays (e.g. 13" MacBook Air with a non-default text size). Inner
        // panes are scrollable, so the Generate button stays reachable.
        .frame(
            minWidth: 900,
            idealWidth: 1280,
            minHeight: 480,
            idealHeight: 800,
            maxHeight: .infinity
        )
        .alert("Error", isPresented: $showError, presenting: generationService.error) { _ in
            Button("OK", role: .cancel) {
                generationService.clearError()
            }
        } message: { error in
            Text(error.localizedDescription)
        }
        .onChange(of: generationService.error) { _, newError in
            showError = newError != nil
        }
        .onChange(of: parameters) { _, newValue in
            SessionSettings.saveParameters(newValue)
            generationPresetRaw = GenerationPreset.custom.rawValue
        }
        .onChange(of: navigation.selection) { _, destination in
            UserDefaults.standard.set(destination.rawValue, forKey: SessionSettings.selectedTabKey)
        }
    }
    
    @ObservedObject private var productionQueue = ProductionQueueService.shared

    private var sidebarContent: some View {
        // Primary navigation is pinned; only the secondary panes scroll. When
        // the whole sidebar shared one ScrollView, a tall Queue could scroll the
        // navigation out of reach, and the ScrollView reported its content's
        // ideal height to the enclosing split view. Clamping to the offered
        // viewport (same reason as the detail column) keeps the navigation
        // anchored at the top at every window size.
        // Issue #52 is still honoured: QueueView and ModelStatusView remain
        // reachable by scrolling when the window is short.
        GeometryReader { proxy in
            VStack(spacing: 0) {
                tabSelector
                Divider()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        QueueView()
                            .frame(minHeight: 160, maxHeight: 300)
                        Divider()
                        // The global job queue sits under the per-render queue:
                        // renders in flight above, whole movies and batches
                        // waiting their turn below.
                        ProductionQueuePanel(queue: productionQueue)
                        Divider()
                        ModelStatusView()
                            .padding()
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var tabSelector: some View {
        VStack(spacing: 4) {
            ForEach(visibleTabs, id: \.self) { tab in
                SidebarButton(
                    title: tab.rawValue,
                    subtitle: tab.subtitle,
                    icon: tab.icon,
                    isSelected: navigation.selection == tab,
                    badge: tab == .generate ? generationService.queue.count : nil
                ) {
                    navigation.select(tab)
                }
            }
        }
        .padding()
    }
    
    @ViewBuilder
    private var detailContent: some View {
        switch navigation.selection {
        case .generate:
            GenerateView(
                prompt: $prompt,
                negativePrompt: $negativePrompt,
                voiceoverText: $voiceoverText,
                parameters: $parameters,
                onSubmissionQueued: { navigation.didQueueDirectGeneration() }
            )
        case .oneShot:
            OneShotView(parameters: $parameters)
        case .storyboard:
            StoryboardView()
        case .hybrid:
            HybridView()
        case .history:
            HistoryView()
        }
    }
}

/// Small value state for sidebar routing. Queue/render activity is
/// intentionally absent: background production never gates navigation.
struct SidebarNavigationState: Equatable {
    private(set) var selection: ContentView.Tab

    init(persistedRawValue: String?) {
        selection = ContentView.Tab(rawValue: persistedRawValue ?? "") ?? .generate
    }

    mutating func select(_ destination: ContentView.Tab) {
        selection = destination
    }

    /// Auto-navigation after a successful Direct Generate enqueue is a single
    /// mutation, not a persistent policy. The next user selection always wins.
    mutating func didQueueDirectGeneration() {
        selection = .history
    }
}

struct SidebarButton: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    let isSelected: Bool
    var badge: Int?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            buttonContent
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
    
    private var buttonContent: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            badgeView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
    }
    
    @ViewBuilder
    private var badgeView: some View {
        if let badge = badge, badge > 0 {
            Text("\(badge)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.blue))
        }
    }
}

/// A compact, always-bilingual page introduction. Navigation and control
/// labels remain English; only the page-level description is duplicated.
struct BilingualPageHeader: View {
    let title: String
    let englishDescription: String
    let japaneseDescription: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle.bold())
            Text(englishDescription)
            Text(japaneseDescription)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Dedicated One Shot mode. It composes LocalDirector, PromptCompiler and the
/// existing single-flight GenerationService; it does not introduce another
/// generation path.
private struct OneShotView: View {
    @EnvironmentObject var generationService: GenerationService
    @Binding var parameters: GenerationParameters

    @State private var brief = ""
    @State private var status: String?
    @State private var isPlanning = false
    @State private var targetDuration = 5.0
    @AppStorage("oneShotGenerationPreset") private var presetRaw = GenerationPreset.standard.rawValue
    @AppStorage(LTXModelCatalog.selectedModelIDKey) private var modelID = LTXModelCatalog.defaultModelID
    @AppStorage(LTXTextEncoderCatalog.selectedTextEncoderIDKey) private var textEncoderID = LTXTextEncoderCatalog.defaultTextEncoderID
    @AppStorage("oneShotStartingImagePath") private var storedStartingImagePath = ""
    @State private var audioEnabled = true
    @State private var startingImageThumbnail: NSImage?
    @State private var startingImageError: String?

    private var preset: GenerationPreset { GenerationPreset(rawValue: presetRaw) ?? .standard }

    private var resolutionSummary: String {
        guard preset != .custom else {
            return "Custom: \(parameters.width)×\(parameters.height), \(parameters.numFrames) frames, \(parameters.fps) fps, \(parameters.numInferenceSteps) steps"
        }
        let request = GenerationRequest(
            prompt: brief,
            sourceImagePath: storedStartingImagePath.isEmpty ? nil : storedStartingImagePath,
            disableAudio: !audioEnabled,
            modelId: modelID,
            textEncoderId: textEncoderID,
            parameters: parameters,
            qualityMode: preset.qualityMode.rawValue,
            preset: preset.rawValue,
            targetDurationSeconds: targetDuration,
            generationSource: "oneShot"
        )
        let resolved = GenerationSettingsResolver.resolveForPreflight(request: request).request
        let orientation = resolved.presetResolutionOrientation?.displayName
            .map { " · \($0)" } ?? ""
        return "\(preset.summary) · Effective \(resolved.parameters.width)×\(resolved.parameters.height)\(orientation)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BilingualPageHeader(
                    title: "One Shot",
                    englishDescription: "Describe a scene, optionally add a starting image, and let the Director turn it into a complete video shot.",
                    japaneseDescription: "作りたいシーンを入力し、必要に応じて開始画像を追加すると、Directorが1つの映像シーンとして組み立てて生成します。"
                )
                Text("Short Brief")
                    .font(.headline)
                TextEditor(text: $brief)
                    .font(.body)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 140)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                startingImageSection
                HStack(spacing: 16) {
                    Picker("Preset", selection: $presetRaw) {
                        ForEach(GenerationPreset.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    Picker("Model", selection: $modelID) {
                        ForEach(ModelRegistry.shared.selectableModels()) { Text($0.displayName).tag($0.id) }
                    }
                    HStack {
                        Text("Target Duration")
                        Stepper("\(targetDuration, specifier: "%.0f")s", value: $targetDuration, in: 1...10)
                    }
                    Toggle("Audio", isOn: $audioEnabled)
                    Spacer()
                }
                if preset == .custom {
                    HStack {
                        Text(resolutionSummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Edit these values in Generate → Custom.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(resolutionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    planAndGenerate()
                } label: {
                    if isPlanning { ProgressView().controlSize(.small) }
                    Label(isPlanning ? "Planning…" : "Create & Generate", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // A running generation does not block submission: this button
                // enqueues a production job, and the queue is what decides when
                // it runs. It stays disabled only while this One Shot's own
                // planning is in flight, or when the input itself is unusable.
                .disabled(!GenerationSubmissionPolicy.canSubmit(
                    prompt: brief,
                    isPreparing: isPlanning,
                    blockingError: startingImageError
                ))
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onChange(of: audioEnabled) { old, new in
            if old != new { presetRaw = GenerationPreset.custom.rawValue }
        }
        .onAppear(perform: refreshStartingImage)
    }

    private var startingImageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Starting Image (Optional)", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                if !storedStartingImagePath.isEmpty {
                    Button("Clear", role: .destructive) { clearStartingImage() }
                        .buttonStyle(.borderless)
                }
            }

            if let thumbnail = startingImageThumbnail {
                HStack(spacing: 12) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(URL(fileURLWithPath: storedStartingImagePath).lastPathComponent)
                            .lineLimit(1)
                        Label("Image-conditioned starting frame", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Button("Choose Another Image…", action: chooseStartingImage)
                    }
                    Spacer()
                }
            } else if !storedStartingImagePath.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(startingImageError ?? "Starting Image is unavailable.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Choose Image Again…", action: chooseStartingImage)
                }
            } else {
                Button(action: chooseStartingImage) {
                    Label("Choose Starting Image…", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
            }

            Text("Optional visual anchor for the first frame. It guides image-conditioned generation and does not guarantee character identity.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func planAndGenerate() {
        let validatedStartingImage: String?
        do {
            validatedStartingImage = try OneShotStartingImagePreflight.validatedPath(storedStartingImagePath)
            startingImageError = nil
        } catch {
            startingImageThumbnail = nil
            startingImageError = error.localizedDescription
            status = error.localizedDescription
            return
        }
        if !DependencyHealthManager.shared.canStartGeneration {
            DependencyHealthManager.shared.showSetupWizard = true
            return
        }
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        isPlanning = true
        status = "Planning locally…"
        Task {
            defer { isPlanning = false }
            do {
                var requestParameters = parameters
                if preset != .custom {
                    requestParameters.numFrames = PromptCompiler.frameCount(forSeconds: targetDuration, fps: requestParameters.fps)
                }
                let baseRequest = GenerationRequest(
                    prompt: trimmed,
                    brief: trimmed,
                    sourceImagePath: validatedStartingImage,
                    disableAudio: !audioEnabled,
                    modelId: modelID,
                    textEncoderId: textEncoderID,
                    parameters: requestParameters,
                    qualityMode: preset.qualityMode.rawValue,
                    preset: preset.rawValue,
                    targetDurationSeconds: preset == .custom ? nil : targetDuration,
                    generationSource: "oneShot"
                )
                let (request, _, providerName) = try await LocalDirector().makeRequest(
                    brief: trimmed,
                    base: baseRequest
                )
                // The file may have moved while local planning was running.
                // Re-check immediately before queue insertion; never downgrade
                // a selected Starting Image request to text-only.
                _ = try OneShotStartingImagePreflight.validatedPath(request.sourceImagePath)
                // Planning has already happened, so the job carries the finished
                // request: what was queued is exactly what renders, even if the
                // brief is edited while it waits.
                var snapshot = ProductionJobSnapshot()
                snapshot.brief = trimmed
                snapshot.prompt = request.prompt
                snapshot.pendingRequests = [request]
                snapshot.seed = request.parameters.seed
                ProductionQueueService.shared.enqueue(ProductionJob(
                    kind: .oneShot,
                    title: trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed,
                    snapshot: snapshot))
                status = validatedStartingImage == nil
                    ? "Planned via \(providerName); queued text-only generation"
                    : "Planned via \(providerName); queued with Starting Image"
            } catch let error as OneShotStartingImageError {
                startingImageThumbnail = nil
                startingImageError = error.localizedDescription
                status = error.localizedDescription
            } catch let error as DirectorError {
                status = error.localizedDescription
            } catch {
                status = "Planning failed: \(error.localizedDescription)"
            }
        }
    }

    private func chooseStartingImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .png, .jpeg, .webP]
        panel.message = "Choose an optional Starting Image for One Shot"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        storedStartingImagePath = url.path
        refreshStartingImage()
    }

    private func refreshStartingImage() {
        do {
            guard let path = try OneShotStartingImagePreflight.validatedPath(storedStartingImagePath),
                  let image = NSImage(contentsOfFile: path) else {
                startingImageThumbnail = nil
                startingImageError = nil
                return
            }
            startingImageThumbnail = makeThumbnail(image)
            startingImageError = nil
        } catch {
            startingImageThumbnail = nil
            startingImageError = error.localizedDescription
        }
    }

    private func clearStartingImage() {
        storedStartingImagePath = ""
        startingImageThumbnail = nil
        startingImageError = nil
        status = nil
    }

    private func makeThumbnail(_ image: NSImage) -> NSImage {
        let maxSize: CGFloat = 192
        let aspectRatio = image.size.width / max(image.size.height, 1)
        let size = aspectRatio > 1
            ? NSSize(width: maxSize, height: maxSize / aspectRatio)
            : NSSize(width: maxSize * aspectRatio, height: maxSize)
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()
        return thumbnail
    }
}

struct ModelStatusView: View {
    @EnvironmentObject var generationService: GenerationService
    @StateObject private var apiServer = APIServer.shared
    @AppStorage(LTXModelCatalog.selectedModelIDKey) private var selectedModelID = LTXModelCatalog.defaultModelID

    private var displayInfo: ActiveModelDisplayResolver.DisplayInfo {
        ActiveModelDisplayResolver.resolve(
            modelID: selectedModelID,
            generationServiceLoaded: generationService.isModelLoaded
        )
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Model variant indicator
            HStack(spacing: 6) {
                Image(systemName: displayInfo.isCustom ? "shippingbox.fill" : "cpu")
                    .foregroundStyle(.blue)
                Text(displayInfo.displayName)
                    .font(.caption.bold())
                Spacer()
                Text(displayInfo.backendBadge)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }
            
            // Model status
            HStack(spacing: 8) {
                Circle()
                    .fill(displayInfo.isReady ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(displayInfo.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !displayInfo.isCustom {
                    if !generationService.isModelLoaded {
                        Button("Load") {
                            Task { await generationService.loadModel() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Unload") {
                            Task { await generationService.unloadModel() }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }

            if !displayInfo.isCustom && generationService.isModelLoaded {
                Text("Model files are downloaded on first generation if cache is missing.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            Divider()
            
            // API Server toggle
            HStack(spacing: 8) {
                Circle()
                    .fill(apiServer.isRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text("API Server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if apiServer.isRunning {
                    Text(":\(apiServer.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Toggle("", isOn: Binding(
                    get: { apiServer.isRunning },
                    set: { newValue in
                        if newValue {
                            apiServer.start(generationService: generationService)
                        } else {
                            apiServer.stop()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

/// Centralized keys + JSON helpers for the session-level settings that issue
/// #51 asked us to persist between launches. Plain values (Bool, String, raw
/// representable enums) live as `@AppStorage` directly in the views; complex
/// structs round-trip through JSON in `UserDefaults`.
enum SessionSettings {
    static let promptKey = "session.prompt"
    static let negativePromptKey = "session.negativePrompt"
    static let voiceoverTextKey = "session.voiceoverText"
    static let selectedTabKey = "session.selectedTab"
    static let parametersKey = "session.generationParameters"

    static let voiceoverSourceKey = "session.voiceoverSource"
    static let elevenLabsVoiceKey = "session.elevenLabsVoice"
    static let mlxVoiceKey = "session.mlxVoice"
    static let musicEnabledKey = "session.musicEnabled"
    static let musicGenreKey = "session.musicGenre"
    static let disableAudioKey = "session.disableAudio"
    static let gemmaRepetitionPenaltyKey = "session.gemmaRepetitionPenalty"
    static let gemmaTopPKey = "session.gemmaTopP"

    /// Keys that "Reset to defaults" wipes. Excludes app-level prefs that the
    /// user explicitly configured (Python path, ElevenLabs key, output dir).
    static let resettableKeys: [String] = [
        promptKey,
        negativePromptKey,
        voiceoverTextKey,
        selectedTabKey,
        parametersKey,
        voiceoverSourceKey,
        elevenLabsVoiceKey,
        mlxVoiceKey,
        musicEnabledKey,
        musicGenreKey,
        disableAudioKey,
        gemmaRepetitionPenaltyKey,
        gemmaTopPKey,
        "sourceImagePath",
        "enableGemmaPromptEnhancement",
        "saveAudioTrackSeparately",
        "keepCompletedInQueue",
        "autoLoadModel",
        "defaultAudioSource",
        LTXModelCatalog.selectedModelIDKey,
        LTXTextEncoderCatalog.selectedTextEncoderIDKey,
        LTXTextEncoderCatalog.customTextEncoderRepoKey,
    ]

    static func loadParameters() -> GenerationParameters {
        guard let data = UserDefaults.standard.data(forKey: parametersKey) else {
            return .default
        }
        if let decoded = try? JSONDecoder().decode(GenerationParameters.self, from: data) {
            return decoded
        }
        return .default
    }

    static func saveParameters(_ value: GenerationParameters) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: parametersKey)
        }
    }

    static func resetAll() {
        let defaults = UserDefaults.standard
        for key in resettableKeys {
            defaults.removeObject(forKey: key)
        }
    }
}

struct GenerateView: View {
    @Binding var prompt: String
    @Binding var negativePrompt: String
    @Binding var voiceoverText: String
    @Binding var parameters: GenerationParameters
    var onSubmissionQueued: () -> Void = {}
    @AppStorage("generationPreset") private var presetRaw = GenerationPreset.standard.rawValue
    
    var body: some View {
        VStack(spacing: 0) {
            BilingualPageHeader(
                title: "Generate",
                englishDescription: "Generate a video directly from a prompt or starting image.",
                japaneseDescription: "プロンプトや開始画像から、動画を直接生成します。"
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider()
            HSplitView {
                promptArea
                parametersPanel
            }
        }
    }
    
    private var promptArea: some View {
        // Issue #52: wrap the prompt + actions in a vertical ScrollView so the
        // Generate button stays reachable when the window is shorter than the
        // accumulated content (e.g. on a 13" MacBook Air with non-default text
        // size). The internal layout is unchanged.
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                PromptInputView(
                    prompt: $prompt,
                    negativePrompt: $negativePrompt,
                    voiceoverText: $voiceoverText,
                    parameters: $parameters,
                    onPrimarySubmissionQueued: onSubmissionQueued
                )
                TipsView()
                    .padding()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 400, idealWidth: 500)
    }
    
    private var parametersPanel: some View {
        Group {
            if presetRaw == GenerationPreset.custom.rawValue {
                ParametersView(parameters: $parameters)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    let preset = GenerationPreset(rawValue: presetRaw) ?? .standard
                    Label("\(preset.displayName) Preset", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Text(preset.summary)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text("Manual resolution, frames, FPS and steps are available with Custom. The finished video records the requested settings, selected effective profile and actual MP4 metadata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            }
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TipsView: View {
    let tips = [
        "Use detailed, descriptive prompts for better results",
        "Try different aspect ratios for cinematic or portrait videos",
        "Lower inference steps for quick previews, higher for quality",
        "Use the same seed to regenerate similar results",
        "Negative prompts help remove unwanted elements"
    ]
    
    @State private var currentTip = 0
    
    var body: some View {
        HStack {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
            Text(tips[currentTip])
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            nextButton
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.yellow.opacity(0.1))
        )
    }
    
    private var nextButton: some View {
        Button {
            withAnimation {
                currentTip = (currentTip + 1) % tips.count
            }
        } label: {
            Image(systemName: "arrow.right.circle")
        }
        .buttonStyle(.borderless)
    }
}
