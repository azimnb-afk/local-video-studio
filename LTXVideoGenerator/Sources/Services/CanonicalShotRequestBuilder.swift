import Foundation

/// Encapsulates already-validated image conditioning inputs for a single shot.
/// Image selection policy (Opening Reference, Continuity Frame, Character Anchor,
/// New Start Frame) remains owned by the caller (e.g. TakeGenerationCoordinator).
struct ResolvedShotConditioningImage: Equatable {
    var path: String?
    var imageStrength: Double?
    var effectiveSource: LTXContinuitySource = .none

    static let none = ResolvedShotConditioningImage(path: nil, imageStrength: nil, effectiveSource: .none)
}

/// Specifications for building a concrete `GenerationRequest` and its effective
/// `GenerationParameters`.
struct CanonicalShotSpecification: Equatable {
    var prompt: String
    var brief: String? = nil
    var modelID: String
    var textEncoderID: String
    var preset: String? = nil
    var qualityMode: String? = nil
    var width: Int
    var height: Int
    var fps: Int
    var numInferenceSteps: Int
    var targetDurationSeconds: Double? = nil
    var numFramesOverride: Int? = nil
    var audioEnabled: Bool = true
    var seed: Int? = nil
    var conditioningImage: ResolvedShotConditioningImage = .none
    var orientation: SourceImageOrientation = .none
    var generationSource: String = "canonicalShot"
    var projectID: UUID? = nil
    var shotID: UUID? = nil
    var takeID: UUID? = nil
    var customModelsEnabled: Bool? = nil
    var customModelLocalPath: String? = nil
    var customModelSourceMode: String? = nil
    var minimaxH3ModelDirectory: String? = nil
    var minimaxH3RuntimeExecutablePath: String? = nil
    var minimaxH3Endpoint: String? = nil
    var minimaxH3ChainWindows: Int? = nil
    var minimaxH3ExpectedFrames: Int? = nil
    var minimaxH3RequestedDurationSeconds: Double? = nil
}

/// Single-shot technical preparation and request assembly.
///
/// This pure, deterministic builder translates an already-determined shot-level
/// prompt and execution parameters into the canonical `GenerationRequest` and
/// effective `GenerationParameters` consumed by generation backends.
///
/// It explicitly does NOT own:
/// - Movie planning / story breakdown
/// - Shot purpose inference / Action Arc generation
/// - Continuity image selection / frame extraction
/// - StoryboardDirector / LocalDirector LLM calls
/// - FilmProject / Take persistence
/// - Queue scheduling / execution
enum CanonicalShotRequestBuilder {

    /// Builds a canonical `GenerationRequest` and the matching `GenerationParameters`
    /// from the given specification.
    static func buildRequest(
        from spec: CanonicalShotSpecification
    ) -> (request: GenerationRequest, parameters: GenerationParameters, technicalPrompt: String) {
        // 1. Technical Audio Policy Guard (idempotent, does not invent story)
        let technicalPrompt = PerShotAudioPolicy.naturalProductionSoundNoMusic
            .applyingPromptGuard(to: spec.prompt)

        // 2. Custom Preset detection
        let isCustom = GenerationPreset.resolving(
            presetRaw: spec.preset,
            qualityModeRaw: spec.qualityMode
        ) == .custom

        // 3. Frame count resolution
        let resolvedFrames: Int
        if isCustom {
            if let explicitFrames = spec.numFramesOverride {
                resolvedFrames = explicitFrames
            } else if let duration = spec.targetDurationSeconds {
                resolvedFrames = PromptCompiler.frameCount(forSeconds: duration, fps: spec.fps)
            } else {
                resolvedFrames = 121
            }
        } else if let duration = spec.targetDurationSeconds {
            resolvedFrames = PromptCompiler.frameCount(forSeconds: duration, fps: spec.fps)
        } else if let explicitFrames = spec.numFramesOverride {
            resolvedFrames = explicitFrames
        } else {
            resolvedFrames = spec.modelID == MiniMaxH3Configuration.modelID ? 39 : 121
        }

        // 4. Parameter Assembly
        var params = GenerationParameters.default
        params.width = spec.width
        params.height = spec.height
        params.fps = spec.fps
        params.numFrames = resolvedFrames
        params.numInferenceSteps = spec.numInferenceSteps
        if let seed = spec.seed {
            params.seed = seed
        }
        if let strength = spec.conditioningImage.imageStrength {
            params.imageStrength = strength
        }

        // 5. Target Duration Seconds
        let resolvedTargetDuration: Double? = isCustom ? nil : spec.targetDurationSeconds

        // 6. GenerationRequest Construction
        let request = GenerationRequest(
            prompt: technicalPrompt,
            brief: spec.brief,
            sourceImagePath: spec.conditioningImage.path,
            presetResolutionOrientation: spec.orientation,
            disableAudio: !spec.audioEnabled,
            modelId: spec.modelID,
            textEncoderId: spec.textEncoderID,
            parameters: params,
            qualityMode: spec.qualityMode,
            preset: spec.preset,
            targetDurationSeconds: resolvedTargetDuration,
            generationSource: spec.generationSource,
            customModelsEnabled: spec.customModelsEnabled,
            customModelLocalPath: spec.customModelLocalPath,
            customModelSourceMode: spec.customModelSourceMode,
            minimaxH3ModelDirectory: spec.minimaxH3ModelDirectory,
            minimaxH3RuntimeExecutablePath: spec.minimaxH3RuntimeExecutablePath,
            minimaxH3Endpoint: spec.minimaxH3Endpoint,
            minimaxH3ChainWindows: spec.minimaxH3ChainWindows,
            minimaxH3ExpectedFrames: spec.minimaxH3ExpectedFrames,
            minimaxH3RequestedDurationSeconds: spec.minimaxH3RequestedDurationSeconds,
            filmProjectID: spec.projectID,
            shotID: spec.shotID,
            takeID: spec.takeID
        )

        return (request, params, technicalPrompt)
    }
}
