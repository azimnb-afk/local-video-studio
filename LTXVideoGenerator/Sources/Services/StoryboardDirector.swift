import Foundation

/// Hybrid storyboard pipeline:
///   Short Brief → Director (story bible) → Screenwriter (scene breakdown into
///   4–6s shots) → Continuity Engine (deterministic snapshots) → Prompt
///   Compiler → FilmProject ready for Take generation.
///
/// One local LLM is used for all roles SEQUENTIALLY (never several heavy LLMs
/// resident at once), and it is terminated before any rendering begins.
final class StoryboardDirector {

    struct ShotPlanDraft: Codable, Equatable {
        var title: String
        var summary: String
        var durationSeconds: Double?
        var shotScale: String?
        var angle: String?
        var movement: String?
        var lighting: String?
        var dialogue: [OneShotPlan.DialogueLine]?
        var audioCues: [String]?
        var explicitChanges: [String]?
    }

    struct StoryboardDraft: Codable, Equatable {
        var logline: String
        var synopsis: String?
        var setting: String?
        var tone: String?
        var initialState: ContinuitySnapshot?
        var shots: [ShotPlanDraft]
    }

    static let storyboardSystemPrompt = """
    You are a film production team (director, screenwriter, cinematographer,
    continuity supervisor) planning a short film as a sequence of 4-6 second
    continuous shots. Respond with ONLY a JSON object:
    {
      "logline": "one sentence",
      "synopsis": "short paragraph",
      "setting": "where/when",
      "tone": "mood",
      "initialState": {"location":"...","timeOfDay":"...","weather":"...","lighting":"...",
                       "characterOutfit":{"Name":"outfit"},"characterPosition":{},"characterCondition":{},
                       "props":[],"propOwner":{},"wetness":{},"injuries":{},"dialogueState":"","storyState":""},
      "shots": [
        {"title":"...","summary":"present-tense visible action","durationSeconds":5,
         "shotScale":"wide|medium|close-up","angle":"low|eye-level|high","movement":"static|pan|dolly|track",
         "lighting":"...","dialogue":[{"speaker":"Name","text":"line"}],"audioCues":["..."],
         "explicitChanges":["location=...","outfit:Name=...","prop+:item"]}
      ]
    }
    Vary shot scale/angle/movement between consecutive shots. explicitChanges
    uses only these directives: location=, timeOfDay=, weather=, lighting=,
    outfit:Name=, position:Name=, condition:Name=, wet:Name=, injury:Name=,
    prop+:item, prop-:item, propOwner:item=Name, dialogueState=, storyState=.
    2 to 8 shots. Keep user-provided dialogue verbatim.
    """

    private let providers: [DirectorProvider]
    private let maxRepairAttempts = 2

    init(providers: [DirectorProvider]? = nil) {
        self.providers = providers ?? [OllamaDirectorProvider(), TemplateStoryboardProvider()]
    }

    /// Brief → validated storyboard draft. Provider terminated before return.
    func draft(brief: String) async throws -> (draft: StoryboardDraft, providerName: String) {
        var lastError: Error = DirectorError.noProviderAvailable
        for provider in providers {
            guard await provider.isAvailable() else { continue }
            do {
                let draft = try await draftWithProvider(provider, brief: brief)
                await provider.terminate()
                return (draft, provider.name)
            } catch {
                await provider.terminate()
                lastError = error
            }
        }
        throw lastError
    }

    private func draftWithProvider(_ provider: DirectorProvider, brief: String) async throws -> StoryboardDraft {
        var prompt = "BRIEF: \(brief)"
        var lastFailure = ""
        for _ in 0...maxRepairAttempts {
            let response = try await provider.complete(system: Self.storyboardSystemPrompt, prompt: prompt)
            if let draft = Self.parseDraft(from: response) {
                let issues = Self.validate(draft)
                if issues.isEmpty { return draft }
                lastFailure = issues.joined(separator: ", ")
            } else {
                lastFailure = "response was not valid JSON"
            }
            prompt = """
            Your previous response was invalid (\(lastFailure)). \
            Respond again with ONLY the JSON object described in the system prompt.
            BRIEF: \(brief)
            """
        }
        throw DirectorError.planValidationFailed([lastFailure])
    }

