import Foundation

/// Decides whether a shot needs a fresh identity-bearing starting image instead
/// of the frame it would normally inherit.
///
/// Two independent questions, kept separate so each can be tested on its own:
///
///   A. does the *next shot* need identity detail?   (from its camera plan)
///   B. does the *current source frame* contain it?  (from vision assessment)
///
/// Refresh only when A is yes and B is no. Measured evidence says a large
/// camera change is not itself the problem — an identity-bearing source
/// survives a wide-to-close reframe intact (D-072) — so triggering on framing
/// alone would burn a generation on shots that were never going to fail.
///
/// The default is always normal continuity. This is a surgical repair, not a
/// replacement for the continuity chain.
enum IdentityRefreshPolicy {

    enum Decision: Equatable {
        case useNormalContinuity(reason: String)
        case refresh(reason: String)

        var isRefresh: Bool { if case .refresh = self { return true }; return false }
    }

    /// - Parameters:
    ///   - requirement: what the next shot needs, from its shot scale.
    ///   - assessment: what the inherited frame shows, or nil if none was run.
    ///   - hasExplicitStartingImage: the user picked an image for this shot.
    static func decide(
        requirement: IdentityDetailRequirement,
        assessment: IdentitySourceAssessment?,
        hasExplicitStartingImage: Bool
    ) -> Decision {
        // The user's own choice for this shot is never overridden.
        if hasExplicitStartingImage {
            return .useNormalContinuity(reason: "This shot already has a starting image you chose.")
        }
        guard IdentityRefreshThresholds.requirementsNeedingFace.contains(requirement) else {
            return .useNormalContinuity(
                reason: "This shot's framing does not depend on facial detail.")
        }
        guard let assessment else {
            return .useNormalContinuity(
                reason: "The inherited frame was not assessed, so continuity is left alone.")
        }
        guard assessment.isAssessed else {
            // Vision unavailable or unusable. Doing nothing is the conservative
            // answer: a refresh costs a whole generation, and an unassessed
            // frame is not evidence that anything is wrong.
            return .useNormalContinuity(
                reason: "The inherited frame could not be assessed, so continuity is left alone.")
        }
        guard assessment.subjectPresent else {
            return .useNormalContinuity(
                reason: "No subject was found in the inherited frame.")
        }

        if IdentityRefreshThresholds.riskyFaceVisibility.contains(assessment.faceVisibility) {
            return .refresh(reason: "The next shot is a close framing and the inherited frame shows no face.")
        }
        if IdentityRefreshThresholds.riskyOrientations.contains(assessment.subjectOrientation) {
            return .refresh(reason: "The next shot is a close framing and the subject is turned away.")
        }
        if assessment.subjectScale == .tiny {
            return .refresh(reason: "The next shot is a close framing and the subject is very small in the inherited frame.")
        }
        if assessment.subjectScale == .small, assessment.faceVisibility != .clear {
            return .refresh(reason: "The next shot is a close framing and the subject is small with an unclear face.")
        }
        return .useNormalContinuity(
            reason: "The inherited frame already carries enough of the character.")
    }
}

// MARK: - Anchor selection

/// Picks which existing image should seed a refresh.
///
/// A raw character sheet is deliberately last and is never used directly as a
/// shot's starting image: it is a posed plate on a plain background, and
/// pinning it as a first frame drags that plate into the movie. It may only be
/// an *input* to a transformation.
enum IdentityAnchorSelector {

    enum Anchor: Equatable {
        /// A previously generated refresh anchor from this movie.
        case previousRefresh(relativePath: String)
        /// The movie's opening reference still.
        case openingReference(relativePath: String)
        /// Nothing usable — refresh cannot proceed.
        case none

        var relativePath: String? {
            switch self {
            case .previousRefresh(let p), .openingReference(let p): return p
            case .none: return nil
            }
        }
    }

    /// Most recent strong anchor first, then the movie's opening reference.
    ///
    /// - Parameter previousRefreshPaths: refresh anchors already generated for
    ///   this movie, in shot order.
    static func select(
        previousRefreshPaths: [String],
        openingReferenceRelativePath: String?
    ) -> Anchor {
        if let latest = previousRefreshPaths.last(where: { !$0.isEmpty }) {
            return .previousRefresh(relativePath: latest)
        }
        if let opening = openingReferenceRelativePath, !opening.isEmpty {
            return .openingReference(relativePath: opening)
        }
        return .none
    }
}

// MARK: - Existing scene-anchor reuse

/// Chooses whether an already-owned cinematic image can satisfy a refresh.
///
/// This remains deliberately separate from `IdentityRefreshPolicy`: the policy
/// answers whether the inherited frame is risky, while this resolver answers
/// whether an existing *different* image is both identity-rich and compatible
/// with the target scene. It performs no biometric matching.
enum SceneCompatibleIdentityAnchorResolver {

    struct Candidate: Equatable {
        enum Kind: String, Equatable {
            case openingReference
            case previousRefresh
        }

        var kind: Kind
        var relativePath: String
        var assessment: IdentitySourceAssessment?
        /// Shot whose scene metadata describes this image. Opening Reference
        /// uses the opening Shot; generated anchors use their target Shot.
        var referenceShotIndex: Int
        var sourceShotID: UUID?
        var sourceTakeID: UUID?
        var isStale: Bool = false
    }

