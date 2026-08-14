import Foundation

/// Reconciles the Director's continuity decisions with the deterministic scene
/// state it produced alongside them.
///
/// The Director owns the story: what happens, how it is framed, where the beats
/// fall. It does not reliably own the visual hand-off between shots — measured
/// sampling showed the local planner marking an entire continuous scene as cuts,
/// which meant nothing was inherited and every shot regenerated a different
/// looking person and set.
///
/// This pass only ever promotes a planned `cut` to a `continue`, and only where
/// the Director's own metadata proves the shot stays in the same place, at the
/// same time, with the same cast, inside one action chain. It never demotes a
/// planned continuation, never touches the first shot, and never overrules an
/// explicit scene, time or location change.
///
/// A change of framing is deliberately NOT a reason to keep a cut: inheriting at
/// the calibrated strength already leaves the camera free to move, so a wide
/// shot followed by a detail insert of the same moment is still a continuation.
enum ContinuityReconciler {

    /// Why a boundary was promoted, or why it was left alone. Recorded on the
    /// shot so a run can be explained after the fact.
    struct Decision: Equatable {
        var shotIndex: Int
        var planned: ShotContinuityMode
        var effective: ShotContinuityMode
        var reason: String

        var wasPromoted: Bool { planned != effective }
    }

    /// Directives that mean the story moved somewhere or somewhen else. Shared
    /// with the capability planner, which must not treat such a boundary as an
    /// inherited frame.
    static let sceneChangeDirectives = ["location=", "timeOfDay=", "weather="]

    /// Produces one decision per shot, in shot order.
    static func decisions(for shots: [Shot]) -> [Decision] {
        let ordered = shots.sorted { $0.index < $1.index }
        return ordered.enumerated().map { position, shot in
            let planned = shot.continuityMode ?? .auto
            // The first shot has nothing to inherit from, ever.
            guard position > 0 else {
                return Decision(shotIndex: shot.index, planned: planned,
                                effective: .cut, reason: "first shot has no previous shot")
            }
            // A planned continuation is respected as-is; this pass never demotes.
            guard planned == .cut else {
                return Decision(shotIndex: shot.index, planned: planned,
                                effective: planned, reason: "director decision kept")
            }
            let previous = ordered[position - 1]
            switch evaluate(previous: previous, current: shot) {
            case .promote(let reason):
                return Decision(shotIndex: shot.index, planned: planned,
                                effective: .continueFromPrevious, reason: reason)
            case .keepCut(let reason):
                return Decision(shotIndex: shot.index, planned: planned,
                                effective: .cut, reason: reason)
            }
        }
    }

    /// Applies the decisions, recording both the planned and effective mode so a
    /// promotion stays visible after the project is reloaded.
    static func reconcile(shots: [Shot]) -> [Shot] {
        let results = decisions(for: shots)
        var byIndex: [Int: Decision] = [:]
        for result in results { byIndex[result.shotIndex] = result }
        return shots.map { shot in
            guard let decision = byIndex[shot.index] else { return shot }
            var updated = shot
            updated.plannedContinuityMode = decision.planned
            updated.continuityMode = decision.effective
            updated.continuityReconciliationReason = decision.reason
            return updated
        }
    }

    // MARK: - Evidence

    private enum Outcome {
        case promote(String)
        case keepCut(String)
    }

