import Foundation

/// Deterministic cinematic progression for Auto Movie's no-LLM path.
///
/// When the Director returns a single shot, Auto Movie splits it into several
/// beats to reach the requested duration. That split used to reuse the brief
/// verbatim for every beat ("… — story beat 2 of 4"), so each shot described the
/// same action and the finished movie repeated one moment instead of telling a
/// story.
///
/// This planner has no story understanding and never invents plot. What it does
/// guarantee, without a language model, is that consecutive shots differ:
/// each beat states a distinct stage of the action, and the camera follows that
/// stage instead of cycling a fixed list.
///
/// Continuing beats are deliberately short. They render image-to-video from the
/// previous shot's final frame, so the scene, wardrobe and lighting already
/// arrive in the image — restating them would only fight the picture and inflate
/// the prompt.
enum AutoMovieBeatPlanner {

    /// Where a beat sits in the arc.
    enum Stage {
        case opening
        case development
        case resolution
    }

    static func stage(index: Int, count: Int) -> Stage {
        guard count > 1 else { return .opening }
        if index == 0 { return .opening }
        return index == count - 1 ? .resolution : .development
    }

    static func title(index: Int, count: Int) -> String {
        switch stage(index: index, count: count) {
        case .opening: return "Opening"
        case .development: return count > 3 ? "Development \(index)" : "Development"
        case .resolution: return "Resolution"
        }
    }

    /// The action text for a beat.
    ///
    /// The opening carries the brief because it is text-to-video and has no
    /// image to inherit. Later beats state how the action moves on, and say it
    /// in a way that works for any subject — a person reaching a door, a car
    /// being approached, someone standing up from a conversation.
    static func beatSummary(brief: String, index: Int, count: Int) -> String {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stage(index: index, count: count) {
        case .opening:
            return trimmed
        case .development:
            // Middle beats are numbered from 1 so successive prompts differ in
            // wording as well as in stage. Each phrase also leads with a
            // different word, so consecutive shots do not share an opening verb.
            let step = index
            let phrases = [
                "The subject moves on from the previous moment and closes in on what comes next.",
                "Movement continues and the subject presses further ahead.",
                "The moment builds toward its turning point.",
            ]
            return phrases[(step - 1) % phrases.count]
        case .resolution:
            return "The final moment arrives and the action completes."
        }
    }

    /// Shot scale per beat. The opening establishes, the middle stays with the
    /// subject, and the closing beat sits tighter on the resolving action.
    ///
    /// Split beats are one continuous action, so every beat after the first
    /// inherits a frame. The ladder is therefore held to the same maximum jump
    /// the capability planner allows an inheriting shot: a two-beat movie used
    /// to go straight from wide to close-up, which is exactly the reframe that
    /// measurement showed does not happen.
    static func shotScales(count: Int) -> [String] {
        guard count > 1 else { return ["medium"] }
        let intended = (0..<count).map { index -> String in
            switch stage(index: index, count: count) {
            case .opening: return "wide"
            case .development: return index % 2 == 1 ? "medium" : "medium-close-up"
            case .resolution: return "close-up"
            }
        }
        return clampToReachableSteps(intended)
    }

    /// Pulls each beat back to within one capability step of the beat before it.
    static func clampToReachableSteps(_ scales: [String]) -> [String] {
        let maxJump = CapabilityAwareShotPlanner.maxInheritedRankJump
        var result: [String] = []
        var previousRank: Int?
        for scale in scales {
            guard var rank = ShotScaleLadder.rank(of: scale) else {
                result.append(scale)
                previousRank = nil
                continue
            }
            if let previousRank {
                rank = min(max(rank, previousRank - maxJump), previousRank + maxJump)
            }
            result.append(ShotScaleLadder.name(atRank: rank))
            previousRank = rank
        }
        return result
    }

    /// Camera angle per beat. Varied so a longer movie does not hold one angle
    /// for three consecutive shots, which the monotony checker flags.
    static func cameraAngles(count: Int) -> [String] {
        guard count > 1 else { return ["eye-level"] }
        return (0..<count).map { index in
            switch stage(index: index, count: count) {
            case .opening, .resolution: return "eye-level"
            case .development: return index % 2 == 1 ? "low" : "high"
            }
        }
    }

    /// Camera movement per beat. Movement is chosen because it suits the beat,
    /// not to avoid stillness: a resolving moment is allowed to be static, which
    /// keeps deliberate stillness available rather than banned.
    static func cameraMovements(count: Int) -> [String] {
        guard count > 1 else { return ["static"] }
        return (0..<count).map { index in
            switch stage(index: index, count: count) {
            case .opening: return "slow push-in"
            case .development: return index % 2 == 1 ? "tracking" : "dolly"
            case .resolution: return "static"
            }
        }
    }
}

/// Makes Auto Movie's project-level duration target authoritative after either
/// Director protocol (or Basic fallback) has produced a valid plan.
///
/// The backend accepts 8n+1 frame counts from 25 through 241. Durations are
/// therefore allocated in deterministic 8-frame units, and stored on each Shot
/// before Plan Preview or GenerationRequest construction sees it. A Director
/// plan is left at its original shot count whenever that count can represent
/// the target; only an impossible count is merged or split.
enum AutoMovieDurationPlanner {
    static let minimumFrameCount = 25
    static let maximumFrameCount = 241
    private static let frameStride = 8

