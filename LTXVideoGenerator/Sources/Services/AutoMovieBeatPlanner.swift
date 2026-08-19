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
///
/// The target total is then divided across shots by weight, not evenly: each
/// shot's visible action-beat count, resolved purpose, and the Director's own
/// per-shot duration (already on `shot.durationSeconds` when this runs) all
/// feed `allocationSignal(for:)`, so a shot with more to show or an explicit
/// longer intent draws a larger share of the total than a brief insert or
/// reaction does — while every shot still lands inside the backend's frame
/// range, and the sum still lands on the requested total exactly.
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

        // feasibleCount's derivation above guarantees
        // shots.count * minimumUnits <= targetUnits <= shots.count * maximumUnits,
        // so a weighted allocation that keeps every shot inside
        // minimumUnits...maximumUnits and still sums to targetUnits always exists.
        let signals = shots.map(allocationSignal(for:))
        let unitsPerShot = allocateUnits(
            weights: signals.map(\.weight), targetUnits: targetUnits,
            minimumUnits: minimumUnits, maximumUnits: maximumUnits)
        for index in shots.indices {
            let frameCount = min(maximumFrameCount, max(minimumFrameCount, unitsPerShot[index] * frameStride + 1))
            // Store the visual time span. PromptCompiler maps it back to the
            // exact 8n+1 frame count, while Plan Preview sums to the target.
            shots[index].durationSeconds = Double(frameCount - 1) / Double(fps)
            shots[index].actionBeatCount = signals[index].beatCount
            shots[index].index = index
        }
        return shots
    }

    /// How many seconds a shot's own content wants (`weight`, used only in
    /// relative proportion to other shots — its unit does not matter to the
    /// allocator), and the visible action-beat count behind that number, kept
    /// so Plan Preview and the validator can display the same figure this
    /// planner used rather than recomputing it.
    private static func allocationSignal(for shot: Shot) -> (weight: Double, beatCount: Int) {
        let beats = CapabilityAwareShotPlanner.visibleBeatCount(in: shot.summary)
        var baseline: Double
        switch beats {
        case ..<1: baseline = 4
        case 1: baseline = 5
        case 2: baseline = 6.5
        case 3: baseline = 8
        default: baseline = 9.5
        }

        // Purpose narrows the baseline toward this shot kind's natural
        // length: a detail insert or transition wants brevity even if its
        // text happens to read as multi-beat; a performance or dialogue
        // exchange wants room even at a single beat.
        switch shot.shotPurpose {
        case .detail: baseline = min(baseline, 3.5)
        case .transition: baseline = min(baseline, 4)
        case .reaction: baseline = min(baseline, 5)
        case .establish: baseline = min(baseline, 6)
        case .performance, .dialogue: baseline = max(baseline, 6)
        case .action, .reveal, nil: break
        }

        // The Director's own stated intent for this shot (already resolved
        // onto `durationSeconds` before this planner runs) is blended in
        // rather than substituted outright, so one unusual value cannot
        // dominate the shot's share on its own.
        if shot.durationSeconds.isFinite, shot.durationSeconds > 0 {
            baseline = (baseline + shot.durationSeconds) / 2
        }
        return (weight: min(10, max(3, baseline)), beatCount: beats)
    }

    /// Distributes `targetUnits` across shots in proportion to `weights`,
    /// while keeping every shot within `minimumUnits...maximumUnits`. Starts
    /// from each shot's floored ideal share, then closes the rounding gap by
    /// giving (or taking back) one unit at a time, largest fractional
    /// remainder first, exactly the classic largest-remainder method. The
    /// caller's feasibility invariant (see `normalize` above) guarantees a
    /// shot with room to absorb or give up a unit always exists while the
    /// gap is still open.
    private static func allocateUnits(
        weights: [Double],
        targetUnits: Int,
        minimumUnits: Int,
        maximumUnits: Int
    ) -> [Int] {
        let count = weights.count
        guard count > 0 else { return [] }
        guard count > 1 else {
            return [min(maximumUnits, max(minimumUnits, targetUnits))]
        }

        let totalWeight = weights.reduce(0, +)
        let normalizedWeights = totalWeight > 0 ? weights : [Double](repeating: 1, count: count)
        let normalizedTotal = normalizedWeights.reduce(0, +)

        let idealShares = normalizedWeights.map { Double(targetUnits) * $0 / normalizedTotal }
        var units = idealShares.map { min(maximumUnits, max(minimumUnits, Int($0.rounded(.down)))) }
        let ascendingByRemainder = idealShares.enumerated()
            .sorted { ($0.element - $0.element.rounded(.down)) < ($1.element - $1.element.rounded(.down)) }
            .map(\.offset)

        var deficit = targetUnits - units.reduce(0, +)
        if deficit > 0 {
            let order = Array(ascendingByRemainder.reversed())
            var cursor = 0
            while deficit > 0 {
                let index = order[cursor % count]
                if units[index] < maximumUnits { units[index] += 1; deficit -= 1 }
                cursor += 1
            }
        } else if deficit < 0 {
            var cursor = 0
            while deficit < 0 {
                let index = ascendingByRemainder[cursor % count]
                if units[index] > minimumUnits { units[index] -= 1; deficit += 1 }
                cursor += 1
            }
        }
        return units
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
