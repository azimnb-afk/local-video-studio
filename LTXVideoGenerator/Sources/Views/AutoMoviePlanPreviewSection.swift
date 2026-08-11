import SwiftUI

/// Shows and lightly edits the Director's plan before generation starts.
///
/// Phase A intentionally limits editing to Action and the fields already in
/// `CameraPlan`. Cut/Continue and its source remain a readable consequence of
/// the saved plan, not an editable timeline control.
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
                Text("Review or adjust Action and Camera before generation. Durations, Cut / Continue, and sources stay unchanged.")
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
}

private struct AutoMoviePlanPreviewRow: View {
    let row: AutoMoviePlanPreview.Row
    let shot: Shot
    let onSave: (String, String, String, String) -> Void

    @State private var isEditing = false
    @State private var action: String
    @State private var shotScale: String
    @State private var angle: String
    @State private var movement: String

    init(
        row: AutoMoviePlanPreview.Row,
        shot: Shot,
        onSave: @escaping (String, String, String, String) -> Void
    ) {
        self.row = row
        self.shot = shot
        self.onSave = onSave
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
                        Text("Cut / Continue and source are read-only in this phase.")
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
                Text("\(row.continuityIntent) · \(row.sourceDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetDraft() {
        action = shot.summary
        shotScale = shot.camera.shotScale
        angle = shot.camera.angle
        movement = shot.camera.movement
        isEditing = false
    }
}
