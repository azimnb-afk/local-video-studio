import Foundation

/// Reads the protagonist's visible appearance out of an Opening Reference image
/// using the *existing* local vision path — the same
/// `CharacterSheetVisionProvider` the Character Sheet importer already uses.
/// There is deliberately no second vision backend and no network call beyond
/// the local Ollama endpoint.
///
/// The question asked of the model is narrow on purpose: not "describe this
/// cinematic frame" but "what does the person in it look like". Scene, lighting
/// and composition are already carried by the image itself and by the Director's
/// own plan; duplicating them in text is what created the original conflict.
enum OpeningReferenceAppearanceAnalyzer {

    static let systemPrompt = """
    You describe what is visibly true in a single film frame. You never guess. \
    If something is not visible — a face turned away, footwear out of frame, \
    hair hidden by a hood — you leave that field empty rather than inventing it. \
    Do not guess the person's age, ethnicity, or personality. \
    Do not invent a hidden story, unseen emotions, cinematic intent, future action, \
    or off-screen facts. Answer with JSON only.
    """

    static let userPrompt = """
    Describe the visual contents of this frame.

    Character Appearance:
    - hairDescription: colour and style, only if visible.
    - clothingDescription: the main garments and their colours.
    - outerwear: coat, cape, jacket or similar, if worn.
    - accessories: belts, bags, straps, visible props worn on the body.
    - silhouetteDescription: overall shape/proportions, only if clear.
    - distinctiveTraits: anything visually distinctive and unambiguous.
    - faceVisible: true only if the face is actually legible.
    - subjectCount: how many people are visible in total.

    Scene Evidence:
    - sceneEnvironment: the location and environment (e.g., "night train platform").
    - sceneLighting: the lighting style and time of day if visible.
    - subjectState: current physical action or posture of the subject.
    - keyObjects: visible key objects in the scene (e.g., "blue suitcase").

    Leave any field empty if it is not visible.
    """

    static let outputSchema: [String: Any] = {
        let string: [String: Any] = ["type": "string"]
        let fields = [
            "hairDescription", "clothingDescription", "outerwear",
            "accessories", "silhouetteDescription", "distinctiveTraits",
            "sceneEnvironment", "sceneLighting", "subjectState", "keyObjects"
        ]
        var properties: [String: Any] = Dictionary(
            uniqueKeysWithValues: fields.map { ($0, string) })
        properties["faceVisible"] = ["type": "boolean"]
        properties["subjectCount"] = ["type": "integer"]
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
            "required": fields + ["faceVisible", "subjectCount"],
        ]
    }()

    /// Decodes a model response into an appearance.
    ///
    /// Kept separate from the network call so the parsing rules — including
    /// every refusal to invent — are testable without a running Ollama.
    static func appearance(
        fromResponse text: String,
        sourceRelativePath: String,
        model: String,
        now: Date = Date()
    ) -> OpeningReferenceAppearance {
        var result = OpeningReferenceAppearance()
        result.sourceRelativePath = sourceRelativePath
        result.analysisModel = model
        result.analysedAt = now

        guard let json = jsonObject(from: text) else {
            result.status = .failed
            result.notes = "The response was not usable JSON."
            return result
        }

        func string(_ key: String) -> String {
            ((json[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        result.hairDescription = string("hairDescription")
        result.clothingDescription = string("clothingDescription")
        result.outerwear = string("outerwear")
        result.accessories = string("accessories")
        result.silhouetteDescription = string("silhouetteDescription")
        result.distinctiveTraits = string("distinctiveTraits")
        result.sceneEnvironment = string("sceneEnvironment")
        result.sceneLighting = string("sceneLighting")
        result.subjectState = string("subjectState")
        result.keyObjects = string("keyObjects")
        result.faceVisible = (json["faceVisible"] as? Bool) ?? false
        result.subjectCount = (json["subjectCount"] as? Int) ?? 0

        // Several people means we cannot say which one the story is about.
        // Refusing to merge is the safe answer; picking wrong would write the
        // wrong costume into every prompt, which is the bug this exists to stop.
        if result.subjectCount > 1 {
            result.status = .ambiguous
            result.notes = "\(result.subjectCount) people are visible, so no appearance was applied."
            return result
        }

        // An answer with nothing visible in it is not evidence.
        let described = [
            result.hairDescription, result.clothingDescription, result.outerwear,
            result.accessories, result.silhouetteDescription, result.distinctiveTraits,
            result.sceneEnvironment, result.sceneLighting, result.subjectState, result.keyObjects
        ].contains { !$0.isEmpty }
        result.status = described ? .analysed : .failed
        if !described { result.notes = "Nothing describable was returned." }
        return result
    }

    /// Result for the case where local vision simply is not there. Explicitly
    /// *not* an error: Auto Movie must still run, it just runs without the
    /// extra evidence.
    static func unavailable(sourceRelativePath: String) -> OpeningReferenceAppearance {
        var result = OpeningReferenceAppearance()
        result.status = .unavailable
        result.sourceRelativePath = sourceRelativePath
        result.notes = "Local Vision was not available, so no appearance was derived."
        return result
    }

    /// Runs the analysis against a provider. Any failure degrades to a status
    /// rather than throwing, because a missing optional analysis must never
    /// block a movie.
    static func analyse(
        imageData: Data,
        sourceRelativePath: String,
        provider: CharacterSheetVisionProvider
    ) async -> OpeningReferenceAppearance {
        guard await provider.isAvailable(), let model = provider.modelIdentifier else {
            return unavailable(sourceRelativePath: sourceRelativePath)
        }
        do {
            let text = try await provider.complete(
                imageData: imageData,
                system: systemPrompt,
                prompt: userPrompt,
                outputSchema: outputSchema
            )
            await provider.terminate()
            return appearance(
                fromResponse: text, sourceRelativePath: sourceRelativePath, model: model)
        } catch {
            await provider.terminate()
            var result = OpeningReferenceAppearance()
            result.status = .unavailable
            result.sourceRelativePath = sourceRelativePath
            result.analysisModel = model
            result.notes = "Local Vision did not answer."
            return result
        }
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        // Models often wrap JSON in prose or a fenced block.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
