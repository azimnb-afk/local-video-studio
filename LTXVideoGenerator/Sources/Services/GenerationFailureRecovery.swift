import Foundation

/// Persists a one-shot VAE tiling fallback after Metal watchdog failures with aggressive tiling (#48).
enum GenerationFailureRecovery {
    private static let pendingAggressiveToAutoKey = "ltxPendingTilingAggressiveToAutoFallback"

    static var pendingAggressiveTilingToAutoFallback: Bool {
        get { UserDefaults.standard.bool(forKey: pendingAggressiveToAutoKey) }
        set { UserDefaults.standard.set(newValue, forKey: pendingAggressiveToAutoKey) }
    }

    static func recordMetalInteractivityFailureWithAggressiveTiling() {
        pendingAggressiveTilingToAutoFallback = true
    }

    static func clearAfterSuccessfulGeneration() {
        pendingAggressiveTilingToAutoFallback = false
    }

    static func effectiveTilingMode(requested: String) -> (mode: String, appliedFallback: Bool) {
        if pendingAggressiveTilingToAutoFallback && requested == "aggressive" {
            return ("auto", true)
        }
        return (requested, false)
    }
}
