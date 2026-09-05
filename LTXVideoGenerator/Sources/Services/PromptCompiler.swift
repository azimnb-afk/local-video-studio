import Foundation

enum JapaneseDialogueHandling: String, Codable, CaseIterable {
    case native          // keep Japanese as written (default)
    case romanizedFallback // native first, romanization appended when available
    case keepOriginal    // never touch dialogue at all
}

/// Lightweight product policy for audio generated inside an individual shot.
/// Global BGM remains a separate Final Audio concern.
enum PerShotAudioPolicy: Equatable {
    case unspecified
    case naturalProductionSoundNoMusic

    static let directorInstruction = """
    PER-SHOT AUDIO POLICY
    Do not plan background music, a soundtrack, a musical score, instrumental music, melodic accompaniment, a music bed, or an underscore for any individual shot.
    Audio must contain only diegetic production sound: spoken dialogue and human vocalization, environmental ambience, room tone, footsteps, foley, mechanical or environmental sounds, and scene-appropriate sound effects.
    If the brief requests music, defer that request to the separate global Final Audio layer; do not place it in a shot's audioCues.
    """

    /// One renderer-facing policy shared by every Director workflow and both
    /// generation backends. Keep this as one compact block: repeating negative
    /// instructions can make prompt adherence worse rather than better.
    static let generationGuard = "Audio policy: No music. No background music. No soundtrack. No musical score. No instrumental music. No melodic accompaniment. Audio contains only diegetic production sound: spoken dialogue, human vocalization, environmental ambience, room tone, footsteps, foley, mechanical and environmental sounds, and scene-specific sound effects."

    private static let legacyGenerationGuard = "Audio policy: no background music or musical score. Keep synchronized natural production sound: spoken dialogue, environmental ambience, footsteps, foley and scene-appropriate sound effects."

    private static let explicitMusicTerms = [
        "background music", "bgm", "musical score", "cinematic score",
        "background score", "soundtrack", "underscore", "music bed",
        "orchestral music", "instrumental music", "melodic accompaniment",
        "musical accompaniment"
    ]

