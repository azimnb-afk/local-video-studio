import Foundation

/// A readable summary of what the Director planned, before ~20 minutes of
/// generation are spent on it.
///
/// Read-only and derived: it reports the plan already stored on the project and
/// owns no state of its own. Not a timeline — there is no trimming, reordering
/// or frame-exact timing here, and the durations are deliberately approximate
/// because the Director plans in beats, not frames.
struct AutoMoviePlanPreview: Equatable {

    struct Row: Equatable {
        var number: Int
        var approximateSeconds: Double
        var action: String
        var framing: String
        var cameraMovement: String
        /// What this shot will start from, in the user's words.
        var sourceDescription: String
        /// Continue vs cut, as planned.
        var continuityIntent: String
        /// True once this shot has a completed take, so the preview can say
        /// what is already done rather than implying everything is pending.
        var isGenerated: Bool

        /// "~5 sec" — never a frame-exact claim.
        var approximateDurationText: String {
            "~\(Int(approximateSeconds.rounded())) sec"
        }
    }

    var rows: [Row] = []

    var totalApproximateSeconds: Double { rows.reduce(0) { $0 + $1.approximateSeconds } }

    /// "Approx. 20 sec total" — wording chosen to avoid implying exactness.
    var totalDurationText: String {
        "Approx. \(Int(totalApproximateSeconds.rounded())) sec total"
    }

    var isEmpty: Bool { rows.isEmpty }
    var generatedCount: Int { rows.filter(\.isGenerated).count }
    var hasAnyGenerated: Bool { generatedCount > 0 }

    /// Builds the preview from a project's plan.
    ///
    /// The source column reuses `LTXContinuityResolver`, so the preview cannot
    /// disagree with what generation will actually do.
    static func make(project: FilmProject) -> AutoMoviePlanPreview {
        let hasOpeningReference = project.openingReferenceImage != nil
        let hasCharacterAnchor = project.characterAnchor.isActive
        var preview = AutoMoviePlanPreview()
        preview.rows = project.shots.enumerated().map { index, shot in
            let resolution = LTXContinuityResolver.resolve(
                shot: shot, shotIndex: index,
                hasOpeningReference: hasOpeningReference,
                hasCharacterAnchor: hasCharacterAnchor)
            // Before anything is generated a later shot has no inherited frame
            // yet, so the resolver correctly reports none. Say what it *will*
            // continue from instead of showing a misleading "text to video".
            let source: String
            if resolution.source == .none, index > 0,
               shot.continuityMode != .cut, shot.startingImageReferenceAssetID == nil {
                source = "Previous shot's last frame"
            } else {
                source = resolution.source.displayName
            }
            return Row(
                number: index + 1,
                approximateSeconds: shot.durationSeconds,
                action: shot.summary.isEmpty ? shot.title : shot.summary,
                framing: sentenceCased(shot.camera.shotScale ?? "medium"),
                cameraMovement: shot.camera.movement ?? "",
                sourceDescription: source,
                continuityIntent: (shot.continuityMode ?? .auto).displayName,
                isGenerated: shot.takes.contains { $0.status == .completed }
            )
        }
        return preview
    }

    /// "close-up" → "Close-up". `capitalized` would give "Close-Up", which
    /// reads like a proper noun.
    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
