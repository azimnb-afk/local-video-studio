import Foundation
import ImageIO

enum OneShotStartingImageError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case invalidImage(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let path):
            return "Starting Image is unavailable (\(URL(fileURLWithPath: path).lastPathComponent)). Choose it again or clear it before generating."
        case .invalidImage(let path):
            return "Starting Image could not be read as an image (\(URL(fileURLWithPath: path).lastPathComponent)). Choose another image or clear it."
        }
    }
}

/// Lightweight One Shot image preflight. The path remains an ordinary
/// sourceImagePath consumed by the existing I2V backend; no identity or
/// CharacterBible semantics are introduced here.
enum OneShotStartingImagePreflight {
    static func validatedPath(
        _ storedPath: String?,
        fileManager: FileManager = .default
    ) throws -> String? {
        guard let raw = storedPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: raw, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: raw) else {
            throw OneShotStartingImageError.unavailable(raw)
        }
        let url = URL(fileURLWithPath: raw) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw OneShotStartingImageError.invalidImage(raw)
        }
        return raw
    }
}

/// One Shot director: brief → structured plan → compiled prompt → request.
///
/// Memory lifecycle (mandatory): the LLM plans, the plan JSON is saved, the
/// LLM is terminated, and only then is the GenerationRequest handed to the
/// (single-flight) GenerationService for LTX rendering.
final class LocalDirector {

    static let directorSystemPrompt = """
    You are a film director planning a single continuous video shot (4-8 seconds).
    Respond with ONLY a JSON object, no markdown, with these fields:
    {
      "camera": "framing and camera movement in English",
      "action": "chronological, present-tense description of visible action in English",
      "acting": "performance and expression notes in English (optional)",
      "motion": "motion quality and pacing in English (optional)",
      "lighting": "light direction and mood in English (optional)",
      "dialogue": [{"speaker": "name", "text": "spoken line"}],
      "audioCues": ["sound effect or ambience in English"],
      "durationIntentSeconds": 5
    }
    Translate or normalize the action and visuals into clear English for the video generation model, while keeping the user's spoken dialogue lines verbatim if they provided any. Do not add
    scene cuts — this is one continuous shot.
    \(PerShotAudioPolicy.directorInstruction)
    """

    private let providers: [DirectorProvider]
    private let maxRepairAttempts = 2

    /// Providers in priority order. Template fallback is always last so the
    /// feature works with no local LLM installed.
    init(providers: [DirectorProvider]? = nil) {
        self.providers = providers ?? [OllamaDirectorProvider(), TemplateDirectorProvider()]
    }

    private static var debugLogURL: URL {
        let dir = AppStorageDirectory.root
        return dir.appendingPathComponent("director_debug.log")
    }

    /// Produces a validated plan from a brief. The provider is ALWAYS
    /// terminated before this returns, success or failure.
    func plan(brief: String, handle: DirectorPlanningHandle? = nil) async throws -> (plan: OneShotPlan, providerName: String) {
        if handle?.isCancelled == true || Task.isCancelled {
            throw DirectorError.cancelled
        }
        var lastError: Error = DirectorError.noProviderAvailable
        for provider in providers {
            if handle?.isCancelled == true || Task.isCancelled {
                throw DirectorError.cancelled
            }
            guard await provider.isAvailable() else { continue }
            do {
                let plan = try await planWithProvider(provider, brief: brief, handle: handle)
                await provider.terminate()
                return (plan, provider.name)
            } catch {
                await provider.terminate()
                if error is CancellationError || (error as? DirectorError) == .cancelled || (error as? URLError)?.code == .cancelled || handle?.isCancelled == true || Task.isCancelled {
                    throw DirectorError.cancelled
                }
                lastError = error
            }
        }
        throw lastError
    }

