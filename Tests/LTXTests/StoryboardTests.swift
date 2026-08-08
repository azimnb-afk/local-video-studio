import Foundation
@testable import LTXVideoGeneratorCore

func runStoryboardTests(_ t: TestKit) {

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
                t.checkEqual(project.storyBible.logline, "A courier races the rain.", "story bible populated")
                t.check(project.characterBible.character(named: "Kei") != nil, "character bible seeded")
                t.checkEqual(project.shots[0].continuityBefore?.location, "street", "shot 1 sees initial state")
                t.checkEqual(project.shots[1].continuityBefore?.weather, "rain", "shot 2 sees shot 1's changes")
                t.checkEqual(project.shots[1].continuityBefore?.wetness["Kei"], "rain-soaked", "wetness propagated")
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

        // Hybrid composes the same director and deterministically expands the
        // template fallback into reviewable 4–6 second shots.
        let hybridDirector = StoryboardDirector(providers: [TemplateStoryboardProvider()])
        let hybrid = HybridProjectCoordinator(director: hybridDirector)
        let sem3 = DispatchSemaphore(value: 0)
        Task {
            do {
                var settings = ProjectSettings()
                settings.applyPreset(.quickPreview)
                settings.targetDurationSeconds = 20
                let (project, _, _) = try await hybrid.makeProject(title: "Hybrid", brief: "a train crosses a valley", settings: settings)
                t.checkEqual(project.workflowMode, "hybrid", "Hybrid workflow state recorded")
                t.checkEqual(project.shots.count, 4, "Hybrid target duration split into short shots")
                t.check(project.shots.allSatisfy { (4...6).contains($0.durationSeconds) }, "Hybrid shots are 4–6 seconds")
                t.checkEqual(Set(project.shots.map(\.id)).count, project.shots.count, "Hybrid shot IDs unique")
                t.check(project.shots.allSatisfy { !$0.compiledPrompt.isEmpty }, "Hybrid prompts compiled")
                t.checkEqual(project.settings.resolvedPreset, .quickPreview, "Hybrid uses shared preset settings")
            } catch { t.check(false, "Hybrid orchestration threw \(error)") }
            sem3.signal()
        }
        sem3.wait()

        // Validation catches bad drafts.
        t.check(!StoryboardDirector.validate(StoryboardDirector.StoryboardDraft(
            logline: "", synopsis: nil, setting: nil, tone: nil, initialState: nil, shots: []
        )).isEmpty, "empty draft rejected")
    }

    t.suite("Final assembly") {
        // Build a project whose selected takes point at real baseline MP4s.
        let a = "/tmp/ltx_baseline/T2V-A-ON.mp4"    // h264+aac
        let b = "/tmp/ltx_baseline/I2V-A-ON.mp4"    // h264+aac same profile
        let c = "/tmp/ltx_baseline/T2V-A-OFF.mp4"   // h264, NO audio
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
