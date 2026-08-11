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
