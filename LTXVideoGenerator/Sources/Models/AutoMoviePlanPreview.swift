import Foundation

/// A readable summary of what the Director planned, before ~20 minutes of
/// generation are spent on it.
///
/// Derived from the plan already stored on the project. The accompanying
/// `AutoMoviePlanEditor` only changes the action and existing camera fields;
/// this remains intentionally not a timeline — there is no trimming,
/// reordering or frame-exact timing here, and durations stay approximate
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
                framing: sentenceCased(shot.camera.shotScale),
                cameraMovement: shot.camera.movement,
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

/// The one small editing boundary for Auto Movie's pre-generation plan review.
///
/// It deliberately edits the persisted `Shot` itself rather than carrying
/// preview-only overrides. `TakeGenerationCoordinator` reads `compiledPrompt`,
/// so the edited shot is immediately recompiled before it is saved. This keeps
/// the visible plan and the generation-facing request as the same source of
/// truth while leaving duration, ordering, continuity and source selection
/// untouched.
enum AutoMoviePlanEditor {

    /// Applies a user-reviewed Action and the existing CameraPlan components.
    /// Empty or whitespace-only fields are rejected so an incomplete inline
    /// edit can never turn into an unusable generation prompt.
    @discardableResult
    static func apply(
        project: inout FilmProject,
        shotID: UUID,
        action: String,
        shotScale: String,
        angle: String,
        movement: String
    ) -> Bool {
        let action = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let shotScale = shotScale.trimmingCharacters(in: .whitespacesAndNewlines)
        let angle = angle.trimmingCharacters(in: .whitespacesAndNewlines)
        let movement = movement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty, !shotScale.isEmpty, !angle.isEmpty, !movement.isEmpty,
              let index = project.shots.firstIndex(where: { $0.id == shotID })
        else { return false }

        var shot = project.shots[index]
        let unchanged = shot.summary == action
            && shot.camera.shotScale == shotScale
            && shot.camera.angle == angle
            && shot.camera.movement == movement
        guard !unchanged else { return false }

        // Only fields explicitly in Phase A change here. In particular, do
        // not touch `continuityMode`, inherited-frame metadata, takes, or any
        // source-image/identity state.
        shot.summary = action
        shot.camera.shotScale = shotScale
        shot.camera.angle = angle
        shot.camera.movement = movement
        project.shots[index] = shot
        CharacterPromptPipeline.recompilePlan(project: &project, shotIndex: index)
        project.touch()
        return true
    }
}
