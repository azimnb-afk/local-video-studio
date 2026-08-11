import Foundation

/// Asks local vision what a continuity frame shows, in visibility terms.
///
/// Reuses the same `CharacterSheetVisionProvider` the Character Sheet importer
/// and the Opening Reference sync already use — no second backend, loopback
/// only. The question is deliberately about visibility, never identity: the app
/// does not do face recognition and does not claim to.
enum IdentitySourceAssessor {

    static let systemPrompt = """
    You report only what is visible in a single film frame, in plain visual \
    terms. You never identify or name anyone. You never guess at anything the \
    frame does not show. If the subject is turned away, say so rather than \
    describing a face you cannot see. Answer with JSON only.
    """

    static let userPrompt = """
    Report on the main person in this frame.

    - subjectPresent: is a person visible at all?
    - subjectCount: how many people are visible.
    - subjectScale: how much of the frame height the person occupies —
      "tiny" (a distant figure), "small", "medium" (roughly half), or
      "large" (most of the frame).
    - faceVisibility: "clear" if facial features are legible, "partial" if
      turned or obscured, "none" if the face cannot be seen at all.
    - subjectOrientation: "front", "threeQuarter", "profile", or "back".
    - hairVisibility and costumeVisibility: "clear", "partial" or "none".

    Describe only what is visible. Do not identify the person.
    """

    static let outputSchema: [String: Any] = {
        func enumString(_ values: [String]) -> [String: Any] {
            ["type": "string", "enum": values]
        }
        let visibility = enumString(["clear", "partial", "none"])
        let properties: [String: Any] = [
            "subjectPresent": ["type": "boolean"],
            "subjectCount": ["type": "integer"],
            "subjectScale": enumString(["tiny", "small", "medium", "large"]),
            "faceVisibility": visibility,
            "hairVisibility": visibility,
            "costumeVisibility": visibility,
            "subjectOrientation": enumString(["front", "threeQuarter", "profile", "back"]),
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
            "required": Array(properties.keys),
        ]
    }()

    /// Pure decoding, so the parsing rules are testable without Ollama running.
    static func assessment(
        fromResponse text: String,
        sourceRelativePath: String,
        model: String,
        now: Date = Date()
    ) -> IdentitySourceAssessment {
        var result = IdentitySourceAssessment()
        result.sourceRelativePath = sourceRelativePath
        result.analysisModel = model
        result.assessedAt = now

        guard let json = jsonObject(from: text) else {
            result.status = .failed
            result.ambiguityReason = "The response was not usable JSON."
            return result
        }
        result.subjectPresent = (json["subjectPresent"] as? Bool) ?? false
        result.subjectCount = (json["subjectCount"] as? Int) ?? 0
        result.subjectScale = IdentitySourceAssessment.SubjectScale(
            rawValue: (json["subjectScale"] as? String) ?? "") ?? .unknown
        result.faceVisibility = IdentitySourceAssessment.Visibility(
            rawValue: (json["faceVisibility"] as? String) ?? "") ?? .unknown
        result.hairVisibility = IdentitySourceAssessment.Visibility(
            rawValue: (json["hairVisibility"] as? String) ?? "") ?? .unknown
        result.costumeVisibility = IdentitySourceAssessment.Visibility(
            rawValue: (json["costumeVisibility"] as? String) ?? "") ?? .unknown
        result.subjectOrientation = IdentitySourceAssessment.Orientation(
            rawValue: (json["subjectOrientation"] as? String) ?? "") ?? .ambiguous
        result.status = .assessed
        return result
    }

    static func unavailable(sourceRelativePath: String) -> IdentitySourceAssessment {
        var result = IdentitySourceAssessment()
        result.status = .unavailable
        result.sourceRelativePath = sourceRelativePath
        result.ambiguityReason = "Local Vision was not available."
        return result
    }

    /// Never throws: an assessment that cannot be made simply is not made, and
    /// the policy then leaves continuity alone.
    static func assess(
        imageData: Data,
        sourceRelativePath: String,
        provider: CharacterSheetVisionProvider
    ) async -> IdentitySourceAssessment {
        guard await provider.isAvailable(), let model = provider.modelIdentifier else {
            return unavailable(sourceRelativePath: sourceRelativePath)
        }
        do {
            let text = try await provider.complete(
                imageData: imageData, system: systemPrompt,
                prompt: userPrompt, outputSchema: outputSchema)
            await provider.terminate()
            return assessment(
                fromResponse: text, sourceRelativePath: sourceRelativePath, model: model)
        } catch {
            await provider.terminate()
            return unavailable(sourceRelativePath: sourceRelativePath)
        }
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end, let data = String(text[start...end]).data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
