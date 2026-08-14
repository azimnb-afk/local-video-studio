import Foundation

/// Protocol for normalizing user semantic scene/action descriptions into
/// clean English descriptions suitable for video generation models.
protocol RenderTextNormalizer: Sendable {
    func normalizeDescriptionToEnglish(_ originalText: String) async throws -> String
}

/// Default local-only normalizer used by Basic Director.
/// If text is already renderer-safe English, it passes through untouched (No Double Translation).
/// If text contains non-English scripts, it attempts local conversion, and fails-closed
/// with an actionable user error if local conversion is unavailable.
final class BasicRenderLanguageNormalizer: RenderTextNormalizer {

    init() {}

    func normalizeDescriptionToEnglish(_ originalText: String) async throws -> String {
        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Phase 8: No Double Translation.
        // If the text is already renderer-safe English (Latin script, numbers, punctuation),
        // pass through as-is without modification.
        if RenderLanguageValidator.isRendererSafeEnglish(trimmed) {
            return trimmed
        }

        // Fail-Closed guarantee:
        // When local on-device translation is not configured/available in Basic mode,
        // we DO NOT silently pass raw Japanese or foreign script to the renderer backend.
        // We throw an explicit actionable DirectorError so generation is safely blocked.
        let scripts = RenderLanguageValidator.detectedNonEnglishScriptNames(in: trimmed)
        let scriptLabel = scripts.isEmpty ? "non-English" : scripts.joined(separator: "/")
        throw DirectorError.basicNormalizationFailed(
            "Basic Director could not convert \(scriptLabel) text to an English render prompt locally. " +
            "Please retry, enable Local AI Director, or provide an English prompt."
        )
    }
}

/// Scriptable deterministic mock normalizer for unit tests.
final class MockRenderTextNormalizer: RenderTextNormalizer {
    var mappings: [String: String] = [:]
    var shouldThrow: Bool = false
    var errorToThrow: Error?
    var fallbackReturnValue: String?
    private(set) var callCount: Int = 0
    private(set) var calledTexts: [String] = []

    init(mappings: [String: String] = [:], shouldThrow: Bool = false, errorToThrow: Error? = nil) {
        self.mappings = mappings
        self.shouldThrow = shouldThrow
        self.errorToThrow = errorToThrow
    }

    func normalizeDescriptionToEnglish(_ originalText: String) async throws -> String {
        callCount += 1
        calledTexts.append(originalText)

        if shouldThrow {
            if let error = errorToThrow {
                throw error
            }
            throw DirectorError.basicNormalizationFailed("Mock normalizer failed as instructed")
        }

        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mapped = mappings[trimmed] {
            return mapped
        }

        if let fallback = fallbackReturnValue {
            return fallback
        }

        // Default behavior: if English, pass through; otherwise throw fail-closed
        if RenderLanguageValidator.isRendererSafeEnglish(trimmed) {
            return trimmed
        }

        throw DirectorError.basicNormalizationFailed("Mock normalizer has no mapping for non-English text: \"\(trimmed)\"")
    }
}
