import Foundation
@testable import LTXVideoGeneratorCore

// ============================================================================
// TEST-ONLY INDEPENDENT REFERENCE IMPLEMENTATION
// Derived strictly from historical Preview 9 commit 9686ca10d842c76cca15400247577003358b2e05
// (LTXVideoGenerator/Sources/Services/TakeGenerationCoordinator.swift L120-L340).
//
// This struct does NOT invoke CanonicalShotRequestBuilder or any current
// TakeGenerationCoordinator code. It represents the ground-truth legacy behavior.
// ============================================================================
enum LegacyPreview9RequestReferenceBuilder {

    struct LegacyInput {
        var shotCompiledPrompt: String
        var shotDurationSeconds: Double
        var startingImageReferenceAssetID: UUID? = nil
        var modelID: String = LTXModelCatalog.defaultModelID
        var textEncoderID: String = LTXTextEncoderCatalog.defaultTextEncoderID
        var preset: String? = GenerationPreset.standard.rawValue
        var qualityMode: String? = QualityMode.auto.rawValue
        var width: Int = 768
        var height: Int = 512
        var fps: Int = 24
        var numInferenceSteps: Int = 30
        var numFrames: Int? = nil
        var audioEnabled: Bool = true
        var seed: Int = 42
        var sourceImagePath: String? = nil
        var usesOpeningReference: Bool = false
        var usesCharacterAnchor: Bool = false
        var usesInheritedContinuityFrame: Bool = false
        var continuityStrengthPolicy: ContinuityStrengthPolicy = .standard
        var projectResolutionOrientation: SourceImageOrientation = .none
        var generationSource: String = "storyboard"
        var projectID: UUID = UUID()
        var shotID: UUID = UUID()
        var takeID: UUID = UUID()
    }

    static func build(
        input: LegacyInput
    ) -> (request: GenerationRequest, parameters: GenerationParameters, prompt: String) {
        // 1. Historical Prompt Sanitization (Preview 9 TakeGenerationCoordinator.swift L135)
        let generationPrompt = PerShotAudioPolicy.naturalProductionSoundNoMusic
            .applyingPromptGuard(to: input.shotCompiledPrompt)

        // 2. Historical Target Duration (Preview 9 TakeGenerationCoordinator.swift L140)
        let isCustom = GenerationPreset.resolving(
            presetRaw: input.preset,
            qualityModeRaw: input.qualityMode
        ) == .custom
        let targetDuration = isCustom ? nil : input.shotDurationSeconds

        // 3. Historical Parameters Assembly (Preview 9 TakeGenerationCoordinator.swift L245-L270)
        var params = GenerationParameters.default
        params.width = input.width
        params.height = input.height
        params.fps = input.fps
        params.numFrames = isCustom
            ? (input.numFrames ?? PromptCompiler.frameCount(forSeconds: input.shotDurationSeconds, fps: input.fps))
            : PromptCompiler.frameCount(forSeconds: input.shotDurationSeconds, fps: input.fps)
        params.numInferenceSteps = input.numInferenceSteps
        params.seed = input.seed

        if input.usesOpeningReference {
            params.imageStrength = OpeningReferencePolicy.openingImageStrength
        } else if input.usesCharacterAnchor {
            params.imageStrength = CharacterAnchorPolicy.openingImageStrength
        } else if input.usesInheritedContinuityFrame {
            params.imageStrength = ContinuityStrengthResolver.strength(for: input.continuityStrengthPolicy)
        }

        // 4. Historical GenerationRequest Assembly (Preview 9 TakeGenerationCoordinator.swift L308-L325)
        let request = GenerationRequest(
            prompt: generationPrompt,
            sourceImagePath: input.sourceImagePath,
            presetResolutionOrientation: input.projectResolutionOrientation,
            disableAudio: !input.audioEnabled,
            modelId: input.modelID,
            textEncoderId: input.textEncoderID,
            parameters: params,
            qualityMode: input.qualityMode,
            preset: input.preset,
            targetDurationSeconds: targetDuration,
            generationSource: input.generationSource,
            filmProjectID: input.projectID,
            shotID: input.shotID,
            takeID: input.takeID
        )

        return (request, params, generationPrompt)
    }
}