    func filteredAudioCues(_ cues: [String]) -> [String] {
        guard self == .naturalProductionSoundNoMusic else { return cues }
        return cues.filter { cue in
            let normalized = cue.lowercased()
            let containsMusicWord = normalized.range(
                of: #"\bmusic\b"#, options: .regularExpression) != nil
            return !containsMusicWord
                && !Self.explicitMusicTerms.contains { normalized.contains($0) }
        }
    }

    /// Basic Director may copy a brief sentence directly into visible action.
    /// Drop complete sentences containing an explicit non-diegetic music
    /// direction; never rewrite fragments inside a visual sentence. Spoken
    /// dialogue is a separate structured field and remains untouched.
    func filteredAction(_ action: String) -> String {
        guard self == .naturalProductionSoundNoMusic else { return action }
        let sentenceSeparated = action.replacingOccurrences(
            of: "([.!?。！？])\\s+",
            with: "$1\n",
            options: .regularExpression)
        let sentences = sentenceSeparated.components(separatedBy: .newlines)
        return sentences.filter { sentence in
            let normalized = sentence.lowercased()
            return !Self.explicitMusicTerms.contains { normalized.contains($0) }
        }.joined(separator: " ")
    }

    func applyingPromptGuard(to prompt: String) -> String {
        guard self == .naturalProductionSoundNoMusic else { return prompt }
        var base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Upgrade the previous weaker guard and make repeated compilation or
        // queue preflight idempotent. This does not treat a user's incidental
        // phrase "no background music" as proof that the product policy was
        // already applied.
        for knownGuard in [Self.generationGuard, Self.legacyGenerationGuard] {
            base = base.replacingOccurrences(
                of: knownGuard, with: "", options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Legacy projects and an LLM enhancer may carry a complete explicit
        // music direction. Remove only those complete sentences; visual words
        // such as "cinematic lighting" remain untouched.
        base = filteredAction(base).trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? Self.generationGuard : base + " " + Self.generationGuard
    }

    /// Prompt enhancement may rewrite the canonical prompt. Preserve an
    /// already-selected product policy without imposing it on Direct Generate.
    static func preservingPolicy(from canonicalPrompt: String, in candidatePrompt: String) -> String {
        let normalized = canonicalPrompt.lowercased()
        let selected: PerShotAudioPolicy = normalized.contains("audio policy:")
            && normalized.contains("no background music")
            ? .naturalProductionSoundNoMusic
            : .unspecified
        return selected.applyingPromptGuard(to: candidatePrompt)
    }
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

/// Converts persisted story pacing into one compact renderer-facing sentence.
/// It is prompt guidance only: generation timing and backend settings remain
/// owned by the existing settings resolver.
enum MotionTempoPromptPolicy {
    static func instruction(
        motionTempo: MotionTempo,
        cameraTempo: CameraTempo,
        playbackStyle: PlaybackStyle
    ) -> String {
        let playback: String
        switch playbackStyle {
        case .realTime: playback = "real-time playback"
        case .slowMotion: playback = "slow-motion playback"
        case .fastMotion: playback = "fast-motion playback"
        }

        let subject: String
        switch motionTempo {
        case .slow: subject = "deliberately slow subject movement"
        case .normal: subject = "natural subject movement at normal speed"
        case .fast: subject = "quick subject movement"
        }

        let camera: String
        switch cameraTempo {
        case .static: camera = "a static camera"
        case .slow: camera = "slow, measured camera movement"
        case .normal: camera = "camera movement at a natural steady pace"
        case .fast: camera = "quick camera movement"
        }

        return "\(playback); \(subject); \(camera)"
    }
}

/// Compiles a structured OneShotPlan into a single flowing LTX prompt:
/// chronological, present tense, visible action, camera, motion, lighting,
/// dialogue and audio in one description (official LTX prompt guidance).
enum PromptCompiler {

    /// Historical, production-wide default ceiling (10.04s @ 24fps).
    public static let defaultMaximumFrameCount = 241
    /// Explicit One Shot ceiling for LTX models (15.04s @ 24fps).
    public static let oneShotMaximumFrameCount = 361

    struct Options {
        var isImageToVideo: Bool = false
        var japaneseHandling: JapaneseDialogueHandling = .native
        var perShotAudioPolicy: PerShotAudioPolicy = .unspecified
    }

    static func compile(plan: OneShotPlan, options: Options = Options()) -> String {
        var sentences: [String] = []

        // Camera first: it frames everything that follows.
        sentences.append(formatCameraSentence(plan.camera))

        // For I2V the source image is the visual source of truth: do not
        // re-describe static appearance, only what changes/moves.
        sentences.append(options.perShotAudioPolicy.filteredAction(
            plan.action.trimmingCharacters(in: .whitespacesAndNewlines)
        ))

        if let acting = plan.acting, !acting.isEmpty {
            sentences.append(acting)
        }
        if let motion = plan.motion, !motion.isEmpty {
            sentences.append(formatMotionSentence(motion))
        }
        if let endState = plan.endState?.trimmingCharacters(in: .whitespacesAndNewlines), !endState.isEmpty {
            // Stated once, plainly: this is where the continuous action lands,
            // not a second description competing with the action sentence.
            sentences.append("By the end of the shot: \(endState)")
        }
        if let lighting = plan.lighting, !lighting.isEmpty {
            sentences.append(formatLightingSentence(lighting))
        }

        let dialogue = DialogueNormalizer.normalize(plan.dialogue, handling: options.japaneseHandling)
        for line in dialogue {
            sentences.append(DialogueNormalizer.render(line, handling: options.japaneseHandling))
        }

        let audioCues = options.perShotAudioPolicy.filteredAudioCues(plan.audioCues)
        if !audioCues.isEmpty {
            sentences.append("Audio: " + audioCues.joined(separator: ", ") + ".")
        }

        let compiled = sentences
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ensureTerminated($0) }
            .joined(separator: " ")
        return options.perShotAudioPolicy.applyingPromptGuard(to: compiled)
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
    /// 8k+1 frame counts: 25/49/73/97/121... up to maximumFrameCount).
    /// Default maximum is 241 frames (10.04s).
    static func frameCount(
        forSeconds seconds: Double,
        fps: Int = 24,
        maximumFrameCount: Int = defaultMaximumFrameCount
    ) -> Int {
        let raw = max(1, Int((seconds * Double(fps)).rounded()))
        // Round to nearest 8n+1, clamp to the requested supported range.
        let n = max(0, Int((Double(raw - 1) / 8.0).rounded()))
        return min(maximumFrameCount, max(25, n * 8 + 1))
    }

    private static func formatCameraSentence(_ camera: String) -> String {
        let trimmed = camera.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("the camera") || lower.hasPrefix("camera") {
            return trimmed
        }
        if lower.hasPrefix("static") {
            return "The camera holds a \(trimmed)"
        }
        let verbs = ["pans", "pan", "tilts", "tilt", "tracks", "track", "zooms", "zoom", "moves", "move", "holds", "hold", "rotates", "rotate", "follows", "follow", "circles", "dollies", "dolly", "sweeps", "glides", "drifts", "pushes", "pulls"]
        let firstWord = lower.components(separatedBy: .whitespaces).first ?? ""
        if verbs.contains(firstWord) {
            return "The camera \(trimmed)"
        }
        return "The camera captures a \(trimmed)"
    }

    private static func formatMotionSentence(_ motion: String) -> String {
        let trimmed = motion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("the motion is") || lower.hasPrefix("motion is") {
            return trimmed
        }
        if lower.hasPrefix("the motion") || lower.hasPrefix("motion") {
            return trimmed
        }
        if lower == "natural, continuous motion" || lower == "natural, continuous" {
            return "The motion is natural and continuous"
        }
        if lower.hasSuffix("motion") {
            let withoutSuffix = trimmed.dropLast(6).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ",-")))
            return "The motion is \(withoutSuffix)"
        }
        return "The motion is \(trimmed)"
    }

    private static func formatLightingSentence(_ lighting: String) -> String {
        let trimmed = lighting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("lighting:") || lower.hasPrefix("lighting is") || lower.hasPrefix("lighting") {
            return trimmed
        }
        return "Lighting: \(trimmed)"
    }

    private static func ensureTerminated(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?。！？\"".contains(last) ? trimmed : trimmed + "."
    }
}

/// Shared Storyboard/Hybrid character propagation boundary.
enum CharacterPromptPipeline {
    /// Recompiles one persisted shot after the user edits its Action or
    /// CameraPlan in Auto Movie Plan Preview. The renderer consumes
    /// `compiledPrompt`, not the preview fields, so updating just the UI/model
    /// would be a false edit. This rebuilds the same base prompt that Director
    /// planning produced, then applies the existing Character Bible pipeline.
    ///
    /// Intentionally does not call any continuity planner or mutate continuity
    /// metadata: Phase A edits wording and framing only, never Cut/Continue or
    /// the selected starting-image source.
    static func recompilePlan(project: inout FilmProject, shotIndex: Int) {
        guard project.shots.indices.contains(shotIndex) else { return }
        var shot = project.shots[shotIndex]
        let snapshot: ContinuitySnapshot
        if let before = shot.continuityBefore,
           let after = try? ContinuityEngine.apply(changes: shot.explicitChanges, to: before) {
            snapshot = after
        } else {
            snapshot = shot.continuityBefore ?? ContinuitySnapshot()
        }
        let plan = OneShotPlan(
            camera: "\(shot.camera.shotScale) shot, \(shot.camera.angle) angle, \(shot.camera.movement) camera",
            action: shot.summary,
            motion: MotionTempoPromptPolicy.instruction(
                motionTempo: shot.motionTempo,
                cameraTempo: shot.cameraTempo,
                playbackStyle: shot.playbackStyle
            ),
            lighting: snapshot.lighting,
            dialogue: shot.audio.dialogue.map {
                OneShotPlan.DialogueLine(
                    speaker: $0.speaker, text: $0.text,
                    language: $0.language, romanization: $0.romanization)
            },
            audioCues: shot.audio.sfx,
            durationIntentSeconds: shot.durationSeconds,
            endState: shot.endStateSummary
        )
        let options = PromptCompiler.Options(
            japaneseHandling: JapaneseDialogueHandling(rawValue: project.settings.japaneseHandling) ?? .native,
            perShotAudioPolicy: .naturalProductionSoundNoMusic)
        let compiled = MiniMaxH3Configuration.isMiniMaxH3(modelID: project.settings.modelID)
            ? MiniMaxH3PromptCompiler.compile(
                plan: plan,
                isImageToVideo: shot.continuityMode == .continueFromPrevious
                    || shot.startingImageReferenceAssetID != nil,
                japaneseHandling: options.japaneseHandling,
                perShotAudioPolicy: options.perShotAudioPolicy)
            : PromptCompiler.compile(plan: plan, options: options)
        let context = ContinuityEngine.promptContext(for: snapshot, bible: project.characterBible)
        shot.baseCompiledPrompt = context.isEmpty ? compiled : context + " " + compiled
        project.shots[shotIndex] = shot
        recompileCharacterContext(project: &project, shotIndex: shotIndex)
    }

