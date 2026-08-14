import Foundation

/// The shot-scale vocabulary the Director is asked to use, ordered coarse to
/// tight.
///
/// Two separate passes need to reason about how far apart two framings are —
/// `ContinuityStrengthResolver` to decide how hard an inherited frame should
/// hold, and `CapabilityAwareShotPlanner` to decide whether a framing change is
/// worth attempting at all. They must agree on what "three rungs apart" means,
/// so the ladder and its ranking live here and neither owns a copy.
enum ShotScaleLadder {

    static let scales: [String] = [
        "extreme-wide",
        "wide",
        "medium-wide",
        "medium",
        "medium-close-up",
        "close-up",
        "extreme-close-up",
    ]

    static var widestRank: Int { 0 }
    static var tightestRank: Int { scales.count - 1 }

    /// Rank on the ladder, or nil when the term is not recognised.
    static func rank(of scale: String) -> Int? {
        let normalized = scale
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "closeup", with: "close-up")
            .replacingOccurrences(of: "-shot", with: "")
        if let exact = scales.firstIndex(of: normalized) { return exact }
        // Tolerate unseen spellings by matching the longest known term the value
        // contains, so "extreme-close-up-insert" still ranks as a detail.
        let matches = scales.enumerated()
            .filter { normalized.contains($0.element) }
            .max { $0.element.count < $1.element.count }
        return matches?.offset
    }

    /// Canonical name for a rank, clamped to the ladder.
    static func name(atRank rank: Int) -> String {
        scales[min(max(rank, widestRank), tightestRank)]
    }
}
