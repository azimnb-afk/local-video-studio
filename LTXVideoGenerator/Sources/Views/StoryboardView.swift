import SwiftUI

private enum StoryboardWorkspaceMode {
    case storyboard
    case hybrid

    var title: String { self == .hybrid ? "Hybrid Projects" : "Storyboards" }
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
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
        .sheet(isPresented: $showNewProjectSheet) {
            NewStoryboardSheet(isCreating: $isCreating, mode: mode) { title, brief, settings, characterBible, generateFirstPass in
                createProject(
                    title: title,
                    brief: brief,
                    settings: settings,
                    characterBible: characterBible,
                    generateFirstPass: generateFirstPass
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
                .help(mode == .hybrid ? "Create a Hybrid project and generate its first pass" : "Create a storyboard from a short brief")
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
            Text(mode == .hybrid ? "Create and generate a first pass automatically" : "Create a storyboard from a short brief")
                .font(.title3)
            Text(mode == .hybrid
                 ? "The local director structures the story, splits it into short shots and queues one take per shot sequentially. Review, retake and assemble here."
                 : "The local director breaks your idea into 4–6 second shots with deterministic continuity. Generate takes per shot, pick the best, then assemble the final video.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
                .multilineTextAlignment(.center)
            Button(mode == .hybrid ? "New Hybrid Project…" : "New Storyboard…") { showNewProjectSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func completedShotCount(_ project: FilmProject) -> Int {
        project.shots.filter { $0.selectedTake?.status == .completed }.count
    }

    private func refresh() {
        projects = store.allProjects.filter { project in
            mode == .hybrid ? project.workflowMode == "hybrid" : project.workflowMode != "hybrid"
        }
    }

    private func createProject(
        title: String,
        brief: String,
        settings: ProjectSettings,
        characterBible: CharacterBible,
        generateFirstPass: Bool
    ) {
        isCreating = true
        statusMessage = "Planning storyboard…"
        Task {
            defer { isCreating = false }
            do {
                var (project, violations, _) = mode == .hybrid
                    ? try await HybridProjectCoordinator().makeProject(
                        title: title, brief: brief, settings: settings, characterBible: characterBible
                    )
                    : try await StoryboardDirector().makeProject(
                        title: title, brief: brief, settings: settings, characterBible: characterBible
                    )
                project.workflowMode = mode.workflowValue
                store.save(project)
                if mode == .hybrid, generateFirstPass {
                    let coordinator = TakeGenerationCoordinator(store: store, generationService: generationService)
                    for shot in project.shots {
                        _ = try coordinator.planTakes(projectID: project.id, shotID: shot.id, count: 1)
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
                showNewProjectSheet = false
            } catch {
                statusMessage = "Storyboard planning failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - New storyboard sheet

private struct NewStoryboardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isCreating: Bool
    let mode: StoryboardWorkspaceMode
    let onCreate: (String, String, ProjectSettings, CharacterBible, Bool) -> Void

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
    @AppStorage(DirectorMode.userDefaultsKey) private var directorModeRaw = DirectorMode.auto.rawValue
    @State private var directorSnapshot = DirectorSetupSnapshot.checking(mode: .auto)
    @State private var isCheckingDirector = false
    private let directorEnvironment = DirectorEnvironmentService()

    private var directorMode: DirectorMode {
        DirectorMode(rawValue: directorModeRaw) ?? .auto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .hybrid ? "New Hybrid Project" : "New Storyboard")
                .font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("Brief — what is this short film about?")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $brief)
                .font(.body)
                .frame(height: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            CharacterBibleDraftSection(bible: $characterBible)
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
            }
            if mode == .hybrid {
                Stepper("Target Duration: \(targetDuration, specifier: "%.0f")s", value: $targetDuration, in: 5...60, step: 5)
                Toggle("Generate first pass after planning", isOn: $generateFirstPass)
                    .help("Turn off to review the Character Bible, shot assignments and compiled prompts before rendering.")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("Director", selection: $directorModeRaw) {
                        Text("Auto").tag(DirectorMode.auto.rawValue)
                        Text("Local AI").tag(DirectorMode.localAI.rawValue)
                        Text("Basic").tag(DirectorMode.basic.rawValue)
                    }
                    .pickerStyle(.segmented)
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
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    var settings = ProjectSettings.usingCurrentSelections()
                    let preset = GenerationPreset(rawValue: presetRaw) ?? .standard
                    settings.applyPreset(preset)
                    settings.modelID = modelID
                    settings.audioEnabled = audioEnabled
                    settings.width = width
                    settings.height = height
                    settings.targetDurationSeconds = mode == .hybrid ? targetDuration : nil
                    onCreate(
                        title.isEmpty ? (mode == .hybrid ? "Untitled Hybrid Project" : "Untitled Storyboard") : title,
                        brief,
                        settings,
                        characterBible,
                        generateFirstPass
                    )
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .hybrid
                             ? (generateFirstPass ? "Create & Generate" : "Create Hybrid Project")
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
                }
                .font(.caption)
                .help("Planned by \(project.directorProvider ?? "local AI")")
            }
            ProjectSettingsEditor(project: project) {
                onChanged()
            }
            ProjectCharactersSection(project: project, onChanged: onChanged)
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
        }
    }

    private func generateMissingTakes() {
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
                    Text(resolutionSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
        .font(.headline)
    }

    private var resolutionSummary: String {
        let width = project.settings.width
        let height = project.settings.height
        let effectiveWidth = (width / 64) * 64
        let effectiveHeight = (height / 64) * 64
        return "Requested \(width)×\(height) → Effective \(effectiveWidth)×\(effectiveHeight) → Actual shown per completed Take"
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

// MARK: - Shot card

private struct ShotCard: View {
    let project: FilmProject
    let shot: Shot
    let coordinator: TakeGenerationCoordinator
    @Binding var statusMessage: String?
    let onChanged: () -> Void

    @State private var takeCount = 1
    @State private var showPrompt = false

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

            characterAssignment

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
}

// MARK: - Character Bible

private struct CharacterBibleDraftSection: View {
    @Binding var bible: CharacterBible
    @State private var isExpanded = true
    @State private var editingCharacter: BibleCharacter?

    var body: some View {
        DisclosureGroup("Characters", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Character Bible · used by Director and every assigned shot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(bible.characters) { character in
                    CharacterSummaryRow(character: character) {
                        editingCharacter = character
                    } onDelete: {
                        bible.characters.removeAll { $0.id == character.id }
                    }
                }
                Button {
                    editingCharacter = BibleCharacter(name: "", lockedTraits: [.face, .hair, .eyes])
                } label: {
                    Label("Add Character", systemImage: "person.badge.plus")
                }
                .controlSize(.small)
            }
            .padding(.top, 6)
        }
        .sheet(item: $editingCharacter) { character in
            CharacterEditorSheet(character: character) { saved in
                if let index = bible.characters.firstIndex(where: { $0.id == saved.id }) {
                    bible.characters[index] = saved
                } else {
                    bible.characters.append(saved)
                }
            }
        }
    }
}

private struct ProjectCharactersSection: View {
    let project: FilmProject
    let onChanged: () -> Void

    @State private var isExpanded = true
    @State private var editingCharacter: BibleCharacter?
    @State private var characterToDelete: BibleCharacter?
    private let store = FilmProjectStore.shared

    var body: some View {
        DisclosureGroup("Characters", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Character Bible · shared by Storyboard and Hybrid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if project.characterBible.characters.isEmpty {
                    Text("No characters yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(project.characterBible.characters) { character in
                    CharacterSummaryRow(character: character) {
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
            }
            .padding(.top, 6)
        }
        .sheet(item: $editingCharacter) { character in
            CharacterEditorSheet(character: character) { saved in
                guard var updated = store.project(id: project.id) else { return }
                updated.upsertCharacter(saved)
                store.save(updated)
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
                characterToDelete = nil
                onChanged()
            }
        } message: { character in
            Text("\(character.name) will be removed from Characters and from every shot. Existing takes are kept.")
        }
    }
}

private struct CharacterSummaryRow: View {
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
}

private struct CharacterEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BibleCharacter
    @State private var aliasesText: String
    let onSave: (BibleCharacter) -> Void

    init(character: BibleCharacter, onSave: @escaping (BibleCharacter) -> Void) {
        _draft = State(initialValue: character)
        _aliasesText = State(initialValue: character.aliases.joined(separator: ", "))
        self.onSave = onSave
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
                Section("Reference Assets") {
                    Text(draft.referenceAssets.isEmpty
                         ? "No managed reference assets. Image analysis and identity conditioning are not enabled."
                         : "\(draft.referenceAssets.count) managed reference asset metadata item(s).")
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
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
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
