import Foundation
@testable import LTXVideoGeneratorCore

func runMotionTempoContinuityTests(_ t: TestKit) {
    t.suite("Motion tempo model and migration") {
        var shot = Shot(index: 0, title: "Paced")
        shot.motionTempo = .fast
        shot.cameraTempo = .slow
        shot.playbackStyle = .slowMotion
        do {
            let data = try JSONEncoder().encode(shot)
            let decoded = try JSONDecoder().decode(Shot.self, from: data)
            t.checkEqual(decoded.motionTempo, .fast, "motion tempo persists")
            t.checkEqual(decoded.cameraTempo, .slow, "camera tempo persists")
            t.checkEqual(decoded.playbackStyle, .slowMotion, "playback style persists")

            var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            legacy.removeValue(forKey: "motionTempo")
            legacy.removeValue(forKey: "cameraTempo")
            legacy.removeValue(forKey: "playbackStyle")
            let migrated = try JSONDecoder().decode(
                Shot.self, from: JSONSerialization.data(withJSONObject: legacy))
            t.checkEqual(migrated.motionTempo, .normal, "legacy Shot defaults motion tempo safely")
            t.checkEqual(migrated.cameraTempo, .normal, "legacy Shot defaults camera tempo safely")
            t.checkEqual(migrated.playbackStyle, .realTime, "legacy Shot defaults to real-time playback")
        } catch {
            t.check(false, "motion tempo persistence threw \(error)")
        }
    }

    t.suite("Director motion tempo protocol parity") {
        let structured = StoryboardDirector.parseDraftDetailed(from: """
        {"logline":"A runner moves.","shots":[
          {"title":"Run","summary":"She runs.","motionTempo":"fast","cameraTempo":"slow","playbackStyle":"realTime"}
        ]}
        """, brief: "A runner moves.").draft
        t.checkEqual(structured?.shots.first?.motionTempo, "fast", "Structured JSON carries motion tempo")
        t.checkEqual(structured?.shots.first?.cameraTempo, "slow", "Structured JSON carries camera tempo")
        t.checkEqual(structured?.shots.first?.playbackStyle, "realTime", "Structured JSON carries playback style")

        let text = TextProtocolPlanParser.parse("""
        LOGLINE: A runner moves.
        SHOT 1
        ACTION: She runs.
        CAMERA: Medium tracking shot.
        MOTION_TEMPO: FAST
        CAMERA_TEMPO: SLOW
        PLAYBACK_STYLE: REAL_TIME
        CONTINUITY: CUT
        """, brief: "A runner moves.").draft
        t.checkEqual(text?.shots.first?.motionTempo, "fast", "Text Protocol normalizes motion tempo")
        t.checkEqual(text?.shots.first?.cameraTempo, "slow", "Text Protocol normalizes camera tempo")
        t.checkEqual(text?.shots.first?.playbackStyle, "realTime", "Text Protocol normalizes playback style")

        let repaired = StoryboardDirector.parseDraftDetailed(from: """
        {"storyline":"A repaired plan.","scenes":[
          {"action":"She sprints.","motion_tempo":"fast","camera_tempo":"fast","playback_style":"slowMotion"}
        ]}
        """, brief: "A repaired plan.").draft
        t.checkEqual(repaired?.shots.first?.motionTempo, "fast",
                     "deterministic schema repair preserves motion tempo")
        t.checkEqual(repaired?.shots.first?.cameraTempo, "fast",
                     "deterministic schema repair preserves camera tempo")
        t.checkEqual(repaired?.shots.first?.playbackStyle, "slowMotion",
                     "deterministic schema repair preserves playback style")

        let structuredPrompt = DirectorPlanFormat.systemPrompt(
            for: .structuredJSON, characterBible: CharacterBible())
        let textPrompt = DirectorPlanFormat.userPrompt(
            for: .textProtocol, brief: "A runner moves.")
        let repairPrompt = DirectorPlanFormat.repairPrompt(
            for: .textProtocol, failure: "missing tempo", brief: "A runner moves.")
        for (label, prompt) in [
            ("Structured", structuredPrompt),
            ("Text", textPrompt),
            ("Repair", repairPrompt),
        ] {
            t.check(prompt.contains("MOTION_TEMPO") || prompt.contains("motionTempo"),
                    "\(label) path requests motion tempo")
            t.check(prompt.contains("PLAYBACK_STYLE") || prompt.contains("playbackStyle"),
                    "\(label) path requests playback style")
        }
    }

    t.suite("Motion tempo continuity policy") {
        let previous = MotionTempoProfile(
            motionTempo: .slow, cameraTempo: .fast, playbackStyle: .slowMotion)
        let continued = MotionTempoPlanningPolicy.resolve(
            draft: .init(title: "Continue", summary: "She reaches the door."),
            brief: "She reaches the door.", previous: previous, isContinuation: true)
        t.checkEqual(continued, previous, "CONTINUE inherits all absent tempo fields")

        let cut = MotionTempoPlanningPolicy.resolve(
            draft: .init(title: "Cut", summary: "She enters another room."),
            brief: "She enters another room.", previous: previous, isContinuation: false)
        t.checkEqual(cut, MotionTempoPlanningPolicy.defaultProfile,
                     "CUT does not randomly inherit slow-motion playback")

        let explicit = MotionTempoPlanningPolicy.resolve(
            draft: .init(title: "Explicit", summary: "She turns in slow motion."),
            brief: "Show the turn in slow motion.", previous: nil, isContinuation: false)
        t.checkEqual(explicit.playbackStyle, .slowMotion, "explicit slow-motion direction wins")

        let ordinarySlowAction = MotionTempoPlanningPolicy.resolve(
            draft: .init(title: "Door", summary: "She slowly opens the door."),
            brief: "She slowly opens the door.", previous: nil, isContinuation: false)
        t.checkEqual(ordinarySlowAction.playbackStyle, .realTime,
                     "slowly opening a door remains real-time action")

        let override = MotionTempoPlanningPolicy.resolve(
            draft: .init(title: "Change", summary: "She runs.", motionTempo: "fast",
                         cameraTempo: "static", playbackStyle: "realTime"),
            brief: "She runs.", previous: previous, isContinuation: true)
        t.checkEqual(override.motionTempo, .fast, "Director can explicitly change continued subject tempo")
        t.checkEqual(override.cameraTempo, .static, "Director can explicitly change continued camera tempo")
        t.checkEqual(override.playbackStyle, .realTime, "Director can explicitly restore real-time playback")
    }

    t.suite("Motion tempo prompt compilation") {
        let instruction = MotionTempoPromptPolicy.instruction(
            motionTempo: .normal, cameraTempo: .slow, playbackStyle: .realTime)
        t.check(instruction.contains("real-time playback"), "compiled tempo distinguishes playback style")
        t.check(instruction.contains("natural subject movement"), "compiled tempo carries subject pace")
        t.check(instruction.contains("slow, measured camera movement"), "compiled tempo carries camera pace")
        t.check(instruction.count < 180, "compiled tempo guidance stays concise")

        let prompt = PromptCompiler.compile(
            plan: OneShotPlan(camera: "medium tracking shot", action: "She runs.", motion: instruction),
            options: .init(perShotAudioPolicy: .naturalProductionSoundNoMusic))
        t.check(prompt.lowercased().contains("no background music"),
                "motion tempo compilation preserves the no-BGM policy")
    }

    t.suite("Basic Director motion tempo integration") {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let director = StoryboardDirector(
                    providers: [TemplateStoryboardProvider()], requestedMode: .basic)
                let result = try await director.makeProject(
                    title: "Basic Tempo",
                    brief: "First shot: She walks to a door. Next shot: She opens it.")
                t.check(result.project.shots.allSatisfy { $0.motionTempo == .normal },
                        "Basic Director uses safe normal subject tempo")
                t.check(result.project.shots.allSatisfy { $0.cameraTempo == .normal },
                        "Basic Director uses safe normal camera tempo")
                t.check(result.project.shots.allSatisfy { $0.playbackStyle == .realTime },
                        "Basic Director uses real-time playback")
                t.check(result.project.shots.allSatisfy {
                    $0.compiledPrompt.contains("real-time playback")
                        && $0.compiledPrompt.lowercased().contains("no background music")
                }, "Basic compiled prompts carry tempo and existing audio policy")
            } catch {
                t.check(false, "Basic motion tempo integration threw \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()

        let durationPrompt = DirectorPlanFormat.userPrompt(
            for: .structuredJSON, brief: "A short scene.", targetDurationSeconds: 15)
        t.check(durationPrompt.contains("15.0 seconds total"),
                "Target Duration instruction remains intact")
        var opening = OpeningReferenceAppearance()
        opening.sceneEnvironment = "seaside ruin"
        opening.sceneLighting = "sunset"
        let openingPrompt = DirectorPlanFormat.userPrompt(
            for: .structuredJSON, brief: "She explores.", openingSceneEvidence: opening)
        t.check(openingPrompt.contains("CURRENT OPENING SCENE EVIDENCE")
                && openingPrompt.contains("seaside ruin"),
                "Opening Grounding evidence remains intact")
    }
}
