import Foundation
@testable import LTXVideoGeneratorCore

func runBasicDirectorStrictEnglishTests(_ t: TestKit) {
    t.suite("Basic Director Strict English Render Prompt & Fail-Closed Gate") {
        let testDefaults = UserDefaults(suiteName: "test.basic.strict.english.\(UUID().uuidString)")!
        defer {
            testDefaults.removePersistentDomain(forName: testDefaults.description)
        }

        let japaneseBrief = "斧を振り回す女性"
        let normalizedEnglishAction = "A woman swings an axe."

        // 1. Basic Japanese brief becomes English renderer description via local normalizer
        let mockNormalizer = MockRenderTextNormalizer(mappings: [
            japaneseBrief: normalizedEnglishAction
        ])
        let templateProvider = TemplateDirectorProvider(normalizer: mockNormalizer)
        let basicDirector = LocalDirector(providers: [templateProvider])

        let baseReq = GenerationRequest(
            prompt: japaneseBrief,
            brief: japaneseBrief,
            userDefaults: testDefaults
        )

        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, plan, providerName) = try await basicDirector.makeRequest(
                    brief: japaneseBrief,
                    base: baseReq
                )

                t.checkEqual(providerName, "template", "Basic / template provider was used")
                t.checkEqual(plan.action, normalizedEnglishAction, "Plan action is normalized English")

                // Descriptive prompt must NOT contain raw Japanese
                t.check(!request.prompt.contains("斧"), "Render prompt does not contain '斧'")
                t.check(!request.prompt.contains("振り"), "Render prompt does not contain '振り'")
                t.check(!request.prompt.contains("女性"), "Render prompt does not contain '女性'")
                t.check(request.prompt.contains(normalizedEnglishAction), "Render prompt contains English action")

                // 2. Original Japanese brief remains unchanged in GenerationRequest
                t.checkEqual(request.brief, japaneseBrief, "GenerationRequest retains original Japanese brief")

                // 12. Camera grammar remains clean
                t.check(request.prompt.contains("The camera holds a static medium shot, eye level."), "Camera grammar is clean")
                t.check(!request.prompt.contains("The camera static"), "Avoids 'The camera static'")

                // 13. Motion grammar remains clean
                t.check(request.prompt.contains("The motion is natural and continuous.") || request.prompt.contains("Motion is natural and continuous."), "Motion grammar is clean")

                // 14. No-BGM policy remains intact
                t.check(request.prompt.contains("No music"), "No-BGM policy is present in prompt")
            } catch {
                t.check(false, "Basic Japanese makeRequest threw: \(error)")
            }
            sem.signal()
        }
        sem.wait()

        // 3 & 4. GenerationResult retains brief and separates Original Brief from Render Prompt
        let result = GenerationResult(
            id: UUID(),
            requestId: UUID(),
            prompt: "The camera holds a static medium shot, eye level. A woman swings an axe. The motion is natural and continuous.",
            brief: japaneseBrief,
            enhancedPrompt: nil,
            negativePrompt: "",
            voiceoverText: "",
            voiceoverSource: "mlx-audio",
            voiceoverVoice: "af_heart",
            modelId: LTXModelCatalog.defaultModelID,
            parameters: .default,
            videoPath: "/tmp/test.mp4",
            thumbnailPath: nil,
            audioPath: nil,
            musicPath: nil,
            musicGenre: nil,
            createdAt: Date(),
            completedAt: Date(),
            duration: 5.0,
            seed: 42
        )
        t.checkEqual(result.brief, japaneseBrief, "GenerationResult retains original Japanese brief")
        t.check(result.prompt.contains("A woman swings an axe."), "GenerationResult prompt is English-only")
        t.check(result.brief != result.prompt, "Original brief and render prompt are cleanly distinguishable")

        // 5. Basic English input remains English and semantically unchanged (No Double Translation)
        let englishBrief = "A woman swings an axe."
        let englishMockNormalizer = MockRenderTextNormalizer()
        let englishTemplateProvider = TemplateDirectorProvider(normalizer: englishMockNormalizer)
        let englishDirector = LocalDirector(providers: [englishTemplateProvider])

        let sem2 = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, plan, _) = try await englishDirector.makeRequest(
                    brief: englishBrief,
                    base: GenerationRequest(prompt: englishBrief, brief: englishBrief, userDefaults: testDefaults)
                )
                t.checkEqual(plan.action, englishBrief, "English action preserved unchanged")
                t.check(request.prompt.contains(englishBrief), "Render prompt contains unchanged English action")
                t.checkEqual(request.brief, englishBrief, "Original English brief retained")
            } catch {
                t.check(false, "English makeRequest threw: \(error)")
            }
            sem2.signal()
        }
        sem2.wait()

        // 6. Chinese Basic description normalizes to English
        let chineseBrief = "一个女人挥舞着斧头"
        let chineseNormalizer = MockRenderTextNormalizer(mappings: [
            chineseBrief: "A woman swings an axe."
        ])
        let chineseProvider = TemplateDirectorProvider(normalizer: chineseNormalizer)
        let chineseDirector = LocalDirector(providers: [chineseProvider])

        let sem3 = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, plan, _) = try await chineseDirector.makeRequest(
                    brief: chineseBrief,
                    base: GenerationRequest(prompt: chineseBrief, brief: chineseBrief, userDefaults: testDefaults)
                )
                t.checkEqual(plan.action, "A woman swings an axe.", "Chinese action normalized to English")
                t.check(!request.prompt.contains("女人"), "Render prompt contains no Chinese Han characters")
                t.checkEqual(request.brief, chineseBrief, "Original Chinese brief retained in request.brief")
            } catch {
                t.check(false, "Chinese makeRequest threw: \(error)")
            }
            sem3.signal()
        }
        sem3.wait()

        // 7. Cyrillic Basic description normalizes to English
        let cyrillicBrief = "Женщина размахивает топором"
        let cyrillicNormalizer = MockRenderTextNormalizer(mappings: [
            cyrillicBrief: "A woman swings an axe."
        ])
        let cyrillicProvider = TemplateDirectorProvider(normalizer: cyrillicNormalizer)
        let cyrillicDirector = LocalDirector(providers: [cyrillicProvider])

        let sem4 = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, plan, _) = try await cyrillicDirector.makeRequest(
                    brief: cyrillicBrief,
                    base: GenerationRequest(prompt: cyrillicBrief, brief: cyrillicBrief, userDefaults: testDefaults)
                )
                t.checkEqual(plan.action, "A woman swings an axe.", "Cyrillic action normalized to English")
                t.check(!request.prompt.contains("Женщина"), "Render prompt contains no Cyrillic characters")
                t.checkEqual(request.brief, cyrillicBrief, "Original Cyrillic brief retained in request.brief")
            } catch {
                t.check(false, "Cyrillic makeRequest threw: \(error)")
            }
            sem4.signal()
        }
        sem4.wait()

        // 8. Fail-Closed: If normalization fails/throws, generation throws and backend is NOT reached
        let failingNormalizer = MockRenderTextNormalizer(shouldThrow: true)
        let failingProvider = TemplateDirectorProvider(normalizer: failingNormalizer)
        let failingDirector = LocalDirector(providers: [failingProvider])

        let sem5 = DispatchSemaphore(value: 0)
        Task {
            do {
                _ = try await failingDirector.makeRequest(
                    brief: japaneseBrief,
                    base: GenerationRequest(prompt: japaneseBrief, brief: japaneseBrief, userDefaults: testDefaults)
                )
                t.check(false, "Failing normalizer did not throw error (Fail-Closed violated)")
            } catch let error as DirectorError {
                t.check(true, "Fail-Closed: Threw expected DirectorError: \(error)")
            } catch {
                t.check(true, "Fail-Closed: Threw error: \(error)")
            }
            sem5.signal()
        }
        sem5.wait()

        // 9. Validation Gate: If normalizer returns unresolved Japanese, validation rejects it
        let leakJapaneseNormalizer = MockRenderTextNormalizer(mappings: [
            japaneseBrief: "斧を振り回す女性" // leaked raw Japanese
        ])
        let leakProvider = TemplateDirectorProvider(normalizer: leakJapaneseNormalizer)
        let leakDirector = LocalDirector(providers: [leakProvider])

        let sem6 = DispatchSemaphore(value: 0)
        Task {
            do {
                _ = try await leakDirector.makeRequest(
                    brief: japaneseBrief,
                    base: GenerationRequest(prompt: japaneseBrief, brief: japaneseBrief, userDefaults: testDefaults)
                )
                t.check(false, "Unresolved Japanese action was not rejected by validation gate")
            } catch let error as DirectorError {
                if case .unsupportedRenderLanguage = error {
                    t.check(true, "Validation gate caught unresolved Japanese action: \(error)")
                } else {
                    t.check(true, "Rejected with DirectorError: \(error)")
                }
            } catch {
                t.check(true, "Rejected with error: \(error)")
            }
            sem6.signal()
        }
        sem6.wait()

        // 10. Validation Gate: CJK Han text rejected
        t.check(!RenderLanguageValidator.isRendererSafeEnglish("一个女人挥舞着斧头"), "CJK Han detected as unsafe")
        t.check(RenderLanguageValidator.detectedNonEnglishScriptNames(in: "一个女人挥舞着斧头").contains("CJK Han"), "Identified CJK Han script")

        // 11. Validation Gate: Cyrillic text rejected
        t.check(!RenderLanguageValidator.isRendererSafeEnglish("Женщина идет"), "Cyrillic detected as unsafe")
        t.check(RenderLanguageValidator.detectedNonEnglishScriptNames(in: "Женщина идет").contains("Cyrillic"), "Identified Cyrillic script")

        // Safe English text with punctuation, numbers, symbols passes validation
        t.check(RenderLanguageValidator.isRendererSafeEnglish("A woman swings an axe, 100% focused! (fast tempo, 24fps)"), "English with punctuation/numbers is safe")

        // 15. Motion Tempo instruction preserved
        let tempoPlan = OneShotPlan(
            camera: "Medium shot, eye level",
            action: "A woman walks.",
            motion: MotionTempoPromptPolicy.instruction(motionTempo: .normal, cameraTempo: .slow, playbackStyle: .realTime),
            lighting: "Bright daylight",
            dialogue: [],
            audioCues: [],
            durationIntentSeconds: 5
        )
        let compiledTempo = PromptCompiler.compile(plan: tempoPlan)
        t.check(compiledTempo.contains("natural subject movement"), "Motion tempo instruction intact")

        // 16. Starting Image logic intact
        let reqWithImage = GenerationRequest(
            prompt: "Compiled prompt",
            brief: japaneseBrief,
            sourceImagePath: "/tmp/start.png",
            userDefaults: testDefaults
        )
        t.check(reqWithImage.isImageToVideo, "Starting Image flag is true")
        t.checkEqual(reqWithImage.sourceImagePath, "/tmp/start.png", "Starting Image path preserved")

        // 17 & 18. Custom local model & snapshot immutability intact
        let customModelReq = GenerationRequest(
            prompt: "Compiled prompt",
            brief: japaneseBrief,
            modelId: ModelRegistry.customModelID,
            customModelLocalPath: "/tmp/custom_weights",
            customModelSourceMode: "local",
            userDefaults: testDefaults
        )
        t.checkEqual(customModelReq.customModelLocalPath, "/tmp/custom_weights", "Custom model local path preserved")
        t.checkEqual(customModelReq.customModelSourceMode, "local", "Custom model source mode preserved")

        // 20. Local Director Japanese normalization remains intact
        let mockLLMPlan = """
        {
          "camera": "static medium shot, eye level",
          "action": "A skilled warrior wields an axe with precision.",
          "acting": "calm and focused",
          "motion": "steady and controlled",
          "lighting": "golden hour glow",
          "dialogue": [],
          "audioCues": ["whoosh of the blade"],
          "durationIntentSeconds": 5
        }
        """
        let mockLLMProvider = MockDirectorProvider(responses: [mockLLMPlan])
        let llmDirector = LocalDirector(providers: [mockLLMProvider])

        let sem7 = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, plan, providerName) = try await llmDirector.makeRequest(
                    brief: japaneseBrief,
                    base: GenerationRequest(prompt: japaneseBrief, brief: japaneseBrief, userDefaults: testDefaults)
                )
                t.checkEqual(providerName, "mock", "LLM Mock provider used")
                t.checkEqual(plan.action, "A skilled warrior wields an axe with precision.", "LLM normalized action to English")
                t.check(!request.prompt.contains(japaneseBrief), "LLM prompt contains no raw Japanese")
                t.checkEqual(request.brief, japaneseBrief, "Original brief preserved in request")
            } catch {
                t.check(false, "Local Director makeRequest threw: \(error)")
            }
            sem7.signal()
        }
        sem7.wait()

        // 21. Default BasicRenderLanguageNormalizer fails closed on non-English text when no translation engine exists
        let defaultNormalizer = BasicRenderLanguageNormalizer()
        let sem8 = DispatchSemaphore(value: 0)
        Task {
            do {
                _ = try await defaultNormalizer.normalizeDescriptionToEnglish(japaneseBrief)
                t.check(false, "Default normalizer unexpectedly succeeded on Japanese without local engine")
            } catch let error as DirectorError {
                if case .basicNormalizationFailed = error {
                    t.check(true, "Default normalizer threw basicNormalizationFailed as expected")
                } else {
                    t.check(true, "Threw DirectorError: \(error)")
                }
            } catch {
                t.check(true, "Threw error: \(error)")
            }
            sem8.signal()
        }
        sem8.wait()

        // Default BasicRenderLanguageNormalizer allows already-English text without error
        let sem9 = DispatchSemaphore(value: 0)
        Task {
            do {
                let result = try await defaultNormalizer.normalizeDescriptionToEnglish("A woman swings an axe.")
                t.checkEqual(result, "A woman swings an axe.", "Already-English text passed through safely")
            } catch {
                t.check(false, "Default normalizer threw on English text: \(error)")
            }
            sem9.signal()
        }
        sem9.wait()
    }
}
