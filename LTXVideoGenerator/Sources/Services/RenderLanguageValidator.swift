import Foundation

/// Validates that descriptive text intended for the video rendering backend
/// contains only renderer-safe English text and no unresolved non-English scripts
/// (e.g. Japanese Hiragana/Katakana, CJK Han, Cyrillic, etc.).
enum RenderLanguageValidator {

    /// Detects whether the given string contains descriptive scripts that are
    /// non-English / non-Latin (e.g. Japanese, Chinese, Cyrillic, Korean, Arabic, Hindi, Thai).
    static func containsNonEnglishDescriptiveScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if isNonEnglishDescriptiveScalar(scalar) {
                return true
            }
        }
        return false
    }

    /// Checks if a text string is safe for English-only video rendering.
    /// Returns true if it contains only Latin/ASCII characters, punctuation,
    /// numbers, and standard whitespace/symbols, with no unsupported foreign scripts.
    static func isRendererSafeEnglish(_ text: String) -> Bool {
        return !containsNonEnglishDescriptiveScript(text)
    }

    /// Identifies the names of any non-English scripts detected in the text.
    static func detectedNonEnglishScriptNames(in text: String) -> [String] {
        var scripts = Set<String>()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x3040...0x309F:
                scripts.insert("Japanese Hiragana")
            case 0x30A0...0x30FF, 0x31F0...0x31FF, 0x3200...0x32FF:
                scripts.insert("Japanese Katakana")
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF:
                scripts.insert("CJK Han")
            case 0x0400...0x04FF, 0x0500...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
                scripts.insert("Cyrillic")
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                scripts.insert("Korean Hangul")
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF:
                scripts.insert("Arabic")
            case 0x0900...0x097F:
                scripts.insert("Devanagari")
            case 0x0E00...0x0E7F:
                scripts.insert("Thai")
            case 0x0370...0x03FF, 0x1F00...0x1FFF:
                scripts.insert("Greek")
            default:
                break
            }
        }
        return Array(scripts).sorted()
    }

    /// Validates an action description before compiling or rendering.
    /// Throws `DirectorError.unsupportedRenderLanguage` if unsupported foreign scripts are present.
    static func validateRendererAction(_ action: String) throws {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if containsNonEnglishDescriptiveScript(trimmed) {
            let scripts = detectedNonEnglishScriptNames(in: trimmed)
            let details = scripts.isEmpty ? "non-English script" : scripts.joined(separator: ", ")
            throw DirectorError.unsupportedRenderLanguage("Render action contains raw \(details): \"\(trimmed.prefix(60))\"")
        }
    }

    private static func isNonEnglishDescriptiveScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        switch v {
        // Japanese Hiragana
        case 0x3040...0x309F:
            return true
        // Japanese Katakana & phonetic extensions
        case 0x30A0...0x30FF, 0x31F0...0x31FF, 0x3200...0x32FF:
            return true
        // CJK Unified Ideographs & Extensions
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF:
            return true
        // Cyrillic & extensions
        case 0x0400...0x04FF, 0x0500...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return true
        // Korean Hangul
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
            return true
        // Arabic
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF:
            return true
        // Devanagari (Hindi, Sanskrit, Marathi)
        case 0x0900...0x097F:
            return true
        // Thai
        case 0x0E00...0x0E7F:
            return true
        // Greek
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return true
        default:
            return false
        }
    }
}
