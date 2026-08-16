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
        var motionTempo: String?
        var cameraTempo: String?
        var playbackStyle: String?
        var lighting: String?
        var dialogue: [OneShotPlan.DialogueLine]?
        var audioCues: [String]?
        var explicitChanges: [String]?
        /// Local AI should return stable UUID strings. String is used at the
        /// transport boundary so unknown IDs/names can be repaired safely.
        var characterIDs: [String]?
        /// Narrow compatibility fallback for observed name-based output.
        var characterNames: [String]?
        /// "continue" when this shot is a direct physical continuation of the
        /// previous one, "cut" for a new scene. Absent/unknown values resolve
        /// conservatively to a cut.
        var continuity: String?
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
    continuity supervisor) planning a short film as a sequence of concise,
    continuous shots. When the user provides a TOTAL MOVIE DURATION TARGET,
    treat it as authoritative for the sum of all shots. Respond with ONLY a JSON object:
    {
      "logline": "one sentence",
      "synopsis": "short paragraph",
      "setting": "where/when",
      "tone": "mood",
      "initialState": {"location":"...","timeOfDay":"...","weather":"...","lighting":"...",
                       "characterOutfit":{"CharacterID":"outfit"},"characterPosition":{},"characterCondition":{},
                       "props":[],"propOwner":{},"wetness":{},"injuries":{},"dialogueState":"","storyState":""},
      "shots": [
        {"title":"...","summary":"present-tense visible action","durationSeconds":5,
         "shotScale":"extreme-wide|wide|medium-wide|medium|medium-close-up|close-up|extreme-close-up",
         "angle":"low|eye-level|high|overhead","movement":"static|pan|tilt|dolly|track|handheld",
         "motionTempo":"slow|normal|fast","cameraTempo":"static|slow|normal|fast",
         "playbackStyle":"realTime|slowMotion|fastMotion",
         "lighting":"...","dialogue":[{"speaker":"Name","text":"line"}],"audioCues":["..."],
         "explicitChanges":["location=...","outfit:CharacterID=...","prop+:item"],
         "characterIDs":["exact-character-uuid"],
         "continuity":"continue|cut"}
      ]
    }
    Vary shot scale/angle/movement between consecutive shots. explicitChanges
    uses only these directives: location=, timeOfDay=, weather=, lighting=,
    outfit:CharacterID=, position:CharacterID=, condition:CharacterID=,
    wet:CharacterID=, injury:CharacterID=,
    prop+:item, prop-:item, propOwner:item=Name, dialogueState=, storyState=.
    2 to 8 shots. Keep user-provided dialogue verbatim.
    \(PerShotAudioPolicy.directorInstruction)
    \(CharacterContinuitySafetyPolicy.directorInstruction)
    Motion tempo describes how quickly the subject acts. Camera tempo describes
    camera pacing independently. Playback style is realTime unless the brief
    explicitly asks for slow motion, fast motion, or time-lapse. Words such as
    "slowly opens the door" describe a slow real-time action, not slow-motion
    playback. A continuing shot inherits the preceding shot's motion, camera,
    and playback tempo unless the story explicitly changes one of them. A cut
    does not by itself imply slow motion.
    Set "continuity":"continue" only when the shot is a direct physical
    continuation of the previous one: same location, same active characters, no
    time jump, one unbroken action. Use "cut" for a location change, a time
    jump, a new establishing shot, a different character, or any intentional
    cinematic cut. When unsure, use "cut". The first shot is always "cut".

    Every shot must advance the story to a NEW visible state. Never restate the
    previous shot's action in different words: "walks toward the door", then
    "keeps walking toward the door", then "continues approaching the door" is
    wrong. Each summary describes what newly happens in that shot — approaching,
    then arriving, then reaching for the handle, then stepping through.

    Continuing shots keep the same character, clothing, place, light and props,
    but they do NOT keep the same framing. Let the camera change with the beat:
    an establishing view can give way to a closer one as the action tightens.
    Choose one primary camera idea per shot from static, slow push-in, pull-back,
    tracking, dolly, pan, tilt or handheld follow. A static camera is correct for
    dialogue, a held reaction or a deliberately still composition — use it
    because the beat calls for it, not as a default for every shot.

    When the story moves somewhere genuinely new, such as outside to inside, use
    "cut" and open the new place with its own establishing shot. Story
    progression matters more than keeping an unbroken visual chain.

    Do not mark every shot "cut". If a shot happens in the same place, with the
    same character, at the same moment in time as the shot before it, it MUST be
    "continue" — even when the framing changes completely, and even when it is a
    tight insert such as a hand on a lock. Only use "cut" when the place, the
    time or the active character actually changes. Marking a whole scene as cuts
    makes each shot regenerate a different-looking person and set, which is
    wrong. Worked example for "a woman walks to a library, opens the door and
    steps inside":
      shot 1 "cut"      — wide, she crosses the courtyard (the first shot always cuts)
      shot 2 "continue" — medium, she arrives at the doors and reaches for the handle
      shot 3 "continue" — close, the handle turns and the door begins to open
      shot 4 "cut"      — interior establishing shot as she steps inside
    """

    static func storyboardSystemPrompt(characterBible: CharacterBible) -> String {
        guard !characterBible.characters.isEmpty else { return storyboardSystemPrompt }
        let characters = characterBible.characters.map { character in
            var parts = ["ID: \(character.id.uuidString)", "Name: \(character.name)"]
            if !character.aliases.isEmpty { parts.append("Aliases: \(character.aliases.joined(separator: ", "))") }
            let appearance = character.appearance.compactVisualSummary
            if !appearance.isEmpty { parts.append("Appearance: \(appearance)") }
            if !character.defaultCostume.isEmpty { parts.append("Default costume: \(character.defaultCostume)") }
            if !character.accessories.isEmpty { parts.append("Accessories: \(character.accessories)") }
            if !character.personality.isEmpty { parts.append("Personality: \(character.personality)") }
            if !character.speakingStyle.isEmpty { parts.append("Speaking style: \(character.speakingStyle)") }
            if !character.roleNotes.isEmpty { parts.append("Role/notes: \(character.roleNotes)") }
            return "- " + parts.joined(separator: " | ")
        }.joined(separator: "\n")
        return storyboardSystemPrompt + """


        AVAILABLE CHARACTERS (use these exact IDs in each shot's characterIDs):
        \(characters)
        A person mentioned in the brief but absent from this list may remain ad-hoc; do not invent an ID.
        """
    }

    private let providers: [DirectorProvider]
    private let requestedMode: DirectorMode
    /// One original request plus one bounded LLM repair request.
    private let maxRepairAttempts = 1
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var lastProviderModel: String?
    private(set) var lastPlanningMode: String?
    private(set) var lastFallbackReason: String?
    /// Which local protocol actually produced the plan, for provenance and
    /// diagnostics. nil when no local provider succeeded.
    private(set) var lastProtocol: LocalDirectorProtocol?
    private let compatibility: LocalDirectorCompatibilityService
    /// Why the protocol the model was expected to use failed. Kept separate
    /// from later protocol attempts so trying a second protocol cannot make
    /// the reported reason less actionable than it was before negotiation.
    private var preferredProtocolFallbackReason: String?

    init(providers: [DirectorProvider]? = nil,
         requestedMode: DirectorMode = DirectorMode.selected(),
         compatibility: LocalDirectorCompatibilityService = LocalDirectorCompatibilityService()) {
        self.requestedMode = requestedMode
        self.compatibility = compatibility
        if let providers {
            self.providers = providers
        } else if requestedMode == .basic {
            self.providers = [TemplateStoryboardProvider()]
        } else {
            self.providers = [EnvironmentDirectorProvider(mode: requestedMode), TemplateStoryboardProvider()]
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? DirectorError) == .cancelled { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return false
    }

    /// Brief → validated storyboard draft. Provider terminated before return.
    func draft(
        brief: String,
        characterBible: CharacterBible = CharacterBible(),
        openingSceneEvidence: OpeningReferenceAppearance? = nil,
        targetDurationSeconds: Double? = nil,
        handle: DirectorPlanningHandle? = nil,
        progressCallback: ((DirectorPlanningPhase, String) -> Void)? = nil
    ) async throws -> (draft: StoryboardDraft, providerName: String) {
        if handle?.isCancelled == true || Task.isCancelled {
            progressCallback?(.cancelled, "Planning cancelled")
            throw DirectorError.cancelled
        }
        progressCallback?(.preparing, "Preparing Local Director…")

        diagnostics = []
        lastProviderModel = nil
        lastPlanningMode = nil
        lastFallbackReason = nil
        lastProtocol = nil
        preferredProtocolFallbackReason = nil
        var lastError: Error = DirectorError.noProviderAvailable
        var precedingProviderFailed = false
        for provider in providers {
            if handle?.isCancelled == true || Task.isCancelled {
                progressCallback?(.cancelled, "Planning cancelled")
                throw DirectorError.cancelled
            }
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
                    lastFallbackReason = preferredProtocolFallbackReason
                        ?? diagnostics.reversed().first {
                        $0.stage != .repairFailed && $0.stage != .retryFailed
                        }?.stage.rawValue
                }
                record(.templateFallback, provider: provider.name, attempt: 0,
                       message: "using deterministic template after structured planning failed")
            }
            do {
                let draft: StoryboardDraft
                if provider.isFallbackProvider {
                    draft = try await draftWithProvider(
                        provider, brief: brief, characterBible: characterBible,
                        openingSceneEvidence: openingSceneEvidence,
                        targetDurationSeconds: targetDurationSeconds,
                        handle: handle,
                        progressCallback: progressCallback)
                } else {
                    // Capability negotiation: start from what this model was
                    // last seen to handle, and if that protocol fails in
                    // production, try the remaining ones once each before
                    // giving up on local planning entirely. Each protocol is
                    // attempted at most once, so the chain is bounded at
                    // Structured -> Text -> (next provider).
                    let model = provider.modelIdentifier ?? ""
                    let preferred = compatibility.startingProtocol(for: model)
                    let order = [preferred] + LocalDirectorProtocol.negotiationOrder.filter { $0 != preferred }
                    var localDraft: StoryboardDraft?
                    var localError: Error?
                    for planProtocol in order {
                        if handle?.isCancelled == true || Task.isCancelled {
                            progressCallback?(.cancelled, "Planning cancelled")
                            throw DirectorError.cancelled
                        }
                        let phase: DirectorPlanningPhase = planProtocol == .structuredJSON ? .structuredPlanning : .textProtocolPlanning
                        progressCallback?(phase, phase.displayName)

                        let diagnosticMark = diagnostics.count
                        do {
                            localDraft = try await draftWithProvider(
                                provider, brief: brief, characterBible: characterBible,
                                openingSceneEvidence: openingSceneEvidence,
                                targetDurationSeconds: targetDurationSeconds,
                                planProtocol: planProtocol,
                                handle: handle,
                                progressCallback: progressCallback)
                            lastProtocol = planProtocol
                            if !model.isEmpty {
                                // Remember a downgrade so the next run starts
                                // with the protocol that actually works.
                                compatibility.recordSuccessfulProtocol(planProtocol, model: model)
                            }
                            break
                        } catch {
                            if Self.isCancellationError(error) || handle?.isCancelled == true || Task.isCancelled {
                                await provider.terminate()
                                progressCallback?(.cancelled, "Planning cancelled")
                                throw DirectorError.cancelled
                            }
                            localError = error
                            if preferredProtocolFallbackReason == nil {
                                preferredProtocolFallbackReason = diagnostics[diagnosticMark...]
                                    .reversed()
                                    .first { $0.stage != .repairFailed && $0.stage != .retryFailed }?
                                    .stage.rawValue
                            }
                            record(.retryFailed, provider: provider.name, attempt: 0,
                                   message: "\(planProtocol.displayName) protocol did not produce a valid plan")
                        }
                    }
                    guard let negotiated = localDraft else {
                        throw localError ?? DirectorError.noProviderAvailable
                    }
                    draft = negotiated
                }
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
                if Self.isCancellationError(error) || handle?.isCancelled == true || Task.isCancelled {
                    progressCallback?(.cancelled, "Planning cancelled")
                    throw DirectorError.cancelled
                }
                lastError = error
                precedingProviderFailed = true
            }
        }
        throw lastError
    }

    /// Runs exactly one protocol against one provider, with the same bounded
    /// repair a production run gets. Capability probing uses this so the probe
    /// asks precisely what production asks — no second implementation of the
    /// request/parse/repair loop, and no probe that is stricter than the real
    /// thing and under-reports a usable model.
    func draftUsingProtocol(
        _ planProtocol: LocalDirectorProtocol,
        provider: DirectorProvider,
        brief: String,
        characterBible: CharacterBible = CharacterBible(),
        openingSceneEvidence: OpeningReferenceAppearance? = nil,
        targetDurationSeconds: Double? = nil
    ) async throws -> StoryboardDraft {
        try await draftWithProvider(provider, brief: brief,
                                    characterBible: characterBible,
                                    openingSceneEvidence: openingSceneEvidence,
                                    targetDurationSeconds: targetDurationSeconds,
                                    planProtocol: planProtocol)
    }

    private func draftWithProvider(
        _ provider: DirectorProvider,
        brief: String,
        characterBible: CharacterBible,
        openingSceneEvidence: OpeningReferenceAppearance? = nil,
        targetDurationSeconds: Double? = nil,
        planProtocol: LocalDirectorProtocol = .structuredJSON,
        handle: DirectorPlanningHandle? = nil,
        progressCallback: ((DirectorPlanningPhase, String) -> Void)? = nil
    ) async throws -> StoryboardDraft {
        var prompt = DirectorPlanFormat.userPrompt(
            for: planProtocol, brief: brief,
            openingSceneEvidence: openingSceneEvidence,
            characterBible: characterBible,
            targetDurationSeconds: targetDurationSeconds)
        var lastFailure = ""
        for attempt in 0...maxRepairAttempts {
            if handle?.isCancelled == true || Task.isCancelled {
                throw DirectorError.cancelled
            }
            let response: String
            do {
                response = try await provider.complete(
                    system: DirectorPlanFormat.systemPrompt(for: planProtocol, characterBible: characterBible),
                    prompt: prompt,
                    expectsJSON: planProtocol == .structuredJSON,
                    handle: handle
                )
            } catch {
                if Self.isCancellationError(error) || handle?.isCancelled == true || Task.isCancelled {
                    throw DirectorError.cancelled
                }
                let stage: FailureStage
                if case DirectorError.noResponse = error {
                    stage = .noResponse
                } else {
                    stage = .ollamaRequestFailed
                }
                record(stage, provider: provider.name, attempt: attempt, message: error.localizedDescription)
                if attempt < maxRepairAttempts {
                    prompt = DirectorPlanFormat.repairPrompt(
                        for: planProtocol,
                        failure: error.localizedDescription,
                        brief: brief,
                        openingSceneEvidence: openingSceneEvidence,
                        characterBible: characterBible,
                        targetDurationSeconds: targetDurationSeconds)
                    continue
                }
                record(.retryFailed, provider: provider.name, attempt: attempt,
                       message: error.localizedDescription)
                throw error
            }

            if handle?.isCancelled == true || Task.isCancelled {
                throw DirectorError.cancelled
            }

            progressCallback?(.parsing, "Parsing director plan…")
            appendDebugRawResponse(response, provider: provider.name, attempt: attempt)

            let parsed = DirectorPlanFormat.parse(response, as: planProtocol, brief: brief)
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
            prompt = DirectorPlanFormat.repairPrompt(
                for: planProtocol, failure: lastFailure, brief: brief,
                openingSceneEvidence: openingSceneEvidence,
                characterBible: characterBible,
                targetDurationSeconds: targetDurationSeconds)
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
        if let extracted = StructuredJSONUtilities.firstJSONObject(in: trimmed), extracted != trimmed {
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
            let repairedSyntax = StructuredJSONUtilities.removingTrailingCommas(from: candidate)
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
                if shot["motionTempo"] == nil { shot["motionTempo"] = shot["motion_tempo"] }
                if shot["cameraTempo"] == nil { shot["cameraTempo"] = shot["camera_tempo"] }
                if shot["playbackStyle"] == nil { shot["playbackStyle"] = shot["playback_style"] }
                if shot["audioCues"] == nil { shot["audioCues"] = shot["audio"] }
                if shot["characterIDs"] == nil { shot["characterIDs"] = shot["characters"] }
                if shot["characterNames"] == nil { shot["characterNames"] = shot["character_names"] }
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
        projectID: UUID = UUID(),
        title: String,
        brief: String,
        settings: ProjectSettings = ProjectSettings(),
        characterBible: CharacterBible = CharacterBible(),
        openingSceneEvidence: OpeningReferenceAppearance? = nil,
        capabilityAwarePlanning: Bool = false,
        handle: DirectorPlanningHandle? = nil,
        progressCallback: ((DirectorPlanningPhase, String) -> Void)? = nil
    ) async throws -> (project: FilmProject, violations: [ContinuityEngine.Violation], providerName: String) {
        let (rawDraft, providerName) = try await self.draft(
            brief: brief, characterBible: characterBible,
            openingSceneEvidence: openingSceneEvidence,
            targetDurationSeconds: capabilityAwarePlanning ? settings.targetDurationSeconds : nil,
            handle: handle,
            progressCallback: progressCallback)

        if handle?.isCancelled == true || Task.isCancelled {
            progressCallback?(.cancelled, "Planning cancelled")
            throw DirectorError.cancelled
        }
        progressCallback?(.applying, "Applying storyboard…")
        var draft = rawDraft

        // Auto Movie steers the plan toward shots this profile actually renders
        // before anything is compiled, so the prompt, the camera fields and the
        // persisted plan all describe the same effective shot. Storyboard and
        // every manual path opt out and keep the Director's plan verbatim.
        var capabilityAdjustments: [CapabilityAwareShotPlanner.Adjustment] = []
        if capabilityAwarePlanning {
            let planned = CapabilityAwareShotPlanner.plan(shots: draft.shots, brief: brief)
            draft.shots = planned.shots
            capabilityAdjustments = planned.adjustments
        }

        var project = FilmProject(id: projectID, title: title)
        project.settings = settings
        project.directorProvider = providerName
        project.directorModel = lastProviderModel
        project.planningMode = lastPlanningMode
        project.directorProtocol = lastProtocol?.rawValue
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
        // Preserve the user-owned Bible. Legacy/no-Bible planning may still
        // seed lightweight entries from the provider's initial outfit state.
        var bible = characterBible
        if bible.characters.isEmpty {
            for (name, outfit) in (draft.initialState?.characterOutfit ?? [:]) {
                bible.characters.append(CharacterBibleEntry(name: name, defaultCostume: outfit))
            }
        }
        project.characterBible = bible

        var violations: [ContinuityEngine.Violation] = []
        var state = ContinuityEngine.normalizedCharacterReferences(
            in: draft.initialState ?? ContinuitySnapshot(), bible: bible
        )
        var previousMotionProfile: MotionTempoProfile?
        let japaneseHandling = JapaneseDialogueHandling(rawValue: settings.japaneseHandling) ?? .native

        for (index, shotDraft) in draft.shots.enumerated() {
            var shot = Shot(index: index, title: shotDraft.title, summary: shotDraft.summary)
            shot.durationSeconds = min(6, max(1, shotDraft.durationSeconds ?? 5))
            // The first shot has nothing to continue from. Unknown or missing
            // planner values fall back to `auto`, which the run coordinator
            // resolves deterministically (and conservatively) at generation time.
            shot.continuityMode = index == 0
                ? .cut
                : ShotContinuityMode(rawValue: (shotDraft.continuity ?? "").lowercased()) ?? .auto
            let motionProfile = MotionTempoPlanningPolicy.resolve(
                draft: shotDraft,
                brief: brief,
                previous: previousMotionProfile,
                isContinuation: shot.continuityMode == .continueFromPrevious
            )
            shot.motionTempo = motionProfile.motionTempo
            shot.cameraTempo = motionProfile.cameraTempo
            shot.playbackStyle = motionProfile.playbackStyle
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
            let resolution = Self.resolveCharacterIDs(
                for: shotDraft,
                brief: brief,
                bible: bible
            )
            shot.characterIDs = resolution.ids
            for unknown in resolution.unknownReferences {
                violations.append(ContinuityEngine.Violation(
                    severity: .warning,
                    message: "Shot \(index + 1): ignored unknown CharacterBible reference '\(unknown)'."
                ))
            }

            // Deterministic transition; malformed directives surface as violations.
            let nextState: ContinuitySnapshot
            do {
                nextState = ContinuityEngine.normalizedCharacterReferences(
                    in: try ContinuityEngine.apply(changes: shot.explicitChanges, to: state),
                    bible: bible
                )
            } catch {
                violations.append(ContinuityEngine.Violation(
                    severity: .error,
                    message: "Shot \(index + 1): malformed continuity directive (\(error))"
                ))
                nextState = state
            }
            violations.append(contentsOf: ContinuityEngine.validate(
                previous: state,
                next: nextState,
                explicitChanges: shot.explicitChanges,
                bible: bible
            ))

            // Compile the shot prompt: continuity context + one-shot plan.
            let plan = OneShotPlan(
                camera: "\(shot.camera.shotScale) shot, \(shot.camera.angle) angle, \(shot.camera.movement) camera",
                action: shot.summary,
                acting: nil,
                motion: MotionTempoPromptPolicy.instruction(
                    motionTempo: shot.motionTempo,
                    cameraTempo: shot.cameraTempo,
                    playbackStyle: shot.playbackStyle
                ),
                lighting: shotDraft.lighting ?? nextState.lighting,
                dialogue: (shotDraft.dialogue ?? []),
                audioCues: shotDraft.audioCues ?? [],
                durationIntentSeconds: shot.durationSeconds
            )
            let context = ContinuityEngine.promptContext(for: nextState, bible: bible)
            let compiled = PromptCompiler.compile(
                plan: plan,
                options: PromptCompiler.Options(
                    japaneseHandling: japaneseHandling,
                    perShotAudioPolicy: .naturalProductionSoundNoMusic)
            )
            shot.baseCompiledPrompt = context.isEmpty ? compiled : context + " " + compiled
            shot.compiledPrompt = shot.baseCompiledPrompt ?? compiled

            // Keep the original framing and the reason on the shot so a run
            // stays explainable after a reload.
            if let adjustment = capabilityAdjustments.first(where: { $0.index == index }),
               adjustment.risk == .highRisk || adjustment.appliedOpeningAnchor {
                shot.capabilityAdjustmentReason = adjustment.explanation
                if adjustment.originalScale != adjustment.effectiveScale {
                    shot.originalCameraScale = adjustment.originalScale
                }
            }

            project.shots.append(shot)
            state = nextState
            previousMotionProfile = motionProfile
        }

        CharacterPromptPipeline.recompile(project: &project)
        violations.append(contentsOf: ContinuityEngine.monotonyWarnings(shots: project.shots))
        progressCallback?(.completed, "Plan ready")
        return (project, violations, providerName)
    }

    private static func resolveCharacterIDs(
        for shot: ShotPlanDraft,
        brief: String,
        bible: CharacterBible
    ) -> (ids: [UUID], unknownReferences: [String]) {
        guard !bible.characters.isEmpty else { return ([], []) }
        var ids: [UUID] = []
        var unknown: [String] = []
        let supplied = (shot.characterIDs ?? []) + (shot.characterNames ?? [])
        for reference in supplied {
            if let id = UUID(uuidString: reference), bible.character(id: id) != nil {
                if !ids.contains(id) { ids.append(id) }
            } else if let character = bible.character(named: reference) {
                if !ids.contains(character.id) { ids.append(character.id) }
            } else {
                unknown.append(reference)
            }
        }
        guard ids.isEmpty else { return (ids, unknown) }

        let shotMatches = mentionedCharacters(in: shot.summary, bible: bible)
        if !shotMatches.isEmpty { return (shotMatches, unknown) }
        let briefMatches = mentionedCharacters(in: brief, bible: bible)
        // A single explicitly mentioned project character may safely carry
        // through pronoun-only shots. Multiple candidates are not guessed.
        return briefMatches.count == 1 ? (briefMatches, unknown) : ([], unknown)
    }

    private static func mentionedCharacters(in text: String, bible: CharacterBible) -> [UUID] {
        bible.characters.compactMap { character in
            character.matchingNames.contains { exactMention($0, in: text) } ? character.id : nil
        }
    }

    private static func exactMention(_ name: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !escaped.isEmpty else { return false }
        return text.range(
            of: "(?i)(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])",
            options: .regularExpression
        ) != nil
    }
}

struct MotionTempoProfile: Equatable {
    var motionTempo: MotionTempo
    var cameraTempo: CameraTempo
    var playbackStyle: PlaybackStyle
}

/// Deterministic continuity policy shared by Structured, Text, and Basic
/// Director output after all protocols have converged on `StoryboardDraft`.
enum MotionTempoPlanningPolicy {
    static let defaultProfile = MotionTempoProfile(
        motionTempo: .normal,
        cameraTempo: .normal,
        playbackStyle: .realTime
    )

    static func resolve(
        draft: StoryboardDirector.ShotPlanDraft,
        brief: String,
        previous: MotionTempoProfile?,
        isContinuation: Bool
    ) -> MotionTempoProfile {
        let inherited = isContinuation ? previous : nil
        var result = MotionTempoProfile(
            motionTempo: decode(draft.motionTempo, as: MotionTempo.self)
                ?? inherited?.motionTempo ?? defaultProfile.motionTempo,
            cameraTempo: decode(draft.cameraTempo, as: CameraTempo.self)
                ?? inherited?.cameraTempo ?? defaultProfile.cameraTempo,
            playbackStyle: decode(draft.playbackStyle, as: PlaybackStyle.self)
                ?? inherited?.playbackStyle ?? defaultProfile.playbackStyle
        )

        // Explicit narrative playback direction is authoritative. Deliberately
        // match phrases, not the adjective "slowly", so action speed is not
        // confused with temporal playback.
        if let explicit = explicitPlaybackStyle(in: draft.summary)
            ?? explicitPlaybackStyle(in: brief) {
            result.playbackStyle = explicit
        }
        return result
    }

    static func explicitPlaybackStyle(in text: String) -> PlaybackStyle? {
        let value = text.lowercased()
        if ["slow motion", "slow-motion", "slowmo", "slo-mo", "スローモーション"]
            .contains(where: value.contains) {
            return .slowMotion
        }
        if ["fast motion", "fast-motion", "time lapse", "time-lapse", "早回し"]
            .contains(where: value.contains) {
            return .fastMotion
        }
        if ["real time", "real-time", "リアルタイム"]
            .contains(where: value.contains) {
            return .realTime
        }
        return nil
    }

    private static func decode<T: RawRepresentable>(
        _ raw: String?, as type: T.Type
    ) -> T? where T.RawValue == String {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return [value, value.lowercased()].compactMap(T.init(rawValue:)).first
            ?? fallbackDecode(value, as: type)
    }

    private static func fallbackDecode<T: RawRepresentable>(
        _ raw: String, as type: T.Type
    ) -> T? where T.RawValue == String {
        let compact = raw.lowercased().filter(\.isLetter)
        let known = [
            MotionTempo.slow.rawValue, MotionTempo.normal.rawValue, MotionTempo.fast.rawValue,
            CameraTempo.static.rawValue,
            PlaybackStyle.realTime.rawValue, PlaybackStyle.slowMotion.rawValue,
            PlaybackStyle.fastMotion.rawValue,
        ]
        guard let canonical = known.first(where: {
            $0.lowercased().filter(\.isLetter) == compact
        }) else { return nil }
        return T(rawValue: canonical)
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
                motionTempo: MotionTempo.normal.rawValue,
                cameraTempo: CameraTempo.normal.rawValue,
                playbackStyle: PlaybackStyle.realTime.rawValue,
                lighting: "soft natural lighting",
                dialogue: [],
                audioCues: [],
                explicitChanges: [],
                characterIDs: nil,
                characterNames: nil
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
        let pattern = #"(?i)(?:^|\n|\.\s+|;\s+)(?:shot\s*\d+[:\s\-\.]+|最初のショット[:\s\-\.]*|次のショット[:\s\-\.]*|最後のショット[:\s\-\.]*)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsString = brief as NSString
            let matches = regex.matches(in: brief, options: [], range: NSRange(location: 0, length: nsString.length))
            if matches.count >= 2 {
                var beats: [String] = []
                for i in 0..<matches.count {
                    let start = matches[i].range.location + matches[i].range.length
                    let end = (i + 1 < matches.count) ? matches[i + 1].range.location : nsString.length
                    if end > start {
                        let beat = nsString.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !beat.isEmpty {
                            beats.append(beat)
                        }
                    }
                }
                if beats.count >= 2 {
                    return Array(beats.prefix(8))
                }
            }
        }

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
            let sequencePrefix = ["first,", "first ", "next,", "next ", "finally,", "finally "]
                .contains { lower.hasPrefix($0) }
            if markers.contains(where: { lower.contains($0) }) || sequencePrefix {
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
        projectID: UUID = UUID(),
        title: String,
        brief: String,
        settings: ProjectSettings,
        characterBible: CharacterBible = CharacterBible(),
        openingSceneEvidence: OpeningReferenceAppearance? = nil,
        handle: DirectorPlanningHandle? = nil,
        progressCallback: ((DirectorPlanningPhase, String) -> Void)? = nil
    ) async throws -> (project: FilmProject, violations: [ContinuityEngine.Violation], providerName: String) {
        var (project, violations, providerName) = try await director.makeProject(
            projectID: projectID, title: title, brief: brief,
            settings: settings, characterBible: characterBible,
            openingSceneEvidence: openingSceneEvidence,
            // Auto Movie only. The same pass runs for the local AI planner and
            // for the no-LLM template, so generation feasibility does not depend
            // on whether a local model happened to be available.
            capabilityAwarePlanning: true,
            handle: handle,
            progressCallback: progressCallback
        )
        let target = min(60, max(5, settings.targetDurationSeconds ?? 20))
        let desiredCount = min(12, max(1, Int(ceil(target / 5))))
        if project.shots.count == 1, desiredCount > 1, let source = project.shots.first {
            // Camera follows the beat rather than cycling a fixed list: the opening
            // establishes, the middle moves with the subject, and the final beat
            // sits closer on the resolving action.
            let scales = AutoMovieBeatPlanner.shotScales(count: desiredCount)
            let angles = AutoMovieBeatPlanner.cameraAngles(count: desiredCount)
            let movements = AutoMovieBeatPlanner.cameraMovements(count: desiredCount)
            var shots: [Shot] = []
            var state = source.continuityBefore ?? ContinuitySnapshot()
            for index in 0..<desiredCount {
                var shot = source
                shot.id = UUID()
                shot.index = index
                shot.title = AutoMovieBeatPlanner.title(index: index, count: desiredCount)
                shot.summary = AutoMovieBeatPlanner.beatSummary(
                    brief: source.summary, index: index, count: desiredCount
                )
                shot.camera.shotScale = scales[index]
                shot.camera.angle = angles[index]
                shot.camera.movement = movements[index]
                shot.continuityBefore = state
                shot.takes = []
                shot.selectedTakeID = nil
                shot.continuityMode = index == 0 ? .cut : .continueFromPrevious
                shot.continuityImageRelativePath = nil
                shot.continuitySourceTakeID = nil
                shot.continuityBlockedReason = nil
                shot.originalCameraScale = nil
                shot.capabilityAdjustmentReason = nil
                shots.append(shot)

                if let next = try? ContinuityEngine.apply(changes: shot.explicitChanges, to: state) {
                    state = next
                }
            }
            project.shots = shots
        }

        // Provider output is advisory; this deterministic pass is the single
        // source of truth for the complete-movie target shown in Plan Preview
        // and later converted to GenerationRequests.
        project.shots = AutoMovieDurationPlanner.normalize(
            shots: project.shots,
            targetDurationSeconds: target,
            fps: settings.fps
        )
        project.shots = ContinuityReconciler.reconcile(shots: project.shots)
        project.workflowMode = "hybrid"
        for index in project.shots.indices {
            CharacterPromptPipeline.recompilePlan(project: &project, shotIndex: index)
        }
        violations.append(contentsOf: ContinuityEngine.monotonyWarnings(shots: project.shots))
        return (project, violations, providerName)
    }
}
