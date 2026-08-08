import SwiftUI

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
            NewStoryboardSheet(isCreating: $isCreating) { title, brief in
                createProject(title: title, brief: brief)
            }
        }
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Storyboards")
                    .font(.headline)
                Spacer()
                Button {
                    showNewProjectSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Create a storyboard from a short brief")
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
            Text("Create a storyboard from a short brief")
                .font(.title3)
            Text("The local director breaks your idea into 4–6 second shots with deterministic continuity. Generate takes per shot, pick the best, then assemble the final video.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
                .multilineTextAlignment(.center)
            Button("New Storyboard…") { showNewProjectSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func completedShotCount(_ project: FilmProject) -> Int {
        project.shots.filter { $0.selectedTake?.status == .completed }.count
    }

    private func refresh() {
        projects = store.allProjects
    }

    private func createProject(title: String, brief: String) {
        isCreating = true
        statusMessage = "Planning storyboard…"
        Task {
            defer { isCreating = false }
            do {
                var settings = ProjectSettings()
                settings.modelID = LTXModelCatalog.selectedModel().id
                let (project, violations, providerName) = try await StoryboardDirector()
                    .makeProject(title: title, brief: brief, settings: settings)
                store.save(project)
                selectedProjectID = project.id
                refresh()
                let warnings = violations.filter { $0.severity == .warning }.count
                let errors = violations.filter { $0.severity == .error }.count
                statusMessage = "Planned \(project.shots.count) shots via \(providerName)"
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
    let onCreate: (String, String) -> Void

    @State private var title = ""
    @State private var brief = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Storyboard")
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
            Text("Planning is local-only: Ollama on localhost when available, otherwise a deterministic single-shot template. Any local LLM is unloaded before rendering.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    onCreate(title.isEmpty ? "Untitled Storyboard" : title, brief)
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create Storyboard")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
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

// MARK: - Shot card

private struct ShotCard: View {
    let project: FilmProject
    let shot: Shot
    let coordinator: TakeGenerationCoordinator
    @Binding var statusMessage: String?
    let onChanged: () -> Void

    @State private var takeCount = 3
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
                        Label("Retake", systemImage: "arrow.clockwise")
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
        case .interrupted, .planned:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}
