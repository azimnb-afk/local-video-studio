import Foundation

/// Canonical sanitizer for LLM-generated prompt text.
/// Strips chat-template artifacts, cuts at the first terminal control token,
/// normalizes formatting, and guarantees no raw control tokens reach the renderer.
enum PromptSanitizer {

    /// Known terminal tokens that signify the end of LLM generation.
    /// The prompt is truncated at the FIRST occurrence of any of these tokens.
    private static let terminalTokens = [
        "<end_of_turn>",
        "<eos>",
        "<|eos|>",
        "</s>",
        "<|eot_id|>",
        "<|end_of_text|>",
        "<|im_end|>"
    ]

    /// Known prefix / start / role artifacts that should be removed if present.
    private static let startTokensAndPatterns: [(pattern: String, isRegex: Bool)] = [
        (pattern: "<start_of_turn>model\n?", isRegex: true),
        (pattern: "<start_of_turn>assistant\n?", isRegex: true),
        (pattern: "<start_of_turn>user\n?", isRegex: true),
        (pattern: "<start_of_turn>system\n?", isRegex: true),
        (pattern: "<start_of_turn>", isRegex: false),
        (pattern: "<bos>", isRegex: false),
        (pattern: "<|bos|>", isRegex: false),
        (pattern: "<s>", isRegex: false),
        (pattern: "<\\|start_header_id\\|>(model|assistant|user|system)<\\|end_header_id\\|>\n?", isRegex: true),
        (pattern: "<\\|im_start\\|>(model|assistant|user|system)\n?", isRegex: true),
        (pattern: "<|im_start|>", isRegex: false),
    ]

    /// Sanitizes LLM output text:
    /// 1. Truncates at the FIRST terminal control token (discarding repeated tokens and following junk).
    /// 2. Strips known start/role control tags.
    /// 3. Strips markdown code fences.
    /// 4. Trims leading/trailing whitespace and normalizes internal line breaks.
    static func sanitize(_ rawText: String) -> String {
        var text = rawText

        // 1. Truncate at the earliest terminal token
        var earliestIndex: String.Index? = nil
        for token in terminalTokens {
            if let range = text.range(of: token, options: .caseInsensitive) {
                if let current = earliestIndex {
                    if range.lowerBound < current {
                        earliestIndex = range.lowerBound
                    }
                } else {
                    earliestIndex = range.lowerBound
                }
            }
        }
        if let cutPoint = earliestIndex {
            text = String(text[..<cutPoint])
        }

        // 2. Remove start and role artifacts
        for item in startTokensAndPatterns {
            if item.isRegex {
                if let regex = try? NSRegularExpression(pattern: item.pattern, options: [.caseInsensitive]) {
                    let range = NSRange(text.startIndex..<text.endIndex, in: text)
                    text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
                }
            } else {
                text = text.replacingOccurrences(of: item.pattern, with: "", options: [.caseInsensitive])
            }
        }

        // 3. Remove leading/trailing code fences (e.g. ```, ```markdown, ```json)
        text = text.replacingOccurrences(of: "```json", with: "", options: [.caseInsensitive])
        text = text.replacingOccurrences(of: "```markdown", with: "", options: [.caseInsensitive])
        text = text.replacingOccurrences(of: "```", with: "")

        // 4. Normalize whitespace
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        text = lines.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    /// Checks if a sanitized enhanced prompt is valid and non-empty.
    static func isValidEnhancedPrompt(_ sanitizedText: String) -> Bool {
        let trimmed = sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Must not contain any remaining control tokens
        for token in terminalTokens {
            if trimmed.contains(token) { return false }
        }
        if trimmed.contains("<start_of_turn>") || trimmed.contains("<|im_start|>") {
            return false
        }
        return true
    }
}