// ============================================================================
// NON-CIRCULAR PARITY TEST SUITE
// ============================================================================
func runCanonicalShotRequestBuilderTests(_ t: TestKit) {
    t.suite("Phase 1C — Non-Circular Preview 9 Request Parity Verification") {

        // Helper to assert field-by-field parity between Legacy Reference and Canonical Builder
        func assertParity(
            legacy: (request: GenerationRequest, parameters: GenerationParameters, prompt: String),
            canonical: (request: GenerationRequest, parameters: GenerationParameters, technicalPrompt: String),
            caseName: String
        ) {
            // PROMPT PARITY (Exact string comparison)
            t.checkEqual(canonical.technicalPrompt, legacy.prompt, "\(caseName) PROMPT: exact prompt string parity")
            t.checkEqual(canonical.request.prompt, legacy.request.prompt, "\(caseName) PROMPT: request.prompt exact parity")

            // PARAMETER PARITY
            t.checkEqual(canonical.parameters.width, legacy.parameters.width, "\(caseName) PARAM: width parity")
            t.checkEqual(canonical.parameters.height, legacy.parameters.height, "\(caseName) PARAM: height parity")
            t.checkEqual(canonical.parameters.fps, legacy.parameters.fps, "\(caseName) PARAM: fps parity")
            t.checkEqual(canonical.parameters.numFrames, legacy.parameters.numFrames, "\(caseName) PARAM: numFrames parity")
            t.checkEqual(canonical.parameters.numInferenceSteps, legacy.parameters.numInferenceSteps, "\(caseName) PARAM: steps parity")
            t.checkEqual(canonical.parameters.seed, legacy.parameters.seed, "\(caseName) PARAM: seed parity")
            t.checkEqual(canonical.parameters.imageStrength, legacy.parameters.imageStrength, "\(caseName) PARAM: imageStrength parity")
            t.checkEqual(canonical.request.disableAudio, legacy.request.disableAudio, "\(caseName) PARAM: disableAudio parity")
            t.checkEqual(canonical.request.targetDurationSeconds, legacy.request.targetDurationSeconds, "\(caseName) PARAM: targetDurationSeconds parity")
            t.checkEqual(canonical.request.presetResolutionOrientation, legacy.request.presetResolutionOrientation, "\(caseName) PARAM: orientation parity")
            t.checkEqual(canonical.request.preset, legacy.request.preset, "\(caseName) PARAM: preset parity")
            t.checkEqual(canonical.request.qualityMode, legacy.request.qualityMode, "\(caseName) PARAM: qualityMode parity")

            // MODEL / ENGINE PARITY
            t.checkEqual(canonical.request.modelId, legacy.request.modelId, "\(caseName) MODEL: modelId parity")
            t.checkEqual(canonical.request.textEncoderId, legacy.request.textEncoderId, "\(caseName) MODEL: textEncoderId parity")

            // CONTEXT PARITY
            t.checkEqual(canonical.request.sourceImagePath, legacy.request.sourceImagePath, "\(caseName) CONTEXT: sourceImagePath parity")
            t.checkEqual(canonical.request.generationSource, legacy.request.generationSource, "\(caseName) CONTEXT: generationSource parity")
            t.checkEqual(canonical.request.filmProjectID, legacy.request.filmProjectID, "\(caseName) CONTEXT: filmProjectID parity")
            t.checkEqual(canonical.request.shotID, legacy.request.shotID, "\(caseName) CONTEXT: shotID parity")
            t.checkEqual(canonical.request.takeID, legacy.request.takeID, "\(caseName) CONTEXT: takeID parity")
        }

        let testProjectID = UUID()
        let testShotID = UUID()
        let testTakeID = UUID()

        // --------------------------------------------------------------------
        // Case 1: LTX Basic T2V (Standard Preset, 5.0s @ 24fps)
        // --------------------------------------------------------------------
        do {
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "A cinematic shot of a train approaching the platform at night.",
                shotDurationSeconds: 5.0,
                modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue,
                width: 768,
                height: 512,
                fps: 24,
                numInferenceSteps: 30,
                audioEnabled: true,
                seed: 42,
                projectID: testProjectID,
                shotID: testShotID,
                takeID: testTakeID
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)

            let spec = CanonicalShotSpecification(
                prompt: "A cinematic shot of a train approaching the platform at night.",
                modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue,
                width: 768,
                height: 512,
                fps: 24,
                numInferenceSteps: 30,
                targetDurationSeconds: 5.0,
                audioEnabled: true,
                seed: 42,
                generationSource: "storyboard",
                projectID: testProjectID,
                shotID: testShotID,
                takeID: testTakeID
            )
            let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)

            assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 1 (LTX Basic T2V)")
        }

        // --------------------------------------------------------------------
        // Case 2: LTX Starting Image (I2V, Landscape)
        // --------------------------------------------------------------------
        do {
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "Subject turns towards camera.",
                shotDurationSeconds: 5.0,
                width: 768,
                height: 512,
                seed: 100,
                sourceImagePath: "/path/to/start.png",
                projectResolutionOrientation: .landscape,
                projectID: testProjectID,
                shotID: testShotID,
                takeID: testTakeID
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)

            let conditioning = ResolvedShotConditioningImage(
                path: "/path/to/start.png",
                imageStrength: nil,
                effectiveSource: .explicitStartingImage
            )
            let spec = CanonicalShotSpecification(
                prompt: "Subject turns towards camera.",
                modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue,
                width: 768,
                height: 512,
                fps: 24,
                numInferenceSteps: 30,
                targetDurationSeconds: 5.0,
                audioEnabled: true,
                seed: 100,
                conditioningImage: conditioning,
                orientation: .landscape,
                generationSource: "storyboard",
                projectID: testProjectID,
                shotID: testShotID,
                takeID: testTakeID
            )
            let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)

            assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 2 (LTX Starting Image)")
        }

        // --------------------------------------------------------------------
        // Case 3: MiniMax H3 Basic Shot (512x288, 24fps, 8 steps)
        // --------------------------------------------------------------------
        do {
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "A quiet room with gentle rain outside.",
                shotDurationSeconds: 5.0,
                modelID: MiniMaxH3Configuration.modelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue,
                width: 512,
                height: 288,
                fps: 24,
                numInferenceSteps: 8,
                audioEnabled: true,
                seed: 777,
                projectID: testProjectID,
                shotID: testShotID,
                takeID: testTakeID
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)

            let spec = CanonicalShotSpecification(
                prompt: "A quiet room with gentle rain outside.",
                modelID: MiniMaxH3Configuration.modelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue,
                width: 512,
                height: 288,
                fps: 24,
                numInferenceSteps: 8,
                targetDurationSeconds: 5.0,
                audioEnabled: true,
                seed: 777,
                generationSource: "storyboard",
                projectID: testProjectID,
                shotID: testShotID,
                takeID: testTakeID
            )
            let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)

            assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 3 (H3 Basic)")
        }

        // --------------------------------------------------------------------
        // Case 4: MiniMax H3 Starting Image (Opening Reference)
        // --------------------------------------------------------------------
        do {
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "Character walks through neon street.",
                shotDurationSeconds: 5.0,
                modelID: MiniMaxH3Configuration.modelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                width: 512,
                height: 288,
                fps: 24,
                numInferenceSteps: 8,
                seed: 888,
                sourceImagePath: "/path/to/h3_anchor.png",
                usesOpeningReference: true,
                projectID: testProjectID,
                shotID: testShotID,
                takeID: testTakeID
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)

            let conditioning = ResolvedShotConditioningImage(
                path: "/path/to/h3_anchor.png",
                imageStrength: OpeningReferencePolicy.openingImageStrength,
                effectiveSource: .openingReference
            )
            let spec = CanonicalShotSpecification(
                prompt: "Character walks through neon street.",
                modelID: MiniMaxH3Configuration.modelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue,
                width: 512,
                height: 288,
                fps: 24,
                numInferenceSteps: 8,
                targetDurationSeconds: 5.0,
                audioEnabled: true,
                seed: 888,
                conditioningImage: conditioning,
                generationSource: "storyboard",
                projectID: testProjectID,
                shotID: testShotID,
                takeID: testTakeID
            )
            let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)

            assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 4 (H3 Starting Image)")
        }

        // --------------------------------------------------------------------
        // Case 5 & 6: Audio ON vs Audio OFF
        // --------------------------------------------------------------------
        do {
            let legacyOnInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "Sound enabled shot.", shotDurationSeconds: 5.0, audioEnabled: true,
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let legacyOn = LegacyPreview9RequestReferenceBuilder.build(input: legacyOnInput)
            let specOn = CanonicalShotSpecification(
                prompt: "Sound enabled shot.", modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID, preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue, width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                targetDurationSeconds: 5.0, audioEnabled: true, seed: 42, generationSource: "storyboard",
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let canonicalOn = CanonicalShotRequestBuilder.buildRequest(from: specOn)
            assertParity(legacy: legacyOn, canonical: canonicalOn, caseName: "Case 5 (Audio ON)")

            let legacyOffInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "Muted shot.", shotDurationSeconds: 5.0, audioEnabled: false,
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let legacyOff = LegacyPreview9RequestReferenceBuilder.build(input: legacyOffInput)
            let specOff = CanonicalShotSpecification(
                prompt: "Muted shot.", modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID, preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue, width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                targetDurationSeconds: 5.0, audioEnabled: false, seed: 42, generationSource: "storyboard",
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let canonicalOff = CanonicalShotRequestBuilder.buildRequest(from: specOff)
            assertParity(legacy: legacyOff, canonical: canonicalOff, caseName: "Case 6 (Audio OFF)")
        }

        // --------------------------------------------------------------------
        // Case 7: Explicit Seed Propagation
        // --------------------------------------------------------------------
        do {
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "Seed check.", shotDurationSeconds: 5.0, seed: 987654321,
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)
            let spec = CanonicalShotSpecification(
                prompt: "Seed check.", modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID, preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue, width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                targetDurationSeconds: 5.0, audioEnabled: true, seed: 987654321, generationSource: "storyboard",
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)
            assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 7 (Explicit Seed)")
        }

        // --------------------------------------------------------------------
        // Case 8: Standard Duration & Frame Calculation (2.0s & 8.0s)
        // --------------------------------------------------------------------
        do {
            for duration in [2.0, 4.0, 8.0] {
                let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                    shotCompiledPrompt: "Duration test \(duration)s", shotDurationSeconds: duration,
                    projectID: testProjectID, shotID: testShotID, takeID: testTakeID
                )
                let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)
                let spec = CanonicalShotSpecification(
                    prompt: "Duration test \(duration)s", modelID: LTXModelCatalog.defaultModelID,
                    textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID, preset: GenerationPreset.standard.rawValue,
                    qualityMode: QualityMode.auto.rawValue, width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                    targetDurationSeconds: duration, audioEnabled: true, seed: 42, generationSource: "storyboard",
                    projectID: testProjectID, shotID: testShotID, takeID: testTakeID
                )
                let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)
                assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 8 (Duration \(duration)s)")
            }
        }

        // --------------------------------------------------------------------
        // Case 9: Custom numFramesOverride (Custom preset)
        // --------------------------------------------------------------------
        do {
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "Custom frames.", shotDurationSeconds: 5.0,
                preset: GenerationPreset.custom.rawValue, qualityMode: QualityMode.advanced.rawValue,
                width: 800, height: 600, fps: 30, numInferenceSteps: 40, numFrames: 73,
                audioEnabled: false, seed: 999, projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)
            let spec = CanonicalShotSpecification(
                prompt: "Custom frames.", modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID, preset: GenerationPreset.custom.rawValue,
                qualityMode: QualityMode.advanced.rawValue, width: 800, height: 600, fps: 30, numInferenceSteps: 40,
                targetDurationSeconds: 5.0, numFramesOverride: 73, audioEnabled: false, seed: 999,
                generationSource: "storyboard", projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)
            assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 9 (Custom numFramesOverride)")
        }

        // --------------------------------------------------------------------
        // Case 10: InheritedLastFrame Strength / Source
        // --------------------------------------------------------------------
        do {
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "Inherited frame shot.", shotDurationSeconds: 5.0,
                sourceImagePath: "/path/to/inherited.png", usesInheritedContinuityFrame: true,
                continuityStrengthPolicy: .reframe,
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)
            let conditioning = ResolvedShotConditioningImage(
                path: "/path/to/inherited.png",
                imageStrength: ContinuityStrengthResolver.strength(for: .reframe),
                effectiveSource: .inheritedLastFrame
            )
            let spec = CanonicalShotSpecification(
                prompt: "Inherited frame shot.", modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID, preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue, width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                targetDurationSeconds: 5.0, audioEnabled: true, seed: 42, conditioningImage: conditioning,
                generationSource: "storyboard", projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)
            assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 10 (InheritedLastFrame)")
        }

        // --------------------------------------------------------------------
        // Case 11: CharacterAnchor Strength / Source
        // --------------------------------------------------------------------
        do {
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "Character anchor shot.", shotDurationSeconds: 5.0,
                sourceImagePath: "/path/to/anchor.png", usesCharacterAnchor: true,
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)
            let conditioning = ResolvedShotConditioningImage(
                path: "/path/to/anchor.png",
                imageStrength: CharacterAnchorPolicy.openingImageStrength,
                effectiveSource: .characterAnchor
            )
            let spec = CanonicalShotSpecification(
                prompt: "Character anchor shot.", modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID, preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue, width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                targetDurationSeconds: 5.0, audioEnabled: true, seed: 42, conditioningImage: conditioning,
                generationSource: "storyboard", projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)
            assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 11 (CharacterAnchor)")
        }

        // --------------------------------------------------------------------
        // Case 12: OpeningReference Strength / Source
        // --------------------------------------------------------------------
        do {
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: "Opening reference shot.", shotDurationSeconds: 5.0,
                sourceImagePath: "/path/to/opening.png", usesOpeningReference: true,
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)
            let conditioning = ResolvedShotConditioningImage(
                path: "/path/to/opening.png",
                imageStrength: OpeningReferencePolicy.openingImageStrength,
                effectiveSource: .openingReference
            )
            let spec = CanonicalShotSpecification(
                prompt: "Opening reference shot.", modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID, preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue, width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                targetDurationSeconds: 5.0, audioEnabled: true, seed: 42, conditioningImage: conditioning,
                generationSource: "storyboard", projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)
            assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 12 (OpeningReference)")
        }

        // --------------------------------------------------------------------
        // Case 13: Prompt Audio Guard Idempotence
        // --------------------------------------------------------------------
        do {
            let rawPrompt = "A quiet alleyway. Sound of footsteps."
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: rawPrompt, shotDurationSeconds: 5.0,
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)
            let spec = CanonicalShotSpecification(
                prompt: rawPrompt, modelID: LTXModelCatalog.defaultModelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID, preset: GenerationPreset.standard.rawValue,
                qualityMode: QualityMode.auto.rawValue, width: 768, height: 512, fps: 24, numInferenceSteps: 30,
                targetDurationSeconds: 5.0, audioEnabled: true, seed: 42, generationSource: "storyboard",
                projectID: testProjectID, shotID: testShotID, takeID: testTakeID
            )
            let canonicalOut = CanonicalShotRequestBuilder.buildRequest(from: spec)
            assertParity(legacy: legacyOut, canonical: canonicalOut, caseName: "Case 13 (Audio Guard)")
        }

        // --------------------------------------------------------------------
        // Case 14: IDs / Metadata Propagation & End-to-End Coordinator Parity
        // --------------------------------------------------------------------
        do {
            let store = FilmProjectStore.shared
            var project = FilmProject(title: "Legacy Reference Parity Project")
            project.settings.modelID = LTXModelCatalog.defaultModelID
            project.settings.textEncoderID = LTXTextEncoderCatalog.defaultTextEncoderID
            project.settings.preset = GenerationPreset.standard.rawValue
            project.settings.width = 768
            project.settings.height = 512
            project.settings.fps = 24
            project.settings.numInferenceSteps = 30
            project.settings.audioEnabled = true

            var shot = Shot(index: 0, title: "Shot 1", durationSeconds: 5.0)
            shot.compiledPrompt = "Camera pushes in on the old library door."
            project.shots = [shot]
            store.save(project)

            let coordinator = TakeGenerationCoordinator(store: store)
            let plannedRequests = try! coordinator.planTakes(
                projectID: project.id,
                shotID: shot.id,
                count: 1,
                baseSeed: 55555
            )

            let coordinatorReq = plannedRequests[0]

            // Construct legacy equivalent directly from Preview 9 reference
            let legacyInput = LegacyPreview9RequestReferenceBuilder.LegacyInput(
                shotCompiledPrompt: shot.compiledPrompt,
                shotDurationSeconds: shot.durationSeconds,
                modelID: project.settings.modelID,
                textEncoderID: project.settings.textEncoderID,
                preset: project.settings.resolvedPreset.rawValue,
                qualityMode: project.settings.qualityMode,
                width: project.settings.width,
                height: project.settings.height,
                fps: project.settings.fps,
                numInferenceSteps: project.settings.resolvedInferenceSteps,
                audioEnabled: project.settings.resolvedAudioEnabled,
                seed: 55555,
                generationSource: "storyboard",
                projectID: project.id,
                shotID: shot.id,
                takeID: coordinatorReq.takeID!
            )
            let legacyOut = LegacyPreview9RequestReferenceBuilder.build(input: legacyInput)

            // Direct comparison between coordinator result and legacy reference
            t.checkEqual(coordinatorReq.prompt, legacyOut.request.prompt, "Case 14: coordinator vs legacy prompt parity")
            t.checkEqual(coordinatorReq.modelId, legacyOut.request.modelId, "Case 14: coordinator vs legacy modelId parity")
            t.checkEqual(coordinatorReq.parameters.width, legacyOut.parameters.width, "Case 14: coordinator vs legacy width parity")
            t.checkEqual(coordinatorReq.parameters.height, legacyOut.parameters.height, "Case 14: coordinator vs legacy height parity")
            t.checkEqual(coordinatorReq.parameters.fps, legacyOut.parameters.fps, "Case 14: coordinator vs legacy fps parity")
            t.checkEqual(coordinatorReq.parameters.numFrames, legacyOut.parameters.numFrames, "Case 14: coordinator vs legacy numFrames parity")
            t.checkEqual(coordinatorReq.parameters.numInferenceSteps, legacyOut.parameters.numInferenceSteps, "Case 14: coordinator vs legacy steps parity")
            t.checkEqual(coordinatorReq.parameters.seed, legacyOut.parameters.seed, "Case 14: coordinator vs legacy seed parity")
            t.checkEqual(coordinatorReq.disableAudio, legacyOut.request.disableAudio, "Case 14: coordinator vs legacy disableAudio parity")
            t.checkEqual(coordinatorReq.filmProjectID, legacyOut.request.filmProjectID, "Case 14: coordinator vs legacy projectID parity")
            t.checkEqual(coordinatorReq.shotID, legacyOut.request.shotID, "Case 14: coordinator vs legacy shotID parity")
            t.checkEqual(coordinatorReq.takeID, legacyOut.request.takeID, "Case 14: coordinator vs legacy takeID parity")

            store.delete(project.id)
        }
    }
}
