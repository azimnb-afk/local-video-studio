import Foundation

enum JapaneseDialogueHandling: String, Codable, CaseIterable {
    case native          // keep Japanese as written (default)
    case romanizedFallback // native first, romanization appended when available
    case keepOriginal    // never touch dialogue at all
}

/// Normalizes dialogue lines without rewriting the user's words.
enum DialogueNormalizer {
    static func normalize(
        _ lines: [OneShotPlan.DialogueLine],
        handling: JapaneseDialogueHandling = .native
    ) -> [OneShotPlan.DialogueLine] {
        lines.compactMap { line in
            var normalized = line
            normalized.speaker = line.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.text.isEmpty else { return nil }
            if handling == .keepOriginal {
                return normalized
            }
            if normalized.speaker.isEmpty { normalized.speaker = "Speaker" }
            return normalized
        }
    }

    /// Renders a dialogue line for the compiled prompt.
    static func render(_ line: OneShotPlan.DialogueLine, handling: JapaneseDialogueHandling) -> String {
        let base = "\(line.speaker) says: \"\(line.text)\""
        if handling == .romanizedFallback,
           let romanization = line.romanization,
           !romanization.isEmpty {
            return base + " (romanized: \(romanization))"
        }
        return base
    }
}

/// Compiles a structured OneShotPlan into a single flowing LTX prompt:
/// chronological, present tense, visible action, camera, motion, lighting,
/// dialogue and audio in one description (official LTX prompt guidance).
enum PromptCompiler {

    struct Options {
        var isImageToVideo: Bool = false
        var japaneseHandling: JapaneseDialogueHandling = .native
    }

    static func compile(plan: OneShotPlan, options: Options = Options()) -> String {
        var sentences: [String] = []

        // Camera first: it frames everything that follows.
        sentences.append(sentence(plan.camera, prefix: "The camera"))

        // For I2V the source image is the visual source of truth: do not
        // re-describe static appearance, only what changes/moves.
        sentences.append(plan.action.trimmingCharacters(in: .whitespacesAndNewlines))

        if let acting = plan.acting, !acting.isEmpty {
            sentences.append(acting)
        }
        if let motion = plan.motion, !motion.isEmpty {
            sentences.append(sentence(motion, prefix: "The motion is"))
        }
        if let lighting = plan.lighting, !lighting.isEmpty {
            sentences.append(sentence(lighting, prefix: "Lighting:"))
        }

        let dialogue = DialogueNormalizer.normalize(plan.dialogue, handling: options.japaneseHandling)
        for line in dialogue {
            sentences.append(DialogueNormalizer.render(line, handling: options.japaneseHandling))
        }

        if !plan.audioCues.isEmpty {
            sentences.append("Audio: " + plan.audioCues.joined(separator: ", ") + ".")
        }

        return sentences
            .map { ensureTerminated($0) }
            .joined(separator: " ")
    }

    /// Suggested frame count for a duration intent (24fps, backend-friendly
    /// 8k+1 frame counts: 25/49/73/97/121...).
    static func frameCount(forSeconds seconds: Double, fps: Int = 24) -> Int {
        let raw = max(1, Int((seconds * Double(fps)).rounded()))
        // Round to nearest 8n+1, clamp to the app's supported range.
        let n = max(0, Int((Double(raw - 1) / 8.0).rounded()))
        return min(241, max(25, n * 8 + 1))
    }

    private static func sentence(_ text: String, prefix: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        // Avoid duplicated subjects ("The camera the camera pans…").
        if lower.hasPrefix("the camera") || lower.hasPrefix("camera")
            || lower.hasPrefix("lighting") || lower.hasPrefix("the motion") {
            return trimmed
        }
        return "\(prefix) \(trimmed)"
    }

    private static func ensureTerminated(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?。！？\"".contains(last) ? trimmed : trimmed + "."
    }
}