    enum Decision: Equatable {
        case reuse(Candidate, reason: String)
        case generate(reason: String)
    }

    static func resolve(
        targetShotIndex: Int,
        shots: [Shot],
        candidates: [Candidate]
    ) -> Decision {
        guard shots.indices.contains(targetShotIndex) else {
            return .generate(reason: "The target shot is unavailable.")
        }
        var rejections: [String] = []
        for candidate in candidates {
            if let why = sceneIncompatibility(
                candidate: candidate, targetShotIndex: targetShotIndex, shots: shots
            ) {
                rejections.append("\(candidate.kind.rawValue): \(why)")
                continue
            }
            if let why = identityInsufficiency(of: candidate.assessment) {
                rejections.append("\(candidate.kind.rawValue): \(why)")
                continue
            }
            let source = candidate.kind == .openingReference
                ? "Opening Reference" : "prior Identity Refresh anchor"
            return .reuse(
                candidate,
                reason: "Reused \(source): face, hair and costume are clear; scene continuity is compatible."
            )
        }
        let detail = rejections.isEmpty
            ? "No existing scene anchor was available."
            : rejections.joined(separator: "; ")
        return .generate(reason: detail)
    }

    /// Visibility-only evidence. No attempt is made to decide whether the face
    /// belongs to a particular person.
    static func identityInsufficiency(of assessment: IdentitySourceAssessment?) -> String? {
        guard let assessment else { return "identity visibility was not assessed" }
        guard assessment.isAssessed else { return "identity visibility was not assessed" }
        guard assessment.subjectPresent, assessment.subjectCount == 1 else {
            return "a single subject is not clearly established"
        }
        guard assessment.ambiguityReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "the assessment is ambiguous"
        }
        guard assessment.faceVisibility == .clear else { return "face is not clear" }
        guard assessment.hairVisibility == .clear else { return "hair is not clear" }
        guard assessment.costumeVisibility == .clear else { return "costume is not clear" }
        guard assessment.subjectOrientation != .back else { return "subject is turned away" }
        guard assessment.subjectScale != .tiny else { return "subject is too small" }
        return nil
    }

    /// Deterministic metadata check. Ordinary action and camera changes are not
    /// compared: Gate #1 proved that a good scene anchor can support a reframe.
    static func sceneIncompatibility(
        candidate: Candidate,
        targetShotIndex: Int,
        shots: [Shot]
    ) -> String? {
        guard !candidate.isStale else { return "anchor is stale" }
        guard shots.indices.contains(candidate.referenceShotIndex),
              candidate.referenceShotIndex < targetShotIndex else {
            return "anchor is not from an earlier scene state"
        }
        let anchorShot = shots[candidate.referenceShotIndex]
        let targetShot = shots[targetShotIndex]

        let anchorCast = Set(anchorShot.characterIDs)
        let targetCast = Set(targetShot.characterIDs)
        if !anchorCast.isEmpty, !targetCast.isEmpty,
           anchorCast.isDisjoint(with: targetCast) {
            return "the protagonist/cast changed"
        }

        let transitionShots = shots[(candidate.referenceShotIndex + 1)...targetShotIndex]
        let incompatiblePrefixes = [
            "location=", "timeofday=", "weather=", "wardrobe=", "costume=",
            "outfit=", "outfit:", "transformation=", "charactertransformation=",
        ]
        if let directive = transitionShots.lazy.flatMap(\.explicitChanges).first(where: { change in
            let normalized = change.lowercased().replacingOccurrences(of: " ", with: "")
            return incompatiblePrefixes.contains { normalized.hasPrefix($0) }
        }) {
            return "explicit story transition (\(directive))"
        }

        let anchorState = anchorShot.continuityBefore
        let targetState = targetShot.continuityBefore
        if differs(anchorState?.location, targetState?.location) { return "location changed" }
        if differs(anchorState?.timeOfDay, targetState?.timeOfDay) { return "time of day changed" }
        if differs(anchorState?.weather, targetState?.weather) { return "weather changed" }
        if wardrobeDiffers(anchorState?.characterOutfit, targetState?.characterOutfit) {
            return "wardrobe changed"
        }

        let sameLocation = equalNonempty(anchorState?.location, targetState?.location)
        let sameContinuitySegment = transitionShots.allSatisfy {
            $0.continuityMode == .continueFromPrevious
        }
        guard sameLocation || sameContinuitySegment else {
            return "same scene is not positively established"
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func differs(_ lhs: String?, _ rhs: String?) -> Bool {
        let a = normalized(lhs), b = normalized(rhs)
        return !a.isEmpty && !b.isEmpty && a != b
    }

    private static func equalNonempty(_ lhs: String?, _ rhs: String?) -> Bool {
        let a = normalized(lhs), b = normalized(rhs)
        return !a.isEmpty && a == b
    }

    private static func wardrobeDiffers(
        _ lhs: [String: String]?, _ rhs: [String: String]?
    ) -> Bool {
        let a = lhs ?? [:], b = rhs ?? [:]
        for key in Set(a.keys).intersection(b.keys) {
            if differs(a[key], b[key]) { return true }
        }
        return false
    }
}
