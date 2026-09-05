import Foundation
@testable import LTXVideoGeneratorCore

// ============================================================================
// LEGACY ONE SHOT REFERENCE IMPLEMENTATION
// Represents the pre-Phase 2 LocalDirector.makeRequest technical request
// construction logic.
// ============================================================================
enum LegacyOneShotRequestReferenceBuilder {

    static func buildRequest(
        brief: String,
        plan: OneShotPlan,
        base: GenerationRequest,
        japaneseHandling: JapaneseDialogueHandling = .native
    ) -> (request: GenerationRequest, compiledPrompt: String) {
        let compiled: String
        if base.modelId == MiniMaxH3Configuration.modelID {
            compiled = MiniMaxH3PromptCompiler.compile(
                plan: plan,
                isImageToVideo: base.isImageToVideo,
                japaneseHandling: japaneseHandling,
                perShotAudioPolicy: .naturalProductionSoundNoMusic)
        } else {
            compiled = PromptCompiler.compile(
                plan: plan,
                options: PromptCompiler.Options(
                    isImageToVideo: base.isImageToVideo,
                    japaneseHandling: japaneseHandling,
                    perShotAudioPolicy: .naturalProductionSoundNoMusic
                )
            )
        }

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
            minimaxH3ModelDirectory: base.minimaxH3ModelDirectory,
            minimaxH3RuntimeExecutablePath: base.minimaxH3RuntimeExecutablePath,
            minimaxH3Endpoint: base.minimaxH3Endpoint,
            minimaxH3ChainWindows: base.minimaxH3ChainWindows,
            minimaxH3ExpectedFrames: base.minimaxH3ExpectedFrames,
            minimaxH3RequestedDurationSeconds: base.minimaxH3RequestedDurationSeconds,
            filmProjectID: base.filmProjectID,
            shotID: base.shotID,
            takeID: base.takeID
        )

        return (request, compiled)
    }
}

