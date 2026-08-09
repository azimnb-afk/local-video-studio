import Foundation
@testable import LTXVideoGeneratorCore

func runFilmProjectTests(_ t: TestKit) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-film-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    func makeProject(store: FilmProjectStore) -> FilmProject {
        var project = FilmProject(title: "Test Film")
        var shot = Shot(index: 0, title: "Opening", summary: "A door opens.")
        shot.compiledPrompt = "The camera holds a static medium shot. A wooden door slowly opens."
        shot.durationSeconds = 3
        project.shots = [shot]
        store.save(project)
        return store.project(id: project.id)!
    }

    t.suite("FilmProject persistence") {
        let store = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("p1"))
        let project = makeProject(store: store)
        t.checkEqual(project.schemaVersion, FilmProject.currentSchemaVersion, "schema version stamped")

        // Reload from disk via a fresh store instance.
        let store2 = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("p1"))
        let reloaded = store2.project(id: project.id)
        t.check(reloaded != nil, "project persists across instances")
        t.checkEqual(reloaded?.shots.count, 1, "shots persist")
        t.checkEqual(reloaded?.shots.first?.compiledPrompt, project.shots.first?.compiledPrompt, "prompt persists")

        var settingsProject = project
        settingsProject.settings.applyPreset(.custom)
        settingsProject.settings.width = 768
        settingsProject.settings.height = 1080
        settingsProject.settings.numFrames = 81
        settingsProject.settings.numInferenceSteps = 35
        settingsProject.settings.audioEnabled = false
        settingsProject.directorProvider = "ollama"
        settingsProject.directorModel = "local-test-model"
        settingsProject.planningMode = "ai"
        settingsProject.fallbackReason = nil
        settingsProject.requestedDirectorMode = "auto"
        settingsProject.effectiveDirectorMode = "localAI"
        store.save(settingsProject)
        let settingsReloaded = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("p1")).project(id: project.id)
        t.checkEqual(settingsReloaded?.settings.resolvedPreset, .custom, "Project Settings preset persists")
        t.checkEqual(settingsReloaded?.settings.height, 1080, "Storyboard resolution persists")
        t.checkEqual(settingsReloaded?.settings.numFrames, 81, "Storyboard frames persist")
        t.checkEqual(settingsReloaded?.settings.audioEnabled, false, "Storyboard audio persists")
        t.checkEqual(settingsReloaded?.directorProvider, "ollama", "Director provider metadata persists")
        t.checkEqual(settingsReloaded?.directorModel, "local-test-model", "Director model metadata persists")
        t.checkEqual(settingsReloaded?.planningMode, "ai", "Planning mode metadata persists")
        t.checkEqual(settingsReloaded?.requestedDirectorMode, "auto", "Requested Director mode persists")
        t.checkEqual(settingsReloaded?.effectiveDirectorMode, "localAI", "Effective Director mode persists")

        // Newer schema is never destroyed.
        let futureURL = tmpDir.appendingPathComponent("p1").appendingPathComponent("\(UUID().uuidString).json")
        let futureJSON = """
        {"schemaVersion": 999, "id": "\(UUID().uuidString)", "title": "future"}
        """
        try? Data(futureJSON.utf8).write(to: futureURL)
        let store3 = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("p1"))
        t.check(FileManager.default.fileExists(atPath: futureURL.path), "newer-schema file left intact")
        t.checkEqual(store3.allProjects.count, 1, "newer-schema file not loaded, others fine")

        // Delete.
        let store4 = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("p1"))
        store4.delete(project.id)
        t.check(store4.project(id: project.id) == nil, "delete removes project")
    }

    t.suite("CharacterBible persistence and migration") {
        var appearance = CharacterAppearance()
        appearance.faceDescription = "soft oval face"
        appearance.hair = "dark brown ponytail"
        appearance.eyes = "dark brown"
        let allAssetTypes = CharacterReferenceAssetType.knownTypes + [
            CharacterReferenceAssetType(rawValue: "futureMultiView")
        ]
        let assets = allAssetTypes.enumerated().map { index, type in
            CharacterReferenceAsset(
                type: type,
                label: "Asset \(index)",
                projectRelativePath: "Assets/Characters/hero/asset-\(index).png",
                originalFilename: "source-\(index).png"
            )
        }
        let hero = BibleCharacter(
            name: "Adventurer Heroine",
            aliases: ["Heroine"],
            appearance: appearance,
            defaultCostume: "navy-and-white adventurer outfit",
            personality: "cheerful, adventurous",
            speakingStyle: "friendly",
            roleNotes: "lead",
            continuityNotes: "keep the same facial characteristics",
            lockedTraits: [.face, .hair, .eyes],
            referenceAssets: assets
        )
        var project = FilmProject(title: "Bible")
        project.characterBible.characters = [hero]
        project.shots = [Shot(
            index: 0,
            title: "Entrance",
            summary: "The heroine enters.",
            characterIDs: [hero.id],
            compiledPrompt: "base"
        )]
        let store = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("bible"))
        store.save(project)
        let loaded = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("bible")).project(id: project.id)
        t.checkEqual(loaded?.characterBible.characters.first?.id, hero.id, "stable Character ID persists")
        t.checkEqual(loaded?.shots.first?.characterIDs, [hero.id], "Shot Character IDs persist")
        t.checkEqual(loaded?.characterBible.characters.first?.referenceAssets.count, allAssetTypes.count,
                     "all reference asset metadata persists")
        t.checkEqual(loaded?.characterBible.characters.first?.referenceAssets.last?.type.rawValue,
                     "futureMultiView", "unknown future asset type round-trips")
        do {
            let legacyAsset = try JSONDecoder().decode(
                CharacterReferenceAsset.self,
                from: Data("{\"type\":\"characterSheet\",\"label\":\"Old Sheet\"}".utf8)
            )
            t.check(legacyAsset.detectedViews.isEmpty && legacyAsset.expressions.isEmpty,
                    "Phase 0 asset without analysis metadata still decodes")
        } catch {
            t.check(false, "Phase 0 reference asset decode threw \(error)")
        }

        // Simulate a schema-v1 project with no CharacterBible, no Shot IDs and
        // no base prompt. Existing shots/takes/jobs must survive.
        var legacyProject = FilmProject(title: "Legacy")
        var legacyShot = Shot(index: 0, title: "Old Shot", summary: "Old summary", compiledPrompt: "old prompt")
        legacyShot.takes = [Take(
            shotID: legacyShot.id,
            modelID: "legacy-model",
            seed: 42,
            promptSnapshot: "old prompt",
            settingsSnapshot: .default,
            requestedWidth: 512,
            requestedHeight: 320,
            fps: 24,
            requestedDuration: 5
        )]
        legacyProject.shots = [legacyShot]
        legacyProject.jobs = [GenerationJob(
            projectID: legacyProject.id,
            shotID: legacyShot.id,
            takeID: legacyShot.takes[0].id,
            requestID: UUID()
        )]
        do {
            let encoded = try JSONEncoder().encode(legacyProject)
            var root = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            root["schemaVersion"] = 1
            root.removeValue(forKey: "characterBible")
            if var shots = root["shots"] as? [[String: Any]] {
                shots[0].removeValue(forKey: "characterIDs")
                shots[0].removeValue(forKey: "baseCompiledPrompt")
                root["shots"] = shots
            }
            let migrated = try JSONDecoder().decode(
                FilmProject.self,
                from: JSONSerialization.data(withJSONObject: root)
            )
            t.checkEqual(migrated.schemaVersion, FilmProject.currentSchemaVersion, "legacy project migrates to current schema")
            t.check(migrated.characterBible.characters.isEmpty, "missing Bible becomes empty Bible")
            t.check(migrated.shots[0].characterIDs.isEmpty, "missing Shot IDs become empty")
            t.checkEqual(migrated.shots[0].takes.count, 1, "legacy Takes preserved")
            t.checkEqual(migrated.jobs.count, 1, "legacy Jobs preserved")
            t.checkEqual(migrated.shots[0].compiledPrompt, "old prompt", "legacy compiled prompt preserved")
        } catch {
            t.check(false, "legacy CharacterBible migration threw \(error)")
        }

        let root = store.characterAssetsDirectory(projectID: project.id, characterID: hero.id)
        t.check(root.path.contains("/\(project.id.uuidString)/Assets/Characters/\(hero.id.uuidString)"),
                "managed Character asset root is project-owned")
        t.check(store.managedCharacterAssetURL(projectID: project.id, relativePath: "Assets/Characters/x/a.png") != nil,
                "safe managed relative asset path resolves")
        t.check(store.managedCharacterAssetURL(projectID: project.id, relativePath: "../outside.png") == nil,
                "asset traversal is rejected")
        t.check(store.managedCharacterAssetURL(projectID: project.id, relativePath: "/tmp/external.png") == nil,
                "absolute external asset path is rejected")
    }

    t.suite("Character rename and delete integrity") {
        var appearance = CharacterAppearance()
        appearance.hair = "dark brown ponytail"
        let id = UUID()
        let original = BibleCharacter(
            id: id,
            name: "Adventurer Heroine",
            appearance: appearance,
            defaultCostume: "navy outfit",
            lockedTraits: [.hair]
        )
        var project = FilmProject(title: "Rename")
        project.characterBible.characters = [original]
        var shot = Shot(index: 0, summary: "She smiles.", characterIDs: [id], compiledPrompt: "The camera holds.")
        shot.continuityBefore = ContinuitySnapshot(characterOutfit: ["Adventurer Heroine": "navy outfit"])
        project.shots = [shot]
        CharacterPromptPipeline.recompile(project: &project)

        var renamed = original
        renamed.name = "Maya"
        renamed.updatedAt = Date()
        project.upsertCharacter(renamed)
        t.checkEqual(project.shots[0].characterIDs, [id], "rename preserves stable Shot reference")
        t.check(project.shots[0].compiledPrompt.contains("Maya"), "renamed display name reaches compiled prompt")
        t.check(!project.shots[0].compiledPrompt.contains("CHARACTER 1: Adventurer Heroine"),
                "old display name is not retained as prompt identity")
        t.checkEqual(project.shots[0].continuityBefore?.characterOutfit[id.uuidString], "navy outfit",
                     "legacy name-keyed continuity normalizes before rename")

        project.removeCharacter(id: id)
        t.check(project.characterBible.characters.isEmpty, "delete removes Bible character")
        t.check(project.shots[0].characterIDs.isEmpty, "delete clears every Shot reference")
        let store = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("delete"))
        store.save(project)
        let reloaded = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("delete")).project(id: project.id)
        t.check(reloaded != nil, "project reloads after referenced Character deletion")
        t.check(reloaded?.shots[0].characterIDs.isEmpty == true, "no dangling ID after reload")
    }

    t.suite("CharacterProfile bridge is explicit and non-mutating") {
        let profile = CharacterProfile(
            name: "Legacy Hero",
            prompt: "young explorer in a green coat",
            negativePrompt: "",
            sourceImagePath: "/tmp/external-reference.png",
            voiceoverText: "",
            voiceoverSource: "mlx-audio",
            voiceoverVoice: "af_heart",
            musicEnabled: false,
            musicGenre: nil,
            disableAudio: false,
            modelId: LTXModelCatalog.defaultModelID,
            parameters: .default
        )
        let candidate = CharacterProfileBibleBridge.candidate(from: profile)
        t.checkEqual(candidate.name, profile.name, "bridge creates an explicit candidate")
        t.checkEqual(candidate.appearance.generalNotes, profile.prompt, "profile prompt remains reviewable input")
        t.check(candidate.referenceAssets.isEmpty, "external profile image path is not silently adopted")
        t.checkEqual(profile.sourceImagePath, "/tmp/external-reference.png", "existing CharacterProfile is untouched")
    }

    t.suite("Take planning (1-20, sequential)") {
        let store = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("p2"))
        let project = makeProject(store: store)
        let shotID = project.shots[0].id
        let sem = DispatchSemaphore(value: 0)
        Task {
            let coordinator = TakeGenerationCoordinator(store: store)

            // Invalid counts rejected.
            do {
                _ = try coordinator.planTakes(projectID: project.id, shotID: shotID, count: 0)
                t.check(false, "count 0 should throw")
            } catch { t.check(true, "count 0 rejected") }
            do {
                _ = try coordinator.planTakes(projectID: project.id, shotID: shotID, count: 21)
                t.check(false, "count 21 should throw")
            } catch { t.check(true, "count 21 rejected (max 20)") }

            // 20 takes with distinct seeds.
            do {
                let requests = try coordinator.planTakes(projectID: project.id, shotID: shotID, count: 20, baseSeed: 1000)
                t.checkEqual(requests.count, 20, "20 requests planned")
                t.checkEqual(Set(requests.compactMap { $0.parameters.seed }).count, 20, "all seeds distinct")
                t.check(requests.allSatisfy { $0.shotID == shotID && $0.filmProjectID == project.id }, "requests linked to shot/project")
                t.check(requests.allSatisfy { $0.takeID != nil }, "requests carry takeID")
                let saved = store.project(id: project.id)!
                t.checkEqual(saved.shots[0].takes.count, 20, "takes persisted")
                t.checkEqual(saved.jobs.count, 20, "jobs recorded")
                t.check(saved.shots[0].takes.allSatisfy { $0.status == .queued }, "takes queued")
                // Frame count derives from duration (3s → 73f).
                t.checkEqual(requests.first?.parameters.numFrames, PromptCompiler.frameCount(forSeconds: 3), "frames from shot duration")
                t.checkEqual(requests.first?.preset, GenerationPreset.standard.rawValue, "take request records Standard preset")
                t.checkEqual(requests.first?.targetDurationSeconds, 3.0, "Storyboard shot duration is carried as target")
                t.checkEqual(requests.first?.generationSource, "storyboard", "Storyboard source recorded")
                t.checkEqual(saved.shots[0].takes.first?.preset, GenerationPreset.standard.rawValue, "take snapshot records preset")

                coordinator.recordCancellation(request: requests[1])
                let afterCancellation = store.project(id: project.id)!
                t.checkEqual(afterCancellation.shots[0].takes[1].status, .cancelled,
                             "cancelled request persists cancelled Take state")
                t.checkEqual(afterCancellation.jobs.first { $0.takeID == requests[1].takeID }?.state, .cancelled,
                             "cancelled request persists cancelled Job state")
            } catch {
                t.check(false, "planTakes threw \(error)")
            }

            // Switching project preset appends a new take and keeps all preview takes.
            if var changed = store.project(id: project.id) {
                let previousCount = changed.shots[0].takes.count
                changed.settings.applyPreset(.highQuality)
                store.save(changed)
                do {
                    let requests = try coordinator.planTakes(projectID: project.id, shotID: shotID, count: 1, baseSeed: 5000)
                    let afterRegeneration = store.project(id: project.id)!
                    t.checkEqual(afterRegeneration.shots[0].takes.count, previousCount + 1, "quality regeneration appends take")
                    t.checkEqual(afterRegeneration.shots[0].takes.first?.preset, GenerationPreset.standard.rawValue,
                                 "existing preview take retained")
                    t.checkEqual(afterRegeneration.shots[0].takes.last?.preset, GenerationPreset.highQuality.rawValue,
                                 "new High Quality take distinguished")
                    t.checkEqual(requests.first?.qualityMode, QualityMode.high.rawValue, "regeneration uses current project preset")
                    t.checkEqual(requests.first?.targetDurationSeconds, 3.0, "regeneration keeps shot duration constraint")

                    let history = HistoricalSuccessStore(storeURL: tmpDir.appendingPathComponent("film-quality.json"))
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
                    let resolved = try GenerationSettingsResolver.resolve(request: requests[0], engine: engine, snapshot: snapshot)
                    t.checkEqual(resolved.profile?.id, "H0", "Storyboard regeneration resolves High through shared policy")
                    t.checkEqual(resolved.request.parameters.numFrames, PromptCompiler.frameCount(forSeconds: 3, fps: 24),
                                 "Storyboard duration survives High profile application")
                } catch { t.check(false, "quality regeneration threw \(error)") }
            }

            // Completion linkage.
            let saved = store.project(id: project.id)!
            let take = saved.shots[0].takes[0]
            let result = GenerationResult(
                id: UUID(), requestId: UUID(), prompt: take.promptSnapshot,
                enhancedPrompt: nil, negativePrompt: "", voiceoverText: "",
                voiceoverSource: "mlx-audio", voiceoverVoice: "af_heart",
                modelId: take.modelID, parameters: take.settingsSnapshot,
                videoPath: "/tmp/ltx_baseline/T2V-A-ON.mp4", thumbnailPath: nil,
                audioPath: nil, musicPath: nil, musicGenre: nil, sourceImagePath: nil,
                createdAt: Date(), completedAt: Date(), duration: 49, seed: take.seed,
                filmProjectID: project.id, shotID: shotID, takeID: take.id
            )
            coordinator.recordCompletion(result: result)
            let after = store.project(id: project.id)!
            let completedTake = after.shots[0].takes.first { $0.id == take.id }
            t.checkEqual(completedTake?.status, .completed, "take marked completed")
            t.checkEqual(completedTake?.outputPath, "/tmp/ltx_baseline/T2V-A-ON.mp4", "output path recorded")
            t.check(after.jobs.first { $0.takeID == take.id }?.state == .completed, "job marked completed")

            // Selection.
            do {
                try coordinator.selectTake(projectID: project.id, shotID: shotID, takeID: take.id)
                t.checkEqual(store.project(id: project.id)?.shots[0].selectedTakeID, take.id, "take selected")
                t.checkEqual(store.project(id: project.id)?.shots[0].selectedTake?.id, take.id, "selectedTake resolves")
            } catch {
                t.check(false, "selectTake threw \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }

    t.suite("Resume reconciliation") {
        let store = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("p3"))
        var project = makeProject(store: store)
        let shotID = project.shots[0].id

        // Take A: was generating, MP4 exists (baseline file) → completed.
        var takeA = Take(
            shotID: shotID, modelID: "m", seed: 1, promptSnapshot: "p",
            settingsSnapshot: .default, requestedWidth: 512, requestedHeight: 320,
            fps: 24, requestedDuration: 1, status: .generating
        )
        takeA.outputPath = "/tmp/ltx_baseline/T2V-A-ON.mp4"
        // Take B: was generating, no file → back to queued.
        var takeB = Take(
            shotID: shotID, modelID: "m", seed: 2, promptSnapshot: "p",
            settingsSnapshot: .default, requestedWidth: 512, requestedHeight: 320,
            fps: 24, requestedDuration: 1, status: .generating
        )
        takeB.outputPath = "/tmp/does-not-exist-\(UUID().uuidString).mp4"
        project.shots[0].takes = [takeA, takeB]
        project.jobs = [GenerationJob(projectID: project.id, shotID: shotID, takeID: takeA.id, requestID: UUID(), state: .running)]
        store.save(project)

        let reconciled = store.reconcileInFlightTakes(projectID: project.id)
        t.checkEqual(reconciled, 2, "two in-flight takes reconciled")
        let after = store.project(id: project.id)!
        let baselineExists = FileManager.default.fileExists(atPath: "/tmp/ltx_baseline/T2V-A-ON.mp4")
        if baselineExists {
            t.checkEqual(after.shots[0].takes[0].status, .completed, "take with real MP4 → completed")
            t.checkEqual(after.shots[0].takes[0].actualWidth, 512, "actual width filled from probe")
        } else {
            t.checkEqual(after.shots[0].takes[0].status, .queued, "take without MP4 → queued (baseline absent)")
        }
        t.checkEqual(after.shots[0].takes[1].status, .queued, "take without MP4 → requeued")
        t.checkEqual(after.jobs[0].state, .queued, "running job → queued")
    }
}