    private func planWithProvider(_ provider: DirectorProvider, brief: String, handle: DirectorPlanningHandle? = nil) async throws -> OneShotPlan {
        var prompt = "BRIEF: \(brief)"
        var lastFailure = ""
        for attempt in 0...maxRepairAttempts {
            if handle?.isCancelled == true || Task.isCancelled {
                throw DirectorError.cancelled
            }
            let response: String
            do {
                response = try await provider.complete(system: Self.directorSystemPrompt, prompt: prompt, expectsJSON: true, handle: handle)
            } catch {
                if error is CancellationError || (error as? DirectorError) == .cancelled || (error as? URLError)?.code == .cancelled || handle?.isCancelled == true || Task.isCancelled {
                    throw DirectorError.cancelled
                }
                throw error
            }
            appendDebugLog("provider=\(provider.name) attempt=\(attempt)\n\(response)")
            if let plan = Self.parsePlan(from: response) {
                if plan.isValid {
                    return plan
                }
                lastFailure = plan.validationErrors.joined(separator: ", ")
            } else {
                lastFailure = "response was not valid JSON"
            }
            // Bounded repair: restate the task with the failure reason. The
            // user's brief is never lost.
            prompt = """
            Your previous response was invalid (\(lastFailure)). \
            Respond again with ONLY the JSON object described in the system prompt.
            \(PerShotAudioPolicy.directorInstruction)
            BRIEF: \(brief)
            """
        }
        if lastFailure.contains("JSON") || lastFailure.contains("json") {
            throw DirectorError.invalidPlanJSON(lastFailure)
        }
        throw DirectorError.planValidationFailed([lastFailure])
    }

    /// Extracts and decodes a OneShotPlan from possibly noisy LLM output.
    static func parsePlan(from response: String) -> OneShotPlan? {
        // Direct decode first.
        if let data = response.data(using: .utf8),
           let plan = try? JSONDecoder().decode(OneShotPlan.self, from: data) {
            return plan
        }
        // Extract the outermost JSON object (handles markdown fences/preambles).
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"), start < end else { return nil }
        let candidate = String(response[start...end])
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OneShotPlan.self, from: data)
    }

    /// Full pipeline: plan → compile → GenerationRequest. The returned request
    /// carries the compiled prompt; base settings come from the caller.
    func makeRequest(
        brief: String,
        base: GenerationRequest,
        japaneseHandling: JapaneseDialogueHandling = .native
    ) async throws -> (request: GenerationRequest, plan: OneShotPlan, providerName: String) {
        let (plan, providerName) = try await self.plan(brief: brief)

        // Strict English renderer action validation gate
        try RenderLanguageValidator.validateRendererAction(plan.action)

        let compiled = PromptCompiler.compile(
            plan: plan,
            options: PromptCompiler.Options(
                isImageToVideo: base.isImageToVideo,
                japaneseHandling: japaneseHandling,
                perShotAudioPolicy: .naturalProductionSoundNoMusic
            )
        )
        var params = base.parameters
        let customParameters = GenerationPreset.resolving(
            presetRaw: base.preset,
            qualityModeRaw: base.qualityMode
        ) == .custom
        if let seconds = plan.durationIntentSeconds, !customParameters {
            params.numFrames = PromptCompiler.frameCount(forSeconds: seconds, fps: params.fps)
        }
        let request = GenerationRequest(
            id: base.id,
            prompt: compiled,
            brief: base.brief ?? brief,
            negativePrompt: base.negativePrompt,
            voiceoverText: base.voiceoverText,
            voiceoverSource: base.voiceoverSource,
            voiceoverVoice: base.voiceoverVoice,
            sourceImagePath: base.sourceImagePath,
            presetResolutionOrientation: base.presetResolutionOrientation,
            musicEnabled: base.musicEnabled,
            musicGenre: base.musicGenre,
            disableAudio: base.disableAudio,
            gemmaRepetitionPenalty: base.gemmaRepetitionPenalty,
            gemmaTopP: base.gemmaTopP,
            modelId: base.modelId,
            textEncoderId: base.textEncoderId,
            parameters: params,
            createdAt: base.createdAt,
            status: base.status,
            modelRevision: base.modelRevision,
            quantization: base.quantization,
            qualityMode: base.qualityMode,
            preset: base.preset,
            targetDurationSeconds: customParameters ? nil : (base.targetDurationSeconds ?? plan.durationIntentSeconds),
            generationSource: base.generationSource ?? "oneShot",
            customModelsEnabled: base.customModelsEnabled,
            customModelLocalPath: base.customModelLocalPath,
            customModelSourceMode: base.customModelSourceMode,
            filmProjectID: base.filmProjectID,
            shotID: base.shotID,
            takeID: base.takeID
        )
        return (request, plan, providerName)
    }

    private func appendDebugLog(_ text: String) {
        let entry = "\n=== \(Date()) ===\n\(text)\n"
        if let data = entry.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: Self.debugLogURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: Self.debugLogURL)
            }
        }
    }
}