    static func parseDraft(from response: String) -> StoryboardDraft? {
        if let data = response.data(using: .utf8),
           let draft = try? JSONDecoder().decode(StoryboardDraft.self, from: data) {
            return draft
        }
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"), start < end,
              let data = String(response[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StoryboardDraft.self, from: data)
    }

    static func validate(_ draft: StoryboardDraft) -> [String] {
        var issues: [String] = []
        if draft.logline.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("logline empty") }
        if draft.shots.isEmpty { issues.append("no shots") }
        if draft.shots.count > 12 { issues.append("too many shots (max 12)") }
        for (i, shot) in draft.shots.enumerated() {
            if shot.summary.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("shot \(i + 1) summary empty")
            }
            if let d = shot.durationSeconds, d < 1 || d > 10 {
                issues.append("shot \(i + 1) duration out of range [1,10]")
            }
        }
        return issues
    }

    /// Materializes a FilmProject: continuity chain, per-shot compiled prompts,
    /// monotony/continuity validation results attached as notes.
    func makeProject(
        title: String,
        brief: String,
        settings: ProjectSettings = ProjectSettings()
    ) async throws -> (project: FilmProject, violations: [ContinuityEngine.Violation], providerName: String) {
        let (draft, providerName) = try await self.draft(brief: brief)

        var project = FilmProject(title: title)
        project.settings = settings
        project.storyBible = StoryBible(
            logline: draft.logline,
            synopsis: draft.synopsis ?? "",
            setting: draft.setting ?? "",
            tone: draft.tone ?? ""
        )
        // Character bible seeded from initial state outfits.
        var bible = CharacterBible()
        for (name, outfit) in (draft.initialState?.characterOutfit ?? [:]) {
            bible.characters.append(CharacterBibleEntry(name: name, wardrobe: outfit))
        }
        project.characterBible = bible

        var violations: [ContinuityEngine.Violation] = []
        var state = draft.initialState ?? ContinuitySnapshot()
        let japaneseHandling = JapaneseDialogueHandling(rawValue: settings.japaneseHandling) ?? .native

        for (index, shotDraft) in draft.shots.enumerated() {
            var shot = Shot(index: index, title: shotDraft.title, summary: shotDraft.summary)
            shot.durationSeconds = min(6, max(1, shotDraft.durationSeconds ?? 5))
            shot.camera = CameraPlan(
                shotScale: shotDraft.shotScale ?? "medium",
                angle: shotDraft.angle ?? "eye-level",
                movement: shotDraft.movement ?? "static"
            )
            shot.audio = AudioPlan(
                dialogue: (shotDraft.dialogue ?? []).map {
                    ShotDialogueLine(speaker: $0.speaker, text: $0.text, language: $0.language, romanization: $0.romanization)
                },
                sfx: shotDraft.audioCues ?? []
            )
            shot.continuityBefore = state
            shot.explicitChanges = shotDraft.explicitChanges ?? []

            // Deterministic transition; malformed directives surface as violations.
            let nextState: ContinuitySnapshot
            do {
                nextState = try ContinuityEngine.apply(changes: shot.explicitChanges, to: state)
            } catch {
                violations.append(ContinuityEngine.Violation(
                    severity: .error,
                    message: "Shot \(index + 1): malformed continuity directive (\(error))"
                ))
                nextState = state
            }
            violations.append(contentsOf: ContinuityEngine.validate(
                previous: state, next: nextState, explicitChanges: shot.explicitChanges
            ))

            // Compile the shot prompt: continuity context + one-shot plan.
            let plan = OneShotPlan(
                camera: "\(shot.camera.shotScale) shot, \(shot.camera.angle) angle, \(shot.camera.movement) camera",
                action: shot.summary,
                acting: nil,
                motion: nil,
                lighting: shotDraft.lighting ?? nextState.lighting,
                dialogue: (shotDraft.dialogue ?? []),
                audioCues: shotDraft.audioCues ?? [],
                durationIntentSeconds: shot.durationSeconds
            )
            let context = ContinuityEngine.promptContext(for: nextState)
            let compiled = PromptCompiler.compile(
                plan: plan,
                options: PromptCompiler.Options(japaneseHandling: japaneseHandling)
            )
            shot.compiledPrompt = context.isEmpty ? compiled : context + " " + compiled

            project.shots.append(shot)
            state = nextState
        }

        violations.append(contentsOf: ContinuityEngine.monotonyWarnings(shots: project.shots))
        return (project, violations, providerName)
    }
}

