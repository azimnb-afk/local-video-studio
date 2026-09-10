import Foundation
@testable import LTXVideoGeneratorCore

/// Deterministic coverage for Phase B/F/G: user-explicit meaning must survive
/// enhancement, and an enhancement that loses it must be rejected rather than
/// warned about.
///
/// Each matrix case asserts three things, which together prove the gate is real
/// rather than vacuous:
///   1. the constraint is actually extracted from the original,
///   2. a faithful candidate is ACCEPTED (no false rejection),
///   3. a lossy candidate is REJECTED (the defect is caught).
/// A gate that only did (3) could be satisfied by rejecting everything.

private func preservationInput(_ prompt: String) -> H3EnhancementInput {
    H3EnhancementInput(originalPrompt: prompt)
}

private func evaluate(_ original: String, _ candidate: String) -> H3EnhancementValidator.Report {
    H3EnhancementValidator.validate(
        draft: H3EnhancementDraft(visualDescription: candidate),
        unexpectedKeys: [],
        input: preservationInput(original))
}

/// One row of the semantic matrix.
private struct MatrixCase {
    let id: String
    let original: String
    /// Preserves the protected meaning — must be accepted.
    let faithful: String
    /// Drops the protected meaning — must be rejected.
    let lossy: String
    /// Category expected to be extracted from `original`.
    let category: H3SemanticCategory
}

private let matrix: [MatrixCase] = [
    // ---- English ----
    .init(id: "E01", original: "slowly raises one hand",
          faithful: "A person slowly raises one hand.",
          lossy: "A person raises one hand.", category: .speed),
    .init(id: "E02", original: "immediately turns around",
          faithful: "A person immediately turns around.",
          lossy: "A person turns around.", category: .speed),
    .init(id: "E03", original: "gradually lowers both arms",
          faithful: "A person gradually lowers both arms.",
          lossy: "A person lowers both arms.", category: .speed),
    .init(id: "E04", original: "takes exactly two steps",
          faithful: "A person takes exactly two steps.",
          lossy: "A person takes a few steps.", category: .quantity),
    .init(id: "E05", original: "turns to the left",
          faithful: "A person turns to the left.",
          lossy: "A person turns.", category: .direction),
    .init(id: "E06", original: "looks right, then looks forward",
          faithful: "A person looks right, then looks forward.",
          lossy: "A person looks right while looking forward.", category: .order),
    .init(id: "E07", original: "does not smile",
          faithful: "A person does not smile.",
          lossy: "A person smiles warmly.", category: .negation),
    .init(id: "E08", original: "keeps looking toward the camera",
          faithful: "A person keeps looking toward the camera.",
          lossy: "A person looks into the distance.", category: .camera),
    .init(id: "E09", original: "raises the hand without stopping",
          faithful: "A person raises the hand without stopping.",
          lossy: "A person raises the hand.", category: .speed),
    .init(id: "E10", original: "walks backward three steps",
          faithful: "A person walks backward three steps.",
          lossy: "A person walks backward.", category: .quantity),

    // ---- Japanese (must preserve through translation) ----
    .init(id: "J11", original: "ゆっくり右手を上げる",
          faithful: "A person slowly raises their right hand.",
          lossy: "A person raises their right hand.", category: .speed),
    .init(id: "J12", original: "すぐに振り向く",
          faithful: "A person immediately turns around.",
          lossy: "A person turns around.", category: .speed),
    .init(id: "J13", original: "徐々に両腕を下げる",
          faithful: "A person gradually lowers both arms.",
          lossy: "A person lowers both arms.", category: .speed),
    .init(id: "J14", original: "左へ二歩進む",
          faithful: "A person takes two steps to the left.",
          lossy: "A person steps to the left.", category: .quantity),
    .init(id: "J15", original: "右を見てから正面を見る",
          faithful: "A person looks right, then looks forward.",
          lossy: "A person looks right and forward at the same time.", category: .order),
    .init(id: "J16", original: "笑わない",
          faithful: "A person does not smile.",
          lossy: "A person smiles.", category: .negation),
    .init(id: "J17", original: "カメラを見続ける",
          faithful: "A person keeps looking at the camera.",
          lossy: "A person keeps looking ahead.", category: .camera),
    .init(id: "J18", original: "止まらずに歩く",
          faithful: "A person walks without stopping.",
          lossy: "A person walks.", category: .speed),
    .init(id: "J19", original: "後ろへ三歩下がる",
          faithful: "A person steps three steps backward.",
          lossy: "A person steps backward.", category: .quantity),
    .init(id: "J20", original: "ゆっくり立ち上がってから前を見る",
          faithful: "A person slowly stands up, then looks forward.",
          lossy: "A person stands up and looks forward.", category: .speed),
]

