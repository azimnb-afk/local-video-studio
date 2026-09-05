import Foundation
@testable import LTXVideoGeneratorCore

func runExactDialogueReconcilerTests(_ t: TestKit) {

    func line(_ speaker: String, _ text: String) -> OneShotPlan.DialogueLine {
        OneShotPlan.DialogueLine(speaker: speaker, text: text)
    }

    func refLine(_ speaker: String, _ text: String, sourceId: String) -> OneShotPlan.DialogueLine {
        OneShotPlan.DialogueLine(speaker: speaker, text: text, sourceId: sourceId)
    }

    t.suite("ExactDialogueReconciler — quote extraction") {
        t.checkEqual(
            ExactDialogueReconciler.extractQuotedDialogue(from: "最初に「こんにちは」と話す。"),
            ["こんにちは"], "corner brackets extracted, delimiters removed"
        )
        t.checkEqual(
            ExactDialogueReconciler.extractQuotedDialogue(from: "最後に「こんにちは！」と言う。"),
            ["こんにちは！"], "internal punctuation inside the quote is preserved, not stripped"
        )
        t.checkEqual(
            ExactDialogueReconciler.extractQuotedDialogue(from: "彼女は『おはようございます。』と言う。"),
            ["おはようございます。"], "double corner brackets (『』) extracted with internal punctuation kept"
        )
        t.checkEqual(
            ExactDialogueReconciler.extractQuotedDialogue(from: #"She says "Hello there"."#),
            ["Hello there"], "straight ASCII quotes extracted"
        )
        t.checkEqual(
            ExactDialogueReconciler.extractQuotedDialogue(from: "She says \u{201C}Hello there!\u{201D}."),
            ["Hello there!"], "curly quotes extracted with internal punctuation kept"
        )
        t.checkEqual(
            ExactDialogueReconciler.extractQuotedDialogue(from: "「こんにちは」\n「今日はいい天気ですね」"),
            ["こんにちは", "今日はいい天気ですね"], "multiple quoted entries extracted in document order"
        )
        t.check(ExactDialogueReconciler.extractQuotedDialogue(from: "女性が部屋に入り、笑顔で挨拶する。").isEmpty,
                "a brief with no quoted text extracts nothing")
    }

    t.suite("ExactDialogueReconciler — reconciliation") {
        // 1. Model appends a Japanese period the user never wrote.
        let case1 = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "こんにちは。")],
            brief: "最後に「こんにちは」と日本語で話す。"
        )
        t.checkEqual(case1.first?.text, "こんにちは", "model-added terminal punctuation does not survive; source wins")
        t.checkEqual(case1.first?.speaker, "Woman", "speaker is left as the Director's own choice")

        // 2. Model drops punctuation the user included.
        let case2 = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "こんにちは")],
            brief: "最後に「こんにちは！」と言う。"
        )
        t.checkEqual(case2.first?.text, "こんにちは！", "the user's own punctuation is restored even though the model omitted it")

        // 3. Exact source with its own internal punctuation, untouched even
        // when the model reply happens to already match it.
        let case3 = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("", "おはようございます。")],
            brief: "彼女は『おはようございます。』と言う。"
        )
        t.checkEqual(case3.first?.text, "おはようございます。", "matching model output is still pinned to the exact source")

        // 4. ASCII quotes.
        let case4 = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "Hello.")],
            brief: #"She says "Hello there"."#
        )
        t.checkEqual(case4.first?.text, "Hello there", "ASCII-quoted source replaces the model's own wording")

        // 5. Curly quotes.
        let case5 = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "Hello")],
            brief: "She says \u{201C}Hello there!\u{201D}."
        )
        t.checkEqual(case5.first?.text, "Hello there!", "curly-quoted source replaces the model's own wording")

        // 6. Multiple lines, order preserved, each mapped to its own source.
        let case6 = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "こんにちは、元気？"), line("Man", "元気ですよ")],
            brief: "女性は「こんにちは」と話す。男性は「今日はいい天気ですね」と答える。"
        )
        t.checkEqual(case6.map(\.text), ["こんにちは", "今日はいい天気ですね"],
                     "two distinct source lines map 1:1 in order, never merged into one paraphrased line")
        t.checkEqual(case6.map(\.speaker), ["Woman", "Man"], "speaker assignment from the Director is untouched")

        // 7. Model-added Japanese punctuation on a mid-length line.
        let case7 = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("", "今日はいい天気ですね、")],
            brief: "「今日はいい天気ですね」と話す。"
        )
        t.checkEqual(case7.first?.text, "今日はいい天気ですね", "model-added trailing 、 is discarded in favor of the exact source")

        // 8. Model translation is still overridden when a clear (count-based)
        // correspondence exists — the model never becomes the source of
        // truth just because it chose to translate instead of relay.
        let case8 = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "Hello")],
            brief: "最後に「こんにちは」と日本語で話す。"
        )
        t.checkEqual(case8.first?.text, "こんにちは", "a translated line is replaced by the user's exact original-language source")

        // 9. No quoted dialogue in the brief: existing behavior (whatever the
        // Director produced) is left completely untouched.
        let case9 = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "Hello there!")],
            brief: "女性が部屋に入り、笑顔で挨拶する。"
        )
        t.checkEqual(case9.first?.text, "Hello there!", "no explicit quoted dialogue means nothing is reconciled or invented")

        // Count mismatch: two model lines, one source. Ambiguous — fail
        // closed, leave every line exactly as the Director produced it.
        let mismatch = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "こんにちは"), line("Woman", "元気？")],
            brief: "「こんにちは」"
        )
        t.checkEqual(mismatch.map(\.text), ["こんにちは", "元気？"],
                     "a count mismatch between quoted sources and planned lines is left untouched, not guessed at")
    }

    t.suite("ExactDialogueReconciler — multi-shot scatter/gather") {
        var shotA = StoryboardDirector.ShotPlanDraft(title: "Shot 1", summary: "She enters.")
        shotA.dialogue = [line("Woman", "こんにちは。")]
        var shotB = StoryboardDirector.ShotPlanDraft(title: "Shot 2", summary: "She waits.")
        shotB.dialogue = nil
        var shotC = StoryboardDirector.ShotPlanDraft(title: "Shot 3", summary: "She continues.")
        shotC.dialogue = [line("Woman", "元気ですか")]

        let reconciled = ExactDialogueReconciler.reconcile(
            shots: [shotA, shotB, shotC],
            brief: "女性は「こんにちは」と話す。その後「元気ですか？」と尋ねる。"
        )
        t.checkEqual(reconciled[0].dialogue?.first?.text, "こんにちは", "shot 1's line reconciled from the first source")
        t.check(reconciled[1].dialogue == nil, "a shot with no dialogue at all is left untouched (still nil, not invented)")
        t.checkEqual(reconciled[2].dialogue?.first?.text, "元気ですか？", "shot 3's line reconciled from the second source, across the gap left by shot 2")
    }

    t.suite("ExactDialogueReconciler — reaches PromptCompiler unchanged (boundary)") {
        // 12. The reconciled value flows through the exact same OneShotPlan
        // -> PromptCompiler.compile path Structured JSON already used before
        // this fix; PromptCompiler itself was not modified for this task.
        let reconciled = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "こんにちは。")],
            brief: "最後に「こんにちは」と日本語で話す。"
        )
        let plan = OneShotPlan(camera: "medium shot", action: "She smiles at the camera.", dialogue: reconciled)
        let compiled = PromptCompiler.compile(plan: plan, options: .init(perShotAudioPolicy: .naturalProductionSoundNoMusic))
        t.check(compiled.contains("Woman says: \"こんにちは\""),
                "PromptCompiler renders the reconciled canonical exact dialogue verbatim")
        t.check(!compiled.contains("こんにちは。"), "the model's own punctuated wording never reaches the compiled prompt")
    }

    // MARK: Structured JSON and Text Protocol both converge on the same
    // reconciliation point inside StoryboardDirector.makeProject.

    t.suite("ExactDialogueReconciler — Structured JSON path (real pipeline)") {
        let jsonReply = """
        {"logline":"A woman greets the camera.","shots":[
          {"title":"Shot 1","summary":"A woman in blue enters and smiles at the camera.",
           "dialogue":[{"speaker":"Woman","text":"こんにちは。"}],"continuity":"cut"}
        ]}
        """
        let provider = ProtocolAwareMockProvider(jsonReply: jsonReply, textReply: nil)
        let defaults = UserDefaults(suiteName: "exact-dialogue-json-\(UUID().uuidString)")!
        let director = StoryboardDirector(
            providers: [provider],
            compatibility: LocalDirectorCompatibilityService(userDefaults: defaults)
        )
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (project, _, _) = try await director.makeProject(
                    title: "Test", brief: "最後に「こんにちは」と日本語で話す。"
                )
                t.checkEqual(project.shots.first?.audio.dialogue.first?.text, "こんにちは",
                             "Structured JSON: exact user source overrides the model's own punctuation")
                t.checkEqual(project.directorProtocol, LocalDirectorProtocol.structuredJSON.rawValue,
                             "confirms this ran the Structured JSON path, not a fallback")
            } catch {
                t.check(false, "Structured JSON reconciliation test threw: \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }

    t.suite("ExactDialogueReconciler — Text Protocol path (real pipeline)") {
        let textReply = """
        LOGLINE: A woman greets the camera.
        SHOT 1
        ACTION: A woman in blue enters and smiles at the camera.
        CONTINUITY: CUT
        DIALOGUE: Woman|こんにちは。
        """
        // No jsonReply: Structured JSON negotiation fails first, causing the
        // real negotiation chain to fall through to Text Protocol — the same
        // production path a genuinely JSON-incapable model would take.
        let provider = ProtocolAwareMockProvider(jsonReply: nil, textReply: textReply)
        let defaults = UserDefaults(suiteName: "exact-dialogue-text-\(UUID().uuidString)")!
        let director = StoryboardDirector(
            providers: [provider],
            compatibility: LocalDirectorCompatibilityService(userDefaults: defaults)
        )
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (project, _, _) = try await director.makeProject(
                    title: "Test", brief: "最後に「こんにちは」と日本語で話す。"
                )
                t.checkEqual(project.shots.first?.audio.dialogue.first?.text, "こんにちは",
                             "Text Protocol: exact user source overrides the model's own punctuation")
                t.checkEqual(project.directorProtocol, LocalDirectorProtocol.textProtocol.rawValue,
                             "confirms this actually ran the Text Protocol path")
                t.checkEqual(project.planningMode, "ai",
                             "Structured failure + Text Protocol success is still classified Local AI, not Basic Fallback")
            } catch {
                t.check(false, "Text Protocol reconciliation test threw: \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }

    // MARK: - Explicit speech detection vs. other quoted text (source IDs)

    t.suite("ExactDialogueReconciler — explicit speech detection") {
        // 1. Japanese explicit speech extraction, several verbs.
        t.checkEqual(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: "女性は「こんにちは」と言う。"),
            [ExplicitDialogueSource(id: "D1", text: "こんにちは")], "と言う recognized"
        )
        t.checkEqual(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: "女性は「こんにちは」と叫ぶ。"),
            [ExplicitDialogueSource(id: "D1", text: "こんにちは")], "と叫ぶ recognized"
        )
        t.checkEqual(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: "女性は「こんにちは」とささやく。"),
            [ExplicitDialogueSource(id: "D1", text: "こんにちは")], "とささやく recognized"
        )
        t.checkEqual(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: "最後に「こんにちは」と日本語で話す。"),
            [ExplicitDialogueSource(id: "D1", text: "こんにちは")],
            "an adverbial phrase between と and the verb (と日本語で話す) is tolerated — cd0d818's own real Qwen brief"
        )

        // 2. English explicit speech extraction, several verbs.
        t.checkEqual(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: #"She says "Hello"."#),
            [ExplicitDialogueSource(id: "D1", text: "Hello")], "says recognized"
        )
        t.checkEqual(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: #"He asks "Hello?""#),
            [ExplicitDialogueSource(id: "D1", text: "Hello?")], "asks recognized"
        )
        t.checkEqual(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: #"She whispers "Hello""#),
            [ExplicitDialogueSource(id: "D1", text: "Hello")], "whispers recognized"
        )

        // 3. Japanese sign/display text excluded.
        t.check(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: "壁の看板には「OPEN」と書いてある。").isEmpty,
            "quoted sign text (と書いてある) is not spoken dialogue"
        )
        t.check(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: "画面に「START」と表示される。").isEmpty,
            "quoted display text (と表示される) is not spoken dialogue"
        )
        t.check(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: "服には「TOKYO」と書かれている。").isEmpty,
            "quoted printed text (と書かれている) is not spoken dialogue"
        )

        // 4. English/display text excluded (no speech verb nearby).
        t.check(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: #"The screen shows "START"."#).isEmpty,
            "quoted on-screen text with no speech verb is not spoken dialogue"
        )

        // 5. Title quote excluded.
        t.check(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: "タイトルは「Summer Days」").isEmpty,
            "a title in quotes is not spoken dialogue"
        )
        t.check(
            ExactDialogueReconciler.extractExplicitDialogueSources(from: "「赤」という色を選んだ。").isEmpty,
            "「X」という (a naming/labeling construction, hiragana いう) is not spoken dialogue"
        )

        // Required Part 10 test: sign quote + real dialogue in the same brief.
        let mixed = ExactDialogueReconciler.extractExplicitDialogueSources(
            from: "壁の看板には「OPEN」と書いてある。\n女性は「こんにちは」と話す。"
        )
        t.checkEqual(mixed, [ExplicitDialogueSource(id: "D1", text: "こんにちは")],
                     "only the spoken line becomes a source; OPEN (signage) is excluded and does not consume an ID")

        let mixed2 = ExactDialogueReconciler.extractExplicitDialogueSources(
            from: "画面に「START」と表示される。\n女性は「始めよう！」と言う。"
        )
        t.checkEqual(mixed2, [ExplicitDialogueSource(id: "D1", text: "始めよう！")],
                     "only 始めよう！ becomes a source; START (display text) is excluded")
    }

    t.suite("ExactDialogueReconciler — source ID reconciliation") {
        // 6. Single source ID reconciliation: source wins regardless of what
        // the model wrote, even a full translation.
        let single = ExactDialogueReconciler.reconcile(
            dialogueLines: [refLine("Woman", "See you tomorrow", sourceId: "D1")],
            brief: "女性は「また明日」と言う。"
        )
        t.checkEqual(single.first?.text, "また明日", "a valid sourceId wins over any model wording, including a translation")

        // 7 & 8. Two source IDs, Director reorders D2 before D1 — the
        // required Part 9 test. Model text is deliberately wrong/placeholder
        // to prove the ID, not position or model wording, is authoritative.
        let brief = "「こんにちは」と言う。その後「また明日」と話す。"
        t.checkEqual(ExactDialogueReconciler.extractExplicitDialogueSources(from: brief),
                     [ExplicitDialogueSource(id: "D1", text: "こんにちは"),
                      ExplicitDialogueSource(id: "D2", text: "また明日")],
                     "D1/D2 assigned in brief order")

        let reordered = ExactDialogueReconciler.reconcile(
            dialogueLines: [
                refLine("Woman", "wrong text", sourceId: "D2"),   // Shot 1 -> D2
                refLine("Woman", "also wrong", sourceId: "D1"),   // Shot 3 -> D1
            ],
            brief: brief
        )
        t.checkEqual(reordered.map(\.text), ["また明日", "こんにちは"],
                     "Shot 1 (D2) and Shot 3 (D1) resolve correctly even though the Director reversed the natural order")

        // 9. Invalid source ID fails safely: left untouched, no crash, no
        // guess at which real source it might have meant.
        let invalid = ExactDialogueReconciler.reconcile(
            dialogueLines: [refLine("Woman", "model's own words", sourceId: "D99")],
            brief: "女性は「こんにちは」と言う。"
        )
        t.checkEqual(invalid.first?.text, "model's own words",
                     "an unmapped sourceId is left exactly as the Director produced it, never mapped to a different source")
        t.checkEqual(invalid.first?.sourceId, "D99", "the (invalid) sourceId itself is preserved for diagnostics, not stripped")

        // 12. cd0d818 single-dialogue punctuation-override regression: no
        // sourceId at all still uses the legacy positional path.
        let legacy = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "こんにちは。")],
            brief: "最後に「こんにちは」と日本語で話す。"
        )
        t.checkEqual(legacy.first?.text, "こんにちは", "cd0d818's punctuation-override behavior still holds with no sourceId present")

        // 13. No explicit dialogue: unchanged.
        let none = ExactDialogueReconciler.reconcile(
            dialogueLines: [line("Woman", "Hello there!")],
            brief: "女性が部屋に入り、笑顔で挨拶する。"
        )
        t.checkEqual(none.first?.text, "Hello there!", "no explicit dialogue sources means nothing is reconciled")
    }

    t.suite("ExactDialogueReconciler — sourceId reaches PromptCompiler unchanged (boundary)") {
        // 14. The resolved value flows through the same OneShotPlan ->
        // PromptCompiler.compile boundary as before; PromptCompiler itself
        // was not modified for source IDs.
        let reconciled = ExactDialogueReconciler.reconcile(
            dialogueLines: [refLine("Woman", "placeholder", sourceId: "D1")],
            brief: "女性は「こんにちは」と言う。"
        )
        let plan = OneShotPlan(camera: "medium shot", action: "She smiles.", dialogue: reconciled)
        let compiled = PromptCompiler.compile(plan: plan, options: .init(perShotAudioPolicy: .naturalProductionSoundNoMusic))
        t.check(compiled.contains("Woman says: \"こんにちは\""), "PromptCompiler renders the ID-resolved exact dialogue")
        t.check(!compiled.contains("placeholder"), "the model's placeholder text never reaches the compiled prompt")
        t.check(!compiled.contains("D1"), "the source ID itself never leaks into the renderer prompt")
    }

    // MARK: - Real pipeline: sourceId through Structured JSON and Text Protocol

    t.suite("ExactDialogueReconciler — Structured JSON sourceId (real pipeline, reordered)") {
        // 10. Legacy-compatible schema plus the new optional "sourceId".
        let jsonReply = """
        {"logline":"A farewell.","shots":[
          {"title":"Shot 1","summary":"She waves goodbye at the door.",
           "dialogue":[{"speaker":"Woman","text":"placeholder","sourceId":"D2"}],"continuity":"cut"},
          {"title":"Shot 2","summary":"She steps outside.","continuity":"continue"},
          {"title":"Shot 3","summary":"She turns back for one last look.",
           "dialogue":[{"speaker":"Woman","text":"placeholder","sourceId":"D1"}],"continuity":"continue"}
        ]}
        """
        let provider = ProtocolAwareMockProvider(jsonReply: jsonReply, textReply: nil)
        let defaults = UserDefaults(suiteName: "exact-dialogue-sourceid-json-\(UUID().uuidString)")!
        let director = StoryboardDirector(
            providers: [provider],
            compatibility: LocalDirectorCompatibilityService(userDefaults: defaults)
        )
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (project, _, _) = try await director.makeProject(
                    title: "Test", brief: "「こんにちは」と言う。その後「また明日」と話す。"
                )
                t.checkEqual(project.shots.count, 3, "all three shots planned")
                t.checkEqual(project.shots[0].audio.dialogue.first?.text, "また明日",
                             "Structured JSON: Shot 1's sourceId=D2 resolves to D2's exact text, not model placeholder text")
                t.checkEqual(project.shots[2].audio.dialogue.first?.text, "こんにちは",
                             "Structured JSON: Shot 3's sourceId=D1 resolves to D1's exact text — reordering is safe")
            } catch {
                t.check(false, "Structured JSON sourceId reordering test threw: \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }

    t.suite("ExactDialogueReconciler — Text Protocol DIALOGUE_REF (real pipeline, reordered)") {
        // 11. Legacy DIALOGUE: <speaker>|<text> (dd6af97) alongside the new
        // DIALOGUE_REF: <id>|<speaker> in the same reply, to prove both
        // still parse in the same shot set.
        let textReply = """
        LOGLINE: A farewell.
        SHOT 1
        ACTION: She waves goodbye at the door.
        CONTINUITY: CUT
        DIALOGUE_REF: D2|Woman
        SHOT 2
        ACTION: She steps outside.
        CONTINUITY: CONTINUE
        DIALOGUE: Woman|some other unrelated line
        SHOT 3
        ACTION: She turns back for one last look.
        CONTINUITY: CONTINUE
        DIALOGUE_REF: D1|Woman
        """
        let provider = ProtocolAwareMockProvider(jsonReply: nil, textReply: textReply)
        let defaults = UserDefaults(suiteName: "exact-dialogue-sourceid-text-\(UUID().uuidString)")!
        let director = StoryboardDirector(
            providers: [provider],
            compatibility: LocalDirectorCompatibilityService(userDefaults: defaults)
        )
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let (project, _, _) = try await director.makeProject(
                    title: "Test", brief: "「こんにちは」と言う。その後「また明日」と話す。"
                )
                t.checkEqual(project.directorProtocol, LocalDirectorProtocol.textProtocol.rawValue,
                             "confirms this ran the Text Protocol path")
                t.checkEqual(project.shots[0].audio.dialogue.first?.text, "また明日",
                             "Text Protocol: Shot 1's DIALOGUE_REF D2 resolves to D2's exact text")
                t.checkEqual(project.shots[1].audio.dialogue.first?.text, "some other unrelated line",
                             "Text Protocol: legacy DIALOGUE (dd6af97, no ID) free text is left untouched alongside sourceId lines")
                t.checkEqual(project.shots[2].audio.dialogue.first?.text, "こんにちは",
                             "Text Protocol: Shot 3's DIALOGUE_REF D1 resolves to D1's exact text — reordering is safe")
            } catch {
                t.check(false, "Text Protocol DIALOGUE_REF reordering test threw: \(error)")
            }
            sem.signal()
        }
        sem.wait()
    }
}
