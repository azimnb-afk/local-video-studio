import Foundation
@testable import LTXVideoGeneratorCore

/// Probe stub: answers per protocol from a script, and records what was asked.
final class StubLocalDirectorProber: LocalDirectorProbing {
    var outcomes: [LocalDirectorProtocol: Result<Void, Error>]
    private(set) var probed: [LocalDirectorProtocol] = []

    init(outcomes: [LocalDirectorProtocol: Result<Void, Error>]) {
        self.outcomes = outcomes
    }

    func probe(_ planProtocol: LocalDirectorProtocol, model: String) async -> Result<Void, Error> {
        probed.append(planProtocol)
        return outcomes[planProtocol] ?? .failure(DirectorError.invalidPlanJSON("no scripted outcome"))
    }
}

/// A provider whose reply depends on which protocol the Director asked for,
/// so the negotiation chain can be driven deterministically without a model.
final class ProtocolAwareMockProvider: DirectorProvider {
    let name = "ollama"
    var modelIdentifier: String? = "mock-model:latest"
    var isFallbackProvider: Bool { false }
    var jsonReply: String?
    var textReply: String?
    private(set) var jsonRequests = 0
    private(set) var textRequests = 0

    init(jsonReply: String?, textReply: String?) {
        self.jsonReply = jsonReply
        self.textReply = textReply
    }

    func isAvailable() async -> Bool { true }
    func terminate() async {}

    func complete(system: String, prompt: String) async throws -> String {
        try await complete(system: system, prompt: prompt, expectsJSON: true)
    }

    func complete(system: String, prompt: String, expectsJSON: Bool) async throws -> String {
        if expectsJSON {
            jsonRequests += 1
            guard let jsonReply else { throw DirectorError.noResponse("no json reply") }
            return jsonReply
        } else {
            textRequests += 1
            guard let textReply else { throw DirectorError.noResponse("no text reply") }
            return textReply
        }
    }
}

private let validPlanJSON = """
{"logline":"A woman walks.","shots":[{"title":"Shot 1","summary":"She walks down a hallway."}]}
"""

private let validTextPlan = """
LOGLINE: A woman walks down a hallway.
SHOT 1
ACTION: She walks steadily down a dim hallway.
CAMERA: Medium shot, slow tracking.
CONTINUITY: CUT
SHOT 2
ACTION: She stops and turns toward a sound.
CAMERA: Close-up, static.
CONTINUITY: CONTINUE
"""

