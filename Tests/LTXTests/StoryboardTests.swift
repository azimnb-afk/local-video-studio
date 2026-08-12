import Foundation
@testable import LTXVideoGeneratorCore

func runStoryboardTests(_ t: TestKit) {

    t.suite("New project settings") {
        let suiteName = "LTXTests-project-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("gemma3_12b_4bit", forKey: LTXTextEncoderCatalog.selectedTextEncoderIDKey)

        let settings = ProjectSettings.usingCurrentSelections(userDefaults: defaults)
        t.checkEqual(settings.textEncoderID, "gemma3_12b_4bit",
                     "new Storyboard inherits selected text encoder")
    }

    t.suite("Storyboard structured-output parsing") {
        let minimal = """
        {"logline":"A quiet walk.","shots":[{"title":"Walk","summary":"A woman walks beside the sea.","durationSeconds":5}]}
        """
        let fenced = "Here is the storyboard:\n```json\n\(minimal)\n```\nDone."
        t.checkEqual(StoryboardDirector.parseDraft(from: fenced)?.shots.count, 1,
                     "balanced extraction handles fenced JSON and surrounding prose")

        let trailingCommas = """
        {"logline":"A quiet walk.","shots":[{"title":"Walk","summary":"A woman walks.",},],}
        """
        t.checkEqual(StoryboardDirector.parseDraft(from: trailingCommas)?.shots.first?.title, "Walk",
                     "deterministic syntax repair removes trailing commas")

        let aliases = """
        {"synopsis":"A quiet walk.","scenes":[{"name":"Walk","action":"A woman walks.","duration":"5","scale":"wide","cameraAngle":"eye-level","cameraMovement":"track"}]}
        """
        let normalized = StoryboardDirector.parseDraftDetailed(from: aliases, brief: "beach walk")
        t.checkEqual(normalized.draft?.shots.first?.durationSeconds, 5,
                     "deterministic schema repair normalizes aliases and numeric strings")
        t.check(normalized.deterministicRepairAttempted, "schema normalization is reported")

        let typedDuration = """
        {"logline":"A quiet walk.","shots":[{"title":"Walk","summary":"A woman walks.","durationSeconds":"4.5"}]}
        """
        t.checkEqual(StoryboardDirector.parseDraftDetailed(from: typedDuration, brief: "x")
            .draft?.shots.first?.durationSeconds, 4.5,
                     "numeric duration string is safely normalized")

        let missingSummary = """
        {"logline":"A quiet walk.","shots":[{"title":"Walk"}]}
        """
        let schemaFailure = StoryboardDirector.parseDraftDetailed(from: missingSummary, brief: "beach walk")
        t.checkEqual(schemaFailure.failureStage, .schemaValidationFailed,
                     "missing required field is classified as schema validation")
        t.check(schemaFailure.message.contains("summary"), "schema diagnostic names the missing field")

        let syntaxFailure = StoryboardDirector.parseDraftDetailed(from: "{not valid JSON}", brief: "x")
        t.checkEqual(syntaxFailure.failureStage, .jsonSyntaxInvalid,
                     "invalid JSON syntax is classified separately")

        let extractionFailure = StoryboardDirector.parseDraftDetailed(from: "no object here", brief: "x")
        t.checkEqual(extractionFailure.failureStage, .jsonExtractionFailed,
                     "missing JSON object is classified as extraction failure")

        let noResponse = StoryboardDirector.parseDraftDetailed(from: "", brief: "x")
        t.checkEqual(noResponse.failureStage, .noResponse, "empty completion is classified separately")
    }

    t.suite("Storyboard repair diagnostics") {
        let valid = """
        {"logline":"A quiet walk.","shots":[{"title":"Walk","summary":"A woman walks beside the sea.","durationSeconds":5}]}
        """
        let repairing = MockDirectorProvider(responses: ["{broken JSON}", valid])
        let repairingDirector = StoryboardDirector(providers: [repairing])
        let repairSemaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let result = try await repairingDirector.draft(brief: "beach walk")
                t.checkEqual(result.draft.shots.count, 1, "one bounded LLM repair can recover")
                t.checkEqual(repairing.completeCalls, 2, "only one repair request is sent")
                t.check(repairingDirector.diagnostics.contains { $0.stage == .jsonSyntaxInvalid },
                        "malformed JSON stage is recorded before successful repair")
            } catch {
                t.check(false, "Storyboard repair path threw \(error)")
            }
            repairSemaphore.signal()
        }
        repairSemaphore.wait()

        let alwaysBad = MockDirectorProvider(responses: ["not json", "still not json"])
        let fallbackDirector = StoryboardDirector(providers: [alwaysBad, TemplateStoryboardProvider()])
        let fallbackSemaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let result = try await fallbackDirector.makeProject(title: "Fallback", brief: "beach walk")
                t.checkEqual(result.providerName, "template", "template remains the final fallback")
                t.checkEqual(result.project.planningMode, "fallback", "fallback planning mode is persisted")
                t.checkEqual(result.project.directorProvider, "template", "fallback provider is persisted")
                t.checkEqual(result.project.requestedDirectorMode, "auto", "requested Auto mode is persisted")
                t.checkEqual(result.project.effectiveDirectorMode, "basic", "fallback effective mode is Basic")
                t.checkEqual(result.project.fallbackReason, StoryboardDirector.FailureStage.jsonExtractionFailed.rawValue,
                             "actionable fallback reason is persisted")
                t.check(fallbackDirector.diagnostics.contains { $0.stage == .jsonExtractionFailed },
                        "JSON extraction failure is recorded")
                t.check(fallbackDirector.diagnostics.contains { $0.stage == .retryFailed },
                        "failed repair retry is recorded")
                t.check(fallbackDirector.diagnostics.contains { $0.stage == .templateFallback },
                        "template fallback stage is recorded")
            } catch {
                t.check(false, "Storyboard fallback path threw \(error)")
            }
            fallbackSemaphore.signal()
        }
        fallbackSemaphore.wait()

        let unavailable = MockDirectorProvider(responses: [], available: false)
        let unavailableDirector = StoryboardDirector(providers: [unavailable, TemplateStoryboardProvider()])
        let unavailableSemaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let result = try await unavailableDirector.makeProject(title: "Offline", brief: "beach walk")
                t.checkEqual(result.providerName, "template", "unavailable AI provider uses Basic fallback")
                t.check(unavailableDirector.diagnostics.contains { $0.stage == .ollamaRequestFailed },
                        "unavailable provider failure is diagnosed")
            } catch {
                t.check(false, "unavailable Storyboard provider fallback threw \(error)")
            }
            unavailableSemaphore.signal()
        }
        unavailableSemaphore.wait()

        let missingModel = MockDirectorProvider(responses: [])
        let missingModelDirector = StoryboardDirector(providers: [missingModel, TemplateStoryboardProvider()])
        let missingModelSemaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let result = try await missingModelDirector.makeProject(title: "Missing", brief: "beach walk")
                t.checkEqual(result.providerName, "template", "provider request failure uses Basic fallback")
                t.check(missingModelDirector.diagnostics.contains { $0.stage == .retryFailed },
                        "provider request retry remains bounded")
            } catch {
                t.check(false, "missing model fallback threw \(error)")
            }
            missingModelSemaphore.signal()
        }
        missingModelSemaphore.wait()
    }

    t.suite("Continuity transitions") {
        var state = ContinuitySnapshot()
        state.location = "kitchen"
        state.timeOfDay = "morning"
        state.characterOutfit = ["Mika": "red coat"]
        state.props = ["umbrella"]
        state.propOwner = ["umbrella": "Mika"]

        // Valid transition.
        do {
            let next = try ContinuityEngine.apply(changes: [
                "location=garden", "outfit:Mika=blue dress", "prop-:umbrella", "wet:Mika=drizzled",
            ], to: state)
            t.checkEqual(next.location, "garden", "location updated")
            t.checkEqual(next.characterOutfit["Mika"], "blue dress", "outfit updated")
            t.check(!next.props.contains("umbrella"), "prop removed")
            t.check(next.propOwner["umbrella"] == nil, "prop owner cleared with prop")
            t.checkEqual(next.wetness["Mika"], "drizzled", "wetness recorded")
            t.checkEqual(next.timeOfDay, "morning", "unchanged fields carried over")
        } catch {
            t.check(false, "valid transition threw \(error)")
        }

        // Malformed directives rejected.
        t.checkThrows(ContinuityEngine.DirectiveError.malformed("teleport=moon=now"),
                      "unknown directive rejected") {
            _ = try ContinuityEngine.apply(changes: ["teleport=moon=now"], to: state)
        }
        t.checkThrows(ContinuityEngine.DirectiveError.malformed("location="),
                      "empty value rejected") {
            _ = try ContinuityEngine.apply(changes: ["location="], to: state)
        }
    }

    t.suite("Continuity validation") {
        var previous = ContinuitySnapshot()
        previous.location = "kitchen"
        previous.characterOutfit = ["Mika": "red coat"]
        previous.injuries = ["Mika": "scraped knee"]

        // Silent location change → error.
        var next = previous
        next.location = "rooftop"
        let violations = ContinuityEngine.validate(previous: previous, next: next, explicitChanges: [])
        t.check(violations.contains { $0.severity == .error && $0.message.contains("Location") },
                "silent location change flagged")

        // Same change WITH directive → clean.
        let ok = ContinuityEngine.validate(previous: previous, next: next, explicitChanges: ["location=rooftop"])
        t.check(!ok.contains { $0.message.contains("Location") }, "explicit location change accepted")

        // Vanishing injury → warning.
        var healed = previous
        healed.injuries = [:]
        let injuryViolations = ContinuityEngine.validate(previous: previous, next: healed, explicitChanges: [])
        t.check(injuryViolations.contains { $0.message.contains("injury") }, "vanishing injury flagged")

        // Orphan prop owner → error.
        var orphan = previous
        orphan.propOwner = ["sword": "Mika"]
        let orphanViolations = ContinuityEngine.validate(previous: previous, next: orphan, explicitChanges: [])
        t.check(orphanViolations.contains { $0.message.contains("not present") }, "orphan prop owner flagged")
    }

    t.suite("Shot monotony") {
        func shot(_ index: Int, scale: String, angle: String = "eye-level", movement: String = "static") -> Shot {
            var s = Shot(index: index, title: "S\(index)", summary: "x")
            s.camera = CameraPlan(shotScale: scale, angle: angle, movement: movement)
            return s
        }
        let monotone = [shot(0, scale: "medium"), shot(1, scale: "medium"), shot(2, scale: "medium"), shot(3, scale: "wide")]
        let warnings = ContinuityEngine.monotonyWarnings(shots: monotone)
        t.check(warnings.contains { $0.message.contains("shot scale") }, "3x same scale flagged")

        let varied = [shot(0, scale: "wide"), shot(1, scale: "medium"), shot(2, scale: "close-up")]
        // All static movement 3 in a row → movement warning, but scale is fine.
        let variedWarnings = ContinuityEngine.monotonyWarnings(shots: varied)
        t.check(!variedWarnings.contains { $0.message.contains("shot scale") }, "varied scale not flagged")
        t.check(variedWarnings.contains { $0.message.contains("movement") }, "3x static movement flagged")
        t.checkEqual(ContinuityEngine.monotonyWarnings(shots: []).count, 0, "empty shot list safe")
    }

    t.suite("Storyboard pipeline (scripted provider)") {
        let draftJSON = """
        {"logline":"A courier races the rain.","synopsis":"...","setting":"city","tone":"urgent",
         "initialState":{"location":"street","timeOfDay":"dusk","weather":"clouds","lighting":"neon",
                         "characterOutfit":{"Kei":"yellow jacket"},"characterPosition":{},"characterCondition":{},
                         "props":["package"],"propOwner":{"package":"Kei"},"wetness":{},"injuries":{},
                         "dialogueState":"","storyState":"start"},
         "shots":[
          {"title":"Sprint","summary":"Kei sprints down the neon street clutching a package.","durationSeconds":5,
           "shotScale":"wide","angle":"low","movement":"track","lighting":"neon reflections",
           "dialogue":[],"audioCues":["footsteps on wet asphalt"],"explicitChanges":["weather=rain","wet:Kei=rain-soaked"]},
          {"title":"Doorway","summary":"Kei ducks into a doorway, breathing hard, rain dripping.","durationSeconds":4,
           "shotScale":"close-up","angle":"eye-level","movement":"static","lighting":"dim doorway light",
           "dialogue":[{"speaker":"Kei","text":"間に合う…"}],"audioCues":["rain"],"explicitChanges":["location=doorway"]}
         ]}
        """
        let provider = MockDirectorProvider(responses: [draftJSON])
        let director = StoryboardDirector(providers: [provider])
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (project, violations, providerName) = try await director.makeProject(title: "Rain Run", brief: "courier in rain")
                t.checkEqual(providerName, "mock", "scripted provider used")
                t.checkEqual(project.shots.count, 2, "two shots materialized")
                t.checkEqual(Set(project.shots.map(\.id)).count, 2, "materialized shot IDs are unique")
                t.checkEqual(project.directorProvider, "mock", "AI provider metadata persisted")
                t.checkEqual(project.planningMode, "ai", "AI planning mode persisted")
                t.checkEqual(project.requestedDirectorMode, "auto", "AI project records requested Auto mode")
                t.checkEqual(project.effectiveDirectorMode, "localAI", "AI project records effective Local AI")
                t.checkEqual(project.storyBible.logline, "A courier races the rain.", "story bible populated")
                t.check(project.characterBible.character(named: "Kei") != nil, "character bible seeded")
                t.checkEqual(project.shots[0].continuityBefore?.location, "street", "shot 1 sees initial state")
                t.checkEqual(project.shots[1].continuityBefore?.weather, "rain", "shot 2 sees shot 1's changes")
                let keiID = project.characterBible.character(named: "Kei")?.id.uuidString ?? ""
                t.checkEqual(project.shots[1].continuityBefore?.wetness[keiID], "rain-soaked",
                             "wetness propagated under stable Character ID")
                t.check(project.shots[0].compiledPrompt.contains("sprints"), "shot 1 prompt compiled")
                t.check(project.shots[0].compiledPrompt.contains("Location:"), "continuity context prepended")
                t.check(project.shots[1].compiledPrompt.contains("間に合う"), "Japanese dialogue kept in shot prompt")
                t.check(!violations.contains { $0.severity == .error }, "no continuity errors in clean draft")
            } catch {
                t.check(false, "storyboard pipeline threw \(error)")
            }
            sem.signal()
        }
        sem.wait()
        t.check(provider.terminated, "storyboard provider terminated before render")

        // Template fallback produces a single-shot project.
        let fallback = StoryboardDirector(providers: [TemplateStoryboardProvider()])
        let sem2 = DispatchSemaphore(value: 0)
        Task {
            do {
                let (project, _, providerName) = try await fallback.makeProject(title: "T", brief: "a dog naps in the sun")
                t.checkEqual(providerName, "template", "template storyboard fallback")
                t.checkEqual(project.shots.count, 1, "single-shot fallback")
                t.check(project.shots[0].compiledPrompt.contains("dog naps"), "brief carried into prompt")
            } catch {
                t.check(false, "template storyboard threw \(error)")
            }
            sem2.signal()
        }
        sem2.wait()

        // Explicit Basic bypasses Local AI and safely decomposes only clear
        // first/next/final shot cues.
        let basicBrief = """
        最初のショットでは、女性が波打ち際を歩く。
        次のショットでは、女性が海を眺める。
        最後のショットでは、女性が振り返って微笑む。
        """
        let explicitBasic = StoryboardDirector(
            providers: [TemplateStoryboardProvider()],
            requestedMode: .basic
        )
        let basicSemaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let (project, _, providerName) = try await explicitBasic.makeProject(
                    title: "Basic", brief: basicBrief
                )
                t.checkEqual(providerName, "template", "explicit Basic uses deterministic provider")
                t.checkEqual(project.shots.count, 3, "Basic decomposes explicit three-shot cues")
                t.checkEqual(project.planningMode, "basic", "explicit Basic is not mislabeled fallback")
                t.checkEqual(project.requestedDirectorMode, "basic", "requested Basic mode persists")
                t.checkEqual(project.effectiveDirectorMode, "basic", "effective Basic mode persists")
                t.check(project.fallbackReason == nil, "explicit Basic has no failure reason")
            } catch {
                t.check(false, "explicit Basic storyboard threw \(error)")
            }
            basicSemaphore.signal()
        }
        basicSemaphore.wait()

        // Hybrid composes the same director and deterministically expands the
        // template fallback into reviewable 4–6 second shots.
        let hybridDirector = StoryboardDirector(providers: [TemplateStoryboardProvider()])
        let hybrid = HybridProjectCoordinator(director: hybridDirector)
        let sem3 = DispatchSemaphore(value: 0)
        Task {
            do {
                var settings = ProjectSettings()
                settings.applyPreset(.quickPreview)
                settings.textEncoderID = "gemma3_12b_4bit"
                settings.targetDurationSeconds = 20
                let (project, _, _) = try await hybrid.makeProject(title: "Hybrid", brief: "a train crosses a valley", settings: settings)
                t.checkEqual(project.workflowMode, "hybrid", "Hybrid workflow state recorded")
                t.checkEqual(project.shots.count, 4, "Hybrid target duration split into short shots")
                t.check(project.shots.allSatisfy { (4...6).contains($0.durationSeconds) }, "Hybrid shots are 4–6 seconds")
                t.checkEqual(Set(project.shots.map(\.id)).count, project.shots.count, "Hybrid shot IDs unique")
                t.check(project.shots.allSatisfy { !$0.compiledPrompt.isEmpty }, "Hybrid prompts compiled")
                t.checkEqual(project.settings.resolvedPreset, .quickPreview, "Hybrid uses shared preset settings")

                let projectDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LTXTests-hybrid-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: projectDir) }
                let projectStore = FilmProjectStore(projectsDirectory: projectDir)
                projectStore.save(project)
                let request = try TakeGenerationCoordinator(store: projectStore).planTakes(
                    projectID: project.id,
                    shotID: project.shots[0].id,
                    count: 1,
                    baseSeed: 700
                )[0]
                t.checkEqual(request.generationSource, "hybrid", "Hybrid request source recorded")
                t.checkEqual(request.textEncoderId, "gemma3_12b_4bit",
                             "Hybrid project encoder is preserved in GenerationRequest")
                t.checkEqual(request.targetDurationSeconds, project.shots[0].durationSeconds,
                             "Hybrid shot target carried to request")

                let history = HistoricalSuccessStore(storeURL: projectDir.appendingPathComponent("quality.json"))
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
                t.checkEqual(resolved.profile?.id, "C3", "Hybrid Quick uses shared resolver")
                t.checkEqual(resolved.request.parameters.numFrames,
                             PromptCompiler.frameCount(forSeconds: project.shots[0].durationSeconds, fps: 24),
                             "Hybrid duration survives profile application")
            } catch { t.check(false, "Hybrid orchestration threw \(error)") }
            sem3.signal()
        }
        sem3.wait()

        // Validation catches bad drafts.
        t.check(!StoryboardDirector.validate(StoryboardDirector.StoryboardDraft(
            logline: "", synopsis: nil, setting: nil, tone: nil, initialState: nil, shots: []
        )).isEmpty, "empty draft rejected")
    }

    t.suite("CharacterBible Director and prompt propagation") {
        var heroineAppearance = CharacterAppearance()
        heroineAppearance.faceDescription = "young adult woman with a soft oval face"
        heroineAppearance.hair = "dark brown high ponytail with straight bangs"
        heroineAppearance.eyes = "dark brown"
        heroineAppearance.ageImpression = "young adult"
        heroineAppearance.build = "slim"
        let heroine = BibleCharacter(
            name: "Adventurer Heroine",
            aliases: ["Heroine"],
            appearance: heroineAppearance,
            defaultCostume: "navy-and-white fantasy adventurer academy outfit",
            personality: "cheerful, adventurous, friendly",
            speakingStyle: "warm and energetic",
            continuityNotes: "keep the same facial characteristics and dark brown ponytail",
            lockedTraits: [.face, .hair, .eyes]
        )
        let bible = CharacterBible(characters: [heroine])
        let brief = """
        Adventurer Heroine explores an ancient seaside ruin at sunset.
        First, she walks through the ruined stone entrance.
        Next, she discovers a glowing magical compass.
        Finally, she picks up the compass and smiles.
        """

        let localJSON = """
        {"logline":"A heroine discovers a compass.","shots":[
          {"title":"Entrance","summary":"Adventurer Heroine enters the ruin.","durationSeconds":5,"characterIDs":["\(heroine.id.uuidString)"]},
          {"title":"Discovery","summary":"She examines a compass.","durationSeconds":5,"characterIDs":["\(heroine.id.uuidString)","unknown-id"]},
          {"title":"Horizon","summary":"She smiles toward the horizon.","durationSeconds":5,"characterIDs":["Adventurer Heroine"]}
        ]}
        """
        let provider = MockDirectorProvider(responses: [localJSON])
        let director = StoryboardDirector(providers: [provider])
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (project, violations, _) = try await director.makeProject(
                    title: "Character AI", brief: brief, characterBible: bible
                )
                t.check(provider.systems.first?.contains(heroine.id.uuidString) == true,
                        "Director prompt contains stable Character ID")
                t.check(provider.systems.first?.contains("Personality: cheerful") == true,
                        "Director receives planning-only personality")
                t.check(project.shots.allSatisfy { $0.characterIDs == [heroine.id] },
                        "AI IDs and exact unique name fallback resolve to one stable ID")
                t.check(violations.contains { $0.message.contains("unknown-id") },
                        "unknown Character ID is dropped with diagnostic")
                t.check(project.shots.allSatisfy { $0.compiledPrompt.contains("dark brown high ponytail") },
                        "hair reaches every relevant compiled prompt")
                t.check(project.shots.allSatisfy { $0.compiledPrompt.contains("soft oval face") },
                        "face guidance reaches every relevant compiled prompt")
                t.check(project.shots.allSatisfy { $0.compiledPrompt.contains("Current costume:") },
                        "default costume reaches every relevant compiled prompt")
                t.check(project.shots.allSatisfy { !$0.compiledPrompt.contains("cheerful, adventurous") },
                        "planning personality is not dumped into visual prompts")
            } catch {
                t.check(false, "CharacterBible Local AI pipeline threw \(error)")
            }
            sem.signal()
        }
        sem.wait()

        let basic = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
        let basicSem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (project, _, _) = try await basic.makeProject(
                    title: "Character Basic", brief: brief, characterBible: bible
                )
                t.checkEqual(project.shots.count, 3, "Basic makes three explicit beats")
                t.check(project.shots.allSatisfy { $0.characterIDs == [heroine.id] },
                        "Basic assigns the exact unique mentioned Bible character")
                t.check(project.shots.allSatisfy { $0.compiledPrompt.contains("CHARACTER 1: Adventurer Heroine") },
                        "Basic uses the shared Character prompt path")
            } catch {
                t.check(false, "CharacterBible Basic pipeline threw \(error)")
            }
            basicSem.signal()
        }
        basicSem.wait()

        let hybridDirector = StoryboardDirector(providers: [TemplateStoryboardProvider()], requestedMode: .basic)
        let hybrid = HybridProjectCoordinator(director: hybridDirector)
        let hybridSem = DispatchSemaphore(value: 0)
        Task {
            do {
                var settings = ProjectSettings()
                settings.targetDurationSeconds = 15
                let (project, _, _) = try await hybrid.makeProject(
                    title: "Character Hybrid", brief: brief, settings: settings, characterBible: bible
                )
                t.checkEqual(project.workflowMode, "hybrid", "Hybrid retains shared FilmProject mode")
                t.check(project.shots.allSatisfy { $0.characterIDs == [heroine.id] },
                        "Hybrid reuses the same Bible and stable Shot IDs")
                t.check(project.shots.allSatisfy { $0.compiledPrompt.contains("dark brown high ponytail") },
                        "Hybrid uses the shared compiled Character context")
            } catch {
                t.check(false, "CharacterBible Hybrid pipeline threw \(error)")
            }
            hybridSem.signal()
        }
        hybridSem.wait()
    }

    t.suite("Character prompt isolation and continuity precedence") {
        var appearanceA = CharacterAppearance()
        appearanceA.faceDescription = "oval face A"
        appearanceA.hair = "red braid A"
        var appearanceB = CharacterAppearance()
        appearanceB.faceDescription = "angular face B"
        appearanceB.hair = "black bob B"
        let a = BibleCharacter(
            name: "Ari", appearance: appearanceA, defaultCostume: "white coat A",
            continuityNotes: "silver compass A", lockedTraits: [.face, .hair, .costume]
        )
        let b = BibleCharacter(
            name: "Bea", appearance: appearanceB, defaultCostume: "blue robe B",
            continuityNotes: "gold staff B", lockedTraits: [.face]
        )
        var project = FilmProject(title: "Two Characters")
        project.characterBible = CharacterBible(characters: [a, b])
        var shot = Shot(
            index: 0,
            summary: "Ari and Bea enter.",
            explicitChanges: ["outfit:\(a.id.uuidString)=red cloak A"],
            characterIDs: [a.id, b.id],
            compiledPrompt: "The camera tracks both characters."
        )
        shot.continuityBefore = ContinuitySnapshot()
        project.shots = [shot]
        CharacterPromptPipeline.recompile(project: &project)
        let prompt = project.shots[0].compiledPrompt
        t.check(prompt.contains("CHARACTER 1: Ari") && prompt.contains("CHARACTER 2: Bea"),
                "multiple characters compile as separate labeled blocks")
        t.check(prompt.range(of: "red braid A")!.lowerBound < prompt.range(of: "CHARACTER 2: Bea")!.lowerBound,
                "Character A traits remain inside A block")
        t.check(prompt.range(of: "black bob B")!.lowerBound > prompt.range(of: "CHARACTER 2: Bea")!.lowerBound,
                "Character B traits remain inside B block")
        t.check(prompt.contains("Current costume: red cloak A"),
                "explicit Shot outfit overrides Bible default")
        t.check(prompt.contains("Current costume: blue robe B"),
                "unmodified character uses Bible default costume")

        var editedA = a
        editedA.lockedTraits.remove(.costume)
        project.upsertCharacter(editedA)
        t.checkEqual(project.shots[0].characterIDs, [a.id, b.id], "lock edit preserves Character IDs")
        t.check(project.shots[0].compiledPrompt.contains("Facial Features, Hair"),
                "face/hair guidance remains after costume lock off")
        t.check(!project.shots[0].compiledPrompt.contains("Costume, Face"),
                "costume is not added to locked trait guidance")
    }

    t.suite("Final assembly") {
        // Build a project whose selected takes point at real synthetic MP4s.
        let a = TestFixtures.videoWithAudioA // h264+aac
        let b = TestFixtures.videoWithAudioB // h264+aac same profile
        let c = TestFixtures.videoOnly       // h264, no audio
        guard FileManager.default.fileExists(atPath: a),
              FileManager.default.fileExists(atPath: b),
              FinalAssemblyService.ffmpegPath() != nil else {
            t.check(true, "baseline media unavailable — assembly integration skipped")
            return
        }

        func project(withPaths paths: [String]) -> FilmProject {
            var project = FilmProject(title: "Asm")
            for (i, path) in paths.enumerated() {
                var shot = Shot(index: i, title: "S\(i)", summary: "x")
                var take = Take(shotID: shot.id, modelID: "m", seed: i, promptSnapshot: "p",
                                settingsSnapshot: .default, requestedWidth: 512, requestedHeight: 320,
                                fps: 24, requestedDuration: 1, status: .completed)
                take.outputPath = path
                shot.takes = [take]
                shot.selectedTakeID = take.id
                project.shots.append(shot)
            }
            return project
        }

        // Compatible files → stream copy.
        do {
            let plan = try FinalAssemblyService.plan(for: project(withPaths: [a, b]))
            t.checkEqual(plan.strategy, .streamCopy, "matching files → stream copy")
        } catch { t.check(false, "plan threw \(error)") }

        // Mixed audio/no-audio → reencode.
        do {
            let plan = try FinalAssemblyService.plan(for: project(withPaths: [a, c]))
            t.checkEqual(plan.strategy, .normalizeReencode, "audio mismatch → normalize+reencode")
        } catch { t.check(false, "mixed plan threw \(error)") }

        // No selected takes → error.
        do {
            _ = try FinalAssemblyService.plan(for: FilmProject(title: "empty"))
            t.check(false, "empty project should throw")
        } catch { t.check(true, "empty project rejected") }

        // Real stream-copy assembly of two compatible baseline files.
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx-asm-test-\(UUID().uuidString).mp4").path
        defer { try? FileManager.default.removeItem(atPath: out) }
        do {
            var proj = project(withPaths: [a, b])
            proj.settings.width = 512
            proj.settings.height = 320
            let info = try FinalAssemblyService.assemble(project: proj, outputPath: out)
            t.checkEqual(info.width, 512, "assembled width")
            t.check((info.durationSeconds ?? 0) > 1.8, "assembled duration ≈ sum of parts")
            t.check(info.hasAudio, "assembled file keeps audio")
        } catch {
            t.check(false, "assembly threw \(error)")
        }
    }
}
