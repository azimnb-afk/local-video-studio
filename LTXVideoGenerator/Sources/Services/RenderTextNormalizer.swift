import Foundation
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

/// Protocol for normalizing user semantic scene/action descriptions into
/// clean English descriptions suitable for video generation models.
protocol RenderTextNormalizer: Sendable {
    func normalizeDescriptionToEnglish(_ originalText: String) async throws -> String
}

/// Real local on-device translator utilizing Apple's platform Translation framework.
/// Runs completely offline with zero network requests and zero external API dependencies.
enum ApplePlatformOnDeviceTranslator {
    static func translateToEnglish(_ text: String) async throws -> String {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }

            // Detect source language (e.g. Japanese "ja", Chinese "zh", etc.)
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(trimmed)
            let sourceIdentifier = recognizer.dominantLanguage?.rawValue ?? "ja"
            let source = Locale.Language(identifier: sourceIdentifier)
            let target = Locale.Language(identifier: "en")

            // Check language availability
            let availability = LanguageAvailability()
            let status = await availability.status(from: source, to: target)
            guard status == .installed || status == .supported else {
                throw DirectorError.basicNormalizationFailed(
                    "On-device translation from \(sourceIdentifier) to English is unavailable (status: \(status))."
                )
            }

            let session = TranslationSession(installedSource: source, target: target)
            let response = try await session.translate(trimmed)
            let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else {
                throw DirectorError.basicNormalizationFailed("On-device translation returned empty text.")
            }
            return translated
        }
        #endif

        throw DirectorError.basicNormalizationFailed(
            "Apple on-device translation requires supported macOS version."
        )
    }
}

/// Default local-only normalizer used by Basic Director.
/// If text is already renderer-safe English, it passes through untouched (No Double Translation).
/// If text contains non-English scripts, it translates locally via Apple on-device translation,
/// and fails-closed with an actionable user error if translation fails or is unavailable.
final class BasicRenderLanguageNormalizer: RenderTextNormalizer {

    init() {}

    func normalizeDescriptionToEnglish(_ originalText: String) async throws -> String {
        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Phase 7: English input fast path (No Double Translation).
        // If the text is already renderer-safe English (Latin script, numbers, punctuation),
        // pass through as-is without modification.
        if RenderLanguageValidator.isRendererSafeEnglish(trimmed) {
            return trimmed
        }

        // Real local on-device translation
        do {
            let translated = try await ApplePlatformOnDeviceTranslator.translateToEnglish(trimmed)
            // Ensure translated text is renderer-safe English
            try RenderLanguageValidator.validateRendererAction(translated)
            return translated
        } catch let error as DirectorError {
            throw error
        } catch {
            let scripts = RenderLanguageValidator.detectedNonEnglishScriptNames(in: trimmed)
            let scriptLabel = scripts.isEmpty ? "non-English" : scripts.joined(separator: "/")
            throw DirectorError.basicNormalizationFailed(
                "Basic Director could not translate \(scriptLabel) text to English locally: \(error.localizedDescription)"
            )
        }
    }
}

/// Scriptable deterministic mock normalizer for unit tests.
final class MockRenderTextNormalizer: RenderTextNormalizer, @unchecked Sendable {
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
