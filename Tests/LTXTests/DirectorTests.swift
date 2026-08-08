import Foundation
@testable import LTXVideoGeneratorCore

/// Scripted provider for deterministic director tests.
final class MockDirectorProvider: DirectorProvider {
    let name = "mock"
    var responses: [String]
    var available: Bool
    private(set) var completeCalls = 0
    private(set) var terminated = false

    init(responses: [String], available: Bool = true) {
        self.responses = responses
        self.available = available
    }

    func isAvailable() async -> Bool { available }

    func complete(system: String, prompt: String) async throws -> String {
        defer { completeCalls += 1 }
        guard completeCalls < responses.count else {
            throw DirectorError.providerFailed("no more scripted responses")
        }
        return responses[completeCalls]
    }

    func terminate() async { terminated = true }
}

func runDirectorTests(_ t: TestKit) {
    let validPlanJSON = """
    {"camera":"slow dolly-in, medium close-up","action":"A woman lifts a cup of tea and smiles.","acting":"soft, warm expression","motion":"gentle, natural","lighting":"golden hour side light","dialogue":[{"speaker":"Mika","text":"おはよう"}],"audioCues":["porcelain clink"],"durationIntentSeconds":5}
    """

    t.suite("Plan parsing") {
        t.check(LocalDirector.parsePlan(from: validPlanJSON) != nil, "clean JSON parses")
        let fenced = "Here is the plan:\n```json\n\(validPlanJSON)\n```\nDone!"
        t.check(LocalDirector.parsePlan(from: fenced) != nil, "fenced/noisy JSON extracted")
        t.check(LocalDirector.parsePlan(from: "not json at all") == nil, "garbage rejected")
        let invalid = OneShotPlan(camera: "", action: "walks")
        t.check(!invalid.isValid, "empty camera fails validation")
        t.check(OneShotPlan(camera: "static", action: "x", durationIntentSeconds: 50).validationErrors.contains { $0.contains("durationIntent") },
                "out-of-range duration rejected")
    }

    t.suite("Ollama response envelope") {
        do {
            let standard = try JSONSerialization.data(withJSONObject: [
                "response": validPlanJSON,
                "thinking": "ignored",
            ])
            t.checkEqual(try OllamaDirectorProvider.completionText(from: standard), validPlanJSON,
                         "response field is canonical")

            let thinkingCompatibility = try JSONSerialization.data(withJSONObject: [
                "response": "",
                "thinking": validPlanJSON,
            ])
            t.checkEqual(try OllamaDirectorProvider.completionText(from: thinkingCompatibility), validPlanJSON,
                         "empty response falls back to thinking content")

            let empty = try JSONSerialization.data(withJSONObject: ["response": "", "thinking": ""])
            do {
                _ = try OllamaDirectorProvider.completionText(from: empty)
                t.check(false, "empty Ollama envelope should fail")
            } catch {
                t.checkEqual(error as? DirectorError,
                             .noResponse("Ollama response contained no completion text"),
                             "empty Ollama envelope is distinguished from invalid JSON")
            }
        } catch {
            t.check(false, "Ollama envelope test setup threw \(error)")
        }
    }

    t.suite("Director lifecycle") {
        // Valid on first try.
        let good = MockDirectorProvider(responses: [validPlanJSON])
        let director = LocalDirector(providers: [good])
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (plan, provider) = try await director.plan(brief: "morning tea")
                t.checkEqual(provider, "mock", "mock provider used")
                t.checkEqual(plan.dialogue.first?.text, "おはよう", "dialogue preserved verbatim")
            } catch {
                t.check(false, "plan threw \(error)")
            }
            sem.signal()
        }
        sem.wait()
        t.check(good.terminated, "provider terminated after planning (LLM lifecycle separation)")

        // Repair path: bad JSON then valid → succeeds with 2 calls.
        let repairing = MockDirectorProvider(responses: ["oops not json", validPlanJSON])
        let director2 = LocalDirector(providers: [repairing])
        let sem2 = DispatchSemaphore(value: 0)
        Task {
            do {
                _ = try await director2.plan(brief: "b")
                t.checkEqual(repairing.completeCalls, 2, "one repair attempt used")
            } catch {
                t.check(false, "repair path threw \(error)")
            }
            sem2.signal()
        }
        sem2.wait()

        // Exhausted repairs → error, provider still terminated, falls through
        // to template fallback when present.
        let alwaysBad = MockDirectorProvider(responses: ["x", "y", "z", "w"])
        let director3 = LocalDirector(providers: [alwaysBad, TemplateDirectorProvider()])
        let sem3 = DispatchSemaphore(value: 0)
        Task {
            do {
                let (plan, provider) = try await director3.plan(brief: "a cat plays piano")
                t.checkEqual(provider, "template", "falls back to template provider")
                t.check(plan.action.contains("cat plays piano"), "template uses brief as action")
            } catch {
                t.check(false, "fallback path threw \(error)")
            }
            sem3.signal()
        }
        sem3.wait()
        t.check(alwaysBad.terminated, "failed provider still terminated")

        // Unavailable provider skipped.
        let offline = MockDirectorProvider(responses: [], available: false)
        let director4 = LocalDirector(providers: [offline, TemplateDirectorProvider()])
        let sem4 = DispatchSemaphore(value: 0)
        Task {
            do {
                let (_, provider) = try await director4.plan(brief: "b")
                t.checkEqual(provider, "template", "unavailable provider skipped")
            } catch {
                t.check(false, "skip path threw \(error)")
            }
            sem4.signal()
        }
        sem4.wait()
    }

    t.suite("Prompt compiler") {
        let plan = LocalDirector.parsePlan(from: validPlanJSON)!
        let compiled = PromptCompiler.compile(plan: plan)
        t.check(compiled.contains("dolly-in"), "camera included")
        t.check(compiled.contains("lifts a cup"), "action included")
        t.check(compiled.contains("golden hour"), "lighting included")
        t.check(compiled.contains("おはよう"), "Japanese dialogue kept native")
        t.check(compiled.contains("porcelain clink"), "audio cues included")
        t.check(!compiled.contains("\n"), "single flowing description (no newlines)")

        // Romanization fallback.
        let line = OneShotPlan.DialogueLine(speaker: "Mika", text: "おはよう", language: "ja", romanization: "ohayou")
        let rendered = DialogueNormalizer.render(line, handling: .romanizedFallback)
        t.check(rendered.contains("ohayou"), "romanization fallback rendered")
        t.check(!DialogueNormalizer.render(line, handling: .native).contains("ohayou"), "native mode omits romanization")

        // Normalizer drops empty lines, keeps text verbatim.
        let normalized = DialogueNormalizer.normalize([
            OneShotPlan.DialogueLine(speaker: " A ", text: "  hello  "),
            OneShotPlan.DialogueLine(speaker: "B", text: "   "),
        ])
        t.checkEqual(normalized.count, 1, "empty dialogue dropped")
        t.checkEqual(normalized.first?.text, "hello", "text trimmed not rewritten")

        // Frame count mapping (8n+1 @ 24fps).
        t.checkEqual(PromptCompiler.frameCount(forSeconds: 1), 25, "1s → 25 frames")
        t.checkEqual(PromptCompiler.frameCount(forSeconds: 5), 121, "5s → 121 frames")
        t.checkEqual(PromptCompiler.frameCount(forSeconds: 100), 241, "clamped to 241 frames")
        t.checkEqual((PromptCompiler.frameCount(forSeconds: 3) - 1) % 8, 0, "3s frame count is 8n+1")
    }

    t.suite("Director request pipeline") {
        let good = MockDirectorProvider(responses: [validPlanJSON])
        let director = LocalDirector(providers: [good])
        let base = GenerationRequest(
            prompt: "ignored",
            parameters: .default,
            qualityMode: QualityMode.auto.rawValue,
            preset: GenerationPreset.standard.rawValue,
            generationSource: "oneShot"
        )
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, plan, _) = try await director.makeRequest(brief: "tea", base: base)
                t.check(request.prompt.contains("lifts a cup"), "request carries compiled prompt")
                t.checkEqual(request.id, base.id, "request identity preserved")
                t.checkEqual(request.qualityMode, "auto", "quality mode preserved")
                t.checkEqual(request.preset, GenerationPreset.standard.rawValue, "preset preserved")
                t.checkEqual(request.generationSource, "oneShot", "One Shot source preserved")
                t.checkEqual(request.targetDurationSeconds, plan.durationIntentSeconds, "One Shot duration intent carried")
                t.checkEqual(request.parameters.numFrames, PromptCompiler.frameCount(forSeconds: plan.durationIntentSeconds ?? 5), "duration intent applied to frames")

                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("director-quality-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: temp) }
                let history = HistoricalSuccessStore(storeURL: temp)
                let hardware = HardwareProfile(modelIdentifier: "TestMac1,1", chipDescription: "Test", physicalMemoryGB: 48)
                let engine = AutoQualityEngine(history: history, hardware: hardware)
                let snapshot = MemorySnapshot(
                    physicalBytes: 48 * 1_073_741_824,
                    approximateAvailableBytes: 30 * 1_073_741_824,
                    swapUsedBytes: 0,
                    swapTotalBytes: 0,
                    thermalState: "nominal",
                    capturedAt: Date()
                )
                let resolved = try GenerationSettingsResolver.resolve(request: request, engine: engine, snapshot: snapshot)
                t.checkEqual(resolved.profile?.id, "S0", "One Shot Standard uses shared resolver")
                t.checkEqual(resolved.request.parameters.numFrames,
                             PromptCompiler.frameCount(forSeconds: plan.durationIntentSeconds ?? 5, fps: 24),
                             "One Shot duration survives profile application")
            } catch {
                t.check(false, "makeRequest threw \(error)")
            }
            sem.signal()
        }
        sem.wait()

        let customProvider = MockDirectorProvider(responses: [validPlanJSON])
        let customDirector = LocalDirector(providers: [customProvider])
        var manual = GenerationParameters.default
        manual.numFrames = 81
        let customBase = GenerationRequest(
            prompt: "ignored",
            parameters: manual,
            qualityMode: QualityMode.advanced.rawValue,
            preset: GenerationPreset.custom.rawValue,
            targetDurationSeconds: 2,
            generationSource: "oneShot"
        )
        let customSem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, _, _) = try await customDirector.makeRequest(brief: "tea", base: customBase)
                t.checkEqual(request.parameters.numFrames, 81, "One Shot Custom preserves manual frames")
                t.check(request.targetDurationSeconds == nil, "One Shot Custom ignores automatic duration constraint")
            } catch {
                t.check(false, "custom makeRequest threw \(error)")
            }
            customSem.signal()
        }
        customSem.wait()
    }
}
