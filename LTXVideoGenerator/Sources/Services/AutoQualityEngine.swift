import Foundation
import ImageIO

/// The orientation of the image as a user sees it. `.none` is a concrete
/// absence/unreadable result, distinct from an un-resolved request (`nil`).
enum SourceImageOrientation: String, Codable, Equatable {
    case portrait
    case landscape
    case square
    case none

    var displayName: String? {
        switch self {
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        case .square: return "Square"
        case .none: return nil
        }
    }
}

/// Lightweight ImageIO metadata inspection shared by every preset workflow.
/// EXIF orientations 5...8 exchange the encoded axes, so a 4032x3024 JPEG
/// displayed as portrait is classified as portrait without modifying it.
enum SourceImageOrientationResolver {
    static func resolve(path: String?) -> SourceImageOrientation {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return .none }
        return resolve(url: URL(fileURLWithPath: path))
    }

    static func resolve(url: URL) -> SourceImageOrientation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let encodedWidth = number(properties[kCGImagePropertyPixelWidth]),
              let encodedHeight = number(properties[kCGImagePropertyPixelHeight]),
              encodedWidth > 0, encodedHeight > 0 else {
            return .none
        }
        let exifOrientation = number(properties[kCGImagePropertyOrientation]) ?? 1
        let exchangesAxes = (5...8).contains(exifOrientation)
        let visualWidth = exchangesAxes ? encodedHeight : encodedWidth
        let visualHeight = exchangesAxes ? encodedWidth : encodedHeight
        if visualWidth == visualHeight { return .square }
        return visualWidth > visualHeight ? .landscape : .portrait
    }

    private static func number(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        return value as? Int
    }
}

/// Resolves a generation request to a concrete quality profile using
/// hardware prior + current memory state + model capability + history,
/// and produces the fallback ladder for OOM recovery.
///
/// Decision flow (Deep Research §16):
///   Request → Policy Filter → Model Compatibility Filter →
///   Known Successful Profile? yes → highest known-safe
///                             no  → hardware estimate → preflight → render
///   OOM/pressure → reset backend → lower profile → max 3 attempts → Unsupported
final class AutoQualityEngine {

    struct Resolution: Equatable {
        var profile: QualityProfile
        /// Profiles to try in order (first = chosen profile). Never more than
        /// maxAttempts entries.
        var attemptLadder: [QualityProfile]
        var reason: String
    }

    enum ResolutionError: Error, Equatable {
        case unsupported(String)
    }

    static let maxAttempts = 3
    /// Fraction of currently-available memory a profile may claim in preflight.
    /// Generous because macOS reclaims cache under pressure and the backend
    /// runs in its own subprocess (jetsam kills the child, not the app).
    static let preflightHeadroomFactor = 1.6

    private let history: HistoricalSuccessStore
    private let hardware: HardwareProfile

    init(history: HistoricalSuccessStore = .shared, hardware: HardwareProfile = HardwareProfiler.current()) {
        self.history = history
        self.hardware = hardware
    }

    /// Picks the target profile for a mode.
    func resolve(
        mode: QualityMode,
        modelID: String,
        snapshot: MemorySnapshot,
        audioRequested: Bool
    ) throws -> Resolution {
        switch mode {
        case .advanced:
            throw ResolutionError.unsupported("Advanced mode is user-controlled; Auto Quality must not modify it.")
        case .compact:
            let target = audioRequested ? QualityProfileLadder.compactAudio : QualityProfileLadder.compact2
            return makeResolution(target: target, snapshot: snapshot, reason: "Compact mode requested")
        case .high:
            return makeResolution(target: QualityProfileLadder.high, snapshot: snapshot, reason: "High mode requested")
        case .auto:
            // Start with the hardware prior. A lower-profile success by itself
            // must not pin Standard to Compact forever; it only becomes a cap
            // after the prior has an explicit latest failure.
            let prior: QualityProfile
            switch hardware.memoryTier {
            case .tier16: prior = QualityProfileLadder.compact0
            case .tier24: prior = QualityProfileLadder.compact2
            case .tier32, .tier48: prior = QualityProfileLadder.standard
            case .tier64plus: prior = QualityProfileLadder.high
            }

            if let known = history.highestKnownSafeProfile(
                hardwareSignature: hardware.signature,
                modelID: modelID
            ), known.rank >= prior.rank {
                return makeResolution(
                    target: prior,
                    snapshot: snapshot,
                    reason: "History confirms the hardware prior \(prior.id) (known success \(known.id))"
                )
            }

            if history.latestAttemptFailed(
                profileID: prior.id,
                hardwareSignature: hardware.signature,
                modelID: modelID
            ) {
                let fallback = history.highestKnownSafeProfile(
                    hardwareSignature: hardware.signature,
                    modelID: modelID
                ) ?? QualityProfileLadder.descending(fromRank: prior.rank).dropFirst().first
                    ?? QualityProfileLadder.compact0
                return makeResolution(
                    target: fallback,
                    snapshot: snapshot,
                    reason: "History fallback: hardware prior \(prior.id) most recently failed; using \(fallback.id)"
                )
            }

            return makeResolution(target: prior, snapshot: snapshot,
                                  reason: "Hardware prior for \(hardware.memoryTier.rawValue); lower-profile successes do not cap Standard")
        }
    }

