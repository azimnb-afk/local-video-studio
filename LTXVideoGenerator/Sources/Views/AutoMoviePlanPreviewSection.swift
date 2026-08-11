import SwiftUI

/// Shows the Director's plan before generation starts.
///
/// Deliberately read-only. The value is knowing what twenty minutes of
/// rendering is about to produce — shot order, rough length, framing and what
/// each shot starts from — not editing it here.
struct AutoMoviePlanPreviewSection: View {
    let project: FilmProject

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
                Text("What the Director planned. Durations are approximate — the plan describes beats, not exact frames.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(plan.rows, id: \.number) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: row.isGenerated
                              ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.caption)
                            .foregroundStyle(row.isGenerated ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Shot \(row.number)").font(.caption.bold())
                                Text(row.approximateDurationText)
                                    .font(.caption2).foregroundStyle(.secondary)
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
                            Text("\(row.continuityIntent) · \(row.sourceDescription)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if row.number != plan.rows.last?.number {
                        Divider()
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        }
    }
}
