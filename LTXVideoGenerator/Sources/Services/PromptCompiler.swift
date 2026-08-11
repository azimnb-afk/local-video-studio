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

    /// Compact visual-only CharacterBible context. Personality and speaking
    /// style stay available to planning, but are not dumped into every render
    /// prompt. Each character is isolated in its own sentence group.
    static func compile(characters: [ContinuityEngine.ResolvedCharacterState]) -> String {
        characters.enumerated().map { index, character in
            var parts = ["CHARACTER \(index + 1): \(character.name)."]
            let appearance = character.appearance
            if !appearance.faceDescription.trimmed.isEmpty {
                parts.append("Face: \(appearance.faceDescription.trimmed).")
            }
            if !appearance.hair.trimmed.isEmpty { parts.append("Hair: \(appearance.hair.trimmed).") }
            if !appearance.eyes.trimmed.isEmpty { parts.append("Eyes: \(appearance.eyes.trimmed).") }
            if !appearance.ageImpression.trimmed.isEmpty {
                parts.append("Age impression: \(appearance.ageImpression.trimmed).")
            }
            if !appearance.build.trimmed.isEmpty { parts.append("Build: \(appearance.build.trimmed).") }
            if !appearance.complexion.trimmed.isEmpty {
                parts.append("Complexion: \(appearance.complexion.trimmed).")
            }
            if !appearance.distinguishingFeatures.trimmed.isEmpty {
                parts.append("Distinctive features: \(appearance.distinguishingFeatures.trimmed).")
            }
            if !character.currentCostume.trimmed.isEmpty {
                parts.append("Current costume: \(character.currentCostume.trimmed).")
            }
            if !character.accessories.trimmed.isEmpty {
                parts.append("Accessories: \(character.accessories.trimmed).")
            }
            if !character.lockedTraits.isEmpty {
                let locks = character.lockedTraits
                    .sorted { $0.rawValue < $1.rawValue }
                    .map(\.displayName)
                    .joined(separator: ", ")
                parts.append("Keep these traits visually consistent across shots: \(locks).")
            }
            if !character.continuityNotes.trimmed.isEmpty {
                parts.append("Continuity: \(character.continuityNotes.trimmed.prefixText(220)).")
            }
            return parts.joined(separator: " ")
        }.joined(separator: " ")
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

/// Shared Storyboard/Hybrid character propagation boundary.
enum CharacterPromptPipeline {
    static func recompile(project: inout FilmProject) {
        for index in project.shots.indices {
            var shot = project.shots[index]
            let base = shot.baseCompiledPrompt ?? shot.compiledPrompt
            shot.baseCompiledPrompt = base
            let promptSnapshot: ContinuitySnapshot?
            if let before = shot.continuityBefore,
               let after = try? ContinuityEngine.apply(changes: shot.explicitChanges, to: before) {
                promptSnapshot = after
            } else {
                promptSnapshot = shot.continuityBefore
            }
            let resolved = ContinuityEngine.resolveCharacters(
                ids: shot.characterIDs,
                bible: project.characterBible,
                snapshot: promptSnapshot
            )
            let characterContext: String
            switch ContinuationPromptPolicy.style(for: shot.continuityMode) {
            case .descriptive:
                characterContext = PromptCompiler.compile(characters: resolved)
            case .changeFocused:
                // The previous shot's last frame already shows who this is and
                // what they are wearing. Restating it makes the text argue with
                // the picture, and the text wins over a few seconds (D-071).
                let before = ContinuityEngine.resolveCharacters(
                    ids: shot.characterIDs,
                    bible: project.characterBible,
                    snapshot: shot.continuityBefore
                )
                characterContext = ContinuationPromptPolicy.changeFocusedContext(
                    before: before, after: resolved)
            }
            shot.compiledPrompt = characterContext.isEmpty ? base : characterContext + " " + base
            project.shots[index] = shot
        }
    }
}

extension FilmProject {
    mutating func upsertCharacter(_ character: BibleCharacter) {
        // Normalize old name-keyed snapshots before a rename makes the old
        // display name unavailable. Stable Shot references never change.
        for index in shots.indices {
            if let snapshot = shots[index].continuityBefore {
                shots[index].continuityBefore = ContinuityEngine.normalizedCharacterReferences(
                    in: snapshot, bible: characterBible
                )
            }
        }
        if let index = characterBible.characters.firstIndex(where: { $0.id == character.id }) {
            characterBible.characters[index] = character
        } else {
            characterBible.characters.append(character)
        }
        CharacterPromptPipeline.recompile(project: &self)
        touch()
    }

    mutating func removeCharacter(id: UUID) {
        characterBible.characters.removeAll { $0.id == id }
        for index in shots.indices {
            shots[index].characterIDs.removeAll { $0 == id }
        }
        sanitizeStartingImageReferences()
        CharacterPromptPipeline.recompile(project: &self)
        touch()
    }

    mutating func setCharacter(_ id: UUID, present: Bool, inShot shotID: UUID) {
        guard characterBible.character(id: id) != nil,
              let shotIndex = shots.firstIndex(where: { $0.id == shotID }) else { return }
        if present {
            if !shots[shotIndex].characterIDs.contains(id) { shots[shotIndex].characterIDs.append(id) }
        } else {
            shots[shotIndex].characterIDs.removeAll { $0 == id }
        }
        CharacterPromptPipeline.recompile(project: &self)
        touch()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func prefixText(_ limit: Int) -> String {
        count <= limit ? self : String(prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
