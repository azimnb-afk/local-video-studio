import SwiftUI

/// How the Opening Reference image compares with the Character Sheet.
///
/// Shown above Planned Shots so it is visible without scrolling — a false or
/// buried warning is as bad as no warning at all. Purely informational: it
/// never blocks generation and the Opening Reference remains the actual first
/// frame regardless of what this reports. Canonical identity is never
/// rewritten here; see `CharacterOpeningConsistencyResolver`.
struct CharacterOpeningConsistencySection: View {
    let project: FilmProject

    var body: some View {
        if let consistency = project.characterOpeningConsistency {
            VStack(alignment: .leading, spacing: 6) {
                Label(consistency.summary, systemImage: icon(for: consistency))
                    .font(.subheadline)
                    .foregroundStyle(color(for: consistency))
                let named = consistency.comparisons.filter { $0.verdict != .unknown }
                if !named.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(named, id: \.field) { comparison in
                            Text("\(comparison.field): \(comparison.verdict.rawValue.capitalized)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if consistency.isConflict {
                    Text("The character sheet stays the source of truth for the character. This image is still used as the first frame.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        }
    }

    private func icon(for c: CharacterOpeningConsistency) -> String {
        switch c.overallStatus {
        case .match: return "checkmark.circle"
        case .partial: return "questionmark.circle"
        case .conflict: return "exclamationmark.triangle"
        case .insufficientEvidence: return "info.circle"
        }
    }

    private func color(for c: CharacterOpeningConsistency) -> Color {
        switch c.overallStatus {
        case .match: return .green
        case .partial: return .secondary
        case .conflict: return .orange
        case .insufficientEvidence: return .secondary
        }
    }
}
