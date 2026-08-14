import SwiftUI

/// Shows and lightly edits the Director's plan before generation starts.
///
/// Phase A edits Action and the existing `CameraPlan`. Phase B adds only the
/// existing Cut / Continue intent; its source remains a derived consequence of
/// the production continuity resolver, not a separately editable value.
struct AutoMoviePlanPreviewSection: View {
    let project: FilmProject
    let onChanged: () -> Void

    private let store = FilmProjectStore.shared
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
}

private struct AutoMoviePlanPreviewRow: View {
    let row: AutoMoviePlanPreview.Row
    let shot: Shot
    let onSave: (String, String, String, String) -> Void
    let onContinuityChange: (ShotContinuityMode) -> Void

    @State private var isEditing = false
    @State private var action: String
    @State private var shotScale: String
    @State private var angle: String
    @State private var movement: String

    init(
        row: AutoMoviePlanPreview.Row,
        shot: Shot,
        onSave: @escaping (String, String, String, String) -> Void,
        onContinuityChange: @escaping (ShotContinuityMode) -> Void
    ) {
        self.row = row
        self.shot = shot
        self.onSave = onSave
        self.onContinuityChange = onContinuityChange
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
            }
        }
    }

    private var continuityBinding: Binding<ShotContinuityMode> {
        Binding(
            get: { row.number == 1 ? .cut : (shot.continuityMode ?? .cut) },
            set: { onContinuityChange($0) }
        )
    }

    private func resetDraft() {
        action = shot.summary
        shotScale = shot.camera.shotScale
        angle = shot.camera.angle
        movement = shot.camera.movement
        isEditing = false
    }
}