    /// Builds the ladder: target first, then progressively safer profiles that
    /// pass preflight, capped at maxAttempts. Fallback order within the ladder
    /// mirrors: frames reduction → resolution reduction → audio off → Compact.
    private func makeResolution(target: QualityProfile, snapshot: MemorySnapshot, reason: String) -> Resolution {
        var ladder: [QualityProfile] = []
        for candidate in QualityProfileLadder.descending(fromRank: target.rank) {
            if ladder.count >= Self.maxAttempts { break }
            ladder.append(candidate)
        }
        if ladder.isEmpty { ladder = [QualityProfileLadder.compact0] }

        // Preflight: if the target clearly exceeds what this machine could ever
        // provide (physical), start lower immediately rather than wasting a run.
        let physical = snapshot.physicalGB
        while ladder.count > 1, ladder[0].estimatedPeakGB > physical {
            ladder.removeFirst()
        }
        return Resolution(profile: ladder[0], attemptLadder: ladder, reason: reason)
    }

    /// Preflight check against the current memory snapshot. Advisory: a failed
    /// preflight prefers a lower profile but the ladder still enforces limits.
    func preflightPasses(_ profile: QualityProfile, snapshot: MemorySnapshot) -> Bool {
        profile.estimatedPeakGB <= snapshot.availableGB * Self.preflightHeadroomFactor
            || profile.estimatedPeakGB <= snapshot.physicalGB * 0.75
    }

    /// Records an attempt outcome so future Auto decisions improve.
    func recordOutcome(modelID: String, profileID: String, succeeded: Bool,
                       peakMemoryBytes: Int64? = nil, wallSeconds: Double? = nil) {
        history.record(HistoricalSuccessRecord(
            hardwareSignature: hardware.signature,
            modelID: modelID,
            profileID: profileID,
            succeeded: succeeded,
            peakMemoryBytes: peakMemoryBytes,
            wallSeconds: wallSeconds,
            recordedAt: Date()
        ))
    }

    /// Classifies a generation failure as memory-related (→ retry lower) or not.
    static func isMemoryRelatedFailure(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("sigkill") || text.contains("out of memory")
            || text.contains("memory pressure") || text.contains("jetsam")
            || text.contains("outofmemory") || text.contains("bad_alloc")
            || text.contains("code -9") || text.contains("insufficient memory")
    }
}

/// The single policy boundary that converts a user-facing preset request into
/// the concrete request sent to the renderer. Every workflow and retry uses
/// this resolver, so profile fields and duration precedence cannot diverge.
struct ResolvedGenerationSettings: Equatable {
    var request: GenerationRequest
    var profile: QualityProfile?
    var attemptLadder: [QualityProfile]
    var reason: String
}

enum GenerationSettingsResolver {
    /// Resolves the settings that the user will actually queue. This is also
    /// used by UI preflight so warnings and queue rows describe the same
    /// profile that GenerationService will render. The service resolves once
    /// more immediately before invoking the backend, which remains the final
    /// source of truth for a changing memory snapshot.
    static func resolveForPreflight(
        request: GenerationRequest,
        engine: AutoQualityEngine = AutoQualityEngine(),
        snapshot: MemorySnapshot = MemoryMonitor.shared.snapshot()
    ) -> ResolvedGenerationSettings {
        do {
            return try resolve(request: request, engine: engine, snapshot: snapshot)
        } catch {
            // A preflight must never prevent a request from being queued. The
            // GenerationService will surface a real resolution error at the
            // execution boundary.
            return ResolvedGenerationSettings(
                request: request,
                profile: nil,
                attemptLadder: [],
                reason: "Preflight unavailable; preserving request parameters"
            )
        }
    }