func runH3SemanticPreservationTests(_ t: TestKit) {

    // Phase F — the exact reported regression.
    t.suite("Semantic preservation — C08 regression (slowly)") {
        let original = "the person in the image slowly raises one hand"

        let extracted = H3SemanticConstraintExtractor.constraints(in: original)
        t.check(extracted.contains { $0.category == .speed },
                "speed constraint extracted from the original")

        // The exact previously-accepted output must now be rejected.
        let previouslyAccepted = evaluate(original, "A person raises one hand.")
        t.check(!previouslyAccepted.isAcceptable,
                "the previously-accepted lossy output is now REJECTED")
        t.check(previouslyAccepted.rejections.contains { $0.contains("speed lost") },
                "rejection names the lost pacing")
        t.check(previouslyAccepted.preservation.missing.contains { $0.category == .speed },
                "preservation report records the missing speed constraint")

        // A candidate that keeps the pacing is still accepted.
        let preserved = evaluate(original, "A person slowly raises one hand.")
        t.check(preserved.isAcceptable, "candidate retaining \"slowly\" is accepted")

        // An equivalent wording counts — the gate is not surface-string matching.
        for equivalent in ["A person raises one hand at a slow pace.",
                           "A person raises one hand in a slow, unhurried motion.",
                           "A person gradually raises one hand."] {
            t.check(evaluate(original, equivalent).isAcceptable,
                    "equivalent slow wording accepted: \(equivalent)")
        }
    }

    // Phase F — end to end through the enhancer, with a real rejection + fallback.
    t.suite("Semantic preservation — C08 through the enhancer falls back safely") {
        let original = "the person in the image slowly raises one hand"
        let dropping = ScriptedPreservationProvider(replies: [
            #"{"visualDescription":"A person raises one hand."}"#,
            #"{"visualDescription":"A person raises one hand."}"#,
        ])
        let enhancer = H3PromptEnhancer(
            provider: dropping,
            heavyTaskGuard: AlwaysOpenGuard(),
            residencyInspector: nil,
            timeoutSeconds: 5)

        runPreservationAsync {
            let result = await enhancer.enhance(input: preservationInput(original))
            t.check(!result.status.isSuccess, "enhancement rejected rather than accepted")
            t.checkEqual(result.effectivePrompt, original,
                         "falls back to the untouched original prompt")
            t.check(result.candidate == nil, "no lossy candidate is exposed")
            t.check(result.lostConstraints.contains { $0.hasPrefix("speed") },
                    "lost constraint is reported by category")
            t.check(result.repairPerformed, "one bounded repair was attempted first")
            // The model was told what to preserve before being judged on it.
            t.check(dropping.prompts.first?.contains("MUST PRESERVE") == true,
                    "MUST PRESERVE list is sent up front")
            t.check(dropping.prompts.first?.contains("slowly") == true,
                    "the specific constraint is named in the prompt")
        }

        // A model that complies on the repair attempt succeeds.
        let recovering = ScriptedPreservationProvider(replies: [
            #"{"visualDescription":"A person raises one hand."}"#,
            #"{"visualDescription":"A person slowly raises one hand."}"#,
        ])
        runPreservationAsync {
            let result = await H3PromptEnhancer(
                provider: recovering, heavyTaskGuard: AlwaysOpenGuard(),
                residencyInspector: nil, timeoutSeconds: 5
            ).enhance(input: preservationInput(original))
            t.check(result.status.isSuccess, "repaired candidate accepted")
            t.check(result.compiledPrompt?.lowercased().contains("slowly") == true,
                    "pacing survives into the compiled prompt")
            t.check(result.lostConstraints.isEmpty, "no constraints reported lost")
        }
    }

    // Phase G — the full 20-case matrix.
    t.suite("Semantic preservation — 20-case matrix") {
        for testCase in matrix {
            let extracted = H3SemanticConstraintExtractor.constraints(in: testCase.original)
            t.check(extracted.contains { $0.category == testCase.category },
                    "\(testCase.id) extracts \(testCase.category.rawValue) from \"\(testCase.original)\"")

            let faithful = evaluate(testCase.original, testCase.faithful)
            t.check(faithful.isAcceptable,
                    "\(testCase.id) faithful candidate accepted"
                        + (faithful.isAcceptable ? "" : " — \(faithful.rejections.joined(separator: "; "))"))

            let lossy = evaluate(testCase.original, testCase.lossy)
            t.check(!lossy.isAcceptable,
                    "\(testCase.id) lossy candidate rejected (\"\(testCase.lossy)\")")
        }
    }

    // Category-level behavior, stated explicitly for the final report.
    t.suite("Semantic preservation — category coverage") {
        let checks: [(H3SemanticCategory, String, String, String)] = [
            (.speed, "slowly raises a hand", "slowly raises a hand", "raises a hand"),
            (.direction, "turns to the left", "turns to the left", "turns around"),
            (.quantity, "takes two steps", "takes two steps", "takes some steps"),
            (.order, "looks up, then looks down", "looks up, then looks down", "looks up and down"),
            (.negation, "does not smile", "does not smile", "smiles"),
            (.camera, "a close-up of a hand", "a close-up of a hand", "a hand"),
            (.emotion, "a smiling woman waves", "a smiling woman waves", "a woman waves"),
        ]
        for (category, original, good, bad) in checks {
            let extracted = H3SemanticConstraintExtractor.constraints(in: original)
            t.check(extracted.contains { $0.category == category },
                    "\(category.rawValue) extracted")
            t.check(evaluate(original, good).isAcceptable,
                    "\(category.rawValue) faithful accepted")
            t.check(!evaluate(original, bad).isAcceptable,
                    "\(category.rawValue) loss rejected")
        }
    }

    // Guards against over-extraction: a false constraint would reject good work.
    t.suite("Semantic preservation — no false constraints") {
        // Plain prompts with no explicit modifier must yield no constraints,
        // so ordinary rewriting is not blocked.
        for plain in ["a cat sits on a wooden table",
                      "an empty office corridor at night",
                      "a runner crosses a bridge"] {
            let extracted = H3SemanticConstraintExtractor.constraints(in: plain)
            t.check(extracted.isEmpty,
                    "no constraint invented for \"\(plain)\" (got \(extracted.map(\.label)))")
        }
        // "background" must not register as a backward-direction constraint.
        let background = H3SemanticConstraintExtractor.constraints(in: "a blurred background behind her")
        t.check(!background.contains { $0.category == .direction },
                "\"background\" does not create a direction constraint")
        // "one" is deliberately not enforced: "one hand" / "a hand" alternate.
        let one = H3SemanticConstraintExtractor.constraints(in: "raises one hand")
        t.check(!one.contains { $0.category == .quantity },
                "quantity 1 is not enforced (one hand / a hand are equivalent)")
        // A negated emotion must not demand the emotion word reappear.
        let negatedEmotion = H3SemanticConstraintExtractor.constraints(in: "does not smile")
        t.check(!negatedEmotion.contains { $0.category == .emotion },
                "negated emotion does not create a positive emotion constraint")
        t.check(H3SemanticConstraintExtractor.containsJapaneseNegation("笑わない"),
                "Japanese ない negation detected")
        t.check(H3SemanticConstraintExtractor.containsJapaneseNegation("止まらずに歩く"),
                "Japanese ず negation detected")
        t.check(!H3SemanticConstraintExtractor.containsJapaneseNegation("女性が振り返る"),
                "no false Japanese negation")
    }

    // Quantity extraction is generic, not a noun list.
    t.suite("Semantic preservation — quantity is generic") {
        for (text, expected) in [("takes 3 steps", 3), ("takes three steps", 3),
                                 ("三歩進む", 3), ("二回まわる", 2), ("blinks 5 times", 5)] {
            let constraints = H3SemanticConstraintExtractor.quantityConstraints(in: text)
            t.check(constraints.contains { $0.sourceToken == String(expected) },
                    "\"\(text)\" yields quantity \(expected)")
        }
        // Digit and word forms both satisfy the same constraint.
        let original = "walks backward three steps"
        t.check(evaluate(original, "A person walks backward 3 steps.").isAcceptable,
                "digit form satisfies a word-form quantity constraint")
        t.check(evaluate(original, "A person walks backward three steps.").isAcceptable,
                "word form satisfies it too")
    }

    // Dialogue and app-owned data remain untouched by the new gate.
    t.suite("Semantic preservation — dialogue and app-owned data") {
        let original = "男が窓辺に立ち、「もう戻れない」と言う"
        let sources = ExactDialogueReconciler.extractExplicitDialogueSources(from: original)
        t.checkEqual(sources.count, 1, "explicit dialogue still extracted")
        t.checkEqual(sources.first?.text, "もう戻れない", "dialogue text exact")
        // The preservation gate must not demand dialogue text inside the
        // visual description — dialogue is a separate, app-owned field.
        let report = evaluate(original, "A man stands by a window.")
        t.check(report.isAcceptable,
                "visual description need not contain the dialogue line")
    }

    // Open-class content deletion, found by the real video A/B run.
    t.suite("Semantic preservation — open-class clause deletion") {
        // The exact AB2 pair that was wrongly accepted.
        let original = "a man standing in a corridor turns to the left and looks at the wall"
        let dropped = "A man stands in a corridor and turns to the left."

        let uncovered = H3ClauseCoverage.uncoveredClauses(original: original, candidate: dropped)
        t.check(uncovered.contains { $0.contains("wall") },
                "the dropped clause is detected (got \(uncovered))")

        let report = evaluate(original, dropped)
        t.check(!report.isAcceptable, "AB2's accepted-but-lossy candidate is now REJECTED")
        t.check(report.rejections.contains { $0.contains("content lost") },
                "rejection names the lost content")

        // A candidate that keeps both clauses is accepted.
        t.check(evaluate(original, "A man stands in a corridor, turns to the left, and looks at the wall.").isAcceptable,
                "candidate keeping both clauses is accepted")
        // Re-conjugation and reordering are not deletions.
        t.check(evaluate(original, "In a corridor, a man turns left while looking at the wall.").isAcceptable,
                "reordered/re-conjugated candidate still accepted")
    }

    t.suite("Semantic preservation — clause coverage does not over-reject") {
        // Ordinary tightening within one clause must still pass: this check is
        // about a whole clause vanishing, not about wording economy.
        let pairs: [(String, String)] = [
            ("a woman turns around in a hallway", "A woman turns around in a hallway."),
            ("a cat sits on a wooden table", "A cat sits on a wooden table."),
            ("rain", "Rain falls."),
            ("an empty office corridor at night", "An empty office corridor at night."),
            // Policy-driven removal of a music request must not be blocked here;
            // the clause still has other content words that survive.
            ("a woman walks along a beach with dramatic background music",
             "A woman walks along a beach."),
            // Pronoun resolution is allowed and must not read as deletion.
            ("the person slowly raises one hand above their head",
             "A person slowly raises one hand above their head."),
        ]
        for (original, candidate) in pairs {
            let report = evaluate(original, candidate)
            t.check(report.isAcceptable,
                    "not over-rejected: \"\(original)\" → \"\(candidate)\""
                        + (report.isAcceptable ? "" : " [\(report.rejections.joined(separator: "; "))]"))
        }

        // Japanese originals are skipped by design — a translation legitimately
        // loses every surface token, so running this check would reject all of them.
        t.checkEqual(H3ClauseCoverage.uncoveredClauses(
                        original: "女性が廊下で振り返る", candidate: "A woman turns around in a hallway.").count,
                     0, "Japanese originals are exempt from clause coverage")
        for japanese in ["ゆっくり右手を上げる", "左へ二歩進む", "右を見てから正面を見る"] {
            t.checkEqual(H3ClauseCoverage.uncoveredClauses(
                            original: japanese, candidate: "A person performs the action.").count,
                         0, "no clause rejection for Japanese: \(japanese)")
        }

        // Dialogue is excluded from the clause source, as it is from constraints.
        t.checkEqual(H3ClauseCoverage.uncoveredClauses(
                        original: "a woman stands in a doorway and says \"I am not leaving\"",
                        candidate: "A woman stands in a doorway and speaks.").count,
                     0, "quoted dialogue does not create an uncovered clause")
    }

    // Phase J — the compile boundary must survive repeated application, since
    // MiniMaxH3Backend recompiles `rendererNeutralPrompt` on EVERY generation
    // attempt, including queue retries and History regeneration. Those paths
    // reuse the frozen stage-1 prompt string (the backend never writes its
    // stage-2 output back), so re-running must be a fixed point.
    t.suite("Semantic preservation — compile boundary is idempotent under retry") {
        let inputs: [(String, H3EnhancementInput)] = [
            ("camera present", H3EnhancementInput(originalPrompt: "a man walks to a door",
                                                  explicitCamera: "static medium shot")),
            ("no camera", H3EnhancementInput(originalPrompt: "a cat sits on a table")),
            ("i2v no camera", H3EnhancementInput(originalPrompt: "the person raises a hand",
                                                 isImageToVideo: true)),
        ]
        for (label, input) in inputs {
            let candidate = H3EnhancementCandidate(
                visualDescription: "A subject performs the action.",
                action: nil, camera: input.explicitCamera, lighting: nil,
                dialogue: [], audioCues: [])
            let stage1 = H3PromptCompilationOrder.compile(candidate: candidate, input: input)
            let once = H3PromptCompilationOrder.rendererPrompt(forCompiled: stage1, input: input)
            let twice = H3PromptCompilationOrder.rendererPrompt(forCompiled: once, input: input)
            let thrice = H3PromptCompilationOrder.rendererPrompt(forCompiled: twice, input: input)

            t.checkEqual(once, twice, "\(label): second backend pass is a fixed point")
            t.checkEqual(twice, thrice, "\(label): third pass changes nothing either")
            // No contract sentence accumulates across retries.
            t.checkEqual(once.components(separatedBy: "Audio policy:").count - 1, 1,
                         "\(label): audio guard appears exactly once after repeats")
            t.checkEqual(
                thrice.components(separatedBy: "The camera movement remains smooth").count - 1,
                input.explicitCamera == nil ? 1 : 0,
                "\(label): generic camera sentence never duplicates")
            if input.isImageToVideo {
                t.checkEqual(
                    thrice.components(separatedBy: "remain consistent throughout").count - 1, 1,
                    "\(label): I2V appearance clause appears exactly once")
            }
        }
    }

    // Phase C — app-owned generation parameters are unreachable from a reply.
    // Phase E — one shot in, one shot out: no shot restructuring is possible.
    t.suite("Semantic preservation — app-owned data and shot structure") {
        // A reply that tries to restructure into multiple shots and set
        // generation parameters must yield exactly one candidate with none of
        // those values adopted.
        let hostile = ScriptedPreservationProvider(replies: [
            #"{"visualDescription":"A woman turns around.","shots":[{"prompt":"another shot"},{"prompt":"third shot"}],"seed":99,"numFrames":107,"width":1920,"height":1080,"steps":40,"modelId":"other-model","characterId":"CID-1","sourceImagePath":"/tmp/x.png","continuity":"strict","disableAudio":false}"#
        ])
        runPreservationAsync {
            let result = await H3PromptEnhancer(
                provider: hostile, heavyTaskGuard: AlwaysOpenGuard(),
                residencyInspector: nil, timeoutSeconds: 5
            ).enhance(input: preservationInput("a woman turns around"))

            t.check(result.status.isSuccess, "known field still usable")
            // One shot in, one shot out.
            t.check(result.candidate != nil, "exactly one candidate produced")
            let compiled = result.compiledPrompt ?? ""
            t.check(!compiled.contains("another shot"), "no second shot adopted")
            t.check(!compiled.contains("third shot"), "no third shot adopted")
            // No app-owned value reaches the prompt.
            for forbidden in ["99", "107", "1920", "1080", "other-model",
                              "CID-1", "/tmp/x.png", "strict"] {
                t.check(!compiled.contains(forbidden),
                        "app-owned value \"\(forbidden)\" never reaches the prompt")
            }
            t.check(result.warnings.contains { $0.contains("dropped unexpected field") },
                    "the attempt is reported, not silently ignored")
        }

        // The schema itself is the structural guarantee.
        for owned in ["shots", "seed", "numFrames", "width", "height", "steps",
                      "modelId", "modelTier", "characterId", "continuity",
                      "sourceImagePath", "referenceImagePath", "disableAudio",
                      "duration", "resolution", "dialogue", "audioCues"] {
            t.check(!H3EnhancementDraft.allowedKeys.contains(owned),
                    "schema exposes no \(owned) field")
        }
        t.checkEqual(H3EnhancementDraft.allowedKeys.count, 4,
                     "schema surface stays minimal (4 language-only fields)")
    }
}

