import Foundation

/// Chooses how strongly an inherited frame should constrain the next shot.
///
/// This is a separate question from whether the visual state is inherited at
/// all. `ContinuityReconciler` decides *should the previous look carry over*;
/// this decides *how hard should it hold*. Camera differences are read here and
/// never fed back into the cut/continue decision.
///
/// Two policies, deliberately:
/// - `standard` for an ordinary continuation, at the calibrated 0.8 that keeps
///   the person, wardrobe, place and light.
/// - `reframe` for a large framing jump such as a full-figure shot followed by a
///   detail insert, where 0.8 held the old composition so firmly that the
///   planned close-up never happened.
enum ContinuityStrengthPolicy: String, Equatable {
    case standard
    case reframe

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .reframe: return "Reframe"
        }
    }
}

enum ContinuityStrengthResolver {

    /// Ordered coarse-to-tight, matching the shot-scale vocabulary the Director
    /// is asked to use. Rank distance between two shots is what "how big is this
    /// reframe" means.
    private static let scaleLadder: [String] = [
        "extreme-wide",
        "wide",
        "medium-wide",
        "medium",
        "medium-close-up",
        "close-up",
        "extreme-close-up",
    ]

    /// A jump of this many rungs or more is treated as a reframe. A wide shot
    /// followed by a close-up (wide → close-up is 4) qualifies; the gentler
    /// steps a scene normally takes do not.
    static let reframeRankDistance = 3

    /// Words that mark a shot as an insert on a detail rather than on a person.
    /// Used only as a fallback signal when the scale ladder alone is unclear.
    private static let detailMarkers = [
        "insert", "detail", "extreme close", "macro",
        "close-up of", "closeup of", "close up of",
    ]

    /// Rank on the ladder, or nil when the term is not recognised.
    static func rank(ofScale scale: String) -> Int? {
        let normalized = scale
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "closeup", with: "close-up")
            .replacingOccurrences(of: "-shot", with: "")
        if let exact = scaleLadder.firstIndex(of: normalized) { return exact }
        // Tolerate unseen spellings by matching the longest known term the value
        // contains, so "extreme-close-up-insert" still ranks as a detail.
        let matches = scaleLadder.enumerated()
            .filter { normalized.contains($0.element) }
            .max { $0.element.count < $1.element.count }
        return matches?.offset
    }

    /// Decides the policy for a continuation from `previous` to `current`.
    ///
    /// Only the framing intent is consulted. Angle and camera movement are
    /// deliberately ignored: swapping a dolly for a static camera, or an
    /// eye-level for a low angle, does not change how much of the subject fills
    /// the frame, so it is no reason to loosen the anchor.
    static func policy(previous: Shot, current: Shot) -> ContinuityStrengthPolicy {
        let previousRank = rank(ofScale: previous.camera.shotScale)
        let currentRank = rank(ofScale: current.camera.shotScale)

        if let a = previousRank, let b = currentRank {
            if b - a >= reframeRankDistance { return .reframe }
            // Pulling far back out of a tight shot is the same size of change.
            if a - b >= reframeRankDistance { return .reframe }
            // A recognised, modest step keeps the standard anchor even when the
            // shot text mentions a detail.
            return .standard
        }

        // Unrecognised vocabulary: fall back to what the shot says it shows.
        if isDetailInsert(current), !isDetailInsert(previous) { return .reframe }
        return .standard
    }

    /// True when the shot is framed on an object or body detail.
    static func isDetailInsert(_ shot: Shot) -> Bool {
        if let rank = rank(ofScale: shot.camera.shotScale),
           rank >= scaleLadder.count - 1 {
            return true
        }
        let text = (shot.camera.composition + " " + shot.summary + " " + shot.title).lowercased()
        return detailMarkers.contains { text.contains($0) }
    }

    /// Effective strength for an inherited continuity frame.
    static func strength(for policy: ContinuityStrengthPolicy) -> Double {
        switch policy {
        case .standard: return AutoMovieRunCoordinator.continuityImageStrength
        case .reframe: return AutoMovieRunCoordinator.reframeContinuityImageStrength
        }
    }

    /// Human-readable explanation for logs and persisted diagnostics.
    static func explanation(previous: Shot, current: Shot, policy: ContinuityStrengthPolicy) -> String {
        let from = previous.camera.shotScale
        let to = current.camera.shotScale
        switch policy {
        case .standard:
            return "Standard continuity (\(from) → \(to))"
        case .reframe:
            return "Reframe continuity (\(from) → \(to))"
        }
    }
}
