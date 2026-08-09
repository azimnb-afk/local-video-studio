import Foundation
@testable import LTXVideoGeneratorCore

let t = TestKit.shared

t.suite("Catalog") {
    t.checkEqual(LTXModelCatalog.resolvedModel(id: nil).id, LTXModelCatalog.defaultModelID, "default model resolves")
    t.checkEqual((1080 / 64) * 64, 1024, "64-px floor")
}

runRegistryTests(t)
runCompatLabTests(t)
runAutoQualityTests(t)
runDirectorTests(t)
runFilmProjectTests(t)
runCharacterSheetTests(t)
runCharacterReferenceExtractionTests(t)
runStartingImageBridgeTests(t)
runStartingImageUXTests(t)
runStoryboardTests(t)
runAutoMovieContinuityTests(t)
runContinuityStrengthTests(t)
runCinematicProgressionTests(t)
runContinuityReconcilerTests(t)
runAPITests(t)
runDependencyHealthTests(t)
runHuggingFaceCacheCheckerTests(t)

t.finish()
