import Foundation

/// How a local model is asked to express a storyboard plan.
///
/// Local models differ enormously in whether they can emit a deep nested JSON
/// object on demand. Rather than branching on model names — which does not
/// generalise to whatever a user has installed — the app probes what a model
/// can actually produce and records the protocol that worked.
///
/// `basic` is deliberately not a case here: the Basic Director is a
/// deterministic non-LLM provider, not a way of talking to a local model.
enum LocalDirectorProtocol: String, Codable, CaseIterable, Equatable {
    /// One JSON object matching `StoryboardDraft`. Preferred: it carries the
    /// most structure and is what capable models already produce.
    case structuredJSON
    /// Line-oriented plain text with fixed markers, converted to the same
    /// `StoryboardDraft` by a deterministic parser. For models that cannot
    /// reliably emit nested JSON but can still plan.
    case textProtocol

    /// Order the negotiator tries protocols in: richest first.
    static let negotiationOrder: [LocalDirectorProtocol] = [.structuredJSON, .textProtocol]

    var displayName: String {
        switch self {
        case .structuredJSON: return "Structured JSON"
        case .textProtocol: return "Text Protocol"
        }
    }
}

/// Builds the prompts for a protocol and turns a raw model reply back into a
/// `StoryboardDraft`. Both protocols end at the same `StoryboardDraft`, so
/// everything downstream — semantic repair, validation, the prompt compiler,
/// LTX — is shared and unchanged.
enum DirectorPlanFormat {

    static func systemPrompt(for planProtocol: LocalDirectorProtocol,
                             characterBible: CharacterBible) -> String {
        switch planProtocol {
        case .structuredJSON:
            return StoryboardDirector.storyboardSystemPrompt(characterBible: characterBible)
        case .textProtocol:
            // Deliberately short. The models that need this protocol are the
            // ones that follow a long system prompt least reliably; the
            // format itself is carried in the user turn below.
            return "You are a film director planning a short film as a sequence of 4-6 second shots."
        }
    }

    static func userPrompt(for planProtocol: LocalDirectorProtocol, brief: String) -> String {
        switch planProtocol {
        case .structuredJSON:
            return "BRIEF: \(brief)"
        case .textProtocol:
            // Measured: models that ignore a format described in the system
            // prompt will still fill in a template presented in the user turn,
            // so the template lives here rather than in the system prompt.
            return """
            \(textProtocolTemplate)

            BRIEF: \(brief)
            """
        }
    }

    static func repairPrompt(for planProtocol: LocalDirectorProtocol,
                             failure: String,
                             brief: String) -> String {
        switch planProtocol {
        case .structuredJSON:
            return """
            Your previous response was invalid (\(failure)). \
            Respond again with ONLY the JSON object described in the system prompt.
            BRIEF: \(brief)
            """
        case .textProtocol:
            return """
            Your previous response did not follow the required format (\(failure)).

            \(textProtocolTemplate)

            BRIEF: \(brief)
            """
        }
    }

    /// The literal template shown to the model. Fixed markers only: no nested
    /// structures, no indentation grammar, no markdown.
    static let textProtocolTemplate = """
    Fill in this exact template. Replace only the <...> parts. Output nothing else.

    LOGLINE: <one sentence>
    SHOT 1
    ACTION: <what happens>
    CAMERA: <shot scale and movement>
    CONTINUITY: CUT
    SHOT 2
    ACTION: <what happens>
    CAMERA: <shot scale and movement>
    CONTINUITY: CONTINUE
    SHOT 3
    ACTION: <what happens>
    CAMERA: <shot scale and movement>
    CONTINUITY: CONTINUE

    Plan 3 to 5 shots. CONTINUITY must be exactly CUT or CONTINUE.
    """

    /// Parses a reply into a draft using the protocol's own rules. Returns the
    /// same `ParseResult` shape both protocols' callers already handle.
    static func parse(_ response: String,
                      as planProtocol: LocalDirectorProtocol,
                      brief: String) -> StoryboardDirector.ParseResult {
        switch planProtocol {
        case .structuredJSON:
            return StoryboardDirector.parseDraftDetailed(from: response, brief: brief)
        case .textProtocol:
            return TextProtocolPlanParser.parse(response, brief: brief)
        }
    }
}
