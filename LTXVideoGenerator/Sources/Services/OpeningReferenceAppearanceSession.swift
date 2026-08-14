import Foundation

/// Runs the Opening Reference appearance analysis for the create flow.
///
/// Thin on purpose: model selection reuses `CharacterSheetVisionEnvironmentService`
/// (the same preference and the same capability probe the Character Sheet
/// importer uses) and the request itself reuses `OllamaCharacterSheetVisionProvider`.
/// There is no second vision backend and nothing leaves the machine.
enum OpeningReferenceAppearanceSession {

    /// Never throws. A movie must still be creatable when local vision is off,
    /// missing, or broken — it just gets created without the extra evidence.
    static func analyse(
        image: OpeningReferenceImage,
        projectID: UUID,
        store: FilmProjectStore,
        environment: CharacterSheetVisionEnvironmentService = CharacterSheetVisionEnvironmentService()
    ) async -> OpeningReferenceAppearance {
        let relativePath = image.projectRelativePath
        guard let url = store.managedProjectAssetURL(
                  projectID: projectID, relativePath: relativePath),
              let data = try? Data(contentsOf: url) else {
            return OpeningReferenceAppearanceAnalyzer.unavailable(sourceRelativePath: relativePath)
        }
        let snapshot = await environment.refresh()
        guard snapshot.effectiveMode == .localVision, let model = snapshot.effectiveModel else {
            return OpeningReferenceAppearanceAnalyzer.unavailable(sourceRelativePath: relativePath)
        }
        return await OpeningReferenceAppearanceAnalyzer.analyse(
            imageData: data,
            sourceRelativePath: relativePath,
            provider: OllamaCharacterSheetVisionProvider(model: model)
        )
    }
}
