import Foundation

/// Interface for a post-generation visual check: does a rendered Take
/// actually match what its ShotIR asked for? DEFERRED (P2) — this file
/// defines the question and the deterministic parsing of an answer; nothing
/// calls it yet. No pipeline wiring, no "Retry with AI Fix" UI, no
/// extraction-from-video step. That is a substantial, separately-scoped
/// follow-up, not a same-pass addition — see the Auto Movie V2 report.
///
/// Modeled directly on `IdentitySourceAssessor`/`IdentitySourceAssessment`,
/// the one precedent this app already has for "extracted frame → local
/// vision model → structured verdict": same reused `CharacterSheetVisionProvider`
/// backend (no second vision path), same schema-constrained JSON question,
/// same "absence of evidence is not a failure" posture. A real implementation
/// would extract a few representative frames from the finished Take (the
/// existing `ContinuityFrameExtractor.extractFrame(atPercent:)` already
/// supports arbitrary offsets) and call Local Vision once per frame; this
/// file stops short of that so it is not silently claiming a judgment
/// capability this pass never validated end-to-end.
enum ShotOutcomeEvaluator {

    static let systemPrompt = """
    You report only what is visible in a still frame from a rendered video \
    shot, compared against what the shot was supposed to show. You never \
    guess at anything the frame does not show, and you never identify or \
    name anyone. Answer with JSON only.
    """

    /// `purpose`/`actionSummary`/`endState` come straight from the same
    /// `Shot` fields Plan Preview already shows — the evaluator is asked
    /// about the same plan the user reviewed, not a second hidden spec.
    static func userPrompt(purpose: String, actionSummary: String, endState: String?) -> String {
        let endStateLine = endState.map { "- Intended ending state: \($0)\n" } ?? ""
        return """
        This shot was planned as:
        - Purpose: \(purpose)
        - Action: \(actionSummary)
        \(endStateLine)
        Report on the attached frame:
        - subjectPresent: is the main subject visible at all?
        - majorCorruption: is the frame visibly broken (garbled geometry,
          frozen/blank output, extreme artifacting) rather than a normal
          rendered frame?
        - actionPlausible: does the frame look consistent with the action
          above having happened, as far as a single still can show?
        - endStateMatch: "match", "mismatch", or "unclear" — does the frame
          look consistent with the intended ending state, when one was given?

        Describe only what is visible. Do not identify anyone.
        """
    }

    static let outputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "subjectPresent": ["type": "boolean"],
            "majorCorruption": ["type": "boolean"],
            "actionPlausible": ["type": "boolean"],
            "endStateMatch": ["type": "string", "enum": ["match", "mismatch", "unclear"]],
        ],
        "required": ["subjectPresent", "majorCorruption", "actionPlausible", "endStateMatch"],
    ]

    /// Pure decoding, so parsing is testable without a vision model running.
    /// An unusable response yields `.failed`, never a guessed verdict.
    static func verdict(fromResponse text: String, shotID: UUID, model: String, now: Date = Date()) -> ShotOutcomeVerdict {
        var result = ShotOutcomeVerdict()
        result.shotID = shotID
        result.analysisModel = model
        result.assessedAt = now

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.status = .failed
            return result
        }
        guard let subjectPresent = json["subjectPresent"] as? Bool,
              let majorCorruption = json["majorCorruption"] as? Bool,
              let actionPlausible = json["actionPlausible"] as? Bool,
              let endStateRaw = json["endStateMatch"] as? String,
              let endStateMatch = ShotOutcomeVerdict.EndStateMatch(rawValue: endStateRaw)
        else {
            result.status = .failed
            return result
        }
        result.status = .assessed
        result.subjectPresent = subjectPresent
        result.majorCorruption = majorCorruption
        result.actionPlausible = actionPlausible
        result.endStateMatch = endStateMatch
        return result
    }
}

/// Deliberately not `Codable`/persisted yet: nothing produces or stores this
/// today. The shape exists so a future live implementation, and its tests,
/// have a fixed target rather than inventing the schema at wiring time.
struct ShotOutcomeVerdict: Equatable {
    enum Status: String { case assessed, unavailable, failed }
    enum EndStateMatch: String { case match, mismatch, unclear }

    var status: Status = .unavailable
    var shotID: UUID?
    var analysisModel: String = ""
    var assessedAt: Date?
    var subjectPresent: Bool = false
    var majorCorruption: Bool = false
    var actionPlausible: Bool = false
    var endStateMatch: EndStateMatch = .unclear

    /// Conservative and narrow on purpose: only an unambiguous corruption
    /// case is worth a user-facing flag without a proven evaluator behind
    /// it. Everything else stays informational until this is validated
    /// against real generations, not wired into an automatic retry.
    var suggestsRetry: Bool {
        status == .assessed && (majorCorruption || !subjectPresent)
    }
}
