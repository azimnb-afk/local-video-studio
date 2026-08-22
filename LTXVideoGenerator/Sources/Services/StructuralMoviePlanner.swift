import Foundation

/// Structural planning output for Director OFF.
struct StructuralMoviePlan: Equatable {
    var segments: [StructuralMovieSegment]
}

/// A single literal shot segment in a structural movie plan.
struct StructuralMovieSegment: Equatable {
    var index: Int
    var literalPrompt: String
    var transition: ShotContinuityMode
    var structuralBoundaryReason: String?
}

/// Errors produced during deterministic structural movie planning.
enum StructuralMoviePlannerError: LocalizedError, Equatable {
    case emptyPrompt
    case exceedsMaximumShots(count: Int, maximum: Int)
    case exceedsDurationCapacity(requestedSeconds: Double, maximumRepresentableSeconds: Double)

    var errorDescription: String? {
        userFacingDescription
    }

    var userFacingDescription: String {
        switch self {
        case .emptyPrompt:
            return "Enter a movie prompt."
        case .exceedsMaximumShots:
            return "Director Off supports up to 12 structured shots. Reduce the number of segments or turn Director on."
        case .exceedsDurationCapacity:
            return "Director Off needs more prompt segments for this movie length. Add more shots/paragraphs or turn Director on."
        }
    }
}

/// Deterministic structural movie planner for Director OFF in Auto Movie.
///
/// Converts the user's prompt structure directly into literal movie shot segments
/// without invoking an LLM, without creative semantic rewriting, and without
/// inventing camera, acting, lighting, dialogue, or story beats.
enum StructuralMoviePlanner {
    static let maximumShotCount = 12

    /// Parses the raw prompt into a deterministic structural movie plan.
    static func plan(prompt: String) throws -> StructuralMoviePlan {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw StructuralMoviePlannerError.emptyPrompt
        }

        let normalized = trimmedPrompt.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        struct IntermediateBlock {
            var lines: [String]
            var explicitTransition: ShotContinuityMode?
            var isNewParagraph: Bool
            var isSceneBoundary: Bool
            var structuralReason: String?
        }

        var blocks: [IntermediateBlock] = []
        var currentBlockLines: [String] = []

        // Pending explicit transition set by [CUT], CUT:, [CONTINUE], CONTINUE:, ---
        // Survives metadata markers (Shot N, Scene N) and empty lines until consumed
        // by a block that actually has content lines.
        var pendingExplicitTransition: ShotContinuityMode?
        var pendingStructuralReason: String?
        var pendingIsNewParagraph = false
        var pendingIsSceneBoundary = false

        func flushCurrentBlock() {
            let filtered = currentBlockLines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !filtered.isEmpty {
                blocks.append(IntermediateBlock(
                    lines: filtered,
                    explicitTransition: pendingExplicitTransition,
                    isNewParagraph: pendingIsNewParagraph || blocks.isEmpty,
                    isSceneBoundary: pendingIsSceneBoundary,
                    structuralReason: pendingStructuralReason
                ))
                // Once consumed by a content block, clear the pending explicit transition
                pendingExplicitTransition = nil
                pendingStructuralReason = nil
                pendingIsNewParagraph = false
                pendingIsSceneBoundary = false
            }
            currentBlockLines = []
        }

        for line in lines {
            let lineTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Empty line indicates paragraph boundary
            if lineTrimmed.isEmpty {
                flushCurrentBlock()
                pendingIsNewParagraph = true
                continue
            }

            // Separator marker (--- or - - -)
            if lineTrimmed == "---" || lineTrimmed == "- - -" {
                flushCurrentBlock()
                pendingExplicitTransition = .cut
                pendingStructuralReason = "Explicit separator (\(lineTrimmed))"
                continue
            }

            // Explicit [CUT] or CUT:
            if let cutRemainder = stripPrefix(lineTrimmed, prefixes: ["[CUT]", "[cut]", "CUT:", "cut:"]) {
                flushCurrentBlock()
                pendingExplicitTransition = .cut
                pendingStructuralReason = "Explicit [CUT] marker"
                if !cutRemainder.isEmpty {
                    currentBlockLines.append(cutRemainder)
                }
                continue
            }

            // Explicit [CONTINUE] or CONTINUE:
            if let continueRemainder = stripPrefix(lineTrimmed, prefixes: ["[CONTINUE]", "[continue]", "CONTINUE:", "continue:"]) {
                flushCurrentBlock()
                pendingExplicitTransition = .continueFromPrevious
                pendingStructuralReason = "Explicit [CONTINUE] marker"
                if !continueRemainder.isEmpty {
                    currentBlockLines.append(continueRemainder)
                }
                continue
            }

            // Shot marker: e.g. "Shot 1:", "[Shot 1]", "Shot 1."
            if let shotRemainder = stripShotMarker(lineTrimmed) {
                flushCurrentBlock()
                // Shot marker acts as structural boundary, but does NOT overwrite pendingExplicitTransition
                if !shotRemainder.isEmpty {
                    currentBlockLines.append(shotRemainder)
                }
                continue
            }

            // Scene marker: e.g. "Scene 1:", "[Scene 1]", "Scene 1." (Defaults to CUT unless explicit transition is pending)
            if let sceneRemainder = stripSceneMarker(lineTrimmed) {
                flushCurrentBlock()
                pendingIsSceneBoundary = true
                if !sceneRemainder.isEmpty {
                    currentBlockLines.append(sceneRemainder)
                }
                continue
            }

            // Line-start numbered list: e.g. "1. ", "2. "
            if let numberRemainder = stripNumberedListPrefix(lineTrimmed) {
                flushCurrentBlock()
                if !numberRemainder.isEmpty {
                    currentBlockLines.append(numberRemainder)
                }
                continue
            }

            // Regular prose line - preserve verbatim (internal line breaks)
            currentBlockLines.append(line)
        }

