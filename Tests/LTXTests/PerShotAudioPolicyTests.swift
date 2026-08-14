import Foundation
@testable import LTXVideoGeneratorCore

func runPerShotAudioPolicyTests(_ t: TestKit) {
    let policy = PerShotAudioPolicy.naturalProductionSoundNoMusic
    let plan = OneShotPlan(
        camera: "medium tracking shot",
        action: "A woman runs along a night train platform.",
        dialogue: [OneShotPlan.DialogueLine(speaker: "Woman", text: "It's here")],
        audioCues: [
            "night station ambience",
            "distant train hum",
            "footsteps and suitcase wheels",
            "epic orchestral music plays throughout",
        ],
        durationIntentSeconds: 5
    )
    let options = PromptCompiler.Options(perShotAudioPolicy: policy)
    let compiled = PromptCompiler.compile(plan: plan, options: options)

    t.suite("Auto Movie per-shot audio policy") {
        t.check(compiled.lowercased().contains("no background music"),
                "A: final prompt explicitly forbids background music")
        t.check(compiled.lowercased().contains("musical score"),
                "A: final prompt explicitly forbids musical score")
        t.check(compiled.lowercased().contains("no music"),
                "A: final prompt begins with the strongest concise prohibition")
        t.check(compiled.lowercased().contains("no soundtrack"),
                "A: final prompt explicitly forbids a soundtrack")
        t.check(compiled.lowercased().contains("instrumental music"),
                "A: final prompt explicitly forbids instrumental music")
        t.check(compiled.lowercased().contains("melodic accompaniment"),
                "A: final prompt explicitly forbids melodic accompaniment")
        t.check(compiled.contains("It's here"), "B: dialogue remains in the prompt")
        t.check(compiled.contains("night station ambience"), "C: ambience remains in the prompt")
        t.check(compiled.contains("footsteps and suitcase wheels"), "D: scene SFX remain in the prompt")
        t.check(!compiled.contains("epic orchestral music"),
                "K: conflicting per-shot music cue is not combined with the no-BGM guard")

        let request = GenerationRequest(prompt: compiled, disableAudio: false)
        t.check(!request.disableAudio, "E: no-BGM policy keeps synchronized audio enabled")

        let unrestricted = PromptCompiler.compile(plan: plan)
        t.check(unrestricted.contains("epic orchestral music"),
                "Direct/raw semantics remain unchanged unless the policy is selected")
        t.check(!unrestricted.lowercased().contains("no background music"),
                "unrestricted compiler does not silently impose the Director policy")

        let guardedAgain = policy.applyingPromptGuard(to: compiled)
        t.checkEqual(guardedAgain, compiled, "prompt guard is idempotent")
        t.checkEqual(
            compiled.lowercased().components(separatedBy: "audio policy:").count - 1,
            1,
            "canonical strong policy appears exactly once"
        )

        let upgradedLegacy = policy.applyingPromptGuard(to:
            "A woman walks through cinematic lighting. Audio policy: no background music or musical score. Keep synchronized natural production sound: spoken dialogue, environmental ambience, footsteps, foley and scene-appropriate sound effects.")
        t.check(upgradedLegacy.contains(PerShotAudioPolicy.generationGuard),
                "legacy guard upgrades to the canonical v2 policy")
        t.checkEqual(
            upgradedLegacy.lowercased().components(separatedBy: "audio policy:").count - 1,
            1,
            "legacy upgrade does not duplicate policy blocks"
        )

        let basicFallback = OneShotPlan(
            camera: "static wide shot",
            action: "A woman waits beside the train. Epic orchestral music plays throughout.",
            audioCues: ["wind"])
        let basicPrompt = PromptCompiler.compile(plan: basicFallback, options: options)
        t.check(basicPrompt.contains("A woman waits beside the train"),
                "K: Basic fallback keeps visible action")
        t.check(!basicPrompt.lowercased().contains("epic orchestral music"),
                "K: Basic fallback defers a standalone music direction")

        let enhanced = PerShotAudioPolicy.preservingPolicy(
            from: compiled,
            in: "Enhanced cinematic lighting follows a running woman. An orchestral soundtrack swells dramatically.")
        t.check(enhanced.lowercased().contains("no background music"),
                "LTX prompt enhancement cannot drop the selected no-BGM policy")
        t.check(enhanced.lowercased().contains("cinematic lighting"),
                "visual cinematic wording survives audio-policy sanitation")
        t.check(!enhanced.lowercased().contains("soundtrack swells"),
                "prompt enhancement cannot reintroduce a contradictory music cue")
        let directEnhanced = PerShotAudioPolicy.preservingPolicy(
            from: "A raw Direct Generate prompt.",
            in: "Enhanced raw prompt.")
        t.check(!directEnhanced.lowercased().contains("no background music"),
                "Direct Generate enhancement remains policy-neutral")
    }

    t.suite("Director protocol audio parity") {
        let structured = DirectorPlanFormat.systemPrompt(
            for: .structuredJSON, characterBible: CharacterBible())
        let textSystem = DirectorPlanFormat.systemPrompt(
            for: .textProtocol, characterBible: CharacterBible())
        let textPrompt = DirectorPlanFormat.userPrompt(
            for: .textProtocol, brief: "She hears a train and runs.")
        let structuredRepair = DirectorPlanFormat.repairPrompt(
            for: .structuredJSON, failure: "invalid JSON", brief: "She runs.")
        let textRepair = DirectorPlanFormat.repairPrompt(
            for: .textProtocol, failure: "missing marker", brief: "She runs.")

        for (label, prompt) in [
            ("F structured", structured),
            ("G text system", textSystem),
            ("G text template", textPrompt),
            ("H structured repair", structuredRepair),
            ("H text repair", textRepair),
        ] {
            t.check(prompt.lowercased().contains("do not plan background music"),
                    "\(label) carries no-BGM policy")
            t.check(prompt.lowercased().contains("environmental ambience"),
                    "\(label) preserves natural audio semantics")
        }
        t.check(LocalDirector.directorSystemPrompt.lowercased().contains("do not plan background music"),
                "One Shot Director naturally shares the same audio policy")
    }

    t.suite("Backend prompt propagation") {
        let ltxRequest = GenerationRequest(
            prompt: compiled,
            disableAudio: false,
            modelId: LTXModelCatalog.defaultModelID)
        t.check(ltxRequest.prompt.lowercased().contains("no background music"),
                "I: LTX-2.3 receives the guarded canonical request prompt")
        t.check(!ltxRequest.disableAudio, "I: LTX-2.3 request keeps audio enabled")

        let customRequest = GenerationRequest(
            prompt: compiled,
            disableAudio: false,
            modelId: CustomLTX2MLXModelCatalog.customModelID)
        let arguments = LTX2MLXBackend.arguments(
            request: customRequest,
            modelDirectory: "/models/custom",
            outputPath: "/tmp/out.mp4",
            seed: 7,
            width: 512,
            height: 320)
        let promptIndex = arguments.firstIndex(of: "--prompt")
        let backendPrompt = promptIndex.flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        t.check(backendPrompt?.lowercased().contains("no background music") == true,
                "J: custom backend receives the same guarded request prompt")
        t.check(!customRequest.disableAudio, "J: custom backend policy does not request no-audio")
    }

    t.suite("Auto Movie project integration") {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                var settings = ProjectSettings()
                settings.audioEnabled = true
                settings.targetDurationSeconds = 10
                let director = StoryboardDirector(
                    providers: [TemplateStoryboardProvider()],
                    requestedMode: .basic)
                let result = try await director.makeProject(
                    title: "Natural Sound",
                    brief: """
                    First shot: A woman waits beside a night train. Epic orchestral music plays throughout.
                    Next shot: She hears the train, says It's here, and starts running.
                    """,
                    settings: settings,
                    capabilityAwarePlanning: true)
                t.check(result.project.shots.count >= 2,
                        "Auto Movie integration materializes multiple planned shots")
                t.check(result.project.shots.allSatisfy {
                    $0.compiledPrompt.lowercased().contains("no background music")
                }, "Auto Movie persists the policy in every Shot compiled prompt")
                t.check(result.project.shots.allSatisfy {
                    !$0.compiledPrompt.lowercased().contains("epic orchestral music")
                }, "explicit Brief music is deferred instead of persisted per Shot")
                t.check(result.project.settings.resolvedAudioEnabled,
                        "Auto Movie project keeps synchronized audio enabled")
            } catch {
                t.check(false, "Auto Movie policy integration threw \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    t.suite("Take freeze audio policy boundary") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-audio-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilmProjectStore(projectsDirectory: root)
        var project = FilmProject(title: "Legacy prompt")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.settings.modelID = CustomLTX2MLXModelCatalog.customModelID
        var shot = Shot(index: 0, title: "Legacy Shot")
        shot.compiledPrompt = "Cinematic station lighting. An orchestral soundtrack swells. A woman says: \"It's here.\""
        project.shots = [shot]
        store.save(project)

        do {
            let request = try XCTUnwrapAudioPolicy(
                try TakeGenerationCoordinator(store: store).planTakes(
                    projectID: project.id, shotID: shot.id, count: 1, baseSeed: 17
                ).first
            )
            let persisted = try XCTUnwrapAudioPolicy(
                store.project(id: project.id)?.shots.first?.takes.first
            )
            t.check(request.prompt.contains(PerShotAudioPolicy.generationGuard),
                    "legacy project request receives the v2 guard at the backend boundary")
            t.checkEqual(request.prompt, persisted.promptSnapshot,
                         "immutable Take records the exact final backend prompt")
            t.check(!request.prompt.lowercased().contains("soundtrack swells"),
                    "legacy contradictory music direction is removed before freeze")
            t.check(request.prompt.lowercased().contains("cinematic station lighting"),
                    "legacy visual cinematic wording remains")
            t.check(!request.disableAudio,
                    "Take boundary policy keeps dialogue, ambience and SFX generation enabled")

            let args = LTX2MLXBackend.arguments(
                request: request, modelDirectory: "/models/custom",
                outputPath: "/tmp/out.mp4", seed: 17, width: 512, height: 320)
            let promptIndex = try XCTUnwrapAudioPolicy(args.firstIndex(of: "--prompt"))
            t.checkEqual(args[promptIndex + 1], request.prompt,
                         "custom backend receives the frozen canonical prompt without substitution")
        } catch {
            t.check(false, "Take freeze policy test threw \(error)")
        }
    }
}

private func XCTUnwrapAudioPolicy<T>(_ value: T?) throws -> T {
    guard let value else { throw CocoaError(.coderValueNotFound) }
    return value
}
