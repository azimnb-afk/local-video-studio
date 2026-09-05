import Foundation
@testable import LTXVideoGeneratorCore

func runStructuralMoviePlannerTests(_ t: TestKit) {
    t.suite("StructuralMoviePlanner — Auto Movie Director OFF Core") {

        // 1. Single English sentence → 1 shot
        do {
            let plan = try? StructuralMoviePlanner.plan(prompt: "A woman walks along the beach.")
            t.check(plan != nil, "1. Single English sentence parses successfully")
            t.checkEqual(plan?.segments.count, 1, "1. Exactly 1 shot created")
            t.checkEqual(plan?.segments.first?.literalPrompt, "A woman walks along the beach.", "1. Literal prompt preserved")
            t.checkEqual(plan?.segments.first?.transition, .cut, "1. Shot 1 transition is CUT")
        }

        // 2. Three English sentences → 3 shots
        do {
            let plan = try? StructuralMoviePlanner.plan(prompt: "Walks to the door. Opens it. Looks outside.")
            t.checkEqual(plan?.segments.count, 3, "2. Three sentences create 3 shots")
            t.checkEqual(plan?.segments[0].literalPrompt, "Walks to the door.", "2. Shot 1 prompt matches")
            t.checkEqual(plan?.segments[0].transition, .cut, "2. Shot 1 is CUT")
            t.checkEqual(plan?.segments[1].literalPrompt, "Opens it.", "2. Shot 2 prompt matches")
            t.checkEqual(plan?.segments[1].transition, .continueFromPrevious, "2. Shot 2 is CONTINUE")
            t.checkEqual(plan?.segments[2].literalPrompt, "Looks outside.", "2. Shot 3 prompt matches")
            t.checkEqual(plan?.segments[2].transition, .continueFromPrevious, "2. Shot 3 is CONTINUE")
        }

        // 3. Three Japanese sentences → 3 shots
        do {
            let plan = try? StructuralMoviePlanner.plan(prompt: "ドアへ歩く。開ける。外を見る。")
            t.checkEqual(plan?.segments.count, 3, "3. Three Japanese sentences create 3 shots")
            t.checkEqual(plan?.segments[0].literalPrompt, "ドアへ歩く。", "3. Shot 1 Japanese prompt matches")
            t.checkEqual(plan?.segments[0].transition, .cut, "3. Shot 1 Japanese is CUT")
            t.checkEqual(plan?.segments[1].literalPrompt, "開ける。", "3. Shot 2 Japanese prompt matches")
            t.checkEqual(plan?.segments[1].transition, .continueFromPrevious, "3. Shot 2 Japanese is CONTINUE")
            t.checkEqual(plan?.segments[2].literalPrompt, "外を見る。", "3. Shot 3 Japanese prompt matches")
            t.checkEqual(plan?.segments[2].transition, .continueFromPrevious, "3. Shot 3 Japanese is CONTINUE")
        }

        // 4, 5, 6. Multiple paragraphs & boundaries
        do {
            let prompt = """
            Walks to the door. Opens it.

            Looks outside. The street is empty.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 4, "4. Two paragraphs with 2 sentences each create 4 shots")
            t.checkEqual(plan?.segments[0].literalPrompt, "Walks to the door.", "4. Shot 1 prompt matches")
            t.checkEqual(plan?.segments[0].transition, .cut, "4. Shot 1 is CUT")
            t.checkEqual(plan?.segments[1].literalPrompt, "Opens it.", "4. Shot 2 prompt matches")
            t.checkEqual(plan?.segments[1].transition, .continueFromPrevious, "6. Same paragraph sentence 2 is CONTINUE")

            t.checkEqual(plan?.segments[2].literalPrompt, "Looks outside.", "4. Shot 3 prompt matches")
            t.checkEqual(plan?.segments[2].transition, .cut, "5. New paragraph shot 3 is CUT")
            t.checkEqual(plan?.segments[3].literalPrompt, "The street is empty.", "4. Shot 4 prompt matches")
            t.checkEqual(plan?.segments[3].transition, .continueFromPrevious, "6. Same paragraph sentence 4 is CONTINUE")
        }

        // 7. Explicit [CUT]
        do {
            let prompt = """
            Walks to the door.
            [CUT]
            A different room appears.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "7. Explicit [CUT] creates 2 shots")
            t.checkEqual(plan?.segments[0].transition, .cut, "7. Shot 1 is CUT")
            t.checkEqual(plan?.segments[1].literalPrompt, "A different room appears.", "7. [CUT] marker stripped from prompt")
            t.checkEqual(plan?.segments[1].transition, .cut, "7. Shot 2 is CUT via explicit marker")
        }

        // 8. Explicit CUT:
        do {
            let prompt = """
            First angle view.
            CUT:
            Second angle view.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "8. Explicit CUT: creates 2 shots")
            t.checkEqual(plan?.segments[1].literalPrompt, "Second angle view.", "8. CUT: stripped from prompt")
            t.checkEqual(plan?.segments[1].transition, .cut, "8. Shot 2 is CUT via CUT: marker")
        }

        // 9. Explicit [CONTINUE] across paragraph
        do {
            let prompt = """
            Shot 1:
            Walks forward.

            [CONTINUE]
            Shot 2:
            Opens the door.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "9. Explicit [CONTINUE] across paragraph creates 2 shots")
            t.checkEqual(plan?.segments[0].literalPrompt, "Walks forward.", "9. Shot 1 prompt matches")
            t.checkEqual(plan?.segments[0].transition, .cut, "9. Shot 1 is CUT")
            t.checkEqual(plan?.segments[1].literalPrompt, "Opens the door.", "9. Shot 2 prompt matches without markers")
            t.checkEqual(plan?.segments[1].transition, .continueFromPrevious, "9. Shot 2 is CONTINUE via explicit marker")
        }

        // 10. Explicit CONTINUE:
        do {
            let prompt = """
            Scene 1:
            The car accelerates.
            CONTINUE:
            The car turns left.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "10. Explicit CONTINUE: creates 2 shots")
            t.checkEqual(plan?.segments[1].literalPrompt, "The car turns left.", "10. CONTINUE: stripped")
            t.checkEqual(plan?.segments[1].transition, .continueFromPrevious, "10. Shot 2 is CONTINUE")
        }

        // 11. Shot N markers
        do {
            let prompt = """
            Shot 1: The detective enters.
            [Shot 2] The detective sits down.
            Shot 3. The detective opens the file.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 3, "11. Shot N markers create 3 shots")
            t.checkEqual(plan?.segments[0].literalPrompt, "The detective enters.", "11. Shot 1 marker stripped")
            t.checkEqual(plan?.segments[1].literalPrompt, "The detective sits down.", "11. [Shot 2] marker stripped")
            t.checkEqual(plan?.segments[2].literalPrompt, "The detective opens the file.", "11. Shot 3. marker stripped")
        }

        // 12. Scene N markers (defaults to CUT)
        do {
            let prompt = """
            Scene 1: Interior office at day. A detective talks on phone.
            Scene 2: Exterior street at night. A car passes by.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 4, "12. Scene markers with 2 sentences each create 4 shots")
            t.checkEqual(plan?.segments[0].transition, .cut, "12. Shot 1 is CUT")
            t.checkEqual(plan?.segments[2].transition, .cut, "12. Scene 2 start is CUT")
        }

        // 13. --- separator
        do {
            let prompt = """
            A man reads a newspaper on the train.
            ---
            The train arrives at the station.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "13. --- separator creates 2 shots")
            t.checkEqual(plan?.segments[0].literalPrompt, "A man reads a newspaper on the train.", "13. Shot 1 prompt matches")
            t.checkEqual(plan?.segments[1].literalPrompt, "The train arrives at the station.", "13. Shot 2 prompt matches")
            t.checkEqual(plan?.segments[1].transition, .cut, "13. Shot 2 after --- is CUT")
        }

        // 14. Line-start numbered list
        do {
            let prompt = """
            1. An astronaut steps onto the red surface.
            2. The astronaut picks up a soil sample.
            3. The astronaut looks toward the horizon.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 3, "14. Line-start numbered list creates 3 shots")
            t.checkEqual(plan?.segments[0].literalPrompt, "An astronaut steps onto the red surface.", "14. Item 1 number stripped")
            t.checkEqual(plan?.segments[1].literalPrompt, "The astronaut picks up a soil sample.", "14. Item 2 number stripped")
            t.checkEqual(plan?.segments[2].literalPrompt, "The astronaut looks toward the horizon.", "14. Item 3 number stripped")
        }

        // 15. Number inside ordinary prose is NOT a marker
        do {
            let prompt = "The store has 2 doors and 1 large window. A customer enters through door 2."
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "15. Inline numbers do not trigger list splitting")
            t.checkEqual(plan?.segments[0].literalPrompt, "The store has 2 doors and 1 large window.", "15. Inline numbers intact")
            t.checkEqual(plan?.segments[1].literalPrompt, "A customer enters through door 2.", "15. Second sentence intact")
        }

        // 16. Empty prompt rejected
        do {
            var caught = false
            do {
                _ = try StructuralMoviePlanner.plan(prompt: "")
            } catch StructuralMoviePlannerError.emptyPrompt {
                caught = true
            } catch {}
            t.check(caught, "16. Empty prompt throws emptyPrompt error")
        }

        // 17. Whitespace-only prompt rejected
        do {
            var caught = false
            do {
                _ = try StructuralMoviePlanner.plan(prompt: "   \n\n\t   \n")
            } catch StructuralMoviePlannerError.emptyPrompt {
                caught = true
            } catch {}
            t.check(caught, "17. Whitespace-only prompt throws emptyPrompt error")
        }

        // 18. Punctuation-only empty/meaningless segments ignored safely
        do {
            let prompt = "Walks forward. ... --- !!! Looks back."
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "18. Meaningless punctuation noise ignored")
            t.checkEqual(plan?.segments[0].literalPrompt, "Walks forward.", "18. Shot 1 prompt matches")
            t.checkEqual(plan?.segments[1].literalPrompt, "Looks back.", "18. Shot 2 prompt matches")
        }

        // 19. 12 shots accepted
        do {
            let twelveSentences = (1...12).map { "Sentence \($0) is action." }.joined(separator: " ")
            let plan = try? StructuralMoviePlanner.plan(prompt: twelveSentences)
            t.checkEqual(plan?.segments.count, 12, "19. Exactly 12 shots accepted")
        }

        // 20. 13 shots rejected
        do {
            let thirteenSentences = (1...13).map { "Sentence \($0) is action." }.joined(separator: " ")
            var caught = false
            do {
                _ = try StructuralMoviePlanner.plan(prompt: thirteenSentences)
            } catch StructuralMoviePlannerError.exceedsMaximumShots(let count, let max) {
                caught = count == 13 && max == 12
            } catch {}
            t.check(caught, "20. 13 shots throws exceedsMaximumShots error")
        }

        // 21. Sentinel literal prompt preservation
        do {
            let sentinelPrompt = """
            DIRECT_AUTO_MOVIE_RAW_SENTINEL_77.
            The subject walks left.
            The subject stops.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: sentinelPrompt)
            t.checkEqual(plan?.segments.count, 3, "21. Sentinel input creates 3 shots")
            t.checkEqual(plan?.segments[0].literalPrompt, "DIRECT_AUTO_MOVIE_RAW_SENTINEL_77.", "21. Sentinel 1 verbatim")
            t.checkEqual(plan?.segments[1].literalPrompt, "The subject walks left.", "21. Sentinel 2 verbatim")
            t.checkEqual(plan?.segments[2].literalPrompt, "The subject stops.", "21. Sentinel 3 verbatim")
        }

        // 22. No Opening/Development/Resolution injection
        do {
            let plan = try? StructuralMoviePlanner.plan(prompt: "Step one. Step two. Step three.")
            for seg in plan?.segments ?? [] {
                t.check(!seg.literalPrompt.contains("Opening"), "22. No 'Opening' injected")
                t.check(!seg.literalPrompt.contains("Development"), "22. No 'Development' injected")
                t.check(!seg.literalPrompt.contains("Resolution"), "22. No 'Resolution' injected")
                t.check(!seg.literalPrompt.contains("The subject moves on"), "22. No AutoMovieBeatPlanner template injected")
            }
        }

        // 23. No camera injection
        do {
            let plan = try? StructuralMoviePlanner.plan(prompt: "A runner crosses the finish line. Spectators cheer.")
            for seg in plan?.segments ?? [] {
                t.check(!seg.literalPrompt.contains("camera"), "23. No camera keywords injected")
                t.check(!seg.literalPrompt.contains("dolly"), "23. No dolly keywords injected")
                t.check(!seg.literalPrompt.contains("pan"), "23. No pan keywords injected")
            }
        }

        // 24. No dialogue injection
        do {
            let plan = try? StructuralMoviePlanner.plan(prompt: "Two people shake hands in a conference room.")
            for seg in plan?.segments ?? [] {
                t.check(!seg.literalPrompt.contains("says:"), "24. No dialogue quotes injected")
            }
        }

        // 25. No character text injection
        do {
            let plan = try? StructuralMoviePlanner.plan(prompt: "A hero stands on a cliff overlooking the ocean.")
            for seg in plan?.segments ?? [] {
                t.check(!seg.literalPrompt.contains("CharacterBible"), "25. No bible context injected")
            }
        }

        // 26. Same input always yields exactly same output (deterministic)
        do {
            let testPrompt = "First beat. Second beat. Third beat.\n\nFourth beat."
            let plan1 = try? StructuralMoviePlanner.plan(prompt: testPrompt)
            let plan2 = try? StructuralMoviePlanner.plan(prompt: testPrompt)
            t.checkEqual(plan1, plan2, "26. StructuralMoviePlanner is strictly deterministic")
        }

        // 27. Capacity validation succeeds when representable
        do {
            var succeeded = false
            do {
                // 3 shots with 10.0s max = 30.0s capacity; requesting 20.0s is valid
                try StructuralMoviePlanner.validateCapacity(
                    requestedTotalDuration: 20.0,
                    shotCount: 3,
                    maximumSecondsPerShot: 10.0
                )
                succeeded = true
            } catch {}
            t.check(succeeded, "27. Capacity validation succeeds when representable")
        }

        // 28. Capacity validation fails when requested duration exceeds capacity
        do {
            var caught = false
            do {
                // 2 shots with 10.0s max = 20.0s capacity; requesting 25.0s must fail closed
                try StructuralMoviePlanner.validateCapacity(
                    requestedTotalDuration: 25.0,
                    shotCount: 2,
                    maximumSecondsPerShot: 10.0
                )
            } catch StructuralMoviePlannerError.exceedsDurationCapacity(let req, let max) {
                caught = req == 25.0 && max == 20.0
            } catch {}
            t.check(caught, "28. Capacity validation fails closed when requested exceeds max capacity")
        }

        // 29. Capacity validation never creates extra segments
        do {
            let plan = try? StructuralMoviePlanner.plan(prompt: "Just one sentence.")
            t.checkEqual(plan?.segments.count, 1, "29. Segment count stays exactly 1 regardless of duration considerations")
        }

        // 30. Capacity validation does not know model IDs
        do {
            var arbitraryValid = false
            do {
                try StructuralMoviePlanner.validateCapacity(
                    requestedTotalDuration: 45.0,
                    shotCount: 3,
                    maximumSecondsPerShot: 15.0
                )
                arbitraryValid = true
            } catch {}
            t.check(arbitraryValid, "30. Capacity validation operates purely on numerical capacity without engine coupling")
        }

        // ====================================================================
        // PHASE 3C-1.1 HARDENING TESTS
        // ====================================================================

        // 31. [CUT] followed by Shot N marker → CUT preserved
        do {
            let prompt = """
            First action.
            [CUT]
            Shot 2:
            Second action.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "31. Plan has 2 shots")
            t.checkEqual(plan?.segments[0].transition, .cut, "31. Shot 1 is CUT")
            t.checkEqual(plan?.segments[1].literalPrompt, "Second action.", "31. Shot 2 literal prompt matches")
            t.checkEqual(plan?.segments[1].transition, .cut, "31. Shot 2 transition is CUT ([CUT] survived Shot 2: marker)")
        }

        // 32. [CONTINUE] followed by Shot N marker → CONTINUE preserved
        do {
            let prompt = """
            First action.

            [CONTINUE]
            Shot 2:
            Second action.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "32. Plan has 2 shots")
            t.checkEqual(plan?.segments[1].literalPrompt, "Second action.", "32. Shot 2 literal prompt matches")
            t.checkEqual(plan?.segments[1].transition, .continueFromPrevious, "32. Shot 2 transition is CONTINUE ([CONTINUE] survived Shot 2: and paragraph)")
        }

        // 33. [CONTINUE] followed by Scene N marker → explicit CONTINUE wins over Scene default
        do {
            let prompt = """
            First action.
            [CONTINUE]
            Scene 2:
            Second action.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "33. Plan has 2 shots")
            t.checkEqual(plan?.segments[1].literalPrompt, "Second action.", "33. Shot 2 literal prompt matches")
            t.checkEqual(plan?.segments[1].transition, .continueFromPrevious, "33. Explicit [CONTINUE] overrides Scene 2 default CUT")
        }

        // 34. Scene N without explicit transition → CUT
        do {
            let prompt = """
            First action.
            Scene 2:
            Second action.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "34. Plan has 2 shots")
            t.checkEqual(plan?.segments[1].literalPrompt, "Second action.", "34. Shot 2 literal prompt matches")
            t.checkEqual(plan?.segments[1].transition, .cut, "34. Scene 2 without override defaults to CUT")
        }

        // 35. [CUT] followed by [CONTINUE] → last explicit marker wins
        do {
            let prompt = """
            First action.
            [CUT]
            [CONTINUE]
            Shot 2:
            Second action.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "35. Plan has 2 shots")
            t.checkEqual(plan?.segments[1].transition, .continueFromPrevious, "35. Last explicit marker [CONTINUE] wins")
        }

        // 36. [CONTINUE] followed by [CUT] → last explicit marker wins
        do {
            let prompt = """
            First action.
            [CONTINUE]
            [CUT]
            Shot 2:
            Second action.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "36. Plan has 2 shots")
            t.checkEqual(plan?.segments[1].transition, .cut, "36. Last explicit marker [CUT] wins")
        }

        // 37. Explicit marker survives blank-line / metadata combination
        do {
            let prompt = """
            First action.

            [CUT]

            Shot 2:

            Second action.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 2, "37. Plan has 2 shots")
            t.checkEqual(plan?.segments[1].transition, .cut, "37. [CUT] survives empty lines and metadata")
        }

        // 38. Pending marker is consumed exactly once
        do {
            let prompt = """
            Shot 1: Action 1.
            [CUT]
            Shot 2: Action 2.
            Shot 3: Action 3.
            """
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 3, "38. Plan has 3 shots")
            t.checkEqual(plan?.segments[0].transition, .cut, "38. Shot 1 is CUT")
            t.checkEqual(plan?.segments[1].transition, .cut, "38. Shot 2 is CUT (explicit marker consumed)")
            t.checkEqual(plan?.segments[2].transition, .continueFromPrevious, "38. Shot 3 returns to default CONTINUE (not CUT)")
        }

        // 39. Internal newline preserved
        do {
            let prompt = "A woman walks slowly\ntoward the old wooden door."
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 1, "39. Single multiline sentence produces 1 shot")
            t.checkEqual(plan?.segments[0].literalPrompt, "A woman walks slowly\ntoward the old wooden door.", "39. Internal newline preserved verbatim")
        }

        // 40. CRLF normalizes to LF
        do {
            let prompt = "First line.\r\nSecond line.\r\nThird line."
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 3, "40. CRLF input parsed into 3 shots")
            t.check(!plan!.segments.contains { $0.literalPrompt.contains("\r") }, "40. No carriage return \\r remaining")
        }

        // 41. Leading/trailing whitespace may be trimmed
        do {
            let prompt = "   \n  Walks forward.   \n   "
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 1, "41. Whitespace trimmed")
            t.checkEqual(plan?.segments[0].literalPrompt, "Walks forward.", "41. Clean prompt output")
        }

        // 42. Structural marker itself removed without rewriting adjacent user text
        do {
            let prompt = "Shot 1: The detective enters the foggy harbor at midnight."
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 1, "42. 1 shot produced")
            t.checkEqual(plan?.segments[0].literalPrompt, "The detective enters the foggy harbor at midnight.", "42. Shot 1: stripped cleanly without modifying remaining sentence")
        }

        // 43. Japanese multiline content preserved
        do {
            let prompt = "女性がゆっくりと\n古い木製のドアへ歩く。"
            let plan = try? StructuralMoviePlanner.plan(prompt: prompt)
            t.checkEqual(plan?.segments.count, 1, "43. Japanese multiline sentence produces 1 shot")
            t.checkEqual(plan?.segments[0].literalPrompt, "女性がゆっくりと\n古い木製のドアへ歩く。", "43. Japanese internal newline preserved")
        }

        // 44. Sentinel multiline prompt exact preservation
        do {
            let sentinelPrompt = "DIRECT_MULTILINE_SENTINEL_88\nliteral second line."
            let plan = try? StructuralMoviePlanner.plan(prompt: sentinelPrompt)
            t.checkEqual(plan?.segments.count, 1, "44. Multiline sentinel produces 1 shot")
            t.checkEqual(plan?.segments[0].literalPrompt, "DIRECT_MULTILINE_SENTINEL_88\nliteral second line.", "44. Multiline sentinel preserved exactly")
        }
    }
}
