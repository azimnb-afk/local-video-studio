import SwiftUI

private enum StoryboardWorkspaceMode {
    case storyboard
    case hybrid

    var title: String { self == .hybrid ? "Auto Movies" : "Storyboards" }
    var workflowValue: String? { self == .hybrid ? "hybrid" : nil }
}

/// Storyboard workspace: Brief → Create Storyboard → Shots → Takes →
/// Select → Generate Missing Takes → Assemble Final Video — all in the GUI.
/// Uses the same single-flight GenerationService as the Generate tab.
struct StoryboardView: View {
    @EnvironmentObject var generationService: GenerationService

    @State private var projects: [FilmProject] = []
    @State private var selectedProjectID: UUID?
    @State private var showNewProjectSheet = false
    @State private var statusMessage: String?
    @State private var isAssembling = false
    @State private var isCreating = false
    @State private var planningPhase: DirectorPlanningPhase = .idle
    @State private var planningElapsedSeconds = 0
    @State private var planningHandle: DirectorPlanningHandle?
    private let mode: StoryboardWorkspaceMode

    init() { self.mode = .storyboard }

    fileprivate init(mode: StoryboardWorkspaceMode) { self.mode = mode }

    private let store = FilmProjectStore.shared
    /// Generation completions land in the store; poll it while visible.
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var selectedProject: FilmProject? {
        selectedProjectID.flatMap { store.project(id: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            BilingualPageHeader(
                title: mode == .hybrid ? "Auto Movie (Sora 2-like)" : "Storyboard",
                englishDescription: mode == .hybrid
                    ? "Turn a simple idea into multiple connected shots and automatically assemble them into a complete video."
                    : "Build and manage a video as multiple shots, takes, and characters.",
                japaneseDescription: mode == .hybrid
                    ? "簡単なアイデアから連続した複数のショットを生成し、1本の動画として自動で仕上げます。"
                    : "複数のショット・テイク・キャラクターを管理しながら映像を制作します。"
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider()
            HSplitView {
                projectList
                    .frame(minWidth: 220, maxWidth: 300)
                if let project = selectedProject {
                    ProjectDetailView(
                        project: project,
                        generationService: generationService,
                        statusMessage: $statusMessage,
                        isAssembling: $isAssembling,
                        onChanged: refresh
                    )
                } else {
                    emptyState
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
        .sheet(isPresented: $showNewProjectSheet) {
            NewStoryboardSheet(
                isCreating: $isCreating,
                planningPhase: $planningPhase,
                planningElapsedSeconds: $planningElapsedSeconds,
                planningHandle: $planningHandle,
                mode: mode
            ) { projectID, title, brief, settings, characterBible, generateFirstPass, openingReferenceURL in
                createProject(
                    projectID: projectID,
                    title: title,
                    brief: brief,
                    settings: settings,
                    characterBible: characterBible,
                    generateFirstPass: generateFirstPass,
                    openingReferenceURL: openingReferenceURL
                )
            }
        }
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(mode.title)
                    .font(.headline)
                Spacer()
                Button {
                    showNewProjectSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help(mode == .hybrid ? "Create an Auto Movie and generate all of its shots automatically" : "Create a storyboard from a short brief")
            }
            .padding(12)
            Divider()
            List(selection: $selectedProjectID) {
                ForEach(projects) { project in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title)
                            .font(.body.bold())
                        Text("\(project.shots.count) shots · \(completedShotCount(project))/\(project.shots.count) with selected take")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(project.id)
                    .contextMenu {
                        Button("Delete Storyboard", role: .destructive) {
                            store.delete(project.id)
                            if selectedProjectID == project.id { selectedProjectID = nil }
                            refresh()
                        }
                    }
                }
            }
            if let statusMessage {
                Divider()
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "movieclapper")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(mode == .hybrid ? "Create connected shots and assemble them automatically" : "Create a storyboard from a short brief")
                .font(.title3)
            Text(mode == .hybrid
                 ? "The local director structures the story, splits it into short shots and queues one take per shot sequentially. Review, retake and assemble here."
                 : "The local director breaks your idea into 4–6 second shots with deterministic continuity. Generate takes per shot, pick the best, then assemble the final video.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
                .multilineTextAlignment(.center)
            Button(mode == .hybrid ? "New Auto Movie…" : "New Storyboard…") { showNewProjectSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func completedShotCount(_ project: FilmProject) -> Int {
        project.shots.filter { $0.selectedTake?.status == .completed }.count
    }

    /// Recorded on the job so a movie that waits in the queue still plans with
    /// the Director mode chosen when it was created.
    private var directorModeForSnapshot: String {
        UserDefaults.standard.string(forKey: DirectorMode.userDefaultsKey)
            ?? DirectorMode.auto.rawValue
    }

    private func refresh() {
        projects = store.allProjects.filter { project in
            mode == .hybrid ? project.workflowMode == "hybrid" : project.workflowMode != "hybrid"
        }
        // Consistency is derived data: when the comparator's semantics change,
        // an old persisted verdict can be wrong without anything about the
        // movie itself changing. Recomputing it here — from evidence already
        // on disk, no Vision call — is what corrects an existing project the
        // next time its list loads, rather than only new ones going forward.
        // Self-limiting: a verdict already at the current version is a no-op,
        // so this does not write on every 2-second poll.
        if mode == .hybrid {
            var didUpdate = false
            for project in projects {
                guard var fresh = store.project(id: project.id) else { continue }
                if OpeningReferenceSync.refreshConsistencyIfOutdated(project: &fresh) {
                    store.save(fresh)
                    didUpdate = true
                }
            }
            if didUpdate {
                projects = store.allProjects.filter { $0.workflowMode == "hybrid" }
            }
        }
    }

    private func createProject(
        projectID: UUID,
        title: String,
        brief: String,
        settings: ProjectSettings,
        characterBible: CharacterBible,
        generateFirstPass: Bool,
        openingReferenceURL: URL? = nil
    ) {
        isCreating = true
        planningPhase = .preparing
        planningElapsedSeconds = 0
        let handle = DirectorPlanningHandle()
        planningHandle = handle
        statusMessage = "Preparing Local Director…"

        let planningTask = Task { @MainActor in
            let timerTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    planningElapsedSeconds += 1
                }
            }
            defer {
                timerTask.cancel()
                isCreating = false
                planningHandle = nil
            }
            do {
                // The opening reference is imported and read *before* planning.
                // When the Director ran first it invented a costume from the
                // brief text alone, and every compiled prompt then contradicted
                // the image the movie opens on (D-071).
                var importedOpeningReference: OpeningReferenceImage?
                var openingAppearance: OpeningReferenceAppearance?
                if let openingReferenceURL {
                    do {
                        importedOpeningReference = try store.importOpeningReferenceImage(
                            from: openingReferenceURL, projectID: projectID)
                    } catch {
                        // Never fall through to text-to-video: the user asked
                        // the movie to open on a specific image.
                        store.removeUncommittedProjectAssets(projectID: projectID)
                        statusMessage = (error as? LocalizedError)?.errorDescription
                            ?? "Could not import the opening reference image. The Auto Movie was not created."
                        return
                    }
                    if let importedOpeningReference {
                        statusMessage = "Reading the opening reference…"
                        openingAppearance = await OpeningReferenceAppearanceSession.analyse(
                            image: importedOpeningReference, projectID: projectID, store: store)
                    }
                }
                // Planning starts from a Bible that already agrees with the
                // image, so the Director has nothing to contradict.
                let planningBible = OpeningReferenceSync.seedBible(
                    from: openingAppearance, existing: characterBible)

                if handle.isCancelled || Task.isCancelled {
                    throw DirectorError.cancelled
                }

                let progressCallback: (DirectorPlanningPhase, String) -> Void = { phase, message in
                    Task { @MainActor in
                        planningPhase = phase
                        statusMessage = message
                    }
                }

                var (project, violations, _) = mode == .hybrid
                    ? try await HybridProjectCoordinator().makeProject(
                        projectID: projectID, title: title, brief: brief,
                        settings: settings, characterBible: planningBible,
                        openingSceneEvidence: openingAppearance,
                        handle: handle,
                        progressCallback: progressCallback
                    )
                    : try await StoryboardDirector().makeProject(
                        projectID: projectID, title: title, brief: brief,
                        settings: settings, characterBible: planningBible,
                        openingSceneEvidence: openingAppearance,
                        handle: handle,
                        progressCallback: progressCallback
                    )
                project.workflowMode = mode.workflowValue
                if mode == .hybrid {
                    project.continuityChainEnabled = true
                }
                // Already imported above, before planning. Attaching it here
                // still happens before `save`, so shot 1's generation request —
                // queued a few lines below — resolves it exactly as before.
                project.openingReferenceImage = importedOpeningReference
                project.openingReferenceAppearance = openingAppearance
                // The Director may still have produced its own character. Image
                // evidence supersedes an auto-generated guess, and never
                // overwrites anything the user authored.
                project.characterBible = OpeningReferenceSync.apply(
                    appearance: openingAppearance, to: project.characterBible)
                // Reporting only, after the canonical merge: records how the
                // opening image compares with the character sheet without
                // changing either.
                OpeningReferenceSync.evaluateConsistency(project: &project)
                CharacterPromptPipeline.recompile(project: &project)
                store.save(project)
                if mode == .hybrid, generateFirstPass {
                    if !DependencyHealthManager.shared.canStartGeneration {
                        DependencyHealthManager.shared.showSetupWizard = true
                    } else {
                        // Rendering goes through the global production queue so
                        // several movies can be lined up and left to run. The
                        // queue starts this immediately when idle, so a single
                        // movie behaves exactly as it did before; when another
                        // job is already running this one waits its turn instead
                        // of interleaving its shots with the other movie's.
                        var snapshot = ProductionJobSnapshot()
                        snapshot.projectID = project.id
                        snapshot.brief = brief
                        snapshot.preset = settings.preset
                        snapshot.qualityMode = settings.qualityMode
                        snapshot.modelID = settings.modelID
                        snapshot.textEncoderID = settings.textEncoderID
                        snapshot.audioEnabled = settings.audioEnabled
                        snapshot.targetDurationSeconds = settings.targetDurationSeconds
                        snapshot.directorMode = directorModeForSnapshot
                        // The opening reference and character anchor are already
                        // project-managed copies, so recording their paths keeps
                        // the job deterministic without duplicating image bytes.
                        snapshot.openingReferenceRelativePath =
                            project.openingReferenceImage?.projectRelativePath
                        snapshot.characterAnchorCharacterID = project.characterAnchor.characterID
                        snapshot.characterAnchorAssetID = project.characterAnchor.referenceAssetID
                        // Appended, not jumped to the front. Creating a movie is
                        // not "run this before the ones I already asked for":
                        // queueing three movies to run overnight must run them
                        // first, second, third, and inserting at the head runs
                        // them backwards.
                        ProductionQueueService.shared.enqueue(ProductionJob(
                            kind: mode == .hybrid ? .autoMovie : .storyboard,
                            title: project.title,
                            snapshot: snapshot
                        ))
                    }
                }
                selectedProjectID = project.id
                refresh()
                let warnings = violations.filter { $0.severity == .warning }.count
                let errors = violations.filter { $0.severity == .error }.count
                let planningSource: String
                switch project.planningMode {
                case "basic": planningSource = "Basic Director"
                case "fallback": planningSource = "Basic Director fallback"
                default: planningSource = "Local AI Director"
                }
                statusMessage = "Planned \(project.shots.count) shots via \(planningSource)"
                    + (mode == .hybrid && generateFirstPass ? "; queued one take per shot sequentially" : "")
                    + (violations.isEmpty ? "" : " (\(errors) continuity errors, \(warnings) warnings)")
                planningPhase = .completed
                showNewProjectSheet = false
            } catch {
                if (error as? DirectorError) == .cancelled || handle.isCancelled || Task.isCancelled {
                    planningPhase = .cancelled
                    statusMessage = "Planning cancelled."
                    store.removeUncommittedProjectAssets(projectID: projectID)
                } else {
                    planningPhase = .failed
                    statusMessage = "Storyboard planning failed: \(error.localizedDescription)"
                }
            }
        }
        handle.registerTask(planningTask)
    }
}

// MARK: - New storyboard sheet

private struct NewStoryboardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var generationService: GenerationService
    @Binding var isCreating: Bool
    @Binding var planningPhase: DirectorPlanningPhase
    @Binding var planningElapsedSeconds: Int
    @Binding var planningHandle: DirectorPlanningHandle?
    let mode: StoryboardWorkspaceMode
    let onCreate: (UUID, String, String, ProjectSettings, CharacterBible, Bool, URL?) -> Void

    @State private var title = ""
    @State private var brief = ""
    @State private var presetRaw = GenerationPreset.standard.rawValue
    @State private var modelID = LTXModelCatalog.selectedModel().id
    @State private var audioEnabled = true
    @State private var targetDuration = 20.0
    @State private var generateFirstPass = true
    @State private var width = 768
    @State private var height = 512
    @State private var characterBible = CharacterBible()
    /// Held as a plain URL until Create: nothing is copied into a project while
    /// the sheet is open, so cancelling leaves no managed asset behind.
    @State private var openingReferenceURL: URL?
    @State private var projectID = UUID()
    @AppStorage(DirectorMode.userDefaultsKey) private var directorModeRaw = DirectorMode.auto.rawValue
    @State private var directorSnapshot = DirectorSetupSnapshot.checking(mode: .auto)
    @State private var isCheckingDirector = false
    private let directorEnvironment = DirectorEnvironmentService()

    private var directorMode: DirectorMode {
        DirectorMode(rawValue: directorModeRaw) ?? .auto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .hybrid ? "New Auto Movie" : "New Storyboard")
                .font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
            Text("Brief — what is this short film about?")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $brief)
                .font(.body)
                .frame(height: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .disabled(isCreating)
            CharacterBibleDraftSection(
                projectID: projectID,
                bible: $characterBible,
                generationActive: generationService.isProcessing || isCreating
            )
            HStack {
                Picker("Preset", selection: $presetRaw) {
                    ForEach(GenerationPreset.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("Model", selection: $modelID) {
                    ForEach(ModelRegistry.shared.selectableModels()) { Text($0.displayName).tag($0.id) }
                }
                Toggle("Audio", isOn: $audioEnabled)
                    .onChange(of: audioEnabled) { old, new in
                        if old != new { presetRaw = GenerationPreset.custom.rawValue }
                    }
            }
            .disabled(isCreating)
            if presetRaw == GenerationPreset.custom.rawValue {
                HStack {
                    Picker("Width", selection: $width) {
                        ForEach([320, 512, 640, 768, 896, 1024], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Height", selection: $height) {
                        ForEach([320, 384, 512, 576, 768, 1024, 1080], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Text(effectiveResolutionText(width: width, height: height))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(isCreating)
            }
            if mode == .hybrid {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Opening Reference Image (Optional)").font(.subheadline.bold())
                    OpeningReferencePicker(selection: $openingReferenceURL, compact: true)
                    OpeningReferenceExplanation()
                }
                .disabled(isCreating)
                Stepper("Target Duration: \(targetDuration, specifier: "%.0f")s", value: $targetDuration, in: 5...60, step: 5)
                    .disabled(isCreating)
                Toggle("Generate first pass after planning", isOn: $generateFirstPass)
                    .help("Turn off to review the Character Bible, shot assignments and compiled prompts before rendering.")
                    .disabled(isCreating)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("Director", selection: $directorModeRaw) {
                        Text("Auto").tag(DirectorMode.auto.rawValue)
                        Text("Local AI").tag(DirectorMode.localAI.rawValue)
                        Text("Basic").tag(DirectorMode.basic.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isCreating)
                    if isCheckingDirector { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 6) {
                    Image(systemName: directorStatusIcon)
                        .foregroundStyle(directorStatusColor)
                    Text(directorStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Local AI can improve planning. Basic Director works without additional setup.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isCreating {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(planningPhase.displayName)
                            .font(.subheadline.bold())
                        Spacer()
                        Text(formatPlanningTime(planningElapsedSeconds))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button {
                            planningPhase = .cancelling
                            planningHandle?.cancel()
                        } label: {
                            if planningPhase == .cancelling {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini)
                                    Text("Cancelling…")
                                }
                            } else {
                                Text("Cancel Planning")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(planningPhase == .cancelling)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isCreating)
                Button {
                    var settings = ProjectSettings.usingCurrentSelections()
                    let preset = GenerationPreset(rawValue: presetRaw) ?? .standard
                    settings.applyPreset(preset)
                    settings.modelID = modelID
                    // Audio remains a deliberate choice for Quick (C3 with
                    // audio, C2 without it). Width and height are Custom-only
                    // controls, so never overwrite a selected preset with
                    // stale sheet state.
                    settings.audioEnabled = audioEnabled
                    if preset == .custom {
                        settings.width = width
                        settings.height = height
                    }
                    settings.targetDurationSeconds = mode == .hybrid ? targetDuration : nil
                    onCreate(
                        projectID,
                        title.isEmpty ? (mode == .hybrid ? "Untitled Auto Movie" : "Untitled Storyboard") : title,
                        brief,
                        settings,
                        characterBible,
                        generateFirstPass,
                        mode == .hybrid ? openingReferenceURL : nil
                    )
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .hybrid
                             ? (generateFirstPass ? "Generate Movie" : "Create Auto Movie")
                             : "Create Storyboard")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await refreshDirectorStatus() }
        .onChange(of: directorModeRaw) { _, _ in
            Task { await refreshDirectorStatus() }
        }
        .onDisappear {
            if FilmProjectStore.shared.project(id: projectID) == nil {
                FilmProjectStore.shared.removeUncommittedProjectAssets(projectID: projectID)
            }
        }
    }

    private func formatPlanningTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(s)s"
        }
    }

    private var directorStatusText: String {
        switch directorSnapshot.availability {
        case .checking: return "Checking Director availability…"
        case .localAIReady(let model): return "Local AI Ready · \(model)"
        case .localAIModelMissing: return "Basic Director · Local AI model unavailable"
        case .localAIServerUnavailable: return "Basic Director · No setup required"
        case .basicOnly: return "Basic Director · No setup required"
        }
    }

    private var directorStatusIcon: String {
        switch directorSnapshot.availability {
        case .localAIReady, .basicOnly: return "checkmark.circle.fill"
        case .checking: return "clock"
        case .localAIModelMissing, .localAIServerUnavailable: return "info.circle.fill"
        }
    }

    private var directorStatusColor: Color {
        switch directorSnapshot.availability {
        case .localAIReady, .basicOnly: return .green
        case .checking: return .secondary
        case .localAIModelMissing, .localAIServerUnavailable: return .orange
        }
    }

    @MainActor
    private func refreshDirectorStatus() async {
        isCheckingDirector = true
        directorSnapshot = await directorEnvironment.refresh(mode: directorMode)
        isCheckingDirector = false
    }

    private func effectiveResolutionText(width: Int, height: Int) -> String {
        let effectiveWidth = (width / 64) * 64
        let effectiveHeight = (height / 64) * 64
        return effectiveWidth == width && effectiveHeight == height
            ? "Requested = Effective \(width)×\(height)"
            : "Requested \(width)×\(height) → Effective \(effectiveWidth)×\(effectiveHeight)"
    }
}

struct HybridView: View {
    var body: some View { StoryboardView(mode: .hybrid) }
}

// MARK: - Project detail

private struct ProjectDetailView: View {
    let project: FilmProject
    let generationService: GenerationService
    @Binding var statusMessage: String?
    @Binding var isAssembling: Bool
    let onChanged: () -> Void

    private let store = FilmProjectStore.shared

    private var coordinator: TakeGenerationCoordinator {
        TakeGenerationCoordinator(store: store, generationService: generationService)
    }

    private var shotsMissingTakes: [Shot] {
        project.shots.filter { shot in
            !shot.takes.contains { $0.status == .completed || $0.status == .queued || $0.status == .generating }
        }
    }

    private var readyToAssemble: Bool {
        !project.shots.isEmpty && project.shots.allSatisfy { $0.selectedTake?.status == .completed }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                // Auto Movie only: the anchor establishes the opening shot, and
                // Storyboard shots are authored one by one with their own
                // starting images.
                if project.workflowMode == "hybrid" {
                    // Consistency sits above Planned Shots specifically so it
                    // is visible without scrolling — it was previously nested
                    // inside Opening Reference, far enough down the page that
                    // it went unnoticed before generation started.
                    CharacterOpeningConsistencySection(project: project)
                    // Shown above the settings so the plan is the first thing
                    // read: it is what the next twenty minutes will produce.
                    AutoMoviePlanPreviewSection(project: project, onChanged: onChanged)
                    OpeningReferenceSection(project: project, onChanged: onChanged)
                    CharacterAnchorSection(project: project, onChanged: onChanged)
                }
                Divider()
                ForEach(project.shots) { shot in
                    ShotCard(
                        project: project,
                        shot: shot,
                        coordinator: coordinator,
                        statusMessage: $statusMessage,
                        onChanged: onChanged
                    )
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.title)
                .font(.title2.bold())
            if !project.storyBible.logline.isEmpty {
                Text(project.storyBible.logline)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            if project.planningMode == "fallback" {
                Label("Director: Basic Fallback", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(DirectorEnvironmentService.friendlyFallbackReason(project.fallbackReason))
            } else if project.planningMode == "basic" {
                Label("Director: Basic", systemImage: "movieclapper")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("No additional setup was required.")
            } else if project.planningMode == "ai" {
                HStack(spacing: 6) {
                    Label("Director: Local AI", systemImage: "sparkles")
                    if let model = project.directorModel {
                        Text(model)
                            .foregroundStyle(.secondary)
                    }
                    if let protocolName = project.directorProtocol {
                        Text(protocolName == "textProtocol" ? "(Text Protocol)" : "(Structured)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .help("Planned by \(project.directorProvider ?? "local AI") via \(project.directorProtocol ?? "local protocol")")
            }
            ProjectSettingsEditor(project: project) {
                onChanged()
            }
            FinalAudioEditor(project: project) {
                onChanged()
            }
            ProjectCharactersSection(
                project: project,
                generationActive: generationService.isProcessing,
                onChanged: onChanged
            )
            HStack(spacing: 12) {
                // Generate one take for every shot that has none yet.
                Button {
                    generateMissingTakes()
                } label: {
                    Label("Generate Missing Takes", systemImage: "play.rectangle.on.rectangle")
                }
                .disabled(shotsMissingTakes.isEmpty)
                .help(shotsMissingTakes.isEmpty
                      ? "Every shot already has a take (queued or completed)."
                      : "Queues one take for each of the \(shotsMissingTakes.count) shots without takes. Generation is sequential.")

                Button {
                    regenerateSelectedShots()
                } label: {
                    Label("Regenerate Selected Shots", systemImage: "arrow.clockwise.circle")
                }
                .disabled(project.shots.allSatisfy { $0.selectedTakeID == nil })
                .help("Adds one new take for each shot that currently has a selected take, using the current Project Settings. Existing preview takes are kept.")

                Button {
                    assemble()
                } label: {
                    if isAssembling {
                        ProgressView().controlSize(.small)
                        Text("Assembling…")
                    } else {
                        Label("Assemble Final Video", systemImage: "film")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!readyToAssemble || isAssembling)
                .help(readyToAssemble
                      ? "Concatenates the selected takes (stream copy when compatible, otherwise normalize + re-encode)."
                      : "Select a completed take for every shot first.")
                Spacer()
                Text("\(project.shots.count) shots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Finished movie produced by automatic (or manual) assembly.
            if let moviePath = project.assembledMoviePath,
               FileManager.default.fileExists(atPath: moviePath) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Completed movie ready")
                            .font(.callout.bold())
                        Text(URL(fileURLWithPath: moviePath).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if project.finalAudio.isActive {
                            VStack(alignment: .leading) {
                                if project.finalAudio.isBGMActive {
                                    Text("Global BGM: \(project.finalAudio.bgmAsset?.originalFilename ?? "—") · Volume: \(Int(project.finalAudio.bgmVolume * 100))%")
                                }
                                if project.finalAudio.isAmbienceActive {
                                    Text("Global Ambience: \(project.finalAudio.ambienceAsset?.originalFilename ?? "—") · Volume: \(Int(project.finalAudio.ambienceVolume * 100))%")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Play") { NSWorkspace.shared.open(URL(fileURLWithPath: moviePath)) }
                    Button("Reveal") {
                        NSWorkspace.shared.selectFile(moviePath, inFileViewerRootedAtPath: "")
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08)))
            }
        }
    }

    private func generateMissingTakes() {
        if !DependencyHealthManager.shared.canStartGeneration {
            DependencyHealthManager.shared.showSetupWizard = true
            return
        }
        var queued = 0
        for shot in shotsMissingTakes {
            if (try? coordinator.planTakes(projectID: project.id, shotID: shot.id, count: 1)) != nil {
                queued += 1
            }
        }
        statusMessage = "Queued 1 take for \(queued) shots (sequential)"
        onChanged()
    }

    private func regenerateSelectedShots() {
        if !DependencyHealthManager.shared.canStartGeneration {
            DependencyHealthManager.shared.showSetupWizard = true
            return
        }
        var queued = 0
        for shot in project.shots where shot.selectedTakeID != nil {
            if (try? coordinator.planTakes(projectID: project.id, shotID: shot.id, count: 1)) != nil {
                queued += 1
            }
        }
        statusMessage = "Queued \(queued) selected shots at \(project.settings.resolvedPreset.displayName); previous takes kept"
        onChanged()
    }

    private func assemble() {
        isAssembling = true
        statusMessage = "Assembling final video…"
        let projectSnapshot = project
        let outputPath = store.projectsDirectory
            .appendingPathComponent("\(project.id.uuidString)_final.mp4").path
        Task.detached {
            do {
                let info = try FinalAssemblyService.assemble(project: projectSnapshot, outputPath: outputPath)
                await MainActor.run {
                    isAssembling = false
                    let size = "\(info.width ?? 0)×\(info.height ?? 0)"
                    let duration = String(format: "%.1fs", info.durationSeconds ?? 0)
                    statusMessage = "Final video: \(size), \(duration) — revealed in Finder"
                    NSWorkspace.shared.selectFile(outputPath, inFileViewerRootedAtPath: "")
                }
            } catch {
                await MainActor.run {
                    isAssembling = false
                    statusMessage = "Assembly failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

private func fmtSeconds(_ value: Double) -> String {
    value == value.rounded() ? "\(Int(value))s" : String(format: "%.1fs", value)
}

// MARK: - Shared project settings

private struct ProjectSettingsEditor: View {
    let project: FilmProject
    let onChanged: () -> Void

    @State private var expanded = true
    private let store = FilmProjectStore.shared

    var body: some View {
        DisclosureGroup("Project Settings", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Picker("Preset", selection: binding(
                        get: { project.settings.resolvedPreset.rawValue },
                        set: { raw, settings in settings.applyPreset(GenerationPreset(rawValue: raw) ?? .standard) }
                    )) {
                        ForEach(GenerationPreset.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    Picker("Model", selection: binding(
                        get: { project.settings.modelID },
                        set: { $1.modelID = $0 }
                    )) {
                        ForEach(ModelRegistry.shared.selectableModels()) { Text($0.displayName).tag($0.id) }
                    }
                    Toggle("Audio", isOn: binding(
                        get: { project.settings.resolvedAudioEnabled },
                        set: { value, settings in
                            settings.audioEnabled = value
                            settings.markCustom()
                        }
                    ))
                    Spacer()
                }
                Text(project.settings.resolvedPreset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if project.settings.resolvedPreset == .custom {
                    HStack(spacing: 12) {
                        Picker("Width", selection: customBinding(\.width)) {
                            ForEach([320, 512, 640, 768, 896, 1024], id: \.self) { Text("\($0)").tag($0) }
                        }
                        Picker("Height", selection: customBinding(\.height)) {
                            ForEach([320, 384, 512, 576, 704, 768, 864, 1024, 1080, 1152], id: \.self) { Text("\($0)").tag($0) }
                        }
                        Picker("FPS", selection: customBinding(\.fps)) {
                            ForEach([12, 20, 24, 30], id: \.self) { Text("\($0)").tag($0) }
                        }
                        Stepper("Frames: \(project.settings.numFrames ?? 121)", value: optionalIntBinding(\.numFrames, default: 121), in: 25...241, step: 8)
                        Stepper("Steps: \(project.settings.numInferenceSteps ?? 30)", value: optionalIntBinding(\.numInferenceSteps, default: 30), in: 10...100, step: 5)
                    }
                }
                Text(resolutionSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.headline)
    }

    private var resolutionSummary: String {
        let settings = project.settings
        if settings.resolvedPreset == .custom {
            let effectiveWidth = (settings.width / 64) * 64
            let effectiveHeight = (settings.height / 64) * 64
            return "Requested \(settings.width)×\(settings.height) → Effective \(effectiveWidth)×\(effectiveHeight) → Actual shown per completed Take"
        }
        var parameters = GenerationParameters.default
        parameters.width = settings.width
        parameters.height = settings.height
        parameters.fps = settings.fps
        parameters.numInferenceSteps = settings.resolvedInferenceSteps
        let orientation = FilmProjectResolutionOrientationResolver.resolve(
            project: project, store: store)
        let request = GenerationRequest(
            prompt: "Project resolution preflight",
            presetResolutionOrientation: orientation,
            disableAudio: !settings.resolvedAudioEnabled,
            modelId: settings.modelID,
            textEncoderId: settings.textEncoderID,
            parameters: parameters,
            qualityMode: settings.qualityMode,
            preset: settings.resolvedPreset.rawValue,
            generationSource: project.workflowMode == "hybrid" ? "hybrid" : "storyboard"
        )
        let resolved = GenerationSettingsResolver.resolveForPreflight(request: request).request
        let orientationLabel = orientation.displayName.map { " · \($0)" } ?? ""
        return "\(settings.resolvedPreset.displayName) · Effective \(resolved.parameters.width)×\(resolved.parameters.height)\(orientationLabel) · \(resolved.parameters.numInferenceSteps) steps → Actual shown per completed Take"
    }

    private func save(_ change: (inout ProjectSettings) -> Void) {
        guard var updated = store.project(id: project.id) else { return }
        change(&updated.settings)
        updated.touch()
        store.save(updated)
        onChanged()
    }

    private func binding<Value>(
        get: @escaping () -> Value,
        set: @escaping (Value, inout ProjectSettings) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: { value in save { set(value, &$0) } })
    }

    private func customBinding(_ keyPath: WritableKeyPath<ProjectSettings, Int>) -> Binding<Int> {
        Binding(
            get: { project.settings[keyPath: keyPath] },
            set: { value in save { settings in
                settings[keyPath: keyPath] = value
                settings.markCustom()
            } }
        )
    }

    private func optionalIntBinding(
        _ keyPath: WritableKeyPath<ProjectSettings, Int?>,
        default defaultValue: Int
    ) -> Binding<Int> {
        Binding(
            get: { project.settings[keyPath: keyPath] ?? defaultValue },
            set: { value in save { settings in
                settings[keyPath: keyPath] = value
                settings.markCustom()
            } }
        )
    }
}

// MARK: - Final Audio (Global BGM overlay)

/// One BGM file applied once, after Final Assembly, to the whole movie —
/// never per Shot, never injected into any Shot's prompt. Off by default;
/// existing Final Assembly behavior is unchanged unless the user explicitly
/// enables this and imports a file.
private struct FinalAudioEditor: View {
    let project: FilmProject
    let onChanged: () -> Void

    @State private var expanded = false
    @State private var importError: String?
    private let store = FilmProjectStore.shared

    var body: some View {
        DisclosureGroup("Final Audio", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: BGM Section
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Global BGM", isOn: bgmEnabledBinding)
                        .help("Applies one background music track to the whole assembled movie, once, after Final Assembly. Shot audio (dialogue, footsteps, SFX, ambience) is preserved and mixed with it — no Shot is ever regenerated.")

                    if project.finalAudio.bgmEnabled {
                        HStack {
                            if let asset = project.finalAudio.bgmAsset {
                                Image(systemName: "music.note")
                                Text(asset.originalFilename ?? "Imported audio")
                                    .font(.callout)
                                Spacer()
                                Button("Replace…") { importAudio(isBGM: true) }
                                Button("Remove") { removeAudio(isBGM: true) }
                            } else {
                                Text("No BGM file selected.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Import Audio…") { importAudio(isBGM: true) }
                            }
                        }

                        if project.finalAudio.bgmAsset != nil {
                            HStack(spacing: 16) {
                                HStack(spacing: 6) {
                                    Text("Volume")
                                    Slider(value: bgmVolumeBinding, in: 0...1)
                                        .frame(width: 140)
                                    Text("\(Int(project.finalAudio.bgmVolume * 100))%")
                                        .font(.caption.monospaced())
                                        .frame(width: 40, alignment: .trailing)
                                }
                                Stepper(
                                    "Fade In: \(fmtSeconds(project.finalAudio.fadeInSeconds))",
                                    value: fadeInBinding, in: 0...30, step: 1
                                )
                                Stepper(
                                    "Fade Out: \(fmtSeconds(project.finalAudio.fadeOutSeconds))",
                                    value: fadeOutBinding, in: 0...30, step: 1
                                )
                            }
                        }
                    }
                }
                
                Divider()
                
                // MARK: Ambience Section
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Global Ambience", isOn: ambienceEnabledBinding)
                        .help("Applies an ambient track (e.g. room tone, nature) to the whole assembled movie.")

                    if project.finalAudio.ambienceEnabled {
                        HStack {
                            if let asset = project.finalAudio.ambienceAsset {
                                Image(systemName: "waveform")
                                Text(asset.originalFilename ?? "Imported audio")
                                    .font(.callout)
                                Spacer()
                                Button("Replace…") { importAudio(isBGM: false) }
                                Button("Remove") { removeAudio(isBGM: false) }
                            } else {
                                Text("No Ambience file selected.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Import Audio…") { importAudio(isBGM: false) }
                            }
                        }

                        if project.finalAudio.ambienceAsset != nil {
                            HStack(spacing: 16) {
                                HStack(spacing: 6) {
                                    Text("Volume")
                                    Slider(value: ambienceVolumeBinding, in: 0...1)
                                        .frame(width: 140)
                                    Text("\(Int(project.finalAudio.ambienceVolume * 100))%")
                                        .font(.caption.monospaced())
                                        .frame(width: 40, alignment: .trailing)
                                }
                                Stepper(
                                    "Fade In: \(fmtSeconds(project.finalAudio.ambienceFadeInSeconds))",
                                    value: ambienceFadeInBinding, in: 0...30, step: 1
                                )
                                Stepper(
                                    "Fade Out: \(fmtSeconds(project.finalAudio.ambienceFadeOutSeconds))",
                                    value: ambienceFadeOutBinding, in: 0...30, step: 1
                                )
                            }
                        }
                    }
                }
                
                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if project.finalAudio.isActive {
                    Text("Final Audio mixes under existing Shot audio at re-assembly — re-run Assemble Final Video after changing these to hear the update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Off — Final Assembly output is unchanged from before this feature existed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
        .font(.headline)
    }

    private func importAudio(isBGM: Bool) {
        importError = nil
        let panel = NSOpenPanel()
        panel.title = isBGM ? "Import Global BGM" : "Import Global Ambience"
        panel.prompt = "Use Audio"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mp3, .wav, .mpeg4Audio]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        do {
            let imported = isBGM ? try store.importFinalAudioAsset(from: sourceURL, projectID: project.id) : try store.importFinalAmbienceAsset(from: sourceURL, projectID: project.id)
            guard var stored = store.project(id: project.id) else { return }
            
            if isBGM {
                if let previous = stored.finalAudio.bgmAsset {
                    store.removeManagedFinalAudioAsset(projectID: project.id, asset: previous)
                }
                stored.finalAudio.bgmAsset = imported
            } else {
                if let previous = stored.finalAudio.ambienceAsset {
                    store.removeManagedFinalAmbienceAsset(projectID: project.id, asset: previous)
                }
                stored.finalAudio.ambienceAsset = imported
            }
            stored.touch()
            store.save(stored)
            onChanged()
        } catch {
            importError = error.localizedDescription
        }
    }

    private func removeAudio(isBGM: Bool) {
        guard var stored = store.project(id: project.id) else { return }
        if isBGM {
            if let previous = stored.finalAudio.bgmAsset {
                store.removeManagedFinalAudioAsset(projectID: project.id, asset: previous)
            }
            stored.finalAudio.bgmAsset = nil
            stored.finalAudio.bgmEnabled = false
        } else {
            if let previous = stored.finalAudio.ambienceAsset {
                store.removeManagedFinalAmbienceAsset(projectID: project.id, asset: previous)
            }
            stored.finalAudio.ambienceAsset = nil
            stored.finalAudio.ambienceEnabled = false
        }
        stored.touch()
        store.save(stored)
        onChanged()
    }

    private func save(_ change: (inout FinalAudioSettings) -> Void) {
        guard var updated = store.project(id: project.id) else { return }
        change(&updated.finalAudio)
        updated.touch()
        store.save(updated)
        onChanged()
    }

    private var bgmEnabledBinding: Binding<Bool> { Binding(get: { project.finalAudio.bgmEnabled }, set: { v in save { $0.bgmEnabled = v } }) }
    private var bgmVolumeBinding: Binding<Double> { Binding(get: { project.finalAudio.bgmVolume }, set: { v in save { $0.bgmVolume = v } }) }
    private var fadeInBinding: Binding<Double> { Binding(get: { project.finalAudio.fadeInSeconds }, set: { v in save { $0.fadeInSeconds = v } }) }
    private var fadeOutBinding: Binding<Double> { Binding(get: { project.finalAudio.fadeOutSeconds }, set: { v in save { $0.fadeOutSeconds = v } }) }
    
    private var ambienceEnabledBinding: Binding<Bool> { Binding(get: { project.finalAudio.ambienceEnabled }, set: { v in save { $0.ambienceEnabled = v } }) }
    private var ambienceVolumeBinding: Binding<Double> { Binding(get: { project.finalAudio.ambienceVolume }, set: { v in save { $0.ambienceVolume = v } }) }
    private var ambienceFadeInBinding: Binding<Double> { Binding(get: { project.finalAudio.ambienceFadeInSeconds }, set: { v in save { $0.ambienceFadeInSeconds = v } }) }
    private var ambienceFadeOutBinding: Binding<Double> { Binding(get: { project.finalAudio.ambienceFadeOutSeconds }, set: { v in save { $0.ambienceFadeOutSeconds = v } }) }
}

// MARK: - Shot card

private struct ShotCard: View {
    let project: FilmProject
    let shot: Shot
    let coordinator: TakeGenerationCoordinator
    @Binding var statusMessage: String?
    let onChanged: () -> Void

    @State private var takeCount = 1
    @State private var showPrompt = false

    /// Shows whether this shot starts from the previous shot's final frame.
    /// The inherited frame is a visual anchor for the same scene and wardrobe;
    /// it is not identity conditioning and cannot guarantee the same person.
    @ViewBuilder
    private var continuityBadge: some View {
        let resolved = AutoMovieRunCoordinator.shared
            .displayedAutoMovieContinuityMode(forShotAt: shot.index, in: project)
        if let blocked = shot.continuityBlockedReason {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(blocked.userMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if shot.index > 0, resolved == .continueFromPrevious {
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.blue)
                Text("Continues from Shot \(shot.index)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if shot.startingImageReferenceAssetID != nil {
                    Text("· using this shot's own starting image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help("This shot starts from the final frame of the previous shot, which carries the scene, wardrobe and lighting forward. It improves visual continuity but does not guarantee an identical person.")
        } else if shot.index > 0 {
            HStack(spacing: 6) {
                Image(systemName: "scissors").foregroundStyle(.secondary)
                Text("Cut — starts a new scene")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shot \(shot.index + 1): \(shot.title)")
                    .font(.headline)
                Spacer()
                Text("\(shot.camera.shotScale) · \(shot.camera.angle) · \(shot.camera.movement) · \(String(format: "%.0fs", shot.durationSeconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(shot.summary)
                .font(.body)
                .foregroundStyle(.secondary)

            continuityBadge

            characterAssignment

            startingImageSection

            DisclosureGroup("Compiled prompt", isExpanded: $showPrompt) {
                Text(shot.compiledPrompt)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)

            // Takes
            if !shot.takes.isEmpty {
                VStack(spacing: 4) {
                    ForEach(shot.takes) { take in
                        TakeRow(
                            project: project,
                            shot: shot,
                            take: take,
                            isSelected: shot.selectedTakeID == take.id,
                            coordinator: coordinator,
                            onChanged: onChanged
                        )
                    }
                }
            }

            HStack(spacing: 10) {
                Stepper("Takes: \(takeCount)", value: $takeCount, in: 1...TakeGenerationCoordinator.maxTakesPerShot)
                    .fixedSize()
                Button {
                    plan(count: takeCount)
                } label: {
                    Label("Generate \(takeCount) Take\(takeCount == 1 ? "" : "s")", systemImage: "play.fill")
                }
                .help("Each take uses a different seed. Takes render one at a time.")
                if shot.takes.contains(where: { $0.status == .completed }) {
                    Button {
                        plan(count: 1)
                    } label: {
                        Label("Regenerate at Current Preset", systemImage: "arrow.clockwise")
                    }
                    .help("Queue one more take with a fresh seed.")
                }
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func plan(count: Int) {
        if !DependencyHealthManager.shared.canStartGeneration {
            DependencyHealthManager.shared.showSetupWizard = true
            return
        }
        do {
            _ = try coordinator.planTakes(projectID: project.id, shotID: shot.id, count: count)
            statusMessage = "Queued \(count) take\(count == 1 ? "" : "s") for Shot \(shot.index + 1)"
            onChanged()
        } catch {
            statusMessage = "Could not queue takes: \(error)"
        }
    }

    @ViewBuilder
    private var characterAssignment: some View {
        if !project.characterBible.characters.isEmpty {
            HStack(spacing: 8) {
                Text("Characters")
                    .font(.caption.bold())
                let assigned = project.characterBible.characters.filter { shot.characterIDs.contains($0.id) }
                if assigned.isEmpty {
                    Text("None")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(assigned) { character in
                        Text(character.name)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
                Menu("Change…") {
                    ForEach(project.characterBible.characters) { character in
                        let selected = shot.characterIDs.contains(character.id)
                        Button {
                            setCharacter(character.id, present: !selected)
                        } label: {
                            Label(
                                "\(character.name) · \(character.id.uuidString.prefix(6))",
                                systemImage: selected ? "checkmark.square.fill" : "square"
                            )
                        }
                    }
                }
                .controlSize(.small)
                Spacer()
            }
        }
    }

    private func setCharacter(_ characterID: UUID, present: Bool) {
        guard var updated = FilmProjectStore.shared.project(id: project.id) else { return }
        updated.setCharacter(characterID, present: present, inShot: shot.id)
        FilmProjectStore.shared.save(updated)
        onChanged()
    }

    @ViewBuilder
    private var startingImageSection: some View {
        if !project.characterBible.characters.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Starting Image (this shot only)")
                        .font(.caption.bold())
                        .help("Optional first-frame image anchor. Anchors the initial frame but restricts camera movement, pose, and background. Recommended: None for dynamic shots.")

                    let currentAssetID = shot.startingImageReferenceAssetID
                    let resolved = currentAssetID.flatMap { project.findReferenceAsset(id: $0) }

                    if let (character, asset) = resolved,
                       let relativePath = asset.projectRelativePath,
                       let url = FilmProjectStore.shared.managedCharacterAssetURL(projectID: project.id, relativePath: relativePath),
                       FileManager.default.fileExists(atPath: url.path) {

                        HStack(spacing: 4) {
                            if let image = NSImage(contentsOf: url) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 20, height: 20)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            Text("\(character.name) · \(asset.displayLabel)")
                                .font(.caption)

                            if asset.type == .front {
                                Text("Recommended Anchor")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            } else if asset.type == .face {
                                Text("Advanced")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))

                    } else if currentAssetID != nil {
                        HStack(spacing: 6) {
                            Label("Image unavailable", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.red)

                            Button("Clear") {
                                setStartingImage(nil)
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Text("None (Recommended)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    startingImageMenu(currentAssetID: currentAssetID)

                    if currentAssetID != nil {
                        Button {
                            setStartingImage(nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear Starting Image")
                    }

                    Spacer()
                }

                // Inline Guidance & Warnings
                if let currentAssetID = shot.startingImageReferenceAssetID,
                   let (_, asset) = project.findReferenceAsset(id: currentAssetID),
                   let relativePath = asset.projectRelativePath,
                   let url = FilmProjectStore.shared.managedCharacterAssetURL(projectID: project.id, relativePath: relativePath),
                   FileManager.default.fileExists(atPath: url.path) {

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Overrides this shot's first frame with a Character Bible asset. Separate from the movie-level Opening Reference Image, and takes precedence over it. Select None for dynamic camera movement.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if asset.type == .face {
                            Text("Close-up starting images strongly constrain camera framing and shot composition.")
                                .font(.caption2.bold())
                                .foregroundStyle(.orange)
                        }

                        if AspectMismatchCalculator.hasAspectMismatch(
                            sourceWidth: asset.pixelWidth,
                            sourceHeight: asset.pixelHeight,
                            targetWidth: project.settings.effectiveWidth,
                            targetHeight: project.settings.effectiveHeight
                        ) {
                            Text("Starting image aspect ratio (\(asset.pixelWidth ?? 0)×\(asset.pixelHeight ?? 0)) differs from video output (\(project.settings.effectiveWidth)×\(project.settings.effectiveHeight)) and may appear stretched.")
                                .font(.caption2.bold())
                                .foregroundStyle(.orange)
                        }
                    }
                } else if shot.startingImageReferenceAssetID != nil {
                    Text("Selected starting image is unavailable. Choose another image or clear the selection.")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func startingImageMenu(currentAssetID: UUID?) -> some View {
        Menu(currentAssetID == nil ? "Select…" : "Change…") {
            Button {
                setStartingImage(nil)
            } label: {
                Label("None (Recommended — Max camera freedom)", systemImage: currentAssetID == nil ? "checkmark" : "")
            }

            let assignedCharacters = project.characterBible.characters.filter { shot.characterIDs.contains($0.id) }
            let unassignedCharacters = project.characterBible.characters.filter { !shot.characterIDs.contains($0.id) }

            if !assignedCharacters.isEmpty {
                Divider()
                ForEach(assignedCharacters) { character in
                    renderCharacterMenuSections(character: character, titlePrefix: "")
                }
            }

            if !unassignedCharacters.isEmpty {
                let candidatesExist = unassignedCharacters.contains { char in
                    char.referenceAssets.contains(where: \.isStartingImageCandidate)
                }
                if candidatesExist {
                    Divider()
                    ForEach(unassignedCharacters) { character in
                        renderCharacterMenuSections(character: character, titlePrefix: "Other: ")
                    }
                }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func renderCharacterMenuSections(character: BibleCharacter, titlePrefix: String) -> some View {
        let candidates = character.referenceAssets.filter(\.isStartingImageCandidate)
        if !candidates.isEmpty {
            let recommended = candidates.filter { $0.type == .front }
            let otherViews = candidates.filter { $0.type == .side || $0.type == .back }
            let advanced = candidates.filter { $0.type == .face || $0.type == .expression || $0.type == .costumeDetail || $0.type == .other }

            Section("\(titlePrefix)\(character.name)") {
                if !recommended.isEmpty {
                    ForEach(recommended) { asset in
                        let selected = shot.startingImageReferenceAssetID == asset.id
                        Button {
                            setStartingImage(asset.id)
                        } label: {
                            Label("\(character.name) · Front (Recommended Anchor)", systemImage: selected ? "checkmark" : "")
                        }
                    }
                }

                if !otherViews.isEmpty {
                    ForEach(otherViews) { asset in
                        let selected = shot.startingImageReferenceAssetID == asset.id
                        Button {
                            setStartingImage(asset.id)
                        } label: {
                            Label("\(character.name) · \(asset.displayLabel)", systemImage: selected ? "checkmark" : "")
                        }
                    }
                }

                if !advanced.isEmpty {
                    ForEach(advanced) { asset in
                        let selected = shot.startingImageReferenceAssetID == asset.id
                        Button {
                            setStartingImage(asset.id)
                        } label: {
                            Label("\(character.name) · \(asset.displayLabel) (Advanced)", systemImage: selected ? "checkmark" : "")
                        }
                    }
                }
            }
        }
    }

    private func setStartingImage(_ assetID: UUID?) {
        guard var updated = FilmProjectStore.shared.project(id: project.id) else { return }
        updated.setStartingImageAsset(assetID, forShot: shot.id)
        FilmProjectStore.shared.save(updated)
        onChanged()
    }
}


// MARK: - Character Bible

private struct CharacterBibleDraftSection: View {
    let projectID: UUID
    @Binding var bible: CharacterBible
    let generationActive: Bool
    @State private var isExpanded = true
    @State private var editingCharacter: BibleCharacter?

    var body: some View {
        DisclosureGroup("Characters", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Character Bible · used by Director and every assigned shot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(bible.characters) { character in
                    CharacterSummaryRow(projectID: projectID, character: character) {
                        editingCharacter = character
                    } onDelete: {
                        FilmProjectStore.shared.removeManagedCharacterAssets(
                            projectID: projectID, characterID: character.id
                        )
                        bible.characters.removeAll { $0.id == character.id }
                        if var updatedProject = FilmProjectStore.shared.project(id: projectID) {
                            updatedProject.sanitizeStartingImageReferences()
                            FilmProjectStore.shared.save(updatedProject)
                        }
                    }
                }
                Button {
                    editingCharacter = BibleCharacter(name: "", lockedTraits: [.face, .hair, .eyes])
                } label: {
                    Label("Add Character", systemImage: "person.badge.plus")
                }
                .controlSize(.small)
                CharacterSheetImportButton(
                    projectID: projectID,
                    characters: bible.characters,
                    generationActive: generationActive
                ) { saved in
                    if let index = bible.characters.firstIndex(where: { $0.id == saved.id }) {
                        bible.characters[index] = saved
                    } else {
                        bible.characters.append(saved)
                    }
                }
            }
            .padding(.top, 6)
        }
        .sheet(item: $editingCharacter) { character in
            CharacterEditorSheet(
                projectID: projectID,
                generationActive: generationActive,
                character: character
            ) { saved in
                if let index = bible.characters.firstIndex(where: { $0.id == saved.id }) {
                    bible.characters[index] = saved
                } else {
                    bible.characters.append(saved)
                }
            } onReferenceAssetsChanged: { characterID, assets in
                if let index = bible.characters.firstIndex(where: { $0.id == characterID }) {
                    bible.characters[index].referenceAssets = assets
                    bible.characters[index].updatedAt = Date()
                }
            }
        }
    }
}

private struct ProjectCharactersSection: View {
    let project: FilmProject
    let generationActive: Bool
    let onChanged: () -> Void

    @State private var isExpanded = true
    @State private var editingCharacter: BibleCharacter?
    @State private var characterToDelete: BibleCharacter?
    private let store = FilmProjectStore.shared

    var body: some View {
        DisclosureGroup("Characters", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Character Bible · shared by Storyboard and Auto Movie")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if project.characterBible.characters.isEmpty {
                    Text("No characters yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(project.characterBible.characters) { character in
                    CharacterSummaryRow(projectID: project.id, character: character) {
                        editingCharacter = character
                    } onDelete: {
                        characterToDelete = character
                    }
                }
                Button {
                    editingCharacter = BibleCharacter(name: "", lockedTraits: [.face, .hair, .eyes])
                } label: {
                    Label("Add Character", systemImage: "person.badge.plus")
                }
                .controlSize(.small)
                CharacterSheetImportButton(
                    projectID: project.id,
                    characters: project.characterBible.characters,
                    generationActive: generationActive
                ) { saved in
                    guard var updated = store.project(id: project.id) else { return }
                    updated.upsertCharacter(saved)
                    store.save(updated)
                    onChanged()
                }
            }
            .padding(.top, 6)
        }
        .sheet(item: $editingCharacter) { character in
            CharacterEditorSheet(
                projectID: project.id,
                generationActive: generationActive,
                character: character
            ) { saved in
                guard var updated = store.project(id: project.id) else { return }
                updated.upsertCharacter(saved)
                store.save(updated)
                onChanged()
            } onReferenceAssetsChanged: { characterID, assets in
                guard var updated = store.project(id: project.id),
                      var saved = updated.characterBible.character(id: characterID) else { return }
                saved.referenceAssets = assets
                saved.updatedAt = Date()
                updated.upsertCharacter(saved)
                try store.saveThrowing(updated)
                onChanged()
            }
        }
        .alert(
            "Delete Character?",
            isPresented: Binding(
                get: { characterToDelete != nil },
                set: { if !$0 { characterToDelete = nil } }
            ),
            presenting: characterToDelete
        ) { character in
            Button("Cancel", role: .cancel) { characterToDelete = nil }
            Button("Delete", role: .destructive) {
                guard var updated = store.project(id: project.id) else { return }
                updated.removeCharacter(id: character.id)
                store.save(updated)
                store.removeManagedCharacterAssets(projectID: project.id, characterID: character.id)
                characterToDelete = nil
                onChanged()
            }
        } message: { character in
            Text("\(character.name) will be removed from Characters and from every shot. Existing takes are kept.")
        }
    }
}

private struct CharacterSummaryRow: View {
    let projectID: UUID
    let character: BibleCharacter
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(character.name.isEmpty ? "New Character" : character.name)
                    .font(.body.bold())
                let appearance = [character.appearance.hair, character.appearance.eyes]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: " · ")
                if !appearance.isEmpty {
                    Text(appearance).font(.caption).foregroundStyle(.secondary)
                }
                if !character.defaultCostume.isEmpty {
                    Text("Default costume: \(character.defaultCostume)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if character.referenceAssets.contains(where: { $0.type == .characterSheet }) {
                    Label(missingSheet ? "Character Sheet Missing" : "Character Sheet",
                          systemImage: missingSheet ? "exclamationmark.triangle" : "photo.on.rectangle")
                        .font(.caption2)
                        .foregroundStyle(missingSheet ? .orange : .secondary)
                }
                Text("ID \(character.id.uuidString.prefix(8))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Edit", action: onEdit).controlSize(.small)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var missingSheet: Bool {
        character.referenceAssets.filter { $0.type == .characterSheet }.contains { asset in
            guard let path = asset.projectRelativePath,
                  let url = FilmProjectStore.shared.managedCharacterAssetURL(
                    projectID: projectID, relativePath: path
                  ) else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }
}

private struct CharacterEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BibleCharacter
    @State private var aliasesText: String
    @State private var extractingFromSheet: CharacterReferenceAsset?
    @State private var assetToDelete: CharacterReferenceAsset?
    @State private var assetOperationError: String?
    let projectID: UUID
    let generationActive: Bool
    let onSave: (BibleCharacter) -> Void
    let onReferenceAssetsChanged: (UUID, [CharacterReferenceAsset]) throws -> Void

    init(
        projectID: UUID,
        generationActive: Bool,
        character: BibleCharacter,
        onSave: @escaping (BibleCharacter) -> Void,
        onReferenceAssetsChanged: @escaping (UUID, [CharacterReferenceAsset]) throws -> Void
    ) {
        self.projectID = projectID
        self.generationActive = generationActive
        _draft = State(initialValue: character)
        _aliasesText = State(initialValue: character.aliases.joined(separator: ", "))
        self.onSave = onSave
        self.onReferenceAssetsChanged = onReferenceAssetsChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.name.isEmpty ? "Add Character" : "Edit Character")
                .font(.headline)
            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.name)
                    TextField("Aliases (comma separated)", text: $aliasesText)
                    TextField("Role / Notes", text: $draft.roleNotes, axis: .vertical)
                }
                Section("Appearance") {
                    TextField("Face Description", text: $draft.appearance.faceDescription, axis: .vertical)
                    TextField("Hair", text: $draft.appearance.hair, axis: .vertical)
                    TextField("Eyes", text: $draft.appearance.eyes)
                    TextField("Age Impression", text: $draft.appearance.ageImpression)
                    TextField("Build", text: $draft.appearance.build)
                    TextField("Skin / Complexion", text: $draft.appearance.complexion)
                    TextField("Distinguishing Features", text: $draft.appearance.distinguishingFeatures, axis: .vertical)
                    TextField("General Appearance Notes", text: $draft.appearance.generalNotes, axis: .vertical)
                }
                Section("Character") {
                    TextField("Default Costume", text: $draft.defaultCostume, axis: .vertical)
                    TextField("Accessories", text: $draft.accessories, axis: .vertical)
                    TextField("Personality", text: $draft.personality, axis: .vertical)
                    TextField("Speaking Style", text: $draft.speakingStyle, axis: .vertical)
                    TextField("Continuity Notes", text: $draft.continuityNotes, axis: .vertical)
                }
                Section("Keep Consistent") {
                    HStack {
                        ForEach(CharacterTraitLock.allCases) { trait in
                            Toggle(trait.displayName, isOn: lockBinding(trait))
                                .toggleStyle(.checkbox)
                        }
                    }
                    Text("These settings guide storyboard continuity. They do not guarantee pixel-identical identity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Reference Images") {
                    if draft.referenceAssets.isEmpty {
                        Text("No managed reference images. Character Sheet analysis is optional; identity conditioning is not enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(draft.referenceAssets) { asset in
                        HStack(spacing: 10) {
                            ManagedCharacterReferenceThumbnail(projectID: projectID, asset: asset)
                                .frame(width: 64, height: 64)
                                .background(Color.black.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(asset.label.isEmpty ? asset.type.referenceDisplayName : asset.label)
                                    .font(.body.bold())
                                Text(asset.type.referenceDisplayName)
                                    .font(.caption).foregroundStyle(.secondary)
                                if let width = asset.pixelWidth, let height = asset.pixelHeight {
                                    Text("\(width)×\(height) · project-owned")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if asset.type == .characterSheet {
                                Button("Extract References") { extractingFromSheet = asset }
                                    .controlSize(.small)
                                    .disabled(generationActive || assetURL(asset) == nil)
                            }
                            Button(role: .destructive) { assetToDelete = asset } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("Reference images are local project assets. They are not currently used as an identity guarantee during video generation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.aliases = aliasesText.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    draft.updatedAt = Date()
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 650, height: 720)
        .interactiveDismissDisabled()
        .sheet(item: $extractingFromSheet) { sourceAsset in
            CharacterReferenceExtractionSheet(
                projectID: projectID,
                characterID: draft.id,
                sourceAsset: sourceAsset,
                generationActive: generationActive
            ) { assets in
                let updatedAssets = draft.referenceAssets + assets
                do {
                    try onReferenceAssetsChanged(draft.id, updatedAssets)
                    draft.referenceAssets = updatedAssets
                    draft.updatedAt = Date()
                } catch {
                    for asset in assets {
                        FilmProjectStore.shared.removeManagedCharacterAsset(projectID: projectID, asset: asset)
                    }
                    assetOperationError = "Reference images were not saved: \(error.localizedDescription)"
                }
                extractingFromSheet = nil
            }
        }
        .alert(
            "Delete Reference Image?",
            isPresented: Binding(
                get: { assetToDelete != nil },
                set: { if !$0 { assetToDelete = nil } }
            ),
            presenting: assetToDelete
        ) { asset in
            Button("Cancel", role: .cancel) { assetToDelete = nil }
            Button("Delete", role: .destructive) {
                let updatedAssets = draft.referenceAssets.filter { $0.id != asset.id }
                do {
                    try onReferenceAssetsChanged(draft.id, updatedAssets)
                    FilmProjectStore.shared.removeManagedCharacterAsset(projectID: projectID, asset: asset)
                    draft.referenceAssets = updatedAssets
                    draft.updatedAt = Date()
                } catch {
                    assetOperationError = "Reference image was not deleted: \(error.localizedDescription)"
                }
                assetToDelete = nil
            }
        } message: { asset in
            if asset.type == .characterSheet {
                Text("The project-owned Character Sheet will be deleted. Existing derived Reference Images are retained.")
            } else {
                Text("The project-owned derived image will be deleted. The original Character Sheet is retained.")
            }
        }
        .alert("Reference Images", isPresented: Binding(
            get: { assetOperationError != nil },
            set: { if !$0 { assetOperationError = nil } }
        )) {
            Button("OK", role: .cancel) { assetOperationError = nil }
        } message: {
            Text(assetOperationError ?? "")
        }
    }

    private func lockBinding(_ trait: CharacterTraitLock) -> Binding<Bool> {
        Binding(
            get: { draft.lockedTraits.contains(trait) },
            set: { enabled in
                if enabled { draft.lockedTraits.insert(trait) }
                else { draft.lockedTraits.remove(trait) }
            }
        )
    }

    private func assetURL(_ asset: CharacterReferenceAsset) -> URL? {
        guard let relativePath = asset.projectRelativePath,
              let url = FilmProjectStore.shared.managedCharacterAssetURL(
                projectID: projectID, relativePath: relativePath
              ), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

private struct CharacterSheetReviewSession: Identifiable {
    var id: UUID { asset.id }
    var projectID: UUID
    var characterID: UUID
    var currentCharacter: BibleCharacter?
    var asset: CharacterReferenceAsset
    var candidate: CharacterSheetAnalysisCandidate
    var previewData: Data?
    var analysisMessage: String?
}

/// One shared import surface for Storyboard and Auto Movie. The managed asset is
/// staged before analysis, but neither a new Character nor existing fields are
/// changed until the user presses Save in the review sheet.
private struct CharacterSheetImportButton: View {
    let projectID: UUID
    let characters: [BibleCharacter]
    let generationActive: Bool
    let onSave: (BibleCharacter) -> Void

    @State private var session: CharacterSheetReviewSession?
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @AppStorage(CharacterSheetAnalysisMode.userDefaultsKey)
    private var modeRaw = CharacterSheetAnalysisMode.auto.rawValue

    private let store = FilmProjectStore.shared

    var body: some View {
        Menu {
            Button("Create New Character…") { chooseSheet(for: nil) }
            if !characters.isEmpty {
                Divider()
                Section("Update Existing Character") {
                    ForEach(characters) { character in
                        Button(character.name) { chooseSheet(for: character) }
                    }
                }
            }
        } label: {
            if isPreparing {
                ProgressView().controlSize(.small)
                Text("Analyzing Character Sheet…")
            } else {
                Label("Import Character Sheet", systemImage: "photo.badge.plus")
            }
        }
        .controlSize(.small)
        .disabled(generationActive || isPreparing)
        .help(generationActive
              ? "Character Sheet analysis waits until video generation finishes."
              : "Copy a PNG or JPEG into this project, then review local analysis before saving.")
        .sheet(item: $session) { value in
            CharacterSheetReviewSheet(session: value) { saved in
                onSave(saved)
                session = nil
            } onCancel: {
                store.removeManagedCharacterAsset(projectID: value.projectID, asset: value.asset)
                session = nil
            }
        }
        .alert("Character Sheet Import", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func chooseSheet(for current: BibleCharacter?) {
        guard !generationActive else {
            errorMessage = CharacterSheetAnalysisError.generationInProgress.localizedDescription
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Character Sheet"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        let characterID = current?.id ?? UUID()
        let asset: CharacterReferenceAsset
        do {
            asset = try store.importCharacterSheet(
                from: sourceURL, projectID: projectID, characterID: characterID
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard let relativePath = asset.projectRelativePath,
              let managedURL = store.managedCharacterAssetURL(projectID: projectID, relativePath: relativePath) else {
            store.removeManagedCharacterAsset(projectID: projectID, asset: asset)
            errorMessage = FilmProjectStore.StoreError.invalidManagedAssetPath.localizedDescription
            return
        }

        var enrichedAsset = asset
        let size = CharacterSheetImagePreprocessor.pixelSize(of: managedURL)
        enrichedAsset.pixelWidth = size.width
        enrichedAsset.pixelHeight = size.height
        let previewData = try? CharacterSheetImagePreprocessor.analysisData(from: managedURL)
        isPreparing = true
        Task {
            let mode = CharacterSheetAnalysisMode(rawValue: modeRaw) ?? .auto
            let environment = CharacterSheetVisionEnvironmentService()
            let snapshot = await environment.refresh(mode: mode)
            var candidate = CharacterSheetAnalysisCandidate(
                sourceAssetID: enrichedAsset.id,
                provider: "manual",
                model: nil
            )
            var message: String?

            if generationActive {
                message = CharacterSheetAnalysisError.generationInProgress.localizedDescription
            } else if snapshot.effectiveMode == .localVision,
                      let model = snapshot.effectiveModel,
                      let previewData {
                let analyzer = CharacterSheetAnalyzer(
                    provider: OllamaCharacterSheetVisionProvider(model: model),
                    generationIsActive: { generationActive }
                )
                do {
                    candidate = try await analyzer.analyze(
                        imageData: previewData, sourceAssetID: enrichedAsset.id
                    )
                } catch {
                    message = error.localizedDescription
                }
            } else if previewData == nil {
                message = "The original sheet was saved, but local image preparation failed. Enter details manually."
            } else {
                message = "No compatible local Vision model is available. Enter details manually."
            }

            await MainActor.run {
                session = CharacterSheetReviewSession(
                    projectID: projectID,
                    characterID: characterID,
                    currentCharacter: current,
                    asset: enrichedAsset,
                    candidate: candidate,
                    previewData: previewData,
                    analysisMessage: message
                )
                isPreparing = false
            }
        }
    }
}

private struct CharacterSheetReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: CharacterSheetAnalysisCandidate
    @State private var selection: CharacterSheetFieldSelection
    @State private var viewsText: String
    @State private var expressionsText: String

    let session: CharacterSheetReviewSession
    let onSave: (BibleCharacter) -> Void
    let onCancel: () -> Void

    init(
        session: CharacterSheetReviewSession,
        onSave: @escaping (BibleCharacter) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.onSave = onSave
        self.onCancel = onCancel
        _candidate = State(initialValue: session.candidate)
        _selection = State(initialValue: .defaults(for: session.currentCharacter))
        _viewsText = State(initialValue: session.candidate.detectedViews.map(\.rawValue).joined(separator: ", "))
        _expressionsText = State(initialValue: session.candidate.expressions.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Character Sheet").font(.headline)
                    Text(candidate.provider == "manual" ? "Manual Entry" : "Local Analysis · Review required")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Vision output is a candidate, not saved truth.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = session.analysisMessage {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HSplitView {
                preview
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 400)
                Form {
                    Section("Extracted Character Data") {
                        reviewField("Name", value: $candidate.nameCandidate, apply: $selection.name,
                                    current: session.currentCharacter?.name)
                        reviewField("Face", value: $candidate.appearance.faceDescription, apply: $selection.face,
                                    current: session.currentCharacter?.appearance.faceDescription)
                        reviewField("Hair", value: $candidate.appearance.hair, apply: $selection.hair,
                                    current: session.currentCharacter?.appearance.hair)
                        reviewField("Eyes", value: $candidate.appearance.eyes, apply: $selection.eyes,
                                    current: session.currentCharacter?.appearance.eyes)
                        reviewField("Age Impression", value: $candidate.appearance.ageImpression,
                                    apply: $selection.ageImpression,
                                    current: session.currentCharacter?.appearance.ageImpression)
                        reviewField("Build", value: $candidate.appearance.build, apply: $selection.build,
                                    current: session.currentCharacter?.appearance.build)
                        reviewField("Complexion", value: $candidate.appearance.complexion,
                                    apply: $selection.complexion,
                                    current: session.currentCharacter?.appearance.complexion)
                        reviewField("Distinguishing Features",
                                    value: $candidate.appearance.distinguishingFeatures,
                                    apply: $selection.distinguishingFeatures,
                                    current: session.currentCharacter?.appearance.distinguishingFeatures)
                        reviewField("Default Costume", value: $candidate.defaultCostumeDescription,
                                    apply: $selection.costume,
                                    current: session.currentCharacter?.defaultCostume)
                        reviewField("Accessories", value: $candidate.accessories,
                                    apply: $selection.accessories,
                                    current: session.currentCharacter?.accessories)
                    }
                    Section("Sheet Contents") {
                        TextField("Detected Views", text: $viewsText)
                        TextField("Expressions", text: $expressionsText)
                        if !candidate.uncertainties.isEmpty {
                            Text("Uncertain: " + candidate.uncertainties.joined(separator: "; "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Continuity Guidance") {
                        Toggle("Apply suggestions", isOn: $selection.continuityNotes)
                        TextField(
                            "Continuity Notes",
                            text: Binding(
                                get: { candidate.continuitySuggestions.joined(separator: " ") },
                                set: { candidate.continuitySuggestions = $0.isEmpty ? [] : [$0] }
                            ),
                            axis: .vertical
                        )
                        Text("Personality, speaking style, and trait locks are not inferred or changed by image analysis.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 520)
            }
            HStack {
                Text("The original project-owned sheet is retained for future local workflows; it is not sent to LTX.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onCancel(); dismiss() }
                Button(session.currentCharacter == nil ? "Create Character" : "Apply Selected") {
                    candidate.detectedViews = commaValues(viewsText).map(DetectedCharacterView.init(rawValue:))
                    candidate.expressions = commaValues(expressionsText)
                    let saved = candidate.applying(
                        to: session.currentCharacter,
                        characterID: session.characterID,
                        asset: session.asset,
                        selection: selection
                    )
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(resolvedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 980, height: 760)
        .interactiveDismissDisabled()
    }

    private var preview: some View {
        VStack(spacing: 8) {
            if let data = session.previewData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Imported Character Sheet preview")
            } else {
                ContentUnavailableView("Preview Unavailable", systemImage: "photo")
            }
            Text(session.asset.originalFilename ?? "Character Sheet")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let width = session.asset.pixelWidth, let height = session.asset.pixelHeight {
                Text("Original: \(width)×\(height)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func reviewField(
        _ label: String,
        value: Binding<String>,
        apply: Binding<Bool>,
        current: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption.bold())
                Spacer()
                Toggle("Apply detected", isOn: apply).toggleStyle(.checkbox).controlSize(.small)
            }
            if let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Current: \(current)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            TextField("Detected", text: value, axis: .vertical)
        }
    }

    private var resolvedName: String {
        if selection.name { return candidate.nameCandidate.trimmingCharacters(in: .whitespacesAndNewlines) }
        return session.currentCharacter?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func commaValues(_ value: String) -> [String] {
        value.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Take row

private struct TakeRow: View {
    let project: FilmProject
    let shot: Shot
    let take: Take
    let isSelected: Bool
    let coordinator: TakeGenerationCoordinator
    let onChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                statusIcon
                Text("Seed \(take.seed)")
                    .font(.caption.monospaced())
                if let preset = take.preset.flatMap(GenerationPreset.init(rawValue:)) {
                    Text(preset.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let profile = take.effectiveProfileID {
                    Text("Effective \(profile)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let width = take.actualWidth, let height = take.actualHeight {
                    Text("\(width)×\(height)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let duration = take.actualDuration {
                    Text(String(format: "%.2fs", duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Requested \(take.requestedWidth)×\(take.requestedHeight)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(take.effectiveProfileReason ?? "No profile resolution reason recorded")
                if let target = take.targetDurationSeconds {
                    Text(String(format: "Target %.2fs", target))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let assetID = take.startingImageReferenceAssetID,
                   let (character, asset) = project.findReferenceAsset(id: assetID) {
                    Text("Starting Image: \(character.name) · \(asset.displayLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let path = take.sourceImagePath, !path.isEmpty {
                    Text("Starting Image: \(URL(fileURLWithPath: path).lastPathComponent)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if take.status == .completed {
                    Button("Play") {
                        if let path = take.outputPath {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    }
                    .controlSize(.small)
                    if isSelected {
                        Button("Selected ✓") {}
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(true)
                    } else {
                        Button("Select") {
                            try? coordinator.selectTake(projectID: project.id, shotID: shot.id, takeID: take.id)
                            onChanged()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text(take.status.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            diagnosticsDisclosure
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    @ViewBuilder
    private var diagnosticsDisclosure: some View {
        if take.generationSourceDiagnostics != nil || take.generationRuntimeDiagnostics != nil {
            DisclosureGroup(diagnosticsHeading) {
                VStack(alignment: .leading, spacing: 2) {
                    if let diagnostics = take.generationSourceDiagnostics {
                        Text("Source")
                            .fontWeight(.semibold)
                        Text("Mode: \(diagnostics.actualVideoMode.displayName)")
                        Text("Source: \(diagnostics.effectiveSource.displayName)")
                        if let filename = diagnostics.sourceFilename {
                            Text("Image: \(filename)")
                        }
                        if let takeID = diagnostics.continuitySourceTakeID {
                            let reason = diagnostics.continuityTakeSelectionReason?.displayName ?? "Recorded source take"
                            Text("Continuation: \(reason) · \(takeID.uuidString.prefix(8))")
                        }
                        if let origin = diagnostics.refreshAnchorOrigin {
                            Text("Refresh provenance: \(origin.displayName)")
                        }
                        if let preparation = diagnostics.imagePreparation {
                            Text("Image prep: \(preparation.originalWidth)×\(preparation.originalHeight) → \(preparation.effectiveWidth)×\(preparation.effectiveHeight) · \(preparation.mode.displayName)")
                        } else if diagnostics.actualVideoMode == .imageToVideo && isHistoricalTake {
                            Text("Image prep: not recorded")
                        }
                    }

                    if let runtime = take.generationRuntimeDiagnostics {
                        if take.generationSourceDiagnostics != nil {
                            Divider().padding(.vertical, 2)
                        }
                        Text("Runtime")
                            .fontWeight(.semibold)
                        Text("Status: \(runtime.status.displayName)")
                        if let elapsed = runtime.elapsedSeconds {
                            Text("Elapsed: \(formattedSeconds(elapsed))")
                        }
                        Text("Requested: \(resolution(runtime.requestedWidth, runtime.requestedHeight))")
                        if let width = runtime.effectiveWidth, let height = runtime.effectiveHeight {
                            Text("Effective: \(resolution(width, height))")
                        }
                        if let width = runtime.actualWidth, let height = runtime.actualHeight {
                            Text("Actual: \(resolution(width, height))")
                            if width != runtime.requestedWidth || height != runtime.requestedHeight {
                                Text("Actual output differs from requested resolution.")
                                    .foregroundStyle(.orange)
                            }
                        } else if runtime.status == .succeeded {
                            Text("Actual: unavailable")
                        }
                        if let videoFacts = runtimeVideoFacts(runtime) {
                            Text("Video: \(videoFacts)")
                        }
                        Text("Backend: \(runtime.backendResult.displayName)\(runtime.backendExitCode.map { " · exit \($0)" } ?? "")")
                        if let stage = runtime.failureStage {
                            Text("Failure: \(stage.displayName)")
                        }
                        if let summary = runtime.errorSummary, !summary.isEmpty {
                            Text("Error: \(summary)")
                        }
                        if let filename = runtime.outputFilename {
                            Text("Output: \(filename) · \(runtime.outputExists ? "present" : "missing")")
                        } else if runtime.status != .running {
                            Text("Output: not created")
                        }
                        if let readable = runtime.outputMetadataReadable {
                            Text("Metadata: \(readable ? "readable" : "unavailable")")
                        }
                    } else if isHistoricalTake {
                        if take.generationSourceDiagnostics != nil {
                            Divider().padding(.vertical, 2)
                        }
                        Text("Runtime diagnostics unavailable for this earlier Take.")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if isHistoricalTake {
            VStack(alignment: .leading, spacing: 1) {
                Text("Generation diagnostics unavailable for this earlier Take.")
                Text("Runtime diagnostics unavailable for this earlier Take.")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func resolution(_ width: Int, _ height: Int) -> String {
        "\(width)×\(height)"
    }

    private func formattedSeconds(_ seconds: Double) -> String {
        String(format: "%.2fs", seconds)
    }

    private func runtimeVideoFacts(_ runtime: GenerationRuntimeDiagnostics) -> String? {
        var parts: [String] = []
        if let duration = runtime.actualDurationSeconds {
            parts.append(formattedSeconds(duration))
        }
        if let fps = runtime.actualFPS {
            parts.append(String(format: "%.2f fps", fps))
        }
        if let frameCount = runtime.actualFrameCount {
            parts.append("\(frameCount) frames")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var diagnosticsHeading: String {
        isHistoricalTake ? "Recorded generation details" : "Queued source plan"
    }

    private var isHistoricalTake: Bool {
        switch take.status {
        case .completed, .failed, .cancelled, .interrupted, .generating:
            return true
        case .planned, .queued:
            return false
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch take.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .generating:
            ProgressView().controlSize(.mini)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.orange)
        case .interrupted, .planned:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}
