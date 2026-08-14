import Foundation
@testable import LTXVideoGeneratorCore

func runOneShotPromptNormalizationTests(_ t: TestKit) {
    t.suite("One Shot Prompt Language Normalization & Template Grammar") {
        let testDefaults = UserDefaults(suiteName: "test.oneshot.prompt.normalization.\(UUID().uuidString)")!
        defer {
            testDefaults.removePersistentDomain(forName: testDefaults.description)
        }

        // 1. Japanese One Shot brief normalized by LocalDirector produces clean English render prompt
        let mockJapanesePlan = """
        {
          "camera": "static medium shot, eye level",
          "action": "A woman swings an axe with focused determination.",
          "acting": "intense and sharp gaze",
          "motion": "rapid and dynamic",
          "lighting": "soft morning sunlight",
          "dialogue": [],
          "audioCues": ["whoosh of the axe", "wood splintering"],
          "durationIntentSeconds": 5
        }
        """
        let mockProvider = MockDirectorProvider(responses: [mockJapanesePlan])
        let director = LocalDirector(providers: [mockProvider])

        let japaneseBrief = "斧を振り回す女性"
        let baseReq = GenerationRequest(
            prompt: japaneseBrief,
            brief: japaneseBrief,
            userDefaults: testDefaults
        )

        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, plan, providerName) = try await director.makeRequest(
                    brief: japaneseBrief,
                    base: baseReq
                )

                t.checkEqual(providerName, "mock", "Mock provider executed")
                t.checkEqual(plan.action, "A woman swings an axe with focused determination.", "Director normalized action to English")
                
                // Final prompt should contain normalized English action
                t.check(request.prompt.contains("A woman swings an axe with focused determination."), "Render prompt contains normalized action")
                
                // Final prompt should NOT contain raw Japanese brief in the middle of English prose
                t.check(!request.prompt.contains(japaneseBrief), "Render prompt does not contain raw Japanese brief")
                
                // 2. Original brief remains unchanged in request.brief
                t.checkEqual(request.brief, japaneseBrief, "Request retains original Japanese brief")
                
                // 6. Camera template grammar is clean and valid
                t.check(request.prompt.contains("The camera holds a static medium shot, eye level."), "Camera sentence formatted cleanly (no 'The camera static')")
                t.check(!request.prompt.contains("The camera static"), "Malformed 'The camera static' is not present")
                
                // 7. Motion template avoids duplicated 'motion ... motion'
                t.check(!request.prompt.contains("motion is rapid and dynamic motion"), "Motion does not duplicate 'motion'")
                
                // 8. Audio policy (No-BGM) remains present
                t.check(request.prompt.contains("No music"), "Audio policy is preserved in compiled prompt")
            } catch {
                t.check(false, "makeRequest threw unexpected error: \(error)")
            }
            sem.signal()
        }
        sem.wait()

        // 3. English user brief remains valid and is not broken
        let englishPlan = """
        {
          "camera": "wide establishing shot",
          "action": "A lone rider travels across the desert dunes.",
          "acting": "calm posture",
          "motion": "steady and continuous",
          "lighting": "harsh afternoon glare",
          "dialogue": [],
          "audioCues": ["wind blowing sand"],
          "durationIntentSeconds": 5
        }
        """
        let mockEnglishProvider = MockDirectorProvider(responses: [englishPlan])
        let englishDirector = LocalDirector(providers: [mockEnglishProvider])
        let englishBrief = "A lone rider in the desert"

        let sem2 = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, _, _) = try await englishDirector.makeRequest(
                    brief: englishBrief,
                    base: GenerationRequest(prompt: englishBrief, brief: englishBrief, userDefaults: testDefaults)
                )
                t.check(request.prompt.contains("wide establishing shot"), "English camera formatted cleanly")
                t.check(request.prompt.contains("A lone rider travels across the desert dunes."), "English action included")
                t.checkEqual(request.brief, englishBrief, "Original English brief retained")
            } catch {
                t.check(false, "English makeRequest threw: \(error)")
            }
            sem2.signal()
        }
        sem2.wait()

        // 4. Basic / Template fallback is structurally formatted rather than malformed English
        let templateProvider = TemplateDirectorProvider()
        let templateDirector = LocalDirector(providers: [templateProvider])

        let sem3 = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, plan, providerName) = try await templateDirector.makeRequest(
                    brief: japaneseBrief,
                    base: GenerationRequest(prompt: japaneseBrief, brief: japaneseBrief, userDefaults: testDefaults)
                )
                t.checkEqual(providerName, "template", "Fallback template provider executed")
                t.checkEqual(plan.action, japaneseBrief, "Fallback plan keeps brief as action")
                
                // Structured cleanly:
                t.check(request.prompt.contains("The camera holds a static medium shot, eye level."), "Fallback camera is clean")
                t.check(request.prompt.contains(japaneseBrief), "Fallback prompt includes action")
                t.check(request.prompt.contains("Motion is natural and continuous.") || request.prompt.contains("The motion is natural and continuous."), "Fallback motion is clean")
                t.check(!request.prompt.contains("The camera static"), "Fallback avoids 'The camera static'")
                t.check(!request.prompt.contains("continuous motion."), "Fallback avoids 'continuous motion.' repetition")
            } catch {
                t.check(false, "Template makeRequest threw: \(error)")
            }
            sem3.signal()
        }
        sem3.wait()

        // 5. Multilingual non-Latin test (e.g. Arabic, Cyrillic, Hindi) to ensure no ASCII-only assumptions
        let multilingualPlan = OneShotPlan(
            camera: "slow pan left",
            action: "Женщина идет по заснеженному лесу",
            acting: nil,
            motion: "gentle and slow",
            lighting: "overcast sky",
            dialogue: [],
            audioCues: ["crunching snow"],
            durationIntentSeconds: 5
        )
        let compiledMulti = PromptCompiler.compile(plan: multilingualPlan)
        t.check(compiledMulti.contains("The camera captures a slow pan left.") || compiledMulti.contains("slow pan left"), "Multilingual camera compiled")
        t.check(compiledMulti.contains("Женщина идет по заснеженному лесу."), "Multilingual Cyrillic text preserved and properly terminated")
        t.check(compiledMulti.contains("Lighting: overcast sky."), "Lighting compiled")

        // 9. Motion Tempo fields remain present/effective when using MotionTempoPromptPolicy
        let motionTempoPlan = OneShotPlan(
            camera: "Medium shot, eye level",
            action: "Character walks",
            motion: MotionTempoPromptPolicy.instruction(
                motionTempo: .normal,
                cameraTempo: .slow,
                playbackStyle: .realTime
            ),
            lighting: "Bright daylight",
            dialogue: [],
            audioCues: [],
            durationIntentSeconds: 5
        )
        let compiledMotion = PromptCompiler.compile(plan: motionTempoPlan)
        t.check(compiledMotion.contains("natural subject movement"), "Motion tempo instruction included")

        // 10. Starting Image path/identity logic remains intact
        let reqWithImage = GenerationRequest(
            prompt: "Compiled prompt",
            brief: "Short brief",
            sourceImagePath: "/tmp/starting_image.png",
            userDefaults: testDefaults
        )
        t.check(reqWithImage.isImageToVideo, "isImageToVideo remains true")
        t.checkEqual(reqWithImage.sourceImagePath, "/tmp/starting_image.png", "sourceImagePath preserved")

        // 11. Custom local model selection unchanged
        let customReq = GenerationRequest(
            prompt: "Compiled prompt",
            brief: "Short brief",
            modelId: ModelRegistry.customModelID,
            customModelLocalPath: "/tmp/custom_model",
            customModelSourceMode: "local",
            userDefaults: testDefaults
        )
        t.checkEqual(customReq.customModelLocalPath, "/tmp/custom_model", "Custom model local path preserved")
        t.checkEqual(customReq.customModelSourceMode, "local", "Custom model source mode preserved")

        // 12. GenerationResult persistence & backward compatibility
        let result = GenerationResult(
            id: UUID(),
            requestId: UUID(),
            prompt: "Render Prompt: The camera holds a static medium shot, eye level. A woman swings an axe.",
            brief: "斧を振り回す女性",
            enhancedPrompt: nil,
            negativePrompt: "",
            voiceoverText: "",
            voiceoverSource: "mlx-audio",
            voiceoverVoice: "af_heart",
            modelId: LTXModelCatalog.defaultModelID,
            parameters: .default,
            videoPath: "/tmp/output.mp4",
            thumbnailPath: nil,
            audioPath: nil,
            musicPath: nil,
            musicGenre: nil,
            createdAt: Date(),
            completedAt: Date(),
            duration: 5.0,
            seed: 42
        )
        t.checkEqual(result.brief, "斧を振り回す女性", "GenerationResult retains brief")
        t.checkEqual(result.prompt, "Render Prompt: The camera holds a static medium shot, eye level. A woman swings an axe.", "GenerationResult retains prompt")

        // JSON Round-trip test for GenerationResult
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        if let data = try? encoder.encode(result),
           let decoded = try? decoder.decode(GenerationResult.self, from: data) {
            t.checkEqual(decoded.brief, "斧を振り回す女性", "Brief round-trips through JSON")
            t.checkEqual(decoded.prompt, result.prompt, "Prompt round-trips through JSON")
        } else {
            t.check(false, "GenerationResult failed to encode/decode JSON")
        }

        // Old JSON without brief field decodes safely with brief == nil
        let legacyJSON = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "requestId": "66666666-7777-8888-9999-000000000000",
          "prompt": "Legacy prompt only",
          "negativePrompt": "",
          "voiceoverText": "",
          "voiceoverSource": "mlx-audio",
          "voiceoverVoice": "af_heart",
          "modelId": "ltx23_distilled_q4",
          "parameters": {
            "width": 768,
            "height": 512,
            "numFrames": 121,
            "fps": 24,
            "guidanceScale": 3.0,
            "numInferenceSteps": 20,
            "seed": 42,
            "vaeTilingMode": "auto",
            "imageStrength": 1.0
          },
          "videoPath": "/tmp/legacy.mp4",
          "createdAt": 1700000000,
          "completedAt": 1700000010,
          "duration": 10.0,
          "seed": 42
        }
        """.data(using: .utf8)!

        if let legacyDecoded = try? decoder.decode(GenerationResult.self, from: legacyJSON) {
            t.checkEqual(legacyDecoded.prompt, "Legacy prompt only", "Legacy prompt decoded")
            t.checkEqual(legacyDecoded.brief, nil, "Legacy missing brief safely decodes as nil")
        } else {
            t.check(false, "Legacy GenerationResult failed to decode")
        }
    }
}
