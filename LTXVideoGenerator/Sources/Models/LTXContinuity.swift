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

/// The video mode actually submitted for a Take. This is deliberately a
/// historical execution fact rather than a new planning input.
enum GenerationVideoMode: String, Codable, Equatable {
    case textToVideo
    case imageToVideo

    var displayName: String {
        switch self {
        case .textToVideo: return "Text to video"
        case .imageToVideo: return "Image to video"
        }
    }
}

/// Why a particular prior Take supplied an inherited continuity frame.
enum ContinuityTakeSelectionReason: String, Codable, Equatable {
    case selectedTake
    case latestCompletedTake

    var displayName: String {
        switch self {
        case .selectedTake: return "Selected take"
        case .latestCompletedTake: return "Latest completed take"
        }
    }
}

/// The non-destructive image preparation applied between a canonical source
/// image and the backend. The terms mirror `PreparedImageConditioning.Mode`.
enum GenerationImagePreparationMode: String, Codable, Equatable {
    case noOp
    case scaleToFillCenterCrop

    var displayName: String {
        switch self {
        case .noOp: return "No-op"
        case .scaleToFillCenterCrop: return "Scale to fill · center crop"
        }
    }
}

/// Facts recorded after the existing image-conditioning boundary has prepared
/// an I2V source for the backend. It does not influence that boundary.
struct GenerationImagePreparationDiagnostics: Codable, Equatable {
    var originalWidth: Int
    var originalHeight: Int
    var effectiveWidth: Int
    var effectiveHeight: Int
    var mode: GenerationImagePreparationMode
    /// The backend-facing filename only. The cache's absolute path stays out
    /// of project JSON and the user-facing UI.
    var backendFilename: String?
}

/// Immutable per-Take provenance captured at queue time, then enriched with
/// the result of the existing backend image-preparation boundary. New planning
/// edits never recalculate a historical Take's snapshot.
struct GenerationSourceDiagnostics: Codable, Equatable {
    var requestedContinuityMode: ShotContinuityMode?
    var effectiveSource: LTXContinuitySource
    var actualVideoMode: GenerationVideoMode
    /// Canonical source filename, not an absolute local path.
    var sourceFilename: String?
    /// Project-relative only when the canonical source belongs to this project.
    var sourceProjectRelativePath: String?
    var continuitySourceShotID: UUID?
    var continuitySourceTakeID: UUID?
    var continuityTakeSelectionReason: ContinuityTakeSelectionReason?
    var refreshAnchorOrigin: IdentityRefreshAnchorOrigin?
    var refreshAnchorSourceShotID: UUID?
    var refreshAnchorSourceTakeID: UUID?
    var imagePreparation: GenerationImagePreparationDiagnostics?
    var recordedAt: Date

    var summary: String {
        "\(actualVideoMode.displayName) · \(effectiveSource.displayName)"
    }
}

/// The execution state recorded for one concrete Take. This intentionally
/// records observations only: it does not participate in source selection,
/// settings resolution, retry policy, or any generation decision.
enum GenerationRuntimeStatus: String, Codable, Equatable {
    case running
    case succeeded
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// What the backend boundary reported for the historical Take. `notStarted`
/// is useful when source preparation or Python configuration failed before a
/// backend subprocess could be launched.
enum GenerationBackendResultStatus: String, Codable, Equatable {
    case notStarted
    case succeeded
    case failed
    case cancelled
    case unavailable

    var displayName: String {
        switch self {
        case .notStarted: return "Not started"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .unavailable: return "Unavailable"
        }
    }
}

/// A deliberately small failure vocabulary. It separates preparation from the
/// video backend without attempting to turn diagnostics into a second retry
/// or queue state machine.
enum GenerationFailureStage: String, Codable, Equatable {
    case sourcePreparation
    case backendLaunch
    case backendGeneration
    case outputMissing
    case outputValidation
    case cancelled
    case unknown

    var displayName: String {
        switch self {
        case .sourcePreparation: return "Source preparation"
        case .backendLaunch: return "Backend launch"
        case .backendGeneration: return "Backend generation"
        case .outputMissing: return "Output missing"
        case .outputValidation: return "Output validation"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown"
        }
    }
}

/// Immutable runtime facts captured from execution start through terminal
/// finalization. Requested, effective, and actual values stay separate:
/// `actual*` is populated only by inspection of the output media file.
struct GenerationRuntimeDiagnostics: Codable, Equatable {
    var status: GenerationRuntimeStatus
    var startedAt: Date
    var finishedAt: Date?
    var elapsedSeconds: Double?

    var requestedWidth: Int
    var requestedHeight: Int
    var effectiveWidth: Int?
    var effectiveHeight: Int?
    var actualWidth: Int?
    var actualHeight: Int?

    var requestedFrames: Int?
    var requestedDurationSeconds: Double?
    var actualDurationSeconds: Double?
    var actualFPS: Double?
    /// Only set when the media inspector reports a native frame count. It is
    /// never inferred from duration × FPS.
    var actualFrameCount: Int?

    var backendResult: GenerationBackendResultStatus
    var backendExitCode: Int?
    var failureStage: GenerationFailureStage?
    /// Bounded, single-line diagnostic suitable for project JSON. Full runner
    /// stderr remains in the existing local log rather than being persisted.
    var errorSummary: String?

    var outputFilename: String?
    var outputExists: Bool
    var outputMetadataReadable: Bool?
}

/// Pure helpers shared by the runtime recorder and its tests. They deliberately
/// inspect only the existing error message; they never alter the error that is
/// surfaced to the user or returned to the generation queue.
enum GenerationRuntimeFailureClassifier {
    static let maximumErrorSummaryLength = 320

    static func conciseSummary(for error: Error) -> String {
        let candidate = error.localizedDescription
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Generation failed."
        guard candidate.count > maximumErrorSummaryLength else { return candidate }
        let end = candidate.index(candidate.startIndex, offsetBy: maximumErrorSummaryLength)
        return String(candidate[..<end]) + "…"
    }

    static func stage(for error: Error) -> GenerationFailureStage {
        let message = error.localizedDescription.lowercased()
        if message.contains("unable to prepare the starting image")
            || message.contains("source image preparation") {
            return .sourcePreparation
        }
        if message.contains("python environment not configured")
            || message.contains("failed to launch")
            || message.contains("no generation adapter supports") {
            return .backendLaunch
        }
        if message.contains("output file")
            && (message.contains("missing") || message.contains("not found")) {
            return .outputMissing
        }
        if message.contains("failed to parse generation output")
            || message.contains("invalid output")
            || message.contains("corrupt output") {
            return .outputValidation
        }
        return .backendGeneration
    }

    static func exitCode(from error: Error) -> Int? {
        let message = error.localizedDescription.lowercased()
        for marker in ["exit code", "exit status"] {
            guard let range = message.range(of: marker) else { continue }
            let suffix = message[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let token = suffix.prefix { $0 == "-" || $0.isNumber }
            if !token.isEmpty, let value = Int(token) {
                return value
            }
        }
        return nil
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
