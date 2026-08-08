import Foundation

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
            // 1. Known-successful profile wins.
            if let known = history.highestKnownSafeProfile(hardwareSignature: hardware.signature, modelID: modelID) {
                return makeResolution(target: known, snapshot: snapshot,
                                      reason: "Highest known-safe profile from history (\(known.id))")
            }
            // 2. Hardware prior.
            let prior: QualityProfile
            switch hardware.memoryTier {
            case .tier16: prior = QualityProfileLadder.compact0
            case .tier24: prior = QualityProfileLadder.compact2
            case .tier32: prior = QualityProfileLadder.standard
            case .tier48, .tier64plus: prior = QualityProfileLadder.high
            }
            return makeResolution(target: prior, snapshot: snapshot,
                                  reason: "Hardware prior for \(hardware.memoryTier.rawValue)")
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