/// Deterministic no-LLM storyboard fallback: single shot from the brief.
final class TemplateStoryboardProvider: DirectorProvider {
    let name = "template"

    func isAvailable() async -> Bool { true }

    func complete(system: String, prompt: String) async throws -> String {
        let brief: String
        if let range = prompt.range(of: "BRIEF:") {
            brief = String(prompt[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            brief = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let draft = StoryboardDirector.StoryboardDraft(
            logline: brief,
            synopsis: brief,
            setting: "",
            tone: "",
            initialState: nil,
            shots: [
                StoryboardDirector.ShotPlanDraft(
                    title: "Shot 1",
                    summary: brief,
                    durationSeconds: 5,
                    shotScale: "medium",
                    angle: "eye-level",
                    movement: "static",
                    lighting: "soft natural lighting",
                    dialogue: [],
                    audioCues: [],
                    explicitChanges: []
                ),
            ]
        )
        let data = try JSONEncoder().encode(draft)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func terminate() async {}
}

/// Thin Hybrid orchestration layer. Planning remains in StoryboardDirector;
/// generation remains in TakeGenerationCoordinator/GenerationService. When
/// the no-LLM template can only return one shot, this expands it into a
/// deterministic 4–6 second review sequence so Hybrid still provides real
/// shot splitting without inventing another inference backend.
final class HybridProjectCoordinator {
    private let director: StoryboardDirector

    init(director: StoryboardDirector = StoryboardDirector()) {
        self.director = director
    }

    func makeProject(
        title: String,
        brief: String,
        settings: ProjectSettings
    ) async throws -> (project: FilmProject, violations: [ContinuityEngine.Violation], providerName: String) {
        var (project, violations, providerName) = try await director.makeProject(
            title: title, brief: brief, settings: settings
        )
        let target = min(60, max(5, settings.targetDurationSeconds ?? 20))
        let desiredCount = min(12, max(1, Int(ceil(target / 5))))
        guard project.shots.count == 1, desiredCount > 1, let source = project.shots.first else {
            project.workflowMode = "hybrid"
            return (project, violations, providerName)
        }

        let scales = ["wide", "medium", "close-up", "medium"]
        let movements = ["dolly", "track", "static", "pan"]
        let duration = min(6, max(4, target / Double(desiredCount)))
        var shots: [Shot] = []
        var state = source.continuityBefore ?? ContinuitySnapshot()
        for index in 0..<desiredCount {
            var shot = source
            shot.id = UUID()
            shot.index = index
            shot.title = "Shot \(index + 1)"
            shot.summary = "\(source.summary) — story beat \(index + 1) of \(desiredCount)."
            shot.durationSeconds = duration
            shot.camera.shotScale = scales[index % scales.count]
            shot.camera.movement = movements[index % movements.count]
            shot.continuityBefore = state
            shot.takes = []
            shot.selectedTakeID = nil

            let plan = OneShotPlan(
                camera: "\(shot.camera.shotScale) shot, \(shot.camera.angle) angle, \(shot.camera.movement) camera",
                action: shot.summary,
                lighting: state.lighting,
                dialogue: shot.audio.dialogue.map {
                    OneShotPlan.DialogueLine(speaker: $0.speaker, text: $0.text, language: $0.language, romanization: $0.romanization)
                },
                audioCues: shot.audio.sfx,
                durationIntentSeconds: duration
            )
            let context = ContinuityEngine.promptContext(for: state)
            let compiled = PromptCompiler.compile(plan: plan)
            shot.compiledPrompt = context.isEmpty ? compiled : context + " " + compiled
            shots.append(shot)

            if let next = try? ContinuityEngine.apply(changes: shot.explicitChanges, to: state) {
                state = next
            }
        }
        project.shots = shots
        project.workflowMode = "hybrid"
        violations.append(contentsOf: ContinuityEngine.monotonyWarnings(shots: shots))
        return (project, violations, providerName)
    }
}
