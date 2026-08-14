import Foundation
@testable import LTXVideoGeneratorCore

func runEnhancedPromptHardeningTests(_ t: TestKit) {
    t.suite("Enhanced Prompt Hardening — Sanitization & Backend Contract") {

        // 1. Clean text remains unchanged
        let cleanText = "In a medium shot, a woman calmly lifts a ceramic coffee cup to her lips and takes a sip."
        t.checkEqual(PromptSanitizer.sanitize(cleanText), cleanText, "Clean text remains unchanged")
        t.check(PromptSanitizer.isValidEnhancedPrompt(cleanText), "Clean text is valid")

        // 2. Terminal token removal
        let withEOT = "A woman sips coffee.<end_of_turn>"
        t.checkEqual(PromptSanitizer.sanitize(withEOT), "A woman sips coffee.", "Single terminal token removed")

        // 3. Repeated terminal tokens cut cleanly
        let withRepeatedEOT = "A woman sips coffee.<end_of_turn><end_of_turn><end_of_turn>"
        t.checkEqual(PromptSanitizer.sanitize(withRepeatedEOT), "A woman sips coffee.", "Repeated terminal tokens cut cleanly")

        // 4. Content after first terminal token is discarded (garbage truncation)
        let withJunk = "A woman sips coffee.<end_of_turn>She puts the cup down, opens a book, and hears a wind chime.<end_of_turn>"
        t.checkEqual(PromptSanitizer.sanitize(withJunk), "A woman sips coffee.", "Content after first terminal token discarded")

        // 5. Start / Role tokens stripped
        let withStartTurn = "<start_of_turn>model\nA woman sips coffee."
        t.checkEqual(PromptSanitizer.sanitize(withStartTurn), "A woman sips coffee.", "start_of_turn model tag stripped")

        let withStartTurnUser = "<start_of_turn>user\nSome prompt<end_of_turn>\n<start_of_turn>model\nA woman sips coffee.<end_of_turn>"
        // Cuts at first terminal token
        t.checkEqual(PromptSanitizer.sanitize(withStartTurnUser), "Some prompt", "Cuts at first terminal token when user turn is present")

        let withImStart = "<|im_start|>assistant\nA woman sips coffee.<|im_end|>"
        t.checkEqual(PromptSanitizer.sanitize(withImStart), "A woman sips coffee.", "ChatML tags stripped and cut at im_end")

        // 6. Supported EOS token variants
        t.checkEqual(PromptSanitizer.sanitize("A woman walks.</s>"), "A woman walks.", "</s> handled")
        t.checkEqual(PromptSanitizer.sanitize("A woman walks.<eos>"), "A woman walks.", "<eos> handled")
        t.checkEqual(PromptSanitizer.sanitize("A woman walks.<|eot_id|>"), "A woman walks.", "<|eot_id|> handled")
        t.checkEqual(PromptSanitizer.sanitize("A woman walks.<|end_of_text|>"), "A woman walks.", "<|end_of_text|> handled")

        // 7. Legitimate normal words "model" and "assistant" preserved
        let naturalWords = "The fashion model walks down the runway with a production assistant."
        t.checkEqual(PromptSanitizer.sanitize(naturalWords), naturalWords, "Natural words 'model' and 'assistant' preserved")

        // 8. Empty / control-only rejection
        let onlyControls = "<start_of_turn>model\n<end_of_turn><end_of_turn>"
        let sanitizedControls = PromptSanitizer.sanitize(onlyControls)
        t.checkEqual(sanitizedControls, "", "Control-only input sanitizes to empty string")
        t.check(!PromptSanitizer.isValidEnhancedPrompt(sanitizedControls), "Empty sanitized text rejected by validator")

        // 9. Markdown code fences stripped
        let withFences = "```markdown\nA woman sips coffee.\n```"
        t.checkEqual(PromptSanitizer.sanitize(withFences), "A woman sips coffee.", "Markdown code fences stripped")

        // 10. Unicode / Japanese / Multilingual content intact
        let japaneseDialogue = "Mika says: \"美味しいコーヒーね\" while taking a sip."
        t.checkEqual(PromptSanitizer.sanitize(japaneseDialogue), japaneseDialogue, "Japanese characters preserved")

        // 11. Backend & GenerationRequest contract:
        // When raw LLM output contains <end_of_turn>, sanitized prompt is applied to generationPrompt
        let rawLLMOutput = "In a medium shot, a woman drinks coffee.<end_of_turn><end_of_turn>unrelated text"
        let cleanPrompt = PromptSanitizer.sanitize(rawLLMOutput)
        t.check(!cleanPrompt.contains("<end_of_turn>"), "Sanitized prompt has 0 <end_of_turn>")
        t.check(!cleanPrompt.contains("unrelated text"), "Sanitized prompt has 0 leaked post-terminal text")

        // 12. System prompt snapshot checks
        let bundlePromptsPath = "LTXVideoGenerator/Resources/prompts/gemma_t2v_system_prompt.txt"
        if let systemPromptText = try? String(contentsOfFile: bundlePromptsPath, encoding: .utf8) {
            t.check(systemPromptText.contains("Preserve Core Intent"), "System prompt specifies 'Preserve Core Intent'")
            t.check(systemPromptText.contains("Do NOT invent unrequested story beats"), "System prompt prohibits unrequested story beats")
            t.check(systemPromptText.contains("Do NOT invent arbitrary environmental sound effects"), "System prompt prohibits arbitrary environmental sound effects")
            t.check(systemPromptText.contains("Do NOT output chat-template tokens"), "System prompt prohibits chat-template tokens")
        }
    }
}
