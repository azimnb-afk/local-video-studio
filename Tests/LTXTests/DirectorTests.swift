import Foundation
@testable import LTXVideoGeneratorCore

/// Scripted provider for deterministic director tests.
final class MockDirectorProvider: DirectorProvider {
    let name = "mock"
    var responses: [String]
    var available: Bool
    private(set) var completeCalls = 0
    private(set) var terminated = false
    private(set) var systems: [String] = []
    private(set) var prompts: [String] = []

    init(responses: [String], available: Bool = true) {
        self.responses = responses
        self.available = available
    }

    func isAvailable() async -> Bool { available }

    func complete(system: String, prompt: String) async throws -> String {
        systems.append(system)
        prompts.append(prompt)
        defer { completeCalls += 1 }
        guard completeCalls < responses.count else {
            throw DirectorError.providerFailed("no more scripted responses")
        }
        return responses[completeCalls]
    }

    func terminate() async { terminated = true }
}

final class MockDirectorEnvironmentClient: DirectorEnvironmentClient {
    var models: [String]
    var listError: Error?
    var testError: Error?
    private(set) var listCalls = 0
    private(set) var testedModels: [String] = []

    init(models: [String] = [], listError: Error? = nil, testError: Error? = nil) {
        self.models = models
        self.listError = listError
        self.testError = testError
    }

    func installedModels() async throws -> [String] {
        listCalls += 1
        if let listError { throw listError }
        return models
    }

    func testModel(_ model: String) async throws {
        testedModels.append(model)
        if let testError { throw testError }
    }
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

