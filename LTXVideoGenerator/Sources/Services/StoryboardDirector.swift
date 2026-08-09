import Foundation

/// Hybrid storyboard pipeline:
///   Short Brief → Director (story bible) → Screenwriter (scene breakdown into
///   4–6s shots) → Continuity Engine (deterministic snapshots) → Prompt
///   Compiler → FilmProject ready for Take generation.
///
/// One local LLM is used for all roles SEQUENTIALLY (never several heavy LLMs
/// resident at once), and it is terminated before any rendering begins.
final class StoryboardDirector {

    enum FailureStage: String, Codable, Equatable {
        case ollamaRequestFailed
        case noResponse
        case jsonExtractionFailed
        case jsonSyntaxInvalid
        case codableDecodeFailed
        case schemaValidationFailed
        case semanticValidationFailed
        case repairFailed
        case retryFailed
        case templateFallback
    }

    struct Diagnostic: Equatable {
        var stage: FailureStage
        var provider: String
        var attempt: Int
        var message: String
    }

    struct ParseResult {
        var draft: StoryboardDraft?
        var failureStage: FailureStage?
        var message: String
        var deterministicRepairAttempted: Bool
    }

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
         "shotScale":"extreme-wide|wide|medium-wide|medium|medium-close-up|close-up|extreme-close-up",
         "angle":"low|eye-level|high|overhead","movement":"static|pan|tilt|dolly|track|handheld",
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
    private let requestedMode: DirectorMode
    /// One original request plus one bounded LLM repair request.
    private let maxRepairAttempts = 1
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var lastProviderModel: String?
    private(set) var lastPlanningMode: String?
    private(set) var lastFallbackReason: String?

    init(providers: [DirectorProvider]? = nil,
         requestedMode: DirectorMode = DirectorMode.selected()) {
        self.requestedMode = requestedMode
        if let providers {
            self.providers = providers
        } else if requestedMode == .basic {
            self.providers = [TemplateStoryboardProvider()]
        } else {
            self.providers = [EnvironmentDirectorProvider(mode: requestedMode), TemplateStoryboardProvider()]
        }
    }

    /// Brief → validated storyboard draft. Provider terminated before return.
    func draft(brief: String) async throws -> (draft: StoryboardDraft, providerName: String) {
        diagnostics = []
        lastProviderModel = nil
        lastPlanningMode = nil
        lastFallbackReason = nil
        var lastError: Error = DirectorError.noProviderAvailable
        var precedingProviderFailed = false
        for provider in providers {
            if let model = provider.modelIdentifier { lastProviderModel = model }
            guard await provider.isAvailable() else {
                record(.ollamaRequestFailed, provider: provider.name, attempt: 0,
                       message: "provider unavailable")
                if let reason = provider.availabilityFailureReason {
                    lastFallbackReason = reason
                }
                precedingProviderFailed = true
                continue
            }
            if precedingProviderFailed, provider.isFallbackProvider {
                if lastFallbackReason == nil {
                    lastFallbackReason = diagnostics.reversed().first {
                        $0.stage != .repairFailed && $0.stage != .retryFailed
                    }?.stage.rawValue
                }
                record(.templateFallback, provider: provider.name, attempt: 0,
                       message: "using deterministic template after structured planning failed")
            }
            do {
                let draft = try await draftWithProvider(provider, brief: brief)
                await provider.terminate()
                lastPlanningMode = provider.isFallbackProvider
                    ? (requestedMode == .basic ? "basic" : "fallback")
                    : "ai"
                if !provider.isFallbackProvider {
                    lastProviderModel = provider.modelIdentifier
                    lastFallbackReason = nil
                }
                return (draft, provider.name)
            } catch {
                await provider.terminate()
                lastError = error
                precedingProviderFailed = true
            }
        }
        throw lastError
    }

