import Foundation
@testable import LTXVideoGeneratorCore

// Inspection mode: run a real Director plan through the shipping capability
// policy and print the original next to the effective plan. Used to sample
// plans from several briefs without writing a second copy of the rules.
//   swift run LTXTests --capability-plan <plan.json> ["<brief>"]
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--capability-plan" {
    let path = CommandLine.arguments[2]
    let brief = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let draft = try JSONDecoder().decode(StoryboardDirector.StoryboardDraft.self, from: data)
    let planned = CapabilityAwareShotPlanner.plan(shots: draft.shots, brief: brief)
    print("brief: \(brief)")
    for (index, adjustment) in planned.adjustments.enumerated() {
        let original = draft.shots[index]
        let effective = planned.shots[index]
        print("--- shot \(index + 1) [\(original.continuity ?? "?")] \(adjustment.risk.rawValue)")
        print("    planned  : \(original.shotScale ?? "?") | \(original.summary)")
        print("    effective: \(effective.shotScale ?? "?") | \(effective.summary)")
        if !adjustment.reasons.isEmpty {
            print("    why      : \(adjustment.reasons.joined(separator: "; "))")
        }
    }
    // The effective plan is written back so a harness can render from exactly
    // what the app would generate, without reimplementing the policy.
    var effectiveDraft = draft
    effectiveDraft.shots = planned.shots
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let effectivePath = path + ".effective.json"
    try encoder.encode(effectiveDraft).write(to: URL(fileURLWithPath: effectivePath))
    print("effective plan: \(effectivePath)")
    exit(0)
}

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
runAdaptiveContinuityStrengthTests(t)
runCapabilityAwarePlanningTests(t)
runOpeningAnchorTests(t)
runCharacterAnchorTests(t)
runOpeningReferenceTests(t)
runProductionQueueTests(t)
runAPITests(t)
runDependencyHealthTests(t)
runHuggingFaceCacheCheckerTests(t)

t.finish()