    t.suite("Director environment") {
        do {
            let tags = try JSONSerialization.data(withJSONObject: [
                "models": [
                    ["name": "qwen3.6-claw-fast:latest", "capabilities": ["completion", "thinking"]],
                    ["model": "gemma3:4b"],
                    ["name": "nomic-embed:latest", "capabilities": ["embedding"]],
                    ["name": "qwen3.6-claw-fast:latest"],
                ],
            ])
            t.checkEqual(try OllamaDirectorEnvironmentClient.modelNames(from: tags),
                         ["gemma3:4b", "qwen3.6-claw-fast:latest"],
                         "installed model list parses, deduplicates and sorts")
        } catch {
            t.check(false, "installed model response parsing threw \(error)")
        }

        let suiteName = "LTXTests-DirectorEnvironment-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        func resolve(_ service: DirectorEnvironmentService, mode: DirectorMode) -> DirectorSetupSnapshot? {
            var value: DirectorSetupSnapshot?
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                value = await service.refresh(mode: mode)
                semaphore.signal()
            }
            semaphore.wait()
            return value
        }

        defaults.set("qwen3.6-claw-fast:latest", forKey: DirectorEnvironmentService.modelUserDefaultsKey)
        let readyClient = MockDirectorEnvironmentClient(models: ["qwen3.6-claw-fast:latest"])
        let readyService = DirectorEnvironmentService(userDefaults: defaults, client: readyClient)
        let ready = resolve(readyService, mode: .auto)
        t.checkEqual(ready?.effectiveMode, .localAI, "Auto + server + configured model selects Local AI")
        t.checkEqual(ready?.effectiveModel, "qwen3.6-claw-fast:latest", "configured model is source of truth")
        t.checkEqual(resolve(readyService, mode: .localAI)?.effectiveMode, .localAI,
                     "explicit Local AI + available model selects Local AI")

        let offlineClient = MockDirectorEnvironmentClient(
            listError: DirectorError.providerFailed("offline")
        )
        let offline = resolve(DirectorEnvironmentService(userDefaults: defaults, client: offlineClient), mode: .auto)
        t.checkEqual(offline?.effectiveMode, .basic, "Auto + unavailable server selects Basic")
        t.checkEqual(offline?.fallbackReason, "localAIServerUnavailable", "offline reason is actionable")

        defaults.set("missing:latest", forKey: DirectorEnvironmentService.modelUserDefaultsKey)
        let alternativeClient = MockDirectorEnvironmentClient(models: ["z-embed:latest", "gemma3:4b"])
        let alternativeService = DirectorEnvironmentService(userDefaults: defaults, client: alternativeClient)
        let alternative = resolve(alternativeService, mode: .auto)
        t.checkEqual(alternative?.effectiveMode, .localAI, "Auto safely uses an installed alternative")
        t.checkEqual(alternative?.effectiveModel, "gemma3:4b", "embedding model is excluded from candidates")
        t.checkEqual(alternative?.fallbackReason, "configuredModelMissingUsingInstalledAlternative",
                     "missing preference is visible when Auto selects an alternative")

        let explicitMissing = resolve(alternativeService, mode: .localAI)
        t.checkEqual(explicitMissing?.effectiveMode, .basic, "explicit Local AI missing model falls back safely")
        t.checkEqual(explicitMissing?.availability, .localAIModelMissing,
                     "explicit Local AI reports model missing")

        let basicClient = MockDirectorEnvironmentClient(models: ["qwen:latest"])
        let basic = resolve(DirectorEnvironmentService(userDefaults: defaults, client: basicClient), mode: .basic)
        t.checkEqual(basic?.availability, .basicOnly, "Basic is a first-class ready state")
        t.checkEqual(basicClient.listCalls, 0, "Basic never contacts Ollama")

        defaults.removeObject(forKey: DirectorEnvironmentService.modelUserDefaultsKey)
        let refreshClient = MockDirectorEnvironmentClient(models: ["first:latest"])
        let refreshService = DirectorEnvironmentService(userDefaults: defaults, client: refreshClient)
        t.checkEqual(resolve(refreshService, mode: .auto)?.installedModels, ["first:latest"],
                     "initial model refresh returns installed list")
        refreshClient.models = ["first:latest", "second:latest"]
        t.checkEqual(resolve(refreshService, mode: .auto)?.installedModels,
                     ["first:latest", "second:latest"],
                     "model refresh observes additions without app restart")

        defaults.set("second:latest", forKey: DirectorEnvironmentService.modelUserDefaultsKey)
        t.checkEqual(resolve(refreshService, mode: .auto)?.effectiveModel, "second:latest",
                     "selected model persists through the shared preference key")
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
                t.check(request.sourceImagePath == nil, "One Shot without image remains text-only")
                t.check(!request.isImageToVideo, "text-only One Shot does not enter I2V")
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

    t.suite("One Shot Starting Image bridge and safety") {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-oneshot-image-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let pngURL = tempDirectory.appendingPathComponent("starting.png")
        let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z1x8AAAAASUVORK5CYII=")!
        try? tinyPNG.write(to: pngURL)

        do {
            t.checkEqual(
                try OneShotStartingImagePreflight.validatedPath(pngURL.path),
                pngURL.path,
                "readable image passes Starting Image preflight"
            )
            t.check(try OneShotStartingImagePreflight.validatedPath(nil) == nil,
                    "no Starting Image stays text-only")
            t.check(try OneShotStartingImagePreflight.validatedPath("") == nil,
                    "clearing Starting Image returns to text-only")
        } catch {
            t.check(false, "valid Starting Image preflight threw \(error)")
        }

        let missingPath = tempDirectory.appendingPathComponent("moved.png").path
        t.checkThrows(OneShotStartingImageError.unavailable(missingPath),
                      "missing selected image is rejected without text-only fallback") {
            _ = try OneShotStartingImagePreflight.validatedPath(missingPath)
        }

        let invalidURL = tempDirectory.appendingPathComponent("not-an-image.png")
        try? Data("not image data".utf8).write(to: invalidURL)
        t.checkThrows(OneShotStartingImageError.invalidImage(invalidURL.path),
                      "invalid selected image is rejected deterministically") {
            _ = try OneShotStartingImagePreflight.validatedPath(invalidURL.path)
        }

        let imageProvider = MockDirectorProvider(responses: [validPlanJSON])
        let imageDirector = LocalDirector(providers: [imageProvider])
        let base = GenerationRequest(
            prompt: "ignored",
            sourceImagePath: pngURL.path,
            parameters: .default,
            qualityMode: QualityMode.compact.rawValue,
            preset: GenerationPreset.quickPreview.rawValue,
            generationSource: "oneShot"
        )
        let imageSemaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let (request, _, _) = try await imageDirector.makeRequest(brief: "smile", base: base)
                t.checkEqual(request.sourceImagePath, pngURL.path,
                             "One Shot bridges Starting Image through sourceImagePath")
                t.check(request.isImageToVideo, "One Shot with Starting Image enters existing I2V path")
                t.checkEqual(request.generationSource, "oneShot", "image-conditioned request remains One Shot")
            } catch {
                t.check(false, "image-conditioned makeRequest threw \(error)")
            }
            imageSemaphore.signal()
        }
        imageSemaphore.wait()
    }

    t.suite("Generate / One Shot responsibility split") {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let promptInputURL = repositoryRoot
            .appendingPathComponent("LTXVideoGenerator/Sources/Views/PromptInputView.swift")
        let oneShotURL = repositoryRoot
            .appendingPathComponent("LTXVideoGenerator/Sources/Views/ContentView.swift")
        let promptInputSource = try? String(contentsOf: promptInputURL, encoding: .utf8)
        let oneShotSource = try? String(contentsOf: oneShotURL, encoding: .utf8)

        t.check(promptInputSource?.contains("One Shot Director") == false,
                "Generate source no longer contains One Shot Director UI")
        t.check(promptInputSource?.contains("planWithDirector") == false,
                "Generate source no longer owns One Shot planning")
        t.check(promptInputSource?.contains("Image to Video") == true,
                "Generate retains direct I2V")
        t.check(oneShotSource?.contains("Starting Image (Optional)") == true,
                "One Shot owns optional Starting Image UI")

        let directGenerate = GenerationRequest(
            prompt: "direct prompt",
            sourceImagePath: "/tmp/direct-i2v.png",
            parameters: .preview,
            qualityMode: QualityMode.compact.rawValue,
            preset: GenerationPreset.quickPreview.rawValue,
            generationSource: "generate"
        )
        t.checkEqual(directGenerate.generationSource, "generate", "direct request remains Generate-owned")
        t.check(directGenerate.isImageToVideo, "Generate direct I2V request remains supported")
    }
}