// ============================================================================
// ONE SHOT DETERMINISTIC PARITY TEST SUITE
// ============================================================================
func runOneShotCanonicalParityTests(_ t: TestKit) {
    t.suite("Phase 2 — Migrate One Shot to CanonicalShotRequestBuilder") {

        let dummyPlan = OneShotPlan(
            camera: "slow pan right",
            action: "A detective examines a dusty book on the table.",
            acting: nil,
            motion: nil,
            lighting: "dim warm tungsten from a single lamp",
            dialogue: [OneShotPlan.DialogueLine(speaker: "Detective", text: "This hasn't been touched in years.")],
            audioCues: [],
            durationIntentSeconds: 5.0
        )

        func assertOneShotParity(
            legacy: (request: GenerationRequest, compiledPrompt: String),
            canonicalReq: GenerationRequest,
            caseName: String
        ) {
            // PROMPT PARITY
            t.checkEqual(canonicalReq.prompt, legacy.request.prompt, "\(caseName) PROMPT: exact final prompt match")
            t.checkEqual(canonicalReq.brief, legacy.request.brief, "\(caseName) PROMPT: brief match")

            // PARAMETER PARITY
            t.checkEqual(canonicalReq.parameters.width, legacy.request.parameters.width, "\(caseName) PARAM: width match")
            t.checkEqual(canonicalReq.parameters.height, legacy.request.parameters.height, "\(caseName) PARAM: height match")
            t.checkEqual(canonicalReq.parameters.fps, legacy.request.parameters.fps, "\(caseName) PARAM: fps match")
            t.checkEqual(canonicalReq.parameters.numFrames, legacy.request.parameters.numFrames, "\(caseName) PARAM: numFrames match")
            t.checkEqual(canonicalReq.parameters.numInferenceSteps, legacy.request.parameters.numInferenceSteps, "\(caseName) PARAM: steps match")
            t.checkEqual(canonicalReq.parameters.seed, legacy.request.parameters.seed, "\(caseName) PARAM: seed match")
            t.checkEqual(canonicalReq.parameters.imageStrength, legacy.request.parameters.imageStrength, "\(caseName) PARAM: imageStrength match")
            t.checkEqual(canonicalReq.disableAudio, legacy.request.disableAudio, "\(caseName) PARAM: disableAudio match")
            t.checkEqual(canonicalReq.targetDurationSeconds, legacy.request.targetDurationSeconds, "\(caseName) PARAM: targetDurationSeconds match")
            t.checkEqual(canonicalReq.presetResolutionOrientation, legacy.request.presetResolutionOrientation, "\(caseName) PARAM: orientation match")
            t.checkEqual(canonicalReq.preset, legacy.request.preset, "\(caseName) PARAM: preset match")
            t.checkEqual(canonicalReq.qualityMode, legacy.request.qualityMode, "\(caseName) PARAM: qualityMode match")

            // MODEL / ENGINE PARITY
            t.checkEqual(canonicalReq.modelId, legacy.request.modelId, "\(caseName) MODEL: modelId match")
            t.checkEqual(canonicalReq.textEncoderId, legacy.request.textEncoderId, "\(caseName) MODEL: textEncoderId match")

            // CONTEXT PARITY
            t.checkEqual(canonicalReq.id, legacy.request.id, "\(caseName) CONTEXT: id match")
            t.checkEqual(canonicalReq.sourceImagePath, legacy.request.sourceImagePath, "\(caseName) CONTEXT: sourceImagePath match")
            t.checkEqual(canonicalReq.generationSource, legacy.request.generationSource, "\(caseName) CONTEXT: generationSource match")
        }

        // 1. LTX Basic T2V
        do {
            var base = GenerationRequest(
                prompt: "",
                disableAudio: false,
                modelId: LTXModelCatalog.defaultModelID
            )
            base.parameters.width = 768
            base.parameters.height = 512
            base.parameters.fps = 24
            base.parameters.numInferenceSteps = 30
            base.parameters.seed = 12345
            base.preset = GenerationPreset.standard.rawValue
            base.qualityMode = QualityMode.auto.rawValue

            let legacy = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "detective in library", plan: dummyPlan, base: base
            )

            // Using CanonicalShotRequestBuilder for One Shot
            let conditioning = ResolvedShotConditioningImage(
                path: base.sourceImagePath,
                imageStrength: base.parameters.imageStrength,
                effectiveSource: base.sourceImagePath != nil ? .explicitStartingImage : .none
            )
            let spec = CanonicalShotSpecification(
                id: base.id,
                prompt: legacy.compiledPrompt,
                brief: base.brief ?? "detective in library",
                modelID: base.modelId,
                textEncoderID: base.textEncoderId,
                preset: base.preset,
                qualityMode: base.qualityMode,
                width: base.parameters.width,
                height: base.parameters.height,
                fps: base.parameters.fps,
                numInferenceSteps: base.parameters.numInferenceSteps,
                targetDurationSeconds: base.targetDurationSeconds ?? dummyPlan.durationIntentSeconds,
                audioEnabled: !base.disableAudio,
                seed: base.parameters.seed,
                conditioningImage: conditioning,
                orientation: base.presetResolutionOrientation,
                generationSource: base.generationSource ?? "oneShot",
                createdAt: base.createdAt,
                status: base.status
            )
            let (req, _, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)

            assertOneShotParity(legacy: legacy, canonicalReq: req, caseName: "1. LTX Basic T2V")
        }

        // 2. LTX Starting Image (I2V)
        do {
            var base = GenerationRequest(
                prompt: "",
                sourceImagePath: "/tmp/detective.png",
                presetResolutionOrientation: .landscape,
                modelId: LTXModelCatalog.defaultModelID
            )
            base.parameters.width = 768
            base.parameters.height = 512
            base.parameters.fps = 24
            base.parameters.numInferenceSteps = 30
            base.parameters.seed = 54321
            base.preset = GenerationPreset.standard.rawValue
            base.qualityMode = QualityMode.auto.rawValue

            let legacy = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "detective examining book", plan: dummyPlan, base: base
            )

            let conditioning = ResolvedShotConditioningImage(
                path: base.sourceImagePath,
                imageStrength: base.parameters.imageStrength,
                effectiveSource: .explicitStartingImage
            )
            let spec = CanonicalShotSpecification(
                id: base.id,
                prompt: legacy.compiledPrompt,
                brief: "detective examining book",
                modelID: base.modelId,
                textEncoderID: base.textEncoderId,
                preset: base.preset,
                qualityMode: base.qualityMode,
                width: base.parameters.width,
                height: base.parameters.height,
                fps: base.parameters.fps,
                numInferenceSteps: base.parameters.numInferenceSteps,
                targetDurationSeconds: base.targetDurationSeconds ?? dummyPlan.durationIntentSeconds,
                audioEnabled: !base.disableAudio,
                seed: base.parameters.seed,
                conditioningImage: conditioning,
                orientation: base.presetResolutionOrientation,
                generationSource: base.generationSource ?? "oneShot",
                createdAt: base.createdAt,
                status: base.status
            )
            let (req, _, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)

            assertOneShotParity(legacy: legacy, canonicalReq: req, caseName: "2. LTX Starting Image")
        }

        // 3. H3 Basic T2V
        do {
            var base = GenerationRequest(prompt: "", modelId: MiniMaxH3Configuration.modelID)
            base.parameters.width = 512
            base.parameters.height = 288
            base.parameters.fps = 24
            base.parameters.numInferenceSteps = 8
            base.parameters.seed = 999
            base.preset = GenerationPreset.standard.rawValue
            base.qualityMode = QualityMode.auto.rawValue
            base.minimaxH3Endpoint = "http://127.0.0.1:8000"

            let legacy = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "h3 room shot", plan: dummyPlan, base: base
            )

            let conditioning = ResolvedShotConditioningImage(
                path: base.sourceImagePath,
                imageStrength: base.parameters.imageStrength,
                effectiveSource: .none
            )
            let spec = CanonicalShotSpecification(
                id: base.id,
                prompt: legacy.compiledPrompt,
                brief: "h3 room shot",
                modelID: base.modelId,
                textEncoderID: base.textEncoderId,
                preset: base.preset,
                qualityMode: base.qualityMode,
                width: base.parameters.width,
                height: base.parameters.height,
                fps: base.parameters.fps,
                numInferenceSteps: base.parameters.numInferenceSteps,
                targetDurationSeconds: base.targetDurationSeconds ?? dummyPlan.durationIntentSeconds,
                audioEnabled: !base.disableAudio,
                seed: base.parameters.seed,
                conditioningImage: conditioning,
                orientation: base.presetResolutionOrientation,
                generationSource: base.generationSource ?? "oneShot",
                createdAt: base.createdAt,
                status: base.status,
                minimaxH3Endpoint: base.minimaxH3Endpoint
            )
            let (req, _, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)

            assertOneShotParity(legacy: legacy, canonicalReq: req, caseName: "3. H3 Basic T2V")
        }

        // 4. H3 Starting Image
        do {
            var base = GenerationRequest(
                prompt: "",
                sourceImagePath: "/tmp/h3_start.png",
                modelId: MiniMaxH3Configuration.modelID
            )
            base.parameters.width = 512
            base.parameters.height = 288
            base.parameters.fps = 24
            base.parameters.numInferenceSteps = 8
            base.preset = GenerationPreset.standard.rawValue
            base.qualityMode = QualityMode.auto.rawValue

            let legacy = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "h3 start image", plan: dummyPlan, base: base
            )

            let conditioning = ResolvedShotConditioningImage(
                path: base.sourceImagePath,
                imageStrength: base.parameters.imageStrength,
                effectiveSource: .explicitStartingImage
            )
            let spec = CanonicalShotSpecification(
                id: base.id,
                prompt: legacy.compiledPrompt,
                brief: "h3 start image",
                modelID: base.modelId,
                textEncoderID: base.textEncoderId,
                preset: base.preset,
                qualityMode: base.qualityMode,
                width: base.parameters.width,
                height: base.parameters.height,
                fps: base.parameters.fps,
                numInferenceSteps: base.parameters.numInferenceSteps,
                targetDurationSeconds: base.targetDurationSeconds ?? dummyPlan.durationIntentSeconds,
                audioEnabled: !base.disableAudio,
                seed: base.parameters.seed,
                conditioningImage: conditioning,
                orientation: base.presetResolutionOrientation,
                generationSource: base.generationSource ?? "oneShot",
                createdAt: base.createdAt,
                status: base.status
            )
            let (req, _, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)

            assertOneShotParity(legacy: legacy, canonicalReq: req, caseName: "4. H3 Starting Image")
        }

        // 5 & 6. Audio ON vs Audio OFF
        do {
            let baseOn = GenerationRequest(
                prompt: "", disableAudio: false, modelId: LTXModelCatalog.defaultModelID
            )
            let legacyOn = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "audio on", plan: dummyPlan, base: baseOn
            )
            let specOn = CanonicalShotSpecification(
                id: baseOn.id, prompt: legacyOn.compiledPrompt, brief: "audio on",
                modelID: baseOn.modelId, textEncoderID: baseOn.textEncoderId,
                preset: baseOn.preset, qualityMode: baseOn.qualityMode,
                width: baseOn.parameters.width, height: baseOn.parameters.height,
                fps: baseOn.parameters.fps, numInferenceSteps: baseOn.parameters.numInferenceSteps,
                targetDurationSeconds: 5.0, audioEnabled: true, seed: baseOn.parameters.seed,
                orientation: baseOn.presetResolutionOrientation,
                generationSource: baseOn.generationSource ?? "oneShot"
            )
            let (reqOn, _, _) = CanonicalShotRequestBuilder.buildRequest(from: specOn)
            assertOneShotParity(legacy: legacyOn, canonicalReq: reqOn, caseName: "5. Audio ON")

            let baseOff = GenerationRequest(
                prompt: "", disableAudio: true, modelId: LTXModelCatalog.defaultModelID
            )
            let legacyOff = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "audio off", plan: dummyPlan, base: baseOff
            )
            let specOff = CanonicalShotSpecification(
                id: baseOff.id, prompt: legacyOff.compiledPrompt, brief: "audio off",
                modelID: baseOff.modelId, textEncoderID: baseOff.textEncoderId,
                preset: baseOff.preset, qualityMode: baseOff.qualityMode,
                width: baseOff.parameters.width, height: baseOff.parameters.height,
                fps: baseOff.parameters.fps, numInferenceSteps: baseOff.parameters.numInferenceSteps,
                targetDurationSeconds: 5.0, audioEnabled: false, seed: baseOff.parameters.seed,
                orientation: baseOff.presetResolutionOrientation,
                generationSource: baseOff.generationSource ?? "oneShot"
            )
            let (reqOff, _, _) = CanonicalShotRequestBuilder.buildRequest(from: specOff)
            assertOneShotParity(legacy: legacyOff, canonicalReq: reqOff, caseName: "6. Audio OFF")
        }

        // 7. Explicit Seed
        do {
            var base = GenerationRequest(prompt: "", modelId: LTXModelCatalog.defaultModelID)
            base.parameters.seed = 88776655
            let legacy = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "seed test", plan: dummyPlan, base: base
            )
            let spec = CanonicalShotSpecification(
                id: base.id, prompt: legacy.compiledPrompt, brief: "seed test",
                modelID: base.modelId, textEncoderID: base.textEncoderId,
                preset: base.preset, qualityMode: base.qualityMode,
                width: base.parameters.width, height: base.parameters.height,
                fps: base.parameters.fps, numInferenceSteps: base.parameters.numInferenceSteps,
                targetDurationSeconds: 5.0, audioEnabled: true, seed: 88776655,
                orientation: base.presetResolutionOrientation,
                generationSource: base.generationSource ?? "oneShot"
            )
            let (req, _, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)
            assertOneShotParity(legacy: legacy, canonicalReq: req, caseName: "7. Explicit Seed")
        }

        // 8. Target duration / frames calculation (2.0s -> 49 frames)
        do {
            let plan2s = OneShotPlan(
                camera: "pan", action: "walk", acting: nil, motion: nil, lighting: "day",
                dialogue: [], audioCues: [], durationIntentSeconds: 2.0
            )
            let base = GenerationRequest(prompt: "", modelId: LTXModelCatalog.defaultModelID)
            let legacy = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "2s duration", plan: plan2s, base: base
            )
            let spec = CanonicalShotSpecification(
                id: base.id, prompt: legacy.compiledPrompt, brief: "2s duration",
                modelID: base.modelId, textEncoderID: base.textEncoderId,
                preset: base.preset, qualityMode: base.qualityMode,
                width: base.parameters.width, height: base.parameters.height,
                fps: base.parameters.fps, numInferenceSteps: base.parameters.numInferenceSteps,
                targetDurationSeconds: 2.0, audioEnabled: true, seed: base.parameters.seed,
                orientation: base.presetResolutionOrientation,
                generationSource: base.generationSource ?? "oneShot"
            )
            let (req, _, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)
            assertOneShotParity(legacy: legacy, canonicalReq: req, caseName: "8. Target Duration (2s)")
            t.checkEqual(req.parameters.numFrames, 49, "8. numFrames is 49 for 2s")
        }

        // 9. Custom frame override (Custom preset)
        do {
            var base = GenerationRequest(prompt: "", modelId: LTXModelCatalog.defaultModelID)
            base.preset = GenerationPreset.custom.rawValue
            base.qualityMode = QualityMode.advanced.rawValue
            base.parameters.numFrames = 73
            let legacy = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "custom override", plan: dummyPlan, base: base
            )
            let spec = CanonicalShotSpecification(
                id: base.id, prompt: legacy.compiledPrompt, brief: "custom override",
                modelID: base.modelId, textEncoderID: base.textEncoderId,
                preset: base.preset, qualityMode: base.qualityMode,
                width: base.parameters.width, height: base.parameters.height,
                fps: base.parameters.fps, numInferenceSteps: base.parameters.numInferenceSteps,
                targetDurationSeconds: dummyPlan.durationIntentSeconds,
                numFramesOverride: 73,
                audioEnabled: true, seed: base.parameters.seed,
                orientation: base.presetResolutionOrientation,
                generationSource: base.generationSource ?? "oneShot"
            )
            let (req, _, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)
            assertOneShotParity(legacy: legacy, canonicalReq: req, caseName: "9. Custom numFramesOverride")
            t.checkEqual(req.parameters.numFrames, 73, "9. numFramesOverride 73 preserved")
            t.checkEqual(req.targetDurationSeconds, nil, "9. targetDurationSeconds cleared for custom")
        }

        // 14 & 15. Dialogue & Audio Policy Guard Idempotence in Prompt
        do {
            let planWithDialogue = OneShotPlan(
                camera: "static eye-level",
                action: "A woman whispers into the telephone receiver.",
                acting: nil,
                motion: nil,
                lighting: "high-contrast shadows",
                dialogue: [OneShotPlan.DialogueLine(speaker: "Woman", text: "We must meet tonight at the clocktower.")],
                audioCues: [],
                durationIntentSeconds: 5.0
            )
            let base = GenerationRequest(prompt: "", modelId: LTXModelCatalog.defaultModelID)
            let legacy = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "whisper on phone", plan: planWithDialogue, base: base
            )
            t.check(legacy.compiledPrompt.contains("We must meet tonight at the clocktower."), "14. Dialogue preserved")
            t.check(legacy.compiledPrompt.contains(PerShotAudioPolicy.generationGuard), "15. Audio guard present")

            let spec = CanonicalShotSpecification(
                id: base.id, prompt: legacy.compiledPrompt, brief: "whisper on phone",
                modelID: base.modelId, textEncoderID: base.textEncoderId,
                preset: base.preset, qualityMode: base.qualityMode,
                width: base.parameters.width, height: base.parameters.height,
                fps: base.parameters.fps, numInferenceSteps: base.parameters.numInferenceSteps,
                targetDurationSeconds: 5.0, audioEnabled: true, seed: base.parameters.seed,
                orientation: base.presetResolutionOrientation,
                generationSource: base.generationSource ?? "oneShot"
            )
            let (req, _, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)
            assertOneShotParity(legacy: legacy, canonicalReq: req, caseName: "14/15. Dialogue & Audio Guard")
        }

        // 17. ProductionJobSnapshot creation parity
        do {
            var base = GenerationRequest(prompt: "", modelId: LTXModelCatalog.defaultModelID)
            base.parameters.seed = 777123
            let legacy = LegacyOneShotRequestReferenceBuilder.buildRequest(
                brief: "snapshot parity brief", plan: dummyPlan, base: base
            )

            var snapshotLegacy = ProductionJobSnapshot()
            snapshotLegacy.brief = "snapshot parity brief"
            snapshotLegacy.prompt = legacy.request.prompt
            snapshotLegacy.pendingRequests = [legacy.request]
            snapshotLegacy.seed = legacy.request.parameters.seed

            let spec = CanonicalShotSpecification(
                id: base.id, prompt: legacy.compiledPrompt, brief: "snapshot parity brief",
                modelID: base.modelId, textEncoderID: base.textEncoderId,
                preset: base.preset, qualityMode: base.qualityMode,
                width: base.parameters.width, height: base.parameters.height,
                fps: base.parameters.fps, numInferenceSteps: base.parameters.numInferenceSteps,
                targetDurationSeconds: 5.0, audioEnabled: true, seed: base.parameters.seed,
                orientation: base.presetResolutionOrientation,
                generationSource: base.generationSource ?? "oneShot"
            )
            let (reqCanonical, _, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)

            var snapshotCanonical = ProductionJobSnapshot()
            snapshotCanonical.brief = "snapshot parity brief"
            snapshotCanonical.prompt = reqCanonical.prompt
            snapshotCanonical.pendingRequests = [reqCanonical]
            snapshotCanonical.seed = reqCanonical.parameters.seed

            t.checkEqual(snapshotCanonical.brief, snapshotLegacy.brief, "17. snapshot brief match")
            t.checkEqual(snapshotCanonical.prompt, snapshotLegacy.prompt, "17. snapshot prompt match")
            t.checkEqual(snapshotCanonical.seed, snapshotLegacy.seed, "17. snapshot seed match")
            t.checkEqual(snapshotCanonical.pendingRequests.count, snapshotLegacy.pendingRequests.count, "17. pendingRequests count match")
            t.checkEqual(snapshotCanonical.pendingRequests[0].id, snapshotLegacy.pendingRequests[0].id, "17. request ID match")
        }

        // ====================================================================
        // PHASE 2.7 — MAKE CANONICAL SHOT BUILDER SURFACE-AGNOSTIC
        // ====================================================================

        // 18. LTX 15-second One Shot Production Pipeline via LocalDirector
        do {
            let base = GenerationRequest(
                prompt: "",
                modelId: LTXModelCatalog.defaultModelID,
                parameters: GenerationParameters.default,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 15.0,
                generationSource: "oneShot"
            )

            let scriptedPlanJSON = """
            {"camera":"epic wide drone orbit","action":"A ship sails across the vast ocean during sunset.","acting":"peaceful, cinematic","motion":"steady glide","lighting":"golden hour reflection on calm waters","dialogue":[],"audioCues":["ocean waves","wind"],"durationIntentSeconds":15}
            """
            let mockProvider = MockDirectorProvider(responses: [scriptedPlanJSON])
            let director = LocalDirector(providers: [mockProvider])
            let sem = DispatchSemaphore(value: 0)
            Task {
                do {
                    let (req, _, _) = try await director.makeRequest(brief: "ocean sunset 15s", base: base)
                    t.checkEqual(req.targetDurationSeconds, 15.0, "18. 15s targetDuration preserved in request")
                    t.checkEqual(req.parameters.numFrames, 361, "18. 361 frames assembled for One Shot LTX 15s")
                    t.checkEqual(req.parameters.fps, 24, "18. fps is 24")
                } catch {
                    t.check(false, "18. LocalDirector.makeRequest failed: \(error)")
                }
                sem.signal()
            }
            sem.wait()
        }

        // 19. Builder Surface-Agnostic Invariants
        do {
            // (a) generationSource = "oneShot" but override = nil -> builder defaults to 241
            let oneShotNoOverrideSpec = CanonicalShotSpecification(
                prompt: "One shot without explicit override",
                modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue,
                width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                targetDurationSeconds: 15.0,
                maximumFrameCountOverride: nil,
                generationSource: "oneShot"
            )
            let (reqNoOverride, _, _) = CanonicalShotRequestBuilder.buildRequest(from: oneShotNoOverrideSpec)
            t.checkEqual(reqNoOverride.parameters.numFrames, 241, "19a. Builder does NOT infer 361 without explicit override even if generationSource is oneShot")

            // (b) arbitrary non-oneShot generationSource with explicit override = 361 -> honors 361
            let customSourceOverrideSpec = CanonicalShotSpecification(
                prompt: "Custom test source with explicit override",
                modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue,
                width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                targetDurationSeconds: 15.0,
                maximumFrameCountOverride: PromptCompiler.oneShotMaximumFrameCount,
                generationSource: "arbitrary_custom_pipeline"
            )
            let (reqCustomOverride, _, _) = CanonicalShotRequestBuilder.buildRequest(from: customSourceOverrideSpec)
            t.checkEqual(reqCustomOverride.parameters.numFrames, 361, "19b. Builder honors explicit 361 override for arbitrary generationSource")

            // (c) Storyboard / Auto Movie default specification -> 241
            let storyboardSpec = CanonicalShotSpecification(
                prompt: "Storyboard shot with 15s requested duration",
                modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue,
                width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                targetDurationSeconds: 15.0,
                maximumFrameCountOverride: nil,
                generationSource: "storyboard"
            )
            let (sbReq, _, _) = CanonicalShotRequestBuilder.buildRequest(from: storyboardSpec)
            t.checkEqual(sbReq.parameters.numFrames, 241, "19c. Storyboard 15s request clamped to historical 241 frames")
        }

        // 20. Explicit Upper Bound Clamping
        do {
            t.checkEqual(PromptCompiler.frameCount(forSeconds: 2.0, fps: 24), 49, "20. 2.0s -> 49 frames unchanged")
            t.checkEqual(PromptCompiler.frameCount(forSeconds: 5.0, fps: 24), 121, "20. 5.0s -> 121 frames unchanged")
            t.checkEqual(PromptCompiler.frameCount(forSeconds: 10.0, fps: 24), 241, "20. 10.0s -> 241 frames unchanged")
            t.checkEqual(PromptCompiler.frameCount(forSeconds: 15.0, fps: 24), 241, "20. Generic 15.0s defaults to 241 frames")
            t.checkEqual(
                PromptCompiler.frameCount(forSeconds: 15.0, fps: 24, maximumFrameCount: PromptCompiler.oneShotMaximumFrameCount),
                361, "20. One Shot 15.0s resolves to 361 frames"
            )
            t.checkEqual(
                PromptCompiler.frameCount(forSeconds: 16.0, fps: 24, maximumFrameCount: PromptCompiler.oneShotMaximumFrameCount),
                361, "20. One Shot 16.0s clamped to 361 frames"
            )
            t.checkEqual(
                PromptCompiler.frameCount(forSeconds: 20.0, fps: 24, maximumFrameCount: PromptCompiler.oneShotMaximumFrameCount),
                361, "20. One Shot 20.0s clamped to 361 frames"
            )
            t.checkEqual(
                PromptCompiler.frameCount(forSeconds: 60.0, fps: 24, maximumFrameCount: PromptCompiler.oneShotMaximumFrameCount),
                361, "20. One Shot 60.0s clamped to 361 frames"
            )
        }

        // 21. H3 15-second Policy Resolution (Fails closed above 9.54s)
        do {
            t.checkThrows(
                MiniMaxH3Error.unsupportedCapability("shot durations above the proven 9.54-second chain limit"),
                "21. H3 15s request fails closed via proven chain policy") {
                    _ = try MiniMaxH3DurationPolicy.plan(requestedDurationSeconds: 15.0)
                }

            let h3MaxPlan = try MiniMaxH3DurationPolicy.plan(requestedDurationSeconds: 9.5)
            t.checkEqual(h3MaxPlan.chainWindows, 6, "21. H3 maximum supported chain is 6 windows")
            t.checkEqual(h3MaxPlan.expectedTotalFrames, 229, "21. H3 maximum expected frames is 229")
            t.checkEqual(h3MaxPlan.expectedDurationSeconds, 229.0 / 24.0, "21. H3 maximum duration is 9.5416s")
        }

        // 22. Auto Movie & Storyboard Max Duration Invariants
        do {
            t.checkEqual(AutoMovieDurationPlanner.maximumFrameCount, 241, "22. AutoMovieDurationPlanner max frames remains 241")
        }

        // 23. Preflight and Generation Frame Parity (OneShotDurationPolicy & AutoQualityEngine)
        do {
            // (a) LTX One Shot 15s Preflight parity
            let oneShot15sReq = GenerationRequest(
                prompt: "One Shot 15s preflight test",
                modelId: LTXModelCatalog.defaultModelID,
                parameters: GenerationParameters.default,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 15.0,
                generationSource: "oneShot"
            )
            let preflight15s = GenerationSettingsResolver.resolveForPreflight(request: oneShot15sReq).request
            t.checkEqual(preflight15s.parameters.numFrames, 361, "23a. One Shot LTX 15s preflight resolves 361 frames")

            // (b) LTX One Shot 10s Preflight parity
            let oneShot10sReq = GenerationRequest(
                prompt: "One Shot 10s preflight test",
                modelId: LTXModelCatalog.defaultModelID,
                parameters: GenerationParameters.default,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 10.0,
                generationSource: "oneShot"
            )
            let preflight10s = GenerationSettingsResolver.resolveForPreflight(request: oneShot10sReq).request
            t.checkEqual(preflight10s.parameters.numFrames, 241, "23b. One Shot LTX 10s preflight resolves 241 frames")

            // (c) LTX One Shot 5s Preflight parity
            let oneShot5sReq = GenerationRequest(
                prompt: "One Shot 5s preflight test",
                modelId: LTXModelCatalog.defaultModelID,
                parameters: GenerationParameters.default,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 5.0,
                generationSource: "oneShot"
            )
            let preflight5s = GenerationSettingsResolver.resolveForPreflight(request: oneShot5sReq).request
            t.checkEqual(preflight5s.parameters.numFrames, 121, "23c. One Shot LTX 5s preflight resolves 121 frames")

            // (d) Storyboard 15s Preflight parity (clamped to 241)
            let storyboard15sReq = GenerationRequest(
                prompt: "Storyboard 15s preflight test",
                modelId: LTXModelCatalog.defaultModelID,
                parameters: GenerationParameters.default,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 15.0,
                generationSource: "storyboard"
            )
            let sbPreflight15s = GenerationSettingsResolver.resolveForPreflight(request: storyboard15sReq).request
            t.checkEqual(sbPreflight15s.parameters.numFrames, 241, "23d. Storyboard 15s preflight clamped to 241 frames")

            // (e) OneShotDurationPolicy Unit Contracts
            t.checkEqual(OneShotDurationPolicy.maximumSelectableSeconds(for: LTXModelCatalog.defaultModelID), 15.0, "23e. LTX UI max selectable is 15s")
            t.checkEqual(OneShotDurationPolicy.maximumSelectableSeconds(for: MiniMaxH3Configuration.modelID), 9.0, "23e. H3 UI max selectable is 9s")
            t.checkEqual(OneShotDurationPolicy.maximumFrameCount(for: LTXModelCatalog.defaultModelID), 361, "23e. LTX technical max frame ceiling is 361")
            t.check(OneShotDurationPolicy.maximumFrameCount(for: MiniMaxH3Configuration.modelID) == nil, "23e. H3 technical frame override is nil")
        }

        // ====================================================================
        // PHASE 3A — ONE SHOT DIRECTOR ON / OFF
        // ====================================================================

        // 24. Characterization: Director ON Full Request Pipeline
        do {
            let scriptedPlanJSON = """
            {"camera":"slow pan right","action":"A detective examines clues in a dark room.","acting":"intense focus","motion":"deliberate","lighting":"moonlight through blinds","dialogue":[{"speaker":"Detective","text":"Found it."}],"audioCues":["floorboard creak"],"durationIntentSeconds":10}
            """
            let mockProvider = MockDirectorProvider(responses: [scriptedPlanJSON, scriptedPlanJSON, scriptedPlanJSON, scriptedPlanJSON])
            let director = LocalDirector(providers: [mockProvider])

            // (a) LTX T2V + Audio ON + 10s + seed + dialogue
            var paramsLTX = GenerationParameters.default
            paramsLTX.seed = 998877
            paramsLTX.numFrames = 241
            paramsLTX.numInferenceSteps = 30
            let baseLTX = GenerationRequest(
                prompt: "detective in room",
                brief: "detective in room",
                sourceImagePath: nil,
                disableAudio: false,
                modelId: LTXModelCatalog.defaultModelID,
                textEncoderId: LTXTextEncoderCatalog.defaultTextEncoderID,
                parameters: paramsLTX,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 10.0,
                generationSource: "oneShot"
            )

            let sem = DispatchSemaphore(value: 0)
            Task {
                do {
                    let (req, plan, providerName) = try await director.makeRequest(brief: "detective in room", base: baseLTX)
                    t.checkEqual(providerName, "mock", "24a. Provider name is mock")
                    t.check(plan.action.contains("detective examines clues"), "24a. Plan action parsed")
                    t.check(req.prompt.contains("Detective says: \"Found it.\""), "24a. Dialogue preserved in compiled prompt")
                    t.check(req.prompt.contains("Audio policy: No music"), "24a. Audio guard present in compiled prompt")
                    t.checkEqual(req.parameters.numFrames, 241, "24a. 10s duration gives 241 frames")
                    t.checkEqual(req.parameters.seed, 998877, "24a. Explicit seed preserved")
                    t.checkEqual(req.disableAudio, false, "24a. Audio ON preserved")
                    t.checkEqual(req.isImageToVideo, false, "24a. T2V is not I2V")
                } catch {
                    t.check(false, "24a. Director ON LTX failed: \(error)")
                }
                sem.signal()
            }
            sem.wait()

            // (b) LTX I2V + Audio OFF
            let baseI2V = GenerationRequest(
                prompt: "detective in room",
                brief: "detective in room",
                sourceImagePath: "/tmp/fake_detective.png",
                disableAudio: true,
                modelId: LTXModelCatalog.defaultModelID,
                textEncoderId: LTXTextEncoderCatalog.defaultTextEncoderID,
                parameters: GenerationParameters.default,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 5.0,
                generationSource: "oneShot"
            )
            let sem2 = DispatchSemaphore(value: 0)
            Task {
                do {
                    let (reqI2V, _, _) = try await director.makeRequest(brief: "detective in room", base: baseI2V)
                    t.checkEqual(reqI2V.sourceImagePath, "/tmp/fake_detective.png", "24b. Source image path preserved")
                    t.checkEqual(reqI2V.isImageToVideo, true, "24b. I2V mode recognized")
                    t.checkEqual(reqI2V.disableAudio, true, "24b. Audio OFF preserved")
                    t.checkEqual(reqI2V.parameters.numFrames, 121, "24b. 5s gives 121 frames")
                } catch {
                    t.check(false, "24b. Director ON I2V failed: \(error)")
                }
                sem2.signal()
            }
            sem2.wait()
        }

        // 25. Director OFF: Pure Direct Request via CanonicalShotRequestBuilder (Zero LLM)
        do {
            // (a) LTX T2V Direct Request
            let rawPrompt = "A futuristic train glides smoothly across a neon city bridge at night."
            var paramsDirect = GenerationParameters.default
            paramsDirect.seed = 123456
            paramsDirect.numFrames = 361
            paramsDirect.numInferenceSteps = 25
            let baseLTXDirect = GenerationRequest(
                prompt: rawPrompt,
                brief: rawPrompt,
                negativePrompt: "low quality, blurry",
                sourceImagePath: nil,
                disableAudio: false,
                modelId: LTXModelCatalog.defaultModelID,
                textEncoderId: LTXTextEncoderCatalog.defaultTextEncoderID,
                parameters: paramsDirect,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 15.0,
                generationSource: "oneShot"
            )

            let (reqDirect, techPrompt) = LocalDirector.makeDirectRequest(prompt: rawPrompt, base: baseLTXDirect)

            t.check(techPrompt.contains(rawPrompt), "25a. Technical prompt contains exact raw prompt")
            t.checkEqual(reqDirect.prompt, techPrompt, "25a. Request carries technical prompt")
            t.checkEqual(reqDirect.brief, rawPrompt, "25a. Request brief matches raw prompt")
            t.checkEqual(reqDirect.negativePrompt, "low quality, blurry", "25a. Negative prompt preserved")
            t.checkEqual(reqDirect.parameters.numFrames, 361, "25a. 15s duration resolves to 361 frames")
            t.checkEqual(reqDirect.parameters.fps, 24, "25a. fps is 24")
            t.checkEqual(reqDirect.parameters.seed, 123456, "25a. Seed preserved")
            t.checkEqual(reqDirect.parameters.numInferenceSteps, 25, "25a. Steps preserved")
            t.checkEqual(reqDirect.disableAudio, false, "25a. Audio enabled preserved")
            t.checkEqual(reqDirect.generationSource, "oneShot", "25a. Generation source is oneShot")
            t.check(!reqDirect.isImageToVideo, "25a. Text-only is not I2V")

            // (b) LTX I2V Direct Request
            let baseI2VDirect = GenerationRequest(
                prompt: rawPrompt,
                brief: rawPrompt,
                sourceImagePath: "/tmp/train_starting.png",
                disableAudio: true,
                modelId: LTXModelCatalog.defaultModelID,
                textEncoderId: LTXTextEncoderCatalog.defaultTextEncoderID,
                parameters: GenerationParameters.default,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 5.0,
                generationSource: "oneShot"
            )
            let (reqI2VDirect, _) = LocalDirector.makeDirectRequest(prompt: rawPrompt, base: baseI2VDirect)
            t.checkEqual(reqI2VDirect.sourceImagePath, "/tmp/train_starting.png", "25b. Starting image preserved in Direct mode")
            t.check(reqI2VDirect.isImageToVideo, "25b. I2V mode recognized in Direct mode")
            t.checkEqual(reqI2VDirect.disableAudio, true, "25b. Audio OFF preserved")
            t.checkEqual(reqI2VDirect.parameters.numFrames, 121, "25b. 5s gives 121 frames")

            // (c) H3 T2V Direct Request
            let baseH3Direct = GenerationRequest(
                prompt: rawPrompt,
                brief: rawPrompt,
                sourceImagePath: nil,
                disableAudio: false,
                modelId: MiniMaxH3Configuration.modelID,
                textEncoderId: LTXTextEncoderCatalog.defaultTextEncoderID,
                parameters: GenerationParameters.default,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 9.0,
                generationSource: "oneShot"
            )
            let (reqH3Direct, _) = LocalDirector.makeDirectRequest(prompt: rawPrompt, base: baseH3Direct)
            t.checkEqual(reqH3Direct.modelId, MiniMaxH3Configuration.modelID, "25c. H3 model ID preserved")
            t.checkEqual(reqH3Direct.targetDurationSeconds, 9.0, "25c. H3 target duration preserved")
        }

        // 26. Special Sentinel Prompt Test for Director OFF
        do {
            let sentinelPrompt = "DIRECT_RAW_SENTINEL_42 :: subject walks left :: exact user wording"
            let baseSentinel = GenerationRequest(
                prompt: sentinelPrompt,
                brief: sentinelPrompt,
                sourceImagePath: nil,
                disableAudio: false,
                modelId: LTXModelCatalog.defaultModelID,
                textEncoderId: LTXTextEncoderCatalog.defaultTextEncoderID,
                parameters: GenerationParameters.default,
                qualityMode: QualityMode.auto.rawValue,
                preset: GenerationPreset.standard.rawValue,
                targetDurationSeconds: 5.0,
                generationSource: "oneShot"
            )

            let (sentinelReq, techPrompt) = LocalDirector.makeDirectRequest(prompt: sentinelPrompt, base: baseSentinel)

            // Pre-technical prompt parity: exactly equal to user input
            t.checkEqual(sentinelReq.brief, sentinelPrompt, "26. Pre-technical prompt exactly matches user sentinel input")

            // Technical prompt: only technical audio guard added, zero creative scene/action/camera beats
            let expectedGuard = PerShotAudioPolicy.naturalProductionSoundNoMusic.applyingPromptGuard(to: sentinelPrompt)
            t.checkEqual(techPrompt, expectedGuard, "26. Technical prompt contains ONLY technical audio guard over raw sentinel")
            t.check(!techPrompt.contains("camera"), "26. No camera beats injected")
            t.check(!techPrompt.contains("Lighting:"), "26. No lighting beats injected")
            t.check(!techPrompt.contains("says:"), "26. No dialogue beats injected")
        }
    }
}