    private func draftWithProvider(_ provider: DirectorProvider, brief: String) async throws -> StoryboardDraft {
        var prompt = "BRIEF: \(brief)"
        var lastFailure = ""
        for attempt in 0...maxRepairAttempts {
            let response: String
            do {
                response = try await provider.complete(system: Self.storyboardSystemPrompt, prompt: prompt)
            } catch {
                let stage: FailureStage
                if case DirectorError.noResponse = error {
                    stage = .noResponse
                } else {
                    stage = .ollamaRequestFailed
                }
                record(stage, provider: provider.name, attempt: attempt, message: error.localizedDescription)
                if attempt < maxRepairAttempts {
                    prompt = """
                    The previous request returned no usable response (\(error.localizedDescription)). \
                    Respond with ONLY the JSON object described in the system prompt.
                    BRIEF: \(brief)
                    """
                    continue
                }
                record(.retryFailed, provider: provider.name, attempt: attempt,
                       message: error.localizedDescription)
                throw error
            }
            appendDebugRawResponse(response, provider: provider.name, attempt: attempt)

            let parsed = Self.parseDraftDetailed(from: response, brief: brief)
            if var draft = parsed.draft {
                let repair = Self.repairSemantics(draft, brief: brief)
                draft = repair.draft
                let issues = Self.validate(draft)
                if issues.isEmpty { return draft }
                lastFailure = issues.joined(separator: ", ")
                record(.semanticValidationFailed, provider: provider.name, attempt: attempt,
                       message: lastFailure)
                if repair.changed {
                    record(.repairFailed, provider: provider.name, attempt: attempt,
                           message: "deterministic semantic repair did not produce a valid draft")
                }
            } else {
                lastFailure = parsed.message
                record(parsed.failureStage ?? .codableDecodeFailed, provider: provider.name,
                       attempt: attempt, message: parsed.message)
                if parsed.deterministicRepairAttempted {
                    record(.repairFailed, provider: provider.name, attempt: attempt,
                           message: "deterministic JSON/schema repair did not decode")
                }
            }
            if attempt == maxRepairAttempts {
                record(.retryFailed, provider: provider.name, attempt: attempt,
                       message: lastFailure)
                break
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
        parseDraftDetailed(from: response, brief: "").draft
    }

    /// Direct decode → balanced JSON extraction → deterministic syntax/schema
    /// repair. Semantic repair/validation remains a separate stage.
    static func parseDraftDetailed(from response: String, brief: String) -> ParseResult {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParseResult(draft: nil, failureStage: .noResponse,
                               message: "provider returned empty completion text",
                               deterministicRepairAttempted: false)
        }

        var candidates = [trimmed]
        if let extracted = extractJSONObject(from: trimmed), extracted != trimmed {
            candidates.append(extracted)
        } else if !trimmed.hasPrefix("{") {
            return ParseResult(draft: nil, failureStage: .jsonExtractionFailed,
                               message: "no balanced JSON object found in response",
                               deterministicRepairAttempted: false)
        }

        var lastStage: FailureStage = .jsonSyntaxInvalid
        var lastMessage = "response was not valid JSON"
        var repairAttempted = false

        for candidate in candidates {
            let repairedSyntax = removingTrailingCommas(from: candidate)
            repairAttempted = repairAttempted || repairedSyntax != candidate
            guard let data = repairedSyntax.data(using: .utf8) else { continue }
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: data)
            } catch {
                lastStage = .jsonSyntaxInvalid
                lastMessage = "JSON syntax invalid: \(error.localizedDescription)"
                continue
            }
            guard let dictionary = object as? [String: Any] else {
                lastStage = .schemaValidationFailed
                lastMessage = "top-level JSON value must be an object"
                continue
            }
            do {
                return ParseResult(
                    draft: try JSONDecoder().decode(StoryboardDraft.self, from: data),
                    failureStage: nil,
                    message: "",
                    deterministicRepairAttempted: repairAttempted
                )
            } catch {
                let classified = classifyDecodingError(error)
                lastStage = classified.stage
                lastMessage = classified.message
            }

            let normalized = normalizeSchema(dictionary, brief: brief)
            if !NSDictionary(dictionary: dictionary).isEqual(to: normalized) {
                repairAttempted = true
                do {
                    let normalizedData = try JSONSerialization.data(withJSONObject: normalized)
                    let draft = try JSONDecoder().decode(StoryboardDraft.self, from: normalizedData)
                    return ParseResult(draft: draft, failureStage: nil, message: "",
                                       deterministicRepairAttempted: true)
                } catch {
                    let classified = classifyDecodingError(error)
                    lastStage = classified.stage
                    lastMessage = classified.message
                }
            }
        }
        return ParseResult(draft: nil, failureStage: lastStage, message: lastMessage,
                           deterministicRepairAttempted: repairAttempted)
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

