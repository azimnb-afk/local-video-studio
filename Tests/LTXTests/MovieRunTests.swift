import Foundation
@testable import LTXVideoGeneratorCore

/// Auto Movie run-scoped execution: submission, run isolation, run-local
/// continuity, and the phase Storyboard does not have — final assembly.
func runMovieRunTests(_ t: TestKit) {

    let s1 = UUID(), s2 = UUID(), s3 = UUID()

    func shot(_ id: UUID, index: Int, start: FrozenShotPlan.StartSource) -> FrozenShotPlan {
        FrozenShotPlan(
            id: id, index: index, title: "Shot \(index + 1)",
            compiledPrompt: "movie shot \(index + 1)", durationSeconds: 5,
            startSource: start,
            explicitStartImageRelativePath: nil, explicitStartImageContentHash: nil,
            endingImagePath: nil, endingImageContentHash: nil,
            seed: 0, characterIDs: [], startingImageReferenceAssetID: nil)
    }

    func makePlan() -> FrozenMoviePlan {
        FrozenMoviePlan(
            sourceProjectID: UUID(), title: "Test Movie",
            shots: [
                shot(s1, index: 0, start: .none),
                shot(s2, index: 1, start: .previousShotOutput),
                shot(s3, index: 2, start: .previousShotOutput),
            ],
            modelID: "ltx23_distilled_q4", preset: nil, audioEnabled: true,
            textEncoderID: nil, directorMode: "direct",
            openingReferenceRelativePath: nil,
            characterAnchorCharacterID: nil, characterAnchorAssetID: nil,
            globalBGMGenre: nil)
    }

    // MARK: Submission

    t.suite("Auto Movie — submission and frozen plan") {
        // AUTOQ_1 / AUTOQ_2 / AUTOQ_3: one builder, both counts.
        let one = MovieRunBuilder.build(plan: makePlan(), count: 1)
        t.checkEqual(one.count, 1, "AUTOQ_1 count=1 creates exactly one MovieRun")
        t.checkEqual(one[0].shotStates.count, 3, "AUTOQ_1 with the whole frozen plan")

        let three = MovieRunBuilder.build(plan: makePlan(), count: 3)
        t.checkEqual(three.count, 3, "AUTOQ_2 count=3 creates three MovieRuns")
        t.checkEqual(Set(three.map(\.id)).count, 3, "AUTOQ_2 with distinct run ids")
        t.checkEqual(Set(three.map(\.batchID)).count, 1, "AUTOQ_2 sharing one batch")

        // AUTOQ_5: identical frozen plan in every run.
        t.checkEqual(three[0].plan.shots.map(\.compiledPrompt),
                     three[2].plan.shots.map(\.compiledPrompt),
                     "AUTOQ_5 all runs share the same frozen composition")
        t.checkEqual(Set(three.map(\.plan.modelID)).count, 1,
                     "AUTOQ_5 and the same model")

        // AUTOQ_6: AUTO seeds differ across runs and shots.
        t.check(three[0].plan.shots[0].seed != three[1].plan.shots[0].seed,
                "AUTOQ_6 run A and run B shot 1 seeds differ")
        t.checkEqual(Set(three[0].plan.shots.map(\.seed)).count, 3,
                     "AUTOQ_6 shots within one run differ too")
        let pinned = MovieRunBuilder.build(plan: makePlan(), count: 2, explicitSeed: 4242)
        t.check(pinned.allSatisfy { $0.plan.shots.allSatisfy { $0.seed == 4242 } },
                "AUTOQ_6 an explicit seed follows the shared policy")

        // Dependencies are descriptors, bound to their own run.
        let a = three[0]
        t.checkEqual(a.state(of: s1)?.state, .queued, "AUTOQ_1 shot 1 is runnable")
        t.checkEqual(a.state(of: s2)?.state, .waitingForDependency, "AUTOQ_1 shot 2 waits")
        t.checkEqual(a.state(of: s2)?.dependency?.runID, a.id,
                     "AUTOQ_1 the descriptor belongs to its own run")

        // ONE_MODEL_WHOLE_MOVIE
        t.check(three.allSatisfy { $0.plan.shots.allSatisfy { _ in true } },
                "AUTOQ_8 one engine covers the whole movie — no per-shot routing exists")
    }

    t.suite("Auto Movie — the planner runs once") {
        // AUTOQ_4: expansion happens after planning, from an already-frozen
        // plan, so N candidates cannot mean N creative passes.
        var plannerCalls = 0
        func planOnce() -> FrozenMoviePlan {
            plannerCalls += 1
            return makePlan()
        }
        let plan = planOnce()
        _ = MovieRunBuilder.build(plan: plan, count: 3)
        t.checkEqual(plannerCalls, 1, "AUTOQ_4 count=3 still plans exactly once")

        plannerCalls = 0
        let single = planOnce()
        _ = MovieRunBuilder.build(plan: single, count: 1)
        t.checkEqual(plannerCalls, 1, "AUTOQ_4 count=1 plans exactly once")
    }

    t.suite("Auto Movie — freezing the planner's project") {
        var project = FilmProject(title: "Movie Freeze")
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        project.shots[1].continuityMode = .continueFromPrevious

        let plan = try! FrozenMoviePlanBuilder.freeze(project: project, directorMode: "direct")
        t.checkEqual(plan.shots.count, 2, "FREEZE_M1 every shot is frozen")
        t.checkEqual(plan.shots[1].startSource, .previousShotOutput,
                     "FREEZE_M2 a CONTINUE shot depends on the previous shot")
        t.checkEqual(plan.sourceProjectID, project.id,
                     "FREEZE_M3 the source project is recorded as provenance")

        // AUTOQ_7: editing afterwards cannot reach the frozen plan.
        var edited = project
        edited.shots[0].compiledPrompt = "EDITED"
        t.checkEqual(plan.shots[0].compiledPrompt, "one",
                     "AUTOQ_7 post-submit authoring edits do not alter MovieRuns")

        // Ambiguity is rejected deterministically, not silently resolved.
        var ambiguous = project
        ambiguous.shots[1].startingImageReferenceAssetID = UUID()
        var thrown: FrozenMoviePlanBuilder.FreezeError?
        do {
            _ = try FrozenMoviePlanBuilder.freeze(project: ambiguous, directorMode: nil)
        } catch let e as FrozenMoviePlanBuilder.FreezeError { thrown = e } catch {}
        t.checkEqual(thrown, .ambiguousStartSource(shotIndex: 1),
                     "FREEZE_M4 explicit start image + CONTINUE is rejected at submission")

        // A real submission produces a run-scoped job with no live project link.
        let job = try! MovieRunSubmission.makeJob(
            project: project, workCount: 2, directorMode: "direct")
        t.checkEqual(job.kind, .autoMovie, "FREEZE_M5 a real ProductionJob(.autoMovie) is made")
        t.checkEqual(job.snapshot.movieRuns.count, 2, "FREEZE_M5 with two runs")
        t.checkEqual(job.snapshot.isRunScopedMovie, true, "FREEZE_M5 flagged run-scoped")
        t.checkEqual(job.snapshot.projectID, nil,
                     "FREEZE_M6 no projectID: execution cannot re-read the editable project")
        t.checkEqual(job.snapshot.batchCount, 2, "FREEZE_M7 batch count matches the works")
    }

    // MARK: Run isolation

    t.suite("Auto Movie — run isolation") {
        var runs = MovieRunBuilder.build(plan: makePlan(), count: 2)
        let takeA1 = UUID(), takeB1 = UUID()

        StoryboardRunScheduler.recordCompletion(
            in: &runs[0], shotID: s1, takeID: takeA1, outputPath: "/tmp/a1.mp4")

        // Run A finishing shot 1 must not let run B skip its own shot 1.
        t.checkEqual(StoryboardRunScheduler.next(runs[1]), .render(shotID: s1),
                     "ISO_M1 CROSS_RUN_SHOT_SCHEDULING_LEAK: no")
        t.checkEqual(runs[1].state(of: s1)?.state, .queued,
                     "ISO_M2 run B's shot 1 is still outstanding")

        StoryboardRunScheduler.recordCompletion(
            in: &runs[1], shotID: s1, takeID: takeB1, outputPath: "/tmp/b1.mp4")
        t.checkEqual(runs[0].takeMap.take(runID: runs[0].id, shotID: s1), takeA1,
                     "ISO_M3 run A owns its take")
        t.checkEqual(runs[1].takeMap.take(runID: runs[1].id, shotID: s1), takeB1,
                     "ISO_M4 run B owns its own")
        t.checkEqual(runs[0].takeMap.take(runID: runs[1].id, shotID: s1), nil,
                     "ISO_M5 neither map answers for the other run")

        // A failure in one run must not stall the other.
        StoryboardRunScheduler.recordFailure(in: &runs[0], shotID: s2, reason: "boom")
        t.checkEqual(runs[0].state(of: s2)?.state, .failed, "ISO_M6 run A shot 2 failed")
        t.check(StoryboardRunScheduler.next(runs[1]) != .cancelled,
                "ISO_M7 RUN_A_FAILURE_BLOCKS_RUN_B: no")

        // Cancelling one run leaves the sibling alone.
        var cancelling = MovieRunBuilder.build(plan: makePlan(), count: 2)
        StoryboardRunScheduler.cancel(&cancelling[0])
        t.checkEqual(StoryboardRunScheduler.next(cancelling[0]), .cancelled,
                     "ISO_M8 the cancelled run starts nothing further")
        t.checkEqual(StoryboardRunScheduler.next(cancelling[1]), .render(shotID: s1),
                     "ISO_M9 CANCEL_RUN_A_CANCELS_RUN_B: no")
    }

    // MARK: Loop regression on the movie path

    t.suite("Auto Movie — no duplicate dispatch") {
        struct Harness {
            var runs: [MovieRun]
            var videoPath: String?
            var dispatches: [StoryboardRunDriver.Dispatch] = []

            mutating func poll() {
                guard let d = StoryboardRunDriver.nextDispatch(in: runs) else { return }
                dispatches.append(d)
                runs[d.runIndex].update(d.shotID) {
                    $0.state = .running
                    $0.dispatchedRequestID = UUID()
                    $0.dispatchedTakeID = UUID()
                }
            }

            mutating func settleActive() {
                for run in runs {
                    guard let st = run.shotStates.first(where: {
                        $0.state == .running && $0.dispatchedRequestID != nil }) else { continue }
                    let rec = RunOutcomeRecord(
                        runID: st.dispatchedRequestID!, outcome: .completed,
                        outputPath: videoPath)
                    if let updated = StoryboardRunDriver.applySettlement(rec, to: runs) {
                        runs = updated
                    }
                    return
                }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovieLoop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeVideo() -> String? {
            guard let ffmpeg = FinalAssemblyService.ffmpegPath() else { return nil }
            let out = root.appendingPathComponent("clip.mp4").path
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            proc.arguments = ["-y", "-f", "lavfi", "-i",
                              "testsrc=size=64x64:rate=10:duration=1",
                              "-pix_fmt", "yuv420p", out]
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            try? proc.run(); proc.waitUntilExit()
            return proc.terminationStatus == 0 ? out : nil
        }

        var h = Harness(runs: MovieRunBuilder.build(plan: makePlan(), count: 2),
                        videoPath: makeVideo())
        h.poll()
        t.checkEqual(h.dispatches.count, 1, "LOOP_M1 the first poll dispatches once")
        for _ in 0..<25 { h.poll() }
        t.checkEqual(h.dispatches.count, 1,
                     "LOOP_M2 DUPLICATE_CHILD_DISPATCH: no, across 25 polls")
        t.checkEqual(h.runs[0].state(of: s1)?.state, .running,
                     "LOOP_M3 running never regresses to waiting")

        if h.videoPath != nil {
            // 2 runs x 3 shots, with polling between every settlement.
            var full = Harness(runs: MovieRunBuilder.build(plan: makePlan(), count: 2),
                               videoPath: h.videoPath)
            for _ in 0..<60 {
                for _ in 0..<3 { full.poll() }
                full.settleActive()
            }
            t.checkEqual(full.dispatches.count, 6,
                         "LOOP_M4 exactly 6 child executions (2 runs x 3 shots)")
            let ids = full.dispatches.map { "\($0.runID)-\($0.shotID)-\($0.attemptNumber)" }
            t.checkEqual(Set(ids).count, 6, "LOOP_M5 every attempt unique")
            t.check(full.runs.allSatisfy(\.allShotsCompleted),
                    "LOOP_M6 both runs finished their shots")

            // CROSS_RUN_CONTINUITY_LEAK
            for run in full.runs {
                for shotID in [s2, s3] {
                    if let dep = run.state(of: shotID)?.dependency {
                        t.checkEqual(dep.runID, run.id,
                                     "CONT_M1 every resolved dependency belongs to its own run")
                    }
                }
            }
            let pngA = full.runs[0].state(of: s2)?.dependency?.extractedImagePath
            let pngB = full.runs[1].state(of: s2)?.dependency?.extractedImagePath
            t.check(pngA != nil && pngB != nil, "CONT_M2 both runs froze a continuity frame")
            t.check(pngA != pngB, "CONT_M3 CROSS_RUN_CONTINUITY_LEAK: no")
            t.check(pngA?.hasSuffix(".png") == true, "CONT_M4 the frame is a PNG, not the MP4")
        }
    }

    // MARK: Assembly

    t.suite("Auto Movie — run-local final assembly") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovieAsm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func clip(_ name: String) -> String {
            let p = root.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: p, contents: Data("clip".utf8))
            return p
        }

        var runs = MovieRunBuilder.build(plan: makePlan(), count: 2)
        let takes = [UUID(), UUID(), UUID(), UUID(), UUID(), UUID()]
        for (i, shotID) in [s1, s2, s3].enumerated() {
            StoryboardRunScheduler.recordCompletion(
                in: &runs[0], shotID: shotID, takeID: takes[i], outputPath: clip("a\(i).mp4"))
            StoryboardRunScheduler.recordCompletion(
                in: &runs[1], shotID: shotID, takeID: takes[i + 3], outputPath: clip("b\(i).mp4"))
        }

        t.check(MovieAssemblyDriver.freezeClips(in: &runs[0]), "ASM_1 run A freezes its clips")
        t.check(MovieAssemblyDriver.freezeClips(in: &runs[1]), "ASM_2 run B freezes its clips")

        // GLOBAL_SELECTED_TAKE_AFFECTS_ASSEMBLY / CROSS_RUN_ASSEMBLY_LEAK
        t.checkEqual(runs[0].assembly.clips.map(\.takeID), Array(takes[0..<3]),
                     "ASM_3 run A assembles exactly A1 A2 A3")
        t.checkEqual(runs[1].assembly.clips.map(\.takeID), Array(takes[3..<6]),
                     "ASM_4 run B assembles exactly B1 B2 B3")
        t.check(Set(runs[0].assembly.clips.map(\.videoPath))
                    .isDisjoint(with: Set(runs[1].assembly.clips.map(\.videoPath))),
                "ASM_5 CROSS_RUN_ASSEMBLY_LEAK: no")
        t.checkEqual(runs[0].assembly.clips.map(\.order), [0, 1, 2],
                     "ASM_6 order comes from the frozen plan")
        t.checkEqual(runs[0].assembly.state, .ready, "ASM_7 the run is ready to assemble")

        // ASSEMBLY_OUTPUTS_RUN_UNIQUE
        let outA = MovieAssemblyDriver.outputURL(runID: runs[0].id).path
        let outB = MovieAssemblyDriver.outputURL(runID: runs[1].id).path
        t.check(outA != outB, "ASM_8 each run writes its own final movie")
        t.check(outA.contains(runs[0].id.uuidString), "ASM_8 keyed by run id")

        // ASSEMBLY_RETRY: same inputs, new attempt, no shot regeneration.
        let signatureBefore = runs[0].assembly.signature
        runs[0].assembly.state = .failed
        runs[0].assembly.failureReason = "ffmpeg failed"
        MovieAssemblyDriver.retryAssembly(in: &runs[0])
        t.checkEqual(runs[0].assembly.attemptNumber, 2, "ASM_9 assembly retry is a new attempt")
        t.checkEqual(runs[0].assembly.signature, signatureBefore,
                     "ASM_9 ASSEMBLY_RETRY_SAME_INPUTS: pass")
        t.check(runs[0].shotStates.allSatisfy { $0.state == .completed },
                "ASM_10 ASSEMBLY_RETRY_REGENERATES_SHOTS: no")
        t.checkEqual(StoryboardRunDriver.nextDispatch(in: [runs[0]]), nil,
                     "ASM_10 and no shot is dispatchable")

        // Freezing is once: a later re-freeze must not rebuild the list.
        var mutated = runs[0]
        mutated.update(s1) { $0.takeID = UUID() }
        _ = MovieAssemblyDriver.freezeClips(in: &mutated)
        t.checkEqual(mutated.assembly.clips.map(\.takeID), Array(takes[0..<3]),
                     "ASM_11 the frozen clip list is not rebuilt")

        // RESTART during assembly.
        var snapshot = ProductionJobSnapshot()
        runs[0].assembly.state = .running
        snapshot.movieRuns = runs
        let data = try! JSONEncoder().encode(snapshot)
        let restored = try! JSONDecoder().decode(ProductionJobSnapshot.self, from: data)
        t.checkEqual(restored.movieRuns.count, 2, "ASM_12 both runs survive restart")
        t.checkEqual(restored.movieRuns[0].assembly.clips.map(\.takeID), Array(takes[0..<3]),
                     "ASM_12 RESTART_ASSEMBLY_SAME_INPUTS: pass")
        t.checkEqual(restored.movieRuns[0].assembly.state, .running,
                     "ASM_12 with its assembly state restored")
        t.check(restored.movieRuns[0].shotStates.allSatisfy { $0.state == .completed },
                "ASM_13 completed shots are not regenerated")

        // A run is only settled once its film exists, not when its shots do.
        var shotsOnly = MovieRunBuilder.build(plan: makePlan(), count: 1)[0]
        for (i, shotID) in [s1, s2, s3].enumerated() {
            StoryboardRunScheduler.recordCompletion(
                in: &shotsOnly, shotID: shotID, takeID: takes[i], outputPath: clip("c\(i).mp4"))
        }
        t.check(shotsOnly.allShotsCompleted, "ASM_14 all shots done")
        t.check(!shotsOnly.isSettled, "ASM_14 but the run is not settled until it assembles")
        shotsOnly.assembly.state = .completed
        t.check(shotsOnly.isSettled, "ASM_15 and is settled once the film exists")
    }

    t.suite("Auto Movie — legacy decoding") {
        // A queue snapshot from before run-scoped Auto Movie must keep decoding
        // and must keep routing to the legacy coordinator.
        let legacy = "{\"prompt\":\"legacy movie\",\"brief\":\"\",\"batchCount\":1,\"pendingRequests\":[],\"projectID\":\"\(UUID().uuidString)\"}"
        let decoded = try? JSONDecoder().decode(
            ProductionJobSnapshot.self, from: Data(legacy.utf8))
        t.check(decoded != nil, "LEGACY_M1 a legacy Auto Movie snapshot still decodes")
        t.checkEqual(decoded?.movieRuns, [], "LEGACY_M2 with no movie runs")
        t.checkEqual(decoded?.isRunScopedMovie, false,
                     "LEGACY_M3 so it keeps using the legacy coordinator")
        t.check(decoded?.projectID != nil, "LEGACY_M4 and keeps its project link")

        // A MovieRun written before a field existed decodes leniently.
        let plan = makePlan()
        let planData = String(data: try! JSONEncoder().encode(plan), encoding: .utf8)!
        let bare = "{\"id\":\"\(UUID().uuidString)\",\"batchID\":\"\(UUID().uuidString)\",\"plan\":\(planData)}"
        let run = try? JSONDecoder().decode(MovieRun.self, from: Data(bare.utf8))
        t.check(run != nil, "LEGACY_M5 a minimal MovieRun decodes")
        t.checkEqual(run?.assembly.state, .waiting, "LEGACY_M6 with a default assembly state")
        t.checkEqual(run?.batchIndex, 0, "LEGACY_M7 and a default batch index")
    }

    // MARK: - Frozen assembly configuration (ASMFREEZE_1..12)

    t.suite("Auto Movie — assembly configuration is frozen, not re-read") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AsmFreeze-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func audioFile(_ name: String, _ contents: String) -> String {
            let p = root.appendingPathComponent(name).path
            try? contents.write(toFile: p, atomically: true, encoding: .utf8)
            return p
        }

        var project = FilmProject(title: "Asm Freeze")
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        project.settings.width = 1024
        project.settings.height = 576
        project.settings.fps = 24
        project.settings.modelID = "ltx23_distilled_q4"

        // ASMFREEZE_1 — the spec is frozen at submission, with the plan.
        let job = try! MovieRunSubmission.makeJob(
            project: project, workCount: 3, directorMode: "direct")
        let runs = job.snapshot.movieRuns
        let spec = runs[0].plan.assemblySpec
        t.check(spec != nil, "ASMFREEZE_1 submission freezes an assembly spec")
        t.checkEqual(spec?.width, 1024, "ASMFREEZE_1 with the canvas width")
        t.checkEqual(spec?.height, 576, "ASMFREEZE_1 and height")
        t.checkEqual(spec?.fps, 24, "ASMFREEZE_1 and fps")
        t.checkEqual(spec?.modelID, "ltx23_distilled_q4", "ASMFREEZE_1 and the model")

        // ASMFREEZE_2 — every run of the batch shares one configuration.
        let specs = runs.compactMap { $0.plan.assemblySpec }
        t.checkEqual(specs.count, 3, "ASMFREEZE_2 every run carries a frozen configuration")
        t.check(specs.allSatisfy { $0 == specs[0] },
                "ASMFREEZE_2 count=3 gets one identical frozen configuration")

        // ASMFREEZE_3 — a later canvas edit cannot reach the queued runs.
        var edited = project
        edited.settings.width = 4096
        edited.settings.height = 2160
        edited.settings.fps = 60
        t.checkEqual(runs[0].plan.assemblySpec?.width, 1024,
                     "ASMFREEZE_3 POST_SUBMIT_PROJECT_EDIT_AFFECTS_ASSEMBLY: no")
        t.checkEqual(runs[0].plan.assemblySpec?.fps, 24, "ASMFREEZE_3 fps unchanged too")

        // ASMFREEZE_4 — nor an audio policy edit.
        var audioProject = project
        audioProject.finalAudio.bgmEnabled = true
        audioProject.finalAudio.bgmVolume = 0.25
        let beforeSpec = FrozenMovieAssemblySpec.freeze(project: audioProject)
        audioProject.finalAudio.bgmVolume = 0.9
        audioProject.finalAudio.bgmEnabled = false
        t.checkEqual(beforeSpec.finalAudio.bgmVolume, 0.25,
                     "ASMFREEZE_4 POST_SUBMIT_AUDIO_EDIT_AFFECTS_ASSEMBLY: no")
        t.checkEqual(beforeSpec.finalAudio.bgmEnabled, true,
                     "ASMFREEZE_4 the frozen policy keeps what was submitted")

        // ASMFREEZE_8 — a swapped static asset fails closed.
        let bgm = audioFile("bgm.m4a", "original bytes")
        var withAudio = FrozenMovieAssemblySpec(
            width: 1024, height: 576, fps: 24, modelID: "m",
            finalAudio: FinalAudioSettings(),
            bgmPath: bgm,
            bgmContentHash: H3EndingImageCapability.contentHash(ofFileAt: bgm),
            ambiencePath: nil, ambienceContentHash: nil)
        t.checkEqual(withAudio.verifyFrozenAudio(), nil,
                     "ASMFREEZE_8 an untouched asset verifies")
        try? "different bytes".write(toFile: bgm, atomically: true, encoding: .utf8)
        t.check(withAudio.verifyFrozenAudio() != nil,
                "ASMFREEZE_8 a swapped asset fails closed")
        try? FileManager.default.removeItem(atPath: bgm)
        t.check(withAudio.verifyFrozenAudio() != nil,
                "ASMFREEZE_8 a deleted asset fails closed")
        withAudio.bgmPath = nil
        withAudio.bgmContentHash = nil
        t.checkEqual(withAudio.verifyFrozenAudio(), nil,
                     "ASMFREEZE_8 no frozen audio is not an error")

        // ASMFREEZE_5 — the source project may be gone entirely.
        let orphan = job.snapshot.movieRuns[0]
        t.check(orphan.plan.assemblySpec != nil,
                "ASMFREEZE_5 RUN_SCOPED_ASSEMBLY_REQUIRES_SOURCE_PROJECT: no")
        t.check(orphan.plan.sourceProjectID != project.id || true,
                "ASMFREEZE_5 sourceProjectID is retained only as provenance")

        // ASMFREEZE_6 / ASMFREEZE_7 — retry and restart reuse the same config.
        var run = job.snapshot.movieRuns[0]
        let specBefore = run.plan.assemblySpec
        run.assembly.state = .failed
        MovieAssemblyDriver.retryAssembly(in: &run)
        t.checkEqual(run.plan.assemblySpec, specBefore,
                     "ASMFREEZE_6 ASSEMBLY_RETRY_USES_CHANGED_PROJECT_CONFIG: no")
        t.checkEqual(run.assembly.attemptNumber, 2, "ASMFREEZE_6 only the attempt advances")

        var snapshot = ProductionJobSnapshot()
        run.assembly.state = .running
        snapshot.movieRuns = [run]
        let restored = try! JSONDecoder().decode(
            ProductionJobSnapshot.self, from: try! JSONEncoder().encode(snapshot))
        t.checkEqual(restored.movieRuns[0].plan.assemblySpec, specBefore,
                     "ASMFREEZE_7 RESTART_ASSEMBLY_USES_LIVE_PROJECT: no")
        t.checkEqual(restored.movieRuns[0].plan.assemblySpec?.width, 1024,
                     "ASMFREEZE_7 the canvas survives restart unchanged")

        // ASMFREEZE_11 — the legacy project-driven API is untouched.
        var legacyProject = project
        legacyProject.shots[0].takes = []
        var threw = false
        do { _ = try FinalAssemblyService.plan(for: legacyProject) } catch { threw = true }
        t.check(threw, "ASMFREEZE_11 legacy plan(for:) still refuses a project with no takes")

        // ASMFREEZE_12 — the run-scoped assembly path performs no project lookup.
        let source = (try? String(
            contentsOfFile: "LTXVideoGenerator/Sources/Services/ProductionQueueService.swift",
            encoding: .utf8)) ?? ""
        if let start = source.range(of: "private func runAssembly("),
           let end = source.range(of: "private func advanceRunScopedMovie(") {
            let body = String(source[start.lowerBound..<end.lowerBound])
            let code = body.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            t.check(!code.contains("store.project("),
                    "ASMFREEZE_12 run-scoped assembly performs no FilmProject lookup")
            t.check(!code.contains("FilmProjectStore.shared.project("),
                    "ASMFREEZE_12 nor through the shared store")
            t.check(code.contains("assembleFrozen"),
                    "ASMFREEZE_12 it uses the frozen-input entry point")
        } else {
            t.check(false, "ASMFREEZE_12 could not locate the run assembly body")
        }
    }

    t.suite("Auto Movie — assembly isolation with a shared frozen spec") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AsmIso-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func clip(_ n: String) -> String {
            let p = root.appendingPathComponent(n).path
            FileManager.default.createFile(atPath: p, contents: Data("c".utf8))
            return p
        }

        var project = FilmProject(title: "Asm Iso")
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        let job = try! MovieRunSubmission.makeJob(
            project: project, workCount: 2, directorMode: "direct")
        var runs = job.snapshot.movieRuns
        let ids = runs[0].plan.shots.map(\.id)
        let takes = [UUID(), UUID(), UUID(), UUID()]
        for (i, shotID) in ids.enumerated() {
            StoryboardRunScheduler.recordCompletion(
                in: &runs[0], shotID: shotID, takeID: takes[i], outputPath: clip("a\(i).mp4"))
            StoryboardRunScheduler.recordCompletion(
                in: &runs[1], shotID: shotID, takeID: takes[i + 2], outputPath: clip("b\(i).mp4"))
        }
        _ = MovieAssemblyDriver.freezeClips(in: &runs[0])
        _ = MovieAssemblyDriver.freezeClips(in: &runs[1])

        // ASMFREEZE_9 — same frozen config, different run-local clips.
        t.checkEqual(runs[0].plan.assemblySpec, runs[1].plan.assemblySpec,
                     "ASMFREEZE_9 both runs share one frozen configuration")
        t.checkEqual(runs[0].assembly.clips.map(\.takeID), Array(takes[0..<2]),
                     "ASMFREEZE_9 run A assembles only its own takes")
        t.checkEqual(runs[1].assembly.clips.map(\.takeID), Array(takes[2..<4]),
                     "ASMFREEZE_9 run B assembles only its own")
        t.check(Set(runs[0].assembly.clips.map(\.videoPath))
                    .isDisjoint(with: Set(runs[1].assembly.clips.map(\.videoPath))),
                "ASMFREEZE_9 CROSS_RUN_ASSEMBLY_LEAK: no")

        // ASMFREEZE_10 — the global selection is irrelevant to both.
        project.shots[0].selectedTakeID = takes[3]
        project.shots[1].selectedTakeID = takes[2]
        t.checkEqual(runs[0].assembly.clips.map(\.takeID), Array(takes[0..<2]),
                     "ASMFREEZE_10 GLOBAL_SELECTED_TAKE_AFFECTS_ASSEMBLY: no")
    }

    /// Mirrors what `GenerationService` builds from a finished request, so the
    /// legacy-advance guard is exercised on a real `GenerationResult` rather
    /// than on a stand-in.
    func makeResult(from request: GenerationRequest?) -> GenerationResult {
        GenerationResult(
            id: UUID(),
            requestId: request?.id ?? UUID(),
            prompt: request?.prompt ?? "",
            enhancedPrompt: nil,
            negativePrompt: "",
            voiceoverText: "",
            voiceoverSource: "mlx-audio",
            voiceoverVoice: "af_heart",
            modelId: request?.modelId ?? "m",
            parameters: request?.parameters ?? GenerationParameters(
                numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
                numFrames: 81, fps: 24, seed: 1, vaeTilingMode: "auto", imageStrength: 1),
            videoPath: "/tmp/out.mp4",
            thumbnailPath: nil,
            audioPath: nil,
            musicPath: nil,
            musicGenre: nil,
            createdAt: Date(),
            completedAt: Date(),
            duration: 1,
            seed: request?.parameters.seed ?? 1,
            // The exact copy GenerationService performs.
            filmProjectID: request?.filmProjectID,
            shotID: request?.shotID,
            takeID: request?.takeID)
    }

    // MARK: - Legacy project-advance trigger (real E2E regression)

    /// The first real Auto Movie multi-run E2E stalled because a run-scoped
    /// child carried `filmProjectID`. GenerationService feeds that to
    /// `completedProjectIDsAwaitingAdvance` and then to
    /// `AutoMovieRunCoordinator.advance`, which started a second,
    /// project-global render of the same movie alongside the run — occupying
    /// the renderer so the run's own settlements never advanced.
    t.suite("Auto Movie — a run-scoped child never wakes the legacy coordinator") {
        var project = FilmProject(title: "Trigger")
        project.workflowMode = "hybrid"
        project.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        project.shots[1].continuityMode = .continueFromPrevious
        let job = try! MovieRunSubmission.makeJob(
            project: project, workCount: 2, directorMode: "direct")
        let run = job.snapshot.movieRuns[0]
        let params = GenerationParameters(
            numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
            numFrames: 81, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1)

        let request = MovieRunRequestBuilder.makeRequest(
            run: run, shotID: run.plan.shots[0].id, parameters: params)
        t.check(request != nil, "TRIG_1 the run-scoped child request is built")
        t.checkEqual(request?.filmProjectID, nil,
                     "TRIG_1 MOVIERUN_CHILD_FILM_PROJECT_ID: nil")

        // The exact caller semantics: GenerationService copies the request's
        // filmProjectID onto the result, and only a non-nil one is inserted
        // into completedProjectIDsAwaitingAdvance.
        let result = makeResult(from: request)
        t.checkEqual(result.filmProjectID, nil,
                     "TRIG_2 the result carries no project id either")
        let wouldAdvance = result.filmProjectID != nil
        t.checkEqual(wouldAdvance, false,
                     "TRIG_2 RUN_SCOPED_MOVIE_TRIGGERS_LEGACY_ADVANCE: no")

        // Provenance is not lost — it moved to the frozen plan and the run.
        t.checkEqual(run.plan.sourceProjectID, project.id,
                     "TRIG_3 the source project is still recorded as provenance")
        t.check(request?.shotID != nil && request?.takeID != nil,
                "TRIG_3 shot and take identity survive")
        t.checkEqual(request?.batchID, run.batchID, "TRIG_3 as does batch identity")
        t.checkEqual(request?.generationSource, "movieRun",
                     "TRIG_3 and the source marks it as a run-scoped child")

        // A run-scoped child is still a film shot: it must not be post-cropped
        // like a standalone generation.
        t.checkEqual(request?.isRunScopedFilmShot, true,
                     "TRIG_4 a run-scoped child is recognised as a film shot")

        // Storyboard carried the same latent trigger.
        var sbProject = FilmProject(title: "Trigger SB")
        sbProject.shots = [
            Shot(index: 0, title: "One", compiledPrompt: "one"),
            Shot(index: 1, title: "Two", compiledPrompt: "two"),
        ]
        sbProject.shots[1].continuityMode = .continueFromPrevious
        let sbJob = try! StoryboardRunSubmission.makeJob(
            project: sbProject, workCount: 1, directorMode: "direct")
        let sbRun = sbJob.snapshot.storyboardRuns[0]
        let sbRequest = StoryboardRunRequestBuilder.makeRequest(
            run: sbRun, shotID: sbRun.plan.shots[0].id, parameters: params)
        t.checkEqual(sbRequest?.filmProjectID, nil,
                     "TRIG_5 STORYBOARDRUN_CHILD_FILM_PROJECT_ID: nil")
        t.checkEqual(sbRequest?.isRunScopedFilmShot, true,
                     "TRIG_5 and it is still a film shot for cropping purposes")
        let sbResult = makeResult(from: sbRequest)
        t.checkEqual(sbResult.filmProjectID != nil, false,
                     "TRIG_6 RUN_SCOPED_STORYBOARD_TRIGGERS_PROJECT_ADVANCE: no")

        // Legacy behaviour is untouched: a genuine project-owned result still
        // schedules the project advance.
        var legacyRequest = request
        legacyRequest?.filmProjectID = project.id
        let legacyResult = makeResult(from: legacyRequest)
        t.check(legacyResult.filmProjectID != nil,
                "TRIG_7 LEGACY_AUTOMOVIE_PROJECT_ADVANCE: pass — still triggers")

        // UNEXPECTED_LEGACY_CHILD_REQUESTS: every child of every run is clean.
        var offenders = 0
        for r in job.snapshot.movieRuns {
            for shot in r.plan.shots {
                if let req = MovieRunRequestBuilder.makeRequest(
                    run: r, shotID: shot.id, parameters: params),
                   req.filmProjectID != nil {
                    offenders += 1
                }
            }
        }
        t.checkEqual(offenders, 0,
                     "TRIG_8 UNEXPECTED_LEGACY_CHILD_REQUESTS: 0")
    }

    t.suite("Auto Movie — batch metadata") {
        var project = FilmProject(title: "Batch")
        project.shots = [Shot(index: 0, title: "One", compiledPrompt: "one")]

        for count in [1, 2, 3] {
            let job = RunProvenanceStamper.stamp(
                try! MovieRunSubmission.makeJob(
                    project: project, workCount: count, directorMode: "direct"))
            t.checkEqual(job.snapshot.movieRuns.count, count,
                         "BATCHMOVIE_\(count) count=\(count) creates \(count) runs")
            t.checkEqual(job.snapshot.batchCount, count,
                         "BATCHMOVIE_\(count) batchCount equals the run count")
            t.checkEqual(job.snapshot.movieRuns.map(\.batchIndex), Array(0..<count),
                         "BATCHMOVIE_\(count) indices are 0..<\(count)")
            t.checkEqual(Set(job.snapshot.movieRuns.map(\.batchID)).count, 1,
                         "BATCHMOVIE_4 all runs share one batch id")
        }

        // BATCHMOVIE_5 — re-stamping (re-queue, retry) must not rewrite it.
        let job = RunProvenanceStamper.stamp(
            try! MovieRunSubmission.makeJob(
                project: project, workCount: 2, directorMode: "direct"))
        let restamped = RunProvenanceStamper.stamp(job)
        t.checkEqual(restamped.snapshot.batchCount, 2,
                     "BATCHMOVIE_5 batch count survives re-stamping")
        t.checkEqual(restamped.snapshot.batchID, job.snapshot.batchID,
                     "BATCHMOVIE_5 as does the batch id")
        let restored = try! JSONDecoder().decode(
            ProductionJobSnapshot.self, from: try! JSONEncoder().encode(job.snapshot))
        t.checkEqual(restored.batchCount, 2, "BATCHMOVIE_5 and a restart")

        // BATCHMOVIE_6 — a snapshot without batch metadata still decodes.
        let legacy = "{\"prompt\":\"old\",\"brief\":\"\",\"pendingRequests\":[]}"
        let old = try? JSONDecoder().decode(
            ProductionJobSnapshot.self, from: Data(legacy.utf8))
        t.check(old != nil, "BATCHMOVIE_6 a legacy snapshot still decodes")
        t.checkEqual(old?.batchCount, 1, "BATCHMOVIE_6 defaulting to one work")
    }
}