    static func recompile(project: inout FilmProject) {
        for index in project.shots.indices {
            recompileCharacterContext(project: &project, shotIndex: index)
        }
    }

    private static func recompileCharacterContext(project: inout FilmProject, shotIndex: Int) {
        guard project.shots.indices.contains(shotIndex) else { return }
        var shot = project.shots[shotIndex]
        let base = PerShotAudioPolicy.naturalProductionSoundNoMusic.applyingPromptGuard(
            to: shot.baseCompiledPrompt ?? shot.compiledPrompt
        )
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
        project.shots[shotIndex] = shot
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

// ============================================================================
// ONE SHOT DURATION POLICY
// ============================================================================

/// Authoritative duration and frame limit policy for One Shot generation.
///
/// Encapsulates model-specific capability ceilings for single-shot generation
/// so UI, Preflight (AutoQualityEngine), and Execution (LocalDirector) share
/// exactly one single source of truth.
enum OneShotDurationPolicy {

    /// Maximum user-facing selectable duration in seconds.
    static func maximumSelectableSeconds(for modelID: String) -> Double {
        if MiniMaxH3Configuration.isMiniMaxH3(modelID: modelID) {
            return Double(Int(MiniMaxH3DurationPolicy.maximumDurationSeconds.rounded(.down)))
        }
        return 15.0
    }

    /// Technical maximum frame ceiling for single-shot LTX generation (361 frames @ 24fps).
    /// Returns `nil` for MiniMax H3, allowing H3's standalone chain policy to govern.
    static func maximumFrameCount(for modelID: String) -> Int? {
        if MiniMaxH3Configuration.isMiniMaxH3(modelID: modelID) {
            return nil
        }
        return PromptCompiler.oneShotMaximumFrameCount
    }
}
