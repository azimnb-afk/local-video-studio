import SwiftUI
import UniformTypeIdentifiers

/// Shows and lightly edits the Director's plan before generation starts.
///
/// Phase A edits Action and the existing `CameraPlan`. Phase B adds only the
/// existing Cut / Continue intent; its source remains a derived consequence of
/// the production continuity resolver, not a separately editable value.
/// Cut-Aware Continuity adds one more optional per-shot choice: an explicit
/// New Start Frame a Cut shot starts from instead of the previous shot's
/// final frame.
struct AutoMoviePlanPreviewSection: View {
    let project: FilmProject
    let onChanged: () -> Void

    private let store = FilmProjectStore.shared
    @State private var newStartFrameError: String?
    private var preview: AutoMoviePlanPreview { AutoMoviePlanPreview.make(project: project) }

    var body: some View {
        let plan = preview
        if !plan.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "list.number").foregroundStyle(.secondary)
                    Text("Planned Shots").font(.headline)
                    Text(plan.totalDurationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if plan.hasAnyGenerated {
                        Text("\(plan.generatedCount) of \(plan.rows.count) generated")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Review Action, Camera, and Cut / Continue before generation. Durations and sources stay derived from the plan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let newStartFrameError {
                    Text(newStartFrameError).font(.caption2).foregroundStyle(.red)
                }

                ForEach(project.shots.indices, id: \.self) { index in
                    AutoMoviePlanPreviewRow(
                        row: plan.rows[index], shot: project.shots[index],
                        onSave: { action, shotScale, angle, movement in
                            saveEdit(
                                shotID: project.shots[index].id,
                                action: action,
                                shotScale: shotScale,
                                angle: angle,
                                movement: movement)
                        },
                        onContinuityChange: { mode in
                            saveContinuityEdit(
                                shotID: project.shots[index].id,
                                mode: mode)
                        },
                        onChooseNewStartFrame: { url in
                            chooseNewStartFrame(shotID: project.shots[index].id, sourceURL: url)
                        },
                        onClearNewStartFrame: {
                            clearNewStartFrame(shotID: project.shots[index].id)
                        }
                    )
                    if index != project.shots.indices.last {
                        Divider()
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        }
    }

    private func saveEdit(
        shotID: UUID,
        action: String,
        shotScale: String,
        angle: String,
        movement: String
    ) {
        guard var fresh = store.project(id: project.id) else { return }
        if AutoMoviePlanEditor.apply(
            project: &fresh, shotID: shotID, action: action,
            shotScale: shotScale, angle: angle, movement: movement
        ) {
            store.save(fresh)
            onChanged()
        }
    }

    private func saveContinuityEdit(shotID: UUID, mode: ShotContinuityMode) {
        guard var fresh = store.project(id: project.id) else { return }
        if AutoMoviePlanEditor.applyContinuityMode(
            project: &fresh, shotID: shotID, mode: mode
        ) {
            store.save(fresh)
            onChanged()
        }
    }

    /// Imports the chosen image as this shot's New Start Frame. Mirrors
    /// `OpeningReferenceSection.choose()`: replacing removes the copy it
    /// supersedes so the project does not accumulate orphaned stills, and the
    /// user's original file is never moved or modified.
    private func chooseNewStartFrame(shotID: UUID, sourceURL: URL) {
        newStartFrameError = nil
        guard var fresh = store.project(id: project.id),
              let index = fresh.shots.firstIndex(where: { $0.id == shotID }) else { return }
        do {
            let relativePath = try store.importNewStartFrame(
                from: sourceURL, projectID: project.id, shotID: shotID)
            if let previous = fresh.shots[index].newStartFrameRelativePath {
                if let previousURL = store.managedProjectAssetURL(
                    projectID: project.id, relativePath: previous) {
                    ImageConditioningPreparer.shared.invalidate(sourceURL: previousURL)
                }
                store.removeManagedNewStartFrame(projectID: project.id, relativePath: previous)
            }
            fresh.shots[index].newStartFrameRelativePath = relativePath
            fresh.touch()
            store.save(fresh)
            onChanged()
        } catch {
            newStartFrameError = (error as? LocalizedError)?.errorDescription
                ?? "Could not import that image."
        }
    }

    private func clearNewStartFrame(shotID: UUID) {
        newStartFrameError = nil
        guard var fresh = store.project(id: project.id),
              let index = fresh.shots.firstIndex(where: { $0.id == shotID }),
              let existing = fresh.shots[index].newStartFrameRelativePath else { return }
        if let existingURL = store.managedProjectAssetURL(
            projectID: project.id, relativePath: existing) {
            ImageConditioningPreparer.shared.invalidate(sourceURL: existingURL)
        }
        store.removeManagedNewStartFrame(projectID: project.id, relativePath: existing)
        fresh.shots[index].newStartFrameRelativePath = nil
        fresh.touch()
        store.save(fresh)
        onChanged()
    }
}

private struct AutoMoviePlanPreviewRow: View {
    let row: AutoMoviePlanPreview.Row
    let shot: Shot
    let onSave: (String, String, String, String) -> Void
    let onContinuityChange: (ShotContinuityMode) -> Void
    let onChooseNewStartFrame: (URL) -> Void
    let onClearNewStartFrame: () -> Void

    @State private var isEditing = false
    @State private var action: String
    @State private var shotScale: String
    @State private var angle: String
    @State private var movement: String

    init(
        row: AutoMoviePlanPreview.Row,
        shot: Shot,
        onSave: @escaping (String, String, String, String) -> Void,
        onContinuityChange: @escaping (ShotContinuityMode) -> Void,
        onChooseNewStartFrame: @escaping (URL) -> Void,
        onClearNewStartFrame: @escaping () -> Void
    ) {
        self.row = row
        self.shot = shot
        self.onSave = onSave
        self.onContinuityChange = onContinuityChange
        self.onChooseNewStartFrame = onChooseNewStartFrame
        self.onClearNewStartFrame = onClearNewStartFrame
        _action = State(initialValue: shot.summary)
        _shotScale = State(initialValue: shot.camera.shotScale)
        _angle = State(initialValue: shot.camera.angle)
        _movement = State(initialValue: shot.camera.movement)
    }

    private var isValid: Bool {
        [action, shotScale, angle, movement].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.isGenerated ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption)
                .foregroundStyle(row.isGenerated ? .green : .secondary)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Shot \(row.number)").font(.caption.bold())
                    Text(row.approximateDurationText)
                        .font(.caption2).foregroundStyle(.secondary)
                    if !row.purposeLabel.isEmpty {
                        Text(row.purposeLabel)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isEditing ? "Cancel" : "Edit") {
                        if isEditing {
                            resetDraft()
                        } else {
                            isEditing = true
                        }
                    }
                    .controlSize(.small)
                }

                if isEditing {
                    Text("Action").font(.caption.bold())
                    TextEditor(text: $action)
                        .font(.caption)
                        .frame(minHeight: 46, maxHeight: 70)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                    Text("Camera / Framing").font(.caption.bold())
                    HStack(spacing: 6) {
                        TextField("Framing", text: $shotScale)
                        TextField("Angle", text: $angle)
                        TextField("Movement", text: $movement)
                    }
                    .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Continuity changes apply to future takes; its source is resolved automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save") {
                            onSave(action, shotScale, angle, movement)
                            isEditing = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isValid)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(row.framing)
                            .font(.caption2).foregroundStyle(.secondary)
                        if !row.cameraMovement.isEmpty {
                            Text(row.cameraMovement)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(row.action)
                        .font(.caption)
                        .lineLimit(2)
                    if !row.endStateText.isEmpty {
                        Text("Ends: \(row.endStateText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if row.isGenerated {
                        Text("Edits apply to future takes; existing takes are unchanged.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Picker("Continuity", selection: continuityBinding) {
                        Text("Cut").tag(ShotContinuityMode.cut)
                        Text("Continue").tag(ShotContinuityMode.continueFromPrevious)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 150)
                    .disabled(row.number == 1)
                    .help(row.number == 1
                          ? "Shot 1 is always a Cut because there is no previous shot."
                          : "Choose whether this shot inherits the previous shot's last frame.")
                    Text("· \(row.sourceDescription)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if row.number > 1, continuityBinding.wrappedValue == .cut {
                    HStack(spacing: 6) {
                        Button(shot.newStartFrameRelativePath == nil ? "New Start Frame [Choose Image]" : "New Start Frame [Replace]") {
                            chooseNewStartFrame()
                        }
                        .controlSize(.small)
                        if shot.newStartFrameRelativePath != nil {
                            Label("Set", systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Button("Clear", role: .destructive) { onClearNewStartFrame() }
                                .controlSize(.small)
                        }
                    }
                    Text(shot.newStartFrameRelativePath == nil
                         ? "No New Start Frame: this Cut re-anchors from the Character Anchor if set, otherwise starts from text only — never the previous shot's frame."
                         : "This Cut starts from the image above, not the previous shot's frame.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var continuityBinding: Binding<ShotContinuityMode> {
        Binding(
            get: { row.number == 1 ? .cut : (shot.continuityMode ?? .cut) },
            set: { onContinuityChange($0) }
        )
    }

    private func chooseNewStartFrame() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChooseNewStartFrame(url)
    }

    private func resetDraft() {
        action = shot.summary
        shotScale = shot.camera.shotScale
        angle = shot.camera.angle
        movement = shot.camera.movement
        isEditing = false
    }
}
