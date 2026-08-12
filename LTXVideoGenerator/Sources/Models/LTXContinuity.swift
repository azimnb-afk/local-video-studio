import Foundation

/// How a shot obtains the image LTX starts from, named.
///
/// This is the minimum vocabulary for the continuity system that already works
/// — it describes the existing precedence in `TakeGenerationCoordinator` rather
/// than replacing it. Nothing here changes generation behaviour; it exists so
/// the choice can be tested, explained and shown.
enum LTXContinuitySource: String, Codable, Equatable, CaseIterable {
    /// An image the user picked for this specific shot.
    case explicitStartingImage
    /// A fresh identity-bearing anchor prepared because the inherited frame
    /// could not carry the character into a closer framing.
    case identityRefreshAnchor
    /// The last usable frame of the previous shot's selected take.
    case inheritedLastFrame
    /// The movie's opening reference still. First shot only.
    case openingReference
    /// A Character Bible anchor. First shot only.
    case characterAnchor
    /// No image: text-to-video.
    case none

    var displayName: String {
        switch self {
        case .explicitStartingImage: return "Starting image you chose"
        case .identityRefreshAnchor: return "Identity Refresh anchor"
        case .inheritedLastFrame: return "Previous shot's last frame"
        case .openingReference: return "Opening Reference"
        case .characterAnchor: return "Character Anchor"
        case .none: return "Text to video"
        }
    }
}

/// What kind of continuation a shot performs.
enum LTXContinuityStrategy: String, Codable, Equatable {
    /// Inherits visual state from the previous shot.
    case lastFrame
    /// Starts fresh — a cut inherits nothing from the shot before it.
    case none

    var displayName: String {
        switch self {
        case .lastFrame: return "Last Frame"
        case .none: return "None (cut)"
        }
    }
}

/// Requested → Effective → Actual, applied to continuity.
///
/// The app already uses this shape for quality settings, and it answers the
/// question that is otherwise guesswork when a shot looks wrong: the plan asked
/// for one thing, the rules resolved it to another, and a specific file was
/// used.
struct LTXContinuityResolution: Equatable {
    /// What the Director's plan asked for. `auto` is a real answer here.
    var requestedMode: ShotContinuityMode?
    /// What the rules resolved it to.
    var effectiveStrategy: LTXContinuityStrategy
    /// Which kind of image won the precedence.
    var source: LTXContinuitySource
    /// The managed asset actually handed to LTX, when there is one.
    var actualRelativePath: String?
    /// Shot and take the inherited frame came from.
    var previousShotID: UUID?
    var previousTakeID: UUID?

    var provenance: String {
        var parts = ["Requested \(requestedMode?.displayName ?? "Auto")",
                     "Effective \(effectiveStrategy.displayName)",
                     "Source \(source.displayName)"]
        if let actualRelativePath, !actualRelativePath.isEmpty {
            parts.append("Actual \(actualRelativePath)")
        }
        return parts.joined(separator: " · ")
    }
}

/// Classifies what a shot will start from.
///
/// Mirrors the precedence in `TakeGenerationCoordinator.planTakes` exactly and
/// deliberately does not re-implement the file-existence checks that live
/// there: this describes the decision, the coordinator makes it. Keeping the
/// order stated once, in a testable place, is what stops it drifting silently.
enum LTXContinuityResolver {

    /// - Parameter shotIndex: position in the movie; only shot 0 can use the
    ///   opening reference or the character anchor.
    static func resolve(
        shot: Shot,
        shotIndex: Int,
        hasOpeningReference: Bool,
        hasCharacterAnchor: Bool,
        inheritsPreviousShot: Bool? = nil
    ) -> LTXContinuityResolution {
        var resolution = LTXContinuityResolution(
            requestedMode: shot.continuityMode,
            effectiveStrategy: .none,
            source: .none,
            actualRelativePath: nil,
            previousShotID: nil,
            previousTakeID: nil
        )

        // 1. The user's own choice for this shot always wins.
        if shot.startingImageReferenceAssetID != nil {
            resolution.source = .explicitStartingImage
            resolution.effectiveStrategy = .lastFrame
            return resolution
        }
        // A Cut can still use an explicit image above, but it can never reuse
        // previous-shot state. The optional argument lets the Auto Movie
        // preview pass the same effective (including `auto`) resolution as the
        // run coordinator; direct callers get the persisted explicit mode.
        let mayInheritPrevious = inheritsPreviousShot
            ?? (shotIndex > 0 && shot.continuityMode != .cut)

        // 2. A refresh anchor replaces an inherited frame that could not carry
        //    the character; it is still a continuation.
        if mayInheritPrevious,
           let refresh = shot.identityRefreshAnchorRelativePath, !refresh.isEmpty {
            resolution.source = .identityRefreshAnchor
            resolution.effectiveStrategy = .lastFrame
            resolution.actualRelativePath = refresh
            resolution.previousTakeID = shot.identityRefreshSourceTakeID
            return resolution
        }
        // 3. The ordinary continuation.
        if mayInheritPrevious,
           let inherited = shot.continuityImageRelativePath, !inherited.isEmpty {
            resolution.source = .inheritedLastFrame
            resolution.effectiveStrategy = .lastFrame
            resolution.actualRelativePath = inherited
            resolution.previousTakeID = shot.continuitySourceTakeID
            return resolution
        }
        // 4/5. Opening-shot-only sources.
        if shotIndex == 0 {
            if hasOpeningReference {
                resolution.source = .openingReference
                resolution.effectiveStrategy = .lastFrame
                return resolution
            }
            if hasCharacterAnchor {
                resolution.source = .characterAnchor
                resolution.effectiveStrategy = .lastFrame
                return resolution
            }
        }
        // 6. Nothing applies — text to video.
        return resolution
    }
}