        flushCurrentBlock()

        // If no blocks were created from valid text, fail
        guard !blocks.isEmpty else {
            throw StructuralMoviePlannerError.emptyPrompt
        }

        // Expand blocks into sentence segments
        var segments: [StructuralMovieSegment] = []

        for block in blocks {
            let blockText = block.lines.joined(separator: "\n")
            let sentences = splitIntoSentences(blockText)

            for (sentenceIndex, sentence) in sentences.enumerated() {
                let transition: ShotContinuityMode
                let reason: String?

                if segments.isEmpty {
                    // First shot is always CUT
                    transition = .cut
                    reason = "First shot of movie"
                } else if sentenceIndex == 0 {
                    // First sentence of this block
                    if let explicit = block.explicitTransition {
                        transition = explicit
                        reason = block.structuralReason
                    } else if block.isSceneBoundary {
                        transition = .cut
                        reason = "Scene boundary"
                    } else if block.isNewParagraph {
                        transition = .cut
                        reason = "Paragraph boundary"
                    } else {
                        transition = .continueFromPrevious
                        reason = "Sequential continuation"
                    }
                } else {
                    // Subsequent sentence within the same block/paragraph
                    transition = .continueFromPrevious
                    reason = "Same paragraph sentence continuation"
                }

                segments.append(StructuralMovieSegment(
                    index: segments.count,
                    literalPrompt: sentence,
                    transition: transition,
                    structuralBoundaryReason: reason
                ))
            }
        }

        guard !segments.isEmpty else {
            throw StructuralMoviePlannerError.emptyPrompt
        }

        if segments.count > maximumShotCount {
            throw StructuralMoviePlannerError.exceedsMaximumShots(
                count: segments.count,
                maximum: maximumShotCount
            )
        }

        return StructuralMoviePlan(segments: segments)
    }

    /// Validates whether the requested total duration is representable with
    /// the given shot count without duplicating or inventing shots.
    static func validateCapacity(
        requestedTotalDuration: Double,
        shotCount: Int,
        maximumSecondsPerShot: Double
    ) throws {
        guard requestedTotalDuration > 0 else { return }
        guard shotCount > 0 else {
            throw StructuralMoviePlannerError.emptyPrompt
        }
        let maxCap = Double(shotCount) * maximumSecondsPerShot
        guard requestedTotalDuration <= maxCap + 0.001 else {
            throw StructuralMoviePlannerError.exceedsDurationCapacity(
                requestedSeconds: requestedTotalDuration,
                maximumRepresentableSeconds: maxCap
            )
        }
    }

    // MARK: - Sentence Splitting

    static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        let length = chars.count
        var i = 0

        let commonAbbreviations: Set<String> = [
            "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "vs.", "etc.", "e.g.", "i.e."
        ]

        while i < length {
            let ch = chars[i]
            current.append(ch)

            if ch == "。" || ch == "！" || ch == "？" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if isMeaningful(trimmed) {
                    sentences.append(trimmed)
                }
                current = ""
            } else if ch == "." || ch == "!" || ch == "?" {
                var isEndOfSentence = false

                if i + 1 >= length {
                    isEndOfSentence = true
                } else {
                    let nextCh = chars[i + 1]
                    if nextCh.isWhitespace {
                        if ch == "." {
                            let words = current.split(separator: " ")
                            if let lastWord = words.last?.lowercased(), commonAbbreviations.contains(lastWord) {
                                isEndOfSentence = false
                            } else {
                                isEndOfSentence = true
                            }
                        } else {
                            isEndOfSentence = true
                        }
                    }
                }

                if isEndOfSentence {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isMeaningful(trimmed) {
                        sentences.append(trimmed)
                    }
                    current = ""
                }
            }
            i += 1
        }

        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if isMeaningful(remaining) {
            sentences.append(remaining)
        }

        return sentences
    }

    private static func isMeaningful(_ text: String) -> Bool {
        let ignoredCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".!?。！？-,:;[]()_ "))
        let clean = text.trimmingCharacters(in: ignoredCharacters)
        return !clean.isEmpty
    }

    // MARK: - Structural Marker Parsers

    private static func stripPrefix(_ text: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            if text.hasPrefix(prefix) {
                let remainder = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return remainder
            }
        }
        return nil
    }

    private static func stripShotMarker(_ text: String) -> String? {
        let pattern = #"^(?:\[\s*)?Shot\s+\d+[:.]?(?:\s*\])?\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range) {
            if let swiftRange = Range(match.range, in: text) {
                return text.replacingCharacters(in: swiftRange, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func stripSceneMarker(_ text: String) -> String? {
        let pattern = #"^(?:\[\s*)?Scene\s+\d+[:.]?(?:\s*\])?\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range) {
            if let swiftRange = Range(match.range, in: text) {
                return text.replacingCharacters(in: swiftRange, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func stripNumberedListPrefix(_ text: String) -> String? {
        let pattern = #"^\d+\.\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range) {
            if let swiftRange = Range(match.range, in: text) {
                return text.replacingCharacters(in: swiftRange, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