func runLocalDirectorCompatibilityTests(_ t: TestKit) {

    // MARK: Text Protocol parser

    t.suite("Text Protocol parser") {
        let parsed = TextProtocolPlanParser.parse(validTextPlan, brief: "b")
        guard let draft = parsed.draft else {
            t.check(false, "valid protocol text failed to parse: \(parsed.message)")
            return
        }
        t.checkEqual(draft.shots.count, 2, "both shots parsed")
        t.checkEqual(draft.logline, "A woman walks down a hallway.", "logline parsed")
        t.checkEqual(draft.shots[0].summary, "She walks steadily down a dim hallway.", "ACTION becomes the shot summary")
        t.checkEqual(draft.shots[0].continuity, "cut", "CUT parsed")
        t.checkEqual(draft.shots[1].continuity, "continue", "CONTINUE parsed")
        t.checkEqual(draft.shots[0].shotScale, "medium", "a named scale is lifted out of the camera line")
        t.checkEqual(draft.shots[1].shotScale, "close-up", "close-up scale detected")
        t.check(StoryboardDirector.validate(draft).isEmpty, "parsed draft passes the production validator")

        // CRLF and casing
        let crlf = validTextPlan.replacingOccurrences(of: "\n", with: "\r\n")
            .replacingOccurrences(of: "CONTINUITY: CUT", with: "continuity: Cut")
        let crlfDraft = TextProtocolPlanParser.parse(crlf, brief: "b").draft
        t.checkEqual(crlfDraft?.shots.count, 2, "CRLF line endings parse")
        t.checkEqual(crlfDraft?.shots[0].continuity, "cut", "lowercase key and mixed-case CUT normalize")

        // Decorated markers some models emit
        let decorated = """
        **LOGLINE:** A test.
        **SHOT 1**
        - ACTION: Something happens.
        - CAMERA: Wide shot.
        - CONTINUITY: CUT
        """
        t.checkEqual(TextProtocolPlanParser.parse(decorated, brief: "b").draft?.shots.count, 1,
                     "markdown bullet/bold decoration is tolerated")

        // Reasoning and a blank template echo before the real answer
        let withEcho = """
        <think>
        LOGLINE: <one sentence>
        SHOT 1
        ACTION: <what happens>
        CONTINUITY: CUT
        </think>
        \(validTextPlan)
        """
        let echoDraft = TextProtocolPlanParser.parse(withEcho, brief: "b").draft
        t.checkEqual(echoDraft?.shots.count, 2, "a reasoning block containing a blank template does not become the plan")
        t.checkEqual(echoDraft?.shots[0].summary, "She walks steadily down a dim hallway.",
                     "the real filled-in answer is the one parsed")

        // Rejections
        t.check(TextProtocolPlanParser.parse("", brief: "b").draft == nil, "empty response rejected")
        t.check(TextProtocolPlanParser.parse("Sure! Here is a lovely story about a hallway.", brief: "b").draft == nil,
                "free prose is rejected rather than guessed at")
        t.check(TextProtocolPlanParser.parse("LOGLINE: x\nSHOT 1\nCAMERA: Wide.\n", brief: "b").draft == nil,
                "a shot with no ACTION is rejected")
        t.check(TextProtocolPlanParser.parse("LOGLINE: x\n", brief: "b").draft == nil,
                "zero shots rejected")
        t.check(TextProtocolPlanParser.parse("LOGLINE: <one sentence>\nSHOT 1\nACTION: <what happens>\n", brief: "b").draft == nil,
                "an unfilled template is rejected, not turned into a plan")

        // A missing logline falls back to the brief, matching the Structured
        // path's semantic repair rather than inventing one.
        let noLogline = "SHOT 1\nACTION: She walks.\nCONTINUITY: CUT"
        t.checkEqual(TextProtocolPlanParser.parse(noLogline, brief: "A woman walks.").draft?.logline,
                     "A woman walks.", "missing logline falls back to the brief")

        // Bounded by the same validator the Structured path uses.
        var many = "LOGLINE: x\n"
        for i in 1...15 { many += "SHOT \(i)\nACTION: Beat \(i).\nCONTINUITY: CUT\n" }
        if let bigDraft = TextProtocolPlanParser.parse(many, brief: "b").draft {
            t.check(!StoryboardDirector.validate(bigDraft).isEmpty,
                    "an over-long plan is caught by the existing validator, not by a second rule here")
        } else {
            t.check(true, "over-long plan rejected during parsing")
        }
    }

    // MARK: Capability negotiation

    t.suite("Local Director capability negotiation") {
        func service(_ outcomes: [LocalDirectorProtocol: Result<Void, Error>],
                     suite: String = UUID().uuidString) -> (LocalDirectorCompatibilityService, StubLocalDirectorProber, UserDefaults) {
            let defaults = UserDefaults(suiteName: "negotiation-\(suite)")!
            let prober = StubLocalDirectorProber(outcomes: outcomes)
            return (LocalDirectorCompatibilityService(userDefaults: defaults, prober: prober), prober, defaults)
        }

        // 1. Structured works -> structured chosen, and Text is never probed.
        var done1 = false
        Task {
            let (svc, prober, _) = service([.structuredJSON: .success(())])
            let capability = await svc.negotiate(model: "m:1")
            t.checkEqual(capability, .ready(.structuredJSON), "a structured-capable model selects Structured JSON")
            t.checkEqual(prober.probed, [.structuredJSON], "Text is not probed once Structured succeeds")
            t.checkEqual(svc.validProfile(for: "m:1")?.selectedProtocol, .structuredJSON, "verdict is cached")
            done1 = true
        }
        while !done1 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }

        // 2/3. Structured fails (empty object, then malformed) -> Text chosen.
        for (label, failure) in [("empty JSON object", "required field 'shots' missing at <root>"),
                                 ("malformed JSON", "JSON syntax invalid")] {
            var done = false
            Task {
                let (svc, prober, _) = service([
                    .structuredJSON: .failure(DirectorError.invalidPlanJSON(failure)),
                    .textProtocol: .success(()),
                ])
                let capability = await svc.negotiate(model: "m:2")
                t.checkEqual(capability, .ready(.textProtocol), "\(label): falls through to Text Protocol")
                t.checkEqual(prober.probed, [.structuredJSON, .textProtocol], "\(label): richest protocol tried first")
                t.checkEqual(svc.validProfile(for: "m:2")?.selectedProtocol, .textProtocol, "\(label): Text cached")
                done = true
            }
            while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        }

        // 4. Both fail -> incompatible, and the failure summary is cached.
        var done4 = false
        Task {
            let (svc, _, _) = service([
                .structuredJSON: .failure(DirectorError.invalidPlanJSON("no shots")),
                .textProtocol: .failure(DirectorError.invalidPlanJSON("no LOGLINE marker")),
            ])
            let capability = await svc.negotiate(model: "m:3")
            if case .incompatible(let summary) = capability {
                t.check(summary.contains("Structured JSON") && summary.contains("Text Protocol"),
                        "both protocol failures are summarised")
            } else {
                t.check(false, "expected incompatible, got \(capability)")
            }
            t.checkEqual(svc.validProfile(for: "m:3")?.selectedProtocol, nil, "no protocol is cached as usable")
            t.check(svc.validProfile(for: "m:3")?.isCompatible == false, "profile records incompatibility")
            done4 = true
        }
        while !done4 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }

        // 5. Transport failure -> unavailable, and nothing is cached, because
        //    an unreachable server says nothing about the model's ability.
        var done5 = false
        Task {
            let (svc, prober, _) = service([
                .structuredJSON: .failure(DirectorError.providerFailed("Local AI is not reachable")),
            ])
            let capability = await svc.negotiate(model: "m:4")
            if case .unavailable = capability {
                t.check(true, "transport failure reports unavailable, not incompatible")
            } else {
                t.check(false, "expected unavailable, got \(capability)")
            }
            t.checkEqual(prober.probed, [.structuredJSON], "no further protocols are tried when the server is down")
            t.check(svc.loadProfile() == nil, "an unreachable server does not write a capability verdict")
            done5 = true
        }
        while !done5 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    }

    // MARK: Profile cache identity

    t.suite("Local Director compatibility cache") {
        let defaults = UserDefaults(suiteName: "compat-cache-\(UUID().uuidString)")!
        let svc = LocalDirectorCompatibilityService(
            userDefaults: defaults,
            prober: StubLocalDirectorProber(outcomes: [:]),
            providerKind: "ollama",
            endpoint: "http://127.0.0.1:11434")
        svc.recordSuccessfulProtocol(.textProtocol, model: "model-a:latest")

        t.checkEqual(svc.validProfile(for: "model-a:latest")?.selectedProtocol, .textProtocol,
                     "same endpoint + model + probe version reuses the cached protocol")
        t.check(svc.validProfile(for: "model-b:latest") == nil,
                "a different model does not inherit another model's verdict")
        t.checkEqual(svc.startingProtocol(for: "model-a:latest"), .textProtocol,
                     "production starts from the cached protocol")
        t.checkEqual(svc.startingProtocol(for: "model-b:latest"), .structuredJSON,
                     "an untested model starts from the richest protocol")

        // Endpoint identity
        let otherEndpoint = LocalDirectorCompatibilityService(
            userDefaults: defaults,
            prober: StubLocalDirectorProber(outcomes: [:]),
            providerKind: "ollama",
            endpoint: "http://192.168.0.5:11434")
        t.check(otherEndpoint.validProfile(for: "model-a:latest") == nil,
                "the same model name at a different endpoint is a different profile")

        // Probe version
        var stale = svc.loadProfile()!
        stale.probeVersion = LocalDirectorCompatibilityProfile.currentProbeVersion - 1
        svc.save(stale)
        t.check(svc.validProfile(for: "model-a:latest") == nil,
                "a verdict from an older probe version is not trusted")
    }

    // MARK: Production negotiation, downgrade and provenance

    t.suite("Local Director production protocol selection") {
        func director(json: String?, text: String?, defaultsSuite: String = UUID().uuidString)
        -> (StoryboardDirector, ProtocolAwareMockProvider, LocalDirectorCompatibilityService) {
            let provider = ProtocolAwareMockProvider(jsonReply: json, textReply: text)
            let defaults = UserDefaults(suiteName: "prod-\(defaultsSuite)")!
            let compat = LocalDirectorCompatibilityService(
                userDefaults: defaults, prober: StubLocalDirectorProber(outcomes: [:]))
            let sd = StoryboardDirector(providers: [provider, TemplateStoryboardProvider()],
                                        requestedMode: .localAI, compatibility: compat)
            return (sd, provider, compat)
        }

        // Structured-capable model: unchanged behaviour, Text never requested.
        var doneA = false
        Task {
            let (sd, provider, compat) = director(json: validPlanJSON, text: validTextPlan)
            do {
                let (draft, name) = try await sd.draft(brief: "walk")
                t.checkEqual(name, "ollama", "local provider planned it")
                t.checkEqual(sd.lastPlanningMode, "ai", "planningMode is ai")
                t.checkEqual(sd.lastProtocol, .structuredJSON, "Structured JSON was used")
                t.check(sd.lastFallbackReason == nil, "no fallback reason on success")
                t.checkEqual(draft.shots.count, 1, "structured draft used")
                t.checkEqual(provider.textRequests, 0, "no Text request is made when Structured works")
                t.checkEqual(compat.validProfile(for: "mock-model:latest")?.selectedProtocol, .structuredJSON,
                             "success records the protocol for next time")
            } catch { t.check(false, "structured production path threw \(error)") }
            doneA = true
        }
        while !doneA { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }

        // Runtime downgrade: Structured unusable, Text works -> Text result,
        // profile updated so the next run starts on Text.
        var doneB = false
        Task {
            let (sd, provider, compat) = director(json: "{}", text: validTextPlan)
            do {
                let (draft, name) = try await sd.draft(brief: "walk")
                t.checkEqual(name, "ollama", "local provider still planned it after downgrade")
                t.checkEqual(sd.lastPlanningMode, "ai", "a downgraded run is still an AI plan, not a fallback")
                t.checkEqual(sd.lastProtocol, .textProtocol, "Text Protocol produced the plan")
                t.checkEqual(draft.shots.count, 2, "text draft used")
                t.check(provider.jsonRequests > 0 && provider.textRequests > 0, "both protocols were attempted once")
                t.checkEqual(compat.validProfile(for: "mock-model:latest")?.selectedProtocol, .textProtocol,
                             "the downgrade is remembered so the next run starts on Text")
            } catch { t.check(false, "downgrade path threw \(error)") }
            doneB = true
        }
        while !doneB { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }

        // Cached Text: production starts there and never asks for JSON.
        var doneC = false
        Task {
            let suite = UUID().uuidString
            let (sd, provider, compat) = director(json: "{}", text: validTextPlan, defaultsSuite: suite)
            compat.recordSuccessfulProtocol(.textProtocol, model: "mock-model:latest")
            do {
                _ = try await sd.draft(brief: "walk")
                t.checkEqual(sd.lastProtocol, .textProtocol, "cached protocol is used")
                t.checkEqual(provider.jsonRequests, 0, "a cached Text verdict skips the Structured attempt entirely")
            } catch { t.check(false, "cached-protocol path threw \(error)") }
            doneC = true
        }
        while !doneC { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }

        // Both protocols unusable -> Basic fallback, existing semantics intact.
        var doneD = false
        Task {
            let (sd, _, _) = director(json: "{}", text: "just some prose, no markers at all")
            do {
                let (_, name) = try await sd.draft(brief: "walk")
                t.checkEqual(name, "template", "Basic Director remains the final safety net")
                t.checkEqual(sd.lastPlanningMode, "fallback", "planningMode is fallback")
                t.check(sd.lastProtocol == nil, "no local protocol is claimed when none worked")
                t.check(sd.lastFallbackReason != nil, "a fallback reason is recorded")
            } catch { t.check(false, "both-fail path threw \(error)") }
            doneD = true
        }
        while !doneD { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    }

    // MARK: Provenance persistence

    t.suite("Local Director protocol provenance") {
        // Projects written before protocol provenance existed still decode.
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"Legacy","planningMode":"ai","directorProvider":"ollama"}
        """.data(using: .utf8)!
        do {
            let project = try JSONDecoder().decode(FilmProject.self, from: legacy)
            t.checkEqual(project.planningMode, "ai", "legacy planningMode preserved")
            t.check(project.directorProtocol == nil, "a project planned before protocols decodes with none")
        } catch {
            t.check(false, "legacy project failed to decode: \(error)")
        }

        var project = FilmProject(title: "P")
        project.directorProtocol = LocalDirectorProtocol.textProtocol.rawValue
        do {
            let round = try JSONDecoder().decode(FilmProject.self, from: JSONEncoder().encode(project))
            t.checkEqual(round.directorProtocol, "textProtocol", "protocol provenance round-trips")
        } catch {
            t.check(false, "provenance round-trip failed: \(error)")
        }
    }

    // MARK: Request shaping

    t.suite("Local Director request shaping") {
        // The Structured protocol wants JSON-constrained decoding; the Text
        // protocol must not be constrained to JSON or it can never answer in
        // its own format. This was a real defect found on a live model.
        t.checkEqual(DirectorPlanFormat.userPrompt(for: .structuredJSON, brief: "b"), "BRIEF: b",
                     "structured keeps the original minimal user prompt")
        let textPrompt = DirectorPlanFormat.userPrompt(for: .textProtocol, brief: "b")
        t.check(textPrompt.contains("LOGLINE:") && textPrompt.contains("SHOT 1"),
                "the text template travels in the user turn, where models follow it")
        t.check(textPrompt.contains("BRIEF: b"), "the brief is included")

        let structuredDuration = DirectorPlanFormat.userPrompt(
            for: .structuredJSON, brief: "b", targetDurationSeconds: 10)
        let textDuration = DirectorPlanFormat.userPrompt(
            for: .textProtocol, brief: "b", targetDurationSeconds: 10)
        for prompt in [structuredDuration, textDuration] {
            t.check(prompt.contains("approximately 10.0 seconds total"),
                    "Structured and Text protocols receive the same total-duration value")
            t.check(prompt.contains("sum across all shots"),
                    "duration intent is explicitly complete-movie, not per-shot")
        }
        let repairDuration = DirectorPlanFormat.repairPrompt(
            for: .textProtocol, failure: "bad format", brief: "b",
            targetDurationSeconds: 10)
        t.check(repairDuration.contains("approximately 10.0 seconds total"),
                "bounded repair retains the total-duration contract")

        var doneE = false
        Task {
            let provider = ProtocolAwareMockProvider(jsonReply: validPlanJSON, textReply: validTextPlan)
            _ = try? await provider.complete(system: "s", prompt: "p", expectsJSON: false)
            t.checkEqual(provider.textRequests, 1, "expectsJSON:false routes to the plain-text path")
            _ = try? await provider.complete(system: "s", prompt: "p")
            t.checkEqual(provider.jsonRequests, 1, "the legacy two-argument call still means JSON")
            doneE = true
        }
        while !doneE { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    }
}