    static func normalize(
        shots input: [Shot],
        targetDurationSeconds: Double,
        fps requestedFPS: Int
    ) -> [Shot] {
        guard !input.isEmpty, targetDurationSeconds.isFinite, targetDurationSeconds > 0 else {
            return input
        }

        let fps = max(1, requestedFPS)
        let targetUnits = max(
            units(forFrameCount: minimumFrameCount),
            Int((targetDurationSeconds * Double(fps) / Double(frameStride)).rounded())
        )
        let minimumUnits = units(forFrameCount: minimumFrameCount)
        let maximumUnits = units(forFrameCount: maximumFrameCount)
        let minimumCount = min(12, max(1, divideRoundingUp(targetUnits, by: maximumUnits)))
        let maximumCount = min(12, max(1, targetUnits / minimumUnits))
        let feasibleCount = min(max(input.count, minimumCount), maximumCount)

        var shots: [Shot]
        if input.count > feasibleCount {
            shots = merge(input, toCount: feasibleCount)
        } else if input.count < feasibleCount {
            shots = split(input, toCount: feasibleCount)
        } else {
            shots = input
        }

        // The feasible-count calculation guarantees this even allocation stays
        // within the backend's 25...241 frame range.
        let baseUnits = targetUnits / shots.count
        let remainder = targetUnits % shots.count
        for index in shots.indices {
            let units = baseUnits + (index < remainder ? 1 : 0)
            let frameCount = min(maximumFrameCount, max(minimumFrameCount, units * frameStride + 1))
            // Store the visual time span. PromptCompiler maps it back to the
            // exact 8n+1 frame count, while Plan Preview sums to the target.
            shots[index].durationSeconds = Double(frameCount - 1) / Double(fps)
            shots[index].index = index
        }
        return shots
    }

    private static func units(forFrameCount frameCount: Int) -> Int {
        max(0, (frameCount - 1) / frameStride)
    }

    private static func divideRoundingUp(_ value: Int, by divisor: Int) -> Int {
        (value + divisor - 1) / divisor
    }

    /// Collapses contiguous groups, preserving every action in order rather
    /// than silently dropping middle story beats.
    private static func merge(_ input: [Shot], toCount count: Int) -> [Shot] {
        (0..<count).map { groupIndex in
            let lower = groupIndex * input.count / count
            let upper = (groupIndex + 1) * input.count / count
            let group = Array(input[lower..<upper])
            var shot = group[0]
            shot.id = UUID()
            if group.count > 1 {
                shot.title = group.first?.title ?? shot.title
                shot.summary = group.map(\.summary)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: " Then, ")
                shot.explicitChanges = unique(group.flatMap(\.explicitChanges))
                shot.characterIDs = unique(group.flatMap(\.characterIDs))
                shot.audio.dialogue = group.flatMap { $0.audio.dialogue }
                shot.audio.foley = unique(group.flatMap { $0.audio.foley })
                shot.audio.sfx = unique(group.flatMap { $0.audio.sfx })
            }
            resetGenerationState(&shot)
            return shot
        }
    }

    /// Splits only when the existing count cannot reach a long target without
    /// exceeding 241 frames. Each original beat remains present; extra pieces
    /// deterministically advance that beat and continue from its prior frame.
    private static func split(_ input: [Shot], toCount count: Int) -> [Shot] {
        let baseParts = count / input.count
        let remainder = count % input.count
        var result: [Shot] = []

        for (sourceIndex, source) in input.enumerated() {
            let partCount = baseParts + (sourceIndex < remainder ? 1 : 0)
            let scales = AutoMovieBeatPlanner.shotScales(count: partCount)
            let angles = AutoMovieBeatPlanner.cameraAngles(count: partCount)
            let movements = AutoMovieBeatPlanner.cameraMovements(count: partCount)
            var state = source.continuityBefore ?? ContinuitySnapshot()

            for partIndex in 0..<partCount {
                var shot = source
                shot.id = UUID()
                shot.title = partCount == 1
                    ? source.title
                    : "\(source.title) · \(AutoMovieBeatPlanner.title(index: partIndex, count: partCount))"
                shot.summary = partIndex == 0
                    ? source.summary
                    : AutoMovieBeatPlanner.beatSummary(
                        brief: source.summary, index: partIndex, count: partCount)
                shot.camera.shotScale = partIndex == 0 ? source.camera.shotScale : scales[partIndex]
                shot.camera.angle = partIndex == 0 ? source.camera.angle : angles[partIndex]
                shot.camera.movement = partIndex == 0 ? source.camera.movement : movements[partIndex]
                shot.continuityBefore = state
                shot.continuityMode = partIndex == 0 ? source.continuityMode : .continueFromPrevious
                shot.explicitChanges = partIndex == 0 ? source.explicitChanges : []
                if partIndex > 0 { shot.startingImageReferenceAssetID = nil }
                resetGenerationState(&shot)
                result.append(shot)

                if let next = try? ContinuityEngine.apply(changes: shot.explicitChanges, to: state) {
                    state = next
                }
            }
        }
        return result
    }

    private static func resetGenerationState(_ shot: inout Shot) {
        shot.takes = []
        shot.selectedTakeID = nil
        shot.plannedContinuityMode = nil
        shot.continuityReconciliationReason = nil
        shot.continuityImageRelativePath = nil
        shot.continuitySourceTakeID = nil
        shot.continuityBlockedReason = nil
        shot.identityRefreshAnchorRelativePath = nil
        shot.identityRefreshAnchorOrigin = nil
        shot.identityRefreshAnchorSourceShotID = nil
        shot.identityRefreshSourceTakeID = nil
        shot.identityRefreshNote = nil
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
