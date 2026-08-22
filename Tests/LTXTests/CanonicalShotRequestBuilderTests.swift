import Foundation
@testable import LTXVideoGeneratorCore

func runCanonicalShotRequestBuilderTests(_ t: TestKit) {
    t.suite("Canonical Shot Request Foundation — Deterministic Parity") {

        // Case A: LTX Basic Shot (T2V, Standard Preset, 5.0s @ 24fps)
        do {
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
                generationSource: "autoMovie"
            )
            let (req, params, prompt) = CanonicalShotRequestBuilder.buildRequest(from: spec)

            t.checkEqual(req.modelId, LTXModelCatalog.defaultModelID, "Case A: modelId preserved")
            t.checkEqual(req.textEncoderId, LTXTextEncoderCatalog.defaultTextEncoderID, "Case A: textEncoderId preserved")
            t.checkEqual(params.width, 768, "Case A: width 768")
            t.checkEqual(params.height, 512, "Case A: height 512")
            t.checkEqual(params.fps, 24, "Case A: fps 24")
            t.checkEqual(params.numFrames, 121, "Case A: 5.0s @ 24fps resolves to 121 frames")
            t.checkEqual(params.numInferenceSteps, 30, "Case A: steps 30")
            t.checkEqual(params.seed, 42, "Case A: seed 42")
            t.checkEqual(req.disableAudio, false, "Case A: audio enabled")
            t.checkEqual(req.sourceImagePath, nil, "Case A: T2V sourceImagePath is nil")
            t.checkEqual(req.targetDurationSeconds, 5.0, "Case A: targetDurationSeconds 5.0")
            t.check(prompt.contains(PerShotAudioPolicy.generationGuard), "Case A: technical audio guard present")
        }

        // Case B: LTX with Starting Image (I2V)
        do {
            let conditioning = ResolvedShotConditioningImage(
                path: "/path/to/start.png",
                imageStrength: 0.85,
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
                generationSource: "autoMovie"
            )
            let (req, params, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)

            t.checkEqual(req.sourceImagePath, "/path/to/start.png", "Case B: sourceImagePath passed")
            t.checkEqual(params.imageStrength, 0.85, "Case B: imageStrength 0.85")
            t.checkEqual(req.presetResolutionOrientation, .landscape, "Case B: orientation landscape")
        }

        // Case C: H3 Basic Shot
        do {
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
                generationSource: "autoMovie"
            )
            let (req, params, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)

            t.checkEqual(req.modelId, MiniMaxH3Configuration.modelID, "Case C: H3 modelId")
            t.checkEqual(params.width, 512, "Case C: H3 width 512")
            t.checkEqual(params.height, 288, "Case C: H3 height 288")
            t.checkEqual(params.numInferenceSteps, 8, "Case C: H3 steps 8")
            t.checkEqual(req.targetDurationSeconds, 5.0, "Case C: H3 duration target 5.0s")
        }

        // Case D: H3 with Starting Image
        do {
            let conditioning = ResolvedShotConditioningImage(
                path: "/path/to/h3_anchor.png",
                imageStrength: 0.85,
                effectiveSource: .openingReference
            )
            let spec = CanonicalShotSpecification(
                prompt: "Character walks through neon street.",
                modelID: MiniMaxH3Configuration.modelID,
                textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
                width: 512,
                height: 288,
                fps: 24,
                numInferenceSteps: 8,
                targetDurationSeconds: 5.0,
                conditioningImage: conditioning,
                generationSource: "autoMovie"
            )
            let (req, params, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)

            t.checkEqual(req.sourceImagePath, "/path/to/h3_anchor.png", "Case D: H3 sourceImagePath passed")
            t.checkEqual(params.imageStrength, 0.85, "Case D: H3 imageStrength")
        }

        // Case E & F: Audio Enabled vs Disabled
        do {
            var specOn = CanonicalShotSpecification(
                prompt: "Sound on", modelID: "model", textEncoderID: "encoder",
                width: 768, height: 512, fps: 24, numInferenceSteps: 30, audioEnabled: true
            )
            let (reqOn, _, _) = CanonicalShotRequestBuilder.buildRequest(from: specOn)
            t.checkEqual(reqOn.disableAudio, false, "Case E: Audio enabled -> disableAudio = false")

            specOn.audioEnabled = false
            let (reqOff, _, _) = CanonicalShotRequestBuilder.buildRequest(from: specOn)
            t.checkEqual(reqOff.disableAudio, true, "Case F: Audio disabled -> disableAudio = true")
        }

        // Case G: Explicit Seed Preserved
        do {
            let spec = CanonicalShotSpecification(
                prompt: "Seed test", modelID: "model", textEncoderID: "encoder",
                width: 768, height: 512, fps: 24, numInferenceSteps: 30, seed: 123456789
            )
            let (_, params, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)
            t.checkEqual(params.seed, 123456789, "Case G: seed exactly preserved")
        }

        // Case H: Duration / Frame Calculation
        do {
            let spec2s = CanonicalShotSpecification(
                prompt: "2s test", modelID: "model", textEncoderID: "encoder",
                width: 768, height: 512, fps: 24, numInferenceSteps: 30, targetDurationSeconds: 2.0
            )
            let (_, params2s, _) = CanonicalShotRequestBuilder.buildRequest(from: spec2s)
            t.checkEqual(params2s.numFrames, 49, "Case H: 2.0s @ 24fps = 49 frames")

            let spec8s = CanonicalShotSpecification(
                prompt: "8s test", modelID: "model", textEncoderID: "encoder",
                width: 768, height: 512, fps: 24, numInferenceSteps: 30, targetDurationSeconds: 8.0
            )
            let (_, params8s, _) = CanonicalShotRequestBuilder.buildRequest(from: spec8s)
            t.checkEqual(params8s.numFrames, 193, "Case H: 8.0s @ 24fps = 193 frames")
        }

        // Case I: Custom Preset Handling
        do {
            let specCustom = CanonicalShotSpecification(
                prompt: "Custom test", modelID: "model", textEncoderID: "encoder",
                preset: GenerationPreset.custom.rawValue,
                qualityMode: QualityMode.advanced.rawValue,
                width: 800, height: 600, fps: 30, numInferenceSteps: 40,
                targetDurationSeconds: 5.0, numFramesOverride: 73,
                audioEnabled: false, seed: 999
            )
            let (reqCustom, paramsCustom, _) = CanonicalShotRequestBuilder.buildRequest(from: specCustom)
            t.checkEqual(paramsCustom.numFrames, 73, "Case I: Custom preset respects explicit numFramesOverride (73)")
            t.checkEqual(paramsCustom.width, 800, "Case I: Custom width 800")
            t.checkEqual(paramsCustom.height, 600, "Case I: Custom height 600")
            t.checkEqual(paramsCustom.fps, 30, "Case I: Custom fps 30")
            t.checkEqual(paramsCustom.numInferenceSteps, 40, "Case I: Custom steps 40")
            t.checkEqual(reqCustom.targetDurationSeconds, nil, "Case I: Custom preset clears targetDurationSeconds to nil")
        }

        // Case J: Continuity Source (Calibrated Strength 0.60)
        do {
            let conditioning = ResolvedShotConditioningImage(
                path: "/path/to/continuity_frame.png",
                imageStrength: 0.60,
                effectiveSource: .inheritedLastFrame
            )
            let spec = CanonicalShotSpecification(
                prompt: "Continuation shot", modelID: "model", textEncoderID: "encoder",
                width: 768, height: 512, fps: 24, numInferenceSteps: 30, targetDurationSeconds: 5.0,
                conditioningImage: conditioning
            )
            let (req, params, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)
            t.checkEqual(req.sourceImagePath, "/path/to/continuity_frame.png", "Case J: continuity frame path")
            t.checkEqual(params.imageStrength, 0.60, "Case J: calibrated continuity strength 0.60")
        }

        // Case K: Character Anchor (Strength 0.65)
        do {
            let conditioning = ResolvedShotConditioningImage(
                path: "/path/to/character_anchor.png",
                imageStrength: 0.65,
                effectiveSource: .characterAnchor
            )
            let spec = CanonicalShotSpecification(
                prompt: "Character re-anchored shot", modelID: "model", textEncoderID: "encoder",
                width: 768, height: 512, fps: 24, numInferenceSteps: 30, targetDurationSeconds: 5.0,
                conditioningImage: conditioning
            )
            let (req, params, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)
            t.checkEqual(req.sourceImagePath, "/path/to/character_anchor.png", "Case K: character anchor path")
            t.checkEqual(params.imageStrength, 0.65, "Case K: character anchor strength 0.65")
        }

        // Case L: Opening Reference (Strength 0.85)
        do {
            let conditioning = ResolvedShotConditioningImage(
                path: "/path/to/opening_ref.png",
                imageStrength: 0.85,
                effectiveSource: .openingReference
            )
            let spec = CanonicalShotSpecification(
                prompt: "Opening shot", modelID: "model", textEncoderID: "encoder",
                width: 768, height: 512, fps: 24, numInferenceSteps: 30, targetDurationSeconds: 5.0,
                conditioningImage: conditioning
            )
            let (req, params, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)
            t.checkEqual(req.sourceImagePath, "/path/to/opening_ref.png", "Case L: opening reference path")
            t.checkEqual(params.imageStrength, 0.85, "Case L: opening reference strength 0.85")
        }

        // Case M: PerShotAudioPolicy Prompt Guard Idempotence
        do {
            let rawPrompt = "A quiet alleyway. Sound of water drops."
            let spec = CanonicalShotSpecification(
                prompt: rawPrompt, modelID: "model", textEncoderID: "encoder",
                width: 768, height: 512, fps: 24, numInferenceSteps: 30
            )
            let (req1, _, prompt1) = CanonicalShotRequestBuilder.buildRequest(from: spec)
            t.check(prompt1.contains(PerShotAudioPolicy.generationGuard), "Case M: first pass adds guard")

            // Re-passing the guarded prompt must be idempotent
            var spec2 = spec
            spec2.prompt = req1.prompt
            let (_, _, prompt2) = CanonicalShotRequestBuilder.buildRequest(from: spec2)
            t.checkEqual(prompt1, prompt2, "Case M: re-compilation is idempotent (no duplicate guards)")
        }

        // Case N: TakeGenerationCoordinator Integration & Parity Test
        do {
            let store = FilmProjectStore.shared
            var project = FilmProject(title: "Parity Test Project")
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

            t.checkEqual(plannedRequests.count, 1, "Case N: planned 1 request")
            let req = plannedRequests[0]
            t.checkEqual(req.filmProjectID, project.id, "Case N: projectID matches")
            t.checkEqual(req.shotID, shot.id, "Case N: shotID matches")
            t.checkEqual(req.modelId, LTXModelCatalog.defaultModelID, "Case N: modelId matches")
            t.checkEqual(req.parameters.width, 768, "Case N: width matches")
            t.checkEqual(req.parameters.height, 512, "Case N: height matches")
            t.checkEqual(req.parameters.fps, 24, "Case N: fps matches")
            t.checkEqual(req.parameters.numFrames, 121, "Case N: numFrames matches (121)")
            t.checkEqual(req.parameters.numInferenceSteps, 30, "Case N: steps matches (30)")
            t.checkEqual(req.parameters.seed, 55555, "Case N: seed matches (55555)")
            t.checkEqual(req.disableAudio, false, "Case N: disableAudio is false")
            t.check(req.prompt.contains("Camera pushes in on the old library door."), "Case N: prompt contains shot description")
            t.check(req.prompt.contains(PerShotAudioPolicy.generationGuard), "Case N: prompt contains audio policy guard")

            // Verify Take was created in store with identical values
            let refreshedProject = store.project(id: project.id)!
            let take = refreshedProject.shots[0].takes[0]
            t.checkEqual(take.seed, 55555, "Case N: Take seed matches")
            t.checkEqual(take.promptSnapshot, req.prompt, "Case N: Take promptSnapshot matches req.prompt")
            t.checkEqual(take.settingsSnapshot.numFrames, req.parameters.numFrames, "Case N: Take frames match req frames")
            t.checkEqual(take.settingsSnapshot.width, req.parameters.width, "Case N: Take width matches req width")
            t.checkEqual(take.settingsSnapshot.height, req.parameters.height, "Case N: Take height matches req height")

            store.delete(project.id)
        }
    }
}
