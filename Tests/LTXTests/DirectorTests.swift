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

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("Handler is unavailable.")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
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
        t.checkEqual(PromptCompiler.frameCount(forSeconds: 100), 361, "clamped to 361 frames")
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

    // MARK: - Local Director readiness probe (Settings Test honesty)
    //
    // A model that answers a trivial JSON echo can still be unable to produce
    // a storyboard: the model configured on the audited machine returned
    // `{"ready":true}` for the old probe but `{}` for the real planning
    // request, so Settings reported "Ready" while every Auto Movie silently
    // fell back to the Basic Director. The probe is therefore plan-shaped and
    // these tests pin that contract.
    t.suite("Local Director readiness probe") {
        let probe = OllamaDirectorEnvironmentClient.probeResponseLooksLikeAPlan

        t.check(probe("{\"logline\":\"x\",\"shots\":[{\"index\":0,\"summary\":\"y\"}]}"),
                "a plan-shaped reply with one shot object is accepted")
        t.check(probe("  {\"shots\":[{\"index\":0}]}  "),
                "surrounding whitespace does not reject a valid reply")

        // The exact reply the audited model gave for the real planning task.
        t.check(!probe("{}"),
                "an empty JSON object is rejected — this is what silently caused Basic fallback")
        // The exact reply the audited model gave for a plan-shaped request.
        t.check(!probe("{\"input\":\"A woman is walking.\",\"output\":\"A woman walks.\"}"),
                "a well-formed object that ignores the requested schema is rejected")
        // What the old probe accepted.
        t.check(!probe("{\"ready\":true}"),
                "the trivial JSON echo the old probe accepted no longer counts as ready")

        t.check(!probe("{\"shots\":[]}"), "an empty shots array is rejected")
        t.check(!probe("{\"shots\":\"soon\"}"), "a non-array shots value is rejected")
        t.check(!probe("{\"shots\":[\"a\",\"b\"]}"), "an array of non-objects is rejected")
        t.check(!probe("Sure! Here is your plan."), "free prose is rejected")
        t.check(!probe(""), "an empty reply is rejected")

        // A model that fails the probe must surface as a plan problem, not as
        // an unreachable server, because the two need different user action.
        var probeDone = false
        Task {
            let failing = MockDirectorEnvironmentClient(
                models: ["m:latest"],
                testError: DirectorError.invalidPlanJSON("The model replied, but did not return a usable plan."))
            let defaults = UserDefaults(suiteName: "director-probe-\(UUID().uuidString)")!
            defaults.set(DirectorMode.localAI.rawValue, forKey: DirectorMode.userDefaultsKey)
            defaults.set("m:latest", forKey: DirectorEnvironmentService.modelUserDefaultsKey)
            let service = DirectorEnvironmentService(userDefaults: defaults, client: failing)
            let result = await service.testSelectedModel()
            switch result {
            case .success:
                t.check(false, "a model that cannot plan must not report success")
            case .failure(let error):
                if case DirectorError.invalidPlanJSON = error {
                    t.check(true, "an unusable plan is reported as a plan failure, not a connection failure")
                } else {
                    t.check(false, "unexpected error kind: \(error)")
                }
            }
            probeDone = true
        }
        while !probeDone { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }

        // Fallback reasons that occur with the server up and the model loaded
        // must not tell the user the server was unreachable.
        let schemaText = DirectorEnvironmentService.friendlyFallbackReason("schemaValidationFailed")
        t.check(schemaText.contains("replied"), "schema failure explains the model replied")
        t.check(!schemaText.lowercased().contains("unavailable"), "schema failure is not described as unavailability")
        let syntaxText = DirectorEnvironmentService.friendlyFallbackReason("jsonSyntaxInvalid")
        t.check(syntaxText.contains("format"), "syntax failure explains the reply format was wrong")
        t.checkEqual(DirectorEnvironmentService.friendlyFallbackReason("localAIServerUnavailable"),
                     "Local AI was unavailable.",
                     "genuine unavailability wording is unchanged")
    }

    t.suite("EnvironmentDirectorProvider expectsJSON forwarding") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var receivedBodies: [[String: Any]] = []
        MockURLProtocol.requestHandler = { request in
            var bodyData = request.httpBody
            if bodyData == nil, let stream = request.httpBodyStream {
                stream.open()
                let bufferSize = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                var data = Data()
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read > 0 { data.append(buffer, count: read) }
                    else { break }
                }
                buffer.deallocate()
                stream.close()
                bodyData = data
            }

            if let data = bodyData, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Ignore api/tags requests which don't have bodies we care about
                if request.url?.path.contains("api/generate") == true {
                    receivedBodies.append(body)
                }
            }

            let json = "{\"response\": \"{}\"}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json.data(using: .utf8)!)
        }

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(DirectorMode.localAI.rawValue, forKey: DirectorMode.userDefaultsKey)
        defaults.set("mock-model", forKey: DirectorEnvironmentService.modelUserDefaultsKey)

        let client = MockDirectorEnvironmentClient(models: ["mock-model"])
        let env = DirectorEnvironmentService(userDefaults: defaults, client: client)
        let provider = EnvironmentDirectorProvider(mode: .localAI, environment: env, session: session)

        var done = false
        Task {
            let available = await provider.isAvailable()
            print("TEST: isAvailable = \(available)")
            if !available {
                print("TEST: fallback reason = \(provider.availabilityFailureReason ?? "nil")")
            }

            do {
                _ = try await provider.complete(system: "s", prompt: "p", expectsJSON: false)
                _ = try await provider.complete(system: "s", prompt: "p", expectsJSON: true)
            } catch {
                print("TEST ERROR: \(error)")
            }
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }

        t.checkEqual(receivedBodies.count, 2, "two requests were intercepted")
        if receivedBodies.count == 2 {
            let firstBody = receivedBodies[0]
            t.check(firstBody["format"] == nil, "Text Protocol / expectsJSON=false is forwarded through EnvironmentDirectorProvider to OllamaDirectorProvider, and the resulting Ollama request does NOT contain format: json")

            let secondBody = receivedBodies[1]
            t.check((secondBody["format"] as? String) == "json", "Structured JSON / expectsJSON=true is forwarded correctly and DOES produce the JSON format request setting")
        }
    }

    t.suite("DirectorPlanFormat - Opening Scene Evidence Injection") {
        var appearance = OpeningReferenceAppearance()
        appearance.status = .analysed
        appearance.sceneEnvironment = "night train platform"
        appearance.sceneLighting = "dim overhead lights"
        appearance.subjectState = "standing still"
        appearance.keyObjects = "blue suitcase"

        let jsonPrompt = DirectorPlanFormat.userPrompt(for: .structuredJSON, brief: "She runs.", openingSceneEvidence: appearance)
        t.check(jsonPrompt.contains("CURRENT OPENING SCENE EVIDENCE"), "JSON prompt contains evidence header")
        t.check(jsonPrompt.contains("night train platform"), "JSON prompt contains environment")
        t.check(jsonPrompt.contains("blue suitcase"), "JSON prompt contains key objects")
        t.check(jsonPrompt.contains("BRIEF: She runs."), "JSON prompt preserves brief at the end")

        let textPrompt = DirectorPlanFormat.userPrompt(for: .textProtocol, brief: "She runs.", openingSceneEvidence: appearance)
        t.check(textPrompt.contains("CURRENT OPENING SCENE EVIDENCE"), "Text Protocol prompt contains evidence header")
        t.check(textPrompt.contains("night train platform"), "Text Protocol prompt contains environment")

        // Case A: CharacterBible/default costume = black coat, Opening = red coat
        var appearanceWithClothing = appearance
        appearanceWithClothing.clothingDescription = "red coat"
        var bibleA = CharacterBible()
        bibleA = OpeningReferenceSync.seedBible(from: appearanceWithClothing, existing: bibleA)
        bibleA.characters[0].defaultCostume = "black coat" // Inferred/default from character sheet
        
        let sysPromptA = DirectorPlanFormat.systemPrompt(for: .structuredJSON, characterBible: bibleA)
        let jsonPromptA = DirectorPlanFormat.userPrompt(for: .structuredJSON, brief: "She runs.", openingSceneEvidence: appearanceWithClothing, characterBible: bibleA)
        t.check(sysPromptA.contains("Default costume: black coat"), "Case A: System prompt contains Default costume: black coat")
        t.check(jsonPromptA.contains("Visible clothing: red coat"), "Case A: Opening evidence (red coat) must NOT be suppressed")

        // Case D: Structured JSON and Text Protocol receive equivalent Opening clothing evidence
        let textPromptA = DirectorPlanFormat.userPrompt(for: .textProtocol, brief: "She runs.", openingSceneEvidence: appearanceWithClothing, characterBible: bibleA)
        t.check(textPromptA.contains("Visible clothing: red coat"), "Case D: Text Protocol receives equivalent Visible clothing evidence")

        // Case B: CharacterBible: "She must always wear a black coat.", Opening: red coat
        var explicitCharacter = BibleCharacter(name: "Character1")
        explicitCharacter.defaultCostume = "She must always wear a black coat."
        var bibleB = CharacterBible()
        bibleB.characters = [explicitCharacter]
        
        let sysPromptB = DirectorPlanFormat.systemPrompt(for: .structuredJSON, characterBible: bibleB)
        let jsonPromptB = DirectorPlanFormat.userPrompt(for: .structuredJSON, brief: "She runs.", openingSceneEvidence: appearanceWithClothing, characterBible: bibleB)
        t.check(sysPromptB.contains("She must always wear a black coat."), "Case B: System prompt retains explicit user constraint")
        t.check(jsonPromptB.contains("Visible clothing: red coat"), "Case B: Opening evidence (red coat) is included despite explicit constraint")

        // Case C: No Opening clothing -> no Visible clothing line
        var appearanceNoClothing = appearance
        appearanceNoClothing.clothingDescription = ""
        let jsonPromptC = DirectorPlanFormat.userPrompt(for: .structuredJSON, brief: "She runs.", openingSceneEvidence: appearanceNoClothing, characterBible: bibleA)
        t.check(!jsonPromptC.contains("Visible clothing:"), "Case C: No Opening clothing -> no Visible clothing line")

        // Test missing/failed scene analysis behavior
        let emptyPrompt = DirectorPlanFormat.userPrompt(for: .structuredJSON, brief: "She runs.", openingSceneEvidence: nil, characterBible: nil)
        t.check(!emptyPrompt.contains("CURRENT OPENING SCENE EVIDENCE"), "Nil evidence generates old behavior (no header)")
        t.checkEqual(emptyPrompt, "BRIEF: She runs.", "Nil evidence generates exactly old behavior")

        var emptyAppearance = OpeningReferenceAppearance()
        emptyAppearance.status = .analysed
        let emptyAppearancePrompt = DirectorPlanFormat.userPrompt(for: .structuredJSON, brief: "She runs.", openingSceneEvidence: emptyAppearance, characterBible: nil)
        t.check(!emptyAppearancePrompt.contains("CURRENT OPENING SCENE EVIDENCE"), "Empty evidence fields generate old behavior (no header)")
        t.checkEqual(emptyAppearancePrompt, "BRIEF: She runs.", "Empty evidence fields generate exactly old behavior")
    }

    t.suite("TemplateStoryboardProvider - Explicit Shot Parsing & Isolation") {
        let multiShotBrief = """
        Shot 1: The woman walks through a softly lit corridor toward a doorway.
        Shot 2: She enters the bright sunlit room and smiles gently.
        """
        let beats = TemplateStoryboardProvider.explicitBeats(from: multiShotBrief)
        t.checkEqual(beats.count, 2, "Extracted exactly 2 shot beats")
        if beats.count >= 2 {
            let shot1 = beats[0]
            let shot2 = beats[1]
            t.checkEqual(shot1, "The woman walks through a softly lit corridor toward a doorway.", "Shot 1 content matches exactly")
            t.check(!shot1.contains("Shot 2"), "Shot 1 must not contain Shot 2 marker")
            t.check(!shot1.contains("enters the bright"), "Shot 1 must not contain Shot 2 action")
            t.check(!shot1.contains("smiles gently"), "Shot 1 must not contain Shot 2 acting")

            t.checkEqual(shot2, "She enters the bright sunlit room and smiles gently.", "Shot 2 content matches exactly")
            t.check(!shot2.contains("Shot 1"), "Shot 2 must not contain Shot 1 marker")
            t.check(!shot2.contains("walks through a softly lit corridor"), "Shot 2 must not contain Shot 1 action")
        }

        let inlineShotBrief = "Shot 1: A woman walking in a park. Shot 2: She sits on a bench."
        let inlineBeats = TemplateStoryboardProvider.explicitBeats(from: inlineShotBrief)
        t.checkEqual(inlineBeats.count, 2, "Inline Shot 1 / Shot 2 extracted cleanly")
        if inlineBeats.count >= 2 {
            t.checkEqual(inlineBeats[0], "A woman walking in a park.", "Inline Shot 1 matches")
            t.checkEqual(inlineBeats[1], "She sits on a bench.", "Inline Shot 2 matches")
        }
    }
}