    static func resolve(
        request: GenerationRequest,
        engine: AutoQualityEngine,
        snapshot: MemorySnapshot
    ) throws -> ResolvedGenerationSettings {
        guard let rawMode = request.qualityMode,
              let mode = QualityMode(rawValue: rawMode) else {
            return ResolvedGenerationSettings(
                request: request,
                profile: nil,
                attemptLadder: [],
                reason: "Direct request parameters (Auto Quality not requested)"
            )
        }
        guard mode != .advanced else {
            return ResolvedGenerationSettings(
                request: request,
                profile: nil,
                attemptLadder: [],
                reason: "Custom/Advanced parameters preserved"
            )
        }

        let resolution = try engine.resolve(
            mode: mode,
            modelID: request.modelId,
            snapshot: snapshot,
            audioRequested: !request.disableAudio
        )
        let orientation = request.presetResolutionOrientation
            ?? SourceImageOrientationResolver.resolve(path: request.sourceImagePath)
        let oriented = applying(
            profile: resolution.profile,
            to: request,
            orientation: orientation
        )
        let orientationReason: String
        if orientation == .portrait,
           resolution.profile.width != resolution.profile.height {
            orientationReason = "; preset resolution oriented to portrait source"
        } else {
            orientationReason = ""
        }
        return ResolvedGenerationSettings(
            request: oriented,
            profile: resolution.profile,
            attemptLadder: resolution.attemptLadder,
            reason: resolution.reason + orientationReason
        )
    }

    /// Preset profile supplies resolution/FPS/steps/audio. A workflow duration
    /// intent then constrains frames using the profile FPS. Custom requests do
    /// not call this method and retain their manual frame count.
    static func applying(profile: QualityProfile, to request: GenerationRequest) -> GenerationRequest {
        let orientation = request.presetResolutionOrientation
            ?? SourceImageOrientationResolver.resolve(path: request.sourceImagePath)
        return applying(profile: profile, to: request, orientation: orientation)
    }

    private static func applying(
        profile: QualityProfile,
        to request: GenerationRequest,
        orientation: SourceImageOrientation
    ) -> GenerationRequest {
        var parameters = profile.applied(to: request.parameters)
        let longSide = max(profile.width, profile.height)
        let shortSide = min(profile.width, profile.height)
        if profile.width != profile.height {
            switch orientation {
            case .portrait:
                parameters.width = shortSide
                parameters.height = longSide
            case .landscape:
                parameters.width = longSide
                parameters.height = shortSide
            case .square, .none:
                break
            }
        }
        if let target = request.targetDurationSeconds {
            parameters.numFrames = PromptCompiler.frameCount(forSeconds: target, fps: profile.fps)
        }
        return GenerationRequest(
            id: request.id,
            prompt: request.prompt,
            negativePrompt: request.negativePrompt,
            voiceoverText: request.voiceoverText,
            voiceoverSource: request.voiceoverSource,
            voiceoverVoice: request.voiceoverVoice,
            sourceImagePath: request.sourceImagePath,
            presetResolutionOrientation: orientation,
            musicEnabled: request.musicEnabled,
            musicGenre: request.musicGenre,
            disableAudio: request.disableAudio || !profile.audioEnabled,
            gemmaRepetitionPenalty: request.gemmaRepetitionPenalty,
            gemmaTopP: request.gemmaTopP,
            modelId: request.modelId,
            textEncoderId: request.textEncoderId,
            parameters: parameters,
            createdAt: request.createdAt,
            status: request.status,
            modelRevision: request.modelRevision,
            quantization: request.quantization,
            qualityMode: request.qualityMode,
            preset: request.preset,
            targetDurationSeconds: request.targetDurationSeconds,
            generationSource: request.generationSource,
            adultMode: request.adultMode,
            filmProjectID: request.filmProjectID,
            shotID: request.shotID,
            takeID: request.takeID
        )
    }
}