func runH3DirectorEnhancerBoundaryTests(_ t: TestKit) {

    // Phase R — the four Director x Enhancer combinations, at text/request level.
    // Director decides WHAT the shot is; Enhancer conservatively normalizes an
    // already-decided shot for H3. They share transport, model selection, schema
    // handling, cancellation and unload — but never each other's decisions.
    t.suite("Director x Enhancer boundary — four combinations") {
        let brief = "a woman turns around in a hallway"
        let planJSON = #"{"camera":"static medium shot","action":"A woman turns around in a hallway","dialogue":[],"audioCues":[],"durationIntentSeconds":5}"#

        // 1. Director OFF / Enhance OFF — the direct path, untouched by either.
        let direct = LocalDirector.makeDirectRequest(
            prompt: brief, base: GenerationRequest(prompt: brief, modelId: MiniMaxH3Configuration.modelID))
        // The direct path still applies the app's own audio policy — that is
        // product policy, not enhancement. What matters is that the user's text
        // survives verbatim and nothing was rewritten or added.
        t.check(direct.request.prompt.hasPrefix(brief),
                "Director OFF / Enhance OFF keeps the user's text verbatim at the front")
        t.check(direct.request.prompt.contains("Audio policy:"),
                "the app's audio policy is still applied on the direct path")
        t.checkEqual(direct.request.prompt.replacingOccurrences(
                        of: PerShotAudioPolicy.generationGuard, with: "")
                        .trimmingCharacters(in: .whitespaces),
                     brief,
                     "nothing beyond the audio guard was added — no enhancement occurred")

        // 2. Director ON / Enhance OFF — Director plans and compiles; no enhancer.
        runPreservationAsync {
            let mock = MockDirectorProvider(responses: [planJSON])
            do {
                let (plan, _) = try await LocalDirector(providers: [mock]).plan(brief: brief)
                t.checkEqual(plan.camera, "static medium shot", "Director ON produces its own plan")
                t.check(mock.terminated, "Director unloads its provider")
            } catch {
                t.check(false, "Director ON / Enhance OFF regressed: \(error)")
            }
        }

        // 3. Director OFF / Enhance ON — enhancer normalizes the user's own text.
        runPreservationAsync {
            let provider = ScriptedPreservationProvider(replies: [
                #"{"visualDescription":"A woman turns around in a hallway."}"#
            ])
            let result = await H3PromptEnhancer(
                provider: provider, heavyTaskGuard: AlwaysOpenGuard(),
                residencyInspector: nil, timeoutSeconds: 5
            ).enhance(input: preservationInput(brief))
            t.check(result.status.isSuccess, "Director OFF / Enhance ON succeeds")
            // The enhancer decided nothing about the shot: no camera appeared.
            t.check(result.candidate?.camera == nil,
                    "Enhancer invents no camera — that is the Director's job")
        }

        // 4. Director ON / Enhance ON — the enhancer receives an ALREADY-decided
        //    shot. It must keep the Director's camera and add nothing.
        runPreservationAsync {
            let provider = ScriptedPreservationProvider(replies: [
                #"{"visualDescription":"A woman turns around in a hallway.","camera":"static medium shot"}"#
            ])
            let decided = H3EnhancementInput(
                originalPrompt: "A woman turns around in a hallway",
                explicitCamera: "static medium shot")
            let result = await H3PromptEnhancer(
                provider: provider, heavyTaskGuard: AlwaysOpenGuard(),
                residencyInspector: nil, timeoutSeconds: 5
            ).enhance(input: decided)
            t.check(result.status.isSuccess, "Director ON / Enhance ON succeeds")
            t.checkEqual(result.candidate?.camera, "static medium shot",
                         "the Director's camera decision survives the enhancer")
            t.check(result.compiledPrompt?.contains("static medium shot") == true,
                    "and reaches the compiled prompt")
        }
    }

    // Shared infrastructure, not duplicated infrastructure.
    t.suite("Director x Enhancer boundary — shared transport, separate roles") {
        // Both drive the same DirectorProvider protocol.
        let provider: DirectorProvider = ScriptedPreservationProvider(replies: ["{}"])
        t.check(provider.modelIdentifier != nil, "enhancer uses the Director transport protocol")

        // Model selection is separate so the PoC cannot rewrite the Director's
        // saved preference.
        t.check(H3PromptEnhancer.modelUserDefaultsKey != OllamaDirectorProvider.modelUserDefaultsKey,
                "enhancer model key is separate from the Director's")
        t.checkEqual(H3PromptEnhancer.modelUserDefaultsKey, "h3PromptEnhancerOllamaModel",
                     "enhancer key name is explicit")

        // Cancellation is the Director's own handle type, not a parallel one.
        let handle = DirectorPlanningHandle()
        handle.cancel()
        t.check(handle.isCancelled, "shared cancellation handle")

        // Roles stay distinct: the enhancer's schema cannot express a plan.
        for directorOnly in ["shots", "durationIntentSeconds", "acting", "motion", "dialogue"] {
            t.check(!H3EnhancementDraft.allowedKeys.contains(directorOnly),
                    "enhancer schema cannot express Director-owned field \(directorOnly)")
        }
    }
}

// MARK: - Local doubles

/// Minimal scripted provider for preservation tests.
final class ScriptedPreservationProvider: DirectorProvider {
    let name = "scripted-preservation"
    var modelIdentifier: String? = "scripted:test"
    var replies: [String]
    private(set) var prompts: [String] = []
    private(set) var terminateCalls = 0

    init(replies: [String]) { self.replies = replies }

    func isAvailable() async -> Bool { true }
    func terminate() async { terminateCalls += 1 }

    func complete(system: String, prompt: String) async throws -> String {
        try await complete(system: system, prompt: prompt, jsonSchema: [:], handle: nil)
    }

    func complete(system: String, prompt: String, jsonSchema: [String: Any],
                  handle: DirectorPlanningHandle?) async throws -> String {
        prompts.append(prompt)
        let index = prompts.count - 1
        guard index < replies.count else {
            throw DirectorError.providerFailed("no more scripted replies")
        }
        return replies[index]
    }
}

struct AlwaysOpenGuard: H3EnhancerHeavyTaskGuard {
    func blockingReason() -> String? { nil }
}

func runPreservationAsync(_ block: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task {
        await block()
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
}
