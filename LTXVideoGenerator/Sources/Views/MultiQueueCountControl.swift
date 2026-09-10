import SwiftUI

/// One source of truth for the multi-queue count control on all four generation
/// surfaces.
///
/// Generate, One Shot, Storyboard and Auto Movie ask the same question — how
/// many independent candidates should this submit create — so they share the
/// label, the choices, the validation and the accessibility text. Only the noun
/// differs: Generate and One Shot count generations, the film surfaces count
/// finished works.
enum MultiQueueCount {

    /// The unit the user is choosing a number of.
    enum Unit {
        /// Generate / One Shot — one render each.
        case generation
        /// Storyboard / Auto Movie — one whole work each, itself many shots.
        case work

        var label: String {
            switch self {
            case .generation: return "生成数"
            case .work: return "作品数"
            }
        }
    }

    /// The offered counts, shared so the surfaces cannot drift apart.
    ///
    /// These are Generate's existing choices with 1 and 2 added at the bottom:
    /// every surface needs to express "just one", and the film surfaces make 20
    /// works an unreasonable default to offer, so the ceiling is per-unit.
    static let generationChoices = [1, 2, 3, 5, 10, 20]
    static let workChoices = [1, 2, 3, 5]

    static func choices(for unit: Unit) -> [Int] {
        switch unit {
        case .generation: return generationChoices
        case .work: return workChoices
        }
    }

    /// Clamps a persisted or hand-edited value onto the offered set, so a
    /// preference written by an older build cannot select nothing.
    static func validated(_ count: Int, unit: Unit) -> Int {
        let options = choices(for: unit)
        guard let first = options.first else { return 1 }
        if options.contains(count) { return count }
        return options.last.map { count > $0 ? $0 : first } ?? first
    }

    /// Spoken by VoiceOver in place of a bare number.
    static func accessibilityLabel(count: Int, unit: Unit) -> String {
        switch unit {
        case .generation:
            return count > 1 ? "生成数 \(count) 本" : "生成数 1 本"
        case .work:
            return count > 1 ? "作品数 \(count) 本" : "作品数 1 本"
        }
    }

    /// The explanatory line under the control.
    static func summary(count: Int, unit: Unit, shotsPerWork: Int? = nil) -> String {
        switch unit {
        case .generation:
            return count > 1
                ? "同じ構成で \(count) 本を生成します（シードのみ変わります）。"
                : "1 本を生成します。"
        case .work:
            // Never present N works × M shots as a bare shot total: that hides
            // the grouping the user actually chose.
            guard let shots = shotsPerWork, shots > 0 else {
                return count > 1 ? "独立した \(count) 作品を生成します。" : "1 作品を生成します。"
            }
            return count > 1
                ? "独立した \(count) 作品 ／ 1作品 \(shots) Shot ／ 合計 \(count * shots) Shot生成"
                : "1 作品 ／ \(shots) Shot"
        }
    }
}

/// The shared control itself. Same behaviour and appearance everywhere; the
/// caller supplies only the unit and, for film surfaces, the shot count.
struct MultiQueueCountControl: View {
    let unit: MultiQueueCount.Unit
    @Binding var count: Int
    var shotsPerWork: Int?

    var body: some View {
        HStack(spacing: 12) {
            Picker(unit.label, selection: $count) {
                ForEach(MultiQueueCount.choices(for: unit), id: \.self) { choice in
                    Text("\(choice)").tag(choice)
                }
            }
            .frame(width: 160)
            .accessibilityLabel(MultiQueueCount.accessibilityLabel(count: count, unit: unit))
            Text(MultiQueueCount.summary(count: count, unit: unit, shotsPerWork: shotsPerWork))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .onAppear { count = MultiQueueCount.validated(count, unit: unit) }
    }
}
