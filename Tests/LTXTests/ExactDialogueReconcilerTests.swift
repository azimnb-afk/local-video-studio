import Foundation
@testable import LTXVideoGeneratorCore

func runExactDialogueReconcilerTests(_ t: TestKit) {

    func line(_ speaker: String, _ text: String) -> OneShotPlan.DialogueLine {
        OneShotPlan.DialogueLine(speaker: speaker, text: text)
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
            brief: "「こんにちは」\n「今日はいい天気ですね」"
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
            brief: "「こんにちは」\n「元気ですか？」"
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
}