    private static func evaluate(previous: Shot, current: Shot) -> Outcome {
        // 1. An explicit scene/time/location change is the Director saying the
        //    story moved. Never overrule it.
        if let directive = current.explicitChanges.first(where: { change in
            sceneChangeDirectives.contains { change.hasPrefix($0) }
        }) {
            return .keepCut("explicit scene change (\(directive))")
        }

        let before = previous.continuityBefore
        let now = current.continuityBefore

        // 2. Differing scene state means a different scene.
        if let a = before?.location, let b = now?.location,
           !a.isEmpty, !b.isEmpty, a != b {
            return .keepCut("location changed (\(a) → \(b))")
        }
        if let a = before?.timeOfDay, let b = now?.timeOfDay,
           !a.isEmpty, !b.isEmpty, a != b {
            return .keepCut("time changed (\(a) → \(b))")
        }
        if let a = before?.weather, let b = now?.weather,
           !a.isEmpty, !b.isEmpty, a != b {
            return .keepCut("weather changed (\(a) → \(b))")
        }

        // 3. A different cast is a different moment.
        let previousCast = cast(of: previous)
        let currentCast = cast(of: current)
        if !previousCast.isEmpty, !currentCast.isEmpty, previousCast != currentCast {
            return .keepCut("cast changed")
        }

        // 4. A story-state jump between two stated states is a new beat.
        if let a = before?.storyState, let b = now?.storyState,
           !a.isEmpty, !b.isEmpty, a != b {
            return .keepCut("story state jumped (\(a) → \(b))")
        }

        // 5. Crossing a threshold reads as a new scene even when the metadata
        //    still names one place, so an interior shot after an exterior one
        //    (or the reverse) keeps its cut.
        if let side = thresholdCrossing(previous: previous, current: current) {
            return .keepCut(side)
        }

        // 6. Positive evidence is required. Absence of metadata is not evidence
        //    of continuity, so an unproven boundary keeps its planned cut.
        let sameLocation = !(before?.location ?? "").isEmpty
            && before?.location == now?.location
        let sameCast = !previousCast.isEmpty && previousCast == currentCast
        guard sameLocation || sameCast else {
            return .keepCut("no positive evidence of the same scene")
        }
        guard sameLocation, sameCast else {
            // One signal alone is too weak: the same room with a different cast,
            // or the same cast somewhere unstated, is not proven continuous.
            return .keepCut(sameLocation
                ? "same location but cast is unconfirmed"
                : "same cast but location is unconfirmed")
        }

        var evidence = ["same cast", "same location"]
        if let time = now?.timeOfDay, !time.isEmpty { evidence.append("same time") }
        return .promote("continuous scene: " + evidence.joined(separator: ", "))
    }

    /// Characters the Director attributed to a shot. Stable Bible identifiers are
    /// preferred; when no Character Bible exists the planner's own continuity
    /// state still names its cast, which is structured data rather than a guess
    /// pulled out of prose.
    static func cast(of shot: Shot) -> Set<String> {
        if !shot.characterIDs.isEmpty {
            return Set(shot.characterIDs.map(\.uuidString))
        }
        guard let state = shot.continuityBefore else { return [] }
        var names = Set(state.characterOutfit.keys)
        names.formUnion(state.characterPosition.keys)
        names.formUnion(state.characterCondition.keys)
        return names
    }

    /// Detects an inside/outside transition from the shot text. Returns a reason
    /// when the two shots sit on opposite sides of a threshold.
    private static func thresholdCrossing(previous: Shot, current: Shot) -> String? {
        // What the shot depicts comes first. The recorded location is only a
        // fallback, because the case this rule exists for is a shot that has
        // moved indoors while the location string still names the old place.
        func side(_ shot: Shot) -> String? {
            SceneThreshold.side(of: shot.summary + " " + shot.title)
                ?? SceneThreshold.side(of: shot.continuityBefore?.location ?? "")
        }
        guard let a = side(previous), let b = side(current), a != b else { return nil }
        return "scene crosses from \(a) to \(b)"
    }
}

/// Which side of a doorway a piece of shot text describes.
///
/// Used only to BLOCK an assumption of continuity, never to justify one, so a
/// vocabulary miss is safe in both users: the reconciler keeps a planned cut,
/// and the capability planner leaves the framing alone.
enum SceneThreshold {

    private static let interiorMarkers = [
        "interior", "inside", "indoors", "within the", "hallway", "corridor",
    ]
    private static let exteriorMarkers = [
        "exterior", "outside", "outdoors", "courtyard", "street", "path",
        "facade", "rooftop",
    ]

    static func side(of text: String) -> String? {
        let lower = text.lowercased()
        let interior = interiorMarkers.contains { lower.contains($0) }
        let exterior = exteriorMarkers.contains { lower.contains($0) }
        if interior && !exterior { return "interior" }
        if exterior && !interior { return "exterior" }
        return nil
    }

    /// True when the two texts sit on opposite, identifiable sides.
    static func crosses(_ previousText: String, _ currentText: String) -> Bool {
        guard let a = side(of: previousText), let b = side(of: currentText) else { return false }
        return a != b
    }
}