    private static func repairSemantics(_ input: StoryboardDraft, brief: String) -> (draft: StoryboardDraft, changed: Bool) {
        var draft = input
        var changed = false
        if draft.logline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.logline = brief.trimmingCharacters(in: .whitespacesAndNewlines)
            changed = true
        }
        for index in draft.shots.indices {
            if draft.shots[index].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.shots[index].title = "Shot \(index + 1)"
                changed = true
            }
            if let duration = draft.shots[index].durationSeconds, duration < 1 || duration > 10 {
                draft.shots[index].durationSeconds = min(6, max(1, duration))
                changed = true
            }
        }
        return (draft, changed)
    }

    private static func normalizeSchema(_ source: [String: Any], brief: String) -> [String: Any] {
        var root = source
        for wrapper in ["storyboard", "plan"] {
            if root["shots"] == nil, let wrapped = root[wrapper] as? [String: Any] {
                root = wrapped
            }
        }
        if root["shots"] == nil { root["shots"] = root["shotList"] ?? root["scenes"] }
        if (root["logline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            root["logline"] = root["storyline"] ?? root["synopsis"] ?? brief
        }
        if let rawShots = root["shots"] as? [[String: Any]] {
            root["shots"] = rawShots.enumerated().map { index, sourceShot in
                var shot = sourceShot
                if shot["title"] == nil { shot["title"] = shot["name"] ?? "Shot \(index + 1)" }
                if shot["summary"] == nil { shot["summary"] = shot["action"] ?? shot["description"] }
                if shot["durationSeconds"] == nil { shot["durationSeconds"] = shot["duration"] }
                if let text = shot["durationSeconds"] as? String, let value = Double(text) {
                    shot["durationSeconds"] = value
                }
                if shot["shotScale"] == nil { shot["shotScale"] = shot["scale"] }
                if shot["angle"] == nil { shot["angle"] = shot["cameraAngle"] }
                if shot["movement"] == nil { shot["movement"] = shot["cameraMovement"] }
                if shot["audioCues"] == nil { shot["audioCues"] = shot["audio"] }
                return shot
            }
        }
        return root
    }

    private static func classifyDecodingError(_ error: Error) -> (stage: FailureStage, message: String) {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return (.schemaValidationFailed,
                    "required field '\(key.stringValue)' missing at \(codingPath(context.codingPath))")
        case DecodingError.typeMismatch(_, let context):
            return (.codableDecodeFailed,
                    "field type mismatch at \(codingPath(context.codingPath)): \(context.debugDescription)")
        case DecodingError.valueNotFound(_, let context):
            return (.schemaValidationFailed,
                    "required value missing at \(codingPath(context.codingPath))")
        case DecodingError.dataCorrupted(let context):
            return (.codableDecodeFailed,
                    "invalid Codable value at \(codingPath(context.codingPath)): \(context.debugDescription)")
        default:
            return (.codableDecodeFailed, error.localizedDescription)
        }
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        path.isEmpty ? "<root>" : path.map(\.stringValue).joined(separator: ".")
    }

    /// Finds the first balanced JSON object, ignoring braces inside strings.
    private static func extractJSONObject(from text: String) -> String? {
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; continue }
            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
            }
        }
        return nil
    }

    /// Repairs only trailing commas outside JSON strings.
    private static func removingTrailingCommas(from text: String) -> String {
        let characters = Array(text)
        var output = ""
        var inString = false
        var escaped = false
        for index in characters.indices {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; output.append(character); continue }
            if character == "," {
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == "}" || characters[next] == "]" { continue }
            }
            output.append(character)
        }
        return output
    }

    private func record(_ stage: FailureStage, provider: String, attempt: Int, message: String) {
        diagnostics.append(Diagnostic(stage: stage, provider: provider, attempt: attempt, message: message))
        #if DEBUG
        appendDebugLine("stage=\(stage.rawValue) provider=\(provider) attempt=\(attempt) message=\(message)")
        #endif
    }

    /// Raw completions are written only by Debug builds to a temporary file;
    /// Release builds retain no prompt/response content.
    private func appendDebugRawResponse(_ response: String, provider: String, attempt: Int) {
        #if DEBUG
        appendDebugLine("RAW provider=\(provider) attempt=\(attempt) chars=\(response.count)\n\(response)")
        #endif
    }

    #if DEBUG
    private static var debugLogURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXVideoGenerator-storyboard-director-debug.log")
    }

    private func appendDebugLine(_ text: String) {
        let entry = "\n=== \(Date()) ===\n\(text)\n"
        guard let data = entry.data(using: .utf8) else { return }
        let url = Self.debugLogURL
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber, size.intValue > 512_000 {
            try? data.write(to: url, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
    #endif

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
        project.directorProvider = providerName
        project.directorModel = lastProviderModel
        project.planningMode = lastPlanningMode
        project.fallbackReason = lastFallbackReason
        project.requestedDirectorMode = requestedMode.rawValue
        project.effectiveDirectorMode = providerName == "template"
            ? DirectorMode.basic.rawValue
            : DirectorMode.localAI.rawValue
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

/// Deterministic no-LLM storyboard fallback. Explicit first/next/final shot
/// cues are decomposed without inventing story content; other briefs remain a
/// single safe shot.
final class TemplateStoryboardProvider: DirectorProvider {
    let name = "template"
    let isFallbackProvider = true

    func isAvailable() async -> Bool { true }

    func complete(system: String, prompt: String) async throws -> String {
        let brief: String
        if let range = prompt.range(of: "BRIEF:") {
            brief = String(prompt[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            brief = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let beats = Self.explicitBeats(from: brief)
        let scales = ["wide", "medium", "close-up", "medium-close-up"]
        let movements = ["track", "dolly", "dolly", "static"]
        let shots = beats.enumerated().map { index, beat in
            StoryboardDirector.ShotPlanDraft(
                title: beats.count == 1 ? "Shot 1" : "Shot \(index + 1)",
                summary: beat,
                durationSeconds: 5,
                shotScale: scales[index % scales.count],
                angle: "eye-level",
                movement: movements[index % movements.count],
                lighting: "soft natural lighting",
                dialogue: [],
                audioCues: [],
                explicitChanges: []
            )
        }
        let draft = StoryboardDirector.StoryboardDraft(
            logline: brief,
            synopsis: brief,
            setting: "",
            tone: "",
            initialState: nil,
            shots: shots
        )
        let data = try JSONEncoder().encode(draft)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func terminate() async {}

    static func explicitBeats(from brief: String) -> [String] {
        let lines = brief.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let markers = [
            "最初のショット", "次のショット", "最後のショット",
            "first shot", "next shot", "final shot", "last shot",
        ]
        var beats: [String] = []
        var current: String?
        for line in lines {
            let lower = line.lowercased()
            if markers.contains(where: { lower.contains($0) }) {
                if let current { beats.append(current) }
                current = line
            } else if let existing = current {
                current = existing + " " + line
            }
        }
        if let current { beats.append(current) }
        return beats.count >= 2 ? Array(beats.prefix(8)) : [brief]
    }
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
